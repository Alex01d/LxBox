# 718 — iOS: real tunnel through a packet tunnel extension

| Field | Value |
|-------|-------|
| Status | Implemented, works on a real iPhone, part of the checks still open. Not merged |
| Start date | 2026-11-04 |
| End date | |
| Commits | |
| Related specs | [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md) (tunnel-control, operating-modes, foreign-vpn, autostart-and-exit, recovery, network-changes, tunnel-sleep, core-resources), [012-LIVE_STATE](../features/012-LIVE_STATE/FEATURE.md) (connection-status, data-channels), [009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md) (node-ping, server-list-test, node-diagnostics), [003-CONFIG_BUILD](../features/003-CONFIG_BUILD/FEATURE.md) settings-lifecycle, [007-NODE_LIST](../features/007-NODE_LIST/FEATURE.md) empty-states, [021-CORE_CONTRACT](../features/021-CORE_CONTRACT/FEATURE.md), [§700](700-tun-mtu-default-9000.md), [§705](705-memory-limit-auto-off.md), [§710](710-ios-clean-startup.md), [§711](711-ios-core-in-app-no-vpn.md), [§712](712-ios-test-servers-and-probe-failure.md), [§714](714-ios-platform-differences.md), [§716](716-ios-routing-section-check.md), core `SPECS/FEATURES/006-OBSERVABILITY`, core `SPECS/TASKS/148` |

## Goals

On Pavel's iPhone 15, signed for development by GGL Projects, Inc.:

- Start in the default VPN mode sends the whole phone's traffic through the core.
- The tunnel keeps running when the app leaves the foreground, gets swiped away, or the phone locks.
- Home, node switch, ping, stats, connections and core logs work while the core runs in another process.
- Stop, errors and reopening the app behave as on Android.
- We learn the real memory limit and what the full L×Box config costs against it.

## Non-goals

- App Store, TestFlight, or any install beyond this one iPhone.
- Changing `wizard_template.json` or defaults to save memory. If the config does not fit, the work stops and the question goes to Pavel.
- Tailscale, Taildrop and OpenConnect.
- Per-app routing, boot start and notifications. iOS offers an app no way to do them, see "Differences with no choice".
- Any change under `app/android/`.

## Problem

After §711 the core runs inside the app. It only serves Local proxy, it stops when the app leaves the foreground, and no other app's traffic reaches it. VPN mode, the default, fails on purpose with the §711 rule 13 reason. A paid team was missing, and now it exists.

## Diagnosis

### 1. The extension cannot read the app's folders

iOS gives the extension its own sandbox. The only place it shares with the app is an App Group. Everything the core needs lives in the app's container today.

| Data | Today | Who reads it in VPN mode |
|---|---|---|
| `singbox_config.json`, `cache.db`, crash and OOM reports | `getFilesDir`, `Library/Application Support/lxbox` | Extension and app |
| `rule_sets/*.srs` | Dart `getApplicationDocumentsDirectory()`. The config holds absolute paths to them | Extension |
| `command.sock` | `tmp` on a device | Extension and app |
| `memory_limit`, `core_logs_enabled` and other native prefs | `UserDefaults.standard` | Extension and app |

Rule sets are the awkward row. Dart writes them, the config names them by absolute path, and §711 rule 8 forbids editing the config natively. So the path itself must change, and that takes a Dart change, against §711's "Expected Dart diff: none". See D8.

### 2. Android has one process, iOS will have two

On Android the service, plugin and activity share a process (`AndroidManifest.xml` has no `android:process`), so native code calls the running core directly. On iOS the app can only reach the extension through:

- **The command socket.** `CoreCommandClient` already uses it for status, groups, outbounds, node select, URL tests and connections. Those calls need no change.
- **`NEVPNConnection` status.** It replaces the in-process status machine for VPN mode.
- **Provider messages.** `CommandClient` has `ServiceReload`, but no `ResetNetwork` and nothing for memory, so these go through `sendProviderMessage`.
- **Files in the App Group.**

Core logs need care. `writeDebugMessage` fires in the process hosting the core, so in VPN mode it never reaches the app's `lxbox/coreLog` channel. `CommandClient` has a log stream (`WriteLogs`), and the app reads that instead.

### 3. Memory settings mean something else in the extension

`service/oomkiller/policy.go` returns 50 MB in `policyModeNetworkExtension` whenever `UnderNetworkExtension()` is true, whatever the config says. `setup.go` sets the GC ceiling to 4/5 of `oomMemoryLimit`, and with limit 0 on iOS it applies the same 50 MB and GC percent 50.

So a 768 MB preset in the extension would raise the GC ceiling far above what iOS allows, and iOS would kill the process before the core reacted. Core spec 006 also says that under an external limit such as iOS NE the measure is RSS, and the heap flag is for a core living in someone else's process. The extension therefore needs limit 0 and `oomMemoryLimitHeap = false`, unlike §711 rule 11.

### 4. What the spike tells us, and what it does not

`ios-spike/logs/measure-warp-rc3.md`, Simulator only, core rc.3. Live AWG costs about 1.3 to 1.5 MB per node and live MASQUE about 0.4 to 0.7 MB per tunnel. The worst real row comes to about 33 MB as a tunnel estimate.

The spike then ran as a real tunnel on the iPhone 15 on 2026-11-05 (`ios-spike/logs/measure-device.md`). The limit is 50.0 MB, and the core reports `policy: network_extension` with its trigger at 45 MiB. The bare core peaked at 21.7 MB with a 100 MB download at 203 Mbit/s, using the `system` stack and no MTU set in the config. Pavel's real config with one VLESS node idled at 17 to 20.6 MB and peaked at 30.4 MB while browsing with 95 connections open, and iOS did not kill it. Exit traffic went through the node. AWG and MASQUE are still unmeasured, and so is a config with many nodes.

### 5. Simulator cannot run a packet tunnel

Local proxy stays the only way to run the core on Simulator, which is why D2 keeps it. A real iPhone is required for everything in this task, and Pavel approved the iPhone 15 on iOS 26.3.1 for that on 2026-11-04. Memory results from it may not match an iPhone 17.

### 6. Signing state

Team `8E52KZEKAM` (GGL Projects, Inc.). Pavel is App Manager with Access to Certificates, Identifiers & Profiles. Bundle ID `com.gglprojects.lxbox`, because Pavel's Personal Team holds `com.leadaxe.lxbox`. Xcode has signed with the wildcard team profile so far. Network Extension and App Groups need explicit App IDs, which the first build after adding the capabilities registers. The ID change makes this a new app on the phone, so there is nothing to migrate.

## Decisions

Made by Pavel on 2026-11-04.

| # | Question | Android | Answer |
|---|---|---|---|
| D1 | Run the spike on the iPhone before changing L×Box? | n/a | Yes. It gives the real limit and the cost of the real config, see "Spike run" |
| D2 | Keep Local proxy on iOS, core inside the app, stopping on leaving the foreground? | Proxy mode runs in the same service as VPN mode | Keep. Simulator has no other way to run the core |
| D3 | Restart the tunnel automatically after iOS kills it? | Yes. `START_STICKY` plus `VpnWatchdog`, limit 3 per 5 minutes | Not now, decide after measuring. iOS On Demand rules are the only way, and a memory kill could loop. Accepted cost: a killed tunnel leaves the phone on its direct connection until Pavel notices |
| D4 | Ask before replacing another VPN? | Yes, P8, using `TRANSPORT_VPN` | Yes. Answer `isForeignVpnActive` from the `__SCOPED__` keys of `CFNetworkCopySystemProxySettings`. The Dart dialog already exists. A false positive costs one extra question |
| D5 | Memory limit setting on iOS? | Auto, 200, 384, 512, 768 MB | Hide it on iOS. The extension always uses its 50 MB, so the setting would do nothing in VPN mode. The stored value stays for backups |
| D6 | Bring back the Wi-Fi network list (§716 D2)? | Works, needs location permission | Leave hidden. It needs the `wifi-info` entitlement and an iOS location prompt, so it gets its own task |
| D7 | Pause the core when the phone sleeps? | Default `never`. Only `lazy` and `always` pause | Pause, as `sing-box-for-apple` does in `sleep()` and `wake()`. iOS calls these itself and there is no setting |
| D8 | Move the app's durable folders into the App Group? This breaks §711's "no Dart diff" | n/a | Yes, with one small Dart class, see "Paths" |

## Solution

The order is the spike run, then project and signing, paths, extension, app side, tests.

### Spike run

This runs before any L×Box change, and it changes only `ios-spike/`, which stays out of the repo.

1. The spike takes L×Box's `Libbox.xcframework`, already built at the pin, `v1.14.4-lx.30`.
2. `ios-spike/app/Config/Local.xcconfig` gets team `8E52KZEKAM` and bundle ID `com.gglprojects.lxspike`.
3. The first build registers `com.gglprojects.lxspike`, `com.gglprojects.lxspike.tunnel` and `group.com.gglprojects.lxspike` on GGL's account. Pavel can delete them when the work is done.
4. A real config names rule sets inside L×Box's container, which the spike cannot read. `devicectl` copies the `.srs` files into the spike's working folder, and the spike rewrites those paths when it saves a config. This shows the same problem as Diagnosis 1.
5. Pavel runs the rows in "Memory table to fill". His real config stays on the phone. Each Start overwrites `memory.csv`, so the file comes off the phone after each row.

If the real config does not fit, the work stops here and the options go to Pavel, before any L×Box change.

### Files

New `app/ios/PacketTunnel/`, a new app extension target:

- `PacketTunnelProvider.swift`: `startTunnel`, `stopTunnel`, `sleep`, `wake`, `handleAppMessage`.
- `TunnelPlatform.swift`: `CorePlatform` subclass with `openTun`, `underNetworkExtension`, `clearDNSCache`, `serviceStop`.
- `Info.plist` with `com.apple.networkextension.packet-tunnel`, and `PacketTunnel.entitlements`.

Shared by both targets, with no Flutter or UIKit imports: `CoreRuntime.swift`, `CorePlatform.swift`.

New in `app/ios/Runner/`: `TunnelController.swift`, which owns `NETunnelProviderManager`, start, stop, status and provider messages.

Changed:

- `CoreService.swift`: route start and stop by `has_tun`, take status from `TunnelController` in VPN mode, skip the background stop for the tunnel.
- `CoreCommandClient.swift`: a log client for VPN mode.
- `LxBoxChannels.swift`: store `setHasTun`, route `getVpnStatus`, `getTunnelUptimeMs`, `getMemoryInfo`, `reloadVPN`, `resetNetwork`, `clearDnsCache`, `isForeignVpnActive`, `openVpnSettings`, add `getAppGroupPath`. Also answer the methods the `develop` merge added: notification button prefs, `setTaildropTags`, `deleteLegacyPrefs`. Without them app startup stopped partway with an error on the home screen.
- `Runner.entitlements`, `project.pbxproj`.
- `app/lib/main.dart` and new `app/lib/services/app_group_path_provider.dart`, per D8.
- `app/lib/controllers/home_controller.dart`: on iOS, a `Stopped` with a reason shows that reason even when the app already reads as disconnected. A cold launch starts disconnected, and the guard against repeated `Stopped` events dropped the reason for a tunnel that ended while the app was closed. Android keeps the guard as it was.
- `app/lib/screens/settings_screen.dart`: per D5, hides the System tab of VPN Settings on iOS. Memory limit was the last thing left in it, and an empty card remained otherwise.

Code derived from `ios-spike/app/`, which follows `sing-box-for-apple` (GPLv3). L×Box is GPLv3 too. `LICENSING.md` gets a line, since the code itself has no comments.

### Project and signing

- Target `PacketTunnel`, bundle ID `com.gglprojects.lxbox.PacketTunnel`, deployment target 15.0, links `Libbox.xcframework` with the same flags as §711.
- App Group `group.com.gglprojects.lxbox`, one constant in `CoreRuntime.swift`.
- `DEVELOPMENT_TEAM = 8E52KZEKAM` on both targets, automatic signing. Never `V52BYHKP7D` (NOLEMON NOMELON INC).
- "Embed Foundation Extensions" goes before "Thin Binary", or the Flutter build fails on a dependency cycle.
- Device builds are Release. Debug Flutter builds need an attached debugger on a device.
- Xcode's reordered lines and `objectVersion` bump stay out of the commit.

### Paths

| Option | App | Extension |
|---|---|---|
| `basePath` | App Group root | App Group root |
| `workingPath`, `getFilesDir` | `<group>/Library/Application Support/lxbox` | `<group>/Library/Application Support/lxbox` |
| `tempPath` | `Library/Caches/lxbox-core` in the app's container | `<group>/Library/Caches/lxbox-core` |
| `crashReportSource` | `lxbox-app` | `lxbox` |
| `oomKillerEnabled` | `true` | `true` |
| `oomMemoryLimit` | Stored preset | `0` |
| `oomMemoryLimitHeap` | `true` | `false` |
| `logMaxLines` | 3000 | 3000 |
| `debug` | `core_logs_enabled` | `core_logs_enabled` |

- `command.sock` at the App Group root is 96 bytes, which fits the 103 limit (§711 finding 1). Simulator keeps its TCP port.
- Everything else goes under `Library/`, because `devicectl` cannot list or copy anything at the App Group root (found in the spike run). Verification reads its files that way.
- Temp stays separate because crash recovery empties it, and the app must not empty a running tunnel's temp.
- The extension takes `lxbox` as its crash source so Dart's `kCrashReportBaseName` finds its report with no Dart change. An in-app crash is still archived at the next launch and shows in `crash_reports/`.
- `NativePrefs` moves to `UserDefaults(suiteName:)`.
- With no App Group container, as with a Personal Team, every path falls back to today's location.
- §711 rule 15 keys on the App Group path instead of `NSHomeDirectory()`.

**D8.** `app_group_path_provider.dart` extends `PathProviderPlatform`. On iOS, `main()` installs it before anything reads a path. It answers `getApplicationDocumentsPath` with `<group>/Library/Documents` and `getApplicationSupportPath` with `<group>/Library/Application Support`, and passes every other call to the default provider. If `getAppGroupPath` returns null it installs nothing.

This beats moving `rule_sets` alone. `workspace_store.dart` renames `rule_sets`, `sub_cache` and settings between the live location and `slots/`, and a rename across two containers is a new way to fail. Moving all three keeps every caller as it is. Android never runs this code.

### Extension

`startTunnel`:

1. Delete `tunnel_stop.json`.
2. Run the §334 crash check on `CrashReport-lxbox.log`, clearing `cache.db` and temp.
3. Call `LibboxSetup` with the options above.
4. Read `singbox_config.json`. Empty means a failed start.
5. Create and start the command server, then call `startOrReloadService`. `openTun` calls `setTunnelNetworkSettings` from the core's `TunOptions`.
6. Return only after the core confirms. That makes iOS report `.connected`, so rule 2 of §711 ("`Started` only after the core confirms") still holds.

On failure, write the verbatim error to `tunnel_stop.json` and throw it.

`stopTunnel` writes the stop reason to `tunnel_stop.json`, then closes the service and the server. `serviceStop` from the core calls `cancelTunnelWithError(nil)`.

`handleAppMessage` answers four messages:

| Message | Action |
|---|---|
| `reload` | Re-read the config, `startOrReloadService`. Failure goes to `server.setError` as today |
| `resetNetwork` | `server.resetNetwork()` |
| `clearDnsCache` | Delete `cache.db`, then reload |
| `memoryInfo` | `{"totalPss": phys_footprint}`, same key as `getMemoryInfo` |

Network change: when the default interface name changes, wait 1500 ms and call `resetNetwork()`, as `DefaultNetworkMonitor.maybeResetOnSwitch` does on Android (010 P15).

### App side

Which process runs the core comes from `has_tun`, the same mirror Android reads in `startVpn`. It defaults to true. `setHasTun` starts storing it instead of answering with no effect. `vpn` and `vpn_proxy` go to the extension. `proxy`, and every mode in Simulator, stays in the app.

Start:

1. `startVPN` loads the manager, sets `isEnabled`, then saves and loads preferences. The first save shows iOS's "add VPN configuration" prompt.
2. On refusal `startVPN` answers `false` and nothing starts. Dart already shows `failedToStartVpn`, as on Android.
3. On success `startVPNTunnel()` runs and `startVPN` answers `true`.

Status comes from `NEVPNStatusDidChange`:

| `NEVPNStatus` | Status event |
|---|---|
| `.invalid`, `.disconnected` | `Stopped` |
| `.connecting` | `Starting` |
| `.connected`, `.reasserting` | `Started` |
| `.disconnecting` | `Stopping` |

On `Stopped`, the app reads `tunnel_stop.json`:

| Found | Event |
|---|---|
| App asked for the stop | `Stopped` |
| An error | `error` plus the verbatim `core_error` (§711 rule 9) |
| `superceded`, or `configurationDisabled`, `configurationRemoved`, or `userInitiated` that the app did not ask for | `revoked` with Android's `onRevoke` text, kept for later status requests (P9) |
| Any other reason, or no file because iOS killed the process | `error: "The tunnel stopped unexpectedly."`, with `fetchLastDisconnectError` as `core_error` on iOS 16 and later |

The §711 rules on statuses, the stop ladder and threads still apply. `stopVPN` waits at most 9 s for `.disconnected`. `forceStopVPN` calls `stopVPNTunnel()` and reports `Stopped` at once. `quitApp` stops the tunnel first, within Android's budget, then exits.

- **Reattach.** `getVpnStatus` and `getTunnelUptimeMs` load the manager first and read `connection.status` and `connectedDate`. This replaces "every cold launch starts `Stopped`". Dart's `getVpnStatus`, `ccResyncForReopen` and `_resyncOnResume` path needs no change. `didBecomeActive` re-reads the status, since a suspended app can miss the notification.
- **Background.** `didEnterBackground` leaves the tunnel alone. Local proxy and the probe session stop as they do now.
- **Test servers.** `probeStartAnswer` also answers `VPN is running` while the tunnel is not `.disconnected`. The Dart gate stays. App and extension share one `command.sock` path, so this gate is what keeps them apart. §712 said the endpoints would no longer collide, and that line gets corrected.
- **Logs.** With core logs on, a log client in VPN mode feeds the existing `writeLog` filter and queue. A fresh session or a cold launch replays the core's 3000-line buffer. A reconnect within a session skips that replay, so `corelog.txt` gets no duplicates, and lines from while the app was suspended can be lost.
- **Memory.** `getMemoryInfo` asks the extension in VPN mode, so Stats shows the number iOS kills on.
- **Simulator.** `openTun` keeps failing with a new text, `VPN mode does not run in Simulator. Select Local proxy in VPN Settings.`

## Differences with no choice

Written down so nobody re-asks. Each goes into `docs/IOS_DISABLED_FEATURES.md`.

| Feature | Android | iOS with the tunnel |
|---|---|---|
| Keep VPN on exit | Default on. Off stops the tunnel on swipe | Always on, setting stays hidden. iOS does not reliably tell an app it was swiped away |
| Service notification, Stop and Restart buttons | Yes | None. Control Center and Settings → VPN show the connection. iPhones with a Dynamic Island show no status bar icon |
| Per-app routing, Allow VPN bypass | Yes | Hidden (§714) |
| Boot start | Yes | Hidden. Only On Demand rules could do it, see D3 |
| `autoDetectInterfaceControl`, `protect(fd)` | Yes | Not needed. iOS keeps the extension's own traffic out of its tunnel |
| `CacheDbLockRetry` | Yes | Not ported (§711), added if a lock appears |

## Conflicts with other specs

All come from the tunnel existing. Most of them §711 expected.

| Spec | It says | §718 |
|---|---|---|
| §711 D2, "Background" | Core stops on leaving the app | Holds for Local proxy only |
| §711 "Expected Dart diff: none" | No Dart change | One class and one line (D8), one UI gate (D5), the stop reason on cold launch |
| §711 rule 10 | `basePath` is `tmp`, `workingPath` in the app | App Group |
| §711 rule 11, 16 | Heap flag on, source `lxbox`, presets apply | Split per process, see "Paths". Follows core spec 006 |
| §711 rule 13 | The not-built-yet text | Simulator only, new text |
| §711 rule 14 | `isForeignVpnActive` answers `false` | Real answer (D4) |
| §711 rule 15 | Keyed on `NSHomeDirectory()` | Keyed on the App Group path |
| §712 line 66 | Endpoints stop colliding with the tunnel | They still share a path, and the gate separates them |
| 010 P6 | Config unchanged | Holds. The core reads `tun-in` itself and passes `TunOptions` to native |
| 010 P11, P12 (recovery) | Restart after process death | Does not hold on iOS for now (D3) |
| 010 core-resources, §705 | Presets 200 to 768 MB | Hidden on iOS, with the System tab (D5) |
| §716 D2 | Wi-Fi list hidden "without a paid Apple team" | That reason goes stale. The row gets the D6 reason |
| 021, `docs/KERNEL.md` | iOS core is dev-only and must not ship | Still true. Development signing on one iPhone ships nothing |

## Risks and edge cases

- **Memory is the risk that can sink this.** iOS kills the extension with no warning, and it leaves no `tunnel_stop.json`. The phone then falls back to its direct connection. If the real config does not fit, the options are a smaller MTU, another stack, or fewer live nodes. All of them touch §700 or the template, so they go to Pavel first.
- **Other apps leak after a kill.** Nothing stops traffic going direct once the tunnel is gone, and `includeAllNetworks` stays false.
- **`system` stack and MTU 9000 in an extension.** Both untested. Check before blaming the core for odd behaviour.
- **DNS.** `localDNSTransport` stays nil, as in `sing-box-for-apple`. A node with a domain name proves the `local` server resolves without looping through the tunnel. §716 lists this as unchecked on a phone.
- **`find_process: true`.** `findConnectionOwner` stays unavailable. Watch for log noise (§711).
- **Slow starts.** Dart allows up to 4 minutes (010 P3). iOS's own limit for `startTunnel` is not documented, so test with AWG nodes.
- **Stale socket.** A killed extension leaves `command.sock`. `command_server.go` removes it on the next start. Until then a client connect fails, and the 012 heartbeat handles that as with a silent core.
- **Credentials.** The config and `configuration.json` move to the App Group, which only these two targets can read. The risk level matches the app's sandbox.
- **Deleted `cache.db`.** If the app deletes it after an in-app crash while the tunnel runs, the running core keeps its open copy. The next start makes a new one.
- **Debug API.** It stays in the app and reads status through the same channel. No route changes.
- **Merging `develop`.** Merged on 2026-11-05 as `34fa8a01`, 38 commits. Conflicts were the App Settings islands against the §714 gates, the `ProbeRunner` constructor, the changelog and Revisions tables. The original repo now uses numbers 710 to 717 for other tasks, so §710 to §716 collide. This task took 718 for that reason.

## Verification

Release build on iPhone 15 with iOS 26.3.1, unless noted. Pavel taps the phone and reports what he sees. Logs and files come off the phone through `devicectl`. A real node link stays on the phone, never in the repo or logs.

1. First Start: iOS prompt appears. Refuse: `failedToStartVpn`, nothing starts. Allow: `Connected`.
2. Safari and another app load pages. L×Box's connection list shows them through `tun-in`. An IP check shows the node.
3. Node with a domain name connects.
4. Node switch, single and mass ping, groups, stats, connections, close a connection.
5. Core logs on: lines reach `corelog.txt`.
6. Leave the app 2 minutes, return: tunnel up, no blink (012 P1), uptime correct, streams live.
7. Swipe the app away, traffic still flows. Reopen: `Connected`, uptime correct.
8. Lock 10 minutes, unlock: traffic flows. Wi-Fi to cellular and back: traffic recovers.
9. Stop from the app: `stopVPN` answers true after `Stopped`. Five cycles run clean.
10. Turn L×Box off in iOS Settings: `revoked`. Same with another VPN taking the slot, if the phone has one.
11. Config the core rejects: `Stopped` with verbatim text, the auto-disable flow works.
12. Reload after a settings change, `resetNetwork`, clear DNS cache: no status change, traffic continues.
13. Test servers: with the tunnel up the popup appears. With it stopped the test runs.
14. Kill the extension process with `devicectl`, which looks the same to the app as a memory kill. App shows the unexpected-stop reason. Next Start works.
15. Crash test: plant a non-empty `CrashReport-lxbox.log`, Start: `cache.db` and temp cleared, report archived and listed.
16. Local proxy on the phone: all §711 device checks still pass.
17. Simulator, iPhone 17, iOS 26.5: VPN mode fails with the new text, Local proxy passes §711 checks, a test run passes, workspaces switch cleanly with the moved folders.
18. Memory limit row is hidden on iOS, and a backup keeps its stored value for Android.
19. `git diff develop --stat` shows nothing under `app/android/`. `flutter analyze` adds no issues. Tests for the changed files pass. Full suite is CI-only.

### Results so far, 2026-11-05

Release build on iPhone 15 with iOS 26.3.1, core `v1.14.4-lx.30`, Pavel's real node. Pavel reported the phone checks. The logs after them have no crash and no error, the extension had exited after Stop, and the spike's tunnel was displaced.

| # | Result | Evidence |
|---|---|---|
| 1 | Partly | Allow worked and `Connected` appeared. Refusing the prompt is not checked yet |
| 2 | Pass | whatismyipaddress shows the node's country |
| 4 | Pass | Ping and node switch work, per Pavel |
| 6 | Pass | Left 2 minutes: still `Connected`, uptime kept counting |
| 7 | Pass | Swiped away, Safari still went through the node. Reopened: `Connected`, right uptime |
| 9 | Partly | One Stop ended in `Disconnected`. Five cycles not run |
| 10 | Partly | Foreign VPN dialog appeared for real with the spike's tunnel running, and Switch took over. Revoke from iOS Settings not checked |
| 14 | Pass | `devicectl` killed the extension with the app swiped away. Traffic went direct, as D3 accepts, and Start reconnected. The reason did not show on reopening at first, because of the Dart guard above. After the fix it showed once, and not again on the next launch. The kill with the app on screen is not checked |
| 16 | Partly | Local proxy checked on Simulator, not on the phone |
| 17 | Partly | Simulator: VPN mode stops with the new text. Local proxy connects, port 2080 and the TCP command port listen, fake node `ERR`, Direct 390 ms, port closes on leaving, no auto-start. Test servers and workspaces not rechecked |
| 18 | Partly | Simulator: VPN Settings shows Core and Mode only. Backup not checked |
| 19 | Partly | No change under `app/android/`. `flutter analyze` clean. Tests pass for the merged and changed files. Full suite not run |

Not checked yet: 3 node with a domain name, 5 core logs, 8 lock and Wi-Fi to cellular, 11 rejected config, 12 reload and clear DNS, 13 Test servers with the tunnel up, 15 crash test.

### Memory table to fill

First pass in the spike, from `memory.csv`, with the real limit from `limit_mb`. Second pass in L×Box, from the Stats sheet.

| Row | Spike peak MB | Spike limit MB | Spike killed? | L×Box peak MB | L×Box killed? |
|---|---|---|---|---|---|
| Bare core, direct, idle and 100 MB download | 21.7 | 50.0 | No | | |
| Pavel's real config, one VLESS node, idle | 20.6 | 50.0 | No | | |
| Same, browsing, 95 connections | 30.4 | 50.0 | No | | |
| Same, 100 MB download in Safari | About 26 | 50.0 | No | | |
| One AWG node, 100 MB | | | | | |
| MASQUE group, live | | | | | |
| Screen locked 10 minutes | | | | | |

## Unresolved / follow-up

- Before the final PR to `Leadaxe/LxBox`: bundle ID, App Group constant, team and entitlements are GGL's and must not go in as they are. Pavel's Personal Team holds `com.leadaxe.lxbox`, so check whether that ID can be released.
- Renumber or alias §710 to §716 against the original repo's tasks.
- An iOS core artifact and hash in fork releases, before any real distribution (§711).
- iPhone 17 with iOS 26.5, the project's target device, still unmeasured.
- D3 revisited with memory results.
- The Wi-Fi network list on iOS (D6), as its own task.
- The spike's own `URLSession` download fails through the VLESS node while Safari reaches the same host. Cause not found. It could affect other apps on the phone, so it needs an answer before this task is done (`ios-spike/logs/measure-device.md`, "Open").

## Docs to update

With implementation:

- `docs/ARCHITECTURE.md`: supported platforms line, iOS paragraph in Channel Contract, VPN Lifecycle, "Phase 4", the Network Extension remark.
- `docs/STORAGE.md`: iOS `basePath`, `workingPath`, native prefs, `tunnel_stop.json`, App Group layout.
- `docs/BUILD.md`: device build, signing, the extension target.
- `docs/IOS_DISABLED_FEATURES.md`: VPN mode, background, Keep VPN on exit, memory limit, Wi-Fi reason, notification, new table rows above.
- `docs/SECURITY.md` and `.ru.md`: the App Group, and "TUN-only inbound" now describes iOS VPN mode.
- `LICENSING.md`: the `sing-box-for-apple` origin of the tunnel code.
- One-line iOS note plus a Revisions row, EN and RU, per `features/README.md` "Platforms": `010` tunnel-control, foreign-vpn, autostart-and-exit, recovery, network-changes, tunnel-sleep, core-resources. `012` connection-status, data-channels. `009` node-ping, server-list-test, node-diagnostics. `007` empty-states. `003` settings-lifecycle.
- `docs/spec/tasks/710`, `711`, `712`: mark the tunnel follow-ups as handled here, and correct §712 line 66.

Stated as none: `docs/api/debug-api-reference.md` (no route change), `CHANGELOG.md` and release notes (nothing ships on iOS), `docs/KERNEL.md` and `021` (core delivery does not change), `pubspec.yaml` version.
