# 722 — iOS: error and crash reports to Sentry

| Field | Value |
|-------|-------|
| Status | Checked on Simulator and on the iPhone 15 on `ios-app`, not merged. On the iPhone, reports arrive only while the VPN is down, T1 in `docs/IOS_FINDINGS.md` |
| Start date | 2026-11-06 |
| End date | |
| Commits | |
| Related specs | [013-DIAGNOSTICS](../features/013-DIAGNOSTICS/FEATURE.md), [020-APP_SHELL](../features/020-APP_SHELL/FEATURE.md) (maintenance notes), tasks [380](380-naive-and-reproducible-builds.md), [390](390-install-source-aware-update-notice.md), [395](395-update-check-consent.md), [714](714-ios-platform-differences.md), [718](718-ios-packet-tunnel.md), [`docs/PRIVACY_POLICY.md`](../../PRIVACY_POLICY.md) |

## Why

Internal TestFlight builds run on our own phones. On iOS a crash in Swift or in the Flutter engine leaves nothing on the device: the app keeps only its own log, core panic reports and the tunnel stop reason (§013, §718). Every piece of evidence stays on the phone until someone taps Share. Most VPN, subscription and network failures are caught by the app and only written to AppLog. Sentry sends uncaught errors, AppLog errors and native crashes to one place, with a screen replay of the moments before an error.

## Goals

- iOS builds send uncaught Dart errors and native crashes of the app process to Sentry.
- Every error entry of AppLog goes to Sentry too, from the app and from the core. This covers the VPN, subscription, WARP and network errors the app catches itself.
- Text leaves the phone without secrets: link paths and queries, proxy links, IP addresses, UUIDs, keys and e-mail addresses are masked. Host names stay.
- An error carries a masked screen replay of the seconds before it.
- A build without a DSN sends nothing.
- Android sends nothing and behaves as before.

## Non-goals

- Sentry in the `PacketTunnel` extension. The extension runs at about 37 MB against a limit near 50 MB (§718), and the core there already writes its own panic reports.
- Warnings and lower levels of AppLog.
- AppLog entries as breadcrumbs.
- Core panic reports. They stay on the phone with the crash banner (§316).
- Tracing, metrics, logs and profiling.
- Sentry on Android, macOS, Linux and Windows.
- A consent prompt or a settings toggle.
- Debug symbol upload. Dart code is not obfuscated, so Dart traces read as is. Native frames may need dSYMs later.

## Decisions

Made by Pavel on 2026-11-06.

| # | Question | Answer |
|---|---|---|
| D1 | How to keep Sentry to iOS? | `sentry_flutter` in `pubspec.yaml`, started only when `Platform.isIOS`. Its Android manifest removes `SentryInitProvider`, so the Android library never starts by itself |
| D2 | `PRIVACY_POLICY.md` promises no crash reporting services | Leave it. iOS builds are internal. Before any PR to Leadaxe, either remove Sentry or update the policy |
| D3 | 020-APP_SHELL wants consent for any new background network channel (§395) | No prompt. Only our own internal builds carry a DSN |
| D4 | Where does the DSN live? | `SENTRY_DSN` in `app/.env`, which git ignores. Builds pass `--dart-define-from-file=.env`, as `LXBOX_DISTRIBUTION` uses `--dart-define`. No file or an empty value means Sentry stays off |
| D5 | Session replay | Only around an error: `onErrorSampleRate` 1.0, `sessionSampleRate` 0. The free plan has 50 replays a month |
| D6 | Which AppLog entries go to Sentry? | Every `error` entry, from the app and from the core. Core lines reach AppLog only while Forward sing-box logs is on, which is off by default |
| D7 | What is masked before sending? | Secrets, IP addresses and e-mail addresses. Host names stay, so `lookup sub.example.com: no such host` keeps its host. Automation masks hosts too (§638), Sentry does not |

## Differences from Android

| What | Android | iOS | Decision |
|---|---|---|---|
| Uncaught Dart errors | AppLog only | AppLog, and Sentry when the build has a DSN | D1 |
| AppLog error entries | AppLog only | AppLog, and Sentry when the build has a DSN | D6 |
| Native crashes of the app | Not reported anywhere. The exit reason is read on the next launch (§038F) | Sent to Sentry on the next launch | D1 |
| Screen replay | None | Masked replay attached to an error | D5 |
| Consent | Update check asks once (§395) | Sentry does not ask | D3 |

## Solution

### Dependency

- `sentry_flutter: ^9.30.1` goes into `app/pubspec.yaml`. Version 10 needs Android `minSdk` 26, and the app supports 24, so the Android build fails with it. 9.30.1 needs 21. It brings Sentry Cocoa 8.58.4, which turns replay off on iOS 26, and the plugin turns it back on because Flutter masks the screen itself.
- Flutter has no per-platform dependencies, so the Android APK carries the library. It never starts there: the Dart gate below is false, and the plugin's manifest removes the auto-init provider.
- The iOS pod lands in the `Runner` target only. `PacketTunnel` links no Flutter plugins.

### Start

`app/lib/services/crash_reporting.dart` owns the switch.

- `SENTRY_DSN` comes from `String.fromEnvironment`. Sentry is on when `Platform.isIOS` and the value is not empty.
- `main()` starts it right after the app installs its own `FlutterError.onError` and `PlatformDispatcher.onError`. Sentry wraps those handlers, so AppLog still gets every error and Sentry sees it too. If Sentry started first, the app's handlers would replace Sentry's.
- `runApp` gets the app wrapped in `SentryWidget` when Sentry is on, because replay needs it. Otherwise the app runs unwrapped, as before.

### AppLog errors

- `AppLog` gets an `errorReporter` callback. Every new `error` entry calls it with the message and its source, both for single entries and for core batches. Entries loaded from the previous session do not call it.
- `CrashReporting` sets it when Sentry starts. Each call becomes `Sentry.captureMessage` at level `error`, tagged `log_source` `app` or `core`. Sentry groups equal messages into one issue.
- The app's own `FlutterError.onError` and `PlatformDispatcher.onError` write to AppLog with `alreadyReported: true`. Sentry has already captured those errors with their stack, so they are not sent twice.

### Masking

`maskSecrets` in `app/lib/services/url_mask.dart`, next to `maskSubscriptionUrl` and `maskNetworkAddresses`, rewrites text in this order.

| What | Example | Becomes |
|---|---|---|
| `http` and `https` links | `https://sub.example.com/api/v1/abc?token=x` | `https://sub.example.com/***`, the `maskSubscriptionUrl` form |
| Any other link | `vless://uuid@1.2.3.4:443?pbk=…#name` | `vless://***` |
| E-mail addresses | `user@example.com` | `***` |
| UUIDs | `b831381d-6324-4d53-ad4f-8cda48b30811` | `***` |
| Base64 keys of 44 characters, hex strings of 32 or more | a WireGuard key, a token | `***` |
| IPv4 and IPv6 addresses | `dial tcp 1.2.3.4:443` | `dial tcp ***:443`, the rules of `maskNetworkAddresses` |

The IP rules move into `maskIpAddresses`, which `maskNetworkAddresses` keeps using, so Automation masking does not change.

Sentry's `beforeSend` runs `maskSecrets` over the event message, every exception value and every breadcrumb message. `beforeBreadcrumb` does the same for each breadcrumb as it is added, so breadcrumbs synced to the native SDK are already masked. Native crash events from Sentry Cocoa skip the Dart callbacks. They carry stack frames and those synced breadcrumbs.

### Options

| Option | Value | Why |
|---|---|---|
| `dsn` | `SENTRY_DSN` | D4 |
| `replay.onErrorSampleRate` | 1.0 | D5 |
| `replay.sessionSampleRate` | 0, the default | D5 |
| `privacy.maskAllText`, `privacy.maskAllImages` | true, the default | Screens show subscription URLs, servers and keys |
| `sendDefaultPii` | false, the default | No user data |
| `tracesSampleRate` | not set | Tracing is a non-goal |

Release and environment come from the SDK: version and build from the app bundle, `debug` for debug builds, `production` for release builds.

### Build

```bash
cd app
echo 'SENTRY_DSN=https://…' > .env
flutter build ios --release --dart-define-from-file=.env
```

`flutter run` and `flutter build ios --simulator` take the same flag. Xcode builds reuse the defines of the last `flutter` command.

## Risks and edge cases

- **Go signal handlers.** The app process loads the Go core (Local proxy, test sessions, §711). Sentry installs its crash handlers after the Go runtime, so it sees a signal first and then passes it on. A check on 10.3.0 showed the effect: after `kill -SEGV` Sentry wrote a crash report, the Go runtime ignored the signal, and the app kept running. Sentry then stopped watching that process, and a later `kill -ABRT` made no report. A Go nil pointer that Go turns into a panic and recovers could do the same. Watch for crash reports in `runtime` or `sagernet` frames while the app kept running.
- **Android Kotlin plugin.** Flutter 3.47 warns that `sentry_flutter` 9 applies the Kotlin Gradle Plugin, and future Flutter versions will refuse such plugins. A Flutter upgrade may need Sentry 10 and a decision on Android `minSdk` 26.
- **Android size and catalogs.** The APK grows by the Sentry Android library. Exodus lists Sentry as a tracker, and F-Droid may flag it. D2 covers it: remove or decide before any PR to Leadaxe.
- **Desktop builds.** The plugin also registers on macOS, Linux and Windows, so their generated plugin files change and those builds compile the Sentry native library. Nothing starts it there.
- **Free plan.** One user, 5,000 errors and 50 replays a month. An error loop can use up the month. With core log forwarding on, a dead node writes an error per connection. When the quota runs out, Sentry drops events until the month ends.
- **Masking misses.** The rules cover known shapes. A secret in an unusual form, such as a password in plain words, still leaves. Sentry's server-side data scrubbing is a second layer.
- **IP address.** Events arrive through the VPN when it is on. The project's "Prevent Storing of IP Addresses" setting drops what Sentry would infer.

## Verification

On iPhone 17 Simulator with iOS 26.5, unless stated.

1. Build with `.env`, launch. Startup, Home and Local proxy work as before.
2. A temporary uncaught async error, not committed, reaches Sentry as an issue with a replay, and AppLog still shows `Uncaught async`.
3. `kill -ABRT` on the app process, then relaunch. Sentry shows a native crash.
4. Local proxy and Test servers with the core in the app make no crash report.
5. Build without `.env`. Nothing reaches Sentry, and Sentry keeps no data in the app's caches.
6. `flutter build apk --debug` succeeds. The merged manifest has no `SentryInitProvider`, and the Sentry providers left in it do nothing without a start.
7. `flutter analyze` and `flutter test` pass.
8. Unit tests: `maskSecrets` on each row of the masking table, `maskNetworkAddresses` tests unchanged, `errorReporter` called for app errors and core batch errors and not for warnings, `alreadyReported` entries or the previous session, and the Sentry event scrubber masks message, exception values and breadcrumbs.
9. Simulator with `.env`: an AppLog error with a link, an IP and a UUID in it reaches Sentry as one issue with the masked text and the `log_source` tag. An uncaught error reaches Sentry once, not twice.

### Results

On 2026-11-06, iPhone 17 Simulator with iOS 26.5, debug builds, `sentry_flutter` 9.30.1 with Sentry Cocoa 8.58.4. An earlier round on 10.3.0 passed checks 1 to 5 the same way and failed check 6, which is why the version is 9.30.1.

| # | Result | Notes |
|---|---|---|
| 1 | Pass | Home and Local proxy work. `io.sentry` and `SentryCrash` folders appear in the app's caches |
| 2 | Pass | A temporary `StateError('Sentry check 722 v9')` 12 s after start, with `options.debug`. AppLog has `Uncaught async: Bad state: Sentry check 722 v9`. The envelope queue emptied. Replay frames were recorded on iOS 26, and every text and icon in them is a solid block. Pavel saw the issue in the `lxbox-ios` project with a replay |
| 3 | Pass | `kill -ABRT` ended the app and left one crash report. The next launch sent it within a second. Pavel saw the crash in the project. On 10.3.0, `kill -SEGV` showed the Go handler effect in Risks |
| 4 | Pass | Local proxy `Connected`, Direct 592 ms, three SOCKS nodes `ERR`, then Stop. No crash report, the app stayed alive |
| 5 | Pass | Sentry caches deleted, build without `.env`. The plugin makes an empty `io.sentry` folder at launch. No `SentryCrash` folder, so no crash handler, and no envelopes |
| 6 | Pass | arm64 debug APK built. `SentryInitProvider` is rejected by the plugin's manifest. `SentryPerformanceProvider` notes the app start time in memory and finds no profiling config. `SentryNdkPreloadProvider` acts only when `io.sentry.ndk.preload` is true, and the app does not set it |
| 7 | Pass | `flutter analyze`: no issues. `flutter test`: 7638 passed, 37 skipped, before the AppLog errors were added |
| 8 | Pass | `mask_secrets_test`, `app_log_error_reporter_test` and `crash_reporting_mask_test` pass, and so do `automation_event_masking_test` and the existing AppLog tests. Full run after the change: `flutter analyze` no issues, `flutter test` 7657 passed, 37 skipped |
| 9 | Pass | Temporary lines, not committed: an AppLog error with `https://sub.example.com/abc?token=x`, `1.2.3.4:443` and a UUID, and an uncaught `StateError` 10 s later. AppLog on the phone kept the raw text. Pavel saw the message as `fetch https://sub.example.com/*** via ***:443 uuid ***` with `log_source` `app`, and the `StateError` once, with no second `Uncaught async` issue |

### Results on the iPhone 15, 2026-11-09

TestFlight build `0.0.1 (3)`, VPN mode on Pavel's VLESS node. The Sentry project had no event from the phone in the 2 days of use before.

- A subscription `https://sentry-check.invalid/sub`, added and deleted afterwards, logged `Fetch failed for https://sentry-check.invalid/***: ...` as an `app` error at 18:32:14. Sentry captured it: an envelope with the masked message, tag `log_source` `app` and release `com.gglprojects.lxbox@0.0.1+3`, written to `Library/Caches/io.sentry/.../envelopes`. Nothing reached Sentry for 15 minutes, and the envelope stayed on the phone.
- The DSN is in the build, and `SentryCrash` has been set up since the first TestFlight launch on 2026-11-07, so Sentry starts. `dns_shield` and the route rules block no Sentry host.
- Pavel pressed Stop, swiped the app away and opened it without Start. Within a minute the outbox was empty, and Sentry showed the issue with 2 events, the second from the subscription's retry at launch.

So capture and masking work on the iPhone, and sending fails while the app's own tunnel is up. T1 in `docs/IOS_FINDINGS.md` describes the same failure of `URLSession` inside the app through the tunnel.

## Docs to update

- `docs/BUILD.md`, Running on iOS: the `.env` file and `--dart-define-from-file=.env`.
- `docs/ARCHITECTURE.md`, the iOS paragraph: Sentry in the app process only.
- `PRIVACY_POLICY.md`, `PRIVACY_POLICY.ru.md`: none for now, by D2. Required before any PR to Leadaxe.
- `CHANGELOG.md`, release notes: none. Nothing changes on Android, and nothing ships on iOS.
- `docs/api/debug-api-reference.md`: none, no route changes.
