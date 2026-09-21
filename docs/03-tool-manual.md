# 03 · vibekey.py Tool Manual
> 🌐 [中文](03-tool-manual.zh.md)

> One file, zero third-party dependencies, talks to the hardware directly.
> Source: [vibekey.py](../vibekey.py)

> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · **03 Tool Manual** · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md) · [10 Input Runtime](10-input-runtime.md)

---

## 1. Installation

There is no installation step.

```bash
cd <project directory>
python3 vibekey.py --help
```

The only dependencies are the **Python 3 standard library** plus the system's built-in **IOKit / CoreFoundation** (called through `ctypes`).
**No `pip install`, no Ulanzi Studio, no background service.**

### The only prerequisite: Input Monitoring permission

Since macOS 10.15, reading a keyboard-class HID interface requires explicit user authorization.

> **System Settings → Privacy & Security → Input Monitoring → enable the terminal you use → fully quit and restart that terminal**

**What happens when the permission is not granted?**

```
13:33:54.756 ✗ 打不开 AU05  输入接口  无权限 (kIOReturnNotPermitted)

  ⚠ 输入接口没打开，按 Vibe Key 不会有任何输出！
    请到 系统设置 → 隐私与安全性 → 输入监控，
    把你运行本程序的终端（如 iTerm2）打开，然后重启终端。
    （程序会持续重试，权限开放后会自动接上）
```

The program **does not fail silently** — this is deliberate (early versions skipped quietly, so "pressed but nothing happened" had no traceable cause).
It retries every 2 seconds, and **hooks up automatically as soon as the permission is granted — no need to restart the program**.

---

## 2. Four Usage Modes

### 2.1 Monitor mode (most common)

```bash
python3 vibekey.py --probe --poll 2
```

| Argument | Effect |
|---|---|
| `--probe` | Reads the device status once at startup (firmware/battery/noise reduction/SN…) |
| `--poll 2` | Reads Hooks mode every 2 seconds; sleep prevention is unverified |

**What does `--poll` do?** It periodically reads Hooks mode. A dongle reply does not establish that the device body is awake.
A 2-second interval works for this query; see [07 Heartbeat Investigation](07-heartbeat-investigation.md) for Studio's dedicated heartbeat and measurement limits.

### 2.2 Configuration mode

```bash
python3 vibekey.py --keys                        # list the current configuration of the six controls
python3 vibekey.py --set-key 0=F13               # key 1 → F13
python3 vibekey.py --set-key 0=enter --set-key 2=0x04    # change several at once
```

In configuration mode the **log is automatically muted**; only the result table is printed:

```
  设备端按键配置（index 0-5 = 六个控件）

  index     控件               类型           键码
  ──────────────────────────────────────────────────────────
  0         键 1 (上)          按键           F13 0x68
  1         键 2 (中)          按键           Enter 0x28
  2         键 3 (下)          按键           Esc 0x29
  3         旋钮 按下            按键           PrintScreen 0x46
  4         旋钮 → 右拧          按键           →右方向键 0x4F
  5         旋钮 ← 左拧          按键           Backspace 0x2A
```

`--set-key` **automatically reads the old value → writes the new value → reads back to confirm**:

```
  修改设备端按键配置

  0  键 1 (上)        F13                    →  0x01 (无效码/未配置) 0x01   ✔ 已写入并确认
```

**The write is persistent** (stored on the device); it survives power-off and reconnection.

After configuring, if you do not add `--poll`/`-t`, the program exits immediately.

### 2.3 Diagnostic mode

```bash
python3 vibekey.py --list           # list HID interfaces only
python3 vibekey.py --descriptor -t 2   # dump the HID report descriptor
python3 vibekey.py --probe -t 3     # read the device status once
```

### 2.4 Learn mode (inspect the protocol)

```bash
python3 vibekey.py --learn --raw -t 30
```

Additionally prints the **raw ciphertext and plaintext** of every frame:

```
13:44:21.333 厂商 ← 读 按键快捷功能  00 01 01 02 68
               CT 5d 07 5c ae 29 61 af 33 38 90 c4 99 a3 60 aa ad ...
               PT 81 06 50 11 00 01 01 02 68 00 00 00 00 00 00 00 ...
```

| Field | Meaning |
|---|---|
| `CT` | CipherText, the raw ciphertext received on the wire (56 decryptable bytes) |
| `PT` | PlainText, the plaintext frame after TEA decryption |

---

## 3. All Arguments

| Argument | Default | Description |
|---|---|---|
| `--list` | | Lists device interfaces only, then exits |
| `--probe` | | Actively queries device status at startup (**read-only**, safe) |
| `--keys` | | Lists the on-device key configuration |
| `--set-key IDX=VALUE` | | Changes a control's HID keycode; **repeatable** |
| `--descriptor` | | Dumps the HID report descriptor |
| `--learn` | | Learn mode: prints raw ciphertext/plaintext |
| `--raw` | | Shows every heartbeat (by default only 1 in 10 is shown) |
| `--poll SECONDS` | `0` | Sends a keepalive query every N seconds; `2` is recommended |
| `-t, --duration SECONDS` | `0` | Run duration; `0` = run forever |
| `--log FILE` | `/tmp/vibekey-events.log` | Also writes events to a log file (append) |
| `--echo` | off | Keeps terminal echo. **Off by default**, so key characters do not scramble the output |
| `--no-color` | off | Disables ANSI color |

### Keycode formats

The VALUE of `--set-key` accepts three forms:

| Form | Example |
|---|---|
| Hexadecimal | `0x68` |
| Decimal | `104` |
| Name | `F13`, `enter`, `esc`, `backspace`, `lctrl`, `right`, `pageup`… |

Common keycode quick reference:

| Key | Code | Key | Code |
|---|---|---|---|
| `a`–`z` | `0x04`–`0x1D` | `F1`–`F12` | `0x3A`–`0x45` |
| `1`–`9`,`0` | `0x1E`–`0x27` | `F13`–`F24` | `0x68`–`0x73` |
| `Enter` | `0x28` | `LeftCtrl` | `0xE0` |
| `Esc` | `0x29` | `LeftShift` | `0xE1` |
| `Backspace` | `0x2A` | `LeftAlt` | `0xE2` |
| `Tab` | `0x2B` | `LeftGUI/⌘` | `0xE3` |
| `Space` | `0x2C` | `RightCtrl` | `0xE4` |
| `PrintScreen` | `0x46` | `RightShift` | `0xE5` |
| `RightArrow` | `0x4F` | `RightAlt` | `0xE6` |
| `LeftArrow` | `0x50` | `RightGUI/⌘` | `0xE7` |

> **Recommendation**: prefer keys such as `F13`–`F24`, which have no default function on macOS,
> so that typing does not trigger them by accident after the change. To put them to work, bind them with Karabiner / skhd / Hammerspoon.

---

## 4. Reading the Output

### 4.1 Key events

```
13:29:21 按键   ⌨ 键 2 (中)        Enter                      400 ms
13:29:26 旋钮   ⟳ 旋钮 → 右拧       RightArrow                   4 ms
```

| Column | Meaning |
|---|---|
| Time | Accurate to the millisecond |
| Category | key / knob |
| Icon | `⌨` key · `⟳` knob rotation |
| Control name | Looked up in the index mapping table |
| Raw code | HID name + `0x` value |
| Duration | Milliseconds held down |

### ⭐ Duration distinguishes control types

A pattern found by measurement:

| Type | Press duration |
|---|---|
| **Knob rotation** (instantaneous pulse) | **0 – 10 ms** |
| **Human key press** | **80 – 2000 ms** |

The program uses **25 ms** as the threshold for automatic classification, so it separates these two event types **without knowing the mapping in advance**.

### 4.2 Vendor channel events

```
13:44:21.333 厂商 ← 读 按键快捷功能  00 01 01 02 68     cmd=0x01 flags=4 len=63
```

- `←` = device reply, `→` = sent by the host
- read / write = the access field
- What follows is the decoded data
- `cmd` / `flags` / `len` are raw frame information

A typical heartbeat:

```
厂商 → 通知/心跳 ctr=2135102066141   cmd=0x0B flags=0 len=63
```

### 4.3 Session statistics

Printed on exit (`Ctrl-C`, or when `-t` expires):

```
  本次会话统计
  ────────────────────────────────────────────────
  按键 Enter                                  3
  旋钮 RightArrow                             10
  （保活往返）                                  5
  时长                                    30.2s
```

---

## 5. Logging

By default the program **always** writes a log to `/tmp/vibekey-events.log` (append mode, with ANSI color codes stripped automatically).

**Why is it needed?** Keystrokes really are injected into the terminal and scramble the screen — the log file always stays clean.

```bash
python3 vibekey.py --poll 2 --log ~/vibekey.log
```

> At startup the program writes a line `===== 2026-09-21T13:44:21 =====` into the log as a separator.

---

## 6. Troubleshooting

| Symptom | Cause | Solution |
|---|---|---|
| ✗ cannot open … no permission (`kIOReturnNotPermitted`) | Missing Input Monitoring permission | System Settings → Privacy & Security → Input Monitoring → enable the terminal → **restart the terminal** |
| ✗ cannot open … held exclusively (`kIOReturnExclusiveAccess`) | Another process holds it exclusively | `pkill -f UlanziDeck`, then run it again |
| Vibe Key not found | The dongle is not seated properly | Reseat the dongle, or check with `python3 vibekey.py --list` |
| Pressing a key does nothing | The input interface is not open | Check whether the startup output has the ● connected … input interface line |
| The screen is scrambled by key characters | Terminal echo | Off by default; it appears only if you use `--echo` |
| Key 1 does nothing when pressed | **It is the invalid code `0x01`** | Use `--set-key 0=F13` to change it to a useful key |
| A key change did not take effect | The read-back confirmation failed | Re-run `--keys` to inspect the configuration table; if necessary, write it again with `--set-key` |
| `--keys` shows `(无回复)` for all six controls | **The Vibe Key itself is powered off** (the dongle is fine) | Press the device's power button to wake it; see [02 §4](02-vibekey-protocol.md) for why |

### Emergency recovery

If the keys get scrambled, restore the factory values:

```bash
python3 vibekey.py \
  --set-key 0=0x01 \
  --set-key 1=0x28 \
  --set-key 2=0x29 \
  --set-key 3=0x46 \
  --set-key 4=0x4F \
  --set-key 5=0x2A
```

---

## 7. Implementation Notes (Pitfalls)

This section is for anyone who wants to modify the source.

### 7.1 Do not use `IOHIDManagerOpen`

`IOHIDManagerOpen(mgr, 0)` **opens every matching device at once**; if any single one fails
(exclusive access `0xE00002C5`, or no permission `0xE00002E2`), **the whole call fails**.

✅ Correct approach: enumerate with `IOServiceGetMatchingServices` → then, for each `IOService`, individually
`IOHIDDeviceCreate` + `IOHIDDeviceOpen`.

```python
matching = iok.IOServiceMatching(b"IOHIDDevice")
cf.CFDictionarySetValue(matching, cfstr("VendorID"), cfnum(VIBE_VID))
cf.CFDictionarySetValue(matching, cfstr("ProductID"), cfnum(VIBE_PID))
iok.IOServiceGetMatchingServices(kIOMainPortDefault, matching, ctypes.byref(it))
# IOHIDDeviceCreate / IOHIDDeviceOpen one by one
```

### 7.2 63 bytes vs 64 bytes

The frame struct is **64 bytes**, and TEA encrypts **8 full blocks**.
But the total HID report length is only 64 bytes, **1 byte of which is the report ID**.

| Direction | Approach |
|---|---|
| **Decryption** | Decrypt only **7 blocks (56 bytes)**; the last 7 bytes are undecryptable padding and are treated as 0 |
| **Encryption** | Encrypt the full 64 bytes and **send only the first 63 bytes** |

```python
ct = tea_encrypt(pt)              # 64 bytes
wire = bytes([0x55]) + ct[:63]    # 64 bytes (including the report ID)
```

### 7.3 The device is passive

An idle 60-second measurement produced no notifications while the final online status still reported online. **Silence is not evidence of sleep.** Hooks polling and Studio's dedicated heartbeat are different; their long-term effect on sleep requires a controlled comparison.

### 7.4 Concurrent opens are safe

All opens use `kIOHIDOptionsTypeNone` (non-exclusive), so
**multiple instances can open the same device at the same time** without fighting each other or taking it exclusively.

Verified: running two `vibekey.py` instances at the same time both succeed.

### 7.5 Keepalive query replies must be filtered out

`--poll` periodically sends `01 0B 89 01` (read Hooks mode), and the device replies every time.
Without filtering, the output would be drowned. The program recognizes replies with `pt[2] == 0x89 and (pt[3] & 0x0F) == 0x01`
and counts them under the keepalive round-trip row in the statistics.

(They are shown when using `--learn` or `--raw`.)

---

## 8. Want to Extend It?

`vibekey.py` is a single-file script and can be imported directly:

```python
import vibekey as V

class MyMon(V.Monitor):
    def _keyboard(self, p):
        ...   # override key handling

mon = MyMon()
handles, pending = V.build_manager(mon)
runloop = V.cf.CFRunLoopGetCurrent()
while True:
    V.cf.CFRunLoopRunInMode(V.kCFRunLoopDefaultMode, 0.1, False)
```

Useful exports:

| Name | Purpose |
|---|---|
| `tea_encrypt` / `tea_decrypt` | TEA encode/decode (blocking into 8 bytes automatically) |
| `send_frame(handles, pt)` | Sends one plaintext frame (automatic encryption + truncation) |
| `build_manager(mon)` | Enumerates and opens all interfaces → `(handles, pending)` |
| `retry_pending(...)` | Retries interfaces that could not be opened |
| `close_all(handles)` | Closes all interfaces |
| `Monitor` | Report decoding + display (subclassable) |
| `OP_TABLE` | Table of 85 commands, `(grp, op) → name` |
| `VIBE_CONTROLS` | Keycode → control name mapping |
| `read_key_config` / `write_key_config` | Read/write the on-device key table |
| `parse_keycode` / `keyname` | Keycode ↔ name |

---

## 9. Safety Notes

| Operation | Risk |
|---|---|
| `--probe`, `--keys`, `--list`, `--descriptor` | **Read-only, safe** |
| `--poll` | Sends only read commands, safe |
| `--set-key` | **Writes device configuration**. Changes are persistent but can be reverted at any time; see §6 Emergency recovery |
| Long-press of the power key | **May power the device off directly**; not touched by this program |

> Do not blindly send unknown `access=0x04` (write) commands — the command table contains dozens of write commands
> (brightness, microphone, indicator light, OTA…); sending them before the parameter formats are understood may put the device into an abnormal state.
