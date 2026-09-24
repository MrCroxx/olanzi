# 02 · Vibe Key Protocol and Terminal Tool (Phase 2)

> 🌐 [中文](02-vibekey-protocol.zh.md)

> For the Phase 1 conclusions, see [01-ulanzi-studio-scope.md](01-ulanzi-studio-scope.md).
> This document records the protocol details and the tool that have been **measured working end to end**.
>
> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · **02 Protocol** · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md) · [10 Input Runtime](10-input-runtime.md)

---

## 0. One-Sentence Conclusion

**The Ulanzi Vibe Key (AU05) can be used completely independently of Ulanzi Studio.**
No Studio, no network, no third-party libraries — a single 800-line Python file is enough.

---

## 1. Hardware

| Item | Value |
|---|---|
| Product | Ulanzi Vibe Key (model **AU05**) |
| USB | VID `0xFFF1` / PID `0x00DD`, composite device |
| Serial number | `202606031150` |
| Firmware | dongle `4.4.2` / device `4.4.2` |
| flashId | `<REDACTED>` (first 7 bytes as ASCII = `AP53002`, a model prefix) |
| deviceSn | `<REDACTED>` |
| MAC | **empty** (no network interface) |
| Controls | **3 keys (stacked vertically) + 1 knob + 1 power key** |

### HID Interfaces (measured descriptors)

**Interface 2** — standard HID, 165-byte descriptor, three collections sharing one interface:

| Report ID | Collection | Layout |
|---|---|---|
| `0x01` | Consumer | 16-bit media key code |
| `0x02` | Mouse | 3-bit buttons + 8-bit X + 8-bit Y + 8-bit wheel + 8-bit AC Pan |
| `0x03` | Keyboard | 8-bit modifier bits + 8-bit reserved + **6 × 8-bit key codes** + 5-bit LED output |

**Interface 3** — vendor-private, 36-byte descriptor:

```
06 fc ff   Usage Page = 0xFFFC
09 01      Usage
a1 01      Collection (Application)
09 02  85 55
75 08  95 3f  81 02   → Input   Report ID 0x55, 63 bytes
09 03  75 08  95 3f  91 02   → Output  Report ID 0x55, 63 bytes
```

> ⚠️ Both interfaces sit on **the same USB interface 2/3**, but in IOKit they are **two independent IOHIDDevices**.

---

## 2. Transport Layer: TEA Encryption

The 63-byte payload of interface 3 is **TEA-encrypted**.

| Item | Value |
|---|---|
| Algorithm | **TEA** (Tiny Encryption Algorithm, **not XTEA**) |
| Mode | **ECB**, 8-byte block, in-place, no IV, no padding |
| Rounds | **32** |
| delta | `0x9E3779B9` |
| Key (16 B) | `ca ba a5 ca 6d 8a 2a bc ba 9e 5a ca ca 8b b8 9b` |

Key location: the `_gaui_custom_encrypt_keys` global in `kwdm.dylib`
(arm64 `__DATA,__data+0x4a580`, x86_64 `+0x4e740`).

**Verification method (decisive)**:

```
TEA_ECB_Enc(00 00 00 00 00 00 00 00) == 38 90 c4 99 a3 60 aa ad
```

That "fixed tail string" that once seemed so mysterious **is simply the ciphertext of the all-zero block**. It was never a constant.

### The Crucial 63 vs 64 Detail

* The plaintext struct is **64 bytes**, and encryption likewise covers **8 complete blocks (64 bytes)**
* But the total HID report length is also 64 bytes — **including the 1-byte report ID**
* So only `ct[0..62]` is sent on the wire, and **the last byte of the 8th block is always lost**

| Direction | Approach |
|---|---|
| **Decrypt** | Decrypt only **7 blocks (56 bytes)**; the last 7 bytes are undecryptable padding and are treated as 0 |
| **Encrypt** | Encrypt all 64 bytes, **send only the first 63 bytes** |

The TEA implementation is at the top of [vibekey.py](../vibekey.py), or in `~/ulanzi-re/tools/tea_kwdm.py`.

---

## 3. Frame Format

```
frame[0]        frame header: cmd = frame[0] & 0x1F, top 3 bits are flags
frame[1]        config header { grp = b & 0x0F, sub = b >> 4 }
frame[2]        opcode
frame[3]        access: 0x01 = read, 0x04 = write, other values see below
frame[4..]      parameters
```

### Determining Direction

| Flag | Meaning |
|---|---|
| `frame[0] & 0x80` = 1 (i.e. `0x81`) | **device → host (reply)** |
| `frame[3] & 0x10` = 1 (i.e. `0x11`) | same as above, reply marker |

Request `01 0b 89 01` → reply `81 0b 89 11`.

### cmd Values

| cmd | Handler |
|---|---|
| `0x01` | device message `handleDeviceMessage` |
| `0x06` | USB message `handleUsbMessage` |
| `0x0B` | notice `handleNoticeMessage` |
| `0x0C` / `0x0D` | BLE short/long audio |
| `0x0E` | USB audio |
| `0x15` | image upload |
| `0x1E` / `0x1F` | dongle / device firmware upgrade |

### Notice Subtypes (cmd = 0x0B, taken from `frame[1]`)

| Subtype | Meaning |
|---|---|
| `0x10` | Key event: state in `frame[3]`, AU05 physical control index in `frame[4]`; see [07 §4](07-heartbeat-investigation.md) |
| `0x7B` | heartbeat (`frame[2..7]` is counter/status) |
| `0x0B` | notice B |
| `0x0D` | notice D |

---

## 4. Command Table (measured working)

For all 85 entries, see `~/ulanzi-re/raw/kwdm_message_builders.txt`.
The following are the ones **actually verified** on the Vibe Key:

### Read-Only Queries (safe, may be sent at any time)

| Name | Report bytes | Measured reply |
|---|---|---|
| Device online status | `06 03 0a 01` | `01` = online |
| Device flashId | `01 04 0b 01` | ⟨16 bytes, redacted⟩, first 7 bytes = `AP53002` |
| Device SN | `01 01 0b 01` | `<REDACTED>` (split across two packets) |
| Firmware version | `01 04 04 01` | `… 04 04 02 …` = 4.4.2 |
| dongle version | `06 02 03 01` | `… 04 04 02 …` = 4.4.2 |
| Battery | `01 01 02 01` | `dd 0d 1e 00 f1 01` (`0x0ddd` ≈ 3549 mV) |
| Hooks mode | `01 0b 89 01` | all 0 |
| Indicator light parameters | `01 0b 88 01` | `00 00 02 07 02 \| 0a 02 07 02 02 \| 0a 02 07 02 01 \| 0a 02 07 02 00` |
| Microphone noise reduction | `01 01 90 01` | `00 64 00 64` → for both mics, low=0 high=100 |
| All key functions | `01 06 31 01` | all 0 (unconfigured) |
| AI button function | `01 06 21 01` | all 0 |
| Motor strength | `01 06 40 01` | all 0 |
| Knob switch | `01 01 34 01` | all 0 |

### Battery Reply Fields

[CONFIRMED] The read-only request is `01 01 02 01`, with reply prefix `81 01 02 11`. Payload offsets below start at plaintext frame byte 4. Studio’s `kwdm.dylib` battery-response handler reads voltage and battery as little-endian 16-bit fields, not individual bytes.

| Payload offset | Plaintext frame offset | Field | Sample value |
|---|---|---|---|
| 0–1 | 4–5 | `voltage`, little-endian millivolts | `f6 0c` = 3318 mV |
| 2–3 | 6–7 | `battery`, little-endian percentage | `0a 00` = 10% |
| 6 | 10 | `charging`, 0 = not charging, 1 = charging | `01` = charging |

The 23:25:12 sample began `81 01 02 11 f6 0c 0a 00 c8 01 01 00 ...`, with the device online. [CONFIRMED] Studio forwards the `battery` integer directly to its battery icon, clamps the upper bound to 100, and selects levels at 10/25/50/75. The [parser and UI disassembly](evidence/2026-09-21-battery-disassembly.log) establishes the percentage scale; it is not estimated from voltage. Olanzi treats percentages outside 0–100 and charging values other than 0/1 as unknown. See [05 §9.10](05-verification-log.md#910-read-only-battery-status-and-main-window-display).

### Write Commands (⚠️ located but not yet measured)

| Name | Report bytes |
|---|---|
| **Set key shortcut function** | `01 06 50 04` + `num/pages/values/signs` |
| Set key function | `01 06 10 04` + `funcIndex` |
| Set AI button function | `01 06 21 04` + `index` |
| Set indicator light parameters | `01 0b 88 04` + `which/value` |
| Set Hooks mode | `01 0b 89 04` |
| Set brightness | `01 06 20 04` |
| Set microphone noise reduction | `01 01 90 04` + `low/high` |

---

### ⚠️ Dongle-level vs device-level (`cmd = 0x06` vs `0x01`)

`cmd` determines who handles a frame. **When troubleshooting, this is the first dividing line:**

| cmd | Handler | When the device is powered off |
|---|---|---|
| `0x06` | the **dongle** (the USB end) | ✅ still answers |
| `0x01` | the **Vibe Key itself** (over the wireless link) | ❌ no reply at all |

**Measured**: with the device powered off, `--probe` sends 17 queries and only 2 come back —
and both are `0x06` (`device online status`, `dongle version`).

### Reading the device online status

```
→ 06 03 0a 01                    query online status
← 06 03 0a 11 ⟨status⟩ 00 00 …   status = 0x01 online / 0x00 offline
```

⚠️ **Note**: this query is answered by the dongle itself, so there is **always** a reply —
what matters is the `status` byte inside it. Don't mistake "there was a reply" for "the device is online".

---

### Studio's Dedicated Heartbeat

[CONFIRMED] `+[MessageHelper deviceHeartbeatMessage]` constructs `06 01 23 00 01` followed by 59 zero bytes; Studio's background worker sends it about once per second. This differs from the old tool's Hooks query `01 0b 89 01`. The heartbeat has no verified response contract, so determine body online state from the explicit status byte above, not from heartbeat acknowledgments.

[INFERRED] Missing this heartbeat may contribute to sleep, but the measured 60-second idle and Hooks windows both ended online; prevention of longer-term sleep remains unverified. See [07 Heartbeat Investigation](07-heartbeat-investigation.md) for the disassembly and controlled-test limits.

[CONFIRMED] A later comparison on 2026-09-21 found that sustained heartbeats stop direct standard HID ordinary-key output and produce `8b 10` vendor events; stopping the heartbeat while retaining the vendor connection restored Enter. `frame[2]` is a logical action number, not a HID keycode; `frame[3]` is press/release state and `frame[4]` is the AU05 physical control index. The host should forward ordinary keys and Fn using confirmed device bindings; the new forwarding path has verified Enter and top-key Fn system effects, while full OS-action coverage of the remaining controls is still pending.

## 5. Control Mapping (confirmed by measurement)

**Verification method**: you were asked to operate the controls in a fixed order (knob press → key 1 → key 2 → key 3 → twist right ×3 → twist left ×3 → long-press knob), and we aligned that 1:1 in time against the captured event stream. The results matched exactly.

| Control | Report code | HID meaning | Notes |
|---|---|---|---|
| **Key 1 (top)** | `0x01` | ErrorRollOver | **invalid code, the system ignores it** |
| **Key 2 (middle)** | `0x28` | Enter | |
| **Key 3 (bottom)** | `0x29` | Esc | |
| **Knob twist → right** | `0x4F` | RightArrow | once per detent |
| **Knob twist ← left** | `0x2A` | Backspace | once per detent |
| **Knob press** | `0x46` | PrintScreen | emitted on both short and long press |
| **Power key** | — | — | **no report on short press** (handled by the device hardware) |

### ⭐ An Unexpected but Important Pattern

**Press duration distinguishes knob rotation from key presses:**

| Type | Duration |
|---|---|
| Knob rotation (instantaneous pulse) | **0–10 ms** |
| Human key press | **80–2000 ms** |

A threshold of **25 ms** is very reliable. This lets a program classify events without knowing the mapping in advance.

### ⚠️ Key 1 Is "Crippled"

Key 1 emits `0x01` (ErrorRollOver) — **a key code that is invalid by protocol, which the operating system simply discards**.

This is not a bug, it is **by design**: key 1 is the AI conversation key, born to serve Studio alone.
Away from Studio, **key 1 may as well not exist**.

> This explains why Ulanzi insists that users install Studio — the primary function key is lashed to its own software.
> **But this can be changed**; see the next steps below.

---

## 6. Reading and Writing Key Configuration (on-device programmable key table) ⭐

**This is the key capability for "ditching Studio": the key table inside the device can be rewritten freely.**

### Frame Format

| Operation | Report |
|---|---|
| **Read** | `→ 01 06 50 01 <index>` |
| | `← 81 06 50 11 <index> 01 <num> <type\|sign<<7> <key code> ×num` |
| **Write** | `→ 01 06 50 04 <index> 01 <num> <type\|sign<<7> <key code> ×num` |
| | `← 81 06 50 14 …` ← `access = 0x14` means write confirmation |

| Field | Meaning |
|---|---|
| `index` | control number |
| `num` | how many keys this entry contains (**key combinations supported**) |
| `type` | `0x02` = ordinary key, `0x03` = system/multimedia |
| `sign` | the top bit (bit 7) of the type byte |
| `key code` | HID Usage ID |

### index ↔ Control (factory values)

| index | Control | Factory key code |
|---|---|---|
| 0 | Key 1 (top) | `0x01` ErrorRollOver (**invalid code**) |
| 1 | Key 2 (middle) | `0x28` Enter |
| 2 | Key 3 (bottom) | `0x29` Esc |
| 3 | Knob press | `0x46` PrintScreen |
| 4 | Knob twist → right | `0x4F` RightArrow |
| 5 | Knob twist ← left | `0x2A` Backspace |

> index 6 and 7 exist but are unused.

### ⭐ Measured Verification (end-to-end loop, all four passes succeeded)

| Step | Result |
|---|---|
| 1. Read index 0 | `[0x02, 0x01]` |
| 2. Write `01 06 50 04 00 01 01 02 68` | reply `81 06 50 14 00 01 01 02 68` |
| 3. Read back index 0 | `[0x02, 0x68]` ✅ persisted |
| 4. **Press "key 1"** | **the device really emits `0x68` = F13** ✅✅ |

**Conclusion: when `type=0x02`, the second byte stores the HID keycode assigned to that control. In direct-output mode the device reports it; in heartbeat/vendor-event mode the host must look it up from the confirmed binding.**

### Command Line

```bash
python3 vibekey.py --keys                                # list the current configuration of all six controls
python3 vibekey.py --set-key 0=F13                       # change key 1 to F13
python3 vibekey.py --set-key 0=enter --set-key 2=0x04    # change several at once
```

Key codes are accepted in three forms: `0x68` / `104` / `F13` (names such as `enter`, `esc`, `lctrl` are also recognized).

### Not Yet Verified

- the actual behavior of key combinations with `num > 1` (conjecture: `[(0x02,0xE0),(0x02,0x06)]` = Ctrl+C)
- the value range of `type = 0x03` (system/multimedia)
- the semantics of the `sign` bit (bit 7)

---

## 7. Data Flow and Heartbeat Mode

```
No Studio dedicated heartbeat → direct standard HID (historically measured state)
Sustained Studio dedicated heartbeat → vendor key event → physical index into confirmed device bindings → host forwarding
```

**Historical measurement**: after Studio exited and before the replacement sent the dedicated heartbeat, the vendor channel showed no `deviceKeyEvent` during key presses. This does not establish that vendor key events require the official Studio process to be running.

[CONFIRMED] Sending the dedicated heartbeat from Olanzi also moved keys to the vendor channel, and stopping it restored direct Enter output. The early standard-HID reading method applies only to that direct-output state. A replacement client using the heartbeat must also interpret vendor events and forward keys on the host; see [07 §4](07-heartbeat-investigation.md).

---

## 8. Terminal Tool vibekey.py

Zero dependencies (Python 3 standard library + system IOKit), and it **reads none of Ulanzi Studio's files**.

```bash
cd <project directory>
python3 vibekey.py --probe --poll 2
```

| Option | Effect |
|---|---|
| `--probe` | read device state once at startup |
| `--poll 2` | read Hooks mode every 2 seconds; sleep prevention is unverified |
| `--learn` | print the raw ciphertext/plaintext of every frame |
| `--raw` | print heartbeats too |
| `--descriptor` | dump the HID report descriptor |
| `--list` | list interfaces only |
| `--log FILE` | also write events to a log (default `/tmp/vibekey-events.log`) |
| `--echo` | keep terminal echo (off by default, so injected key characters do not scramble the output) |
| `--keys` | **list the on-device key configuration** |
| `--set-key IDX=VALUE` | **change a control's HID key code** (repeatable) |
| `-t 30` | run for only 30 seconds |

Example output:

```
13:36:28.960 key    ⌨ knob press          PrintScreen     178 ms
13:36:32.822 knob   ⟳ knob twist ← left   Backspace         2 ms
13:36:33.778 knob   ⟳ knob twist → right  RightArrow        3 ms
13:36:35.209 key    ⌨ key 1 (top)         ErrorRollOver   132 ms
13:36:36.164 key    ⌨ key 2 (middle)      Enter           147 ms
13:36:36.908 key    ⌨ key 3 (bottom)      Esc              90 ms
```

### Implementation Notes (pitfalls)

1. **`IOHIDManagerOpen` cannot be used** — it requires all matching devices to be opened at once, and if any one of them fails
   (held exclusively `0xE00002C5` or lacking permission `0xE00002E2`) the entire call fails.
   → you must use `IOServiceGetMatchingServices` + `IOHIDDeviceOpen` one by one.

2. **Input Monitoring permission is a hard gate** — without permission `IOHIDDeviceOpen` returns `0xE00002E2`,
   and in that state **not a single key press is received**, yet the device still injects keys into the system.
   → the program must **fail loudly**; it must not skip silently.

3. **Key presses really do land in the focused window** — key 2 types `Enter`, key 3 types `Esc`, the knob types arrow keys/backspace.
   → `stty -echo` by default, otherwise the screen gets scrambled.

4. **Silence does not establish sleep** — `--poll` reads Hooks mode; it is not Studio's dedicated heartbeat and its ability to prevent sleep is unverified. See [07 Heartbeat Investigation](07-heartbeat-investigation.md).

5. **Two instances can open it at the same time** (both `kIOHIDOptionsTypeNone`, non-exclusive) without fighting each other.

---

## 9. Open Questions / Next Steps

### Open Questions

- whether a long press of the power key (which may power the device off) emits a report (untested, risky)
- the full semantics of notice subtypes `0x0B` / `0x0D`
- the field layout of the indicator light parameters (`00 00 02 07 02 | 0a 02 07 02 02 | 0a 02 07 02 01 | 0a 02 07 02 00`),
  apparently 3 groups (corresponding to standby / working / awaiting approval), but the byte meanings are undetermined
- the concrete value mapping from AI state → indicator light
  (`UlanziDeck::updateIndicatorLightByState` / `LedIndicator::getConfigForState`)
- the actual behavior of key combinations (`num > 1`) and of `type=0x03`

### Next Steps (ordered by value)

1. ~~Reprogram key 1~~ ✅ **done**, see Section 6
2. **Drive the indicator light** — use `setDeviceIndicatorLight*` (`01 0b 88 04`) to
   replicate the AI state lighting effects
3. **Ollama / script callbacks** — since the keys are a standard keyboard, they can drive shell scripts directly
4. **Turn it into a resident service** — replacing Studio's "AI hooks → indicator light" pipeline

---

## 10. Evidence and Artifact Locations

| Item | Path |
|---|---|
| Terminal tool | [vibekey.py](../vibekey.py) |
| TEA codec | `~/ulanzi-re/tools/tea_kwdm.py` |
| Command table (85 entries) | `~/ulanzi-re/raw/kwdm_message_builders.txt` |
| Struct layouts (109 entries) | `~/ulanzi-re/raw/kwdm_struct_layout.txt` |
| kwdm reverse engineering report | `~/ulanzi-re/findings/kwdm-protocol.md` |
| 62 MB decoded xlog | `~/ulanzi-re/raw/logs_decoded.txt` |
| Measured event log | `/tmp/vibekey-events.log` |
