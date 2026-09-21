#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vibekey — 在终端里监控 / 操作 Ulanzi Vibe Key（AU05）。

亮点
----
* 纯 Python 3 标准库，**零第三方依赖**，不依赖 Ulanzi Studio 的任何文件。
* 直接走 macOS IOKit HID —— **退出甚至卸载 Studio 后照样能用**。
* **内置 TEA 解密**，能读懂厂商通道（Report ID 0x55）的私有报文。

协议速查（逆向自 kwdm.dylib）
---------------------------
* 报文 = [0x55][63 字节密文]
* 加密 = **TEA / ECB / 8 字节分组 / 32 轮**，密钥 16 字节（见 KEY）
* 64 字节明文分组，但 HID 报文含 report ID 只有 64 字节 ⇒ 只发出前 63 字节
  ⇒ 解密时只能解 **7 个分组（56 字节）**，末 7 字节是固定填充
* 帧头 `cmd = frame[0] & 0x1F`
* 命令字：0x01 设备消息 / 0x06 USB 消息 / 0x0B 通知 / 0x1E dongle 升级 / 0x1F 设备升级 …

用法
----
    python3 vibekey.py                # 监控（Ctrl-C 退出）
    python3 vibekey.py --learn        # 学习模式：多打印原始字节
    python3 vibekey.py --list         # 列出设备接口
    python3 vibekey.py -t 30          # 只跑 30 秒
    python3 vibekey.py --no-color

⚠️ Vibe Key 的按键是**设备固件直接发标准 USB 键盘报文**的，
   运行本程序时按键会真的注入当前焦点窗口，建议保持本终端在前台。
"""

from __future__ import annotations

import argparse
import atexit
import ctypes
import os
import re
import ctypes.util
import struct
import sys
import time
from datetime import datetime

# ==========================================================================
# 1. TEA 解密（逆向自 kwdm.dylib：_encode/_decode @0x27790/0x277f4）
# ==========================================================================

M32 = 0xFFFFFFFF
DELTA = 0x9E3779B9
KEY = bytes.fromhex("cabaa5ca6d8a2abcba9e5acaca8bb89b")
_K = list(struct.unpack("<4I", KEY))


def _dec_block(v0, v1, k=_K, rounds=32):
    s = (DELTA * rounds) & M32
    for _ in range(rounds):
        v1 = (v1 - (((((v0 << 4) & M32) + k[2]) ^ ((v0 + s) & M32) ^ (((v0 >> 5) + k[3]) & M32)))) & M32
        v0 = (v0 - (((((v1 << 4) & M32) + k[0]) ^ ((v1 + s) & M32) ^ (((v1 >> 5) + k[1]) & M32)))) & M32
        s = (s - DELTA) & M32
    return v0, v1


def tea_decrypt(data: bytes) -> bytes:
    """ECB 解密整个缓冲区；只处理 floor(len/8) 个完整分组，尾部原样保留。"""
    b = bytearray(data)
    for i in range(len(b) >> 3):
        struct.pack_into("<2I", b, i * 8, *_dec_block(*struct.unpack_from("<2I", b, i * 8)))
    return bytes(b)


def _enc_block(v0, v1, k=_K, rounds=32):
    s = 0
    for _ in range(rounds):
        s = (s + DELTA) & M32
        v0 = (v0 + (((((v1 << 4) & M32) + k[0]) ^ ((v1 + s) & M32) ^ (((v1 >> 5) + k[1]) & M32)))) & M32
        v1 = (v1 + (((((v0 << 4) & M32) + k[2]) ^ ((v0 + s) & M32) ^ (((v0 >> 5) + k[3]) & M32)))) & M32
    return v0, v1


def tea_encrypt(data: bytes) -> bytes:
    b = bytearray(data)
    for i in range(len(b) >> 3):
        struct.pack_into("<2I", b, i * 8, *_enc_block(*struct.unpack_from("<2I", b, i * 8)))
    return bytes(b)


# 自检：零分组的密文应当等于那个"神秘固定尾串"
assert tea_decrypt(bytes.fromhex("3890c499a360aaad")) == bytes(8), "TEA 自检失败"

# ==========================================================================
# 2. 协议表
# ==========================================================================

CMD_NAMES = {
    0x01: "设备消息", 0x06: "USB消息", 0x0B: "通知", 0x0C: "BLE短音频",
    0x0D: "BLE长音频", 0x0E: "USB音频", 0x15: "上传图片",
    0x1E: "dongle升级", 0x1F: "设备升级",
}

# 通知（cmd 0x0B）子类型
NOTICE_NAMES = {
    0x0B: "通知B", 0x0D: "通知D", 0x7B: "心跳",
}

# 完整命令表：(frame[1] 的低 4 位 = grp, frame[2] = opcode) -> 名称
# 逆向自 kwdm.dylib 全部 +[MessageHelper ...] 构造函数，共 ~85 条
OP_TABLE = {
    (0x02, 0x03): "dongle 版本",      (0x02, 0x05): "dongle 鉴权",
    (0x02, 0x0B): "dongle flashId",   (0x02, 0x81): "dongle SN",
    (0x03, 0x0A): "设备在线状态",      (0x08, 0x02): "充电状态",
    (0x01, 0x02): "电量",             (0x01, 0x0A): "设备 UUID",
    (0x01, 0x0B): "设备 SN",          (0x01, 0x0C): "设备重启",
    (0x01, 0x0D): "待机状态",          (0x01, 0x2A): "麦克风开关",
    (0x01, 0x2C): "待机时间",          (0x01, 0x34): "旋钮开关",
    (0x01, 0x41): "硬件版本",          (0x01, 0x42): "休眠时间",
    (0x01, 0x43): "DialMini 灯效",    (0x01, 0x90): "麦克风降噪等级",
    (0x01, 0xFA): "MAC 地址",
    (0x04, 0x04): "固件版本",          (0x04, 0x0B): "设备 flashId",
    (0x06, 0x0D): "回报率",            (0x06, 0x10): "按键功能",
    (0x06, 0x11): "LED 效果",          (0x06, 0x12): "DPI",
    (0x06, 0x13): "全部 DPI",          (0x06, 0x20): "亮度",
    (0x06, 0x21): "AI 按钮功能",       (0x06, 0x22): "息屏时间",
    (0x06, 0x24): "麦克风UI闪烁",      (0x06, 0x26): "dongle 重启",
    (0x06, 0x31): "全部按键功能",      (0x06, 0x37): "麦克风支持",
    (0x06, 0x38): "按键功能支持",      (0x06, 0x39): "LED效果支持",
    (0x06, 0x40): "马达强度",          (0x06, 0x42): "旋钮等级",
    (0x06, 0x50): "按键快捷功能",      (0x06, 0x51): "音频按键系统模式",
    (0x06, 0x65): "LCD GIF",
    (0x07, 0x09): "光标 DPI",          (0x07, 0x1B): "聚光灯",
    (0x07, 0x30): "光标功能支持",      (0x07, 0x31): "光标功能状态",
    (0x07, 0x32): "倒计时",            (0x07, 0x33): "长按功能/马达",
    (0x0B, 0x88): "指示灯参数",        (0x0B, 0x89): "Hooks 模式",
}

# ==========================================================================
# 3. HID 报文字典
# ==========================================================================

KEYS = {
    0x00: "(无)", 0x01: "0x01 (无效码/未配置)",
    0x04: "A", 0x05: "B", 0x06: "C", 0x07: "D", 0x08: "E", 0x09: "F", 0x0A: "G",
    0x0B: "H", 0x0C: "I", 0x0D: "J", 0x0E: "K", 0x0F: "L", 0x10: "M", 0x11: "N",
    0x12: "O", 0x13: "P", 0x14: "Q", 0x15: "R", 0x16: "S", 0x17: "T", 0x18: "U",
    0x19: "V", 0x1A: "W", 0x1B: "X", 0x1C: "Y", 0x1D: "Z",
    0x1E: "数字1", 0x1F: "数字2", 0x20: "数字3", 0x21: "数字4", 0x22: "数字5",
    0x23: "数字6", 0x24: "数字7", 0x25: "数字8", 0x26: "数字9", 0x27: "数字0",
    0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "空格",
    0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\", 0x32: "#", 0x33: ";",
    0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/", 0x39: "CapsLock",
    0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4", 0x3E: "F5", 0x3F: "F6",
    0x40: "F7", 0x41: "F8", 0x42: "F9", 0x43: "F10", 0x44: "F11", 0x45: "F12",
    0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause",
    0x49: "Insert", 0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End",
    0x4E: "PageDown", 0x4F: "→右方向键", 0x50: "←左方向键", 0x51: "↓下方向键",
    0x52: "↑上方向键", 0x53: "NumLock", 0x54: "小键盘/", 0x55: "小键盘*",
    0x56: "小键盘-", 0x57: "小键盘+", 0x58: "小键盘Enter",
    0x59: "小键盘1", 0x5A: "小键盘2", 0x5B: "小键盘3", 0x5C: "小键盘4",
    0x5D: "小键盘5", 0x5E: "小键盘6", 0x5F: "小键盘7", 0x60: "小键盘8",
    0x61: "小键盘9", 0x62: "小键盘0", 0x63: "小键盘.",
    0x65: "Application",
    0x68: "F13", 0x69: "F14", 0x6A: "F15", 0x6B: "F16", 0x6C: "F17",
    0x6D: "F18", 0x6E: "F19", 0x6F: "F20", 0x70: "F21", 0x71: "F22",
    0x72: "F23", 0x73: "F24",
    0xE0: "左Ctrl", 0xE1: "左Shift", 0xE2: "左Alt", 0xE3: "左Cmd",
    0xE4: "右Ctrl", 0xE5: "右Shift", 0xE6: "右Alt", 0xE7: "右Cmd",
}
MODS = [(0x01, "Ctrl"), (0x02, "Shift"), (0x04, "Alt"), (0x08, "Cmd"),
        (0x10, "RCtrl"), (0x20, "RShift"), (0x40, "RAlt"), (0x80, "RCmd")]
CONSUMER = {
    0x0E9: "音量+", 0x0EA: "音量-", 0x0E2: "静音", 0x0B5: "下一曲",
    0x0B6: "上一曲", 0x0CD: "播放/暂停", 0x0B3: "快进", 0x0B4: "快退",
    0x0B7: "停止", 0x0E8: "音乐播放器", 0x06F: "亮度+", 0x070: "亮度-",
    0x194: "听写", 0x19A: "切换应用", 0x221: "搜索", 0x222: "主页",
    0x223: "返回", 0x224: "前进", 0x226: "刷新", 0x279: "书签",
    0x1AE: "语音助手", 0x0CF: "语音命令",
}

# --------------------------------------------------------------------------
# 实测确认的 Vibe Key（AU05 / 固件 4.4.2）控件映射
#   顺序验证：按下旋钮 → 键1 → 键2 → 键3 → 右拧×3 → 左拧×3 → 长按旋钮
# --------------------------------------------------------------------------
VIBE_CONTROLS = {
    0x46: ("旋钮 按下",   "PrintScreen"),
    0x01: ("键 1 (上)",   "ErrorRollOver —— 无效码"),
    0x28: ("键 2 (中)",   "Enter"),
    0x29: ("键 3 (下)",   "Esc"),
    0x4F: ("旋钮 → 右拧", "RightArrow"),
    0x2A: ("旋钮 ← 左拧", "Backspace"),
}
# 转动是瞬时脉冲，按键是人手按压；用时长区分
INSTANT_MS = 25

# ==========================================================================
# 4. IOKit 绑定
# ==========================================================================

VIBE_VID, VIBE_PID = 0xFFF1, 0x00DD
VENDOR_USAGE_PAGE = 0xFFFC

cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation") or
                 "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
iok = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")

kCFAllocatorDefault = ctypes.c_void_p.in_dll(cf, "kCFAllocatorDefault")
kCFNumberIntType = 9
kCFStringEncodingUTF8 = 0x08000100
kCFRunLoopDefaultMode = ctypes.c_void_p.in_dll(cf, "kCFRunLoopDefaultMode")

cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFNumberCreate.restype = ctypes.c_void_p
cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
cf.CFDictionaryCreate.restype = ctypes.c_void_p
cf.CFDictionaryCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                  ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
cf.CFStringGetCString.restype = ctypes.c_bool
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
cf.CFNumberGetValue.restype = ctypes.c_bool
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
cf.CFRunLoopGetCurrent.restype = ctypes.c_void_p
cf.CFRunLoopRunInMode.restype = ctypes.c_int
cf.CFRunLoopRunInMode.argtypes = [ctypes.c_void_p, ctypes.c_double, ctypes.c_bool]

iok.IOHIDManagerCreate.restype = ctypes.c_void_p
iok.IOHIDManagerCreate.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iok.IOHIDManagerSetDeviceMatching.restype = None
iok.IOHIDManagerSetDeviceMatching.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
iok.IOHIDManagerRegisterDeviceMatchingCallback.restype = None
iok.IOHIDManagerRegisterDeviceMatchingCallback.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
iok.IOHIDManagerRegisterInputReportCallback.restype = None
iok.IOHIDManagerRegisterInputReportCallback.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
iok.IOHIDManagerScheduleWithRunLoop.restype = None
iok.IOHIDManagerScheduleWithRunLoop.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
iok.IOHIDManagerOpen.restype = ctypes.c_int
iok.IOHIDManagerOpen.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iok.IOHIDManagerClose.restype = ctypes.c_int
iok.IOHIDManagerClose.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iok.IOHIDDeviceGetProperty.restype = ctypes.c_void_p
iok.IOHIDDeviceGetProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

# --- 逐个设备打开所需的绑定（比 IOHIDManagerOpen 稳，某个接口被占用不影响其它）---
iok.IOServiceMatching.restype = ctypes.c_void_p
iok.IOServiceMatching.argtypes = [ctypes.c_char_p]
iok.IOServiceGetMatchingServices.restype = ctypes.c_int
iok.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint32, ctypes.c_void_p,
                                             ctypes.POINTER(ctypes.c_uint32)]
iok.IOIteratorNext.restype = ctypes.c_uint32
iok.IOIteratorNext.argtypes = [ctypes.c_uint32]
iok.IOObjectRelease.restype = ctypes.c_int
iok.IOObjectRelease.argtypes = [ctypes.c_uint32]
iok.IOHIDDeviceCreate.restype = ctypes.c_void_p
iok.IOHIDDeviceCreate.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iok.IOHIDDeviceOpen.restype = ctypes.c_int
iok.IOHIDDeviceOpen.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iok.IOHIDDeviceClose.restype = ctypes.c_int
iok.IOHIDDeviceClose.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iok.IOHIDDeviceRegisterInputReportCallback.restype = None
iok.IOHIDDeviceRegisterInputReportCallback.argtypes = [
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_long,
    ctypes.c_void_p, ctypes.c_void_p]
iok.IOHIDDeviceScheduleWithRunLoop.restype = None
iok.IOHIDDeviceScheduleWithRunLoop.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
cf.CFDictionarySetValue.restype = None
cf.CFDictionarySetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]

iok.IOHIDDeviceSetReport.restype = ctypes.c_int
iok.IOHIDDeviceSetReport.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                     ctypes.POINTER(ctypes.c_uint8), ctypes.c_long]

cf.CFDataGetLength.restype = ctypes.c_long
cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
cf.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_uint8)
cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]

kIOHIDReportTypeOutput = 1
kIOMainPortDefault = 0
MAX_REPORT = 1024
VIBE_REPORT_ID = 0x55

ReportCB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p,
                            ctypes.c_uint32, ctypes.c_uint32,
                            ctypes.POINTER(ctypes.c_uint8), ctypes.c_long)
DeviceCB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int,
                            ctypes.c_void_p, ctypes.c_void_p)

_cache: dict[str, ctypes.c_void_p] = {}


def cfstr(s):
    if s not in _cache:
        _cache[s] = cf.CFStringCreateWithCString(
            kCFAllocatorDefault, s.encode(), kCFStringEncodingUTF8)
    return _cache[s]


def cfnum(v):
    b = ctypes.c_int(v)
    return cf.CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, ctypes.byref(b))


def prop_str(dev, key):
    v = iok.IOHIDDeviceGetProperty(dev, cfstr(key))
    if not v:
        return None
    buf = ctypes.create_string_buffer(512)
    return buf.value.decode("utf-8", "replace") if cf.CFStringGetCString(v, buf, 512, kCFStringEncodingUTF8) else None


def prop_int(dev, key):
    v = iok.IOHIDDeviceGetProperty(dev, cfstr(key))
    if not v:
        return None
    o = ctypes.c_int(0)
    return o.value if cf.CFNumberGetValue(v, kCFNumberIntType, ctypes.byref(o)) else None


# ==========================================================================
# 5. 颜色
# ==========================================================================

class C:
    on = sys.stdout.isatty()
    @staticmethod
    def w(c, s): return f"\033[{c}m{s}\033[0m" if C.on else s


def dim(s):     return C.w("2", s)
def bold(s):    return C.w("1", s)
def green(s):   return C.w("32", s)
def yellow(s):  return C.w("33", s)
def cyan(s):    return C.w("36", s)
def red(s):     return C.w("31", s)
def magenta(s): return C.w("35", s)
def blue(s):    return C.w("34", s)


def now() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


# ==========================================================================
# 6. 主监控器
# ==========================================================================

class Monitor:
    def __init__(self, raw=False, learn=False):
        self.raw, self.learn = raw, learn
        self.quiet = False
        self.keycfg = []
        self.hide = False
        self.devs: dict[int, dict] = {}
        self.held: dict[tuple, float] = {}
        self.stats: dict[str, int] = {}
        self.t0 = time.time()
        self.heartbeats = 0
        # 设备在线状态：None=未知  True=在线  False=离线
        # 用来区分"工具/协议有问题"和"Vibe Key 本体没开机"。
        self.device_online = None
        self.device_replied = False

    # ---------------- 设备 ----------------

    def on_device(self, ctx, result, sender, device):
        if prop_int(device, "VendorID") != VIBE_VID or prop_int(device, "ProductID") != VIBE_PID:
            return
        info = {
            "product": prop_str(device, "Product") or "?",
            "up": prop_int(device, "PrimaryUsagePage") or 0,
            "u": prop_int(device, "PrimaryUsage") or 0,
            "serial": prop_str(device, "SerialNumber") or "?",
        }
        self.devs[sender] = info
        kind = "厂商通道" if info["up"] == VENDOR_USAGE_PAGE else "键盘/多媒体"
        usg = "usagePage=0x%04X usage=0x%04X" % (info["up"], info["u"])
        print(f"{dim(now())} {green('● 已连接')}  {bold(info['product'])}  "
              f"{cyan(kind)}  {dim(usg)}")
        print(f"{'':>12}  {dim('序列号 ' + info['serial'])}")

    # ---------------- 报文 ----------------

    def on_report(self, ctx, result, sender, rtype, rid, report, length):
        if self.quiet:
            return
        data = bytes(report[:length])
        if data and data[0] == rid and len(data) in (9, 64):
            data = data[1:]
        if rid == 0x03:
            self._keyboard(data)
        elif rid == 0x01:
            self._consumer(data)
        elif rid == 0x02:
            self._mouse(data)
        else:
            self._vendor(rid, data)

    def _line(self, tag, tagcol, body):
        print(f"{dim(now())} {tagcol(f'{tag:<6}')} {body}", flush=True)

    def _bump(self, k):
        self.stats[k] = self.stats.get(k, 0) + 1

    # ---------------- 键盘 ----------------

    def _keyboard(self, p):
        """键盘报文 [修饰位, 保留, 键码×6]。

        实测规律：旋钮转动是瞬时脉冲（约 5ms），真正的按键是人手按压
        （60~250ms）。据此自动区分两类控件。
        """
        if len(p) < 8:
            return
        mods = [n for bit, n in MODS if p[0] & bit]
        codes = [c for c in p[2:8] if c]
        pref = ("+".join(mods) + "+") if mods else ""
        t_now = time.time()

        for c in codes:                                    # 新的按下
            if (0x03, c) not in self.held:
                self.held[(0x03, c)] = t_now

        for (fam, c), t in list(self.held.items()):        # 抬起
            if fam == 0x03 and c not in codes:
                del self.held[(fam, c)]
                ms = (t_now - t) * 1000
                ent = VIBE_CONTROLS.get(c)
                if ent:
                    label, raw = ent
                else:
                    label, raw = f"未知 0x{c:02X}", KEYS.get(c, "?")
                if pref:
                    label = pref + label
                word, col, icon = (("旋钮", cyan, "⟳") if ms < INSTANT_MS
                                   else ("按键", green, "⌨"))
                self._bump(f"{word} {label}")
                self._line(word, col,
                           f"{icon} {bold(label):<14} "
                           f"{dim(f'{raw:<24} {ms:5.0f} ms')}")

    # ---------------- 多媒体 / 鼠标 ----------------

    def _consumer(self, p):
        if len(p) < 2:
            return
        code = p[0] | (p[1] << 8)
        if code == 0:
            for (fam, c), t in list(self.held.items()):
                if fam == 0x01:
                    del self.held[(fam, c)]
                    self._line("抬起", dim, f"{CONSUMER.get(c, f'usage 0x{c:03X}'):<24} "
                                            f"{dim(f'按住 {(time.time()-t)*1000:.0f} ms')}")
            return
        if (0x01, code) in self.held:
            return
        self.held[(0x01, code)] = time.time()
        name = CONSUMER.get(code, f"usage 0x{code:03X}")
        self._bump(f"多媒体 {name}")
        self._line("多媒体", blue, f"{bold(name):<24} {dim(f'usage=0x{code:03X}')}")

    def _mouse(self, p):
        if len(p) < 4:
            return
        s = lambda v: v - 256 if v > 127 else v
        dx, dy, wh = s(p[1]), s(p[2]), s(p[3])
        if p[0] or dx or dy or wh:
            self._bump("鼠标")
            self._line("鼠标", blue, f"btn=0x{p[0]:02X}  dx={dx} dy={dy} wheel={wh}")

    # ---------------- 厂商通道 ----------------

    def _vendor(self, rid, ct):
        if rid != 0x55:
            self._line("原始", magenta, f"rid=0x{rid:02X} len={len(ct)}  {ct.hex(' ')}")
            return

        pt = tea_decrypt(ct)
        cmd = pt[0] & 0x1F
        flags = pt[0] >> 5

        # 按键配置回复（op 0x50），供 --keys / --set-key 使用
        if len(pt) > 8 and pt[2] == 0x50 and (pt[0] & 0x80):
            self.keycfg.append(bytes(pt))
        if self.hide:
            return

        # 记录"设备级"应答，用来区分工具/协议有问题 还是 本体没开机。
        # cmd=0x01 由 Vibe Key 本体处理（走无线链路），cmd=0x06 由 dongle 处理。
        # 保活(op 0x89)不算数 —— 那条由 dongle 代答，本体关机时照样会回。
        _reply = bool(pt[0] & 0x80) or (len(pt) > 3 and bool(pt[3] & 0x10))
        if _reply and cmd in (0x01, 0x06) and len(pt) > 3 and pt[2] != 0x89:
            if cmd == 0x01:
                self.device_replied = True
            if (pt[1] & 0x0F) == 0x03 and pt[2] == 0x0A:      # 设备在线状态
                self.device_online = bool(pt[4] & 0x01)

        # 保活查询（读 Hooks 模式）的回复属于噪声，默认不打印
        if (not self.learn and cmd in (0x01, 0x06) and len(pt) > 3
                and pt[2] == 0x89 and (pt[3] & 0x0F) == 0x01):
            self.stats["（保活往返）"] = self.stats.get("（保活往返）", 0) + 1
            return

        desc = self._describe(cmd, pt)

        if cmd == 0x0B:
            self.heartbeats += 1
            if not self.learn and self.heartbeats % 10 != 1:
                return                       # 心跳太吵，每 10 条只显示 1 条
        self._bump(f"厂商 {desc}")

        line = (f"{magenta('厂商')} {bold(desc):<30} "
                f"{dim(f'cmd=0x{cmd:02X} flags={flags} len={len(ct)}')}")
        print(f"{dim(now())} {line}")
        if self.learn:
            print(f"{'':>13}  {dim('CT ' + ct.hex(' '))}")
            print(f"{'':>13}  {dim('PT ' + pt.hex(' '))}")

    @staticmethod
    def _describe(cmd, pt):
        """把明文翻译成人话。"""
        is_reply = bool(pt[0] & 0x80) or (len(pt) > 3 and bool(pt[3] & 0x10))
        mark = "← " if is_reply else "→ "
        name = CMD_NAMES.get(cmd, f"未知cmd0x{cmd:02X}")

        if cmd == 0x0B:                                    # 通知
            sub = pt[1]
            sn = NOTICE_NAMES.get(sub, f"子类型0x{sub:02X}")
            if sub == 0x7B:                                # 心跳
                return f"{mark}{name}/{sn} ctr={int.from_bytes(pt[2:8], 'little')}"
            return f"{mark}{name}/{sn} [{pt[2:10].hex(' ')}]"

        if cmd in (0x01, 0x06):                            # 配置读写
            b1 = pt[1]
            grp, sub = b1 & 0x0F, b1 >> 4
            op, acc = pt[2], pt[3] & 0x0F
            opname = OP_TABLE.get((grp, op), f"未知命令 op0x{op:02X}")
            verb = {0x01: "读", 0x04: "写"}.get(acc, f"acc0x{pt[3]:02X}")
            data = pt[4:24]

            # 已知回复的贴心解码
            if is_reply and op == 0x90:                    # 麦克风降噪
                return (f"{mark}{verb} {opname}  低={data[0]} 高={data[1]}  "
                        f"低={data[2]} 高={data[3]}  (双麦)")
            if is_reply and op == 0x88:                    # 指示灯参数
                return (f"{mark}{verb} {opname}  [{data[:16].hex(' ')}]")
            if is_reply:
                nz = data.rstrip(b"\x00")
                body = nz.hex(" ") if nz else "全 0（未配置）"
                return f"{mark}{verb} {opname}  {body}"

            return f"{mark}{verb} {opname}  grp={grp} sub={sub} val={pt[4]}"

        return f"{mark}{name}"

    # ---------------- 汇总 ----------------

    def summary(self):
        print()
        print(bold("─" * 64))
        print(bold("  本次会话统计"))
        print(bold("─" * 64))
        if not self.stats:
            print(yellow("  （没有捕获到任何事件）"))
        else:
            for k, v in sorted(self.stats.items(), key=lambda kv: -kv[1]):
                print(f"  {k:<34} {v}")
        print(f"  {'时长':<34} {time.time()-self.t0:.1f}s")
        print()



# --------------------------------------------------------------------------
# 输出分流：终端 + 日志文件（日志里剥掉 ANSI 颜色码）
# --------------------------------------------------------------------------

_ANSI = re.compile(r"\033\[[0-9;]*m")


class _Tee:
    def __init__(self, real, fh):
        self.real, self.fh = real, fh

    def write(self, s):
        self.real.write(s)
        if not self.fh.closed:
            self.fh.write(_ANSI.sub("", s))
        return len(s)

    def flush(self):
        try:
            self.real.flush()
            if not self.fh.closed:
                self.fh.flush()
        except ValueError:
            pass

    def isatty(self):
        return False


# ==========================================================================
# 7. 入口
# ==========================================================================

# IOKit 错误码
IOKIT_ERR = {
    0xE00002C5: "被独占 (kIOReturnExclusiveAccess)",
    0xE00002E2: "无权限 (kIOReturnNotPermitted)",
    0xE00002C7: "设备不存在",
    0xE00002BC: "参数错误",
}


def _kind_of(up):
    return "厂商通道" if up == VENDOR_USAGE_PAGE else "输入接口"


def _try_open(mon, svc, runloop):
    """尝试打开一个 IOHIDDevice。成功返回 handle dict，失败返回错误码。"""
    dev = iok.IOHIDDeviceCreate(kCFAllocatorDefault, svc)
    if not dev:
        return -1
    up = prop_int(dev, "PrimaryUsagePage") or 0
    rc = iok.IOHIDDeviceOpen(dev, 0)
    if rc != 0:
        return rc
    buf = (ctypes.c_uint8 * MAX_REPORT)()
    cb = ReportCB(mon.on_report)
    iok.IOHIDDeviceRegisterInputReportCallback(dev, buf, MAX_REPORT, cb, None)
    iok.IOHIDDeviceScheduleWithRunLoop(dev, runloop, kCFRunLoopDefaultMode)
    return {"dev": dev, "buf": buf, "cb": cb, "up": up,
            "u": prop_int(dev, "PrimaryUsage") or 0,
            "product": prop_str(dev, "Product") or "?"}


def build_manager(mon):
    """逐个打开 AU05 的每个 HID 接口。

    刻意**不用** IOHIDManagerOpen：它会一次性打开所有匹配设备，只要其中任何
    一个打不开（被独占、或无输入监控权限），整个调用就失败。逐个打开则互不
    影响。打不开的接口会被记下来，之后在运行期间持续重试。
    """
    matching = iok.IOServiceMatching(b"IOHIDDevice")
    if not matching:
        raise RuntimeError("IOServiceMatching 失败")
    cf.CFDictionarySetValue(matching, cfstr("VendorID"), cfnum(VIBE_VID))
    cf.CFDictionarySetValue(matching, cfstr("ProductID"), cfnum(VIBE_PID))

    it = ctypes.c_uint32(0)
    rc = iok.IOServiceGetMatchingServices(kIOMainPortDefault, matching, ctypes.byref(it))
    if rc != 0:
        raise RuntimeError(f"IOServiceGetMatchingServices 失败 (0x{rc & 0xFFFFFFFF:08X})")

    runloop = cf.CFRunLoopGetCurrent()
    handles, pending = [], []
    svc = iok.IOIteratorNext(it)
    while svc:
        h = _try_open(mon, svc, runloop)
        if isinstance(h, dict):
            handles.append(h)
            iok.IOObjectRelease(svc)
            print(f"{dim(now())} {green('● 已连接')} {bold(h['product'])}  "
                  f"{cyan(_kind_of(h['up']))}  "
                  f"{dim('usagePage=0x%04X usage=0x%04X' % (h['up'], h['u']))}")
            if mon.learn:
                print(f"{'':>13}  {dim('序列号 ' + (prop_str(h['dev'], 'SerialNumber') or '?'))}")
        else:
            pending.append({"svc": svc, "rc": h})
            up = prop_int(iok.IOHIDDeviceCreate(kCFAllocatorDefault, svc),
                          "PrimaryUsagePage") or 0
            print(f"{dim(now())} {red('✗ 打不开')} {bold('AU05')}  {cyan(_kind_of(up))}  "
                  f"{red(IOKIT_ERR.get(h & 0xFFFFFFFF, '0x%08X' % (h & 0xFFFFFFFF)))}")
        svc = iok.IOIteratorNext(it)
    iok.IOObjectRelease(it)

    if not handles and not pending:
        raise RuntimeError("没有找到 Vibe Key，请确认 dongle 已插好。")

    # 关键：输入接口没打开 = 按键收不到，必须显式警告
    if not any(h["up"] != VENDOR_USAGE_PAGE for h in handles):
        print()
        print(red("  ⚠ 输入接口没打开，按 Vibe Key 不会有任何输出！"))
        print(red("    请到 系统设置 → 隐私与安全性 → 输入监控，"))
        print(red("    把你运行本程序的终端（如 iTerm2）打开，然后重启终端。"))
        print(dim("    （程序会持续重试，权限开放后会自动接上）"))
        print()
    return handles, pending


def retry_pending(mon, handles, pending, runloop):
    """重试之前打不开的接口。返回剩余的 pending。"""
    still = []
    for item in pending:
        h = _try_open(mon, item["svc"], runloop)
        if isinstance(h, dict):
            handles.append(h)
            iok.IOObjectRelease(item["svc"])
            print(f"{dim(now())} {green('● 重试成功')} {bold(h['product'])}  "
                  f"{cyan(_kind_of(h['up']))}")
        else:
            item["rc"] = h
            still.append(item)
    return still


def close_all(handles):
    for h in handles:
        iok.IOHIDDeviceClose(h["dev"], 0)


def send_frame(handles, pt: bytes) -> bool:
    """把一条明文帧加密后发给设备的厂商通道。

    明文 64 字节 → TEA 加密 64 字节 → 只发出前 63 字节（报文含 report ID 共 64）。
    """
    vend = next((h for h in handles if h["up"] == VENDOR_USAGE_PAGE), None)
    if not vend:
        print(red("没有可用的厂商通道"))
        return False
    pt = (pt + bytes(64))[:64]
    ct = tea_encrypt(pt)
    wire = bytes([VIBE_REPORT_ID]) + ct[:63]
    arr = (ctypes.c_uint8 * len(wire)).from_buffer_copy(wire)
    rc = iok.IOHIDDeviceSetReport(vend["dev"], kIOHIDReportTypeOutput,
                                  VIBE_REPORT_ID, arr, len(wire))
    if rc != 0:
        print(red(f"发送失败 0x{rc & 0xFFFFFFFF:08X}"))
        return False
    return True


# 安全的"只读"查询命令： frame[0]=cmd | frame[1]={grp,sub} | frame[2]=opcode | frame[3]=0x01 读
KEEPALIVE = bytes([0x01, 0x0B, 0x89, 0x01])            # 读 Hooks 模式，最轻量

PROBES = [
    ("设备在线状态",    bytes([0x06, 0x03, 0x0A, 0x01])),
    ("设备 flashId",   bytes([0x01, 0x04, 0x0B, 0x01])),
    ("设备 SN",        bytes([0x01, 0x01, 0x0B, 0x01])),
    ("固件版本",        bytes([0x01, 0x04, 0x04, 0x01])),
    ("硬件版本",        bytes([0x01, 0x01, 0x41, 0x01])),
    ("dongle 版本",    bytes([0x06, 0x02, 0x03, 0x01])),
    ("电量",           bytes([0x01, 0x01, 0x02, 0x01])),
    ("亮度",           bytes([0x01, 0x06, 0x20, 0x01])),
    ("Hooks 模式",     bytes([0x01, 0x0B, 0x89, 0x01])),
    ("指示灯参数",      bytes([0x01, 0x0B, 0x88, 0x01])),
    ("全部按键功能",    bytes([0x01, 0x06, 0x31, 0x01])),
    ("按键功能支持",    bytes([0x01, 0x06, 0x38, 0x01])),
    ("AI 按钮功能",    bytes([0x01, 0x06, 0x21, 0x01])),
    ("麦克风开关",      bytes([0x01, 0x01, 0x2A, 0x01])),
    ("麦克风降噪等级",   bytes([0x01, 0x01, 0x90, 0x01])),
    ("马达强度",        bytes([0x01, 0x06, 0x40, 0x01])),
    ("旋钮开关",        bytes([0x01, 0x01, 0x34, 0x01])),
]


def probe(handles, pump, mon=None):
    """发只读查询并泵动 run loop，好让回复能被回调收到。"""
    print(bold("\n  主动查询设备状态（只读）\n"))
    for name, frame in PROBES:
        print(f"  {cyan('→ 查询')} {name:<16} {dim(frame.hex(' '))}")
        send_frame(handles, frame)
        end = time.time() + 0.4
        while time.time() < end:
            pump()
    end = time.time() + 1.2
    while time.time() < end:
        pump()

    # 区分"协议/权限有问题"和"Vibe Key 本体没开机" —— 现象一样，原因完全不同。
    if mon is not None and not mon.device_replied:
        print()
        print(red(bold("  ⚠ Vibe Key 本体没有应答，只有 dongle 在回话。")))
        print(red("     设备可能已关机 / 休眠 / 超出无线范围。"))
        print(f"     请按一下 Vibe Key 的{cyan('电源键')}唤醒它，再跑一次。")
        print(dim("     （dongle 已正常枚举、私有协议也通，不是权限或工具的问题）"))


# --------------------------------------------------------------------------
# HID 报文描述符解析
# --------------------------------------------------------------------------

ITEM_LEN = {0: 0, 1: 1, 2: 2, 3: 4}
# (type, tag) -> 名称。  type: 0=Main 1=Global 2=Local
ITEM_NAME = {
    (1, 0x0): "Usage Page", (1, 0x1): "Logical Min", (1, 0x2): "Logical Max",
    (1, 0x7): "Report Size", (1, 0x8): "Report ID", (1, 0x9): "Report Count",
    (2, 0x0): "Usage", (2, 0x1): "Usage Min", (2, 0x2): "Usage Max",
    (0, 0x8): "Input", (0, 0x9): "Output", (0, 0xB): "Feature",
}

USAGE_PAGE_NAMES = {
    0x01: "Generic Desktop", 0x07: "Keyboard", 0x08: "LED", 0x09: "Button",
    0x0C: "Consumer", 0xFFFC: "厂商自定义",
}


def dump_descriptor(handles):
    """打印每个接口的 HID 报文描述符，并列出它声明的 Report ID / 长度。"""
    for h in handles:
        kind = "厂商通道" if h["up"] == VENDOR_USAGE_PAGE else "接口2"
        print(bold(f"\n  ── {kind}   usagePage=0x{h['up']:04X} usage=0x{h['u']:04X} ──"))
        raw = iok.IOHIDDeviceGetProperty(h["dev"], cfstr("ReportDescriptor"))
        if not raw:
            print(dim("    （拿不到描述符）"))
            continue
        n = cf.CFDataGetLength(raw)
        p = cf.CFDataGetBytePtr(raw)
        d = bytes(p[i] for i in range(n))
        print(dim(f"    {n} 字节: {d.hex(' ')}"))

        i, cur_id, rsize, rcount, upage = 0, 0, 0, 0, 0
        declared: dict[int, dict] = {}
        while i < len(d):
            b = d[i]
            if b == 0xFE:                                   # long item
                sz = d[i + 1] if i + 1 < len(d) else 0
                i += 3 + sz
                continue
            size = ITEM_LEN[b & 0x03]
            itype = (b >> 2) & 0x03
            tag = b >> 4
            val = int.from_bytes(d[i + 1:i + 1 + size], "little") if size else 0
            nm = ITEM_NAME.get((itype, tag))
            if nm == "Usage Page":
                upage = val
            elif nm == "Report ID":
                cur_id = val
            elif nm == "Report Size":
                rsize = val
            elif nm == "Report Count":
                rcount = val
            elif nm in ("Input", "Output", "Feature") and rsize and rcount:
                key = f"{nm}@{USAGE_PAGE_NAMES.get(upage, hex(upage))}"
                declared.setdefault(cur_id, {})[key] = (rsize, rcount)
                rsize = rcount = 0
            i += 1 + size

        print()
        if not declared:
            print(dim("    （没解析出报文定义）"))
        for rid in sorted(declared):
            print(f"    Report ID 0x{rid:02X}")
            for k, (sz, cnt) in sorted(declared[rid].items()):
                print(f"        {k:<26} {sz*cnt:>4} bit  ({cnt} × {sz} bit)")


# ==========================================================================
# 9. 按键配置读写（设备端可编程按键表）
#
#   读:  → 01 06 50 01 <index>
#        ← 81 06 50 11 <index> 01 <num> <类型|sign<<7> 键码> × num
#   写:  → 01 06 50 04 <index> 01 <num> <类型|sign<<7> 键码> × num
#        ← 81 06 50 14 ...           (access 0x14 = 写确认)
#
#   实测：把 index 0 从 0x01 改成 0x68 后，按"键1"设备真的发出 0x68 (F13)。
# ==========================================================================

CONTROL_NAMES = {
    0: "键 1 (上)", 1: "键 2 (中)", 2: "键 3 (下)",
    3: "旋钮 按下", 4: "旋钮 → 右拧", 5: "旋钮 ← 左拧",
}
KEYTYPE_NAMES = {0x02: "按键", 0x03: "系统/多媒体"}

_NAME2CODE = {}
for _c, _n in KEYS.items():
    _NAME2CODE.setdefault(_n.lower(), _c)
_NAME2CODE.update({
    "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29,
    "backspace": 0x2A, "tab": 0x2B, "space": 0x2C, "del": 0x4C,
    "delete": 0x4C, "home": 0x4A, "end": 0x4D, "pageup": 0x4B,
    "pagedown": 0x4E, "up": 0x52, "down": 0x51, "left": 0x50, "right": 0x4F,
    "printscreen": 0x46, "capslock": 0x39, "insert": 0x49, "pause": 0x48,
    "lctrl": 0xE0, "lshift": 0xE1, "lalt": 0xE2, "lgui": 0xE3, "lcmd": 0xE3,
    "rctrl": 0xE4, "rshift": 0xE5, "ralt": 0xE6, "rgui": 0xE7, "rcmd": 0xE7,
})


def keyname(code):
    return KEYS.get(code, f"0x{code:02X}")


def parse_keycode(text):
    """接受 0x68 / 104 / F13 / enter 这几种写法。"""
    t = text.strip()
    if t.lower() in _NAME2CODE:
        return _NAME2CODE[t.lower()]
    try:
        return int(t, 0) & 0xFF
    except ValueError:
        raise ValueError(f"无法识别的键码: {text!r}")


def _settle(sec):
    end = time.time() + sec
    while time.time() < end:
        cf.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, False)


def read_key_config(handles, mon, index, settle=0.6):
    mon.keycfg.clear()
    send_frame(handles, bytes([0x01, 0x06, 0x50, 0x01, index]))
    _settle(settle)
    return mon.keycfg[-1] if mon.keycfg else None


def parse_entries(pt):
    """回复 → [(类型, 键码), ...]"""
    return [(pt[7 + 2 * i], pt[8 + 2 * i]) for i in range(pt[6])]


def write_key_config(handles, mon, index, entries, settle=0.6):
    frame = bytes([0x01, 0x06, 0x50, 0x04, index, 0x01, len(entries)])
    for etype, code in entries:
        frame += bytes([etype, code])
    mon.keycfg.clear()
    send_frame(handles, frame)
    _settle(settle)
    return mon.keycfg[-1] if mon.keycfg else None


def show_keys(handles, mon):
    mon.hide = True
    print(bold("\n  设备端按键配置（index 0-5 = 六个控件）\n"))
    print(f"  {dim('index'):<9} {dim('控件'):<16} {dim('类型'):<12} {dim('键码')}")
    print(dim("  " + "─" * 58))
    got = 0
    for i in range(6):
        r = read_key_config(handles, mon, i)
        name = CONTROL_NAMES.get(i, f"#{i}")
        if not r:
            print(f"  {i:<9} {name:<16} {red('(无回复)')}")
            continue
        got += 1
        ent = parse_entries(r)
        if not ent:
            print(f"  {i:<9} {name:<16} {dim('未配置')}")
            continue
        types = "/".join(KEYTYPE_NAMES.get(t & 0x7F, f"0x{t:02X}") for t, _ in ent)
        codes = "  +  ".join(f"{green(keyname(v))} {dim(f'0x{v:02X}')}"
                             for _, v in ent)
        print(f"  {i:<9} {name:<16} {types:<12} {codes}")
    print()
    if got == 0:
        print(red(bold("  ⚠ 六个控件全都没有应答 —— Vibe Key 本体可能没开机。")))
        print(f"     请按一下 Vibe Key 的{cyan('电源键')}唤醒它，再跑一次。")
        print(dim("     （按键配置存在设备里，设备关机当然读不到；"))
        print(dim("       dongle 会照常枚举，所以 --list 看起来一切正常）"))
        print()
    mon.hide = False


def apply_set_keys(handles, mon, specs):
    jobs = []
    for spec in specs:
        if "=" not in spec:
            print(red(f"  --set-key 格式应为 IDX=VALUE，收到 {spec!r}"))
            return False
        k, v = spec.split("=", 1)
        try:
            jobs.append((int(k, 0), parse_keycode(v)))
        except ValueError as e:
            print(red(f"  {e}"))
            return False

    mon.hide = True
    print(bold("\n  修改设备端按键配置\n"))
    for idx, code in jobs:
        name = CONTROL_NAMES.get(idx, f"#{idx}")
        old = read_key_config(handles, mon, idx)
        before = ("  +  ".join(keyname(v) for _, v in parse_entries(old))
                  if old and old[6] else "未配置")
        write_key_config(handles, mon, idx, [(0x02, code)])
        chk = read_key_config(handles, mon, idx)
        ent = parse_entries(chk) if chk else []
        ok = bool(ent) and ent[0][1] == code
        print(f"  {idx}  {name:<14} {dim(before):<22} →  "
              f"{green(keyname(code)) + dim(f' 0x{code:02X}')}   "
              + (green("✔ 已写入并确认") if ok else red("✘ 写入失败")))
    print()
    mon.hide = False
    return True


def main():
    ap = argparse.ArgumentParser(description="终端里监控 Ulanzi Vibe Key")
    ap.add_argument("--list", action="store_true", help="只列出设备接口")
    ap.add_argument("--learn", action="store_true", help="学习模式：打印原始密文/明文")
    ap.add_argument("--raw", action="store_true", help="显示每一条心跳")
    ap.add_argument("-t", "--duration", type=float, default=0, help="运行秒数")
    ap.add_argument("--probe", action="store_true", help="启动时主动查询设备状态（只读）")
    ap.add_argument("--poll", type=float, default=0, metavar="秒",
                    help="每隔 N 秒发一次保活查询，让设备保持唤醒（推荐 1）")
    ap.add_argument("--descriptor", action="store_true", help="dump HID 报文描述符")
    ap.add_argument("--log", metavar="文件", default="/tmp/vibekey-events.log",
                    help="同时把事件写入日志文件（默认 /tmp/vibekey-events.log）")
    ap.add_argument("--echo", action="store_true",
                    help="保留终端回显（默认关闭，避免按键字符冲乱输出）")
    ap.add_argument("--keys", action="store_true",
                    help="列出设备端按键配置（六个控件的 HID 键码）")
    ap.add_argument("--set-key", action="append", metavar="IDX=VALUE",
                    help="改某个控件的键码，可重复。例：--set-key 0=F13 --set-key 1=0x04")
    ap.add_argument("--no-color", action="store_true")
    a = ap.parse_args()

    C.on = not (a.no_color or not sys.stdout.isatty())

    real_out = sys.stdout
    logfh = open(a.log, "a", buffering=1) if a.log else None
    if logfh:
        logfh.write("\n===== %s =====\n" % datetime.now().isoformat(timespec="seconds"))
        sys.stdout = _Tee(real_out, logfh)
    atexit.register(lambda: logfh and logfh.close())

    no_echo = sys.stdin.isatty() and not a.echo
    if no_echo:
        os.system("stty -echo")

    if a.list:
        m = Monitor(learn=True)
        hs, _ = build_manager(m)
        m.quiet = True
        end = time.time() + 1.0
        while time.time() < end:
            cf.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
        close_all(hs)
        return 0

    print(bold("═" * 64))
    print(bold("   Vibe Key 终端监控") + dim("    Ctrl-C 退出"))
    print(bold("═" * 64))
    print(dim("   TEA/ECB 解密已启用 · 不依赖 Ulanzi Studio"))
    print(dim("   注意：按键会注入当前焦点窗口，建议保持本终端在前台\n"))

    mon = Monitor(raw=a.raw, learn=a.learn)
    try:
        hs, pending = build_manager(mon)
    except RuntimeError as e:
        print(red(str(e)))
        return 1

    def pump():
        cf.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, False)

    if a.probe:
        probe(hs, pump, mon)

    if a.descriptor:
        dump_descriptor(hs)

    if a.keys:
        show_keys(hs, mon)
    if a.set_key:
        if not apply_set_keys(hs, mon, a.set_key):
            close_all(hs)
            return 1
    if (a.keys or a.set_key) and not a.poll and not a.duration:
        a.duration = 0.01          # 只做配置，不进入监听

    if not (a.keys or a.set_key) or a.poll:
        print(green("\n   开始监听，请操作 Vibe Key…") + "\n")

    deadline = time.time() + a.duration if a.duration else None
    next_poll = time.time() if a.poll else float("inf")
    next_retry = time.time() + 2
    runloop = cf.CFRunLoopGetCurrent()
    try:
        while not deadline or time.time() < deadline:
            cf.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
            if time.time() >= next_poll:
                send_frame(hs, KEEPALIVE)
                next_poll = time.time() + a.poll
            if pending and time.time() >= next_retry:
                pending = retry_pending(mon, hs, pending, runloop)
                next_retry = time.time() + 2
    except KeyboardInterrupt:
        pass
    finally:
        close_all(hs)
        if no_echo:
            os.system("stty echo")
        mon.summary()
        if a.log:
            print(dim(f"   事件已写入 {a.log}"))
            sys.stdout = real_out
            logfh.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
