# 08 · Mac Fn Bridge

> 🌐 [中文](08-mac-fn.zh.md)

> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md) · [06 Workspace](06-local-workspace.md) · [07 Heartbeat](07-heartbeat-investigation.md) · **08 Mac Fn** · [09 Native macOS](09-native-macos.md) · [10 Input Runtime](10-input-runtime.md)

> This document retains the legacy Python Fn implementation based on standard input reports. New testing on 2026-09-21 found that Studio heartbeats stop direct standard-key output. The native fix instead looks up saved host actions by the physical control index in vendor events and forwards ordinary keys as well as Fn; see [07 §4](07-heartbeat-investigation.md) and **[09 · Native macOS App](09-native-macos.md)**. Statements below about indistinguishable same-code controls, a separate Fn switch, Python, HTTP, JSON files, and terminal permissions describe the old standard-HID prototype, not the new vendor-event path.

## 1. What this feature does

The legacy prototype's optional local bridge translates AU05 standard input reports into Fn modifier events in the current macOS session. Assign Mac Fn in Olanzi's modifier category and apply the mapping, then enable the local Fn setting. Two separate things happen: the device stores keycode `0x01`, and the running host service interprets a matching input report as Fn.

The factory top key already uses `0x01` (ErrorRollOver), which macOS normally ignores. With the bridge enabled, that existing mapping becomes a Fn trigger without requiring a different on-device code. With the bridge disabled, it remains an ignored code. This does not establish a native Fn command in the device firmware.

All controls configured with this code share the same interpretation. The standard keyboard report contains keycodes rather than physical control indices, so the bridge cannot distinguish two controls sending the same code. It cannot implement independent held-key accounting for multiple same-code controls. Prefer one dedicated Fn control, and do not expect a momentary knob twist to behave like a held key.

## 2. Legacy prototype enablement and permissions

1. Start Olanzi manually with `python3 olanzi.py` (or start the background service), connect the receiver, turn on Vibe Key, and wait for automatic connection.
2. Select the intended control, choose Mac Fn in the modifier category, and apply the mapping. The factory top key can retain its original mapping.
3. Enable the local Mac Fn conversion setting in the interface.
4. If permissions are missing, click the explicit permission-request button. In System Settings → Privacy & Security, enable both Input Monitoring and Accessibility for the terminal running Olanzi.
5. If macOS requires a restart for the grant to take effect, stop the service yourself, fully quit and reopen that terminal, then run `python3 olanzi.py` again and reconnect. Wait for the bridge to report active before testing.

The feature is disabled by default on first launch. Enabling it does not silently request system permission. Background retries check permission state without prompting; only the permission-request button initiates an authorization request. Missing permission or an unavailable input interface is reported explicitly, and retrying the bridge does not replace or disable the vendor-channel remapping and heartbeat connection.

The service and device connection must remain active. Closing the browser stops neither the foreground nor the background service. After manually starting the background service with `python3 olanzi.py daemon start`, you can also close the terminal; use `python3 olanzi.py daemon status` to check the process and `python3 olanzi.py daemon stop` to stop it. Background mode installs no boot-time startup; see [06 · Workspace](06-local-workspace.md) for operations and logs. Disconnecting, disabling the bridge, or stopping the service ends conversion and attempts to release any synthetic Fn hold. Demo mode does not open a real input interface or inject Fn events.

## 3. Device reports and event lifecycle

| Input or condition | Bridge behavior |
|---|---|
| AU05 vendor/product match and standard input interface | Opens this device interface independently from the vendor channel |
| Keyboard Report ID `0x03`, complete report, exactly one `0x01` key entry | Sends Fn down on the transition into the pressed state |
| Repeated report while the same Fn state is held | Does not send another Fn down |
| Valid report with no Fn trigger, including all-zero release | Sends Fn up if the bridge has an outstanding hold |
| Six `0x01` entries (ErrorRollOver), or error entries | Does not trigger Fn down |
| Non-keyboard or malformed report | Ignores it |
| Device disconnect, unavailable online state, disabling, or shutdown | Attempts Fn release before closing the input interface |
| Release-posting failure | Reports the error and retains the pending hold state for retry instead of claiming release succeeded |

The filter targets VID `0xFFF1` / PID `0x00DD` and the AU05 standard input interface. It does not monitor input reports from other keyboards. When the bridge is disabled, that input interface is not opened. The legacy emitter reads aggregate modifier flags to preserve concurrently held modifiers; it does not collect or log other keyboards' key events. These aggregate flags are not proof of physical Fn state: the later native-app investigation in [05 §9.9](05-verification-log.md#99-synthetic-fn-feedback-contaminating-the-hid-state) found that the app's own synthetic Fn could appear in both HID flags and key state.

The host event uses virtual keycode 63, equivalent to `kVK_Function = 0x3F` in Apple's SDK `HIToolbox.framework/Headers/Events.h`, and the Fn flag `0x800000`. Apple's [maskSecondaryFn documentation](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn) defines this flag as the Fn-down indicator. Press and release are emitted as [flagsChanged events](https://developer.apple.com/documentation/coregraphics/cgeventtype/flagschanged).

The historical prototype creates keyboard events, sets their type and flags, and posts them at [cgSessionEventTap](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cgsessioneventtap), using a private event source. That source was intended to separate synthetic and physical Fn state, but it does not isolate the HID aggregate and must not be treated as a validated physical-state detector. The current native implementation independently tracks physical Fn metadata; see [09](09-native-macos.md) and [10](10-input-runtime.md). This implementation choice does not prove equivalence to every hardware or Studio-specific Fn path. See Apple's [CGEventSetFlags reference](https://developer.apple.com/documentation/coregraphics/cgeventsetflags?language=objc) for event flag assignment.

## 4. Legacy prototype settings and profiles

The local switch is stored at:

```text
~/Library/Application Support/Olanzi/settings.json
```

This is a Mac-local service setting, separate from both on-device key mappings and browser-local profiles. Restarting the service reloads the saved switch; changing browser or port does not create a separate service preference. A settings-file read error leaves the bridge disabled and exposes the error.

Importing or exporting a device profile includes its keycodes, so a profile can contain the Fn trigger code. It does not include or change the local Fn switch. Applying factory mappings does not turn the bridge off; the factory top key will still trigger Fn if the local switch is enabled. Demo-mode changes do not persist to the real settings file.

The local HTTP API uses `POST /api/fn` with `{"enabled": true}` or `{"enabled": false}` for the switch, and `POST /api/fn/permissions` with `{}` for explicit permission requests. These endpoints retain the same loopback, host, and same-origin checks as other workspace mutations. The UI reports enabled, active, permission, pressed, and error states separately; an enabled preference alone does not mean the bridge is active.

## 5. Verification boundaries

The legacy prototype implementation and automated tests cover decoding, filtering, repeated reports, press/release transitions, permission failures, reconnection, settings persistence, and cleanup behavior. A passing simulated test establishes application behavior under its simulated inputs; it does not establish that macOS invoked a particular user action.

The bridge does not claim complete equivalence to an Apple hardware Fn/Globe key, the official Studio's dedicated Fn handling, Dictation, input-source switching, or every application's shortcut handling. Those outcomes require testing on the user's actual macOS version, keyboard settings, and target application. Browser input testing is not a reliable Fn verifier because Fn may not reach the page as a regular keyboard event.

For a manual test, keep the sequence and pauses explicit:

1. Confirm the bridge is active and the selected physical control is mapped to the Fn trigger. Leave other controls alone.
2. Press that control for one second, then release it. Wait two seconds and check that the bridge no longer reports it as pressed.
3. Repeat once, then wait two seconds. Verify that a single hold was not interpreted as repeated presses.
4. Check the intended Fn action in the target application or system setting. Record the actual visible result separately from the bridge's event count.
5. While holding the control, disable the bridge, then release the physical control. Wait two seconds and verify that no synthetic Fn hold remains reported. Re-enable only if further testing is needed.

Do not turn an unobserved system effect into a confirmed result. Hardware observations and OS-visible behavior should be recorded with the macOS version, relevant keyboard setting, target application, and actual outcome. Until those observations exist, the relevant system action remains unverified.
