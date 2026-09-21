# 05 · Verification Log
> 🌐 [中文](05-verification-log.zh.md)

> An archive of all measured data, **including the failed attempts**.
> Conclusions are in [02-vibekey-protocol.md](02-vibekey-protocol.md); the process is in [04-methodology.md](04-methodology.md).

> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · **05 Verification Log** · [10 Input Runtime](10-input-runtime.md)

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

---

## 8. Heartbeat Investigation (2026-09-21)

[CONFIRMED] A vendor-interface-only test measured 60.005 seconds with no requests, followed by 60.005 seconds with 30 Hooks queries at two-second intervals. Both windows ended with `06 03 0a 11 01 00 00 00`, no notifications, and no callback errors. No configuration writes were sent.

[CONFIRMED] LLDB identified a separate Studio heartbeat: `06 01 23 00 01` plus 59 zero bytes, sent approximately once per second. The old `--poll` command reads Hooks mode and does not send that frame. A later attempt to test the Studio heartbeat found `06 03 0a 11 00 00 00 00` at baseline and was aborted before sending heartbeats. A preceding six-control read was incomplete, so the checker now validates online state first.

[CONFIRMED] A retry after the user reported physical wake still returned offline. A separate diagnostic submitted 10 official heartbeat frames successfully, interleaving status queries at approximately two-second intervals; all statuses stayed offline and six-key reads remained incomplete. No notifications or callback errors occurred. This was not an online-start, one-second heartbeat comparison.

[INFERRED] The later offline state may be sleep, but its onset and cause were not measured. The dedicated-heartbeat window and key-configuration before/after comparison were incomplete in those attempts. User activity, power conditions, and longer idle periods were not controlled. These measurements do not prove a sleep-prevention effect, nor can wireless online status prove that indicator lights stay awake.

[CONFIRMED] After wireless connectivity was restored, the real workspace read all six controls, wrote key 1 from `0x01` to F13 (`0x68`) with acknowledgment and matching device readback, and restored it to `0x01`. All six final configurations matched the original snapshot. The [round-trip evidence](evidence/2026-09-21-workspace-roundtrip.log) verifies the configuration write through readback, not physical key events.

[CONFIRMED] The running local service was then observed through HTTP for **90.019 seconds**, with 91 samples at roughly one-second intervals. Every sample reported `online=true` and `connected=true`, Studio heartbeat enabled with a one-second interval, and no error. The observed `lastSent` timestamp advanced between 86 adjacent sample pairs; its maximum age at sampling was 1.001 seconds. Sampling and heartbeat scheduling are independent, so adjacent equal timestamps do not imply a missed heartbeat. All six controls were read through `POST /api/refresh` before and after the window and were unchanged. The service remained running. See the [90-second observation log](evidence/2026-09-21-workspace-heartbeat90.log).

This is a successful short operational check, not an isolated sleep-prevention experiment: the service also queried online status every two seconds, and the before/after key reads may affect wake state. HTTP state reads only observed the running service; no second HID client or configuration write was used during this window. Longer-term sleep causality and physical key events remain unverified.

See [07 Heartbeat Investigation](07-heartbeat-investigation.md), the [comparison log](evidence/2026-09-21-keepalive-comparison.log), and the [original disassembly](evidence/2026-09-21-studio-heartbeat-disassembly.log). Missing reports must never be treated as proof of shutdown; use the raw status byte.


---

## 9. Native App Local Review and Fixes (2026-09-21)

### 9.1 Heartbeats after failed initial configuration

[CONFIRMED] On launching PR #2 locally after its development on another computer, the receiver and device were online. Clockwise rotation, `index 4`, read back as `type=0x03`, `code=0x04`; the other five controls retained factory values. No local `host-keymap.json` existed. The app reported the unsupported type, created no host map, and disabled all action editing, yet continued sending Studio heartbeats. This review did not rewrite device mappings or use physical key presses to verify lost input.

[INFERRED] The host bridge does not forward vendor events without an initialized map. Combined with the earlier physical evidence in [07 §4](07-heartbeat-investigation.md#4-heartbeat-changes-the-key-reporting-path-2026-09-21) that heartbeats stop standard HID output, this code path makes ordinary device input unavailable. This conclusion combines the current initialization and heartbeat observations, code inspection, and prior hardware evidence; it is not a new physical key test.

The fix defaults Studio heartbeats to disabled and enables them only with a valid host map, a connected and online device, Input Monitoring and Accessibility permissions, and unsuspended input. Read-only queries remain available while heartbeats pause. Query waits check permissions and sleep state, while normal online queries retain the last confirmed state until completion to avoid interrupting holds. Unsupported initial device actions are not automatically replaced by defaults. The UI can create a factory-key draft or import a profile; an explicit save persists only the host map. A corrupt local file remains protected and requires repair followed by a restart; a draft cannot overwrite it. The device-seeding rule and manual draft recovery described here are historical intermediate behavior, superseded by §9.8; heartbeat gating and corrupt-file protection remain.

### 9.2 Save results and profile-collection migration

Code review also identified two P2 issues and implemented the following fixes; automated regression for the initial fixes passed.

| Issue | Trigger and previous behavior | Implemented fix |
|---|---|---|
| Save-completion identification | When a save followed a refresh or reconnection, the earlier job's busy-state completion could be mistaken for save completion, clearing the pending state early and incorrectly reporting failure. | Each save has a request ID. The service returns its matching success or failure, and the UI completes only that request while preserving further draft edits made during saving. |
| Whole-collection decoding | One corrupt or unsupported profile caused decoding of the entire array to fail, preventing valid profiles from loading as well. | Decode and migrate entries independently, load valid entries, and back up the complete original data containing failed entries in `nativeHostProfilesRecoveryBackups`; later collection edits do not overwrite the recovery copy. |

### 9.3 Hidden permission notices before initialization

The user additionally noted that the Mac app might lack permissions without a visible notice. Code inspection confirmed that `VendorKeyBridge` previously reported missing permissions only when both configuration and device were ready, while the footer authorization button also required the bridge to be enabled. Missing Input Monitoring or Accessibility access could therefore remain hidden with an empty host map or an offline device. The fix separates permission diagnostics from configuration and online status, showing missing permissions and the relevant authorization entry point even before initialization. Automated regression and real-app UI verification of that permission-notice patch passed, within the scope below. The user subsequently requested a welcome page only when permissions are missing, without entering the configuration workspace or settings interface. The UI was therefore further changed to a permission welcome page inside the main app window, showing the two permission guides, corresponding system-settings buttons, and an app-location entry point. Ready permissions open the workspace automatically; revocation returns to the welcome page, while demo mode bypasses the gate. It replaces the main window's content rather than opening a popup, another window, or a sheet, and does not stack initialization errors with footer notices.

[CONFIRMED] `codesign` verified that the running app used the sole Apple Development identity in the keychain, with bundle identifier `com.mrcroxx.olanzi`, rather than ad-hoc signing. Stable signing identity and granted system permissions are distinct; this check does not establish Input Monitoring or Accessibility approval.

### 9.4 Verification boundary and pending checks

[CONFIRMED] Before these fixes, this local review passed the existing 120 native tests, 84 Python tests, and 3 JavaScript tests. Those passing results did not cover the initial-configuration, queued-save, and mixed-validity profile-collection cases above.

[CONFIRMED] Before the welcome-page change, the fix baseline passed all 131 native tests, `make build` succeeded, and strict `codesign` verification passed for the keychain-certificate-signed build. With the real device online and initialization still failing on unsupported actions, the UI displayed heartbeats as `未运行` (stopped). The `使用出厂键位创建本机配置` button was clickable, and creating its draft enabled control editing. This UI check neither saved the host configuration nor rewrote device mappings; it does not establish active host forwarding or a physical shortcut effect.

[CONFIRMED] Before the welcome-page change, the real app's accessibility tree and screenshot simultaneously showed the `type=0x03` initialization error, `权限不足：按键转换需要输入监控与辅助功能权限，心跳已暂停。`, and the `打开输入监控设置` button. The device was online and heartbeats were stopped. After the final restart, the original uninitialized state remained; the earlier factory-key draft check had not written a host configuration.

[CONFIRMED] After the welcome-page implementation, all 133 native tests passed. New coverage includes requiring both permissions before entering the workspace, returning to the welcome page on revocation while retaining drafts, and bypassing the gate in demo mode. The simultaneous errors and footer authorization entry observed above were an intermediate debugging state before the welcome-page change. The welcome-page version completed `make build` successfully and retained keychain-certificate signing.

[CONFIRMED] The final welcome page's app UI tree and screenshot both confirmed a single standard Olanzi main window. Its content showed `欢迎使用 Olanzi`, two permissions awaiting approval, and the `打开输入监控设置` and `显示 App 位置` controls. There was no key, device, or profile navigation, initialization error, save footer, additional popup, or sheet. The layout was complete; this verifies the welcome interface inside the main window while permissions are missing.

Physical forwarding, double-press, and long-press effects still require permission approval and ordered physical actions. Actual system permission revocation and sleep behavior also require separate testing. Record automated regression, UI observations, and actual input effects separately; successful test doubles do not establish that an OS shortcut fired.

### 9.5 Independent status polling after authorization

[CONFIRMED] Subsequently, `Olanzi.app_Toggle` was enabled in System Settings' Input Monitoring list while the older running app's welcome page still showed both permissions awaiting approval. This establishes disagreement between Settings and the app UI, not that a particular permission API caches its result. A listed switch also does not establish approval for the currently running process.

The fix adds independent, non-prompting permission checks once per second from the app, using the main run loop's common mode without depending on the device worker or window reactivation. The UI stores its latest polled status separately to prevent older device snapshots from overwriting it. Only status changes ask the service for an immediate recheck and automatically switch between the welcome page and workspace. Stopping or destroying the model cancels the timer; demo mode does not invoke real checks.

The UI and worker share the permission rules used by `InputPermission.currentStatus()`: a true `CGPreflightListenEventAccess()` means Input Monitoring is available. When it is false, an unknown `IOHIDCheckAccess()` remains unknown, while other HID results mean unavailable; a granted HID result cannot mask a negative CG listening preflight. That intermediate version still used `CGPreflightPostEventAccess() && AXIsProcessTrusted()` for Accessibility, skipping the latter when the former was false to preserve initial-authorization protection. This condition was subsequently shown to be too broad and corrected in §9.6. Diagnostics record only changes in raw permission results and do not read keyboard content.

[CONFIRMED] All 136 native tests passed after this change, including conflicting permission checks, revocation, short-circuit protection, and independent UI-state updates. This version passed `make build` and strict signature verification.

[CONFIRMED] After rebuilding and restarting, the real app's UI tree showed Input Monitoring enabled and Accessibility awaiting approval. The primary button automatically targeted Accessibility settings, and the copy described checks every second. Raw diagnostics from the currently signed process were `HID=0, CGListen=true, CGPost=false, accessibility=false`. This is a post-restart observation, not evidence that either API caches results or that real grant/revocation without restarting has been exercised. The observed `accessibility=false` was a short-circuit result, not a directly measured AX denial; the later in-process check in §9.6 corrects that interpretation. Timer regression tests cover live transitions, while key forwarding and gesture effects were not physically tested in this round.

### 9.6 Event-synthesis preflight is not accessibility trust

[CONFIRMED] The user had enabled Accessibility in System Settings while the app still showed it pending. LLDB attached to the then-running Olanzi process with its original signature. After `@import ApplicationServices`, separate calls returned `AXIsProcessTrusted()=true`, `CGPreflightPostEventAccess()=false`, and `CGPreflightListenEventAccess()=true`, followed by a normal detach. System permissions were not changed during measurement, and the values were not obtained only after restarting.

This directly establishes that the Accessibility misreport came from the code's `CGPost && AX`: the false first operand prevented AX from being called at all. It cannot be attributed to missing user approval, a signing error, or confirmed system caching. The lesson is to distinguish event-synthesis preflight from accessibility-client trust, avoid recording skipped queries as real denials, and avoid expanding initial-authorization protection into a permanent barrier to AX checks.

The fix uses `trust = (listening || posting) ? AXIsProcessTrusted() : nil` and reports Accessibility as `trust == true`. AX is skipped only when both listening and posting preflights are false, preserving the initial protection. Diagnostics explicitly distinguish `AX=skipped`, `AX=true`, and `AX=false`. New regression cases cover AX grant and revocation while CGPost remains false, and reading AX with input denied but posting preflight true while input remains unavailable.

[CONFIRMED] All 138 native tests passed after this fix. `make build` retained the keychain Apple Development certificate and passed strict signature verification. After rebuilding and restarting, the real app entered the main configuration window directly, with no welcome page or missing-permission notice. The current process logged `HID=0, CGListen=true, CGPost=true, AX=true`. The device's existing multimedia type `0x03` still prevented automatic initialization; this check neither wrote the device nor created a host configuration.

The new process's true CGPost result does not change the earlier measurement of false CGPost and true AX in the original running process, nor establish a caching cause. True AX confirms accessibility trust only. Actual key output and gesture effects still require separate verification.


### 9.7 Checking keyboard-listening capability after a negative preflight

[CONFIRMED] After the user enabled Input Monitoring again, the Settings switch was on while the app's checkmark remained absent. LLDB measured `IOHIDCheckAccess(Listen)=1` (denied), `CGPreflightListenEventAccess()=false`, `CGPreflightPostEventAccess()=false`, and `AXIsProcessTrusted()=false` in the same original running process, PID 78712. A session-level, head-inserted, listen-only tap containing only key-down/key-up events was then created successfully; both `CFMachPortIsValid` and `CGEventTapIsEnabled` were true. The probe was immediately invalidated and released without being scheduled on a run loop. Reading CGListen again still returned false.

This in-process evidence establishes disagreement between preflight results and available keyboard-listening capability. It does not establish a particular API caching mechanism or successful device-key forwarding. The probe only checked capability and did not read or record keyboard events. Because keyboard-tap capability may also be affected by Accessibility authorization, successful creation is not a direct reading of the separate Input Monitoring switch in Settings.

The current local Digger `PermissionChecker.swift` only reads `AXIsProcessTrusted()` directly. Its `WelcomeViewModel` rechecks every second and publishes only changed status; showing the window refreshes immediately, and closing it stops polling. Digger's historical `tapCreate` was a persistent ForceClick listener, not a permission probe, so the new approach is not described as a Digger-verified Input Monitoring implementation.

This revision retains independent one-second polling but adds the temporary capability probe when CGListen is false. Input availability follows a positive preflight or a successful valid probe. Accessibility now reads AX unconditionally on every check, removing the short-circuit conditions from §9.5/§9.6. Raw HID, CGListen, `ListenProbe`, CGPost, and AX results are recorded separately. Sections §9.5/§9.6 remain a history of intermediate implementations and failed attempts, not the current decision rules.

[CONFIRMED] All 139 native tests passed with the capability probe. `make build` and strict signature verification passed, retaining the same keychain Apple Development certificate.

[CONFIRMED] To establish an unapproved baseline for a new process, the old app was quit and Input Monitoring was disabled before starting the new build as PID 81521 at 22:45:32. It logged `HID=1, CGListen=false, ListenProbe=false, CGPost=false, AX=false`, and the UI showed both permissions pending. The user enabled Input Monitoring and reported `已开启，自动打勾了`. The same PID logged `HID=1, CGListen=false, ListenProbe=true, CGPost=false, AX=false` at 22:45:59. At 22:46:05 AX became true while the other values remained unchanged. The PID was verified unchanged, and the real app UI automatically entered the main configuration window without quitting or restarting.

This physically verified live UI transitions in the same running process after keyboard-listening capability became available and Accessibility was granted. It is no longer merely a post-restart observation. A complete running-process revocation cycle remains untested, as do actual key output and gesture effects. The device's original type `0x03` still leaves configuration uninitialized, and device mappings were not rewritten.


### 9.8 Separating host defaults from optional device-map import

The user identified a remaining architectural error: an unsupported legacy device action must not prevent configuring independent host actions. The observed `type=0x03` describes the old on-device fallback, not a required source for the app's configuration. The device-seeding approach in §9.1 and the uninitialized states recorded through §9.7 are historical behavior, superseded by the rules below.

- The worker first loads the existing host configuration. If no file exists, it publishes `hostConfigurationMissing=true` without deriving a map from the device or writing a file automatically.
- The app provides `HostKeymap.defaultKeymap` as an editable draft when the host file is missing. Once permissions are ready, the user can configure it offline. Device readback, connection, and old action types do not determine or replace that draft.
- Only an explicit successful local save persists the draft and makes it eligible for runtime forwarding and heartbeats. The online-device, permission, and suspension checks still apply. No hardware key-table write is involved.
- The profile page exposes optional `从设备键位导入` (import device mappings). It validates the entire six-control read-only snapshot before loading a draft; an unsupported action identifies its control and leaves the previous draft intact. Import does not automatically save or activate the result.
- An existing valid host file takes precedence. A corrupt or unsupported local file remains preserved and blocks replacement until repaired and the app restarted; a missing file must not be confused with a failed load.

The user explicitly retained double-press and long-press actions and dropped automatic cross-Mac synchronization through the device. The supported transfer workflow exports and imports the full version-2 `HostProfile` JSON, including primary/double/long actions and timing values, then explicitly saves it on the destination Mac. This does not synchronize or rewrite device mappings.

[CONFIRMED] The independent-default-draft revision passed all 143 native tests, `make build` with keychain-certificate signing, and strict signature verification. With the device asleep, the actual app showed one main window with all six default controls editable and no `type=0x03` initialization error. Assigning Enter to a double-press draft displayed `双击 Enter`, establishing offline draft editing. The test edit was then discarded: double press returned to disabled, the undo button became disabled, and the primary action was selected again. The six-key default draft remained pending save, and the real host configuration file still did not exist. No device mappings were written. Physical output, gesture effects, online operation with the legacy `type=0x03` mapping, and running-process permission revocation remain unverified.


### 9.9 Synthetic Fn feedback contaminating the HID state

The initial report arrived while the default draft was still unsaved, so the first check identified that configuration boundary. The user subsequently saved `host-keymap.json`. The saved top-key action was primary Fn with neither double-press nor long-press configured. The later failure therefore cannot be attributed to an unsaved draft or optional-gesture timing.

[CONFIRMED] The user reported that Fn worked only the first time and that holding it affected the input method only momentarily. Logs showed multiple correct AU05 press/release pairs, while generated virtual keycode 63, event type 12 (`flagsChanged`) had flags 545259520 (`0x20800000`) on both press and release. The release therefore retained the Fn bit rather than clearing it. There was no evidence that the gesture router emitted an early end.

[CONFIRMED] A breakpoint immediately before the emitter read modifier state in the original PID 86081 measured HID flags 0 and key state 63 false before the first down. Before its up, HID flags were 545259520 and key state 63 was true; the following down and up again observed true. This establishes that the app’s synthetic Fn fed back into both `.hidSystemState` flags and key state. A private event source does not isolate that aggregate, and switching from flags to key state alone would not address the observed contamination.

The first fix introduced `PhysicalFnMonitor`, a session-level listen-only `flagsChanged` tap accepting updates only from source PID 0 and keycode 63. It still took a one-time initial seed from global key state before its first synthetic event. The emitter cleared the aggregate Fn bit and merged this tracked state with software-owned Fn holds; the legacy native backend used the same rule.

[CONFIRMED] That intermediate version passed all 150 native tests, `make build` with the keychain certificate, and strict signature verification. PID 91133 retained the user’s saved configuration and displayed the saved Fn action and sustained-hold explanation. Physical retesting nevertheless still produced release flags `0x20800000`. Monitor logs identified the Fn events as PID 91133, which its filter correctly ignored; the initial seed had already inherited global Fn=true contamination left by the previous process. The passing tests had not covered that startup state. Moving the aggregate read to a one-time seed was therefore an unsuccessful intermediate fix.

The second correction removes every global initial key-state read. `PhysicalFnMonitor` starts false and changes only on accepted source-PID-0 `flagsChanged` events for keycode 63. `VendorKeyBridge` now prepares monitoring before enabling forwarding in its synchronize/pump path; preparation failure leaves forwarding disabled and reports an explicit error. The legacy `NativeFnBackend.open` also starts the monitor before emitting events. Emitters clear the aggregate Fn bit and merge the independent monitor state with software-held Fn. Other modifiers retain their existing global-state path. Tap creation or invalidation fails explicitly, disabled taps are re-enabled when possible, and destruction removes and releases the run-loop source and tap.

A real Fn already held when monitoring starts has an unobservable initial state until a qualifying transition arrives; the implementation initially treats it as false. Actual Mac Fn source PID 0 and physical-key overlap have not been verified. Simulated state and overlap tests do not establish every physical keyboard combination.

The UI explains action semantics: primary-only Fn is held until release; long-press Fn begins holding after its threshold and ends on release. Primary Fn combined with other gestures, or double-press Fn, is a pulse after gesture recognition. This explanation does not change the confirmed primary-only configuration involved in the failure.

[CONFIRMED] All 151 native tests passed for the second correction. `make build` succeeded with the existing Apple Development certificate. The user subsequently reported `好用了`, confirming that holding and releasing the current default Fn mapping works in use. This is a user-reported physical result; no new-build raw flags log was captured to verify each emitted edge independently. It does not establish all gesture mappings, a counted repeated-hold sequence, actual Mac Fn source PID 0, or real-Fn overlap; those remain unverified.


### 9.10 Read-only battery status and main-window display

[CONFIRMED] At 23:25:12, the read-only battery request `01 01 02 01` returned plaintext beginning `81 01 02 11 f6 0c 0a 00 c8 01 01 00 ...`. The accompanying online reply began `06 03 0a 11 01 ...`, confirming that the device was online for this sample. The little-endian voltage bytes `f6 0c` represent 3318 mV.

[CONFIRMED] Studio’s `kwdm.dylib` battery-response handler reads payload bytes 0–1 as little-endian `voltage`, bytes 2–3 as little-endian `battery`, and byte 6 as `charging`. In this sample those fields are 3318, 10, and 1 respectively; payload offsets start at plaintext byte 4. Studio’s UI reads the `battery` integer, forwards it through `deviceBatteryUpdated` to `IconDrawer::setIconForLabel`, bounds it at 100, and selects icon levels at 10/25/50/75. The [disassembly excerpts](evidence/2026-09-21-battery-disassembly.log) establish that this sample reports 10% and charging, with 3318 mV; the percentage is not inferred from voltage.

The main-window implementation displays battery status below the connection state, marks levels at or below 20% in orange, and refreshes every 20 seconds while online. A missing or failed reading is displayed as `电量 —`, while a valid voltage can be shown when percentage alone is unknown. Read errors and update timestamps remain separate from the input runtime; failed reads clear stale values and do not disable Fn. [CONFIRMED] All 158 native tests passed at 23:32:22. `make build`, with the existing Apple Development signing identity explicitly selected, and strict code-signature verification succeeded. The real app’s accessibility tree showed `Vibe Key 已连接 电池电量：10% · 充电中`; its screenshot confirmed an orange reading at the top right without truncation. Integration tests using a fake clock verified the 20-second schedule and that battery failures do not disable Fn; that test coverage does not establish an exactly timed 20-second interval on the physical device. The user’s subsequent confirmation of the default Fn hold/release is recorded in §9.9; this battery check does not add Fn event-log or physical-overlap evidence.

[CONFIRMED] Before quitting the battery-display build for the next UI update, a second accessibility-tree inspection of the same running app showed `20% · 充电中`, following the earlier `10% · 充电中`. This confirms that the visible battery reading refreshed during real operation; the elapsed interval was not measured, so it does not verify an exact 20-second cadence.

### 9.11 Device illustration and gesture cards

[CONFIRMED] The UI revision built successfully with `make build`, Apple Development signing, and strict signature verification; the latest build log is `/tmp/olanzi-gesture-cards-signed.log`. A screenshot of the real app confirmed the centered device illustration, prominent rotation arrows on either side of the knob, and four separate cards for the three keys and knob press. Each press-control card displays primary, double-press, and long-press assignments together; rotation retains a single action per direction. The temporary verification draft was discarded without saving. This UI check adds no physical gesture-output verification.
