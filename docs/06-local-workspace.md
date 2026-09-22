# 06 · Legacy Local Workspace Prototype

> 🌐 [中文](06-local-workspace.zh.md)

> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md) · **06 Workspace** · [07 Heartbeat](07-heartbeat-investigation.md) · [08 Mac Fn](08-mac-fn.md) · [09 Native macOS](09-native-macos.md) · [10 Input Runtime](10-input-runtime.md)

> This document retains the legacy Python/browser workspace and daemon instructions. The current product entry point is **[09 · Native Swift macOS App](09-native-macos.md)**. Commands, web pages, terminal permissions, and settings files below apply only to the legacy prototype, not to running the native app.

## 1. Product scope

This legacy prototype explored interaction for a lightweight local Studio alternative. Key configuration is its first module; its device connection, state, and background service form the foundation for later capabilities. The interface uses VIA's default Olivia Dark warm peach `#E8C4B8` and charcoal background, with top icon navigation, a device preview above, and a keycode panel below. The device preview follows the user-supplied hardware photo: a silver rectangular body, top grille, large round knob, and three white square keys. Its control layout and protocol specifically target the AU05.

| Module | Current support | Boundary |
|---|---|---|
| Key configuration | Three keys, knob press, knob twist → right / ← left | Six actions; the hardware power key is not programmable here |
| Key selection | Single ordinary keyboard keycodes, including standalone modifier keys | Key combinations, macros, and system / multimedia writes are not enabled |
| Browser input test | Shows keyboard events received by the focused browser page | Cannot identify which keyboard produced an event; OS shortcuts may never reach the page |
| Local profiles | Named profiles, JSON import/export, factory-mapping draft | Browser-local storage; importing or loading does not write to the device |
| Local Mac Fn bridge | Converts AU05 `0x01` into Fn events in the current Mac session | Disabled by default; requires Input Monitoring, Accessibility, a connected device, and a running service |
| Device connection | Vendor channel connection, separate device-online query, background heartbeat | Receiver availability is distinct from the device itself being online |
| Future modules | Shared device-service foundation | Lighting, firmware OTA, and other unverified writes are not exposed |

## 2. Launch and connect

### Foreground operation

Run from the repository root on macOS with Python 3:

```bash
python3 olanzi.py
```

The service runs in the foreground in the current terminal and opens [http://127.0.0.1:8765](http://127.0.0.1:8765) in your browser. All interface assets come from this repository; no account, CDN, or third-party Python package is required. The HTTP service binds to loopback and validates the request host and mutation origin. The browser talks to this service; the service uses system IOKit to access the vendor HID interface.

1. Quit Ulanzi Studio and any other tool holding the vendor channel.
2. Plug in the receiver and turn on Vibe Key.
3. Wait for automatic connection and loading of the six current mappings; the service retries about every two seconds while disconnected, and you can also select Connect Vibe Key manually.
4. If the receiver is connected but the device is offline, turn on the device and wait for the next online check.

```bash
# Do not open a browser automatically
python3 olanzi.py --no-browser

# Select another local port
python3 olanzi.py --port 8766

# Preview with an isolated simulated device; never accesses hardware
python3 olanzi.py --demo
```

Demo mode is explicitly marked in the interface. Simulated reads, writes, and connection states do not establish real hardware behavior. The service does not silently fall back to demo mode when hardware access fails.

The terminal key monitor in [03 · Tool Manual](03-tool-manual.md) opens the keyboard input interface and needs Input Monitoring permission. The workspace's browser input test uses page keyboard events instead; it is not a raw HID capture tool. The optional Mac Fn bridge opens the AU05 standard input interface separately and requires Input Monitoring and Accessibility permissions for the running terminal; disabling it leaves the keyboard interface unopened.

### Background operation

```bash
# Start manually in the background without opening a browser
python3 olanzi.py daemon start

# Show background process status and the log location
python3 olanzi.py daemon status

# Stop the background process managed by this project
python3 olanzi.py daemon stop
```

After startup, open the [local workspace](http://127.0.0.1:8765) manually. The background process continues after closing the terminal or browser. It is not a login item or boot service: the project installs no `launchd` service, and you must start it manually after a system restart. Plain `python3 olanzi.py` retains foreground execution and automatic browser opening.

If an existing foreground service occupies the same port, background startup reports an error without killing or replacing that service. Press Ctrl-C in the original terminal before running the background start command. `daemon status` checks the managed background process; it does not establish that the device itself is online. Check device connection and Fn activity in the page.

Background logs are written to `~/Library/Logs/Olanzi/daemon.log`, and process metadata to `~/Library/Application Support/Olanzi/daemon.json`. Local feature settings remain independently stored in `~/Library/Application Support/Olanzi/settings.json`; starting or stopping the background service neither turns those settings into browser profiles nor deletes on-device mappings.

### Automatic connection and explicit disconnect

Both foreground and background services connect automatically on startup, retrying about every two seconds while disconnected. A connected receiver with an offline device continues to receive separate device-online checks. Explicitly selecting Disconnect in the page pauses automatic connection for the current service run until you select Connect again. This pause is not persistent; the next service start resumes automatic connection.

## 3. Edit and apply mappings

1. Select a control in the device illustration or action list.
2. Choose or search for a key in the keycode picker. The change remains a draft.
3. Review the pending changes, then select Apply to Device.
4. Wait for the write acknowledgement and readback verification before considering the mapping saved.

The device stores applied mappings persistently. The application reads current values before writing; if another program changed a targeted control since it was loaded, the application refuses the stale write and asks you to refresh. Each changed control must receive a matching write acknowledgement and a matching readback.

A multi-control apply is not an atomic transaction. If a later write fails, earlier writes may already have persisted. The application reports partial failure and attempts to reread the actual state; if that reread fails, reconnect and refresh before retrying. Do not interpret an error as proof that nothing changed.

The UI warns before discarding an unsaved draft. Restoring factory mappings loads a draft too; applying it explicitly is required to change the device. The top factory key is the ErrorRollOver code. If the local Mac Fn bridge is enabled, that code triggers Fn; otherwise the OS still ignores it. Restoring factory mappings does not disable the local bridge setting.

An existing combination or system / multimedia configuration can be read as raw configuration, but the picker only creates supported single-key mappings. Replacing such a mapping discards its previous multi-entry or non-keyboard definition for that control.

## 4. Profiles and input testing

Profiles are stored in the current browser's local storage. A different browser, profile, or local service port has separate storage; clearing browser data removes those saved profiles. Export JSON for a portable backup. Saving a profile captures the current draft, and loading or importing one updates the draft before any device write.

The input test displays browser keyboard events while testing is active and the page has focus. Other keyboards can generate the same events, and the browser cannot attribute them to Vibe Key. System-reserved shortcuts, media events, and some keys may not be delivered to the page. A missing browser event is therefore not proof of a missing HID report.

## 5. Heartbeats and sleep

The background device worker sends the Studio heartbeat approximately every second after connection, using the plaintext prefix `06 01 23 00 01` with zero padding. This command is confirmed by static analysis of the local Studio binary. Device-online status is queried separately about every two seconds. A successful host-side send does not itself prove that the device received the heartbeat or stayed awake.

Closing the browser tab leaves the foreground or background service and its heartbeat running. Disconnecting in the UI, stopping the foreground service with Ctrl-C, stopping the background service with `daemon stop`, or suspending the computer stops continued delivery. Command scheduling shares the device worker, so slow device exchanges can affect timing.

The old `01 0b 89 01` command is a Hooks query, not the verified Studio heartbeat. A receiver reply to it cannot establish device-online status or sleep prevention. The relationship between the official heartbeat and the observed idle sleep requires hardware observation over the relevant idle period; see [07 · Heartbeat Investigation](07-heartbeat-investigation.md) for evidence and measurement limits.

## 6. Optional Mac Fn bridge

Select Mac Fn from the modifier category in the key picker and apply it to the device, then enable the local Fn bridge in the interface. The device still stores `0x01`; the local service converts matching standard HID reports into Fn events. The bridge is disabled by default and requests system authorization only through the explicit permission button. Missing permissions or an unavailable interface produce an error and retries without blocking vendor-channel remapping or heartbeats.

The bridge requires a connected, online device, a running service, and Input Monitoring and Accessibility permissions for the terminal running it. It continues after closing the browser, including in background mode, but stops converting when the service stops. Every control assigned that keycode triggers Fn; multiple physical controls sharing the code cannot be distinguished. This capability is not native device firmware Fn.

The setting lives in `~/Library/Application Support/Olanzi/settings.json`, separately from browser profiles; profile JSON import/export excludes it. Demo mode opens no real input interface and injects no system Fn events. See [08 · Mac Fn](08-mac-fn.md) for press/release behavior, permission steps, and unverified system actions.

## 7. Architecture and extension boundaries

| File or directory | Responsibility |
|---|---|
| `olanzi.py` | Loopback HTTP entry point, local assets, request validation, browser launch |
| `olanzi_device.py` | macOS HID transport, demo transport, serialized device worker, state, heartbeat, verified writes |
| `olanzi_fn.py` | Separate AU05 input interface, permission state, Fn press/release, and release on failure |
| `olanzi_settings.py` | Independent persistence of the local Fn setting |
| `olanzi_daemon.py` | Manual background process start, status, and stop, with separate process metadata and logs |
| `web/` | Vanilla HTML / CSS / JavaScript interface, draft mappings, profile storage, browser input test |
| `vibekey.py` | Existing terminal tools and recovered protocol primitives |
| `tests/` | Device behavior, HTTP boundary, and frontend validation tests |

HTTP request threads submit work to a single device worker so vendor-channel reads, writes, and heartbeats use one serialized connection. The optional Fn bridge manages a separate standard input interface on the same worker. The frontend distinguishes its editable draft from the last device snapshot. Profiles are separate from device persistence: loading a profile never implicitly applies it.

New modules should reuse the device service, retain explicit read/write boundaries, and expose only commands with verified parameter formats. The reverse-engineered command table is evidence of command existence, not authorization to send every write command. Firmware OTA, lighting, and other device functions need their own protocol validation before implementation.

## 8. Verification

From the repository root:

```bash
python3 -m unittest discover -s tests -v
node --test tests/test_frontend.mjs
python3 tools/check_docs.py
git diff --check
```

Python runtime operation uses only the standard library. Node.js is needed for the frontend tests, not for launching the workspace.

Mock and demo tests validate application logic, acknowledgements, readback handling, stale-write rejection, partial failures, and local HTTP boundaries. They cannot prove radio delivery, device-side persistence across power cycles, every selectable key's behavior, or idle-sleep prevention. Fn state-machine tests also cannot prove system Globe-key actions, Dictation, or full equivalence to hardware Fn. Hardware observations belong in the [verification log](05-verification-log.md) and [heartbeat investigation](07-heartbeat-investigation.md), with unmeasured conclusions left explicitly unconfirmed.
