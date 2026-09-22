#!/usr/bin/env python3
"""比较空闲、Hooks 查询与官方心跳；只打开厂商接口，不写配置或记录唯一标识。"""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vibekey as v

STATUS = bytes.fromhex("06 03 0a 01")
STUDIO_HEARTBEAT = bytes.fromhex("06 01 23 00 01")


class Capture:
    def __init__(self):
        self.status = []
        self.hooks = 0
        self.notifications = 0
        self.keyconfigs = {}
        self.errors = []

    def on_report(self, context, result, sender, report_type, report_id, report, length):
        # ctypes 回调必须自行收集异常，不能静默丢失测量结果。
        try:
            if result:
                self.errors.append(f"report error 0x{result & 0xffffffff:08x}")
                return
            raw = bytes(report[:length])
            if len(raw) == 64 and raw[0] == v.VIBE_REPORT_ID:
                raw = raw[1:]
            if report_id != v.VIBE_REPORT_ID or len(raw) < 8:
                return
            frame = v.tea_decrypt(raw)
            command = frame[0] & 0x1f
            if command == 6 and frame[1:4] == bytes.fromhex("03 0a 11"):
                self.status.append({"status": frame[4], "plaintext_prefix": frame[:8].hex(" ")})
            elif command in (1, 6) and frame[1:4] == bytes.fromhex("0b 89 11"):
                self.hooks += 1
            elif command == 0x0b:
                self.notifications += 1
            elif command == 1 and frame[1:4] == bytes.fromhex("06 50 11"):
                size = 7 + 2 * frame[6]
                if size <= 56 and frame[4] < 6:
                    self.keyconfigs[frame[4]] = frame[4:size].hex(" ")
        except Exception as exc:
            self.errors.append(type(exc).__name__ + ": " + str(exc))


def open_vendor(capture):
    matching = v.iok.IOServiceMatching(b"IOHIDDevice")
    if not matching:
        raise RuntimeError("无法创建设备匹配条件")
    v.cf.CFDictionarySetValue(matching, v.cfstr("VendorID"), v.cfnum(v.VIBE_VID))
    v.cf.CFDictionarySetValue(matching, v.cfstr("ProductID"), v.cfnum(v.VIBE_PID))
    v.cf.CFDictionarySetValue(matching, v.cfstr("PrimaryUsagePage"), v.cfnum(v.VENDOR_USAGE_PAGE))
    iterator = ctypes.c_uint32()
    rc = v.iok.IOServiceGetMatchingServices(0, matching, ctypes.byref(iterator))
    if rc:
        raise RuntimeError(f"枚举失败 0x{rc & 0xffffffff:08x}")
    handles = []
    try:
        service = v.iok.IOIteratorNext(iterator)
        while service:
            try:
                handle = v._try_open(capture, service, v.cf.CFRunLoopGetCurrent())
                if isinstance(handle, dict):
                    handles.append(handle)
                else:
                    raise RuntimeError(f"厂商接口打开失败 0x{handle & 0xffffffff:08x}")
            finally:
                v.iok.IOObjectRelease(service)
            service = v.iok.IOIteratorNext(iterator)
    except Exception:
        v.close_all(handles)
        raise
    finally:
        v.iok.IOObjectRelease(iterator)
    if len(handles) != 1:
        v.close_all(handles)
        raise RuntimeError(f"需要恰好一个厂商接口，实际 {len(handles)}")
    return handles


def pump(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        v.cf.CFRunLoopRunInMode(v.kCFRunLoopDefaultMode, min(0.1, deadline - time.monotonic()), False)


def query_status(handles, capture):
    start = len(capture.status)
    if not v.send_frame(handles, STATUS):
        raise RuntimeError("在线状态查询发送失败")
    pump(1)
    return capture.status[start:]


def emit(event, **data):
    print(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "event": event, **data}, ensure_ascii=False), flush=True)


def read_keys(handles, capture):
    capture.keyconfigs.clear()
    for index in range(6):
        if not v.send_frame(handles, bytes.fromhex("01 06 50 01") + bytes([index])):
            raise RuntimeError("按键配置查询发送失败")
        pump(0.4)
    pump(1)
    if len(capture.keyconfigs) != 6:
        raise RuntimeError("未收齐六个控件配置，无法确认配置一致")
    return dict(capture.keyconfigs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=60, help="每个比较阶段的秒数，默认 60")
    parser.add_argument("--mode", choices=("hooks", "studio"), default="hooks", help="Hooks 查询或官方单向心跳")
    parser.add_argument("--interval", type=float, help="间隔秒数；Hooks 默认 2，Studio 默认 1")
    parser.add_argument("--skip-idle", action="store_true", help="跳过零请求空闲阶段，只测指定模式")
    parser.add_argument("--check-keys", action="store_true", help="测试前后只读比较六个控件配置；查询可能影响初始唤醒状态")
    args = parser.parse_args()
    if args.interval is None:
        args.interval = 1 if args.mode == "studio" else 2
    if (not math.isfinite(args.seconds) or not math.isfinite(args.interval)
            or not 1 <= args.seconds <= 86400 or not 0.5 <= args.interval <= 60):
        parser.error("时长必须为 1–86400 秒，间隔必须为 0.5–60 秒，且均为有限数值")
    capture = Capture()
    handles = []
    try:
        handles = open_vendor(capture)
        baseline = query_status(handles, capture)
        emit("baseline", replies=baseline)
        if not baseline or baseline[-1]["status"] != 1:
            emit("inconclusive", reason="起始状态非已确认在线，无法执行保持唤醒对照", errors=capture.errors)
            return 2
        keys_before = read_keys(handles, capture) if args.check_keys else None
        if keys_before is not None:
            emit("keys_before", controls=keys_before, caveat="只读查询可能影响初始唤醒状态")
        phases = ([] if args.skip_idle else ["idle"]) + [args.mode]
        for mode in phases:
            start = time.monotonic()
            next_send = start
            count = 0
            hooks_before = capture.hooks
            notifications_before = capture.notifications
            emit("phase_start", mode=mode, seconds=args.seconds, interval=args.interval if mode != "idle" else None)
            while time.monotonic() - start < args.seconds:
                if mode != "idle" and time.monotonic() >= next_send:
                    frame = STUDIO_HEARTBEAT if mode == "studio" else v.KEEPALIVE
                    if not v.send_frame(handles, frame):
                        raise RuntimeError("测试帧发送失败")
                    count += 1
                    next_send = time.monotonic() + args.interval
                pump(min(0.1, max(0, args.seconds - (time.monotonic() - start))))
            elapsed = time.monotonic() - start
            after = query_status(handles, capture)
            emit("phase_end", mode=mode, seconds=round(elapsed, 3), sent=count,
                 hooks_replies=capture.hooks - hooks_before,
                 notifications=capture.notifications - notifications_before, replies=after,
                 errors=capture.errors)
            if not after or after[-1]["status"] != 1:
                emit("inconclusive", reason="阶段结束未确认在线；继续轮询不能构成相同起点的唤醒对照")
                return 2
        if keys_before is not None:
            keys_after = read_keys(handles, capture)
            emit("keys_after", controls=keys_after, unchanged=keys_before == keys_after)
            if keys_before != keys_after:
                raise RuntimeError("前后配置不一致；本工具没有发送任何配置写入")
        emit("complete", conclusion="所测窗口结束均在线；不能据此证明或否定更长时间的休眠与保活因果关系",
             errors=capture.errors)
        return 1 if capture.errors else 0
    except Exception as exc:
        emit("error", error=str(exc))
        return 1
    finally:
        v.close_all(handles)


if __name__ == "__main__":
    raise SystemExit(main())
