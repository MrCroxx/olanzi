# 09 · Native macOS App

> 🌐 [中文](09-native-macos.zh.md)

> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md) · [06 Legacy Prototype](06-local-workspace.md) · [07 Heartbeat](07-heartbeat-investigation.md) · [08 Mac Fn](08-mac-fn.md) · **09 Native macOS** · [10 Input Runtime](10-input-runtime.md)

## 1. Current product entry point

Olanzi's main application is a native macOS menu-bar app. It uses a complete SwiftUI interface for key configuration and AppKit for the menu-bar lifecycle, with device communication implemented in Swift through IOKit and CoreGraphics. Running the app requires no Python process, browser page, or local HTTP server.

The product remains a lightweight Studio alternative with room for additional device modules. Its initial scope is the AU05's three keys and three knob actions, background heartbeats, and host-side actions for ordinary keys and Fn, with optional double-press and long-press gestures. Additional firmware functions require their own protocol validation; the presence of a command in the reverse-engineered table does not make it safe to expose.

| Component | Role |
|---|---|
| `native/Package.swift` | Swift package; macOS 14 minimum, Swift 6 toolchain, Swift 5 language mode |
| `native/Sources/OlanziCore/` | TEA framing, IOKit transport, device state, CoreGraphics Fn events, dedicated background thread |
| `native/Sources/OlanziApp/` | SwiftUI keymap window, application state, AppKit menu bar |
| `native/Tests/` | Native core regression tests |
| `tools/build-macos.sh` | Builds and packages `build/Olanzi.app`; debug by default |
| Legacy Python and `web/` sources | Retained prototype and research tools; not the native app runtime |

## 2. Build and launch

Use macOS 14 or later with a Swift 6 toolchain. From the repository root:

```bash
make dev
```

`make dev` builds and opens the Debug app bundle at `build/Olanzi.app`. Launch the app bundle to use the native window and menu bar. No Python daemon command or browser URL is part of this startup path.

Other targets: `make build` builds Debug without launching, `make release` builds and signs Release and packages a DMG without launching, `make test` runs Swift tests, and `make check-docs` checks bilingual documentation. Both configurations share the `build/Olanzi.app` output path. If Olanzi is already running, quit it from the menu bar before running `make dev` to ensure the newly built version starts; `open` does not restart an existing process.

The build automatically uses the sole valid code-signing identity in your Keychain. If several exist, select one explicitly; if none exist, the build warns and falls back to ad-hoc signing. Set the same identity for Debug and Release to keep the signing requirement stable across rebuilds. A local self-signed certificate supports local development; it is not an Apple Developer distribution certificate or notarization.

```bash
make dev OLANZI_SIGNING_IDENTITY="Digger Local Signing"
```

The variable also accepts a certificate SHA-1 hash, or `-` to explicitly request ad-hoc signing. Signing uses the Keychain private key without exporting it. macOS may ask you to allow `codesign` to access that key.

To build the signed Release app and an installable disk image in one step:

```bash
make release
# Equivalent alias
make dmg
# Explicit signing identity
make release OLANZI_SIGNING_IDENTITY="Digger Local Signing"
```

The outputs are `build/Olanzi.app` and `build/Olanzi-<version>-<arch>.dmg` (currently `Olanzi-0.1.0-arm64.dmg` on Apple Silicon). The architecture comes from the compiled executable; this does not create a universal binary. The DMG contains the app and an Applications shortcut. Open it, drag Olanzi into Applications, then launch that installed copy. Quit a running copy before replacing it.

`tools/package-dmg.sh` packages the existing bundle; normally use `make release` so it is rebuilt first. Packaging signs the DMG with the app's certificate, checks the image checksum, mounts it read-only, verifies the bundled signature and file contents, checks the Applications link, and unmounts it before publishing the output. Temporary files are cleaned up; if unmounting fails, they are retained for recovery. No private key is exported. Local certificate signing is not Apple notarization.

For isolated UI development without real hardware:

```bash
swift run --package-path native Olanzi --demo
```

Demo mode must remain visibly distinguishable from a real device session. It uses simulated device behavior and does not open real HID interfaces or inject system Fn events. A successful demo preview is not evidence of real-device writes or OS actions.

Before connecting real hardware, quit official Studio and stop any legacy tool that still holds the device. The native app does not kill those processes on your behalf. Plug in the receiver, turn on Vibe Key, and check the app's connection state; receiver presence and device-online status are different observations.

## 3. Window and menu-bar lifecycle

The red close button and `Cmd-W` only hide the configuration window and retain drafts. Olanzi keeps running in the menu bar, and its Dock icon remains if already shown. Its background device worker continues the connection, heartbeat scheduling, and key forwarding through the saved host action map while the device is available. Reopen the configuration window from the menu bar or Dock when you need to edit mappings. While a receiver is connected, the background worker holds an activity assertion against App Nap so hiding the window does not reduce heartbeat and input scheduling. It releases the assertion on disconnect or quit, and demo mode never acquires one. This assertion allows the Mac to sleep normally.

Choose Quit from the application menu to stop the app and device worker. Shutdown attempts to release any synthetic Fn hold and closes the device interfaces. Closing a window is therefore different from quitting the app. Computer sleep interrupts continued heartbeat delivery regardless of whether the window is open.

No login item, `launchd` service, or automatic startup at boot is installed. Start the app manually when needed. Its menu-bar presence provides the background lifetime; a separate Python daemon is unnecessary.

## 4. Host actions and heartbeat

1. On first connection, read the six device mappings and initialize the local host map if its file does not exist.
2. Select a control in the device preview or right-hand list. Edit the primary, double-press, or long-press action; rotation exposes only its per-tick action.
3. Review draft labels. Optional gestures can be disabled independently; leaving them disabled preserves immediate primary-key response.
4. Apply to this Mac. The worker validates and atomically saves the complete map before activating it. This operation does not write device keycodes.

The host map is authoritative for all six controls while Olanzi is running, including ordinary keys and Fn. It can be edited offline after initialization. Device refresh and reconnection do not overwrite it. Saved and exported profiles retain gestures and timing; old six-key native profiles migrate into primary actions. See [10 · Daemon Input Runtime](10-input-runtime.md) for ownership, timing, and migration details.

The on-device key table remains an independent fallback. Explicit hardware writes through the protocol tool still require ACK/readback and can partially succeed; the native host-action editor no longer invokes that operation. Drafts are separate from both the saved host map and hardware snapshot.

The heartbeat follows Studio's recovered plaintext prefix `06 01 23 00 01` with zero padding. It selects vendor-event forwarding as well as keeping the device online. Successful transmission does not alone prove radio delivery or idle wakefulness. See [07 · Heartbeat Investigation](07-heartbeat-investigation.md).

## 5. Vendor Key Forwarding, Fn, and Permissions

[CONFIRMED] The physical comparison on 2026-09-21 found that one-second Studio heartbeats from Olanzi stopped ordinary-key standard HID output and left the Fn standard-input callback without reports. Closing only the Fn input interface did not help; stopping only the heartbeat while retaining the vendor connection and read-only queries restored Enter. Keys then appeared as `8b 10` vendor events; see [07 §4](07-heartbeat-investigation.md). Both ordinary keys and Fn therefore require application-side forwarding and its permissions.

`GestureRouter` interprets the event's physical control index using the saved host map; `VendorKeyBridge` executes the selected action to emit ordinary keys or Fn. The logical action number in `frame[2]` is not a HID keycode and must not be injected directly; the AU05 physical index is in `frame[4]`. Unapplied drafts do not participate in forwarding. Unknown or multimedia mappings must produce explicit errors rather than guessed input. Physical capture has confirmed all six control indices and rotation directions; rotation indices 4/5 report only down, requiring a host-supplied release pulse. The preceding vendor-routing implementation passed 68 automated tests and a signed Release build; the host-runtime checks are described in [10](10-input-runtime.md). Physical Enter and top-key Fn effects are confirmed; full OS-action coverage of other controls remains pending.

Fn remains an ordinary key name in the modifier category: select it and apply, without a separate feature switch or `macFnEnabled` setting. Device keycode `0x01` means Fn in the host mapping; the factory top key also uses it. Vendor events carry physical control indices, so the old standard-HID prototype's inability to distinguish same-code controls does not directly apply. Removing every Fn assignment stops Fn generation, while ordinary-key forwarding still requires the bridge and permissions.

Give **Olanzi App** both Input Monitoring and Accessibility permission in System Settings → Privacy & Security. These permissions belong to the native bundle, not the legacy terminal process. When access is missing, the footer identifies only the missing permissions and offers a button to open Input Monitoring or Accessibility settings. The device page keeps the same entry point available while the device is asleep or disconnected. Clicking requests the selected permission directly on the app main thread before opening the matching System Settings page; the request no longer waits for the device worker or connection. Input Monitoring uses the HID request API, with an event-listening request as a fallback if access remains denied. The app requests one permission at a time, without adding a separate Fn panel. System policy and existing denial records can still prevent a new prompt; opening Settings alone is not evidence that the app was registered. Returning to Olanzi refreshes permission status without prompting. If the system still reports missing access after approval, quit and reopen Olanzi. Ordinary-key and Fn forwarding both depend on these permissions; a device mapping does not establish that access is ready or forwarding is active.

If Olanzi is absent from the settings list, click + to add it. The device page's “Show App Location” button reveals the running bundle in Finder. Grant permission to that copy at a stable path, such as the repository's `build/Olanzi.app` or `~/Applications/Olanzi.app`. Reuse the same signing certificate and bundle identifier across builds. Switching from ad-hoc signing to a certificate changes the signing requirement, so existing permissions may need to be removed and granted again once. Stable signing does not grant permissions automatically.

Permission polling checks `CGPreflightPostEventAccess()` before `AXIsProcessTrusted()`. While posting is not approved, it skips the trust check: on the tested Mac, calling the trust check first left an Accessibility denial that also blocked the Input Monitoring request. Regression tests cover this initial state and later grant/revocation. [CONFIRMED] After this change and removal of stale Olanzi permission records, clicking the installed app's permission button added Olanzi to Input Monitoring with its switch off. Registration is distinct from the user's approval.

If migrating from an older ad-hoc build leaves stale denial records, quit Olanzi, reset only its affected permissions, then relaunch the installed copy and click its permission button. This removes existing approvals for those services, which must be granted again. The app never runs these reset commands automatically.

```bash
tccutil reset Accessibility com.mrcroxx.olanzi
tccutil reset PostEvent com.mrcroxx.olanzi
tccutil reset ListenEvent com.mrcroxx.olanzi
open /Applications/Olanzi.app
```


The new forwarding path consumes key events from the existing vendor connection instead of relying on the silent Fn standard-input callback. All key forwarding requires a running app, an online device, a valid saved host map, and the relevant permissions. Closing the window keeps it running; quitting stops it. The implementation must track holds by physical control, avoid duplicate presses, and attempt releases on key-up, disconnect, or quit; Enter and top-key Fn press/release have physical confirmation, which does not establish physical coverage of every control or failure-release scenario.

Fn conversion is not a native firmware Fn command, and neither the protocol nor a simulated event test proves equivalence to an Apple hardware Fn/Globe key. Dictation, input-source switching, Studio-specific Fn handling, and application-specific actions still require physical testing. See [08 · Mac Fn](08-mac-fn.md) for the trigger mechanism and historical prototype implementation; its Python commands and HTTP settings do not apply to the native app.

The native bridge posts Fn events at `cghidEventTap`, retaining a private event source and paired `flagsChanged` events. [CONFIRMED] Inspection of the running Doubao input method found its listener at the HID tap; Studio's general keyboard emitter also posts there. The previous session-level injection bypassed listeners at that earlier stage. Moving injection to the HID tap corrects the routing mismatch; the user has now confirmed top-key Fn activation of Doubao, and the log records its cleared Fn bit on release, within the physical test below. That addresses only the injection-stage mismatch. The new heartbeat comparison additionally establishes a standard-HID-to-vendor-event transition, which a Fn tap change alone cannot fix. New ordinary-key and Fn forwarding both use a private CoreGraphics source and the HID tap.

Local diagnosis uses the `com.mrcroxx.olanzi` log subsystem's `device-input` category. Distinguish vendor frames, decoded physical-control press/release events, saved host actions, and host event emission. An empty standard-input callback is no longer evidence that no key event exists. The [vendor key routing record](evidence/2026-09-21-vendor-key-routing.log) retains the six-control events and Enter / Fn validation excerpts. The six-control capture establishes indices and edge shapes; only Enter and top-key Fn additionally have current physical OS-effect confirmation. A pending draft is not the device mapping; save to this Mac and wait for activation before testing.

## 6. Legacy tools and migration boundary

The Python files, browser interface, and daemon manager remain available as the earlier prototype described in [06 · Legacy Local Workspace](06-local-workspace.md). The single-file `vibekey.py` remains a reverse-engineering and terminal inspection tool documented in [03 · Tool Manual](03-tool-manual.md). Their permissions and runtime instructions apply only when deliberately running those tools.

The native app does not require the legacy HTTP service to be running. Avoid running both against the same receiver, because an occupied interface can prevent connection. A previously running legacy service is not automatically stopped or migrated by launching the app. Native local settings, legacy JSON settings, and browser-local profiles are separate stores; the legacy Fn switch does not affect the native app, whose Fn behavior follows the saved host action map.

## 7. Verification and remaining observations

Run the native tests and documentation checks from the repository root:

```bash
swift test --package-path native
python3 tools/check_docs.py
git diff --check
```

Python in the documentation-check command is a repository maintenance tool, not a native runtime requirement. Native automated tests exercise protocol and state behavior with controlled inputs; a successful build or demo establishes neither a physical Fn action nor idle-sleep prevention.

The preceding vendor-routing implementation passed 68 automated tests and a signed Release build; host-runtime checks are described in [10](10-input-runtime.md). Earlier demo UI checks covered selection through the knob-side rotation arrows, Fn assignment, apply/readback, profile saving, reopening the window, and graceful quit; those demo checks did not open real hardware.

[CONFIRMED] In the fixed build, the user confirmed Enter newline and top-key Fn activation of Doubao, reporting `好用！！`. Logs record Enter virtual keycode 36 down/up and one Fn virtual keycode 63 pair: down at 17:31:24.285 with flags 545259520, then up at 17:31:25.616 with flags 536870912, clearing the Fn bit. See the [verification excerpts](evidence/2026-09-21-vendor-key-routing.log). This establishes neither two Fn trials nor successful OS actions for all six controls.

For hardware validation, record the actual on-device readback separately from the visible OS action. In particular, test a one-second Fn hold and release with a two-second pause, confirm no repeated presses, then check the intended action in the target application. Distinguish the app's event state from macOS behavior. Long-idle heartbeat tests must run for the relevant duration with the app still running. Do not mark these observations confirmed until direct evidence exists.
