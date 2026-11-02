# 710 — iOS: clean startup without a tunnel

| Field | Value |
|-------|-------|
| Status | Done on Simulator, not merged |
| Start date | 2026-11-02 |
| End date | |
| Commits | |
| Related specs | [020-APP_SHELL](../features/020-APP_SHELL/FEATURE.md) ([first-run](../features/020-APP_SHELL/FUNCTIONS/first-run.md), [update-check](../features/020-APP_SHELL/FUNCTIONS/update-check.md)), [003-CONFIG_BUILD](../features/003-CONFIG_BUILD/FEATURE.md), [007-NODE_LIST](../features/007-NODE_LIST/FUNCTIONS/empty-states.md), [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md), [012-LIVE_STATE](../features/012-LIVE_STATE/FEATURE.md), [013-DIAGNOSTICS](../features/013-DIAGNOSTICS/FEATURE.md), [017-BACKUP_AND_STORAGE](../features/017-BACKUP_AND_STORAGE/FEATURE.md), [018-WORKSPACES](../features/018-WORKSPACES/FEATURE.md), [024-TEMPLATE](../features/024-TEMPLATE/FEATURE.md), [029-LOCALIZATION](../features/029-LOCALIZATION/FEATURE.md); tasks [055](055-mobile-stack-decision/spec.md), [056](056-mvp-scope-historical/spec.md), [189](189-native-prefs-mirror-in-json.md), [414](414-config-dirty-check-files-dir.md) |

## Goals

On iPhone 17 Simulator with iOS 26.5 or newer, a fresh install and every later launch of L×Box:

- run the whole startup sequence, so settings, language, template, presets and migrations are all applied;
- reach the home screen with the "Add a server" empty state;
- log no warnings or errors caused by missing native code;
- show no prompt that only makes sense on Android.

Android behaviour does not change.

## Non-goals

- A VPN tunnel, Network Extension, App Group, signing or a paid Apple team.
- Linking the core (`Libbox.xcframework`). `CommandClient` and `lxbox/cc/*` data stay unimplemented.
- Start and Stop. "Tap to connect" is not usable yet, see Risks.
- Hiding Android-only rows in App Settings, per-app routing, Tasker, tile, boot start.
- `codex/tailscale-awg` and `handshake-fragmentation-fix`. These are out of scope for iOS.
- Rewriting `app/lib/main.dart` startup.

## Problem

Today `app/ios` is the stock Flutter template with no native channels. Running `develop` (`4a236896`, core pin `v1.14.4-lx.30-rc.1`) on Simulator opens the UI with an `Errors (5)` banner and only part of startup done:

| Native call | Log line | What it stops |
|---|---|---|
| `getAutoStart` | `Startup init failed (continuing best-effort)` | Everything after `bootstrapAndSyncNativePrefs()` in the single `try` in `app/lib/main.dart`: language bootstrap, date formats, template load, directions migration, preset seeding, later migrations |
| `getVpnStatus` | `Bootstrap skipped` | `HomeController.init()` and the bootstrap in `app/lib/screens/home_screen.dart` |
| `isIgnoringBatteryOptimizations` | `Uncaught async` | The rest of `StartupWizard.run()`, which has no `try` |
| `status_events` `listen` | `Flutter error` | The status subscription |
| `installSource` | Warning, caught | Nothing, falls back to GitHub |

The cause is `_invoke` in `app/lib/vpn/box_vpn_client.dart`, which only catches `TimeoutException`. `MissingPluginException` propagates. No spec defines "no native handler" as a state.

## Diagnosis

A throwaway build answered every channel with `nil` and logged each call. This shows the startup needs a small, known set of methods. Results:

- First launch: 40 calls, 26 distinct method names, 5 channels.
- Relaunch: 28 calls, no new methods.
- No warnings or errors, because `applog.txt` was never created. It only holds warnings and errors.
- Settings file gets `native_prefs`, `presets_migrated`, `directions_migrated`, 7 rules, 2 directions and DNS.
- The Dart config builder runs and calls `saveConfig`.

So Dart code does not need to change for startup to complete. Answering `nil` is not correct though. It exposed three real issues:

1. **Wrong defaults.** `keep_on_exit` was stored as `false`. `docs/STORAGE.md` and `_nativePrefsDefaults` say `true` (§188). Native-to-JSON seeding runs once, so a wrong answer sticks.
2. **Android prompt on iOS.** `false` from `isIgnoringBatteryOptimizations` shows "Android restricts background activity…".
3. **Repeated rebuilds.** `saveConfig` was called 3 times in about a minute because nothing was stored. `config_dirty_check.dart` compares settings against `singbox_config.json` in `getFilesDir`, so with no file the config always looks stale. [003-CONFIG_BUILD](../features/003-CONFIG_BUILD/FEATURE.md) treats false banners as a defect.

Things that looked like blockers and are not:

- **iOS 13 deployment target.** `flutter build ios` raised it to 15.0 by itself and built. The repo still says 13, so this task commits 15.0.
- **Plugin floors.** All plugins built on Xcode 26.6. No conflict with file picker or device info was reproduced.

## Decisions

Made by the operator on 2026-11-02.

| # | Question | Answer |
|---|---|---|
| D1 | Does "iPhone 17, iOS 26.5+ only" limit testing, or also set the minimum iOS version? | Testing only. Deployment target is iOS 15.0, the minimum the core builds for, so older iPhones can still install it |
| D2 | Is the "Check for updates?" prompt shown on iOS? GitHub releases only hold Android APKs | Hidden on iOS. `auto_check_updates` defaults to `false`, so no request goes to GitHub without consent. The App Settings toggle stays until the follow-up that hides Android-only settings |

## Solution

Implement the native side of the existing channel contract in Swift. Keep Dart as it is, except one iOS check for D2: `if (Platform.isIOS) return;` at the top of `maybeShowUpdateCheckPrompt`. It runs before the "asked" flag is set, so a backup restored from Android keeps its own flag, and Linux CI never takes this path.

This keeps Android at zero risk, follows §055 (thin bridge, same names on both platforms), and each stub is later replaced in place by real behaviour.

### Rules

1. Channel and method names match `PlatformChannels` and `method_names.dart` exactly.
2. Methods outside the table below return `FlutterMethodNotImplemented`, so missing native work stays loud. There is no catch-all `nil`. Later tasks add methods deliberately.
3. Tunnel status comes only from the status path, per the two-channel invariant in `docs/ARCHITECTURE.md`. `getVpnStatus` returns `Stopped`. No fifth status (010) and no polling (§004). Status is never inferred from `lxbox/cc/*`.
4. Event channels have one sink, used on the main thread (`docs/DEVELOPMENT_GUIDE.md`). They emit nothing here, because there are no transitions.
5. Native pref defaults equal the table in `docs/STORAGE.md`. JSON stays the truth, and native never writes JSON (§189).
6. `app/lib/main.dart` is not touched, so `startup_order_contract_test.dart` keeps passing.
7. Dart gates use `Platform.isIOS` only. CI runs on Linux, where `Platform.isAndroid` is false too, so an Android gate would silently switch off paths under test.
8. No new plugin, no `pubspec.lock` change, no new network request. Update consent rules in [first-run](../features/020-APP_SHELL/FUNCTIONS/first-run.md) stay as they are.

### What iOS answers

Channel `com.leadaxe.lxbox/methods`:

| Method | Answer | Why |
|---|---|---|
| `getFilesDir` | Real path, `Library/Application Support/lxbox`, created if missing | `config_dirty_check` and diagnostics read it. Moves to the App Group with the tunnel |
| `saveConfig` | Writes `singbox_config.json` atomically in that folder, returns `true` | Same file name as Android, ends false "dirty" |
| `getConfig` | File content, or `{}` if absent | Same as `ConfigManager.load` |
| `getVpnStatus` | `{status: "Stopped", revoked: false}` | Honest, there is no tunnel |
| `getCoreVersion` | Empty string | No core linked yet, Dart already handles it |
| `getAutoStart`, `getCoreLogsEnabled`, `getCoreLogsVerbose`, `getAllowBypass`, `getAutoRedirect` | Stored value, default `false` | `docs/STORAGE.md` |
| `getKeepOnExit` | Stored value, default `true` | §188 |
| `getBackgroundMode` | Stored value, default `never` | `docs/STORAGE.md` |
| `getMemoryLimit` | Stored value, default `auto` | §271 |
| Matching setters | Store in `UserDefaults`, return `true` | `_syncJsonToNative` calls them when JSON differs. Without storage it would re-push on every launch |
| `setHasTun`, `setAppLanguage`, `setAutomationEnabled` | Accept, return `true` | No native user yet |
| `getAppLanguageState` | `{supported: false}` | Dart treats it as nothing to reconcile, same as Android below 13 |
| `isIgnoringBatteryOptimizations` | `true` | iOS has no such exemption, so no dialog |
| `requestAddTile` | `"unsupported"` | Documented quiet exit. Flag gets set, so no repeat |
| `ccGetOpenConnectStatus`, `ccTakeOpenConnectOpenRequest`, `ccTakeTaildropOpenRequest` | `nil` | Dart reads this as "nothing there" |

Channel `com.leadaxe.lxbox/utils`:

| Method | Answer | Why |
|---|---|---|
| `installSource` | `nil` | Falls back to GitHub, per §390 |
| `isTelevision` | `false` | |
| `checkNotificationPermission` | `true` | Skips the foreground service prompt, which does not apply |

Event channels `com.leadaxe.lxbox/status_events`, `lxbox/coreLog`, `lxbox/cc/openconnect`: accept `listen` and `cancel`.

### Files

- New `app/ios/Runner/LxBoxChannels.swift`.
- `app/ios/Runner/AppDelegate.swift`, register channels in `didInitializeImplicitFlutterEngine`.
- `app/ios/Runner.xcodeproj/project.pbxproj`, add the file and set the deployment target to 15.0.
- `app/ios/Podfile`, set `platform :ios, '15.0'`.
- `app/lib/screens/home/home_dialogs.dart`, the D2 check.

`flutter build ios` also changes these on first run, and they belong in the same change: CocoaPods and Swift Package entries in `project.pbxproj`, `Runner.xcscheme`, `Runner.xcworkspace/contents.xcworkspacedata`, and a new `app/ios/Podfile.lock`. `pubspec.lock` does not change.

`app/ios/**` is on the night-work blacklist, so this task is the explicit permission it requires.

### Rejected

- **Catch `MissingPluginException` in `_invoke`.** Turns every future missing method into a silent default, and §055 item 6 calls for normalized errors, not swallowed ones.
- **`Platform.isIOS` gates at about 26 call sites.** Spreads platform checks through shared code, touches Android paths, and each gate is later removed again.
- **Split the single `try` in `main.dart`.** Good hardening, but it touches a contract-tested order and is not needed once methods answer. See follow-up.

## Risks and edge cases

- **Start does not work (handled in [§711](711-ios-core-in-app-no-vpn.md)).** With a server added, tapping Start stays on `Disconnected` and the `Errors (1)` banner appears, with `MissingPluginException` for `isForeignVpnActive` in the log. This conflicts with §055 item 6 until the bridge task. Accepted for now, because no iOS build ships.
- **Empty core version.** Registry gates judge fields by core version at config build. A config built with an empty version must not be treated as correct for a real core. Re-check when the core is linked.
- **Android rows in App Settings.** Battery and tile rows stay visible and now report "fine" or "unsupported". Cleaned up in a later task.
- **`main.dart` stays fragile.** Any new startup method without an iOS answer again skips everything after it. Acceptance 1 catches this, but only when someone runs it, because CI has no iOS job and `flutter analyze` excludes `ios/**`.
- **Flutter version.** Evidence comes from 3.47.9, the repo pins 3.47.1. Confirm on the pin before merge.
- **Storage move.** `getFilesDir` and native prefs move to the App Group with the tunnel. No migration needed, since no iOS installs exist.

## Verification

Manual, with a debug build from this branch, on iPhone 17 Simulator with iOS 26.5.

1. Fresh install, launch: home shows "Add a server". No `Errors` banner. `applog.txt` is absent or has no warnings or errors.
2. `lxbox_settings.json` has `native_prefs` equal to the `docs/STORAGE.md` table (`keep_on_exit: true`), plus `presets_migrated`, `directions_migrated`, rules and directions.
3. No battery, notification, tile or update prompt appears. `auto_check_updates` stays `false` and no request goes to GitHub.
4. Terminate and relaunch: no prompt repeats, no "Settings changed" banner, no new `saveConfig` caused by startup alone.
5. Change a native-mirrored setting, relaunch: JSON value is kept, and no setter is re-sent on the following launch.
6. Device language Russian: first frame is in Russian.
7. Android unchanged: `git diff develop --stat` shows nothing under `app/android/`, and the only Dart change is the D2 check. `flutter analyze` adds no new issues. Tests that bear on the change pass. The full suite is CI-only per `docs/DEVELOPMENT_GUIDE.md`, so it runs on the first push.
8. With a server added, relaunch: no "Settings changed" banner, no config rewrite.

### Results, 2026-11-02

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, Xcode 26.6.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | Home shows "Add a server", no banner, no `applog.txt` |
| 2 | Pass | `keep_on_exit: true`, `presets_migrated`, `directions_migrated`, 7 rules, 2 directions |
| 3 | Pass | No prompt on screen. `auto_check_updates` not set, so off |
| 4 | Pass | Settings file not rewritten on relaunch |
| 5 | Pass | `keep_on_exit: false` in JSON reached `UserDefaults` once. JSON kept, and the prefs file was not rewritten on the next launch |
| 6 | Pass | Launched with `-AppleLanguages (ru)`, home is in Russian |
| 7 | Pass, full suite pending | `app/android/` and `pubspec.lock` unchanged. `flutter analyze`: no issues. 55 tests pass in 7 files: `startup_wizard`, `startup_order_contract`, `native_prefs_memory_limit`, `box_vpn_client`, `install_source`, `config_dirty_check`, `allow_rotation_tv`. Full suite not run, because nothing is pushed |
| 8 | Pass | Fake VLESS server on `192.0.2.1`: `singbox_config.json` written, not rewritten on relaunch, no banner |

Not checked: the pinned Flutter 3.47.1, a real iPhone.

## Unresolved / follow-up

- A VLESS link typed into the Servers field was rejected as "Input is not a subscription URL…", while the same link pasted from the clipboard was recognized. Cause not checked. Typing was driven by the Simulator tool, so a changed first letter is one possibility.
- Connect UI to core without a tunnel: link `Libbox.xcframework`, `CommandClient` in Swift, normalized error for `startVPN`.
- Tunnel: Network Extension, App Group, real limit on iPhone. Needs the paid team.
- Hide Android-only settings and first-run steps properly, including a platform line in 020-APP_SHELL.
- `NSCameraUsageDescription` before QR scanning.
- Split the single `try` in `main.dart` so one platform failure cannot skip unrelated steps. Needs its own task and the startup order test.
- CI job for iOS, and a support tier in 023-BUILD_CI_RELEASE.

## Docs to update

With implementation:

- `docs/ARCHITECTURE.md`: Channel Contract (add `/utils`, `/wifi_history`, `lxbox/cc/*`, and what iOS implements); replace "iOS: absent" in the extraction notes.
- `docs/STORAGE.md`: iOS location of the config and native prefs.
- `docs/BUILD.md`: how to run on Simulator.
- `docs/spec/features/020-APP_SHELL/FUNCTIONS/first-run.md` and `.ru.md`: which steps do not apply on iOS, with a Revisions row.

Stated as none: `docs/api/debug-api-reference.md` (no route changes), `CHANGELOG.md` and release notes (nothing ships on iOS), `README.md` (no platform claim yet), `docs/l10n.md` (no new strings).

Tasks 055 and 056 and the Android-only notes in 014, 032F and 047F stay as written. This task qualifies them for iOS and does not rewrite them.
