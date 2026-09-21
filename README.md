# olanzi · A lightweight Ulanzi device workspace

> 🌐 [中文](README.zh.md)

> 📚 Docs set: [01 Scope](docs/01-ulanzi-studio-scope.md) · [02 Protocol](docs/02-vibekey-protocol.md) · [03 Tool Manual](docs/03-tool-manual.md) · [04 Methodology](docs/04-methodology.md) · [05 Verification Log](docs/05-verification-log.md) · [06 Workspace](docs/06-local-workspace.md) · [07 Heartbeat](docs/07-heartbeat-investigation.md) · [08 Mac Fn](docs/08-mac-fn.md) · [09 Native macOS](docs/09-native-macos.md) · [10 Input Runtime](docs/10-input-runtime.md)

> A lightweight Studio alternative for Ulanzi devices, starting with Vibe Key (AU05) key configuration.
> **Native SwiftUI + AppKit menu-bar app using IOKit / CoreGraphics directly; the main app needs no Python, browser, or HTTP service.**

---

## In a sentence

Olanzi is an extensible native macOS device workspace, offering Studio-style device management in a lightweight menu-bar app. The first modules provide VIA-inspired visual key configuration, background heartbeats, and Fn key assignments; further capabilities follow verified protocol support. The Python web prototype and reverse-engineering tools remain as research references.

The Ulanzi Vibe Key is a USB composite HID device. Ulanzi Studio wrapped a private
protocol around it, so it looked like "you must install Studio to use it". We tore that layer off:

```
✅ Read keys      standard HID in direct-output mode; vendor events in Studio-heartbeat mode
✅ Remap keys     vendor channel 01 06 50 04, persisted on-device, measured working
✅ Read device state   firmware / battery / noise reduction / indicator light / SN / UUID
✅ Decrypt the private protocol   TEA-ECB, key and algorithm fully recovered, 85-command table
```

---

## Quick start

### Native macOS app

Requires macOS 14 or later and a Swift 6 toolchain; the source uses Swift 5 language mode. Build and open from the repository root:

```bash
make dev
```

`make release` builds and signs the Release app and packages `build/Olanzi-<version>-<arch>.dmg`; `make dmg` is an alias. Open the DMG and drag Olanzi into Applications to install. The disk image uses the same signing certificate as the app; this local signing is not Apple notarization.

`make dev` builds and opens a Debug version through the existing packaging script, producing `build/Olanzi.app`. The main app has a complete SwiftUI keymap interface and AppKit menu bar; it needs no Python process, browser, or local HTTP service. Quit official Studio and any legacy tool holding the device, plug in the receiver, turn on Vibe Key, then select a control, edit its keycode, and apply in the app.

Configure six actions: three keys plus knob press, right twist, and left twist. Each push control supports a primary action and optional double-press/long-press actions; rotary ticks remain immediate. Normal edits save an atomic host map without rewriting device keycodes. Macros, multimedia, and lighting remain outside this implementation. Closing the window leaves the menu-bar app maintaining its device connection, heartbeats, and key forwarding through the saved host map; quit through the menu to stop it. No login item or boot service is installed.

```bash
# Isolated demo without real hardware access
swift run --package-path native Olanzi --demo

# Native core tests
swift test --package-path native
```

Studio heartbeats switch keys to the vendor-event path, so both ordinary keys and Fn need host forwarding through the saved host map and Input Monitoring plus Accessibility permissions for **Olanzi App**. Select **Fn** in the modifier category and apply; no additional switch is needed, and drafts do not affect forwarding. Fn uses device keycode `0x01`, also assigned to the factory top key. Keep the app path and signing certificate stable; identity changes may require renewed authorization. The earlier vendor-forwarding build was physically verified with Enter and Doubao Fn; the new runtime architecture, migration, gesture rules, and checks are documented in [10 · Daemon Input Runtime](docs/10-input-runtime.md).

See **[09 · Native macOS App](docs/09-native-macos.md)** for builds, menu-bar lifecycle, permissions, and verification limits. The old Python/browser prototype and daemon instructions remain in [06 · Legacy Local Workspace Prototype](docs/06-local-workspace.md), rather than serving as the main app entry point. See [08 · Mac Fn](docs/08-mac-fn.md) for the underlying mechanism.

### Existing terminal tool

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

### Terminal key monitoring prerequisite: Input Monitoring permission

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
| Key 1 (top) | `0x01` | ErrorRollOver — **ignored natively by the OS**; the native app automatically uses it as the Fn trigger from confirmed mappings |
| Key 2 (middle) | `0x28` | Enter |
| Key 3 (bottom) | `0x29` | Esc |
| Knob twist → right | `0x4F` | RightArrow |
| Knob twist ← left | `0x2A` | Backspace |
| Knob press | `0x46` | PrintScreen |
| Power key | — | **sends no reports**, handled by device hardware |

> **Key 1 is "crippled"** — it sends an invalid code, so without Studio it does nothing.
> That is not a bug, it is by design: key 1 is the AI chat key, tied to the vendor's own software.
> **Now you can remap it**, or retain that keycode for automatic Fn conversion by the native app once permissions are granted. Vendor events select bindings by physical control index rather than using the old standard-HID prototype's same-code identification.

---

## Capability boundary

| Handled by the device / OS | Handled by Ulanzi Studio |
|---|---|
| ✅ Direct standard HID without Studio heartbeat; host forwarding in heartbeat mode | ⬜ Indicator light effects (AI state → lighting effect) |
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
| **[06 · Legacy Local Workspace Prototype](docs/06-local-workspace.md)** | Retained Python/browser prototype, profiles, and daemon instructions |
| **[07 · Heartbeat Investigation](docs/07-heartbeat-investigation.md)** | Official heartbeat command, online state, and sleep-prevention verification |
| **[08 · Mac Fn](docs/08-mac-fn.md)** | Fn mechanism, legacy Python implementation record, and verification limits |
| **[09 · Native macOS App](docs/09-native-macos.md)** | Current entry point: Swift build, menu bar, permissions, and verification limits |
| **[10 · Input Runtime](docs/10-input-runtime.md)** | Host-owned actions, double/long presses, persistence and migration |

> English is the default: documentation files carry no language suffix. Chinese is an opt-in alternative suffixed with `.zh.md`. Both versions are kept in strict structural sync — editing one requires updating the other.

---

## Original reverse-engineering tool data flow

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

> **Scope update**: the diagram and early standard-HID capture describe the historical state without Studio's dedicated heartbeat. On 2026-09-21, Olanzi heartbeats switched keys to vendor `8b 10` events, and stopping them restored direct Enter output; ordinary keys also need host forwarding. The old Hooks query is not this heartbeat, and sleep-prevention causality still requires independent testing. See [07 · Heartbeat Investigation](docs/07-heartbeat-investigation.md).

---

## Project structure

```
olanzi/
├── AGENTS.md                    ← project memory (conventions / invariants / safety)
├── README.md / README.zh.md     ← you are here (en / zh)
├── native/
│   ├── Package.swift           ← macOS 14+, Swift 6 toolchain / Swift 5 language mode
│   ├── Sources/OlanziCore/     ← TEA, IOKit, CoreGraphics, and background thread
│   ├── Sources/OlanziApp/      ← SwiftUI interface and AppKit menu bar
│   └── Tests/                  ← native core tests
├── vibekey.py                  ← reverse-engineering terminal tool (zero third-party dependencies)
├── olanzi*.py / web/ / tests/   ← retained legacy Python/browser prototype and tests
├── tools/
│   ├── build-macos.sh          ← builds build/Olanzi.app
│   └── check_docs.py           ← bilingual documentation consistency check
└── docs/
    ├── 01-ulanzi-studio-scope.md   (+ .zh.md)
    ├── 02-vibekey-protocol.md      (+ .zh.md)
    ├── 03-tool-manual.md           (+ .zh.md)
    ├── 04-methodology.md           (+ .zh.md)
    ├── 05-verification-log.md      (+ .zh.md)
    ├── 06-local-workspace.md       (+ .zh.md)
    ├── 07-heartbeat-investigation.md (+ .zh.md)
    ├── 08-mac-fn.md                (+ .zh.md)
    ├── 09-native-macos.md          (+ .zh.md)
    └── evidence/
        └── 2026-09-21-key-reprogram.log
```

The raw data from the reverse-engineering process (disassembly, symbol table, 62 MB decode log, etc.) lives in `~/ulanzi-re/`
and counts as an **intermediate artifact** — it is not in this repository.

---

## Environment

| Item | Version |
|---|---|
| Native app OS | macOS 14 or later |
| Native toolchain | Swift 6 (Swift 5 language mode) |
| Legacy research tools | Python 3.x (standard library only; not required by the main app) |
| Firmware under test | Ulanzi Studio **3.3.9** / Vibe Key firmware **4.4.2** |
| Verification date | 2026-09-21 |

> The protocol may change with firmware updates. If behaviour looks wrong after an upgrade, first run `python3 vibekey.py --keys` to see whether the configuration table is still there.

---

## Roadmap

- [x] **Phase 1** — Draw the boundary of Studio's scope
- [x] **Phase 2** — Decrypt the private protocol (TEA + 85 commands + control mapping)
- [x] **Phase 3** — Terminal tool for reading keys (works without Studio)
- [x] **Phase 4** — Read and write the device's programmable key table (**remapping**)
- [x] **Phase 5** — Python local workspace prototype (retained as a research reference)
- [x] **Phase 6** — Native Swift menu-bar app (keymap interface, background heartbeats, Fn assignments)
- [ ] **Next** — Extend lighting, automation, and other Studio capabilities as their protocols are verified
- [ ] To be verified — key combinations (`num > 1`), `type=0x03` (system / multimedia)

---

## Notes

This project is **interoperability research**: the goal is to let users run software they wrote themselves on hardware they bought themselves.
All conclusions come from observation and static analysis of **a locally purchased device**; no copy protection was cracked,
no authentication was bypassed, and no vendor code or firmware is distributed.

`vibekey.py` depends only on the system's built-in IOKit and **does not read or modify any file of Ulanzi Studio**.
