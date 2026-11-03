# 714 — iOS: decisions on differences from Android

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-03 |
| End date | |
| Commits | |
| Related specs | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.md) ([fetch-identity](../features/001-SUBSCRIPTIONS/FUNCTIONS/fetch-identity.md)), [010-VPN_SERVICE](../features/010-VPN_SERVICE/FEATURE.md) ([autostart-and-exit](../features/010-VPN_SERVICE/FUNCTIONS/autostart-and-exit.md), [tunnel-sleep](../features/010-VPN_SERVICE/FUNCTIONS/tunnel-sleep.md)), [011-SPLIT_TUNNELING](../features/011-SPLIT_TUNNELING/FEATURE.md) ([mode-and-list](../features/011-SPLIT_TUNNELING/FUNCTIONS/mode-and-list.md), [app-picker](../features/011-SPLIT_TUNNELING/FUNCTIONS/app-picker.md)), [014-AUTOMATION](../features/014-AUTOMATION/FEATURE.md), [017-BACKUP_AND_STORAGE](../features/017-BACKUP_AND_STORAGE/FUNCTIONS/desktop-transfer.md), [020-APP_SHELL](../features/020-APP_SHELL/FEATURE.md) ([app-settings](../features/020-APP_SHELL/FUNCTIONS/app-settings.md), [update-check](../features/020-APP_SHELL/FUNCTIONS/update-check.md)), [024-TEMPLATE](../features/024-TEMPLATE/FUNCTIONS/preset-bundles.md), [029-LOCALIZATION](../features/029-LOCALIZATION/FUNCTIONS/native-and-core-strings.md); tasks [114](114-subscription-user-agent-rebrand.md), [710](710-ios-clean-startup.md), [711](711-ios-core-in-app-no-vpn.md), [713](713-ios-flows-from-android.md) |

## Goals

Apply what Pavel decided on 2026-11-03 for the differences listed in [§713](713-ios-flows-from-android.md).

- iOS stops showing settings and screens that have no meaning there.
- The "Unknown traffic" preset cannot send all traffic past the proxy on iOS.
- The keyboard can be closed on iOS.
- Panels and backups see iOS, not Android.
- The camera prompt follows the phone's language.
- One document lists everything turned off on iOS: [IOS_DISABLED_FEATURES.md](../../IOS_DISABLED_FEATURES.md).

Android does not change, except what [§713](713-ios-flows-from-android.md) already states about text fields.

## Non-goals

- The tunnel, Tailscale, Taildrop, OpenConnect.
- Wi-Fi rule conditions. They stay visible until decided, see the document.
- A new code editor. Search and wrap stay as they are (D4).

## Decisions

Made by Pavel on 2026-11-03.

| # | Question | Answer |
|---|---|---|
| D1 | Android-only settings that say false things on iOS | Hide on iOS, after adding a per-platform rule to the specs |
| D2 | Per-app UI, empty on iOS because iOS gives no app list and no connection owner | Hide on iOS, and write a document listing what is off |
| D3 | "Unknown traffic" preset, on by default, would catch all tunnel traffic on iOS | Turn off on iOS now |
| D4 | Plain code field, dead search and wrap buttons | Leave as is |
| D5 | No way to close the number pad | A tap outside the field closes the keyboard, iOS only |
| D6 | Quit & reopen uses `exit(0)` | Keep |
| D7 | Panels see `LxBox-android`, OS `android`, no version or model. Backups say `platform: android` | Send iOS in full: `LxBox-ios/<version>`, `x-device-os: ios`, real version and model, `platform: ios`. Accepted risk: a panel that matches the `LxBox-android` token may not recognize the client |
| D8 | Camera prompt in English only | Add Russian and Chinese now, though Simulator cannot show the prompt |
| D9 | File picker needs a tap and Open | No change. Check on a real iPhone first |
| D10 | Text field flags also reach Android | Keep on both |

## Solution

One gate, `app/lib/services/platform_features.dart`, so the list stays in one place and reads the same as the document:

| Getter | Meaning |
|---|---|
| `isIos` | The platform. `Platform.isIOS`, or a test override. CI runs on Linux, so nothing hides there unless a test asks |
| `hasAndroidSystemSettings` | Rows about Android system services |
| `hasPerAppRouting` | Anything that picks an app |
| `isPresetDisabled(id)` | A template preset that does not apply here |

### What is hidden on iOS

| Where | What | Gate |
|---|---|---|
| App Settings, General | Auto-start on boot, Quick connect, Updates | `hasAndroidSystemSettings` |
| App Settings, Diagnostics | System setup, Auto-record visited Wi-Fi networks | `hasAndroidSystemSettings` |
| App Settings | Automation tab | `hasAndroidSystemSettings` |
| VPN Settings, System | Tunnel sleep mode | `hasAndroidSystemSettings` |
| VPN Settings, Mode | Keep VPN on exit, Allow VPN bypass | `hasAndroidSystemSettings` |
| About | Installed from, update block, Where to get L×Box | `hasAndroidSystemSettings` |
| Routing | Tunnel apps tab | `hasPerAppRouting` |
| Rule editor | Apps section | `hasPerAppRouting` |
| URL Check | App row | `hasPerAppRouting` |
| Routing, Presets and Rules | Unknown traffic | `isPresetDisabled` |

A hidden setting keeps its stored value, so a backup taken on iOS still restores on Android.

### Unknown traffic

The builder drops the rule, so no config carries it, whatever the stored state says. Stored rules are not rewritten. The Presets tab does not list it and the Rules tab does not draw it.

### Keyboard

The Flutter docs name `EditableTextTapOutsideIntent` as the way to change the default for all fields. On iOS `MaterialApp.actions` overrides it to unfocus the field's node. No per-field code.

### Identity

`buildSubscriptionUserAgent` picks the product token by platform. `deviceOsDefault` becomes `ios`. `init` reads `DeviceInfoPlugin().iosInfo`: `systemVersion` and `modelName`. The plugin is already a dependency. User overrides in App Settings keep working.

### Camera text

`Runner/ru.lproj/InfoPlist.strings` and `Runner/zh-Hans.lproj/InfoPlist.strings`. English stays in `Info.plist`. iOS picks the language from the system, not from the app's language setting.

## Risks and edge cases

- **Rules with apps from an Android backup.** They stay in storage and in the config, and never match on iOS. The editor no longer shows the section.
- **Scrolling closes the keyboard too.** The intent fires on any pointer down outside the field.
- **System strings.** With `ru.lproj` present, iOS may show its own menus (Copy, Paste) in Russian. That is the expected result.
- **A panel may refuse `LxBox-ios`** (D7). The Custom User-Agent setting is the way out.

## Verification

Debug build, iPhone 17 Simulator with iOS 26.5, one change at a time.

1. Number field: the on-screen keyboard closes on a tap outside.
2. App Settings has 4 tabs. General and Diagnostics have no hidden rows. Stored values are untouched.
3. VPN Settings and About have no hidden rows.
4. Routing has 4 tabs. Rule editor has no Apps section. URL Check has no App row and still runs.
5. Unknown traffic is not in Presets or Rules. The saved config has no `unknown-apps`. Stored rules keep it.
6. A local HTTP server logs `User-Agent: LxBox-ios/…`, `x-device-os: ios`, version and model on a subscription fetch. A new LX backup says `platform: ios`.
7. The built app has both `InfoPlist.strings`. A launch in Russian keeps Russian UI and region `BY`. Simulator cannot show the prompt, so that needs a real iPhone.
8. Android: nothing changes under `app/android/`. `flutter analyze` has no issues. Tests that bear on the change pass.

### Results

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, core `v1.14.4-lx.30`.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | VPN Settings, Mode, Listen port: number pad shows with no Return key. A tap on empty space closes it, the value stays `2080` |

## Docs to update

With implementation:

- `docs/IOS_DISABLED_FEATURES.md`: new.
- `docs/README.md`: the new document in the index.
- `docs/spec/features/README.md` and `.ru.md`: the per-platform rule.
- `docs/l10n.md`: the iOS native strings row.
- `docs/spec/tasks/713-ios-flows-from-android.md`: the differences point here.
- `docs/spec/tasks/710-ios-clean-startup.md`, `711-ios-core-in-app-no-vpn.md`: the follow-ups on hiding settings point here.
- One-line iOS note plus a Revisions row, EN and RU: `001` fetch-identity, `010` autostart-and-exit and tunnel-sleep, `011` mode-and-list, `017` desktop-transfer, `020` app-settings and update-check, `024` preset-bundles, `029` native-and-core-strings.

Stated as none: `CHANGELOG.md` and release notes (nothing changes on Android, nothing ships on iOS), `docs/api/debug-api-reference.md` (no route change), template and registry files.
