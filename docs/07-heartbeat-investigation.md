# 07 · Heartbeat and Sleep Investigation

> 🌐 [中文](07-heartbeat-investigation.zh.md)
>
> 📚 Docs set: [README](../README.md) · [01 Scope](01-ulanzi-studio-scope.md) · [02 Protocol](02-vibekey-protocol.md) · [03 Tool Manual](03-tool-manual.md) · [04 Methodology](04-methodology.md) · [05 Verification Log](05-verification-log.md) · **07 Heartbeat** · [08 Fn Prototype](08-mac-fn.md) · [09 Native App](09-native-macos.md) · [10 Input Runtime](10-input-runtime.md)

## 1. What Is Confirmed

[CONFIRMED] The old tool's `--poll` sends `01 0b 89 01`, a Hooks-mode **read**, every configured interval. This is different from Studio's dedicated heartbeat. The dongle can answer Hooks queries without the device body being online; a successful exchange is not proof of an awake device.

[CONFIRMED] LLDB disassembly of the installed Studio library shows that `+[MessageHelper deviceHeartbeatMessage]` constructs a 64-byte plaintext frame beginning with `06 01 23 00 01`, followed by 59 zero bytes. The background worker sends this frame about once per second while its connection state allows it. `+[TimeUtils now]` multiplies `CACurrentMediaTime` by 1000; the worker compares elapsed time with 1000.

```text
mov  w8, #0x106
movk w8, #0x23, lsl #16
str  w8, [sp, #0x8]
mov  w8, #0x1
strb w8, [sp, #0xc]

plaintext: 06 01 23 00 01 + 59 zero bytes
```

The intermediate `kwdm_message_builders.txt` incorrectly extracted this constructor as `01 00 00 00`: it attributed a later register assignment to an earlier store. Use the original disassembly as evidence. This is a heartbeat frame, not permission to send other undocumented commands with the same access byte.

## 2. Hardware Observations

The test opened only the vendor interface. No Ulanzi Studio process was observed, no input interface was opened, and no configuration writes were sent. Online state was checked only before and after each window so that status queries did not pollute its idle interval.

| Window | Duration | Traffic | Final status |
|---|---|---|---|
| Idle | 60.005 seconds | No requests | `06 03 0a 11 01 00 00 00` |
| Hooks polling | 60.005 seconds | 30 requests, 30 replies; 2-second interval | `06 03 0a 11 01 00 00 00` |
| Later Studio-heartbeat attempt | Aborted at baseline | Status query only; no heartbeat sent | `06 03 0a 11 00 00 00 00` |
| Offline recovery diagnostic | About 20 seconds | 10 Studio heartbeat send calls succeeded; interleaved status queries | `06 03 0a 11 00 00 00 00` |

[CONFIRMED] Both completed windows ended online, with no notifications or callback errors. A later check returned an explicit offline status. The six-control read attempted before that check could not collect a complete configuration snapshot; the revised checker now validates online state first.

[CONFIRMED] After the user reported physically waking the device, the status query still returned offline. A separate recovery diagnostic successfully submitted 10 confirmed Studio heartbeat frames, approximately two seconds apart because status queries were interleaved; every status remained offline, and the six-control snapshot stayed incomplete. There were no notifications or callback errors. This does not contradict the physical observation: the measured state is the dongle's wireless-online flag. This diagnostic did not establish an online starting state or test one-second sustained heartbeats.

[INFERRED] A longer idle period may cause sleep. The exact transition time and cause were not measured. These results do not establish whether Hooks polling prevents sleep, whether the dedicated heartbeat prevents sleep, or whether it can wake an already offline device. Those attempts did not complete a Studio-heartbeat window or before/after key comparison from an online starting state. Later validation through the running workspace is recorded below.

## 3. Validation Through the Running Workspace

[CONFIRMED] After wireless connectivity was restored, the real local workspace read all six controls. Key 1 was changed from `0x01` to F13 (`0x68`), with a write acknowledgment and matching device readback, and then restored to `0x01`. All six final configurations matched the original snapshot. This verifies the configuration write/read/restore path; it does not verify physical key events. The complete round trip is retained in the [workspace log](evidence/2026-09-21-workspace-roundtrip.log).

[CONFIRMED] The running local service was then observed through HTTP for **90.019 seconds**, with 91 samples at roughly one-second intervals. Every sample reported `online=true` and `connected=true`, Studio heartbeat enabled with a one-second interval, and no error. The observed `lastSent` timestamp advanced between 86 adjacent sample pairs; its maximum age at sampling was 1.001 seconds. Sampling and heartbeat scheduling are independent, so adjacent equal timestamps do not imply a missed heartbeat. All six controls were read through `POST /api/refresh` before and after the window and were unchanged. The service remained running. See the [90-second observation log](evidence/2026-09-21-workspace-heartbeat90.log).

This is a successful short operational check, not an isolated sleep-prevention experiment: the service also queried online status every two seconds, and the before/after key reads may affect wake state. HTTP state reads only observed the running service; no second HID client or configuration write was used during this window. That historical window did not verify longer-term sleep causality or physical key events; the later key-path comparison follows below.

## 4. Heartbeat Changes the Key Reporting Path (2026-09-21)

[CONFIRMED] A later physical AU05 comparison found that while Olanzi sent `06 01 23 00 01` every second, ordinary keys stopped injecting through standard HID and the Fn standard-input callback received no reports. Keeping the vendor connection and heartbeat while closing only the Fn standard-input interface did not restore input. Stopping only the heartbeat while retaining the vendor connection and read-only queries restored Enter. This failure therefore cannot be attributed to the Fn input interface holding the device, and this heartbeat cannot be treated as input-neutral keepalive.

| Observed condition | Result |
|---|---|
| One-second Studio heartbeat; vendor connection retained | No ordinary-key standard HID injection; no Fn standard-input callback reports |
| Heartbeat and vendor connection retained; Fn standard-input interface closed | Ordinary keys still failed |
| Heartbeat stopped; vendor connection and read-only queries retained | Enter recovered |
| Vendor channel observed while heartbeat was running | Keys arrived as `8b 10` events instead |

[CONFIRMED] Vendor events combined with Studio's AU05 `isSwitchKeyIndex=true` path establish the fields below. `frame[2]` is a logical action number, with captured example byte `70`, and must not be treated as a HID keycode. Look up the physical control index in the confirmed device bindings before choosing a host event.

| Field | Confirmed meaning |
|---|---|
| `frame[0] & 0x1F` | `0x0B`, notice command |
| `frame[1]` | `0x10`, key-event subtype |
| `frame[2]` | Logical action number, not a HID keycode |
| `frame[3]` | `0x01` down, `0x00` up |
| `frame[4]` | AU05 physical control index, interpreted through Studio's `isSwitchKeyIndex=true` path |

[CONFIRMED] A subsequent six-control physical capture (17:28:35–17:28:42; see the [vendor key routing record](evidence/2026-09-21-vendor-key-routing.log)) confirmed `frame[4]` values 0, 1, 2, 3, 4, and 5 in the user's action order, matching the configured controls: top, middle, bottom, knob press, clockwise right twist, and counterclockwise left twist. The first four actions carry both down and up edges. Rotation indices 4 and 5 report only `status=1`, with no corresponding release; the host must supply an up event to form a pulse rather than wait indefinitely. This confirms physical control indices and both rotation directions, not successful host injection for every action.

The native fix uses `VendorKeyBridge`: consume these vendor events, translate ordinary keys and Fn through confirmed device bindings, and post at the HID tap using a private CoreGraphics event source. Application-side conversion requires the relevant permissions for all keys, not only Fn. Unknown or multimedia mappings must produce explicit errors rather than guessing keycodes from action numbers. The updated implementation passed 68 automated tests and a signed Release build. Physical end-to-end confirmation covers the Enter and top-key Fn cases below, not every OS action from all six controls.

[CONFIRMED] In the fixed build's physical test, the user confirmed Enter newline and top-key Fn activation of Doubao, reporting `好用！！`. `build/key-bridge-verification.log` records Enter virtual keycode 36 down/up at 17:31:22, followed by Fn virtual keycode 63 down at 17:31:24.285 (flags 545259520) and up at 17:31:25.616 (flags 536870912); the Fn bit was cleared on release. The current log establishes one Fn down/up pair, not two complete trials or verified OS actions for every control. Excerpts are retained in the [vendor key routing record](evidence/2026-09-21-vendor-key-routing.log).

The earlier conclusion that keys use standard HID without Studio applies only to the then-observed state without this heartbeat. Presence of the official Studio process is not the only condition: Olanzi sending the same heartbeat also changes the reporting path. Long-term sleep prevention still needs independent measurement; a key-path transition does not establish that sleep is solved.

[CONFIRMED] Source comparison on 2026-09-23: [OpenVibeKey background heartbeat](https://github.com/palaemonboy/OpenVibeKey/blob/c9970faa126cb2ee355571ecd79901e397f49574/native/VibeKit/Sources/VibeKitApp/VibeVM.swift#L544-L567) actually reads battery every three seconds; its [power interface](https://github.com/palaemonboy/OpenVibeKey/blob/c9970faa126cb2ee355571ecd79901e397f49574/native/VibeKit/Sources/VibeKitHID/VibeKitDevice.swift#L134-L155) distinguishes on-device standby and sleep durations. Olanzi previously stopped only the dedicated heartbeat on idle pause, continuing online queries every two seconds and battery reads every 20 seconds. The fix pauses both background requests while retaining receive callbacks, USB removal detection, and explicit user queries. Automated tests cover no background requests after pausing and resumed polling afterwards.

[INFERRED] Remaining queries may interfere with firmware idle timing; source comparison cannot establish the effect of individual requests on the current firmware. Automatic sleep timing after the fix has not been measured, and this fix does not change on-device standby or sleep settings.

[CONFIRMED] Subsequent user feedback was that the device lights came on but configured actions did not respond; the running UI still showed an idle keepalive pause. The pause latch required manual resumption, vendor input did not clear it, and returned standard HID input was not monitored. The fix adds an AU05-specific passive standard input listener and lets physical activity on either input path request resumption after all controls release and trailing reports drain for 100 ms. The wake gesture is not replayed. This listener sends no device queries; failures are reported and manual resumption remains available. Automated tests cover both input paths, held-control isolation, listener errors, and no background requests while paused; the complete physical wake path still requires hardware verification.

## 5. Reproduce Without Writing Configuration

```bash
python3 tools/check_keepalive.py --seconds 60 --interval 2
python3 tools/check_keepalive.py --mode studio --seconds 60 --skip-idle --check-keys
```

The default mode compares idle with Hooks polling. Studio mode uses the confirmed heartbeat, with a default one-second interval, and can switch to the vendor key-event path above; do not rely on direct ordinary-key injection during that run. `--skip-idle` runs only the selected mode. `--check-keys` reads all six controls before and after the window and compares their configuration bytes; these reads may affect the initial awake state, so they are explicitly reported and excluded from the timed window. The checker exits without starting the window if the baseline is not confirmed online.

For a longer causal test, start each mode from a physically awake device, keep power conditions unchanged, avoid operating its controls, and measure beyond the observed sleep timeout. Do not long-press the power key. Online status describes the wireless connection and does not prove that every indicator or power-saving subsystem is awake. Do not infer shutdown from missing replies.

## 6. Evidence

| Artifact | Contents |
|---|---|
| [Comparison log](evidence/2026-09-21-keepalive-comparison.log) | Raw status prefixes, elapsed times, reply counts, and incomplete attempt |
| [Studio disassembly](evidence/2026-09-21-studio-heartbeat-disassembly.log) | Constructor, worker call site, clock units, and interval constant |
| [Workspace round trip](evidence/2026-09-21-workspace-roundtrip.log) | Real F13 write, acknowledgment, readback, and restoration |
| [90-second service observation](evidence/2026-09-21-workspace-heartbeat90.log) | Online state, heartbeat timestamps, and unchanged six-control snapshots |
| [Vendor key routing record](evidence/2026-09-21-vendor-key-routing.log) | Heartbeat comparison, six-control events, and the scope of physical Enter / Fn validation |
| [Checker](../tools/check_keepalive.py) | Standard-library vendor-interface measurement tool |

The logs retain no complete device-unique identifiers. They do not claim that a dongle response alone proves the device body is awake.
