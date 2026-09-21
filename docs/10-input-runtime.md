# 10 · Daemon Input Runtime

> 🌐 [中文](10-input-runtime.zh.md)

> 📚 Docs set: [README](../README.md) · [02 Protocol](02-vibekey-protocol.md) · [07 Heartbeat](07-heartbeat-investigation.md) · [09 Native macOS](09-native-macos.md) · **10 Input Runtime**

## 1. Ownership and scope

All six controls enter one host input pipeline. The menu-bar application's device worker owns the receiver, heartbeat, gesture clock, committed action map, and generated key holds. The window edits drafts and submits configurations; closing it does not stop the worker. This is an in-process background service, not a separately installed launch daemon or login item. Quitting the app stops forwarding.

The previous implementation looked up each event in the device's key table. That conflated the hardware fallback with runtime actions and had no place to recognize double presses or long presses. The new runtime uses a persistent host configuration, initially seeded from a read-only device snapshot. Subsequent refreshes and reconnects do not replace that configuration. Normal edits never issue a hardware key-table write.

| Layer | Responsibility |
|---|---|
| `MacHIDTransport` | Decode vendor frames and deliver physical-control edges, including while a query is waiting |
| `GestureRouter` | Interpret edges and monotonic deadlines; choose exactly one configured action |
| `VendorKeyBridge` | Execute action holds, preserve shared modifiers, and retry failed releases |
| `MacKeyEmitter` | Translate keyboard usages to macOS events and post at the HID tap |
| `HostKeymapStore` | Validate and atomically persist the authoritative host configuration |
| SwiftUI / `AppModel` | Edit drafts, choose gestures, import/export profiles, and submit saves |

Vendor events identify controls independently of their configured actions. The AU05 physical index is `frame[4]`; `frame[2]` is a logical action number and is never injected as a keyboard usage. The four push controls send press/release edges. Rotary controls 4 and 5 send a press-only pulse per tick. See [the routing capture](evidence/2026-09-21-vendor-key-routing.log).

## 2. Actions and timing

Each control has a primary `press` action. The four push controls may additionally configure `doublePress` and `longPress`. Each action contains keyboard entries, so the runtime can preserve existing keyboard combinations; the current picker assigns one key to the chosen action. An absent optional action disables that gesture, while a configured unassigned key is an intentional no-op. Rotary controls reject double/long mappings.

| Configuration or event | Behavior |
|---|---|
| No optional gesture | Primary down is immediate; primary up follows physical release. Fn and modifiers acquire no gesture delay. |
| Long press only | Release before the threshold emits one primary pulse; reaching the threshold starts the long action, held until release. |
| Double press configured | The first release waits for the double-press window; expiry emits one primary pulse. |
| Second down before the double deadline | Claims the second press; its release emits one double action pulse. |
| Second press reaches the long threshold | A configured long action takes precedence; neither the pending primary nor double action is emitted. |
| Second down exactly at or after the deadline | The first primary expires first; the new down starts another gesture. |
| Rotary tick | Emit one primary down/up pair immediately, without waiting for a device release. |

The default double-press window is 250 ms from the first release; the long-press threshold is 500 ms from the relevant press. Configuration accepts a double window of 150–500 ms and a long threshold of 300–2000 ms, with the long threshold greater than the double window. The clock is monotonic. Duplicate down packets do not restart a hold or deadline.

Enabling an optional gesture necessarily delays the ambiguous primary action. Keep optional gestures disabled on a control that must immediately act as a held Fn, Shift, or other modifier. A long action mapped to Fn begins holding Fn only after its threshold.

## 3. Configuration and migration

The active map is stored at `~/Library/Application Support/Olanzi/host-keymap.json`. It contains six unique control indices, the action entries, timing values, and schema version. The store validates before writing, uses an atomic replacement, and does not activate a new map when persistence fails. A missing file permits first-device seeding; a corrupt or unsupported file is an error, not permission to silently reset the user’s configuration.

The device table is a separate fallback used when the app is absent and the receiver returns to standard HID output. Editing the fallback remains an explicit protocol-tool operation described in [03 · Tool Manual](03-tool-manual.md). Applying a host map or importing a profile does not rewrite it. Host actions can be edited and saved offline after initialization; demo mode uses memory only and never touches the real host store or device.

Exported `HostProfile` version 2 includes the full map and timing values. Import accepts legacy native version-1 six-code profiles by turning their codes into primary actions with optional gestures disabled. Saved profile collections use `nativeHostProfiles`; the old `nativeProfiles` collection remains available as the migration source. Import is bounded to 32 KiB and rejects invalid versions, duplicate/missing controls, unsupported keys, invalid timings, and rotary gesture mappings.

## 4. Holds, cancellation, and failures

An emitted hold owns a snapshot of its action. Shared macOS keys are reference-counted across controls, including aliases such as Print Screen and F13; releasing one control must not release another control's key. Other active modifiers remain present in emitted flags. Every rotary tick receives a host-generated release.

Disconnect, loss of online status or permissions, system sleep, configuration replacement, and shutdown cancel unresolved gestures and attempt to release owned keys. Cancellation never flushes a delayed single action into the newly focused application. Held push controls are quarantined until their physical release after a configuration change, preventing a held key from becoming a new action under the replacement map. A failed release remains pending for retry rather than being treated as successful. Sleep immediately gates input callbacks while the worker cancels gestures and closes the connection; waking reconnects only if the user had not manually disconnected. No pending pre-sleep action is replayed.

Device-query waits continue to deliver physical events, so a readback cannot compress an entire Fn hold into two events after the query returns. Gesture deadlines are serviced by the worker; no window timer owns input behavior. Unknown action types and unsupported macOS usages produce an error instead of guessed input. F21–F24 have no supported virtual-key mapping in this implementation.

## 5. Verification and extension boundary

The 120 native tests (108 core and 12 app-model tests) passed. The automated suite exercises deterministic gesture traces, exact deadline boundaries, long/double exclusivity, rotary pulses, cancellation, modifier ownership, configuration validation, persistence failure, migration, and service integration. Tests use fake emitters and temporary stores; passing tests is not evidence of a physical OS shortcut firing. The earlier Enter and Doubao Fn physical evidence in [07](07-heartbeat-investigation.md) establishes the vendor-to-host route, not every new gesture or application action.

Demo UI verification covered assigning and saving double/long actions, displaying both in the device diagram and control list, and restricting rotary controls to immediate actions. Offline editing and save races are covered by model/service tests. New physical double/long shortcuts remain to be verified on the device.

Run the checks and build locally:

```bash
make test
make check-docs
make release
```

The PR workflow also checks the legacy protocol suites and builds a DMG with an ad-hoc CI signature. CI artifacts are not notarized releases and do not use the developer's local signing key. Future action types can be added after gesture selection without changing the USB protocol or coupling input behavior to SwiftUI. Macros, application launch actions, and multimedia commands are not implicitly enabled by this design.
