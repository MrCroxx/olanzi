# 05 · Verification Log
> 🌐 [中文](05-verification-log.zh.md)

> An archive of all measured data, **including the failed attempts**.
> Conclusions are in [02-vibekey-protocol.md](02-vibekey-protocol.md); the process is in [04-methodology.md](04-methodology.md).

> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · **05 Verification Log**

---

## Verification Environment

| Item | Value |
|---|---|
| Date | 2026-09-21 |
| OS | macOS (Apple Silicon) |
| Ulanzi Studio | 3.3.9 |
| Vibe Key firmware | 4.4.2 |
| Device serial number | `202606031150` |
| Tool | `vibekey.py` (this project) |

> All verification was performed with **Ulanzi Studio exited** (unless noted otherwise).

---

## 1. Device Identity Readout

**Command**: `python3 vibekey.py --probe -t 3`

| Query frame | Device reply (after decryption) | Interpretation |
|---|---|---|
| `06 03 0a 01` | `01` | Device online |
| `01 04 0b 01` | ⟨16 bytes, redacted⟩ | flashId, first 7 bytes ASCII = `AP53002` (a model prefix) |
| `01 01 0b 01` | `0a 00` + ⟨14 bytes, redacted⟩ + `07 01` + ⟨8 bytes, redacted⟩ | SN = **`<REDACTED>`** (in two packets) |
| `01 04 04 01` | `41 00 00 28 28 01 04 04 02 26 08 13 20 30` | Firmware **4.4.2** |
| `06 02 03 01` | `41 00 00 16 28 00 04 04 02 26 08 13 20 30` | dongle **4.4.2** |
| `01 01 02 01` | `dd 0d 1e 00 f1 01` | `0x0ddd` = 3549 mV |
| `01 01 90 01` | `00 64 00 64` | Dual-mic noise reduction: each `low=0 high=100` |
| `01 0b 88 01` | `00 00 02 07 02 \| 0a 02 07 02 02 \| 0a 02 07 02 01 \| 0a 02 07 02 00` | Indicator light parameters (apparently 3 groups + header) |
| `01 06 31 01` | all zeros | All key functions (not configured) |
| `01 06 21 01` | all zeros | AI button function (not configured) |
| `01 06 40 01` | all zeros | Motor strength (not configured) |
| `01 01 34 01` | all zeros | Knob switch (not configured) |
| `01 0b 89 01` | all zeros | Hooks mode (off) |
| `01 01 41 01` | all zeros | Hardware version (not configured) |

**Conclusion**: The device answers normally with **no Studio at all**. ✅

---

## 2. Key Mapping Experiments

### Experiment 1 — Free Pressing (13:27, failed but produced a discovery)

The user operated freely for about 40 seconds, and 47 presses were captured:

| keycode | Count | Time range |
|---|---|---|
| `0x2A` Backspace | 10 | 13:27:22.664 – 25.569 |
| `0x46` PrintScreen | 4 | 13:27:25.976 – 29.175 |
| `0x01` ErrorRollOver | 12 | 13:27:30.535 – 37.020 |
| `0x28` Enter | 10 | 13:27:31.394 – 37.319 |
| `0x29` Esc | 11 | 13:27:32.224 – 38.088 |

**Result**: No mapping could be established (no annotations).
**But a duration pattern surfaced** — every `0x2A` was 4–7 ms, and everything else was 64–205 ms.

### Experiment 2 — Free Pressing (13:28)

| Time | Event | Duration |
|---|---|---|
| 13:28:27.836 | `0x46` | 129 ms |
| 13:28:29.480 | `0x46` | 174 ms |
| 13:28:30.375 | `0x46` | 120 ms |
| 13:28:31.959 | `0x01` | **1855 ms** |
| 13:28:34.080 – 34.845 | `0x01` ×6 | 80–139 ms |

**Result**: Still no mapping. But the 1855 ms long press of `0x01` shows that it **really is a control**.

### Experiment 3 — Controlled Sequence (13:29) ✅ **Success**

**Action sequence** (3-second gap between steps):
> Knob press → Key 1 → Key 2 → Key 3 → twist right ×3 → twist left ×3 → long-press knob

**Captured result**:

| Time | Event | Duration | Corresponding action |
|---|---|---|---|
| 13:29:20.180 | `0x46` PrintScreen | 300 ms | ① Knob press |
| 13:29:21.095 | `0x01` ErrorRollOver | 320 ms | ② Key 1 |
| 13:29:21.980 | `0x28` Enter | 400 ms | ③ Key 2 |
| 13:29:22.760 | `0x29` Esc | 260 ms | ④ Key 3 |
| 13:29:26.079 | `0x4F` RightArrow | 4 ms | ⑤ Twist right #1 |
| 13:29:26.444 | `0x4F` RightArrow | 5 ms | ⑤ Twist right #2 |
| 13:29:26.985 | `0x4F` RightArrow | 6 ms | ⑤ Twist right #3 |
| 13:29:29.414 | `0x2A` Backspace | 4 ms | ⑥ Twist left #1 |
| 13:29:29.831 | `0x2A` Backspace | 0 ms | ⑥ Twist left #2 |
| 13:29:30.215 | `0x2A` Backspace | 10 ms | ⑥ Twist left #3 |
| 13:29:34.459 | `0x46` PrintScreen | **1220 ms** | ⑦ Long-press knob |

**7 actions ↔ 7 event groups; order, count and category all line up.** ✅

### Experiment 4 — Independent Re-check (13:36)

The user operated once more in their own habitual way:

```
13:36:28.960 按键   ⌨ 旋钮 按下    PrintScreen    178 ms
13:36:32.822 旋钮   ⟳ 旋钮 ← 左拧   Backspace        2 ms
13:36:33.778 旋钮   ⟳ 旋钮 → 右拧   RightArrow       3 ms
13:36:35.209 按键   ⌨ 键 1 (上)    ErrorRollOver  132 ms
13:36:36.164 按键   ⌨ 键 2 (中)    Enter          147 ms
13:36:36.908 按键   ⌨ 键 3 (下)    Esc             90 ms
```

**Identical to Experiment 3.** Mapping confirmed.

### Cross-validation: On-device Configuration Table

The official configuration read from the device (see §3) matches the mapping derived from the experiments **byte for byte**:

```
index 0..5 →  01  28  29  46  4f  2a
实验结论   →  01  28  29  46  4f  2a   ✅
```

---

## 3. Programmable Key Table

### 3.1 Reading the Full Configuration

**Command**: `send_frame(01 06 50 01 <i>)` for `i` in 0..7

```
index 0 → 81 06 50 11 00 01 01 02 01 00 00 ...
index 1 → 81 06 50 11 01 01 01 02 28 00 00 ...
index 2 → 81 06 50 11 02 01 01 02 29 00 00 ...
index 3 → 81 06 50 11 03 01 01 02 46 00 00 ...
index 4 → 81 06 50 11 04 01 01 02 4f 00 00 ...
index 5 → 81 06 50 11 05 01 01 02 2a 00 00 ...
index 6 → 81 06 50 11 06 00 00 00 00 00 00 ...     ← 未使用
index 7 → 81 06 50 11 07 00 00 00 00 00 00 ...     ← 未使用
```

**Parsing** (against the setter format recovered from the lldb disassembly):

```
81 06 50 11 | index | 01 | num | ⟨类型|sign<<7⟩ ⟨键码⟩ ×num
              pt[4]   pt[5] pt[6]   pt[7]        pt[8]
```

### 3.2 ⭐ Write Verification (end-to-end closed loop)

**Target selection**: `index 0` (Key 1), original value `0x01` = invalid code — **changing it cannot break any function**.

| Step | Frame / Result |
|---|---|
| 1. Read original value | `81 06 50 11 00 01 01 02 01 00` |
| 2. Write | `→ 01 06 50 04 00 01 01 02 68` |
| 3. Write reply | `← 81 06 50 14 00 01 01 02 68 00` (`access=0x14` = write confirmation) |
| 4. Read back | `81 06 50 11 00 01 01 02 68 00` ✅ **persisted** |
| 5. **Press the real key** | **Captured `0x68` = F13, 185 ms** ✅✅✅<br>← [line 282 of the raw evidence](evidence/2026-09-21-key-reprogram.log) |
| 6. Restore | `→ 01 06 50 04 00 01 01 02 01` → read back `[02, 01]` ✅ |

**Also confirmed that the other 5 keys were unaffected**:

```
index 1 : 01 01 01 02 28 00    ← 0x28 Enter，未变
index 2 : 02 01 01 02 29 00    ← 0x29 Esc，未变
index 3 : 03 01 01 02 46 00    ← 0x46，未变
index 4 : 04 01 01 02 4f 00    ← 0x4f，未变
index 5 : 05 01 01 02 2a 00    ← 0x2a，未变
```

**Conclusion**: With `type=0x02`, the second byte is exactly the HID keycode the device reports. ✅

### 3.3 Final Form of the Command Line

```bash
$ python3 vibekey.py --keys
  设备端按键配置（index 0-5 = 六个控件）

  index     控件               类型           键码
  ──────────────────────────────────────────────────────────
  0         键 1 (上)          按键           0x01 (无效码/未配置) 0x01
  1         键 2 (中)          按键           Enter 0x28
  2         键 3 (下)          按键           Esc 0x29
  3         旋钮 按下            按键           PrintScreen 0x46
  4         旋钮 → 右拧          按键           →右方向键 0x4F
  5         旋钮 ← 左拧          按键           Backspace 0x2A
```

---

## 4. Vendor Channel Behavior

### 4.1 After Studio Exits, Does the Vendor Channel Emit Events While Keys Are Pressed?

**Experiment**: `vibekey.py --poll 2 -t 600`, with the user pressing several keys.

**Result**: During the key-press window the vendor channel carried **heartbeats only**, and **zero key events**.

```
13:28:37.660 厂商 → 通知/心跳 ctr=2182346706399   cmd=0x0B flags=0 len=63
```

**Conclusion**: **Once detached from Studio, key presses go over standard HID only (interface 2) and never touch the private channel.** ✅

### 4.2 What About While Studio Is Running? (control)

`cap3.log` (Studio running), 11:55:37–43, six consecutive presses of "Key 1":

```
11:55:37.924 iface2 KEYBOARD keys=['ErrorRollOver']
11:55:38.999 iface2 KEYBOARD keys=['ErrorRollOver']
11:55:40.120 iface2 KEYBOARD keys=['ErrorRollOver']
11:55:41.140 iface2 KEYBOARD keys=['ErrorRollOver']
11:55:42.583 iface2 KEYBOARD keys=['ErrorRollOver']
11:55:43.444 iface2 KEYBOARD keys=['ErrorRollOver']
```

During the same window **interface 3 had no frames at all**.

**Conclusion**: Even with Studio running, **key presses still go over standard HID**.
(`deviceKeyEvent` does appear in the historical logs, but it is **not a required path for key presses**.)

### 4.3 deviceKeyEvent in the Historical Logs

Tallied from the 62 MB decoded log (4 days of data, 3893 records in total):

| index | Records |
|---|---|
| 0 | 518 |
| 1 | 230 |
| 2 | 38 |
| 3 | 142 |
| 4 | 645 |
| 5 | 2320 |

Sample:

```json
{ "status" : 1, "access" : 2, "type" : "deviceKeyEvent", "index" : 3 }
```

> `index 0..5` is consistent with the control numbering scheme in §3, which shows that it is **the same numbering**.
> But the trigger condition is not fully determined (see "Open Questions").

### 4.4 What the device looks like when it is offline (found during the final regression)

While running the final regression, `--keys` returned `(无回复)` for all six controls. Diagnosis:

**The dongle is alive; the Vibe Key itself is powered off.**

| Query | Reply |
|---|---|
| `06 03 0a 01` device online status | `06 03 0a 11` **00** `…` ← status = **0x00 offline** |
| `06 02 03 01` dongle version | `06 02 03 11 41 00 …` ✅ normal |
| the other 15 (all `cmd=0x01`) | ❌ no reply |

**The rule**: `cmd=0x06` is handled by the dongle, `cmd=0x01` by the device itself (over the wireless link).
With the device powered off, only `0x06` answers.

> This is not a fault — it is the device's normal sleep / power-off state. `vibekey.py` now prints an offline hint.

#### ⚠️ A wrong diagnosis (archived)

After the user powered the device on, `--keys` worked again (all 6 keys read), but `--probe` still reported
"device offline". I took that as evidence the device was still asleep. **That call was wrong** — the real
cause was code I had just written myself:

```python
    @staticmethod                    # ← no self
    def _describe(cmd, pt):
        if is_reply and cmd == 0x01:
            self.device_replied = True    # ← NameError
```

The exception was **swallowed silently inside the ctypes callback** (it prints one `Exception ignored`
line), so the reply line was never printed — a symptom identical to a powered-off device.

**Why `--keys` was unaffected**: it sets `self.hide = True` and returns *before* `_describe` is ever called.

**Lesson**: never judge "offline" from "did a reply arrive" alone — look at the **raw plaintext**.
When genuinely offline, `06 03 0a 11` still comes back but its status is `00`; a code bug prints **nothing at all**.

---

## 5. Failed Attempts (archived)

| Attempt | Result | Cause |
|---|---|---|
| Opening everything at once with `IOHIDManagerOpen` | ❌ `0xE00002C5` | Our own capture process was holding the device |
| Running the capture inside DSH while the user also ran it | ⚠️ Worked, but the two interfered with each other | Later confirmed that **non-exclusive opens can coexist** |
| Establishing a mapping by free pressing (Experiments 1, 2) | ❌ Could not align | Missing annotations |
| Reasoning from a "4 keys + knob" model | ❌ All wrong | It is actually **3 keys** |
| Pinpointing with `objdump --start-address` | ❌ Dumped the full output | LLVM objdump has problems with Mach-O |
| Automatically extracting the setter's opcode | ❌ Got `01 00 00 00` | The extraction script did not cover that pattern; manual lldb was required |
| Searching the 62 MB log with `grep` | ❌ Error | `maximum repetition exceeds 255`; switched to Python |
| Aligning logs with capture times after the fact | ❌ Did not line up | xlog **flushes late** (that day's log was last written at 11:21, the capture was at 11:44) |
| Running the tool in the background so the user could watch the output | ❌ The user saw nothing | The output was not shown on the user's screen; it must be run in the user's own terminal |
| Running it in iTerm2 without input monitoring permission | ❌ Keys took effect but nothing was captured | `0xE00002E2`, and the program **silently skipped** it at the time |

---

## 6. Open Questions

| Question | Status | Next step |
|---|---|---|
| Key combinations (`num > 1`) | Untested | Try writing `[(0x02,0xE0),(0x02,0x06)]` (presumed = Ctrl+C) |
| `type = 0x03` (system/multimedia) | Untested | Derive the range from the parser's `isSysCtrl` branch |
| Semantics of the `sign` bit (bit 7) | Untested | Observe a key combination written by Studio |
| `deviceKeyEvent` trigger condition | Undetermined | Possibly "the key function has been configured", or some handshake |
| Indicator light parameter field layout | Partial | `00 00 02 07 02 \| 0a 02 07 02 02 \| …` — the meaning of the three groups is undetermined |
| AI state → light value mapping | Unsolved | lldb breakpoint `+[MessageHelper setDeviceAIButtonFuncMessage:]` |
| Long-pressing the power key | Untested (risky) | Not necessary |
| Purpose of `index 6/7` | Unknown | Possibly controls of another model (e.g. a 4-key version) |

---

## 7. Raw Data Locations

| Data | Path |
|---|---|
| **Raw evidence for the programmable key table** | [evidence/2026-09-21-key-reprogram.log](evidence/2026-09-21-key-reprogram.log) |
| Event log (written automatically by the tool) | `/tmp/vibekey-events.log` |
| Session captures | `/tmp/vk.log`, `vk2.log`, `vk3.log`, `vk4.log`, `vk5.log` |
| HID captures (including Studio) | `~/ulanzi-re/raw/cap2.log`, `cap3.log` |
| 62 MB decoded log | `~/ulanzi-re/raw/logs_decoded.txt` |
| Command table | `~/ulanzi-re/raw/kwdm_message_builders.txt` |
| kwdm disassembly | `~/ulanzi-re/raw/kwdm_arm64_disasm.txt` |
