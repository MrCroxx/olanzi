# Reverse Engineering Ulanzi Studio · Phase 1: Scope and Responsibility Boundaries
> 🌐 [中文](01-ulanzi-studio-scope.zh.md)

> Goal: establish **what Ulanzi Studio actually does, what falls under it, and what does not**, in order to define the scope of an open-source replacement client.
>
> Subject: `Ulanzi Studio 3.3.9` on macOS (main executable name `UlanziDeck`)
> Hardware: Ulanzi Vibe Key (USB wireless microphone kit, dongle product name `AU05`)
> Method: static analysis (symbol table / ObjC metadata / disassembly) + runtime capture (HID / lsof / WebSocket probing)
>
> Tagging convention: **[CONFIRMED]** = direct evidence (measured data or binary literal); **[INFERRED]** = inferred from indirect evidence, to be verified.
>
> 📚 Docs set: [README](../README.md) · **01 Scope and Responsibility Boundaries** · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Reverse-Engineering Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md)
>
> ⚠️ This document is a **Phase 1** snapshot (written before the protocol was solved); some "to be confirmed" items are **already done**, see §5 and [02](02-vibekey-protocol.md).

---

## 0. Conclusions at a Glance (read this first)

| Question | Conclusion |
|---|---|
| How do Vibe Key's keys reach the computer? | **Standard USB HID keyboard reports**; no private protocol needed **[CONFIRMED]** |
| Then what does Ulanzi Studio manage? | **Output** (indicator light / status / LED / firmware OTA) and **configuration** (profiles, bindings, brightness) |
| How does Vibe Coding's AI state reach the device? | For **WiFi devices**, plain HTTP can bypass Studio; for **Vibe Key (USB-only), Studio is mandatory** **[INFERRED, see §4.2]** |
| What is the plugin system? | A local WebSocket at `127.0.0.1:3906`, **no authentication, no path routing**; the protocol can be fully replicated **[CONFIRMED]** |
| Can we just write a Studio replacement? | Yes, but the private HID protocol in `kwdm.dylib` must be replicated — **✅ Done, see [02](02-vibekey-protocol.md)** |

**In one sentence**: Ulanzi Studio's core value is not "key input" (that is a free keyboard supplied by the device firmware), but
**① translating AI agent state into indicator light effects**, **② firmware OTA**, and **③ the plugin ecosystem and cloud marketplace**.

---

## 1. Application Composition

### 1.1 Basic Information **[CONFIRMED]**

| Item | Value |
|---|---|
| Version | `3.3.9` (`version.txt`, crashpad `AppVersion=3.3.9`) |
| Main binary | `/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck` (62 MB, Mach-O arm64, **not stripped**) |
| UI framework | Qt 6 (full QtQuick / QtWebEngine / QtWebChannel stack) |
| Single instance | `QtSingleApplication` + `qtlocalpeer` / `qtlockedfile` |
| Data directory | `~/Library/Application Support/Ulanzi/UlanziDeck/` |
| Preferences | `~/Library/Preferences/com.ulanzi.UlanziDeck.plist` |

### 1.2 Key Dependencies (they determine what it can do) **[CONFIRMED]**

| Component | Role |
|---|---|
| `kwdm.dylib` (Kehwin SDK, **loaded at runtime via QLibrary**) | **Private HID protocol of the Vibe / Dial family** ← core |
| `libhidapi.0.14.0.dylib` | **Only for older Ulanzi Deck models**: `hid_enumerate(0x2207, 0x0019)` |
| `libUlanziFZBle.dylib` | BLE devices (TC002 / K6500 lights + possibly network provisioning) |
| `libcountly.dylib` | Analytics / telemetry |
| `crashpad_handler` | Crash reporting |
| `libmars-boost.a` + `xlog` | Tencent mars xlog logging (**encrypted, not readable yet**) |
| `QtBluetooth` / `QtSerialPort` | BLE / serial port (**the serial port is actually unused**) |

---

## 2. What Ulanzi Studio Manages

### 2.1 Device Onboarding and Firmware

- Maintains the device list, model detection, profile persistence (`ProfilesV2/`), brightness, fonts, icons **[CONFIRMED]**
- **Firmware OTA**: `VibeOtaManager` handles the Vibe family's **chained upgrade** (dongle `AU05_USB` first, then mic `AU05_Device`; aborts after 20 seconds without progress; restarts both ends on error) **[CONFIRMED]**
  - Upgrade payloads go through `kwdm`'s `FirmwareFrame` / `UploadImageFrame` / `calc_crc16-8`, **not over HTTP**
  - HTTP is used only to **ask whether a new version exists**: `/vibekey/firmware/checkUpdate?deviceSn=&pid=&ver=&lang=`
- Device discovery: **UDP 55555** (`DeviceWatcherManager`, `ShareAddress`). **No mDNS** **[CONFIRMED]**

### 2.2 Plugin System (`127.0.0.1:3906`) **[CONFIRMED]**

- A bare `QWebSocketServer`, **listening on localhost only, plain `ws://` with no TLS**
- **No path routing whatsoever** — `/`, `/index.html`, `/api` are all equivalent (measured: all three paths return `101 Switching Protocols`)
- Plugin handshake: `{"cmd":"connected","code":0,"uuid":"<plugin-uuid>"}`; `code` is required (int `0` or `"0"`); **no response is sent**
- **No authentication**: any local process can impersonate any `uuid`
- App → plugin commands: `run` / `add` / `paramfromapp` / `setactive` / `clear` / `rotateEvent`
- Plugin → app commands: `setImage` / `setTitle` / `setState` / `setSettings` / `hotkey` / `toast` / `showAlert` / `openurl` / `sendToPlugin` / `subscribeAiAgentState` / `getAiAgentSessions` and more

→ **This is the easiest part to replicate**: the community already has equivalent implementations for the Elgato Stream Deck (Ulanzi's `deps/DeckSDK/` is descended from the Stream Deck SDK).

### 2.3 Cloud Services **[CONFIRMED]**

| Domain | Purpose |
|---|---|
| `api.ulanzistudio.com/api` | Login / user info / SMS verification code / forgot password / log upload |
| `ulanzistudio.com` | Product list, icons, downloads, announcements, plugin marketplace, **crashpad upload** |
| `countly.ulanzistudio.com` | Analytics (app key `e7655fcbc00acffc5ca86f196bba2a68cfc8001b`) |

### 2.4 Vibe Coding Integration (`ustudio-cli`)

This was the focus of this phase; the structure has **three stages**:

```
①  AI coding agent triggers hook
        ↓  (stdin JSON)
②  ustudio-cli-hook  (shell wrapper → compiled ustudio-cli binary)
        ↓  QLocalSocket, socket name "ulanzistudio_cli"
③  UlanziDeck  (must be running, otherwise the CLI errors out and exits)
        ↓
④  kwdm.dylib  →  USB HID vendor channel  →  device
```

> ⚠️ **Important correction (Phase 2)**: the path commonly seen online and in early analyses, where
> `ustudio-cli` directly does `POST http://<device-IP>/events`, is **deprecated legacy code**.
> `hooks/device-hook.js` and `installers/device-install.js` are **orphan files with no callers**;
> moreover `isLegacyLocalStateCommand()` in `install.js` **actively deletes** any hook entry matching
> `https?://(127.0.0.1|localhost):\d+` + `"state":"(thinking|streaming|done|idle|error)"`
> — the vendor is actively cleaning up this old path.
> Evidence: **0 hits for IPv4 literals** across the entire `~/Library/Application Support/Ulanzi/`
> directory tree; the main binary contains **no** `--device-ip` / `ai-tool-state` / `device-hook` strings.
>
> **The real chain is a local socket, not the network.**

- Supports **8 agents**: `claude-code`, `codex`, `gemini-cli`, `cursor-agent`, `codebuddy`, `kiro-cli`, `kimi-cli`, `copilot-cli` **[CONFIRMED]**
- Event → state mapping (`hooks/mappings.js`) **[CONFIRMED]**:

  | State | Triggering event (claude-code) |
  |---|---|
  | `idle` | SessionStart |
  | `thinking` | UserPromptSubmit |
  | `working` | PreToolUse / PostToolUse / SubagentStart / SubagentStop |
  | `error` | PostToolUseFailure / StopFailure |
  | `attention` | Stop |
  | `notification` | Notification / PermissionRequest |
  | `sweeping` | PreCompact |

- Confirmed to write to `~/.claude/settings.json` on your machine (all 12 hook events registered) **[CONFIRMED]**
- The vendor states it **anonymizes** data: only allowlisted metadata is forwarded, prompts / transcripts / tool arguments are never recorded **[CONFIRMED, from manifest.json]**

---

## 3. What Is Out of Scope (important!)

This is the most valuable finding of this phase.

### 3.1 ⭐ Device Key Input Needs No Private Protocol At All **[CONFIRMED]**

The Vibe Key dongle (`AU05`) is a **USB composite device** that enumerates the following interfaces at once:

| Interface | Purpose | Notes |
|---|---|---|
| USB Audio | Microphone input (2 channels, 48 kHz) | Audio from the wireless mic comes in through this interface |
| HID interface 2 | **Keyboard + mouse + multimedia keys** | Report ID 1/2/3, standard HID |
| HID interface 3 | **Vendor-defined control channel** | Usage Page `0xFFFC`, Report ID `0x55`, 63 bytes |

**Measured evidence**: having you press the 4 keys and the knob in sequence captured **12 standard keyboard reports with `rid=0x03`** (6 presses + 6 releases),
each one corresponding to one of your actions, with **not a single frame on the vendor channel**:

| Your action | Captured key code |
|---|---|
| Press key 1 | `0x01` |
| Press key 2 | `0x28` Enter |
| Press key 3 | `0x29` Esc |
| Knob twist → right | `0x4f` → |
| Knob twist → right (second time) | `0x2a` Backspace |
| Knob press | `0x46` PrintScreen |

> **Corollary**: to build an open-source client that "reads keys", standard HID is enough — **zero reverse-engineering cost**.
> And the device can also **inject keyboard and mouse input** directly into the Mac (this is how it controls Claude Code).
>
> ✅ **Done**: the mapping table has been pinned down through controlled ordered experiments and cross-verified against the on-device configuration table.
> 6 controls = `01 / 28 / 29 / 46 / 4f / 2a`, see [02 §5](02-vibekey-protocol.md).
> **And these key codes are now writable** — see [02 §6 Programmable Key Table](02-vibekey-protocol.md).

### 3.2 The Vendor Channel Is a **Periodic Heartbeat**, Not Key Presses **[CONFIRMED]**

During your interaction the vendor interface (interface 3) sent only 4 frames, with timestamp intervals of
`10.100s / 10.100s / 10.100s` — an **exact period**, uncorrelated with key press times.

The payload structure is fixed:

```
rid=0x55 | first 8 bytes (different every time) | last 55 bytes (identical every time)
                                  38 90 c4 99 a3 60 aa ad  (repeated 6 times + 7 bytes truncated)
```

- This fixed tail string **cannot be found in the binary** (0 hits) → it is computed at runtime
- In 3 of the 4 frames the first 8 bytes are **byte-identical** → no random IV, **the encryption is deterministic**
- Strongly suspected to be an **8-byte block cipher in ECB mode + a static IV**, with most of the plaintext fixed / zero

### 3.3 The Real Boundary of the Private Protocol

`kwdm.dylib` is written in Objective-C and **retains complete type encodings**, which exposes the on-wire struct layout directly:

```
st_small_base_com_msg = { st_base_header(1B) | union { ... } }  total length 63 bytes
```

This is exactly the 63-byte payload we captured. The five union branches:

| Branch | Direction | Content |
|---|---|---|
| `st_usb_singel_cfg` | ↔ dongle | version, flash id, **dongle SN**, heartbeat, key long-press function, reboot, **encryption fields** |
| `st_device_singel_cfg` | ↔ device | **oversized configuration table** (see below) |
| `st_msg_interactive_pc` | device → PC | **key messages**, wheel events, battery, LED effects, **mic noise reduction level** |
| `mic_sbc_data_t` | mic audio | SBC-encoded audio (32 bytes) |
| `st_upgrade_software_msg` | OTA | connect / download / verify / program / result |

The field names inside **`st_device_singel_cfg`** read almost like a requirements document:

- **`ai_index_cfg_t`** ← AI state index (the core of Vibe Coding)
- **`led_hooks_param_cfg_t`** ← LED parameters for hook events
- `led_light_param_cfg_t`, `sys_work_led_cfg_t`
- **`sys_mic_nr_level_t`** ← mic noise reduction
- `mic_open_cfg_t`, `device_mic_ui_cfg_t`
- `oled_brightness_cfg_t`, `oled_screen_off_time_cfg_t`, `cfg_lcd_git_param_t`
- `device_uuid_cfg_t`, `device_sn_cfg_t`, `sys_mac_addr_t`, `sys_hardware_version_t`
- `key_shortcut_msg_unit_cfg_t`, `key_shortcut_mode_cfg_t` ← **key bindings**

---

## 4. Full Inventory of Communication Surfaces

| # | Channel | Address / Identifier | Owner | Replicability |
|---|---|---|---|---|
| 1 | Plugin WebSocket | `127.0.0.1:3906` | Studio | ⭐⭐⭐ trivial (plaintext JSON) |
| 2 | Internal CLI IPC | QLocalServer `ulanzistudio_cli` | Studio ↔ ustudio-cli | ⭐⭐ moderate |
| 3 | Device discovery | **UDP 55555** broadcast | Studio ↔ network devices | ⭐⭐⭐ easy |
| 4 | Device HTTP | `http://<ip>:<port>/events` | hook → direct device connection | ⭐⭐⭐ easy (but unusable with Vibe Key) |
| 5 | **Vendor HID** | Usage Page `0xFFFC`, **Report ID `0x55`**, 63B | kwdm → Vibe Key | ⭐ **hard, the core work** |
| 6 | Standard HID input | Report ID 1/2/3 | **device firmware** | ⭐⭐⭐ free |
| 7 | BLE GATT | `0000fff0`→`fff2/fff1`; `0000a002`→`c304/c305`; `f000ffc0`→`ffc1` | FZ BLE | ⭐⭐ moderate |
| 8 | Legacy Deck HID | `hid_enumerate(0x2207, 0x0019)` | hidapi | ⭐⭐ moderate (old devices only) |
| 9 | Cloud API | `api./countly./www.ulanzistudio.com` | Studio | ⭐⭐⭐ easy (but not required for a replacement client) |
| 10 | Serial port | linked but **unimplemented** | — | nothing to handle |

### 4.1 Complete Device Model Roster **[CONFIRMED, from the bundled `defProfile/`]**

| Model | Product | Controls |
|---|---|---|
| `AU05` | **Vibe Key** | **1 knob + 4 keys** (main / Talk / Confirm / Cancel), no screen |
| `AU05-X` | **Vibe Ring** | dual mics A/B, each with left/right plugin slot / key / indicator light |
| — | Vibe Talk | 2 plugin slots + 2 keys + 2 lights |
| — | Dial Mini | 1 knob + 1 key |
| `Dial` | Dial | 3×3 + 1 knob |
| `D200` / `D200H` / `D200X` | 5×3 keypad |
| `20GBA9901` | Ulanzi Deck 5×3 | 5×3, via legacy hidapi |
| TC002 / K6500 | BLE lights |

### 4.2 ⚠️ Why Vibe Key Cannot Bypass Studio **[CONFIRMED]**

From the Mac's point of view, Vibe Key is a **USB-only device**:

- **No network interface** (no interface created by it appears in `ifconfig`)
- It does **not participate** in UDP 55555 discovery
- The device's self-reported `XXX SN: "" flashId: "4150…1578" MAC: "" Active: true` — **MAC is empty**
- **0 hits for IPv4 literals** across the entire App Support directory tree

So for Vibe Key there is only one path:

> **hook → ustudio-cli → Studio (QLocalServer) → kwdm → USB HID → device indicator light**
>
> On this chain **Studio is unavoidable** (when Studio is not running, the CLI immediately reports
> `Error: Ulanzi Studio is not running. Please start UlanziDeck first.` and exits)

**This is the root cause of "it is too painful to use".** There are only two ways to get rid of Studio:
1. Replicate `kwdm`'s private HID protocol (**recommended**, see §6)
2. Use standard HID — but that is only enough to read keys, not to drive the indicator light

---

## 5. TODO / Verification Needed From You

| # | Item | Status |
|---|---|---|
| 1 | Pin down the "physical control → key code" mapping table | ✅ **Done** (dual confirmation: controlled experiment + on-device configuration table) |
| 2 | Confirm whether key presses are really injected into the system | ✅ **Done** (measured: key 2 typed Enter, key 3 typed Esc) |
| 3 | **Decrypt the vendor HID channel** | ✅ **Done** (TEA-ECB; key and algorithm fully recovered) |
| 4 | `ai_index_cfg_t` state values → LED colors | ⬜ Not done (Phase 5 goal) |
| 5 | Does the recording / microphone path also use the private protocol | ⬜ Not done |
| 6 | xlog log decoding | ✅ **Done** (mars xlog, 223/223 records → 62 MB plaintext) |
| 7 | Which Vibe models `AU03` / `AU04` correspond to | ⬜ Unconfirmed |
| 8 | **Rewrite the on-device key table** | ✅ **Done** (`01 06 50 04`, verified end to end to take effect) |

> Evidence and raw data for the completed items are in [05 Verification Log](05-verification-log.md).

---

## 6. Phase 2 Progress: The Protocol Semantics Layer Has Been Solved **[CONFIRMED]**

### 6.1 Device Identity

| Item | Value |
|---|---|
| flashId (primary key) | `<REDACTED>` (first 7 bytes as ASCII = `AP53002`, a model prefix) |
| deviceSn | `<REDACTED>` |
| MAC | **empty** |
| Firmware version | dongle `4.4.2` / device `4.4.2` |
| Storage location | `Devices[].UUID` in `config/device_source.json` |

### 6.2 What the Vendor HID Channel Carries Is a **JSON String**

kwdm hands plaintext JSON to the application through a callback:

```
DialDeviceManager::onDeviceMessage(const char *deviceId, const char *msg)   ← kwdm SDK callback
  → parseAndDispatchMessage()
  → DeviceMessageHandler::onRawMessageReceived(flashId, JSON)
  → dispatch by "type" to handleKeyEvent / handleBattery / handleIndicatorLightAllParams / ...
```

That is, **the 63-byte HID payload = one JSON text** (which is also why it is so compact and its field names are so blunt).

### 6.3 Device → App: Message Vocabulary (exhaustive count from the 62 MB plaintext log)

| `type` | Occurrences | Notes |
|---|---|---|
| `deviceKeyEvent` | 15572 | **key / knob events** |
| `deviceBattery` | 1784 | battery |
| `deviceButtonShortcutFunction2` | 1580 | shortcut code of the key binding |
| `deviceActive` | 440 | online status |
| `deviceHooksMode` | 424 | AI hooks mode |
| `deviceSN` | 420 | serial number |
| `deviceIndicatorLightAllParams` | 348 | **all indicator light parameters** |
| `deviceSleepTime` | 332+83 | sleep time |
| `deviceMotorStrength` | 332 | motor strength |
| `deviceStandbyStatus` | 248 | standby status |
| `dongleVersion` / `dongleSN` | 164 / 160 | dongle info |
| `deviceVersion` | 148 | firmware version |
| `deviceMicNRLevel` | 148 | **mic noise reduction level** |
| `deviceFlashId` | 148 | flashId |

**Sample key message:**

```json
{ "status" : 1, "access" : 2, "type" : "deviceKeyEvent", "index" : 3 }
```

The measured `index` values are **0 / 1 / 2 / 3 / 4 / 5** (corresponding to the 4 keys + knob + knob press),
`status` = 1 pressed / 0 released.

**Sample key binding messages (`content` is the key code):**

```json
{ "access" : 0, "content" : "2A",  "type" : "deviceButtonShortcutFunction2", "index" : 3 }
{ "access" : 0, "content" : "105", "type" : "deviceButtonShortcutFunction2", "index" : 5 }
```

### 6.4 App → Device: Confirmed Command

```json
{ "type" : "deviceHooksMode", "status" : 0|1, "access" : 0 }
```

Triggered by `CliManager::aiHooksStatusFinished → onSetDeviceHooksMode`,
locating the device by `flashId`. **This is the command that delivers the "AI hooks switch" to the device.**

### 6.5 Complete Key Handling Chain (hard evidence)

```
deviceKeyEvent{index:3,status:1}
 → DeviceMessageHandler::handleKeyEvent       [KeyEvent][Handled] Position: 3 | status: 1
 → UlanziDeck::onDialKeyPressed
 → ProfilePresenter::onDialEvent
 → UlanziDeck::onActionTriggered("com.ulanzi.ulanzideck.system.hotkey")
 → ActionManager::OnTriggerAction
 → HotkeyParser::parse → "F13"
 → InputSimulator::KeyDownEx(CGKeyCode 105, flags 256)
```

**Implication**: key bindings (the "shortcut function") are **stored in the on-device firmware**;
the device can either report `deviceKeyEvent` over the vendor channel, **or send standard keyboard reports by itself** (interface 2).
→ So Vibe Key **works perfectly well as an ordinary keyboard with no Studio at all**.

### 6.6 Bonus Finding: The xlog Log Format Has Been Cracked **[CONFIRMED]**

- 73-byte file header: `magic(1) | seq(u16 LE) | beginHour(1) | endHour(1) | length(u32 LE) | cryptPubkey(64)`
- `0x08` = synchronous plaintext; `0x09` = asynchronous **raw DEFLATE** (`deflateInit2(wbits=-15)` + `Z_SYNC_FLUSH`)
- **The logs are not encrypted** (the 64-byte ECDH/TEA key field is all zeros)
- Fully decoded **223/223 records → 62 MB plaintext**
- Decoder: `~/ulanzi-re/tools/xlog_decode.py`
- These 62 MB are the most valuable forensic material in this project

---

## Appendix: Evidence Sources

- Static: `~/ulanzi-re/raw/strings_short.txt`, `symbols.txt`, `kwdm.dylib` ObjC metadata
- Dynamic: `~/ulanzi-re/raw/cap2.log` (raw), `cap3.log` (decoded)
- Tools: `~/ulanzi-re/tools/vibekey_probe.py` (direct hidapi), `vibekey_decode.py` (human-readable capture)
- Detailed breakdown: `~/ulanzi-re/findings/binary-surface.md`, `kwdm-protocol.md`
