# 712 — iOS: "Test servers" in the app-process core, and a failed core call ends the test

| Field | Value |
|-------|-------|
| Status | Implemented, passes on Simulator, not merged |
| Start date | 2026-11-03 |
| End date | |
| Commits | |
| Related specs | [009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md) with [server-list-test](../features/009-NODE_HEALTH/FUNCTIONS/server-list-test.md) and [node-diagnostics](../features/009-NODE_HEALTH/FUNCTIONS/node-diagnostics.md), [015-WARP](../features/015-WARP/FEATURE.md); tasks [236F](236F-folder-server-testing/spec.md), [286](286-probe-lifecycle-halt.md), [296](296-folder-probe-controller.md), [392F](392F-node-diagnostics/spec.md), [518](518-naive-probe-batch-oom.md), [523](523-wireguard-probe-batch-memory.md), [669](669-probe-session-cancel-stop-timeout-race.md), [703](703-cache-db-lock-timeout-retry.md), [711](711-ios-core-in-app-no-vpn.md) |

## Goals

- On iPhone 17 Simulator with iOS 26.5 or newer, "Test servers" gives every node of a folder or subscription its own result, with the core inside the app process and no tunnel.
- On all platforms, a probe call that throws ends the run with a visible error.
- On all platforms, Stop always ends the run, even if a native call never replies.

## Non-goals

- A tunnel, or a test that keeps running after the app leaves the foreground (§711 D2).
- `ccGetUrlViaOutbound`, so Diagnostics while Connected stays unavailable on iOS. Diagnostics with the core stopped gains `probeGetUrl` here.
- Kotlin changes. `ProbeSession.kt` already behaves as §669 says.
- Android's `CacheDbLockRetry` (§703), unless a `cache.db` lock appears in the Simulator run. §711 made the same call.

## Problem

Seen on 2026-11-03, iPhone 17 Simulator, iOS 26.5, branch `ios-app`, in the "WARP GENERATOR" folder. Test shows `Testing… 0 done` forever. Stop changes it to `Stopping…` forever. Leaving the screen is the only way out. `applog.txt` has:

```
Uncaught async: MissingPluginException(No implementation found for method probeStart on channel com.leadaxe.lxbox/methods)
```

§711 listed `probe*` among the methods that "surface an error". They don't, they hang. Mass ping on Home works through `ccUrlTestOutbound`, so this does not block other iOS work.

## Diagnosis

**Hang.** `ProbeRunner.run` has `try`/`finally` and no `catch`. A throw from `_cc.probeStart` leaves `run`, and `_runProbe` in `folder_detail_screen.dart` and `subscription_detail_screen.dart` never reaches the code that clears `_testing` and `_stopping`. Any throw in `_runPool` or from `probeStop` does the same. The screens already show the text `run` returns, so nothing is wrong there.

Other callers of `run` are safe once it stops throwing: the Debug API maps its text to an upstream error. Node Diagnostics has its own `catch` in `node_diagnostics_tab.dart` and needs no change.

**Android has no such hang in practice,** because `ProbeSession.kt` wraps everything and answers with a map. Only a channel failure throws there. The `catch` still belongs in shared Dart.

**Two command servers cannot run together on iOS, for the same reason as Android.** `LibboxSetup` runs once per process and fixes one command endpoint. In Simulator that is TCP port 54345. On a device it is `tmp/command.sock`, and `CommandServer.Start` removes an existing socket file, so a second server would take the first one's socket.

**What differs from Android:**

- There is no `DefaultNetworkMonitor` to start. `CorePlatform` opens `NWPathMonitor` when the core asks for it.
- `oomKillerEnabled` makes the core add an `oom-killer` service to any config that lacks one, so the test session gets the same limit as the in-app core. On iOS, preset `auto` means the 50 MB Apple default (§711 finding 2). Android's measured 17.5 MB per WireGuard endpoint (§523) may not hold, because the Apple build sets `with_low_memory`. Check this in the Simulator run.

## Decisions

| # | Question | Answer |
|---|---|---|
| D1 | How does the test session coexist with the in-app core? | Exclusive, as on Android (§236). Pavel, 2026-11-03. See "Coexistence" |
| D2 | Should Stop have a time limit, on all platforms? | 10 s, proposed to Pavel on 2026-11-03. He raised no objection but has not explicitly approved it, and he can still veto it. It adds to §669, which records the addition |
| D3 | What do nodes show when a core Start ends a test early? | They stay not tested, so "Disable unreachable" cannot turn off a node nobody measured. The Dart part stays shared, with no native change on Android. Pavel, 2026-11-03 |

### Coexistence

- Core not `Stopped`: the existing "VPN is running" popup with Stop VPN, then the test starts. No Dart gate change.
- Core comes up between the gate and `probeStart`: native answers `VPN is running`, and Dart shows the same popup (`kProbeVpnRunning`).
- Start tapped during a test: the core wins, and the test session closes before the core's server starts.
- Leaving the app: the test session closes inside the same short background task as the core. Dart also cancels the run on app pause (§286).

Rejected: testing through the live core while Connected. §236 removed that on purpose, because it measures through the active detour and leaves out disabled nodes.

When the tunnel arrives, the core moves to the extension process and the test session stays in the app. Both use one `command.sock` path, so `getVpnStatus` and the native `VPN is running` answer are what keep them apart, per P9 in 009 ([§718](718-ios-packet-tunnel.md)).

## Solution

### Dart, all platforms

In `app/lib/services/probe/probe_runner.dart`:

1. `run` moves its batch loop to `_runBatches` and catches everything it throws. It logs the error and returns `Error: <text>`, built from `formatUserError`. Both strings already exist, so no new translations.
2. A worker whose `probeUrlTest` throws calls `cancel()` and rethrows, so the other five stop and the session closes. A throw is a channel failure, not a verdict on the node, so it is a run error and not an `err` badge. Per-node errors still arrive inside the result map.
3. A throw from `probeStop` in `finally` reaches the same `catch`.
4. `cancel()` during a run starts a 10 s timer. If `_runBatches` has not finished by then, `run` fails with `TimeoutException`, which shows as `Error: timeout 10s`. The leftover `_runBatches` closes its session when the native call returns, and §669's run IDs stop it from touching a newer run. The normal path takes at most 3 s (the native close cap), so this timer only fires when a native call does not reply. A throw also goes through `cancel()`, so a throw plus a hung call still ends with an error.

5. A reply of `probe session not running` means the session closed under the run, which happens when a core Start takes priority. The runner handles it like `stale run`: it stops, and the node gets no verdict. The run returns no error, because the user asked for the Start.

The screens do not change.

### Swift, D3

`urlTest` in `CoreProbeSession.swift` checks the session again after a failed measurement. If the session closed meanwhile, it answers `probe session not running` in place of the transport error, so measurements cut off by the close also get no verdict. A delay that arrived before the close is kept.

`ProbeSession.kt` stays as it is. Android still gets item 5 from the shared Dart, so nodes not yet reached stay not tested. Up to six measurements cut off by the close still read `err` there.

### Swift

New `app/ios/Runner/CoreProbeSession.swift`, which follows `ProbeSession.kt` and §669:

1. **One session object.** `runId`, server, client and platform live and die together. `runId` comes from a counter that only goes up.
2. **Own platform per session.** A close that outlasts its cap would otherwise cancel the next session's `NWPathMonitor`.
3. **`start`** answers `{error, runId}`. Starting over a live session restarts it, and the old owner then gets `stale run`.
4. **`urlTest`, `getUrl`** check `runId` first. A stale ID answers `stale run`, and a cancelled run answers `probe run cancelled`, with no throw. Result keys match the Dart `fromMap` readers. In a URL test, `error` is the only success signal (§711 rule 16).
5. **`cancel`** marks the run and disconnects its client, which aborts the dials already sent to the core (§175). It takes no lock held across a long call.
6. **`stop(runId)`** with a stale ID does nothing. The internal `stop()` closes whatever is live.
7. **Close** runs `close()` then `closeService()` on its own thread, and waits at most 3 s. A close that overruns is logged and left to finish.
8. **Threads.** `start` and `stop` run on `CoreService`'s serial queue, so they cannot overlap the core's start and teardown, and the "core is running" check holds. `urlTest`, `getUrl` and `cancel` run off the main thread and off that queue. Replies go to `FlutterResult` on the main thread (§711 rule 5).
9. **Callbacks never throw or trap** (§711 rule 6).

`CoreService` gains the gate on `probeStart`, closes the session at the top of `runStart`, and closes it on `didEnterBackground`. `LxBoxChannels.swift` routes `probeStart`, `probeUrlTest`, `probeGetUrl`, `probeCancel` and `probeStop`. `project.pbxproj` gets the new file. Android's text for the refusal is `VPN is running — test uses the live tunnel instead`. Dart only matches `vpn is running`, and iOS answers `VPN is running`.

## Risks and edge cases

- **The test takes the command port.** While a test runs, port 54345 belongs to the test session. All Simulators on a Mac share loopback, so two LxBox Simulators testing at once collide, and the second shows a start error. Nothing ships this way.
- **`configuration.json` in `basePath`** holds the test config after a run, node credentials included (§711 "Found during implementation"). Android does the same. Same sandbox as `singbox_config.json`.
- **A full run costs one core start per batch.** The generated "WARP GENERATOR" here has 4 WireGuard and 16 MASQUE nodes, so one session. A list with 100 WireGuard nodes would need 25 starts, and each close may wait up to 3 s.
- **Abandoned native call.** After the 10 s timer, the session can still be up until the call returns. The next `probeStart` restarts it and core Start closes it.
- **Memory.** No 50 MB kill exists in the app process, so a pass here says nothing about the extension (§711).

## Verification

Debug build, iPhone 17 Simulator with iOS 26.5 or newer, core at the pin. Reuse the cached WARP registrations and do not tap Re-register. Never print or commit keys or tokens from `lxbox_settings.json`.

1. "WARP GENERATOR", core stopped, Test: every node ends with a verdict and the summary is right. Log the time, the session count and any `oom` line.
2. Stop mid-run: `Stopping…`, then Start is available within about 3 s. Start again: a new run in a new session.
3. Force a failure: a build with the `probeStart` case removed gives a visible error and Start comes back. Same for `probeUrlTest`.
4. Subscription list: Test and Stop work the same.
5. Core Connected, Test: popup, Stop VPN, then the test starts by itself.
6. Start during a test: the test ends, and the core reaches `Connected`.
7. Leave the app during a test: port 54345 closes, and return shows Start available. Core Start still works after that.
8. Node Diagnostics with the core stopped gives a result through `probeGetUrl`.
9. Android: nothing changes under `app/android/`. Dart analyzer has no new issues.

Unit tests: `app/test/probe/probe_runner_failure_test.dart` covers a throw from `probeStart`, a missing plugin, a throw from `probeUrlTest` and from `probeStop`, the Stop timer with a call that never replies, and a session closed by a core Start. `app/test/screens/subscription_detail_probe_stop_test.dart` gets the same failure on screen. Also run the existing `probe_runner_cancel_test.dart`, `probe_test.dart`, `node_diagnostics_runner_test.dart`, `probe_lifecycle_test.dart` and `probe_controller_test.dart`.

### Results, 2026-11-03

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, core `v1.14.4-lx.30-rc.3`.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | "WARP GENERATOR", 20 nodes, one session: `10 ok · 10 err`, `13 ok · 7 err`, `12 ok · 8 err`. Tapped errors read `context deadline exceeded`, which is the core's own timeout, and results vary per run. The port was held for about 3 s in the sampled run. No new `oom_reports` entry. The session's own log lines go to `NSLog`, not `corelog.txt`, so the core log proves nothing here. Process peak 556 MB, but this is a debug Simulator process on a Mac and says nothing about a device |
| 2 | Pass | Stop at `Testing… 8 done`: port closed within about 1 s, then `8 ok · 0 err` and Start. Start again gave a full run in a new session |
| 3 | Pass | `probeUrlTest` unrouted: `Error: MissingPluginException(No implementation found for method probeUrlTest…`, port closed, Start back. `probeStart` unrouted, the original bug: same error for `probeStart`, Start back. Port 54345 held by another process: `listen command server: … address already in use`, as text, Start back. Both temporary edits were reverted |
| 4 | Pass | Temporary local subscription with 9 dummy WireGuard and 3 dummy VLESS nodes on 192.0.2.0/24: 3 batches in 9 s, `0 ok · 12 err`, per-node text `(context deadline exceeded \| missing IPv6 local address)`. No `cache.db` lock. Stop mid-run: port closed within 1 s, Start back. Subscription deleted afterwards |
| 5 | Pass | Core Connected, Test: "VPN is running" popup. Stop VPN: port 2080 closed, test started by itself, `12 ok · 8 err`, session closed |
| 6 | Pass | With the folder screen open and a test running, `POST /action/start-vpn` through the Debug API: port 2080 up within about 1 s, `tunnel: connected`. The test ended with `8 ok · 0 err`, and the other 12 nodes stayed `…`, with no `probe session not running`. The same check before D3 gave `8 ok · 12 err` |
| 7 | Pass | Leaving during a run: port closed within about 1 s, same process, return shows partial results and Start. Core Start afterwards reached `Connected`. An earlier attempt failed with `listen tcp 127.0.0.1:2080: bind: address already in use`, because another app on this Mac held the port. It needed no cleanup and disabled no node |
| 8 | Pass | Stopped core, AWG node, Cloudflare trace: `200 · 348ms`, `warp=on`, port closed after |
| 9 | Pass | Nothing under `app/android/`. Dart analyzer has no issues |

### Found during implementation

- **Start during a test marked untested nodes `err`.** The core closes the session, and each remaining `probeUrlTest` answered `probe session not running`, which the runner recorded as a failed node. "Disable unreachable" would then have disabled nodes nobody measured. Fixed by D3. The first run of check 6 showed this as `8 ok · 12 err`.
- **Test sessions overwrite `tmp/configuration.json`.** Anything that copies that file gets the test config, with no inbound and only the tested nodes. A core start overwrites it back. `singbox_config.json` is not touched.
- **User agent.** The Diagnostics reply shows `uag=LxBox-android/2.25.15.1` on iOS, so `resolveAppUserAgent` names the wrong platform. Not changed here.
- **Subscription test bar.** At iPhone 17 width, the first character of `0 ok · 3 err` and `Testing…` sits under the bar's switch. The label starts at a fixed offset. The code is shared, so Android should do the same (§715), not run there. Not changed here.

## Unresolved / follow-up

- Real iPhone run, with the rest of §711's list.
- Android: this Dart change is not checked on a device. The Android path gains only the `catch` and the timer.

## Docs to update

With implementation:

- `docs/spec/features/009-NODE_HEALTH/FUNCTIONS/server-list-test.md` and `.ru.md`: the rule on failure and Stop, a one-line iOS note, a Revisions row.
- `docs/spec/features/009-NODE_HEALTH/FUNCTIONS/node-diagnostics.md` and `.ru.md`: an iOS note and a Revisions row, if check 8 passes.
- `docs/spec/tasks/711-ios-core-in-app-no-vpn.md`: non-goal line, "Everything else stays" paragraph and follow-ups point here.
- `docs/ARCHITECTURE.md`: the test session in the iOS paragraph.
- `CHANGELOG.md`: one `Fixed` line under `[Unreleased]`, because the failure path and the Stop timer reach Android too.

Stated as none: `docs/api/debug-api-reference.md` (no route change, and a thrown call now reaches the error path it already documents), `RELEASE_NOTES.md` and `pubspec.yaml` (no version bump), `docs/l10n.md` (no new strings), template and registry files.
