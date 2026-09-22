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

`make dev` builds and opens a Debug version through the existing packaging script, producing `build/Olanzi.app`. The main app has a complete SwiftUI keymap interface and AppKit menu bar; it needs no Python process, browser, or local HTTP service. Quit official Studio and any legacy tool holding the device, plug in the receiver, turn on Vibe Key, then select a control, choose its action, and save it to this Mac.

The interface supports English and Simplified Chinese. Open Settings from the main window’s top navigation or the macOS application menu (`Cmd-,`) to choose Follow System, English, or Simplified Chinese; the permission welcome page also has a language selector. Follow System is the default and falls back to English for unsupported system languages. Changes take effect immediately and are remembered without restarting, changing key mappings, or discarding drafts. User-defined profile names and file paths remain unchanged.

The Keymap page keeps device and gesture selection above the key picker. Its lower area has eight categories: Common, Characters, Function Keys, Numpad, Combinations, Layer, Apps, and Macros. Common includes navigation and modifier keys; Characters combines letters, digits, and symbols. The right side displays selectable keycaps, and search covers all keys. Record a simultaneous combination in Combinations, then choose **Assign Shortcut** to update the selected gesture draft. Save to this Mac to activate it. Recording one combination ends when all keys are released; continuous macro recording is available separately in the macro editor.

Configure six controls: three keys plus knob press, right twist, and left twist. Each push control supports primary, double-press, and long-press actions. Gesture selection determines when an action triggers; its keyboard output mode independently determines how many times it is sent. Each gesture can use **Tap Once** or **Repeat**, with a separate repeat count of 2–20 (default 2). Primary and long-press keyboard actions also offer **Hold**: a primary-only hold follows physical press/release, while a long hold starts at its threshold and ends on release. If a primary has optional gestures, it waits for recognition and Hold emits one pulse when recognized. Double press and rotary ticks offer Tap Once and Repeat because they do not provide a continuing physical hold after recognition. A triggered repeat group finishes after physical release; continuing to hold does not restart it. Existing long-press modes and counts remain compatible. App switches, macros, and MO do not use these keyboard output options. New primary, double-press, and rotary repeat behavior still requires physical verification. Normal edits save an atomic host map without rewriting device keycodes. Application switching and macros also run on the host; multimedia and lighting remain outside this implementation. Closing the window leaves the menu-bar app maintaining its device connection and, while keepalive is active, heartbeats and key forwarding through the saved host map; quit through the menu to stop it. No login item or boot service is installed.

The keymap supports four fixed momentary layers, shown as **0 1 2 3** in one row above the device. Layer 0 is the base; layers 1–3 inherit by default and need no setup before editing. Click a number to edit that layer and override only the gestures that should change. Unset controls inherit all gestures from lower active layers and ultimately Layer 0. The key picker always includes **▽** and a **rounded square with a cross (`xmark.square`)** (No Action): on a non-base layer, ▽ restores inheritance only for the selected gesture, including its output mode and repeat count, while keeping the other gestures unchanged. The crossed-square keycap makes a primary action a no-op or disables the selected double/long gesture, overriding any lower-layer action. Layer 0 cannot inherit. Inherited primary/double/long actions and both rotary directions display a VIA-style downward triangle, with hover and accessibility text identifying inheritance. These keycaps replace separate clear-action and restore-inheritance buttons. For example, click **1** and assign key 2 and knob rotation, then click **0** and set key 1's primary action to **MO(1)** in the Layer category. After **Save to This Mac**, holding key 1 immediately enables Layer 1 for other controls; releasing key 1 restores the remaining active layers. MO can be assigned to a push control's primary or long-press action. Primary MO activates immediately, clears only double press, and preserves a separately configured long action. That long action runs at its threshold; releasing the control immediately exits its primary MO layer even if a keyboard repeat group continues. With an ordinary primary action and long-press MO, a short press uses the primary action, while reaching the threshold holds the target layer until release and suppresses the primary action. If both actions are MO, the threshold replaces this control's layer activation with its long-press target. Long-press MO always waits for the configured threshold; pressing another control does not activate it early. Selecting an editing layer only previews it and does not activate it. Already-started holds and gestures keep their original mapping; higher-numbered active layers take priority for new presses. Physical multi-control Layer behavior still requires device verification. See [10 · Input Runtime](docs/10-input-runtime.md#21-momentary-layers) for details.

Each gesture can use a keyboard combination, **Switch App**, or a **Macro**. In Apps, add a local `.app` to the library, then click its A0, A1, or later keycap to assign it to the selected gesture. In Macros, create a named macro, edit its steps, then click its M0, M1, or later keycap to assign it. Edit a library item through its card’s edit icon in the same lower area. A macro runs 1–32 ordered steps combining app switches, keyboard combinations, and waits of 0.05–10 seconds. The driver launches target apps if needed and confirms the foreground app. App switches and macros trigger once per recognized gesture, including long press; Hold, Tap Once, and Repeat apply only to keyboard actions.

The macro editor provides continuous recording with optional inter-step timing, plus **Visual** and **Code** editing of the same sequence. Code uses a supported subset of QMK macro syntax and the Olanzi app-switch extension, not a full C compiler or firmware environment. Invalid code stays in the editor and does not replace existing steps. Library edits and key assignments remain drafts until the page’s **Save to This Mac** succeeds. Editing a shared macro updates every gesture referencing it after that save; unlink all references before deleting a library item. See [09 · Native macOS App](docs/09-native-macos.md#4-host-actions-and-heartbeat) for recording, code syntax, and the Codex example.

To focus Codex directly, open the Macros category, create a macro, and choose **Fill Codex Focus Macro**: switch to `com.openai.codex`, wait 0.8 seconds, then send `⌃⌥⌘I`. Save the macro to the draft library, assign its M keycap to the intended gesture, and save to this Mac. This replaces the F13/Raycast relay. The shortcut comes from the previously verified script, but the new direct driver path still needs target-application verification. Failed app switches or loss of the selected foreground app stop subsequent macro keys.

```bash
# Isolated demo without real hardware access
swift run --package-path native Olanzi --demo

# Native core tests
swift test --package-path native
```

Studio heartbeats switch keys to the vendor-event path, so both ordinary keys and Fn need host forwarding through the saved host map and Input Monitoring plus Accessibility permissions for **Olanzi App**. Heartbeats are enabled only with a valid local map, an online device, and the required permissions; otherwise they pause while read-only queries remain available. The app loads an existing host configuration first. If none exists, it provides an editable factory-key draft even without a device; only an explicit local save persists and activates it. Existing device mappings do not determine this draft or block editing. `从设备键位导入` (import device mappings) is an optional profile-page action: it validates the snapshot and loads a draft, or identifies the unsupported control while retaining the current draft. No device mappings are rewritten. A corrupt local configuration file is preserved and requires repair followed by an app restart. Select **Fn** in Common and apply; no additional switch is needed, and drafts do not affect forwarding. Fn uses device keycode `0x01`, also assigned to the factory top key. Keep the app path and signing certificate stable; identity changes may require renewed authorization. The earlier vendor-forwarding build was physically verified with Enter and Doubao Fn; the new runtime architecture, migration, gesture rules, and checks are documented in [10 · Daemon Input Runtime](docs/10-input-runtime.md).

The device page can stop heartbeats after **1, 5, 10, 15, 30, or 60 minutes** without a Vibe Key key or knob action; the default is **Never**. This preference saves immediately on this Mac, independently of keymap drafts and profiles. A held control prevents the idle timeout, and release starts a new interval; status/battery queries and hiding the window do not count as activity. Timeout also cancels host gestures, layers, and macros and releases owned keys, so the device may return to its firmware mappings. Resume explicitly from the device page or menu bar; vendor events alone do not resume forwarding. Actual device sleep and power savings remain unverified. See [09 · Native macOS App](docs/09-native-macos.md#4-host-actions-and-heartbeat) for resume behavior.

The main window shows battery percentage and charging status below the connection status, refreshing through a read-only query every 20 seconds while online. Levels at or below 20% appear orange; offline or unavailable readings show `电量 —`. Battery-query failures are reported separately and do not disable Fn forwarding.

Double-press and long-press actions remain supported. To move a configuration between Macs, export the complete `HostProfile` JSON and import it on the other Mac, then explicitly save it locally. The profile includes primary, double-press, and long-press actions, the keyboard output modes and repeat counts for each gesture, and timing values, including app targets, named library items, their shared references, and macro steps. Automatic cross-Mac synchronization through the device is not provided, and this workflow does not write device mappings.

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
- [ ] To be verified — on-device key-table combinations (`num > 1`), `type=0x03` (system / multimedia)

---

## Notes

This project is **interoperability research**: the goal is to let users run software they wrote themselves on hardware they bought themselves.
All conclusions come from observation and static analysis of **a locally purchased device**; no copy protection was cracked,
no authentication was bypassed, and no vendor code or firmware is distributed.

`vibekey.py` depends only on the system's built-in IOKit and **does not read or modify any file of Ulanzi Studio**.
