# 724 — iOS: process lookup off, Apple icon, crash banner record

| Field | Value |
|-------|-------|
| Status | Checked on Simulator on `ios-app`, not merged. T3 fixed only for configs without an app list |
| Start date | 2026-11-09 |
| End date | |
| Commits | |
| Related specs | [003-CONFIG_BUILD](../features/003-CONFIG_BUILD/FEATURE.md) build-pipeline, [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.md) fetch-identity, [013-DIAGNOSTICS](../features/013-DIAGNOSTICS/FEATURE.md) crash-reports, tasks [316](316-kernel-crash-reports-access.md), [711](711-ios-core-in-app-no-vpn.md), [714](714-ios-platform-differences.md), [718](718-ios-packet-tunnel.md), [`docs/IOS_FINDINGS.md`](../../IOS_FINDINGS.md) T2, T3, F24 |

## Goals

- T3: the config stops asking the core to find the app behind each connection on iOS, so the core log loses `router: failed to search process: Not available on iOS` on every connection.
- F24: the `x-device-os` row shows an Apple icon on iOS instead of the Android robot.
- T2: the record matches what the app does.

## Non-goals

- Any change on Android.
- The template. `route.find_process: true` stays in `wizard_template.json`.
- Code for T2.
- The other iOS findings, and every shared finding.

## Decisions

Made by Pavel on 2026-11-09.

| # | Question | Android | Answer |
|---|---|---|---|
| D1 | T3: process lookup on iOS | `find_process: true`, needed for app rules | Off on iOS when the config is built. The template stays. Same pattern as the Unknown traffic preset (§714 D3) |
| D2 | F24: identity row icon | Android robot | Apple icon on iOS, robot on Android |
| D3 | T2: crash banner after a tunnel crash | Banner at the next app start | Correct the record, no code. See "T2, checked again" |
| D4 | T3: the core still searches when a rule set holds app rules, such as `ru-direct:ru-apps` | Same core rule, and the lookup works | Keep `find_process: false`, record the rest in T3. Package rule sets stay in the iOS config |

## T2, checked again

T2 said the banner comes one launch later than on Android. On iPhone 17 Simulator a non-empty `CrashReport-lxbox.log` was planted in the App Group and the app launched cold: the banner `The core crashed last session` showed at once. `CrashReports.list()` reads the unarchived report too, `stderr_reader.dart:129`. The §718 check that found T2 planted the report while the app was running and then pressed Start.

Two cases remain, both rare. The tunnel did not crash once in 9.5 hours and 2 days of use.

- The app sat in the background when the tunnel crashed. Back in the app there is no banner until the next cold launch. On Android a crash ends the whole app, so the next open is always cold.
- By code, not run: the banner is closed with ×, then Start. The tunnel archives the report under a new name, and the next launch shows the banner for the same crash again, because the stored stamp is `name@mtime`.

## Solution

- `app/lib/services/platform_features.dart`: `canFindConnectionOwner`, false on iOS.
- `app/lib/services/builder/build_config.dart`: when the gate is off, the built config gets `route.find_process: false`.
- `subscription_settings_tab.dart` and `app_settings_screen/widgets/subscriptions_tab.dart`: the `x-device-os` row icon is `Icons.apple` on iOS.

The core still looks up the owner when a rule or a rule set needs it, `route/router.go:220` in the core: a `package_name` rule restored from an Android backup, or a binary rule set with app rules, such as `ru-direct:ru-apps` from the RU preset. Those never match on iOS (§716), and each connection then logs the line as before.

## Risks and edge cases

- Nothing in the app reads `find_process`. §044F planned an error in the Per-app tab for `find_process: false`, and it was never built.
- A config saved before this change keeps `find_process: true` until the next rebuild. It only means the log line stays until then.

## Verification

1. `platform_features_test.dart`: the gate is true on Android and false on iOS. A built config keeps `find_process: true` on Android and has `false` on iOS.
2. iPhone 17 Simulator, Local proxy, core logs forwarded: connections through the proxy log no `failed to search process`. The saved config has `"find_process": false`.
3. iPhone 17 Simulator: App Settings → Subscriptions and a subscription's settings show the Apple icon beside `x-device-os`.
4. `flutter analyze` and `flutter test` pass.

### Results

On 2026-11-09, iPhone 17 Simulator with iOS 26.5, debug build, core `v1.14.4-lx.33`.

| # | Result | Notes |
|---|---|---|
| 1 | Pass | 6 tests in `platform_features_test.dart` |
| 2 | Partly | The rebuilt config has `"find_process":false`. With Forward sing-box logs on, 3 requests through the proxy still logged `router: failed to search process: Not available on iOS`, one per connection. The Work set has the RU preset with `ru-direct:ru-apps`, a binary rule set with app rules, and that turns the lookup on (D4). A config without such a rule set has nothing that turns it on, by the core's code. Not run |
| 3 | Pass | Apple icon beside `x-device-os: ios` in App Settings → Subscriptions and in a subscription's Settings tab with Custom identity on |
| 4 | Pass | `flutter analyze`: no issues. `flutter test`: 7680 passed, 37 skipped |

## Unresolved / follow-up

- T2's two remaining cases stay in `docs/IOS_FINDINGS.md`.
- T3 stays in `docs/IOS_FINDINGS.md` for configs with app rule sets (D4).

## Docs to update

- `docs/IOS_FINDINGS.md`: F24 leaves the list, T2 and T3 are rewritten.
- `docs/IOS_DISABLED_FEATURES.md`: a "Process lookup" row under "Different, not turned off".
- `docs/spec/features/003-CONFIG_BUILD/FUNCTIONS/build-pipeline.md` and `.ru.md`: one iOS line, a Revisions row.
- `docs/spec/features/001-SUBSCRIPTIONS/FUNCTIONS/fetch-identity.md` and `.ru.md`: the icon in the iOS line, a Revisions row.

Stated as none: `CHANGELOG.md` and release notes (nothing changes on Android, nothing ships on iOS), `docs/ARCHITECTURE.md` (the gate file is already named there), `docs/TEMPLATE.md` (the template does not change), `docs/api/debug-api-reference.md` (no route change), `docs/l10n.md` (no new strings).
