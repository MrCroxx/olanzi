# 04 · Reverse-Engineering Methodology
> 🌐 [中文](04-methodology.zh.md)

> Records **how this was reverse-engineered**, so the whole process is reproducible and auditable.
> The conclusions themselves are in [02-vibekey-protocol.md](02-vibekey-protocol.md); this document is about the process.
>
> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md)

---

## 0. Overview: three fronts

This target could not be cracked by any single technique; three fronts have to cross-validate each other:

```
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│ Static analysis     │   │ Log decryption      │   │ Runtime capture     │
│ disasm / symbols    │   │ xlog / 62 MB        │   │ HID / lsof          │
├─────────────────────┤   ├─────────────────────┤   ├─────────────────────┤
│ • algorithms & keys │   │ • message meaning   │   │ • real packets      │
│ • data structures   │   │ • data flow         │   │ • timing            │
│ • command table     │   │ • field ranges      │   │ • trigger conditions│
└──────────┬──────────┘   └──────────┬──────────┘   └──────────┬──────────┘
           │                         │                         │
           └─────────────────────────┼─────────────────────────┘
                                     ▼
                     cross-validate before concluding
```

**Lesson learned**: a conclusion from any single source can be wrong. We got burned in phase one —
the `route: "device-direct"` HTTP path looked entirely real, but it is actually **dead code**.

---

## 1. Front one: static analysis

### 1.1 Target files

| File | Description |
|---|---|
| `/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck` | Main binary, 62 MB, Qt 6, arm64, **not stripped** |
| `…/Contents/Frameworks/kwdm.dylib` | **Kehwin SDK** — the library that actually talks to the USB device, ObjC, universal |

### 1.2 The first step is always the symbol table

```bash
nm -arch arm64 UlanziDeck > symbols.txt
nm -arch arm64 kwdm.dylib > kwdm_symbols.txt

# the main binary has 64,681 demangled symbols — essentially the source code
```

**Not being stripped + ObjC is enormous luck.** ObjC method names, class names and selectors are all in
the symbol table; a name like
`+[MessageHelper setDeviceButtonShortcutFunctionMessage:num:pages:values:signs:]`
tells you outright how many parameters there are and what they are called.

```bash
# ObjC metadata: classes / methods / protocols
otool -arch arm64 -ov kwdm.dylib > kwdm_objc.txt

# the __cstring section: string literals
strings -a kwdm.dylib > kwdm_strings.txt
```

### 1.3 Disassembly: don't use objdump

Pitfall log:

```bash
# ❌ none of these worked (LLVM objdump mishandles Mach-O address ranges)
objdump --macho --disassemble --start-address=0x1f398 --stop-address=0x1f46c kwdm.dylib
objdump --macho --disassemble --disassemble-symbols='+[MessageHelper ...]' kwdm.dylib
```

✅ **Use lldb — it can pinpoint code by symbol name**:

```bash
lldb -b \
  -o "target create --arch arm64 kwdm.dylib" \
  -o "disassemble -n '+[MessageHelper setDeviceButtonShortcutFunctionMessage:num:pages:values:signs:]'" \
  -o "quit"
```

Output:

```
kwdm.dylib[0x1f3c8] <+48>:  mov    w8, #0x601
kwdm.dylib[0x1f3cc] <+52>:  movk   w8, #0x450, lsl #16    ; w8 = 0x04500601
kwdm.dylib[0x1f3d0] <+56>:  str    w8, [sp, #0x48]        ; → frame header 01 06 50 04
```

> 💡 **Tip**: an immediate value assembled from `mov` + `movk`, **stored little-endian, is the frame
> header**. `0x04500601` → `01 06 50 04` — it lines up at a glance.

### 1.4 Bulk-extracting the command table from the builder methods

Every method in the `+[MessageHelper xxxMessage]` family assembles a 4-byte frame header.
So write a script to disassemble them in bulk and extract with a regex:

```bash
python3 tools/extract_opcodes.py     # → raw/kwdm_message_builders.txt
```

85 entries came out: `name | builder opcode | frame-header bytes | argument registers`. For example:

```
getDeviceAllButtonFuncMessage          0x01310601  01 06 31 01  str w8@8
setDeviceButtonShortcutFunction…       0x04500601  01 06 50 04  str w8@72, strb w2@76 …
```

> ⚠️ Some methods failed extraction (they show up as `01 00 00 00`), so **they must be confirmed by
> hand-disassembly** — that is exactly how the setter was missed, and how lldb recovered it.

---

## 2. Front two: log decryption (xlog)

Ulanzi Studio writes its logs with Tencent's **mars xlog**. Getting the plaintext logs is equivalent
to getting the **product requirements document**.

### 2.1 Find the source code first

The vendor shipped part of the mars source code **verbatim** inside the app:

```
~/Library/Application Support/Ulanzi/…/log_base_buffer.cc
                                 log_zlib_buffer.cc
                                 mars_log_crypt.cc
                                 mars_log_magic_num.h
```

**This is a gold mine.** `mars_log_magic_num.h` hands you the magic number directly, and
`mars_log_crypt.cc` hands you the encryption algorithm.

### 2.2 File format

```
[73-byte header][records...]
```

The header has one byte that flags the compression method; `0x09` = **raw DEFLATE**.

```python
import zlib
d = zlib.decompressobj(-15)      # -15 = raw deflate, no zlib header
plain = d.decompress(payload)
```

> 💡 **Key point**: `-15` (raw), not `15`/`31`. Use the wrong one and you keep getting
> `invalid header`.

**Result**: all 223/223 records decoded → a **62 MB plaintext log**.

### 2.3 What was dug out of the logs

```bash
python3 -c "
import re, collections
c = collections.Counter()
for line in open('logs_decoded.txt', errors='ignore'):
    for m in re.finditer(r'\"type\"\s*:\s*\"(\w+)\"', line):
        c[m.group(1)] += 1
print(c.most_common(20))
"
```

JSON vocabulary of device→app messages (4 days of data):

| type | count | meaning |
|---|---|---|
| `deviceKeyEvent` | 3893 | **key event, with the physical index** |
| `deviceBattery` | 1784 | battery |
| `deviceButtonShortcutFunction2` | 1580 | key shortcut function |
| `deviceActive` | 440 | online |
| `deviceHooksMode` | 424 | AI hooks mode |
| `deviceIndicatorLightAllParams` | 348 | indicator light parameters |
| `deviceMicNRLevel` | 148 | microphone noise reduction |
| … | | |

**The format of `deviceKeyEvent` is absolutely critical**:

```json
{ "status": 1, "access": 2, "type": "deviceKeyEvent", "index": 5 }
```

`index` is the **physical control number** — exactly what a replacement client wants most.

> ⚠️ The JSON in the logs is **escaped** (`\"index\"`), so the regex has to be written
> `\\"index\\"`. The first time I searched for `"index"` I got 0 hits and wasted half an hour.

### 2.4 The full call chain (read out of the logs)

```
deviceKeyEvent{index:3}
  → handleKeyEvent
  → UlanziDeck::onDialKeyPressed
  → ProfilePresenter::onDialEvent
  → onActionTriggered("com.ulanzi.ulanzideck.system.hotkey")
  → ActionManager::OnTriggerAction
  → HotkeyParser::parse("F13")
  → InputSimulator::KeyDownEx(105, flags 256)
```

**This chain proves that what Studio does on a key press is nothing but "inject the key once
more".** No other magic involved.

---

## 3. Front three: runtime capture

### 3.1 Enumerating HID devices

```python
# IOKit: find the device by VID/PID, then pull out its elements one by one
matching = IOServiceMatching(b"IOHIDDevice")
CFDictionarySetValue(matching, "VendorID", 0xFFF1)
CFDictionarySetValue(matching, "ProductID", 0x00DD)
```

Once you have an interface, reading `PrimaryUsagePage` / `PrimaryUsage` tells you which channel it is:

| Usage Page | Purpose |
|---|---|
| `0x000C` | standard HID (keyboard / multimedia / mouse) |
| `0xFFFC` | **vendor private** |

### 3.2 ⚠️ Pitfall one: `IOHIDManagerOpen` is all-or-nothing

```c
IOHIDManagerOpen(mgr, 0);   // ❌ if even one matching device fails to open, the whole call fails
```

Error code `kIOReturnExclusiveAccess (0xE00002C5)`.

**The nastier part**: the cause of that error was **my own capture process holding the device**,
yet it looked like a permissions problem, and I chased it for a long time.

✅ **The right way: open them one at a time**

```c
IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it);
while ((svc = IOIteratorNext(it))) {
    IOHIDDeviceRef dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
    IOReturn rc = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    // check each one separately; they don't affect each other
}
```

### 3.3 Pitfall two: input monitoring permission

`IOHIDDeviceOpen` returns `kIOReturnNotPermitted (0xE00002E2)` = **no input monitoring permission**.

**The most insidious part**: at this point the device **is still injecting keys into the system**
(press anything and it types it), but your program **receives not a single report**. If the program
silently skips the interfaces that failed, the symptom is "I press and nothing happens — but the key
really does fire" — extremely hard to pin down.

> **Lesson**: **a permission failure must fail loudly**; never silently degrade.

### 3.4 Pitfall three: report length

- The keyboard report callback receives **8 bytes** (`mods + reserved + 6×keycode`)
- The vendor report receives **63 bytes** (excluding the report ID)
- But the descriptor declares `0x55` + 63 bytes

Once a report callback is registered, IOKit **strips the report ID** (depending on how you register).
Measured `len=63`; the first 63 bytes are the ciphertext, so just decrypt them.

---

## 4. Breakthrough: the TEA key

### 4.1 How it was found

Search the global symbols for anything key-related:

```bash
nm -arch arm64 kwdm.dylib | grep -i "encrypt\|key\|crypt"
# → _gaui_custom_encrypt_keys
```

It resolves to `__DATA,__data+0x4a580` (arm64); dumping 16 bytes gives:

```
ca ba a5 ca 6d 8a 2a bc ba 9e 5a ca ca 8b b8 9b
```

### 4.2 How it was confirmed to be TEA

Disassemble the encrypt/decrypt functions:

```asm
_encode:                          ; 0x27790
  mov  w8, #0x79b9
  movk w8, #0x9e37, lsl #16       ; delta = 0x9E3779B9  ← TEA signature
  mov  w13, #0x20                 ; 32 rounds
  ldp  w9, w10, [x0]              ; v0, v1
  ldp  w11, w12, [x1]             ; k0, k1
  ldp  w15, w16, [x1, #0x8]       ; k2, k3
  ...

_decode:                          ; 0x277f4
  mov  w12, #0x3720
  movk w12, #0xc6ef, lsl #16      ; sum start = 0xC6EF3720  ← TEA decryption
  mov  w14, #0x8647
  movk w14, #0x61c8, lsl #16      ; -delta = 0x61C88647
```

`0x9E3779B9` / `0xC6EF3720` are the textbook TEA constants. **But note it is not XTEA**
(there is no `>> 11` step).

### 4.3 ⭐ The decisive verification

Every captured report always ends with the same string of **identical bytes**:

```
... 38 90 c4 99 a3 60 aa ad  38 90 c4 99 a3 60 aa ad ...
```

At first I took it for a "fixed tail" or some kind of magic. Then I tried a hunch:

```python
TEA_ECB_Enc(b"\x00"*8, key)  ==  b"\x38\x90\xc4\x99\xa3\x60\xaa\xad"   # ✅
```

**That "mystery constant" is simply the ciphertext of an all-zero block.** The second half of the
plaintext frame is all 0s, so the ciphertext repeats.

> **In that moment the whole protocol clicked.** Every earlier "strange unchanging byte" suddenly
> made sense.
>
> **Methodology**: when you meet "strange fixed bytes", first suspect that **they are the encryption
> of a known input**, rather than hunting for their meaning as a constant.

### 4.4 The side effect of ECB

Because it is ECB (no IV, no chaining), **identical plaintext blocks produce identical ciphertext
blocks**. That is also why we can spot long runs of 0s in the plaintext at a glance — for analysis,
this is actually a **good thing**.

### 4.5 Deriving 63 vs 64

The struct is 64 bytes; encrypting 64 bytes = 8 blocks.
But the report carries only 64 bytes (including the 1-byte report ID).

```
63 bytes on the wire = ct[0..62] = 7 full blocks + the first 7 bytes of the 8th block
```

**Conclusion**: only 7 blocks (56 bytes) are decrypted; the last 7 bytes are undecryptable padding.

**Verification**: the decrypted plaintext frame header `81 0b 89 11 …` is entirely plausible, and the
trailing 7 bytes are meaningless. ✅

---

## 5. Breakthrough: the control mapping

This is the **methodologically most valuable** section — because it was designed purely by experiment.

### 5.1 The approach that failed

Poke the device at random and then look at what got captured. **Result: nothing matched up.**

Reason: with 6 controls and several key codes, random pressing cannot establish a correspondence.
Worse, I spent a while reasoning from a "4 keys + knob" model, so **the direction was wrong all
along** (there are actually 3 keys).

> 💡 **The user's on-site observations are irreplaceable.** It was the user telling me "there are only
> three keys, stacked vertically" that made all the earlier inferences line up.

### 5.2 The approach that worked: a controlled, ordered experiment

Design an operation sequence that is **strictly ordered, with a gap between every step**:

> knob press → key 1 → key 2 → key 3 → twist right ×3 → twist left ×3 → long-press knob

Then align it **1:1** against the timeline:

| Time | Your action | Device emits |
|---|---|---|
| 13:29:20.180 | knob press | `0x46` (300ms) |
| 13:29:21.095 | key 1 | `0x01` (320ms) |
| 13:29:21.980 | key 2 | `0x28` (400ms) |
| 13:29:22.760 | key 3 | `0x29` (260ms) |
| 13:29:26.079/444/985 | twist right ×3 | `0x4F` ×3 |
| 13:29:29.414/831/30.215 | twist left ×3 | `0x2A` ×3 |
| 13:29:34.459 | long-press knob | `0x46` (1220ms) |

**7 actions, 7 events, matching exactly in order and count.** At that point the mapping was beyond
dispute.

### 5.3 A bonus finding: classifying by duration

While aligning, I noticed:

```
0x2A → 4ms, 7ms, 6ms, 7ms, 6ms, 4ms …     ← knob twist
0x28 → 126ms, 105ms, 99ms, 140ms …        ← human press
```

**A knob twist is an instantaneous pulse (<10ms); a key press is a human press (>80ms).**

That rule lets a program classify events automatically **without knowing the mapping** — it is now
baked into the `INSTANT_MS = 25` threshold in `vibekey.py`.

> **Methodology**: physical characteristics (duration, frequency, timing) are often easier to use for
> telling sources apart than the data content itself.

### 5.4 Confirmation from the other direction

After obtaining the mapping, I also read the **official configuration table** out of the device (see
the next section); the values for `index 0..5` are `01 28 29 46 4f 2a` — **exactly what the
experiment had derived**.

**Two-way verification passed.**

---

## 6. Breakthrough: the programmable key table

### 6.1 The entry point: the user's hunch

The user suggested:

> "You can adjust what these keys do inside Studio. My guess is that it changes the HID it sends at
> that moment."

That hunch **pointed straight at the right direction** and saved a great deal of blind searching.

### 6.2 Locating it by static analysis

From the command table:

```
getDeviceButtonShortcutFunctionMessage:      01 06 50 01
setDeviceButtonShortcutFunctionMessage:…     (extraction failed, needs hand-work)
```

Hand-disassembling the setter with lldb reveals the **byte-by-byte framing logic**:

```asm
mov    w8, #0x601
movk   w8, #0x450, lsl #16     ; 0x04500601 → 01 06 50 04
str    w8, [sp, #0x48]
strb   w2, [sp, #0x4c]         ; frame[4] = index
strb   w8=1, [sp, #0x4d]       ; frame[5] = 1 (constant)
strb   w3, [sp, #0x4e]         ; frame[6] = num
loop:
  ldrb   w10, [x4], #1         ; page  = *pages++
  ldrb   w11, [x5], #1         ; value = *values++
  strb   w11, [x9]             ; frame[8+2i]   = value
  ldrb   w11, [x6], #1         ; sign  = *signs++
  bfi    w10, w11, #7, #25     ; page |= (sign & 1) << 7
  sturb  w10, [x9, #-0x1]      ; frame[7+2i]   = page | sign<<7
  add    x9, x9, #2
```

> **Note `sturb w10, [x9, #-0x1]`** — it writes `frame[7]`, not `frame[8]`. Miss that offset and the
> entire format is off by one byte.

### 6.3 Reading the real format back from the device

Rather than guess, **just ask the device**:

```python
for i in range(8):
    send_frame(hs, bytes([0x01,0x06,0x50,0x01,i]))   # read index i
```

Replies:

```
index 0 → 81 06 50 11 | 00 | 01 01 02 01
index 1 → 81 06 50 11 | 01 | 01 01 02 28
index 2 → 81 06 50 11 | 02 | 01 01 02 29
index 3 → 81 06 50 11 | 03 | 01 01 02 46
index 4 → 81 06 50 11 | 04 | 01 01 02 4f
index 5 → 81 06 50 11 | 05 | 01 01 02 2a
index 6 → 81 06 50 11 | 06 | 00 …            ← 未使用
```

**The static analysis and the device replies match byte for byte.** Two independent lines of evidence
cross-confirm each other.

### 6.4 End-to-end closed-loop verification

**This is the most convincing step** — not settling for "it was written", but proving that "the device
really does send the key according to the new configuration":

| Step | Result |
|---|---|
| 1. Read the original value | `[0x02, 0x01]` |
| 2. Write `01 06 50 04 00 01 01 02 68` | reply `81 06 50 14 …` (access `0x14` = write confirmation) |
| 3. Read back | `[0x02, 0x68]` ✅ persisted |
| 4. **The user presses the real key** | **the device emits `0x68` = F13** ✅✅ |

**Why `index 0` was chosen**: it was originally the invalid code `0x01`, so changing it **cannot break
any functionality**; it is the safest possible test target. It was restored immediately after the
test.

> **Methodology**: when verifying a write, **prefer a target where breaking it does not matter**, and
> **make sure it can be restored with a single command**.

### 6.5 TEA confirmed along the way

Disassembling `_encode` / `_decode` (0x27790 / 0x277f4) shows `delta = 0x9E3779B9`,
`sum = 0xC6EF3720` and 32 rounds — **exactly consistent with what was inferred from the ciphertext**.

---

## 7. Methodology summary

### 7.1 Techniques that worked (ranked by return on effort)

| Technique | Why it works |
|---|---|
| **Read the symbol table** | unstripped binary + ObjC ⇒ method names tell you outright what the code does |
| **Find the bundled source** | vendors often ship third-party library source along with the app (mars did) |
| **Decrypt the logs** | plaintext logs = free product documentation + a data dictionary |
| **Cross-validate** | static + dynamic + device replies must all agree before you conclude |
| **Ask the device** | if it can be read, read it. 10× faster than guessing from disassembly |
| **Controlled ordered experiment** | the only reliable way to build an "action ↔ data" mapping |
| **End-to-end closed loop** | "the write succeeded" ≠ "it took effect". Observe the final behaviour |

### 7.2 Key mental models

1. **A "strange constant" is often the encryption of a known input** — the ciphertext of an all-zero block broke the whole protocol open
2. **Physical characteristics (duration / frequency) classify better than content** — knob vs key
3. **Failures must be loud** — a silently degraded permission failure wastes hours
4. **The user is a sensor** — "there are only three keys" was worth more than a pile of disassembly
5. **Pick a safe test target** — remap a key that was already useless
6. **Dead code lies** — the `device-direct` HTTP path looks real, but it is leftover garbage

### 7.3 Judging the strength of evidence

The annotation convention from the phase-one report is worth carrying forward:

| Tag | Meaning |
|---|---|
| **[CONFIRMED]** | direct evidence: a measurement, a binary literal, or a device reply |
| **[INFERRED]** | inferred from indirect evidence, **to be verified** |

**Never write your own inference down as a conclusion.** In phase one, `device-direct` was recorded
as a conclusion and was later overturned.

---

## 8. Pitfalls (complete list)

| # | Pitfall | Symptom | Truth |
|---|---|---|---|
| 1 | `IOHIDManagerOpen` all-or-nothing | `0xE00002C5` | **my own capture process** was holding the device |
| 2 | input monitoring permission | keys fire but nothing is captured | `0xE00002E2`, not "device busy" |
| 3 | silently skipping failed interfaces | "I press and nothing happens" | it must fail loudly |
| 4 | xlog decompression parameter | `invalid header` | you need `zlib.decompressobj(-15)` (raw) |
| 5 | escaped JSON in the logs | regex gets 0 hits | it is actually `\"index\"` |
| 6 | `objdump` address ranges | dumps everything | switch to `lldb disassemble -n <symbol>` |
| 7 | extraction script missed an opcode | the setter shows `01 00 00 00` | recovered by hand-disassembly |
| 8 | misread frame offset | format off by one byte | `sturb w10, [x9, #-0x1]` writes `frame[7]` |
| 9 | wrong key model | the mapping never lined up | there are actually **3 keys**, not 4 |
| 10 | terminal echo | output scrambled by injected keys | `stty -echo` + write a log file |
| 11 | macOS has no `timeout` | the script errors out | use a Python socket timeout / sleep yourself |
| 12 | using `grep` on a 62 MB log | `maximum repetition exceeds 255` | use Python `re` |
| 13 | correlating logs with captures after the fact | the timestamps don't line up | xlog **flushes lazily**; don't expect real-time alignment |
| 14 | keys are injected into the focused window | your editor gets random keystrokes | keep the terminal in front, or remap the key to F13+ |
| 15 | **exceptions thrown inside a ctypes callback are silently swallowed** | `--probe` reports "device offline" while `--keys` still reads fine | I referenced `self.xxx` inside a `@staticmethod` → `NameError`. ctypes prints one `Exception ignored` line and carries on — **the symptom is identical to a genuinely powered-off device** |
| 16 | judging "offline" only by whether a reply arrived | misdiagnoses a code bug as a hardware problem | you must look at the **raw plaintext**: truly offline gives `06 03 0a 11` **`00`** (status=0x00), while a code bug prints **nothing at all** |

---

## 9. Reproduction guide

To redo the whole thing from scratch:

```bash
# ── setup ──
mkdir -p ~/ulanzi-re/{raw,findings,tools}

# ── 1. static analysis ──
nm -arch arm64 "/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck" > raw/symbols.txt
nm -arch arm64 "/Applications/Ulanzi Studio.app/Contents/Frameworks/kwdm.dylib" > raw/kwdm_symbols.txt
otool -arch arm64 -ov "/Applications/Ulanzi Studio.app/Contents/Frameworks/kwdm.dylib" > raw/kwdm_objc.txt

# ── 2. pinpoint a method ──
lldb -b -o "target create --arch arm64 \
  '/Applications/Ulanzi Studio.app/Contents/Frameworks/kwdm.dylib'" \
  -o "disassemble -n '+[MessageHelper getDeviceAllButtonFuncMessage]'" -o quit

# ── 3. find the TEA key ──
#    nm | grep encrypt  →  _gaui_custom_encrypt_keys
#    objdump -s --section=__data kwdm.dylib  → 16 bytes starting at offset 0x4a580

# ── 4. decode xlog ──
#    see the mars_* sources under ~/Library/Application Support/Ulanzi/
#    header is 73 bytes, 0x09 → zlib.decompressobj(-15)

# ── 5. capture HID ──
python3 vibekey.py --learn --raw -t 30

# ── 6. build the mapping (controlled experiment) ──
#    operate in a fixed order and time-align against the event stream
```

### Artifacts of this reverse-engineering effort

| Item | Path |
|---|---|
| Main binary symbols (64,681) | `~/ulanzi-re/raw/symbols.txt` |
| kwdm symbols / ObjC / disassembly | `~/ulanzi-re/raw/kwdm_*` |
| **Command table (85 entries)** | `~/ulanzi-re/raw/kwdm_message_builders.txt` |
| Struct layouts (109 entries) | `~/ulanzi-re/raw/kwdm_struct_layout.txt` |
| **Decoded 62 MB log** | `~/ulanzi-re/raw/logs_decoded.txt` |
| kwdm protocol report | `~/ulanzi-re/findings/kwdm-protocol.md` |
| Main-binary capability surface | `~/ulanzi-re/findings/binary-surface.md` |
| ustudio-cli analysis | `~/ulanzi-re/findings/ustudio-cli.md` |
| TEA reference implementation | `~/ulanzi-re/tools/tea_kwdm.py` |
| opcode extraction script | `~/ulanzi-re/tools/extract_opcodes.py` |
