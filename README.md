# olanzi · Ulanzi Vibe Key reverse engineering & open-source client

> 🌐 [中文](README.zh.md)

> Free the Ulanzi Vibe Key (AU05) from Ulanzi Studio.
> **Pure Python standard library + system IOKit — no Studio, no third-party packages.**

---

## In a sentence

The Ulanzi Vibe Key is a USB composite HID device. Ulanzi Studio wrapped a private
protocol around it, so it looked like "you must install Studio to use it". We tore that layer off:

```
✅ Read keys      standard HID keyboard reports, zero cost
✅ Remap keys     vendor channel 01 06 50 04, persisted on-device, measured working
✅ Read device state   firmware / battery / noise reduction / indicator light / SN / UUID
✅ Decrypt the private protocol   TEA-ECB, key and algorithm fully recovered, 85-command table
```

---

## Quick start

```bash
cd olanzi

# 1. Live key monitor (Ctrl-C to exit)
python3 vibekey.py --probe --poll 2

# 2. Show the key configuration stored on the device
python3 vibekey.py --keys

# 3. Remap a key (turn the topmost key into F13)
python3 vibekey.py --set-key 0=F13
```

The output looks like this:

```
13:29:21 按键   ⌨ 键 2 (中)        Enter                      400 ms
13:29:26 旋钮   ⟳ 旋钮 → 右拧       RightArrow                   4 ms
13:29:34 按键   ⌨ 旋钮 按下        PrintScreen               1220 ms
```

> ⚠️ **Keys really are injected into your focused window** (key 2 types `Enter`, key 3 types `Esc`, the knob types arrow keys / Backspace).
> The program disables terminal echo by default to keep the output clean; add `--echo` to see the typed characters again.

### Prerequisite: Input Monitoring permission

macOS needs the **Input Monitoring** permission to read the keyboard interface.

> System Settings → Privacy & Security → **Input Monitoring** → enable the terminal you use (iTerm2 / Terminal) → **restart the terminal**

Without the permission the program prints a red warning and retries automatically; once you grant it, it reconnects on its own — no need to restart the program.

---

## What's on this device

| Item | Value |
|---|---|
| Model | **AU05** (Vibe Key) |
| USB | VID `0xFFF1` / PID `0x00DD`, composite device, serial number `202606031150` |
| Firmware | 4.4.2 (dongle and device share the same version) |
| Controls | **3 keys (stacked vertically) + 1 knob + 1 power key** |
| Interface 2 | Standard HID: Consumer `0x01` / Mouse `0x02` / **Keyboard `0x03`** |
| Interface 3 | Vendor-private: Usage Page `0xFFFC`, Report ID `0x55`, TEA encryption |

**Factory key mapping** (measured and confirmed):

| Control | HID keycode | Meaning |
|---|---|---|
| Key 1 (top) | `0x01` | ErrorRollOver — **invalid code, the system ignores it outright** |
| Key 2 (middle) | `0x28` | Enter |
| Key 3 (bottom) | `0x29` | Esc |
| Knob twist → right | `0x4F` | RightArrow |
| Knob twist ← left | `0x2A` | Backspace |
| Knob press | `0x46` | PrintScreen |
| Power key | — | **sends no reports**, handled by device hardware |

> **Key 1 is "crippled"** — it sends an invalid code, so without Studio it does nothing.
> That is not a bug, it is by design: key 1 is the AI chat key, tied to the vendor's own software.
> **Now you can remap it** — see below.

---

## Capability boundary

| Handled by the device / OS | Handled by Ulanzi Studio |
|---|---|
| ✅ Key input (standard HID, injected straight into the OS) | ⬜ Indicator light effects (AI state → lighting effect) |
| ✅ Key table (we can now read and write it) | ⬜ Firmware OTA |
| ✅ Multimedia keys / mouse | ⬜ Plugin ecosystem, cloud marketplace |
| | ⬜ profile management, multi-device orchestration |

The complete phase-1 analysis is in [docs/01-ulanzi-studio-scope.md](docs/01-ulanzi-studio-scope.md).

---

## Documentation

| Document | Contents |
|---|---|
| **[01 · Studio Scope](docs/01-ulanzi-studio-scope.md)** | What Ulanzi Studio actually does, and what is not its job (phase 1) |
| **[02 · Vibe Key Protocol](docs/02-vibekey-protocol.md)** | TEA key, frame format, 85-command table, control mapping, **programmable key table** |
| **[03 · Tool Manual](docs/03-tool-manual.md)** | Every `vibekey.py` option, output interpretation, troubleshooting |
| **[04 · Methodology](docs/04-methodology.md)** | How we reversed it: reproducible steps, key breakthroughs, pitfalls |
| **[05 · Verification Log](docs/05-verification-log.md)** | All measured data on record (including failed attempts) |

> English is the default: documentation files carry no language suffix. Chinese is an opt-in alternative suffixed with `.zh.md`. Both versions are kept in strict structural sync — editing one requires updating the other.

---

## Data flow

```
                    ┌──────────────────────────────────┐
   ┌──────────┐     │         Vibe Key (AU05)          │
   │  3 keys   │────▶│  firmware reads key table → keycode  │
   │  1 knob   │     │                                  │
   └──────────┘     └────────────┬─────────────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
   ┌─────────────────────┐              ┌──────────────────────┐
   │ Interface 2 · std HID│              │ Interface 3 · vendor   │
   │ Report ID 0x03      │              │ Report ID 0x55       │
   │ plaintext kbd report │              │ TEA encrypted        │
   └──────────┬──────────┘              └──────────┬───────────┘
              │                                     │
              ▼                                     ▼
    directly injected into macOS          ┌─────────────────┐
    any program can read it                │ config read/write│
    (our tool takes this path)               │ device info query │
              │                          │  indicator light  │
              │                          │  firmware update  │
              │                          └─────────────────┘
              │                                     │
              └──────────────┬──────────────────────┘
                             ▼
                    ┌─────────────────┐
                    │  vibekey.py     │
                    │  (this project)   │
                    └─────────────────┘
                    ↑ completely bypasses Ulanzi Studio
```

> **Note**: once Studio exits, the vendor channel carries **only heartbeats**, no `deviceKeyEvent` at all.
> Keys keep working over standard HID — which is why reading keys never has to touch the private protocol.

---

## Project structure

```
olanzi/
├── AGENTS.md                    ← project memory (conventions / invariants / safety)
├── README.md / README.zh.md     ← you are here (en / zh)
├── vibekey.py                   ← terminal tool (zero dependencies, 1060 lines)
├── tools/
│   └── check_docs.py            ← bilingual documentation consistency check
└── docs/
    ├── 01-ulanzi-studio-scope.md   (+ .zh.md)
    ├── 02-vibekey-protocol.md      (+ .zh.md)
    ├── 03-tool-manual.md           (+ .zh.md)
    ├── 04-methodology.md           (+ .zh.md)
    ├── 05-verification-log.md      (+ .zh.md)
    └── evidence/
        └── 2026-09-21-key-reprogram.log
```

The raw data from the reverse-engineering process (disassembly, symbol table, 62 MB decode log, etc.) lives in `~/ulanzi-re/`
and counts as an **intermediate artifact** — it is not in this repository.

---

## Environment

| Item | Version |
|---|---|
| OS | macOS (Apple Silicon) |
| Python | 3.x (standard library only) |
| Firmware under test | Ulanzi Studio **3.3.9** / Vibe Key firmware **4.4.2** |
| Verification date | 2026-09-21 |

> The protocol may change with firmware updates. If behaviour looks wrong after an upgrade, first run `python3 vibekey.py --keys` to see whether the configuration table is still there.

---

## Roadmap

- [x] **Phase 1** — Draw the boundary of Studio's scope
- [x] **Phase 2** — Decrypt the private protocol (TEA + 85 commands + control mapping)
- [x] **Phase 3** — Terminal tool for reading keys (works without Studio)
- [x] **Phase 4** — Read and write the device's programmable key table (**remapping**)
- [ ] **Phase 5** — Drive the indicator light (AI state lighting effects)
- [ ] **Phase 6** — The replacement client itself (key → script / Ollama / window switching)
- [ ] To be verified — key combinations (`num > 1`), `type=0x03` (system / multimedia)

---

## Notes

This project is **interoperability research**: the goal is to let users run software they wrote themselves on hardware they bought themselves.
All conclusions come from observation and static analysis of **a locally purchased device**; no copy protection was cracked,
no authentication was bypassed, and no vendor code or firmware is distributed.

`vibekey.py` depends only on the system's built-in IOKit and **does not read or modify any file of Ulanzi Studio**.
