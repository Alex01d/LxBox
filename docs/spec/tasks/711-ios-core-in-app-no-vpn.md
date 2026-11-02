# 711 — iOS: run the core inside the app, without a tunnel

| Field | Value |
|-------|-------|
| Status | Implemented, passes on Simulator, partly checked on a real iPhone, not merged |
| Start date | 2026-11-02 |
| End date | |
| Commits | |
| Related specs | [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md), [009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md), [012-LIVE_STATE](../features/012-LIVE_STATE/FEATURE.md), [013-DIAGNOSTICS](../features/013-DIAGNOSTICS/FEATURE.md), [021-CORE_CONTRACT](../features/021-CORE_CONTRACT/FEATURE.md), [022-ARCHITECTURE](../features/022-ARCHITECTURE/FEATURE.md), [026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md); tasks [055](055-mobile-stack-decision/spec.md), [119F](119F-vpn-mode/spec.md), [122F](122F-commandclient-migration/spec.md), [185](185-cold-start-cc-resync.md), [192](192-proxy-mode-prepare-revokes-foreign-vpn.md), [236F](236F-folder-server-testing/spec.md), [276](276-revoked-status-contract.md), [316](316-kernel-crash-reports-access.md), [334](334-on-launch-after-crash-cache-reset.md), [373](373-reload-on-main-thread-anr.md), [705](705-memory-limit-auto-off.md), [710](710-ios-clean-startup.md) |

## Goals

On iPhone 17 Simulator with iOS 26.5 or newer, in the existing Local proxy mode, the real core runs inside the app process and the existing UI drives it through Swift:

- Start and Stop, with honest status.
- Node list and groups on Home, node switch, single and mass ping.
- Stats, connections and core logs.
- Traffic through `mixed-in` reaches a real server.

This is a test bench for work that needs no paid Apple team. Most of it carries over to the tunnel: linking the core, platform interface, status machine and `CommandClient` in Swift. It is not a usable product, see Decisions D2 and Risks.

## Non-goals

- A tunnel, Network Extension, App Group, or system-wide traffic. Those need a paid team, which comes later.
- Traffic from other apps. Only the app that is on screen runs, so nothing else can use the proxy on the device.
- Changing settings, defaults or the template for this limitation (D1).
- Tailscale, Taildrop, OpenConnect, the DNS profiler, connection test, pprof, split tunneling, notifications.
- "Test servers" (`probe*`). It needs its own core session rules from §236F, so it gets a separate task.
- Publishing an iOS core in fork releases (D3).
- `codex/tailscale-awg` and `handshake-fragmentation-fix`.

## Problem

After [§710](710-ios-clean-startup.md) the app starts cleanly, but nothing connects. Tapping Start ends in `MissingPluginException` for `isForeignVpnActive`. `getVpnStatus` is always `Stopped`, `getCoreVersion` is empty, and no core is linked.

## Diagnosis

Evidence from a throwaway build of core `v1.14.4-lx.30-rc.1`, not part of this repo:

- **The core builds and links for iOS.** Device and Simulator slices, 383 MB framework, bind takes 3 to 5 minutes.
- **A real LxBox config starts.** The config generated in §710, with a fake VLESS node, started on the iOS core in 0.2 s, with its inbound swapped for a loopback proxy. It carries `find_process: true`, `auto_detect_interface: true`, 6 rule sets and DNS groups. No error at start.
- **Traffic flows.** 100 MB went through a loopback `mixed` inbound at about 180 Mbit/s, direct outbound. One SSL failure in 6 downloads stays unexplained.
- **The API is there.** Every libbox symbol the Start-to-Stop path uses exists in `Libbox.objc.h`. All Android build tags in `kCoreBuildTags` are in the Apple build too, which adds `with_dhcp` and `with_low_memory`.
- **The path is small.** About 35 native calls. About 700 of the 2026 lines in `BoxCommandClient.kt` serve it. The rest is Tailscale, Taildrop, OpenConnect, profiler and similar.
- **Proxy mode already exists.** `vpn_mode: proxy` builds `mixed-in` with no `tun-in`, and libbox never calls `openTun` (§119F).

Three findings shape the design:

**1. `command.sock` cannot live in `getFilesDir`.** Unix socket paths are limited to 103 bytes on Darwin. On a device:

| `basePath` | Socket path length |
|---|---|
| `Library/Application Support/lxbox` (`getFilesDir`) | 123, too long |
| `Library/Caches` | 104, too long |
| `tmp` | 93, or 101 with `/private`, fits |
| App Group, for the tunnel later | 96, fits |

Simulator container paths are longer than any of these. `SetupOptions.commandServerListenPort` makes the server and client use loopback TCP instead. `cache.db` and crash reports follow `workingPath`, not `basePath`, confirmed in the throwaway run, so `basePath` can be `tmp` without losing selection.

**2. Default memory on iOS is the tunnel's.** With `oomKillerEnabled` and limit 0, `setup.go` applies the Apple default of 50 MB and GC percent 50, whichever process hosts the core. That is useful here, since the core behaves closer to how it will in the extension. `oomMemoryLimitHeap` must be true, otherwise the threshold reads process memory including Flutter (§705).

**3. Spec conflict on errors.** §055 item 6 forbids raw platform errors as the only source of truth. 009 and 010 require the verbatim core text to travel with the reason, and `docs/GUARDS.md` parses it. This task keeps Android's wire format: `error` as the reason, `core_error` as the raw text. A shared error model is out of scope.

## Decisions

Made by the operator on 2026-11-02.

| # | Question | Answer |
|---|---|---|
| D1 | Should settings change so Start works without a tunnel? | No. Default mode stays `vpn`, with no `Platform.isIOS` gate and no template change. Start in VPN mode fails with a clear reason. A developer selects Local proxy in VPN Settings |
| D2 | What happens when the app leaves the foreground? | The core stops cleanly and the app shows Disconnected. The user taps Start on return. No automatic restart. See "Background" below |
| D3 | Where does the iOS core come from? | A local build script from the pin, not in git. Dev-only, because nothing ships on iOS. Fork release assets come before real distribution |
| D4 | Which branch? | `ios-app`, with §710. All iOS work stays on this branch until one PR goes to the original repo |

## Solution

Swift replaces the Android native layer for this path. Dart stays as it is. **Expected Dart diff: none.** If implementation shows one is needed, stop and raise it.

### Files

- New `scripts/build-libbox-ios.sh`, see "The core binary".
- New in `app/ios/Runner/`:
  - `CoreRuntime.swift`: paths, crash check, `LibboxSetup` once at launch.
  - `CorePlatform.swift`: `LibboxPlatformInterface` and `LibboxCommandServerHandler`.
  - `CoreService.swift`: status machine, start, stop, reload, status and log sinks.
  - `CoreCommandClient.swift`: status, screen and ping clients, RPCs, serializers.
- `LxBoxChannels.swift`: route the methods below.
- `project.pbxproj`, `.gitignore`: link the framework, keep it out of git.

### Rules

1. **Four statuses only:** `Starting`, `Started`, `Stopping`, `Stopped`, with `error`, `core_error` and `revoked` as on Android. Every teardown ends in exactly one `Stopped`, because the stop waiter depends on it (010, §276).
2. **Honest transitions.** `Started` only after the core confirms. A late `Started` after a stop has begun is dropped. A repeated status without an error is not sent. Start while not `Stopped` is ignored. Start waits for `LibboxSetup` to finish.
3. **Stop ladder.** `stopVPN` replies only after `Stopped`, without blocking the main thread. Native wait 9 s stays below Dart's 10 s, and emergency stop stays at 12 s. Each core handle closes once. `close()` runs before `closeService()`.
4. **Reload** is an in-place `startOrReloadService`, with no status change, only while `Started`. The 3 s cooldown lives in Dart, as on Android.
5. **Threads.** Start, stop, reload, `checkConfig` and RPCs run off the main thread (§373). Event sinks and `FlutterResult` run on the main thread, one sink per channel.
6. **Callbacks never throw or trap.** This is the Swift form of the JNI no-throw rule (§122F). No force unwrap on values from libbox.
7. **Two channels stay separate.** Status comes from the status machine, never from `lxbox/cc/*` (`docs/ARCHITECTURE.md`, 012). Dart's subscribe, then resync, then connect-screen order is kept (§185).
8. **Config goes to the core unchanged.** No native edit of listen, port, users or protocol (010 P6). No new listener besides `mixed-in`. Android's `stripClashApi` is not ported, because iOS has no old stored configs, and a stray `clash_api` is a fatal core error that reports itself.
9. **Core rejection text is verbatim** in the `Stopped` event (`docs/GUARDS.md`). `checkConfig` runs with no service. The two-starts-per-press rule stays in Dart.
10. **Paths.** `workingPath` is the `getFilesDir` folder (§316). `tempPath` is `Library/Caches/lxbox-core`, because crash recovery empties it. `basePath` is `tmp` on a device. In Simulator only, `commandServerListenPort` with a random `commandServerSecret`, behind `#if targetEnvironment(simulator)`.
11. **Setup.** `crashReportSource = "lxbox"`, `logMaxLines = 3000`, `oomKillerEnabled = true`, `oomMemoryLimitHeap = true`, `oomMemoryLimit` from the stored preset, `debug` from `core_logs_enabled`.
12. **Launch order** (§334). Check for a non-empty crash log, clear `cache.db` and temp with a log line, then `LibboxSetup`. Report rotation stays where Dart runs it.
13. **VPN mode (D1).** `openTun` fails with `VPN mode needs the iOS tunnel, which is not built yet. Select Local proxy in VPN Settings.` That arrives as a normal `Stopped` with a reason.
14. **No fake success.** `isForeignVpnActive` answers `false`, since no other VPN can be detected here. It is not a claim about the tunnel.
15. **Container moves.** iOS moves the app container on reinstall and update, and the saved config holds absolute rule-set paths. When `NSHomeDirectory()` changes, the saved config is deleted before Dart starts, and Dart rebuilds it (§414).
16. **Details that are easy to break**, kept here because the Swift has no comments:
    - Native pref defaults match `docs/STORAGE.md`. Native-to-JSON seeding runs once, so a wrong answer sticks.
    - Memory presets `auto` and unknown give 0, which the core treats as its Apple default. A reload reads only the OOM fields.
    - In a URL test, `error` is the only success signal. Delay 0 with no error is a 0 ms success.
    - `ops` serializes client lifecycle, because `connect` blocks. Clients stop before the command server closes.
    - The core sends its connections reset once per subscription, so a new listener gets the snapshot replayed.
    - The log queue drops the newest line on overflow, so the core never blocks on the UI.
    - `formatConfig` answers null when the core cannot format, and the caller treats the config as changed (§324).

### Background

Only a Network Extension process keeps running after an app leaves the foreground. A core inside the app freezes when iOS suspends the app, and its sockets die. 012 says "Connected" survives a minute in the background, and that cannot hold here.

Per D2, on `didEnterBackground` the core stops inside a short background task, ending in `Stopped`. Returning shows Disconnected, and Start is a tap away. Starting again on return was rejected, because it adds code the tunnel will delete and can hide start failures.

### What Swift answers

Channel `com.leadaxe.lxbox/methods`, real behaviour:

| Method | Behaviour |
|---|---|
| `startVPN`, `stopVPN`, `forceStopVPN`, `reloadVPN` | Rules 1 to 4 |
| `getVpnStatus` | Current status and `revoked` |
| `getTunnelUptimeMs` | Time since `Started`, 0 if not running |
| `getCoreVersion` | `LibboxVersion()`, replaces the §710 empty string |
| `checkConfig`, `formatConfig` | `LibboxCheckConfig`, `LibboxFormatConfig` |
| `getMemoryInfo` | Same keys as Android, from `task_vm_info`, so the Stats sheet does not hang |
| `resetNetwork`, `clearDnsCache` | Through the command server, or no-op with `true` if not running |
| `setMemoryLimit`, `setCoreLogsVerbose` | Stored as in §710, plus applied live via `LibboxReloadSetupOptions` and the log filter |
| `ccGetRunningConfig`, `ccResyncForReopen`, `ccConnectScreen`, `ccDisconnectScreen` | `CommandClient`, screen client reference-counted as on Android |
| `ccPauseClients`, `ccResumeClients`, `ccSetStatusFast` | Status interval 500 ms or 100 ms |
| `ccGetGroups`, `ccGetOutbounds`, `ccSelectOutbound` | Unary RPCs. Serialized keys match `BoxCommandClient.kt` |
| `ccUrlTestOutbound`, `ccUrlTestGroup`, `ccCancelPing` | Ping client |
| `ccCloseConnection`, `ccCloseConnections` | Unary RPCs |

Accepted with no effect, because iOS has no such surface here:

| Method | Answer |
|---|---|
| `isForeignVpnActive` | `false` |
| `setNotificationTitle`, `setNotificationText`, `setAutomationActiveState` | `true` |
| `getCurrentSessionAllowBypass` | `false` |
| `areNotificationsEnabled` | `true`, otherwise App Settings never finishes loading |

Event channels, now emitting:

| Channel | Payload |
|---|---|
| `com.leadaxe.lxbox/status_events` | Status map, transitions only |
| `lxbox/coreLog` | `List<String>`, batches up to 200, queue 4096, TRACE and DEBUG dropped unless verbose |
| `lxbox/cc/status` | 9 ints, same keys as Android |
| `lxbox/cc/groups`, `lxbox/cc/outbounds` | Same maps as the unary RPCs |
| `lxbox/cc/connections` | Full snapshot from the delta accumulator, re-emitted on listen |

Everything else stays `FlutterMethodNotImplemented`. Known result: Dart catches `ccGetDnsGroups`, the Tailscale, Taildrop and connection test families, `getAppInfo` and `getLogcatTail`. `probe*`, `ccGetUrlViaOutbound`, `getInstalledApps`, `getPool` and some Settings buttons surface an error, which is accepted for this task.

### The core binary

`scripts/build-libbox-ios.sh` mirrors `scripts/fetch-libbox.sh`:

- Reads `app/android/libbox.version`, the single pin (021). No second pin.
- Clones `Leadaxe/sing-box-lx` at that tag, with the 4 `submodules/*`, in a private folder. `git describe` must give `-lx.N`, because version gates fail open otherwise. The script fails if `git describe --exact-match` does not match the pin.
- Uses the Go version from the core's `go.version`, in a private folder, with no system install.
- Runs `build_libbox -target apple -platform ios`, which gives device and Simulator slices.
- Writes `app/ios/Frameworks/Libbox.xcframework` and a `.libbox.version` marker. Idempotent. Both are gitignored.

**Exception to 021, stated on purpose.** 021 and `docs/KERNEL.md` require a release artifact with a `SHA256SUMS` check for production, and forbid shipping local builds in a release. This binary has no published hash and must not ship. iOS has no release, so nothing is violated today. Before any real distribution, the fork's release job needs an iOS artifact and a hash. That is the fork's decision, not an LxBox edit.

Linking needs `-lresolv -lc++` and the `SystemConfiguration`, `Security`, `CFNetwork`, `CoreFoundation`, `Foundation` and `UIKit` frameworks, because gomobile's static framework does not carry its cgo inputs.

### Swift names that differ from Kotlin

Found in the throwaway build, listed so nobody re-derives them: `usePlatformAutoDetectControl`, `autoDetectControl(_:)`, `send(_:)` for notifications, `write(_:)` overloads for connection events and DNS queries, `Connection.id_`, getters as properties (`uplink`, `urlTestDelay`, `isExpand`), and `Network.NWPath` to resolve an ambiguity.

### Rejected

- **Force proxy mode on iOS.** Rejected by the operator (D1). It would change settings behaviour for a temporary limitation.
- **Rewrite the tun inbound to a proxy in native code.** The core would run a config the app did not build, and `getRunningConfig` and rules bound to `tun-in` would disagree.
- **Port all of `BoxCommandClient.kt`.** About 1190 lines serve features outside this path. They come with their own tasks.

## Risks and edge cases

- **Promises that do not hold here.** Keep VPN on exit, autostart, recovery, silent-core check, network-change reset, tunnel sleep, service notification, background ping and profiler, and reopen after swipe all assume a service that outlives the UI (010, 012, 009, 013). Settings for them stay visible. Each feature doc gets a short iOS note, see Docs.
- **`Started` overstates things.** The app says Connected while the phone's traffic does not use the core. Android's proxy mode has the same trait, but there the user chose it. Accepted, since this build is for developers.
- **Memory.** There is no 50 MB kill in the app process, so passing here proves nothing about the extension.
- **Device differs from Simulator.** Simulator uses TCP for the command channel and a device uses the socket in `tmp`. Only a real iPhone tests the second. A Personal Team can install this mode, since it has no Network Extension entitlement.
- **Process lookup.** `find_process: true` started fine, but per-connection lookup on iOS is untested, because `findConnectionOwner` is unavailable. Check for log noise.
- **TLS trust.** `certificate.store: system` against a real server is untested on iOS.
- **Real server test.** Needs a real link from the operator. It stays in the Simulator, never in the repo or logs.
- **SSL failure.** One unexplained failure in 6 downloads in the throwaway run. Watch for it.
- **Flutter version.** Local builds use 3.47.9, the repo pins 3.47.1.
- **Docs drift.** `docs/ARCHITECTURE.md` shows `getVpnStatus` returning a bare string, and `docs/BUILD.md` and 021 quote old pins. The first is fixed here. The others are upstream's, and are only noted.

## Verification

Manual, debug build, iPhone 17 Simulator with iOS 26.5, core at the pin.

1. `scripts/build-libbox-ios.sh` runs from clean, and a second run exits fast. `getCoreVersion` equals the pin.
2. All §710 checks still pass.
3. Default VPN mode, with a server: Start goes `Starting` then one `Stopped` with the rule 13 reason. No crash and no stuck state.
4. Select Local proxy, Start: `Started` only after the core confirms, uptime counts, Home shows groups and nodes.
5. Ping one node and mass ping: a fake node reports an error, a real node reports a delay.
6. Switch node, stop, start: selection survives (`cache.db`).
7. From the Mac, `curl` through `127.0.0.1:2080` with the configured auth reaches the internet through a real server. Stats counters move and the connection is listed. Close it from the UI.
8. Core logs on, relaunch: lines appear. Off: none.
9. Stop: `stopVPN` returns true after `Stopped`, and the port is closed. Five Start and Stop cycles run clean.
10. Tap Stop during `Starting`: no late `Started`. Tap Start during `Stopping`: ignored.
11. A config the core rejects: `Stopped` carries the verbatim rejection text, and the auto-disable flow works.
12. Plant a non-empty crash log, relaunch: `cache.db` is cleared and logged, then setup archives the report.
13. Leave the app while running: one `Stopped`, port closed. Return: Disconnected, no automatic start, and Start works. Kill the app while running, relaunch: `Stopped`.
14. Android unchanged: `git diff develop --stat` shows nothing under `app/android/` and no Dart change. `flutter analyze` adds no issues. Tests that bear on the change pass. The full suite is CI-only.

Run on a real iPhone with the Personal Team once before calling this done, for the socket path and real suspension.

### Results, 2026-11-02

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, Xcode 26.6, core `v1.14.4-lx.30-rc.1`. **Expected Dart diff held: none.**

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | Clean run built the framework, second run exited in 0 s |
| 2 | Pass | Fresh install starts clean |
| 3 | Pass | One `Stopped`, the rule 13 reason on screen and in the log, no crash |
| 4 | Pass | `Connected` after the core confirmed, uptime counted, groups and nodes shown |
| 5 | Pass | Fake node `ERR`, real node 80 ms, Direct 157 to 375 ms |
| 6 | Pass | Selection moved to the tapped node and survived a relaunch |
| 7 | Pass | 100 MB at 192 Mbit/s through a real VLESS REALITY node. No auth was refused. Stats moved. Closing from the UI cut the live download, curl exit 56. Exit IP was the server, but that alone proves nothing on this Mac, see "Exit IP" below |
| 8 | Pass | Lines reach `corelog.txt` with forwarding on, none with it off |
| 9 | Pass | Port closed after Stop. Repeated cycles ended clean |
| 10 | Partly | A burst of 6 fast Start and Stop taps ended `Disconnected`, port closed, no stuck state. Tool taps are too slow to prove a stop landed inside `Starting` |
| 11 | Pass | `initialize outbound[4] vless[…]: invalid public_key` arrived verbatim, the node was disabled, the second start connected |
| 12 | Pass | `cache.db` and temp cleared, report archived to `crash_reports/`, log truncated, the app's crash banner appeared. The `NSLog` line was not found with `log show` |
| 13 | Pass | Leaving the app closed the port in 0.9 s, return shows `Disconnected` with no auto-start. Kill then relaunch: no listener, `Disconnected` |
| 14 | Pass | Nothing under `app/android/`, `pubspec.lock` unchanged. `flutter analyze`: no issues. 39 tests pass in 5 related files. Full suite on CI, before the merge below: 7441 passed, 37 skipped, Flutter 3.47.1. CI runs on Linux, so it does not compile the Swift |

### Results on a real iPhone, 2026-11-02

Release build on iPhone 15 with iOS 26.3.1, core `v1.14.4-lx.30-rc.1`, signed by a Personal Team in a throwaway copy of the project. This is not the target device, so it tests device behaviour only.

| Check | Result | Evidence |
|---|---|---|
| Install | Pass | Listed on the phone, opens after trusting the developer |
| Default VPN mode | Pass | Rule 13 reason in `applog.txt`, empty crash log |
| Local proxy, Start | Pass | Operator saw Connected. A device has no loopback command port, so the server listened on the socket in `tmp` |
| Leave and return | Pass | Operator saw Disconnected on return. No socket listed in `tmp` afterwards |
| Traffic through the node | Not checked | Nothing on the phone can reach the proxy, see below |
| OOM false alarm | Not checked | Needs `corelog.txt`, and core logs were off |
| Command client over the socket | Not checked | Connected comes from the status machine, not the client |

### Re-check after merging `develop`, 2026-11-03

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, Xcode 26.6, core `v1.14.4-lx.30-rc.3`, the new pin. The merge had no conflicts and no change to Swift.

| Check | Result | Evidence |
|---|---|---|
| Core script | Pass | Rebuilt for the new pin, second run exited in 0 s |
| Build and analyzer | Pass | Swift compiles against the new core. `flutter analyze`: no issues. 70 tests pass in 3 related files |
| New native methods | Accepted | `develop` added 7, all Taildrop, a non-goal here. No exception in `applog.txt` after a start and stop |
| Local proxy, Start | Pass | `Connected`, groups and nodes shown, real node 91 ms, fake node `ERR` |
| Traffic | Pass | 105 MB at 171 Mbit/s. The connection list shows `mixed-in`, then `final`, the VPN group and its auto group. Home shows the real node as that group's active member. No auth got 407 |
| Leave and return | Pass | Port closed about 1.5 s after leaving, no listener on return. Crash log empty |
| Errors | Known | Only the Simulator OOM line below. The crash banner on screen was the report planted for check 12 |

The full suite has not run on this merge. A push to `ios-app` runs no CI, so start CI by hand.

### Found during implementation

- **Exit IP.** This Mac runs its own tunnel through `singbox-launcher`, so its direct traffic exits from the same server as the test node. Exit IP cannot show which path a request took here. The connection list and the node's own ping are the evidence.

- **Renumbered.** These tasks began as 708 and 709, and the original repo took both numbers for other tasks on the same day. Numbers are not reused, so they became 710 and 711. Three commit subjects keep the old numbers (`3963cf62`, `9f14db69`, `518153ec`). Check again that the numbers are free before the PR to the original repo.
- **An IP checker outside LxBox shows the phone's own address while the app says Connected.** Expected, per Non-goals and the `Started` risk. Nothing sends that traffic to `mixed-in`, and leaving LxBox stops the core anyway. LxBox's own check, node Diagnostics (§392), needs `ccGetUrlViaOutbound`, so the phone cannot show the exit address yet.
- **A bundle ID override breaks device install.** `PRODUCT_BUNDLE_IDENTIFIER` on the `xcodebuild` command line reaches every target, so embedded frameworks get the app's ID and iOS refuses with `DuplicateIdentifier`. Change it for `Runner` only, in a throwaway copy of the project.
- **The core keeps a copy of the config in `basePath`.** `saveConfigSnapshot` writes `configuration.json`, node credentials included, at each start, and it stays after Stop. On a device that is `tmp`, on Android `filesDir`. It holds the same data as `singbox_config.json`, under the same sandbox.
- **Container moves broke Start after a reinstall**, with `parse rule-set: open …/Application/<old id>/…`. Android paths do not move, so no spec covered it. Fixed by rule 15.
- **OOM service fires in Simulator.** `os_proc_available_memory()` returns 0 there, so the core logs `memory threshold reached, available: 0 B, resetting network` once per start. This is why the Errors banner shows on Simulator. The template's `oom-killer` service wins over `SetupOptions`, so native code cannot turn it off without editing the config. Check that it is absent on a real iPhone.
- **`reality verification failed` on the test node is not specific to iOS.** A Mac build of the same core failed the same way with three fingerprints and `key_share: classical`. TLS Record Fragment fixed it on both. The cause is open: both runs shared this Mac's path, which has its own tunnel (see "Exit IP"), so the network and that tunnel are not separated.
- **Method names.** The `BoxCommandClient` RPC names in the first inventory were wrong for close. A check of all 108 Dart method names against Swift found no other mismatch.
- **Config text.** Android's `stripClashApi` is not ported (rule 8), and `CacheDbLockRetry` is not ported either, because nothing has failed on it. Add it if a `cache.db` lock appears.

## Unresolved / follow-up

- Rest of the real iPhone run: traffic through the node, OOM false alarm, command client over the socket, whether `reality verification failed` appears on a path without this Mac's tunnel, and the target device (iPhone 17, iOS 26.5 or newer).
- Full suite on the merge with `develop`.
- Conns tab after leaving the app while it is open: it keeps the last list, with one row shown as active, after the core has stopped. Not compared with Android.
- Node Diagnostics (§392) on iOS: `ccGetUrlViaOutbound` while Connected, `probeGetUrl` with "Test servers".
- Tunnel: Network Extension, App Group, real memory limit. Needs the paid team, which the project owner provides later.
- "Test servers" (`probe*`), which must also work once the tunnel exists.
- A shared error model, per §055 item 6.
- An iOS artifact and hash in fork releases, before real distribution.
- Hide settings with no meaning on iOS.
- A per-platform convention in feature specs, since `docs/spec/features/README.md` does not define one.
- Speed test path on iOS: the app's own HTTP client does not use `mixed-in`.
- The typed VLESS link rejected in §710.

## Docs to update

With implementation:

- `docs/ARCHITECTURE.md`: iOS paragraph in Channel Contract, the `getVpnStatus` row, iOS in VPN Lifecycle and CommandClient, Supported platforms.
- `docs/KERNEL.md`: iOS core provenance, Apple tag set, the 021 exception.
- `docs/BUILD.md`: the build script and Simulator section.
- `docs/STORAGE.md`: iOS `basePath`, `workingPath`, `cache.db`, crash folders, `has_tun`.
- `docs/SECURITY.md` and `.ru.md`: "TUN-only inbound" does not describe iOS in Local proxy mode.
- `docs/spec/features/021-CORE_CONTRACT/FEATURE.md` and `.ru.md`: iOS delivery and the exception.
- One-line iOS note plus a Revisions row, EN and RU, as in `first-run.md`: `010-VPN_SERVICE` tunnel-control, `012-LIVE_STATE` connection-status, `009-NODE_HEALTH` node-ping, `013-DIAGNOSTICS` crash-reports and core-log, `003-CONFIG_BUILD` settings-lifecycle, `007-NODE_LIST` empty-states.
- `docs/spec/tasks/710-ios-clean-startup.md`: mark the Start risk and the follow-up as handled here.

Stated as none: `docs/api/debug-api-reference.md` (no route change), `CHANGELOG.md` and release notes (nothing ships on iOS), `docs/l10n.md` (rule 13's reason is developer-facing English, like other core errors), template and registry files.
