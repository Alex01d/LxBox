# 713 — iOS: broken flows, ported from Android

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-03 |
| End date | |
| Commits | |
| Related specs | [009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md) ([node-diagnostics](../features/009-NODE_HEALTH/FUNCTIONS/node-diagnostics.md)), [011-SPLIT_TUNNELING](../features/011-SPLIT_TUNNELING/FEATURE.md) ([app-picker](../features/011-SPLIT_TUNNELING/FUNCTIONS/app-picker.md)), [012-LIVE_STATE](../features/012-LIVE_STATE/FEATURE.md), [013-DIAGNOSTICS](../features/013-DIAGNOSTICS/FEATURE.md) ([core-log](../features/013-DIAGNOSTICS/FUNCTIONS/core-log.md)), [017-BACKUP_AND_STORAGE](../features/017-BACKUP_AND_STORAGE/FEATURE.md), [028-TRAFFIC_PROFILER](../features/028-TRAFFIC_PROFILER/FEATURE.md) ([recording](../features/028-TRAFFIC_PROFILER/FUNCTIONS/recording.md)); tasks [168](168-profiler-on-commandclient-connections.md), [170](170-connections-accumulator-per-client-race.md), [261](261-dns-stream-to-command-multiplex.md), [390](390-install-source-aware-update-notice.md), [392F](392F-node-diagnostics/spec.md), [639](639-quit-clears-vpn-notification.md), [687](687-diagnostics-url-check.md), [710](710-ios-clean-startup.md), [711](711-ios-core-in-app-no-vpn.md), [712](712-ios-test-servers-and-probe-failure.md) |

## Goals

On iPhone 17 Simulator with iOS 26.5 or newer, these flows do what they do on Android:

- typed text stays as typed in fields the app parses;
- external links open;
- URL Check and the Profiler work while the core runs;
- node Diagnostics works while the core runs;
- round-robin pool, DNS groups, WireGuard status and node on/off reach the core;
- Quit & reopen and Restart now end the process;
- the app picker finishes loading instead of spinning.

Android behaviour does not change, with one stated exception, see Text fields.

## Non-goals

Pavel, 2026-11-03: no new functionality and no new behaviour. Each fix is what the app or the Android side already does. A difference from Android is reported for a joint decision, not solved here.

So these stay out, and are listed under Differences:

- Hiding Android-only settings, per-app UI, or presets.
- A new code editor on iOS.
- Closing the keyboard by tapping outside.
- The tunnel, Tailscale, Taildrop, OpenConnect, Wi-Fi rules.
- A `User-Agent` or backup `platform` that says iOS.

## Problem

Seen on 2026-11-03, iPhone 17 Simulator, iOS 26.5, branch `ios-app`:

| Flow | What happens |
|---|---|
| Servers field | `vless://a--b"c@…` typed becomes `bless://a—b”c@…`, so it is rejected. This is the open item from §710 |
| "User guide" in About | No browser, no message, the clipboard is overwritten |
| URL Check while Connected | `VPN is not running`, with `MissingPluginException` for `lxbox/cc/connection_test` in the log |
| Profiler START | `Recording system-wide events`, 0 events forever, with `MissingPluginException` for `lxbox/cc/dns` in the log |

Read from code, not run:

| Flow | What happens |
|---|---|
| "Scan QR code" on an iPhone | `NSCameraUsageDescription` is absent, and iOS ends an app that asks for the camera without it. Simulator has no camera, so it only shows an empty scanner |
| Round-robin group on Home | `ccGetPool` throws, and `_fetchPool` has no catch |
| Quit & reopen, Restart now | `quitApp` throws, so nothing happens. After a restore the screens keep old data |
| App picker | `getInstalledApps` throws, `_load` has no catch, and the progress bar never ends |

## Solution

The native side of the existing channel contract in Swift, as in §710 and §711. Each method follows its Kotlin source. No new channel, no new method name, no new plugin.

### Text fields

`autocorrect` and smart punctuation are Flutter defaults that act on iOS. Android has no smart punctuation, and fields that take URLs there already set `autocorrect: false`.

Fields whose value the app parses get:

```dart
autocorrect: false,
smartDashesType: SmartDashesType.disabled,
smartQuotesType: SmartQuotesType.disabled,
```

That covers links, URLs, hosts, paths, JSON, regex, tags, durations, keys and the iOS code field in `lx_code_editor.dart`. Fields for numbers and for human text (names, titles, descriptions, search) stay as they are.

Flags per field, because `TextField` has no theme for them, and a subclass would break `find.byType(TextField)` in widget tests.

**Exception to "Android does not change".** On Android these fields stop asking the keyboard for autocorrect, same as the fields that already have the flag. Smart flags do nothing there.

### Swift

| Method or channel | Source | iOS |
|---|---|---|
| `openUrl` on `/utils` | `MainActivity.openUrlOrFallback` | `UIApplication.open`, then `fallbackUrl`, then error `NO_ACTIVITY`, so Dart keeps its clipboard fallback. Error `INVALID_URL` with no URL |
| `ccStartConnectionTest`, `ccStopConnectionTest`, `lxbox/cc/connection_test` | `BoxCommandClient`, §687 | Own client and session per test, generation check on callbacks, batches. Returns `false` when the core is down, so Dart keeps its `VPN is not running` text for that case |
| `ccConnectProfiler`, `ccDisconnectProfiler`, `lxbox/cc/dns` | `BoxCommandClient`, §168, §261 | One client with `CommandConnections` and `CommandDNS`, answers included. Its own `LibboxConnections`, because two clients on one crash the core (§170). Same `lxbox/cc/connections` output. `ccResyncForReopen` also closes it |
| `ccGetUrlViaOutbound`, `ccGetRules`, `ccGetDnsGroups`, `ccGetPool`, `ccSetEndpointEnabled`, `ccGetWireGuardStatus` | `BoxCommandClient` | Unary on the ping client, same keys. `null` when the client is down. Endpoint errors keep their codes |
| `quitApp` | `VpnPlugin`, §639 | Reply `true`, stop the core with a 3 s budget, then `exit(0)` no earlier than 250 ms after the call |
| `getInstalledApps`, `getAppIcon`, `getAppInfo` | `VpnPlugin` | `[]`, `""` and `{"notFound": true}`. iOS gives an app no list of other apps, so this is the honest answer, and 011 already says the list depends on the OS |

`NSCameraUsageDescription` goes to `Info.plist`. iOS requires the text, and Android has no such string. It is in English only for now, see Differences.

### Rules

§711 rules hold: Callbacks never throw or trap, event sinks and `FlutterResult` run on the main thread, RPCs run off it, and status never comes from `lxbox/cc/*`.

## Differences from Android, for decision

| # | Difference | Options |
|---|---|---|
| 1 | Android-only settings claim things that are not true on iOS: battery `Whitelisted`, Location `Granted`, Doze, `Installed from GitHub` | Leave, or hide per platform. Hiding needs a per-platform rule in `docs/spec/features/README.md` first |
| 2 | Per-app UI stays visible and now shows an empty list. Alexander accepted losing the feature | Leave, or hide |
| 3 | The "Unknown traffic" preset matches all tunnel traffic on iOS, because the core gets no package names. No effect until the tunnel exists | Hide before the tunnel, or leave |
| 4 | Code editor is a plain field on iOS. Search and wrap buttons have no native view behind them | Leave, or choose an editor |
| 5 | The iOS number pad has no Return key, and nothing closes the keyboard on a tap outside. Android has its back button | Leave, or add a tap-outside rule |
| 6 | `exit(0)` looks like a crash on iOS. Android's `killProcess` is the same call, but its launcher hides it | Accept, or remove the buttons |
| 7 | Subscription `User-Agent` says `LxBox-android`, OS `android`, empty version and model. Backups say `platform: android` | Leave, or send iOS values |
| 8 | Camera prompt text is English only. Android's prompt is the system's own | Leave, or add `InfoPlist.strings` for ru and zh |

## Verification

Debug build, iPhone 17 Simulator with iOS 26.5, core `v1.14.4-lx.30`, each change on its own.

1. Servers field: `vless://a--b"c@192.0.2.1:443#teh` stays as typed. Same in the code field, a template variable field and a Test URL field.
2. `Info.plist` in the built app holds the string. "Scan QR code" still opens.
3. "User guide" opens Safari. Clipboard is untouched. A link with no handler falls back to the clipboard as before.
4. URL Check while Connected shows stages and a result. Core stopped: `VPN is not running`. Stop during a test works.
5. Profiler START while Connected: events appear, connections and DNS. STOP ends it. No `MissingPluginException`.
6. Node Diagnostics while Connected gives a result. WireGuard status and node on/off work on an AWG node. DNS tab reads groups.
7. Quit & reopen while Connected: process ends, relaunch shows Disconnected, no crash banner, port closed.
8. App picker: empty list, no endless progress. Tunnel apps tab with saved packages does not spin.
9. Backup export, import and restore run. Restart now ends the process, relaunch shows restored data.
10. Android: nothing changes under `app/android/`. `flutter analyze` has no issues. Tests that bear on the change pass. Full suite is CI-only.

### Results

Filled in as each change lands.

## Docs to update

With implementation:

- `docs/ARCHITECTURE.md`: the iOS paragraph in Channel Contract.
- `docs/spec/features/009-NODE_HEALTH/FUNCTIONS/node-diagnostics.md` and `.ru.md`: iOS note and a Revisions row.
- `docs/spec/features/011-SPLIT_TUNNELING/FUNCTIONS/app-picker.md` and `.ru.md`: iOS note and a Revisions row.
- `docs/spec/features/013-DIAGNOSTICS/FUNCTIONS/core-log.md` and `.ru.md`: Quit & reopen on iOS, a Revisions row.
- `docs/spec/features/028-TRAFFIC_PROFILER/FUNCTIONS/recording.md` and `.ru.md`: a Revisions row.
- `docs/spec/tasks/710-ios-clean-startup.md`: the typed link and the camera follow-ups point here.
- `docs/spec/tasks/711-ios-core-in-app-no-vpn.md`: the "Everything else stays" paragraph and follow-ups point here.
- `CHANGELOG.md`: one `Fixed` line under `[Unreleased]`, because the text fields reach Android.

Stated as none: `docs/api/debug-api-reference.md` (no route change), `RELEASE_NOTES.md` and `pubspec.yaml` (no version bump), `docs/l10n.md` (no new strings in Dart), template and registry files.
