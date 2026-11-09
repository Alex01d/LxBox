# iOS findings

Bugs and gaps found while checking L×Box on iOS section by section, and not fixed yet. Pavel decides when each one gets fixed. When an item is fixed, it leaves this list and its task records the fix.

What Android has and iOS hides is in [IOS_DISABLED_FEATURES.md](IOS_DISABLED_FEATURES.md), not here.

"Shared" means shared Dart code, so Android should do the same. Android was not run. Tasks: [§715 Servers](spec/tasks/715-ios-servers-section-check.md), [§716 Routing](spec/tasks/716-ios-routing-section-check.md).

## Tunnel

| # | What happens | Cause | Found |
|---|---|---|---|
| T1 | A `URLSession` download inside the spike app failed with `The network connection was lost` about 1 s after the tap, every time, through a VLESS node. Safari reached the same host through the same tunnel and downloaded 100 MB. Messaging apps, TikTok and browsing then worked for 9.5 hours through L×Box's tunnel. Details in `ios-spike/logs/measure-device.md`. On 2026-11-09 L×Box itself showed the same pattern: with the VPN up on Pavel's node, Sentry, which sends through `URLSession`, kept an error event in its outbox from 18:32 and sent nothing. After Stop and a relaunch with the VPN down, the outbox emptied within a minute and the issue appeared in Sentry. So Sentry reports from the iPhone arrive only while the VPN is down (§722) | Not found. Seen only for the app's own `URLSession` traffic through its own tunnel. The app's Dart HTTP client is a different path | [§718](spec/tasks/718-ios-packet-tunnel.md), [§722](spec/tasks/722-ios-sentry-error-reports.md) |
| T2 | A cold launch after a tunnel crash shows the crash banner at once, as on Android. Two rare cases differ. The app sat in the background during the crash: back in it, no banner until the next cold launch. By code, not run: the banner closed with ×, then Start, and the next launch shows it again for the same crash. Pavel, 2026-11-09: record only | Dart reads the reports only at app launch, `main.dart:186`. The tunnel archives its report at the next Start under a new name, and the stored stamp is `name@mtime`. On Android a crash ends the whole app, and the core archives at app start. Details in [§724](spec/tasks/724-ios-only-findings.md) | §718, §724 |
| T3 | With core logs on, every connection logs `router: failed to search process: Not available on iOS` at INFO, while the config holds a rule set with app rules, such as `ru-direct:ru-apps` from the RU preset. Without one, the line is gone by the core's code, not run. Pavel, 2026-11-09: keep it so | §724 sets `find_process: false` on iOS. A rule set with app rules turns the lookup on in the core anyway, `route/router.go:220`, and iOS has no owner lookup | §718, §724 |
| T4 | Local proxy only: WARP logs `failed to send data packets: address family not supported by protocol family`, 2 lines in about 4 minutes. Ping to WARP still answered. None in VPN mode | Not found. Low priority | §718 |

## Start fails, or a rule silently does nothing

| # | What happens | Cause | Found |
|---|---|---|---|
| F1 | New `.srs` rule: ☁ in the editor says "Updated just now", then the file is gone. After Save the rule is left out of the config: `SRS rule "Rule 10" skipped: no cached file (Download first).` ☁ in the list after Save works | Shared. `pruneOrphans` deletes the file within 0.5 s, since the draft id is not on disk yet. `custom_rule_edit/edit_controller.dart:879`, `routing_screen/routing_srs_cache.dart:133` | §716 |
| F2 | A junk `.srs` passes as downloaded. Start then fails: `initialize router: parse rule-set[2]: invalid sing-box rule-set file` | Shared. `RuleSetDownloader.fetch` does not check the content | §716 |
| F3 | Direction Interval `abc` saves. Start then fails: `outbounds[22].interval: time: invalid duration "abc"` | Shared. `direction_edit_screen.dart:354 _save` does not validate | §716 |
| F30 | After an update to core `v1.14.4-lx.33`, Start fails: `decode config: lx.quic_sniff_decoy: lx.quic_sniff_decoy must be an object: {mode, outbound_type, detour_type, send}`. The config saved by the lx.32 build still holds `"quic_sniff_decoy": "detour"`, and launch does not rebuild it. The core reject guard does not help, since the error names no node. ↻ (Rebuild config + connect) fixes it. Seen on Simulator, installing `38318903` over the build of 2026-11-07, and on Pavel's iPhone at 18:18:54 on 2026-11-09 after the TestFlight update to build 3 | Shared. Launch decides staleness by file times only, `config_dirty_check.dart`, and nothing reacts to a new template or core. Release v2.25.20 writes the old form by default, so an Android update to lx.33 should fail the same way. Android not run. Pavel, 2026-11-09: no fix on `ios-app` and no report for now, take the upstream fix in a later merge | Sync with `develop`, 2026-11-09 |

## Gets in the way

| # | What happens | Cause | Found |
|---|---|---|---|
| F4 | `Template: 1 warnings` snackbar never leaves. It covers the bottom Save button, later messages queue behind it, one showed 4 minutes late, and tapping Show does not close it | Shared. Flutter 3.47 makes a snackbar with an action persistent, so the 6 s duration in `template_warnings_snack.dart` is ignored. `SnackBarAction` is also in `custom_rule_edit_screen.dart`, `subscription_filters_tab.dart`, `restore_flow.dart` | §716 |
| F5 | Rules import with 2 files: `Import failed: Bad state: Too many elements`. The iOS picker makes it easy to select two | Shared | §716 |
| F6 | Share .conf leaves `<tag>.conf` with the private key in the temporary folder | Shared. `_shareIni` never removes it | §715 |
| F7 | A server moved out of a folder, or kept on folder delete, is written to the end of the list, not right after the folder as [server-folders](spec/features/007-NODE_LIST/FUNCTIONS/server-folders.md) says. The next save puts it right | Shared. `_replaceKind` puts entries with new keys at the end of `sources[]`. §715 D2: record only | §715 |
| F8 | Empty subscription: `1 dropped` opens a sheet saying "The core rejected this server. Its technical message: empty body", though no server was involved | Shared | §715 |
| F27 | Clear DNS cache moves the selected node to Auto. Seen with the tunnel up. The crash test's cache reset did the same | Shared by code. The core stores the selection in `cache.db`, and the action deletes that file, `BoxService.kt:228` on Android. No spec mentions it | §718 |
| F28 | `corelog.txt` loses errors while the app is still running. 7 `ERROR` lines were gone after a browsing session, and the file shrank from 2 KB to 743 bytes | Shared. `_writePersistent` writes from the 500-line Core window, so INFO lines push older errors out | §718 |
| F29 | Auto-disable: a toast `Stopped: Failed to start service: ...` stays beside `Connected` while the banner reports the disabled node | Shared by code. The first refused start sets `lastError`. Spec 478 asks for a banner, not a snackbar, for the result | §718 |

## Values lost or not checked

All shared.

| # | What happens | Found |
|---|---|---|
| F9 | DNS Port `99999` is shown, then dropped with no message | §716 |
| F10 | Group `Error TTL abc` shows a clipped `Invalid duration (e.g. 2…`, save goes on, the value is dropped | §716 |
| F11 | `bad domain!` is flagged invalid and still goes to the config | §716 |
| F12 | Port range `5:1` is flagged and still goes to the config. The core accepted it | §716 |
| F13 | New custom DNS server prefills tag `dns_new` even when it is taken. The Replace dialog guards it | §716 |
| F14 | New DNS rule prefill `yandex_doh` with `geoip-ru` is dropped at build: `Template: Entry of dns.rules ... left out` | §716 |
| F15 | Direction tag allows spaces | §716 |
| F16 | Pool size says `of 22 nodes` while the filter leaves 18 | §716 |
| F17 | Export Share shows its snackbar whatever the sheet returns. Read from code | §716 |

## Layout and wording

All shared.

| # | What happens | Found |
|---|---|---|
| F18 | `RIGHT OVERFLOWED BY 22 PIXELS` at Default Domain Resolver. `BOTTOM OVERFLOWED BY 6.0 PIXELS` on the inline DNS rule tile, its icons still work. Both reach the applog as errors and count in Home's `Errors (N)` bar | §716 |
| F19 | Long subscription error: `BOTTOM OVERFLOWED BY 17 PIXELS`, the `(1 fails)` line is cut. `ListTile.computeMinIntrinsicHeight` measures the subtitle at the full width. §715 D3: skip for now | §715 |
| F20 | Auto form mode buttons break words: `Fastes/t`, `Manua/l`, `Load balan/ce`, and `Hold until failure` is clipped. `direction_edit_screen.dart` and `source_replace_screen.dart` have the same labels and were not looked at. §715 D3: skip for now | §715 |
| F21 | Host dialog helper text is clipped | §716 |
| F22 | No singular: `1 servers`, `1 rules`, `1 domains`, `1 warnings` | §715, §716 |
| F23 | Editors use `←`, other screens use `<` | §716 |

## Needs a real iPhone

| # | What is open | Found |
|---|---|---|
| F25 | `oom-killer` resets the network: `memory threshold reached, usage: 321 MB, available: 0 B, resetting network`, up to 371 MB. It counts the app's own memory, because the core runs in the app (§711). Debug inflates that number and Flutter has no release mode on Simulators. Belongs to VPN Settings. A release build on the iPhone 15 logged no `memory threshold` line in about 4 minutes of Local proxy with a 25 MB download, too short to close this | §715, §716, §718 |

## Specs behind the code

Left for Pavel, none edited.

| # | Spec | Code |
|---|---|---|
| S1 | [add-server-wizard](spec/features/008-NODE_EDITOR/FUNCTIONS/add-server-wizard.md) says five tabs | Six, with OpenConnect (§654) |
| S2 | [add-source](spec/features/001-SUBSCRIPTIONS/FUNCTIONS/add-source.md) lists "Get Public Test Servers" | `CommunityServersLoader.enabled` is `false` on all platforms |
| S3 | [rule-actions](spec/features/004-ROUTING/FUNCTIONS/rule-actions.md) line 19 names an Action & Resolve sheet | §683 replaced it with a section in the editor |
| S4 | [resolvers-and-strategy](spec/features/005-DNS/FUNCTIONS/resolvers-and-strategy.md) lines 61-65 say the leak banner button is `Switch to cloudflare_udp`, fixed and intentional | The screen shows `Switch to google_doh` |
| S5 | [dns-servers](spec/features/005-DNS/FUNCTIONS/dns-servers.md) line 36 says `hosts` has no form | It has one |
| S6 | [wifi-conditions](spec/features/004-ROUTING/FUNCTIONS/wifi-conditions.md) Boundaries say only Wi-Fi conditions exist | The editor has Any, Wi-Fi, Cellular, Ethernet and Metered (§694) |
| S7 | [direction-groups-in-config](spec/features/026-DIRECTIONS/FUNCTIONS/direction-groups-in-config.md) line 41 lists Fastest and Load balance | The code also has Hold until failure |
