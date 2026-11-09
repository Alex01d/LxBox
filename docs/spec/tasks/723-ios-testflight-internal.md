# 723 — iOS: internal TestFlight builds

| Field | Value |
|-------|-------|
| Status | Done on `ios-app`, not merged. Builds `0.0.1 (1)` to `0.0.1 (3)` uploaded. 1 and 2 installed on Pavel's iPhone 15 from TestFlight, 2 days of everyday use with no problems |
| Start date | 2026-11-05 |
| End date | 2026-11-09 |
| Commits | `396a3be7` build(ios): declare exempt encryption and document TestFlight upload |
| Related specs | [021-CORE_CONTRACT](../features/021-CORE_CONTRACT/FEATURE.md), [023-BUILD_CI_RELEASE](../features/023-BUILD_CI_RELEASE/FEATURE.md), tasks [065](065-version-from-tag.md), [711](711-ios-core-in-app-no-vpn.md), [718](718-ios-packet-tunnel.md), [721](721-ios-wifi-rules.md), [722](722-ios-sentry-error-reports.md) |

## Goals

- L×Box reaches the phones of GGL Projects, Inc. team members through internal TestFlight, with no Mac or cable.
- Each build carries the same app, tunnel extension, core and Sentry setup as a development build.

## Non-goals

- External testers, a public link, or the App Store. External groups need Beta App Review.
- Builds from CI. Each build is made and uploaded on a Mac by hand.
- An iOS core artifact with a hash in the fork's Releases. That is still needed for anything wider than internal testers, see D6.
- Any change to the app, the extension or Android.

## Problem

Until 2026-11-05 L×Box went to one iPhone through development signing and `devicectl` (§718). Pavel chose internal TestFlight on 2026-11-05. Two specs said no:

- §718 listed "App Store, TestFlight, or any install beyond this one iPhone" as a non-goal.
- 021 and `docs/KERNEL.md` said the iOS core is a local build with no published hash, "dev only, must not ship" (§711).

The builds were uploaded before this spec existed. This spec records the decisions and the exception.

## Decisions

Made by Pavel between 2026-11-05 and 2026-11-09.

| # | Question | Answer |
|---|---|---|
| D1 | Who gets builds? | Internal testers of GGL Projects, Inc. only, in the internal group `Manual`. No external groups. The Distribution tab in App Store Connect stays empty |
| D2 | Which version does iOS show? | Its own line, starting at `0.0.1`, passed with `--build-name`. The build number goes up by one with each upload, passed with `--build-number`. The pubspec keeps the Android version (§065), because its `-dev.N` part gives four numbers, which App Store Connect refuses |
| D3 | How are builds signed? | Manual export signing with the Apple Distribution certificate and the App Store profiles `LxBox TestFlight` and `LxBox PacketTunnel TestFlight`. Automatic signing fails with a 403 on cloud-managed distribution certificates for this account |
| D4 | How are builds uploaded? | Xcode Organizer: Distribute App, Custom, App Store Connect, Upload. No Transporter or other tools |
| D5 | Export compliance | `ITSAppUsesNonExemptEncryption` is false in `Info.plist`. It records the answers given for builds 1 and 2: standard encryption algorithms, no distribution in France |
| D6 | The iOS core has no published hash. Can a TestFlight build carry it? | Yes, for internal TestFlight only. Every tester is a team member, the same people who could build it from the pin. External testers, the App Store or any other distribution still need an iOS artifact and hash in the fork's Releases, as 021 says. Decided on 2026-11-09 |

## Differences from Android

| What | Android | iOS |
|---|---|---|
| Channel | GitHub Releases, F-Droid, Google Play | Internal TestFlight only (D1) |
| Who builds | CI on a tag | A team member on a Mac (Non-goals) |
| Version | From the git tag through the pubspec (§065, §379) | Own line from `0.0.1`, set by flags (D2) |
| Core | Fork release AAR, checked against its SHA256 | Local build from the pin, no hash (D6) |
| Who updates | The app's update notice, or the store | The TestFlight app |

## Solution

- `app/ios/Runner/Info.plist`: `ITSAppUsesNonExemptEncryption` false (D5).
- `docs/BUILD.md`, Running on iOS, "TestFlight": the build command, the export options keys, the Organizer steps, the group.
- The export options file is not in git. BUILD.md lists its keys.

### Rules for each upload

1. Run `scripts/build-libbox-ios.sh` first. It skips the build when `app/ios/Frameworks/.libbox.version` matches the pin, and rebuilds when the pin moved. Xcode does not check the marker, so a skipped run can ship an older core than the pin says.
2. Build with `.env`, so the build has Sentry (§722).
3. Raise `--build-number` by one. Keep `--build-name` unless Pavel names a new version.
4. Upload, then add the build to the group `Manual` by hand. Its automatic distribution is off.

```bash
./scripts/build-libbox-ios.sh
cd app
flutter build ipa --release --build-name 0.0.1 --build-number <next> --dart-define-from-file=.env --export-options-plist <export options file>
open build/ios/archive/Runner.xcarchive
```

## Risks and edge cases

- **Stale core.** See rule 1. The marker is the only link between the pin and the framework inside a build.
- **Builds expire.** TestFlight stops a build 90 days after upload. The App Store profiles expire on 2027-11-05.
- **Sentry in every build.** Builds carry the DSN, so testers' errors reach Sentry, masked (§722). `PRIVACY_POLICY.md` still says no crash reporting. §722 D2 covers it for internal builds.
- **No dSYMs.** Xcode warns that `Sentry.framework` has no dSYM. The upload goes through. Native frames in Sentry may stay unsymbolicated.
- **GGL identifiers.** Bundle ID, App Group and team are GGL's. They must not reach the final PR to `Leadaxe/LxBox` as they are (§718).

## Verification

1. `flutter build ipa` with the command above gives `build/ios/archive/Runner.xcarchive`, signed by GGL's Apple Distribution certificate.
2. The upload passes and App Store Connect asks no encryption question.
3. The build installs from TestFlight on a phone, and VPN mode reaches `Connected` through the tunnel extension.
4. Everyday use on the phone shows no regression against the development build.

### Results

| # | Result | Notes |
|---|---|---|
| 1 | Pass | `0.0.1 (1)` from `a0df7d00`, then `0.0.1 (2)`. `0.0.1 (3)` from `4a4a9a9f` on 2026-11-09, core `v1.14.4-lx.33` |
| 2 | Pass | Builds 1 and 2 had the encryption questions answered by hand: build 2 was archived at 11:34 on 2026-11-07, before `396a3be7` added the key at 11:50. Build 3 carries the key. Pavel uploaded it on 2026-11-09, App Store Connect asked no encryption question, and the build appeared in TestFlight |
| 3 | Pass | Pavel's iPhone 15 |
| 4 | Pass | 2 days of everyday use by Pavel, 2026-11-07 to 2026-11-09. "looks good" |

## Unresolved / follow-up

- The next upload carries core lx.33. A phone updated from build 1 or 2 keeps a config the new core refuses, F30 in `docs/IOS_FINDINGS.md`. After the update, tap ↻ once instead of Start, or fix F30 first.
- §721 open check: Wi-Fi rules with the `wifi-info` entitlement in a TestFlight build.
- §722: no check on the iPhone yet. The Sentry project should show events from the 2 days.
- An iOS core artifact and hash in the fork's Releases, before anything wider than internal TestFlight (D6).
- dSYM upload for native frames, if Sentry's crash traces turn out unreadable.
- Builds from CI, with the iOS job from the §710 follow-ups.

## Docs to update

- `docs/BUILD.md`: link from the TestFlight paragraph to this task, and rule 1.
- `docs/KERNEL.md`, "The iOS core": internal TestFlight is allowed (D6).
- `docs/spec/features/021-CORE_CONTRACT/FEATURE.md` and `.ru.md`: the iOS core delivery row, a Revisions row.
- `docs/spec/features/023-BUILD_CI_RELEASE/FEATURE.md` and `.ru.md`: a TestFlight row in delivery channels, a Revisions row.
- `docs/spec/tasks/711-ios-core-in-app-no-vpn.md`: the 021 exception points here.
- `docs/spec/tasks/718-ios-packet-tunnel.md`: the TestFlight non-goal and the 021 conflict row point here.

Stated as none: `CHANGELOG.md` and release notes (nothing changes on Android), `pubspec.yaml` (iOS version comes from flags, D2), `docs/ARCHITECTURE.md` (no new module or data flow), `docs/api/debug-api-reference.md` (no route change), `docs/RELEASE_PROCESS.md` (Android releases do not change).
