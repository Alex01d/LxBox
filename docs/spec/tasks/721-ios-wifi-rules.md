# 721 — iOS: Wi-Fi rules and auto-record

| Field | Value |
|-------|-------|
| Status | Checked on Simulator and iPhone 15 on `ios-app`, not merged |
| Start date | 2026-11-05 |
| End date | |
| Commits | |
| Related specs | [004-ROUTING](../features/004-ROUTING/FEATURE.md) ([wifi-conditions](../features/004-ROUTING/FUNCTIONS/wifi-conditions.md)), [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md) ([network-changes](../features/010-VPN_SERVICE/FUNCTIONS/network-changes.md)), tasks [051](051-custom-rule-wifi-conditions.md), [567](567-wifi-ssid-read-preflight-and-diagnostics.md), [714](714-ios-platform-differences.md), [716](716-ios-routing-section-check.md), [718](718-ios-packet-tunnel.md) |

## Goals

- A rule can match named Wi-Fi networks on iOS, as on Android. Add current, Pick saved and Manual work, and the core matches `wifi_ssid` and `wifi_bssid`.
- Auto-record visited Wi-Fi networks works on iOS.

## Non-goals

- A location prompt. A test build read the network name without one.
- Any change on Android, apart from one harmless sync call at app start.
- Other rows that §714 hid, such as System setup.

## Why this is possible

§716 D2 hid the list because the free team could not get the entitlement. §718 D6 kept it hidden and said it needs a location prompt. A test build on the iPhone 15 on 2026-11-05 proved the prompt is not needed.

With the `com.apple.developer.networking.wifi-info` entitlement, `NEHotspotNetwork.fetchCurrent` returned the real SSID and BSSID in the app and in the tunnel extension. `locationAuth` was 0 and the app had no `NSLocation` key. A rule of `api.ipify.org` plus the current network went direct, a control site stayed on the VPN, and a made-up name did not match.

## Decisions

Made by Pavel on 2026-11-05.

| # | Question | Answer |
|---|---|---|
| D1 | Port Wi-Fi rules? | Yes. This replaces §716 D2 and §718 D6 |
| D2 | Auto-record visited networks on iOS? | Port it too, from the tunnel extension, so it records only while the VPN is on |
| D3 | What does Add current say when iOS returns no name? | The existing `Not connected to Wi-Fi.` No new text. It can be wrong before the first VPN start |

## Differences from Android

| What | Android | iOS | Decision |
|---|---|---|---|
| Reading the name | Location and nearby Wi-Fi permissions, asked at runtime | `wifi-info` entitlement and no prompt. iOS returns nothing while no L×Box VPN profile is installed, see check 12 | D1 |
| Failure reason | Names the permission or setting | iOS gives none, so every empty answer is `no_wifi` | D3 |
| Permission dialog on Save | Shows when a permission is missing | Never shows. `checkBackgroundLocationPermission` and `checkNearbyWifiPermission` are not ported and Dart reads that as granted | D1 |
| Where auto-record runs | App process, whenever it is alive | Tunnel extension, only while the VPN is on. Proxy mode records nothing | D2 |
| Delivery of a recorded network | Straight to Dart, dropped if the channel is gone | A file in the App Group, read when the app starts or becomes active. A network recorded while the app is on screen shows after the next return to the app | D2 |
| 5 minute timer | `Handler.postDelayed`, stops during deep sleep | `DispatchQueue.asyncAfter`, stops while iOS keeps the extension asleep | Same as Android |

## Solution

### Reading the network

- Both `Runner.entitlements` and `PacketTunnel.entitlements` get `com.apple.developer.networking.wifi-info`. Automatic signing enables Access Wi-Fi Information on the App IDs. The team has done this for `com.gglprojects.lxbox` and `.PacketTunnel`.
- `CorePlatform.readWIFIState` waits for `NEHotspotNetwork.fetchCurrent` and returns `LibboxWIFIState`, as sing-box-for-apple does. Both the extension and the in-app core use it.
- `getCurrentWifiInfo` on the utils channel returns `{ssid, bssid}` or `{error: no_wifi}`. These are the keys Kotlin returns.

### Showing the list

- `PlatformFeatures.canReadWifiName` goes away, and `WifiSection` draws the list under Wi-Fi on every platform.
- The Wi-Fi networks block in App Settings, Diagnostics loses its `hasAndroidSystemSettings` gate. System setup stays hidden.
- Pick saved keeps its banner, because the row it points to is visible again.

### Auto-record

Port of `WifiNetworkObserver.kt`, with the same names and the same 5 minutes.

1. `setAutoRecordWifi` stores `auto_record_wifi` in `NativePrefs`, which the app and the extension share, and sends `TunnelMessage.autoRecordWifi` to a running tunnel.
2. `PacketTunnelProvider` starts or stops `WifiNetworkObserver` from that value after the core starts and on that message. It stops the observer when the core closes.
3. `WifiNetworkObserver` uses `NWPathMonitor(requiredInterfaceType: .wifi)` in place of Android's `TRANSPORT_WIFI` callback. On a satisfied path it reads the network. A new network cancels the old timer and starts a 5 minute one. A lost path cancels the timer.
4. When the timer fires, the extension appends the network to `wifi_seen.jsonl` through `WifiSeenStore`. The extension never writes `lxbox_settings.json`.
5. `WifiHistoryBridge` in the app moves that file aside, reads it and sends `onWifiSeen` on the `wifi_history` channel. `WifiHistoryListener` already handles that call. The bridge reads after `setAutoRecordWifi(true)` and each time the app becomes active.
6. Turning the setting off stops the observer and deletes the waiting file.

`WifiHistoryListener.init` now always sends the stored value, not only when it is on. iOS keeps the flag across launches, so a restored backup with the setting off must be able to clear it. On Android this calls `stop()` on an observer that was not started, which returns at once.

## Verification

### iPhone 17 Simulator, iOS 26.5

The Simulator has no Wi-Fi to read and no tunnel.

1. New rule, tap Wi-Fi: chips area, Add current, Pick saved and Manual show. Metered stays.
2. Add current says `Not connected to Wi-Fi.`
3. Manual `HomeWiFi`, Save: no permission dialog. The config has `wifi_ssid: ["HomeWiFi"]`.
4. Pick saved lists `HomeWiFi`, with the Auto-record banner.
5. App Settings, Diagnostics shows Wi-Fi networks and hides System setup. The switch survives a relaunch.

### iPhone 15

6. Add current fills the real SSID and BSSID, with no prompt.
7. Rule of `api.ipify.org` plus the current network goes direct, and a control site stays on the VPN.
8. Same rule with a made-up name stays on the VPN.
9. Same rule with the real SSID typed by hand, no BSSID, goes direct.
10. Auto-record on, VPN on, 5 minutes on one network, back to the app: Pick saved lists the network, turned on with the tunnel already running.
11. Auto-record off, VPN on, 5 minutes: nothing new.
12. VPN profile deleted in Settings: Add current result. Needs Pavel's tap.

### Results

Run on 2026-11-05 with `develop` merged, core `v1.14.4-lx.32`. Simulator is a debug build, the phone is a release build on iOS 26.3.1. Pavel's phone was driven through a throwaway XCUITest runner, and the exit IP came from `api.ipify.org` in Safari.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | Any, Wi-Fi, Cellular, Ethernet, `No SSID filter`, the three buttons and Metered |
| 2 | Pass | `Not connected to Wi-Fi.` |
| 3 | Pass | Saved with no dialog, `{"wifi_ssid":["HomeWiFi"]}` in the inline rule-set |
| 4 | Pass | `HomeWiFi` under History, with the banner. Its Open Settings lands on Diagnostics |
| 5 | Pass | Wi-Fi networks shows, System setup does not. The setting and `auto_record_wifi` hold after a relaunch |
| 6 | Pass | Chip with the real SSID and BSSID, `locationAuth` stayed 0 in the test build, no prompt on the phone |
| 7 | Pass | `api.ipify.org` exits at the home IP, `icanhazip.com` at the node |
| 8 | Pass | `NoSuchNet` in the config, `api.ipify.org` exits at the node |
| 9 | Pass | `wifi_ssid` only in the config, `api.ipify.org` exits at the home IP |
| 10 | Pass | Turned on with the tunnel up at 18:46:46. By 18:52:40 `wifi_seen.jsonl` held the network. A return to the app moved it to `wifi_history` and removed the file, and Pick saved listed it with no banner |
| 11 | Pass | Turned off with the tunnel up and a timer running. No `wifi_seen.jsonl` after 5 min 54 s |
| 12 | Pass | On 2026-11-06, VPN stopped and the L×Box profile deleted in iOS Settings by Pavel, phone on Wi-Fi: Add current said `Not connected to Wi-Fi.` Start showed the iOS prompt to add VPN configurations, Pavel allowed it, and the tunnel reached `Connected`. Add current then filled the chip with the real SSID and BSSID. The test rule was discarded |

On the Simulator a planted `wifi_seen.jsonl` reached the history at launch and on return from Safari, and not while the app was in the background.

The phone stayed awake through 10 and 11, because the runner tapped an empty area every 50 seconds.

Locked phone, 2026-11-06, release build of `ios-app` with `develop` at `442d5401` merged, tunnel up on Wi-Fi, history empty. Auto-record turned on at 10:53:10 and the phone locked at 10:53:17. `wifi_seen.jsonl` appeared at 10:58:30 while `devicectl` still reported the phone locked, so the timer runs while the phone is locked. After Pavel unlocked, the app moved the entry into `wifi_history` and removed the file. Auto-record was turned off and the entry removed afterwards.

Two Wi-Fi networks, 2026-11-06, same build. A rule of `api.ipify.org` plus the home network from Add current, action direct, applied with ↻. On home Wi-Fi `api.ipify.org` exited at the home IP and `icanhazip.com` at the node. Pavel joined another phone's hotspot with the tunnel up: `api.ipify.org` exited at the node, in the same extension process. Back on home Wi-Fi it exited at the home IP again, still the same process. The rule was deleted afterwards. Add current had also put the home network into `wifi_history`, as it does with Auto-record off.

`flutter analyze` on the changed Dart files: no issues. The three named test files pass, 12 tests. The full suite ends at 7633 passed, 37 skipped, 0 failed. It first had 5 failures in `probe_runner_failure_test.dart`, which also failed on `7ca3c9c3`, before this task. That test assumed 6 parallel checks, and `f712ad53` made the default 10. It now passes `concurrency: 6`, as `probe_runner_cancel_test.dart` does.

### Open checks

- A BSSID with a zero byte. Core matching is exact, so a rule from an Android backup with `0a:...` fails if iOS gives `a:...`. The phone's BSSID has no zero byte.
- TestFlight build with this entitlement.

### Tests

`flutter analyze` on changed files. `wifi_section_test.dart`, `platform_features_test.dart`, `url_launcher_wifi_info_test.dart`.

## Docs to update

- `docs/IOS_DISABLED_FEATURES.md`: remove the Wi-Fi list and Auto-record rows, add a row under Different.
- `docs/spec/features/004-ROUTING/FUNCTIONS/wifi-conditions.md` and `.ru.md`: iOS paragraph and a Revisions row.
- §714, §716 and §718: note that this task replaces their Wi-Fi decisions.

Stated as none: `CHANGELOG.md` and release notes (nothing changes on Android, nothing ships on iOS), `docs/ARCHITECTURE.md` (no new module for Android, and the iOS tunnel is described in §718), `docs/api/debug-api-reference.md` (no route change).
