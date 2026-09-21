"""Vibe Key 的串行设备控制；只开放已验证的按键配置命令。"""
from __future__ import annotations

import copy
import ctypes
import queue
import sys
import threading
import time
from concurrent.futures import Future

from olanzi_fn import FnBridge

STUDIO_HEARTBEAT = bytes([0x06, 0x01, 0x23, 0x00, 0x01])

DEFAULT_CODES = (0x01, 0x28, 0x29, 0x46, 0x4F, 0x2A)
ALLOWED_CODES = frozenset([0, 1, *range(0x04, 0x64), 0x65,
                           *range(0x68, 0x74), *range(0xE0, 0xE8)])


class DeviceError(Exception):
    def __init__(self, message, status=503):
        super().__init__(message)
        self.status = status


def matches_reply(frame, access, index):
    """完整匹配命令、组、操作码、访问类型和控件，忽略无关通知。"""
    return (len(frame) >= 5 and frame[0] & 0x1F == 1
            and frame[1] == 6 and frame[2] == 0x50
            and frame[3] == access and frame[4] == index)


def parse_entries(frame):
    if len(frame) < 7 or frame[5] != 1:
        raise DeviceError("按键配置回复格式无效，请重新连接。")
    count = frame[6]
    if count > 24 or 7 + count * 2 > len(frame):
        raise DeviceError("收到不完整的按键配置回复。")
    return [[frame[7 + i * 2], frame[8 + i * 2]] for i in range(count)]


class MacHIDTransport:
    """所有 IOKit 与 CoreFoundation 调用均由同一个工作线程执行。"""
    def __init__(self):
        self.api = None
        self.dev = None
        self.frames = []
        self.callback_error = None
        self.removed = False
        self.buf = self.callback = self.removal_callback = None
        self.heartbeat_enabled = False
        self.last_heartbeat_sent = None
        self.next_heartbeat = 0

    def open(self):
        if sys.platform != "darwin":
            raise DeviceError("真实设备连接需要 macOS；其他系统可使用 --demo 预览。")
        import vibekey as api
        self.api = api
        api.cf.CFRelease.argtypes = [ctypes.c_void_p]
        api.cf.CFRelease.restype = None
        api.iok.IOHIDDeviceUnscheduleFromRunLoop.argtypes = [ctypes.c_void_p] * 3
        api.iok.IOHIDDeviceUnscheduleFromRunLoop.restype = None
        api.iok.IOHIDDeviceRegisterRemovalCallback.argtypes = [ctypes.c_void_p] * 3
        api.iok.IOHIDDeviceRegisterRemovalCallback.restype = None
        matching = api.iok.IOServiceMatching(b"IOHIDDevice")
        if not matching:
            raise DeviceError("无法枚举 HID 设备。")
        for name, value in (("VendorID", api.VIBE_VID), ("ProductID", api.VIBE_PID)):
            number = api.cfnum(value)
            api.cf.CFDictionarySetValue(matching, api.cfstr(name), number)
            api.cf.CFRelease(number)
        iterator = ctypes.c_uint32()
        rc = api.iok.IOServiceGetMatchingServices(0, matching, ctypes.byref(iterator))
        if rc:
            raise DeviceError(f"HID 枚举失败：0x{rc & 0xFFFFFFFF:08X}")
        candidates = []
        try:
            while True:
                service = api.iok.IOIteratorNext(iterator)
                if not service:
                    break
                dev = None
                try:
                    dev = api.iok.IOHIDDeviceCreate(api.kCFAllocatorDefault, service)
                    if dev and api.prop_int(dev, "PrimaryUsagePage") == api.VENDOR_USAGE_PAGE:
                        candidates.append(dev)
                        dev = None
                finally:
                    if dev:
                        api.cf.CFRelease(dev)
                    api.iok.IOObjectRelease(service)
        except Exception:
            for dev in candidates:
                api.cf.CFRelease(dev)
            raise
        finally:
            api.iok.IOObjectRelease(iterator)
        if len(candidates) != 1:
            for dev in candidates:
                api.cf.CFRelease(dev)
            raise DeviceError("请只连接一个 Vibe Key 接收器。" if candidates else
                              "未找到 Vibe Key，请插入 USB 接收器并打开设备。")
        dev = candidates[0]
        rc = api.iok.IOHIDDeviceOpen(dev, 0)
        if rc:
            api.cf.CFRelease(dev)
            detail = {0xE00002E2: "无权限，请在系统设置的输入监控中授权当前终端并重启终端",
                      0xE00002C5: "设备被占用，请关闭 Studio 或其他抓包进程"}.get(
                          rc & 0xFFFFFFFF, "厂商通道打开失败")
            raise DeviceError(f"{detail}（0x{rc & 0xFFFFFFFF:08X}）。")
        self.dev = dev
        self.removed = False
        self.callback_error = None
        self.runloop = api.cf.CFRunLoopGetCurrent()
        try:
            self.buf = (ctypes.c_uint8 * api.MAX_REPORT)()
            self.callback = api.ReportCB(self._on_report)
            self.removal_callback = ctypes.CFUNCTYPE(
                None, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p)(self._on_remove)
            api.iok.IOHIDDeviceRegisterInputReportCallback(dev, self.buf, api.MAX_REPORT,
                                                          self.callback, None)
            api.iok.IOHIDDeviceRegisterRemovalCallback(dev, self.removal_callback, None)
            api.iok.IOHIDDeviceScheduleWithRunLoop(dev, self.runloop, api.kCFRunLoopDefaultMode)
            self.heartbeat_enabled = True
            self.next_heartbeat = 0
        except Exception:
            self.close()
            raise

    def _on_remove(self, *_args):
        self.removed = True

    def _on_report(self, _ctx, result, _sender, _rtype, rid, report, length):
        try:
            if result:
                raise DeviceError(f"读取 HID 报文失败：0x{result & 0xFFFFFFFF:08X}")
            if rid != 0x55 or length not in (63, 64):
                return
            data = bytes(report[:length])
            if length == 64:
                if data[0] != 0x55:
                    return
                data = data[1:]
            # 末尾不完整的 TEA 分组不能用于解析协议字段。
            self.frames.append(self.api.tea_decrypt(data[:56]))
            self.frames = self.frames[-128:]
        except Exception as exc:
            self.callback_error = f"HID 回调处理失败：{exc}"

    def pump(self, duration=0.01):
        if not self.dev:
            return
        self.api.cf.CFRunLoopRunInMode(self.api.kCFRunLoopDefaultMode, duration, False)
        if self.callback_error:
            raise DeviceError(self.callback_error)
        if self.removed:
            raise DeviceError("USB 接收器已断开，请重新连接。")
        self.keepalive()

    def exchange(self, request, access, index, timeout=1.3):
        return self._exchange(request, lambda frame: matches_reply(frame, access, index), timeout)

    def keepalive(self):
        if not self.heartbeat_enabled or time.monotonic() < self.next_heartbeat:
            return
        # 官方心跳没有已确认的 ACK：只记录成功发送，不据此推断本体在线。
        self._send(STUDIO_HEARTBEAT)
        self.last_heartbeat_sent = time.time()
        self.next_heartbeat = time.monotonic() + 1

    def query_online(self):
        frame = self._exchange(bytes([6, 3, 0x0A, 1]),
                               lambda f: len(f) >= 5 and f[0] & 0x1F == 6
                               and f[1:4] == bytes([3, 0x0A, 0x11]), 0.8)
        if frame[4] not in (0, 1):
            raise DeviceError("接收器返回未知的设备在线状态。")
        return bool(frame[4])

    def _exchange(self, request, predicate, timeout):
        if not self.dev:
            raise DeviceError("设备尚未连接。")
        self.pump()
        self.frames.clear()
        self._send(request)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.02)
            while self.frames:
                frame = self.frames.pop(0)
                if predicate(frame):
                    return frame
        raise DeviceError("设备回复超时，请确认 Vibe Key 已开机，并关闭其他配置工具。")

    def _send(self, request):
        if not self.dev:
            raise DeviceError("设备尚未连接。")
        api = self.api
        wire = b"\x55" + api.tea_encrypt(request.ljust(64, b"\0"))[:63]
        buf = (ctypes.c_uint8 * len(wire)).from_buffer_copy(wire)
        rc = api.iok.IOHIDDeviceSetReport(self.dev, 1, 0x55, buf, len(wire))
        if rc:
            raise DeviceError(f"发送失败：0x{rc & 0xFFFFFFFF:08X}，请检查设备连接。")

    def close(self):
        self.heartbeat_enabled = False
        self.last_heartbeat_sent = None
        if self.dev:
            api = self.api
            try:
                api.iok.IOHIDDeviceUnscheduleFromRunLoop(self.dev, self.runloop,
                                                        api.kCFRunLoopDefaultMode)
                api.iok.IOHIDDeviceClose(self.dev, 0)
            finally:
                api.cf.CFRelease(self.dev)
                self.dev = None
        self.buf = self.callback = self.removal_callback = None
        self.frames.clear()


class DemoTransport:
    """独立内存中的演示设备，不加载 IOKit，不访问硬件。"""
    def __init__(self):
        self.keys = [[[2, code]] for code in DEFAULT_CODES]
        self.heartbeat_enabled = False
        self.last_heartbeat_sent = None
        self.next_heartbeat = 0

    def open(self):
        self.heartbeat_enabled = True
        self.next_heartbeat = 0

    def close(self):
        self.heartbeat_enabled = False
        self.last_heartbeat_sent = None

    def pump(self, duration=0):
        self.keepalive()

    def keepalive(self):
        if self.heartbeat_enabled and time.monotonic() >= self.next_heartbeat:
            self.last_heartbeat_sent = time.time()
            self.next_heartbeat = time.monotonic() + 1

    def query_online(self):
        return True

    def exchange(self, request, access, index, timeout=1.3):
        if access == 0x14:
            self.keys[index] = [[2, request[8]]]
        entries = self.keys[index]
        return bytes([0x81, 6, 0x50, access, index, 1, len(entries)] +
                     [value for entry in entries for value in entry])


class DeviceController:
    def __init__(self, demo=False, transport=None, fn_bridge=None, fn_enabled=False,
                 save_fn=None, settings_error=None):
        self.transport = transport or (DemoTransport() if demo else MacHIDTransport())
        self.fn_bridge = fn_bridge or FnBridge(demo=demo)
        self.fn_enabled = fn_enabled
        self.save_fn = save_fn
        self.settings_error = settings_error
        self.state = {"connected": False, "online": None, "demo": demo,
                      "heartbeat": {"enabled": False, "mode": "studio", "interval": 1,
                                    "lastSent": None, "lastReply": None},
                      "device": {"name": "Vibe Key", "model": "AU05",
                                 "firmware": None, "battery": None},
                      "keys": [], "error": None, "lastRead": None}

    def snapshot(self):
        self.state["heartbeat"]["lastSent"] = self.transport.last_heartbeat_sent
        self.state["fnBridge"] = self.fn_bridge.snapshot()
        self.state["fnBridge"]["settingsError"] = self.settings_error
        return copy.deepcopy(self.state)

    def _sync_fn(self):
        # Fn 权限与监听故障独立呈现，不能中断厂商通道及心跳。
        if self.fn_bridge.snapshot()["enabled"] != self.fn_enabled:
            self.fn_bridge.set_enabled(self.fn_enabled)
        self.fn_bridge.synchronize(self.state["connected"], self.state["online"])
        self.fn_bridge.pump()

    def configure_fn(self, payload):
        if (not isinstance(payload, dict) or set(payload) != {"enabled"}
                or type(payload["enabled"]) is not bool):
            raise DeviceError("Fn 设置只接受 enabled 布尔值。", 400)
        enabled = payload["enabled"]
        if self.save_fn:
            try:
                self.save_fn(enabled)
            except OSError as exc:
                raise DeviceError(f"无法保存 Fn 开关，设置尚未改变：{exc}", 500) from exc
        self.settings_error = None
        self.fn_enabled = enabled
        self._sync_fn()
        return self.snapshot()

    def fn_permissions(self):
        self.fn_bridge.request_permissions()
        self._sync_fn()
        return self.snapshot()

    def _read(self, index):
        frame = self.transport.exchange(bytes([1, 6, 0x50, 1, index]), 0x11, index)
        if not matches_reply(frame, 0x11, index):
            raise DeviceError("按键配置回复与当前请求不匹配。")
        entries = parse_entries(frame)
        return {"index": index, "entries": entries,
                "code": entries[0][1] if len(entries) == 1 and entries[0][0] == 2 else None}

    def refresh(self):
        if not self.state["connected"]:
            raise DeviceError("请先连接设备。", 409)
        # 全部读取成功后才替换快照，避免把半份配置当作成功结果。
        try:
            keys = [self._read(index) for index in range(6)]
        except DeviceError:
            self.state["online"] = None
            raise
        self.state.update(keys=keys, online=True, lastRead=time.time(), error=None)
        return self.snapshot()

    def connect(self):
        if self.state["connected"]:
            self.tick()
            return self.refresh() if self.state["online"] else self.snapshot()
        self.transport.open()
        self.state.update(connected=True, error=None)
        self.state["heartbeat"]["enabled"] = True
        self.transport.keepalive()
        self.tick()
        return self.snapshot()

    def tick(self):
        if not self.state["connected"]:
            return
        was_online = self.state["online"]
        try:
            self.state["online"] = self.transport.query_online()
        except DeviceError:
            self.state["online"] = None
            raise
        if not self.state["online"]:
            self.state["error"] = "接收器已连接，但 Vibe Key 本体离线，请打开设备。"
        elif was_online is not True or not self.state["keys"]:
            self.refresh()
        else:
            self.state["error"] = None

    def disconnect(self):
        self.fn_bridge.synchronize(False, None)
        self.fn_bridge.close()
        self.transport.close()
        self.state.update(connected=False, online=None, keys=[], error=None, lastRead=None)
        self.state["heartbeat"].update(enabled=False, lastSent=None, lastReply=None)
        return self.snapshot()

    @staticmethod
    def validate_apply(payload):
        if not isinstance(payload, dict) or set(payload) != {"changes", "expected"}:
            raise DeviceError("请求必须包含 changes 和 expected。", 400)
        changes, expected = payload["changes"], payload["expected"]
        if not isinstance(changes, list) or not 1 <= len(changes) <= 6:
            raise DeviceError("每次需提交 1–6 个控件。", 400)
        indices = set()
        for change in changes:
            if (not isinstance(change, dict) or set(change) != {"index", "code"}
                    or type(change["index"]) is not int or change["index"] not in range(6)
                    or type(change["code"]) is not int or change["code"] not in ALLOWED_CODES
                    or change["index"] in indices):
                raise DeviceError("控件或键码无效，或存在重复控件。", 400)
            indices.add(change["index"])
        if not isinstance(expected, list) or len(expected) != len(changes):
            raise DeviceError("expected 必须包含每个修改控件的原始配置。", 400)
        originals = {}
        for item in expected:
            if (not isinstance(item, dict) or set(item) != {"index", "entries"}
                    or type(item["index"]) is not int or item["index"] not in indices
                    or item["index"] in originals or not isinstance(item["entries"], list)
                    or len(item["entries"]) > 24):
                raise DeviceError("expected 配置格式无效。", 400)
            for entry in item["entries"]:
                if (not isinstance(entry, list) or len(entry) != 2
                        or any(type(value) is not int or not 0 <= value <= 255 for value in entry)):
                    raise DeviceError("expected 键码格式无效。", 400)
            originals[item["index"]] = item["entries"]
        return changes, originals

    def apply(self, payload):
        changes, expected = self.validate_apply(payload)
        if not self.state["connected"] or self.state["online"] is not True:
            raise DeviceError("请先连接并打开设备。", 409)
        self.refresh()
        for change in changes:
            index = change["index"]
            if self.state["keys"][index]["entries"] != expected[index]:
                raise DeviceError("设备配置已被其他程序修改，请刷新后重新确认草稿。", 409)
        try:
            for change in changes:
                index, code = change["index"], change["code"]
                if self.state["keys"][index]["entries"] == [[2, code]]:
                    continue
                frame = self.transport.exchange(bytes([1, 6, 0x50, 4, index, 1, 1, 2, code]),
                                                0x14, index)
                if not matches_reply(frame, 0x14, index):
                    raise DeviceError("写入确认与当前控件不匹配。")
                key = self._read(index)
                self.state["keys"][index] = key
                if key["entries"] != [[2, code]]:
                    raise DeviceError("设备回读与目标键码不一致；请检查实际配置后重试。")
            return self.refresh()
        except DeviceError as exc:
            # 写入没有事务保证：尽量重新读取，向界面报告已经生效的部分。
            try:
                self.refresh()
            except DeviceError:
                # 本体无回复不等于接收器被拔掉：保留通道与心跳，等待独立状态查询恢复。
                # 真正的原生断开会由下一轮 pump 检测并释放设备。
                self.state["online"] = None
            raise DeviceError(f"写入未全部完成，部分改动可能已生效。{exc}", exc.status) from exc

    def dispatch(self, action, payload=None):
        try:
            if action == "state":
                self.transport.pump()
            elif action == "apply":
                self.apply(payload)
            elif action == "configure_fn":
                self.configure_fn(payload)
            else:
                getattr(self, action)()
            self._sync_fn()
            return self.snapshot()
        except DeviceError as exc:
            self.state["error"] = str(exc)
            if action == "tick":
                self.state["online"] = None
            if action == "state" and exc.status == 503:
                self.state["connected"] = False
                self.state["online"] = None
                self.state["heartbeat"]["enabled"] = False
                self.transport.close()
            self._sync_fn()
            raise


class DeviceWorker:
    """HTTP 线程只提交任务；设备对象只在唯一的工作线程中使用。"""
    def __init__(self, demo=False, transport=None, fn_bridge=None, fn_enabled=False,
                 save_fn=None, settings_error=None, auto_connect=False):
        self.jobs = queue.Queue()
        self.controller = DeviceController(demo, transport, fn_bridge, fn_enabled,
                                           save_fn, settings_error)
        self.want_connection = auto_connect
        self.thread = threading.Thread(target=self._run, name="olanzi-hid", daemon=True)
        self.thread.start()

    def _run(self):
        next_check = time.monotonic() + 2
        next_connect = 0
        while True:
            try:
                if (self.want_connection and not self.controller.state["connected"]
                        and time.monotonic() >= next_connect):
                    next_connect = time.monotonic() + 2
                    self.controller.dispatch("connect")
                self.controller.dispatch("state")
                if self.controller.state["connected"] and time.monotonic() >= next_check:
                    next_check = time.monotonic() + 2
                    self.controller.dispatch("tick")
            except DeviceError:
                next_check = time.monotonic() + 2
            except Exception:
                self._internal_error()
            try:
                job = self.jobs.get(timeout=0.1)
            except queue.Empty:
                continue
            if job is None:
                self.controller.disconnect()
                return
            action, payload, future = job
            if not future.set_running_or_notify_cancel():
                continue
            if action in ("connect", "disconnect"):
                # 手动断开意味着暂停自动连接，直到用户再次点击连接。
                self.want_connection = action == "connect"
            try:
                state = self.controller.dispatch(action, payload)
                future.set_result((200, state))
            except DeviceError as exc:
                future.set_result((exc.status, {"error": str(exc), "state": self.controller.snapshot()}))
            except Exception:
                # 避免原生回调等意外异常让队列线程静默死亡。
                self._internal_error()
                future.set_result((500, {"error": self.controller.state["error"],
                                         "state": self.controller.snapshot()}))

    def _internal_error(self):
        import traceback
        traceback.print_exc()
        try:
            self.controller.disconnect()
        except Exception:
            traceback.print_exc()
        self.controller.state["error"] = "设备服务出现内部错误，请重新连接。"

    def call(self, action, payload=None):
        future = Future()
        self.jobs.put((action, payload, future))
        try:
            return future.result(timeout=60)
        except TimeoutError:
            cancelled = future.cancel()
            message = ("设备队列繁忙，本次操作已取消，请稍后重试。" if cancelled else
                       "设备操作尚未完成，请等待后刷新实际配置，不要重复提交。")
            return 504, {"error": message}

    def close(self):
        self.jobs.put(None)
        self.thread.join(timeout=60)
