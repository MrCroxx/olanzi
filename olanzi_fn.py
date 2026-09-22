"""仅将 AU05 的自定义 HID 键码转换为当前 Mac 会话的 Fn 事件。"""
from __future__ import annotations

import ctypes
import sys
import time

FN_FLAG = 0x800000
FN_KEYCODE = 63


def decode_fn_report(report_id, data):
    """返回按下状态；非键盘/非完整报文返回 None，rollover 不触发 Fn。"""
    if report_id != 3:
        return None
    if len(data) == 9:
        if data[0] != 3:
            return None
        data = data[1:]
    if len(data) != 8 or data[1] != 0:
        return None
    codes = data[2:]
    return codes.count(1) == 1 and not any(code in (2, 3) for code in codes)


def fn_event_flags(hardware_flags, pressed):
    """本桥接不写入硬件源状态，松开时保留真实 Fn 和其他修饰键。"""
    return hardware_flags | FN_FLAG if pressed else hardware_flags


class MacFnBackend:
    """由设备工作线程持有；独立打开标准接口，不影响厂商通信句柄。"""
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("Mac Fn 桥接仅支持 macOS。")
        import vibekey as api
        self.api = api
        self.dev = self.source = self.runloop = None
        self.buf = self.callback = self.removal_callback = None
        self.on_report = self.on_lost = None
        self.scheduled = False
        self.callback_error = None
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.ax = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        ptr = ctypes.c_void_p
        bindings = [
            (api.cf, "CFRelease", None, [ptr]),
            (api.iok, "IOHIDCheckAccess", ctypes.c_int, [ctypes.c_int]),
            (api.iok, "IOHIDRequestAccess", ctypes.c_bool, [ctypes.c_int]),
            (api.iok, "IOHIDDeviceUnscheduleFromRunLoop", None, [ptr, ptr, ptr]),
            (api.iok, "IOHIDDeviceRegisterRemovalCallback", None, [ptr, ptr, ptr]),
            (self.ax, "AXIsProcessTrusted", ctypes.c_bool, []),
            (self.cg, "CGPreflightPostEventAccess", ctypes.c_bool, []),
            (self.cg, "CGRequestPostEventAccess", ctypes.c_bool, []),
            (self.cg, "CGEventSourceCreate", ptr, [ctypes.c_int]),
            (self.cg, "CGEventSourceFlagsState", ctypes.c_uint64, [ctypes.c_int]),
            (self.cg, "CGEventCreateKeyboardEvent", ptr, [ptr, ctypes.c_uint16, ctypes.c_bool]),
            (self.cg, "CGEventSetType", None, [ptr, ctypes.c_uint32]),
            (self.cg, "CGEventSetFlags", None, [ptr, ctypes.c_uint64]),
            (self.cg, "CGEventPost", None, [ctypes.c_uint32, ptr]),
        ]
        for library, name, result, args in bindings:
            function = getattr(library, name)
            function.restype, function.argtypes = result, args

    def permissions(self):
        access = self.api.iok.IOHIDCheckAccess(1)
        return ({0: True, 1: False}.get(access),
                bool(self.ax.AXIsProcessTrusted() and self.cg.CGPreflightPostEventAccess()))

    def request_permissions(self):
        # 只有用户显式点击时才请求，后台重试始终使用无弹框查询。
        self.api.iok.IOHIDRequestAccess(1)
        self.cg.CGRequestPostEventAccess()

    @staticmethod
    def matches_device(vendor, product, usage_page, usage):
        # 实测接口 2 由 Consumer 主集合开头，同时带键盘 Report ID 3。
        return vendor == 0xFFF1 and product == 0x00DD and (usage_page, usage) in ((12, 1), (1, 6))

    def _candidates(self):
        api = self.api
        matching = api.iok.IOServiceMatching(b"IOHIDDevice")
        if not matching:
            raise RuntimeError("无法枚举 Vibe Key 输入接口。")
        handed_off = False
        iterator = ctypes.c_uint32()
        candidates = []
        try:
            for name, value in (("VendorID", 0xFFF1), ("ProductID", 0x00DD)):
                number = api.cfnum(value)
                if not number:
                    raise RuntimeError("无法创建 HID 匹配条件。")
                try:
                    api.cf.CFDictionarySetValue(matching, api.cfstr(name), number)
                finally:
                    api.cf.CFRelease(number)
            # IOServiceGetMatchingServices 消耗 matching 的引用，即使调用失败也一样。
            handed_off = True
            rc = api.iok.IOServiceGetMatchingServices(0, matching, ctypes.byref(iterator))
            if rc:
                raise RuntimeError(f"Fn 输入接口枚举失败：0x{rc & 0xFFFFFFFF:08X}")
            while True:
                service = api.iok.IOIteratorNext(iterator)
                if not service:
                    break
                dev = None
                try:
                    dev = api.iok.IOHIDDeviceCreate(api.kCFAllocatorDefault, service)
                    if dev and self.matches_device(*(api.prop_int(dev, name) for name in (
                            "VendorID", "ProductID", "PrimaryUsagePage", "PrimaryUsage"))):
                        candidates.append(dev)
                        dev = None
                finally:
                    if dev:
                        api.cf.CFRelease(dev)
                    api.iok.IOObjectRelease(service)
            return candidates
        except Exception:
            for dev in candidates:
                api.cf.CFRelease(dev)
            raise
        finally:
            if iterator.value:
                api.iok.IOObjectRelease(iterator)
            if not handed_off:
                api.cf.CFRelease(matching)

    def open(self, on_report, on_lost):
        api = self.api
        candidates = self._candidates()
        if len(candidates) != 1:
            for dev in candidates:
                api.cf.CFRelease(dev)
            raise RuntimeError("Fn 桥接需要恰好一个 Vibe Key 标准输入接口。")
        dev = candidates[0]
        rc = api.iok.IOHIDDeviceOpen(dev, 0)
        if rc:
            api.cf.CFRelease(dev)
            detail = {0xE00002E2: "请在系统设置的输入监控中授权当前终端并重启终端",
                      0xE00002C5: "输入接口被占用，请关闭 Studio 或其他抓包程序"}.get(
                          rc & 0xFFFFFFFF, "无法打开 Fn 输入接口")
            raise RuntimeError(f"{detail}（0x{rc & 0xFFFFFFFF:08X}）。")
        self.dev = dev
        self.callback_error = None
        self.on_report, self.on_lost = on_report, on_lost
        try:
            # 私有源和 session tap 使合成 Fn 不污染用于合并修饰键的 HID 硬件状态。
            self.source = self.cg.CGEventSourceCreate(-1)
            if not self.source:
                raise RuntimeError("无法创建 Mac Fn 事件源。")
            self.runloop = api.cf.CFRunLoopGetCurrent()
            self.buf = (ctypes.c_uint8 * api.MAX_REPORT)()
            self.callback = api.ReportCB(self._on_report)
            self.removal_callback = ctypes.CFUNCTYPE(
                None, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p)(self._on_remove)
            api.iok.IOHIDDeviceRegisterInputReportCallback(
                dev, self.buf, api.MAX_REPORT, self.callback, None)
            api.iok.IOHIDDeviceRegisterRemovalCallback(dev, self.removal_callback, None)
            api.iok.IOHIDDeviceScheduleWithRunLoop(dev, self.runloop, api.kCFRunLoopDefaultMode)
            self.scheduled = True
        except Exception:
            self.close()
            raise

    def _notify_lost(self, message):
        # 所有 ctypes 回调都在边界捕获异常，避免静默失效被误诊为设备休眠。
        self.callback_error = message
        try:
            if self.on_lost:
                self.on_lost(message)
        except Exception:
            # 正常桥接回调不会抛异常；此兜底仍明确记录错误供 pump 检查。
            self.callback_error = message

    def _on_report(self, _ctx, result, sender, report_type, report_id, report, length):
        try:
            if sender != self.dev or report_type != 0:
                return
            if result:
                raise RuntimeError(f"Fn 输入读取失败：0x{result & 0xFFFFFFFF:08X}")
            if report_id != 3 or length not in (8, 9):
                return
            self.on_report(report_id, bytes(report[:length]))
        except Exception as exc:
            self._notify_lost(f"Fn 输入回调失败：{exc}")

    def _on_remove(self, _ctx, _result, sender):
        # 同线程注销后到达的旧通知不能影响重新连接的句柄。
        if self.dev and sender == self.dev:
            self._notify_lost("Vibe Key 输入接口已断开。")

    def post_fn(self, pressed):
        if not self.source:
            raise RuntimeError("Mac Fn 事件源尚未就绪。")
        # 读取的是修饰键位掩码，既不读取也不记录其他键盘输入。
        flags = fn_event_flags(self.cg.CGEventSourceFlagsState(1), pressed)
        event = self.cg.CGEventCreateKeyboardEvent(self.source, FN_KEYCODE, pressed)
        if not event:
            raise RuntimeError("无法创建 Mac Fn 事件。")
        try:
            # Fn 是修饰键，按下和松开均为 flagsChanged。
            self.cg.CGEventSetType(event, 12)
            self.cg.CGEventSetFlags(event, flags)
            self.cg.CGEventPost(1, event)
        finally:
            self.api.cf.CFRelease(event)

    def close(self):
        api = self.api
        errors = []
        if self.dev:
            dev = self.dev
            operations = [
                lambda: api.iok.IOHIDDeviceRegisterInputReportCallback(dev, None, 0, None, None),
                lambda: api.iok.IOHIDDeviceRegisterRemovalCallback(dev, None, None),
            ]
            if self.scheduled:
                operations.append(lambda: api.iok.IOHIDDeviceUnscheduleFromRunLoop(
                    dev, self.runloop, api.kCFRunLoopDefaultMode))
            operations.extend((lambda: api.iok.IOHIDDeviceClose(dev, 0),
                               lambda: api.cf.CFRelease(dev)))
            for operation in operations:
                try:
                    operation()
                except Exception as exc:
                    errors.append(str(exc))
            self.dev = None
        if self.source:
            try:
                api.cf.CFRelease(self.source)
            except Exception as exc:
                errors.append(str(exc))
            self.source = None
        self.scheduled = False
        self.buf = self.callback = self.removal_callback = self.runloop = None
        self.on_report = self.on_lost = None
        if errors:
            raise RuntimeError("Fn 资源清理失败：" + "；".join(errors))


class FnBridge:
    """默认关闭；同步状态、权限重试和回调均运行在唯一设备线程。"""
    def __init__(self, demo=False, backend=None):
        self.demo = demo
        self.backend = backend
        self.connected = False
        self.online = None
        self._opened = False
        self._fault = None
        self._next_retry = 0
        self.state = {"enabled": False, "active": False, "pressed": False,
                      "inputPermission": None, "accessibilityPermission": None,
                      "error": None, "events": 0}

    def snapshot(self):
        return dict(self.state)

    def set_enabled(self, enabled):
        if type(enabled) is not bool:
            raise ValueError("Fn 桥接开关必须是布尔值。")
        self.state["enabled"] = enabled
        self._next_retry = 0
        if not enabled:
            self._stop()
            if not self.state["pressed"]:
                self._fault = None
                self.state["error"] = None
        else:
            self.pump()
        return self.snapshot()

    def synchronize(self, connected, online):
        ready_before = self.connected and self.online is True
        self.connected, self.online = connected, online
        if not connected or online is not True:
            self._stop()
        elif not ready_before:
            self._next_retry = 0
        self.pump()
        return self.snapshot()

    def _get_backend(self):
        if self.backend is None:
            self.backend = MacFnBackend()
        return self.backend

    def request_permissions(self):
        if not self.demo:
            try:
                backend = self._get_backend()
                backend.request_permissions()
                self._update_permissions()
                self._next_retry = 0
                self.pump()
            except Exception as exc:
                self.state["error"] = f"Fn 权限请求失败：{exc}"
        return self.snapshot()

    def _update_permissions(self):
        listen, post = self._get_backend().permissions()
        self.state.update(inputPermission=listen, accessibilityPermission=post)
        return listen is True and post is True

    def pump(self):
        if self._opened and getattr(self.backend, "callback_error", None):
            self._fault = self.backend.callback_error
            self.backend.callback_error = None
        if self._fault:
            message, self._fault = self._fault, None
            self._stop()
            self.state["error"] = message
            self._next_retry = time.monotonic() + 2
        if not self.state["enabled"] or not self.connected or self.online is not True:
            self._stop()
            return
        if self.state["pressed"] and not self.state["active"]:
            self._stop()
            if self.state["pressed"]:
                return
        if self.demo:
            # 演示状态不表示真实权限或真实注入，只展示开关和配置。
            self.state["active"] = False
            return
        if time.monotonic() < self._next_retry:
            return
        self._next_retry = time.monotonic() + 2
        try:
            if not self._update_permissions():
                self._stop()
                self.state["error"] = "Mac Fn 需要当前终端的输入监控和辅助功能权限；授权后重启终端。"
                return
            if not self._opened:
                self._get_backend().open(self._on_report, self._on_lost)
                self._opened = True
            self.state.update(active=True, error=None)
        except Exception as exc:
            self._stop()
            self.state["error"] = f"Mac Fn 桥接不可用：{exc}"

    def _on_report(self, report_id, data):
        try:
            if not self.state["active"]:
                return
            pressed = decode_fn_report(report_id, data)
            if pressed is None or pressed == self.state["pressed"]:
                return
            if pressed:
                # 先记录可能已提交的按下，出现异常也必须尝试释放。
                self.state["pressed"] = True
                self.backend.post_fn(True)
                self.state["events"] += 1
            else:
                self.release()
        except Exception as exc:
            self._on_lost(f"Fn 报文处理失败：{exc}")

    def _on_lost(self, message):
        self.state.update(active=False, error=message)
        self._fault = message
        self.release()

    def release(self):
        if self.state["pressed"]:
            try:
                self.backend.post_fn(False)
                self.state["pressed"] = False
                self.state["events"] += 1
            except Exception as exc:
                self.state["error"] = f"Fn 松开事件发送失败：{exc}"
                self.state["active"] = False
                self._fault = self.state["error"]
        return self.snapshot()

    def _stop(self):
        self.state["active"] = False
        self.release()
        # 松开发送失败时保留事件源，下次 pump 重试，不能假报已经松开。
        if self.state["pressed"]:
            return
        if self._opened:
            try:
                self.backend.close()
            except Exception as exc:
                self.state["error"] = f"Fn 输入接口关闭失败：{exc}"
            self._opened = False

    def close(self):
        self.connected = False
        self.online = None
        # 退出后不再有 pump；为瞬时事件分配/发送失败提供有界的最后重试。
        for _ in range(3):
            self._stop()
            if not self.state["pressed"]:
                break
        return self.snapshot()
