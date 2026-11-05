# 716 — iOS: Routing section check and hidden Wi-Fi list

| Field | Value |
|-------|-------|
| Status | Check done. Wi-Fi list hidden on iOS, not merged. Bugs recorded, not fixed |
| Start date | 2026-11-03 |
| End date | |
| Commits | |
| Related specs | [004-ROUTING](../features/004-ROUTING/FEATURE.md) ([inline-rules](../features/004-ROUTING/FUNCTIONS/inline-rules.md), [raw-json-rules](../features/004-ROUTING/FUNCTIONS/raw-json-rules.md), [remote-rule-sets](../features/004-ROUTING/FUNCTIONS/remote-rule-sets.md), [rule-actions](../features/004-ROUTING/FUNCTIONS/rule-actions.md), [rule-order](../features/004-ROUTING/FUNCTIONS/rule-order.md), [rule-transfer](../features/004-ROUTING/FUNCTIONS/rule-transfer.md), [wifi-conditions](../features/004-ROUTING/FUNCTIONS/wifi-conditions.md)), [005-DNS](../features/005-DNS/FEATURE.md) ([dns-servers](../features/005-DNS/FUNCTIONS/dns-servers.md), [resolvers-and-strategy](../features/005-DNS/FUNCTIONS/resolvers-and-strategy.md)), [026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md) ([direction-groups-in-config](../features/026-DIRECTIONS/FUNCTIONS/direction-groups-in-config.md)); tasks [711](711-ios-core-in-app-no-vpn.md), [714](714-ios-platform-differences.md), [715](715-ios-servers-section-check.md) |

## Goals

Go through Routing on iPhone 17 Simulator: every tab, button and input, whether settings reach the config and the core, whether the behaviour matches Android. Pavel decides each difference. Second section of the pass that began with §715.

## Non-goals

- Fixes for the bugs found. Pavel said: don't fix now.
- Editing specs that lag the code. They are listed for Pavel.
- New behaviour. The one code change hides what cannot work on iOS.

## Decisions

Made by Pavel on 2026-11-03.

| # | Question | Answer |
|---|---|---|
| D1 | Bugs found in shared code | Don't fix now, record |
| D2 | Wi-Fi network list in the rule editor does not work on iOS | Hide it. The network type stays |
| D3 | Shared text speaks about Android: Metered, package presets, Play region | Leave, record |
| D4 | Where findings live | One file, [`docs/IOS_FINDINGS.md`](../../IOS_FINDINGS.md), for all sections. §715 leftovers moved there |

## Differences from Android

Android was not run. Where this document says Android, it means the shared Dart code and the Kotlin source.

| What | Android | iOS | Decision |
|---|---|---|---|
| Add current | Reads the network name, with permissions | Said `Could not read current Wi-Fi (runtime_error).` `getCurrentWifiInfo` is not ported, and Apple needs an entitlement a free team does not have | D2, hidden |
| Pick saved | History of visited networks | Was empty, and its banner sent to a Settings row §714 hid | D2, hidden |
| Manual SSID | The rule matches on that network | Saved, the core accepted `wifi_ssid`, the rule never matched, because `readWIFIState` returns nil | D2, hidden |
| Metered text | "Mobile data and Wi-Fi marked as metered in Android settings" is right | Same text. The condition works: `CorePlatform` passes `path.isExpensive` as `network_is_expensive`. On iOS that means cellular or personal hotspot | D3 |
| Preset text | "Russian apps (by package name)", "Russian apps by package", "Play region" are right | Same text, and package conditions never match. The core documents `package_name` as Android only | D3 |
| Sticky session by, Load balance | `process` and domain | `process` stays preselected, with no owner on iOS. `urltest_balance_lx.go` then hashes the domain alone, so nothing breaks | Recorded |
| System DNS | `localDNSTransport` is `LocalResolver` | `localDNSTransport` is nil. Checked on a phone in §718, check 3 | Recorded |
| Paste prompt | No prompt | Same as §715 D4 | §715 D4 |

## Solution: Wi-Fi list hidden

`PlatformFeatures.canReadWifiName` is false on iOS. `WifiSection` draws the list only under Wi-Fi and only when that gate is true.

- Gone on iOS: network chips, Add current, Pick saved, Manual, the permissions hint, "No SSID filter".
- Stays: Any, Wi-Fi, Cellular, Ethernet and Metered.
- Stored values stay. A rule from an Android backup keeps its `wifi_ssid`, goes to the config with it, and never matches on iOS. It works again when the backup returns to Android.
- `_refreshWifiHint` still calls `getCurrentWifiInfo` on iOS. It gets `runtime_error`, which gives no hint, so nothing shows.

Android: the gate is true, nothing changes.

## Found, recorded by D1 and D4

Items F1 to F5, F9 to F18, F21 to F23, F25 and specs S3 to S7 in [`docs/IOS_FINDINGS.md`](../../IOS_FINDINGS.md). F26, System DNS, closed in §718.

## Verification

### Routing section

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, core `v1.14.4-lx.30`, before the Wi-Fi change. A local server gave `.srs` answers. App data was restored from a snapshot after, then the snapshot was deleted.

| Area | Checked | Result |
|---|---|---|
| Directions list | Required lock, toggle with heal (`route_final` to `vpn-1`), forbidden drag message, successful drag saved `['vpn-2','vpn-1']` | Pass |
| Direction editor | Fields, Use as detour adds ⚙, live regex preview, case-insensitive, invert 16 to 6, filter picker with chips, Default regex sets `default`, Load balance fields, pool 0 clamps to 1, tolerance 70000 clamps to 65535, interval over idle raises idle with a warning | Pass, except F3 |
| New direction | Duplicate blocked live, Create opens editor, Unsaved dialog by swipe, Delete | Pass |
| Broken regex | Saved, falls back to all nodes. This is 026-DIRECTIONS P8 | Pass |
| Presets | Add, Block Ads arrives off, Unknown traffic absent (§714) | Pass |
| Rules list | ☁ download, list switch downloads then enables, outbound dropdown, drag at x=14, Home button flushes, preset Params, View, Copy, Delete removes the file, Default traffic | Pass |
| Rule editor | Draft, Paste and Clear with `N · M invalid`, IDN to punycode, Fixed IP with validation, Dedicated server, Force IPv4, Resolve first with Advanced (`rewrite_ttl`, `timeout`, `client_subnet`), Resolve only, Raw JSON, kind change saves off, IP CIDR presets, ports, Protocol, Inbound, Metered gives `network_is_expensive`, sniff off removes rule, FakeIP preset gives `resolve_enabled=false` | Pass, except F1, F2 |
| Wi-Fi list | Add current, Pick saved, Manual | Fail on iOS, D2 |
| Export and Import | Both pickers, Save to file, Share, format 2, dedup, `.srs` arrives off, junk file gives a clear error | Pass, except F5 |
| DNS servers | Catalog, Add all defaults message, URL paste splits into DoH, DoT, DoQ. Group, Hosts, DoH3 (`type: h3`) forms. Tailscale form with `No Tailscale nodes yet`. JSON and Params sync, `Fix body JSON first`, resolver and detour, locks, Duplicate, Delete, preset note, Strategy, ✕ Force IPv4, live group lines | Pass, except F9 to F13 |
| Edited server | `cloudflare_udp` to `1.0.0.1` shows `Overridden`, Reset returns `Template` and `1.1.1.1`, the server stays off | Pass |
| DNS rules | User rule add, edit, delete, invalid JSON, rename of a server cascades to its rule | Pass, except F14 |
| DNS settings | ⓘ dialog at x=21, so the §715 strip does not eat taps. Leak banner and its button. Clear cache both branches | Pass, see S4 |
| Saved config | Return to Home rebuilds. `dns.strategy prefer_ipv4`, `dns.optimistic false`, `cache_file.store_dns false`, `default_domain_resolver.disable_optimistic_cache false`. Off servers absent. `dns_doq`, `dns_renamed`, `dns_new` present. `vpn-1-auto` has `45m`, `65535`, `45m` | Pass |
| Core with this config | `Connected` with DoQ, DoH3, group, hosts and FakeIP in the config. System DNS under Direct, 180 ms | Pass, see F25 |
| Traffic through the proxy | `cp.cloudflare.com` 204. `example.com` 200, then reset once a rule rejected it. `www.wikipedia.org` 200, `raw.test` 502. `network_type: cellular` did not match, `wifi` did | Pass |
| Relaunch | Kill and launch: `lxbox_settings.json` hash unchanged, direction order, rules, three DNS toggles and strategy on screen | Pass |
| Stop | `Stop VPN?` with the connection count, port 2080 closed | Pass |

Not checked: Android; a real iPhone; Tailscale DNS with a real node; Metered matching on a real cellular network; Debug API routes for Routing.

### Wi-Fi list hidden

1. New rule, tap Wi-Fi: the segment selects, no list shows. Metered stays.
2. Save: the config has `network_type: ["wifi"]`.
3. Rule with `wifi_ssid` from a backup: no chip shows. Edit Metered and save: `wifi_ssid` stays in the file and the config.
4. Android: `WifiSection` shows the list as before.

#### Results

Debug build on iPhone 17 Simulator with iOS 26.5. App data restored after.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | Rule 8, Wi-Fi highlighted, Metered directly below it |
| 2 | Pass | `{"domain":["example.org"],"network_type":["wifi"]}` in the inline rule-set |
| 3 | Pass | Body and config both hold `wifi_ssid: ["HomeWiFi"]` with `network_is_expensive: true` added |
| 4 | Pass by test | `wifi_section_test.dart` with the gate off. Android was not run |

`flutter analyze` on the changed Dart files: no issues. `wifi_section_test.dart`, `platform_features_test.dart` and `url_launcher_wifi_info_test.dart` pass, 13 tests. Full suite runs on CI, which a push to `ios-app` does not start.

## Docs to update

- `docs/IOS_FINDINGS.md`: new, with §715 leftovers moved in.
- `docs/IOS_DISABLED_FEATURES.md`: Wi-Fi list, Metered and preset text, Sticky session, System DNS.
- `docs/spec/features/004-ROUTING/FUNCTIONS/wifi-conditions.md` and `.ru.md`: iOS note and a Revisions row.
- `docs/README.md`: link to the new file.
- §715: leftovers replaced by a link.

Stated as none: `CHANGELOG.md` and release notes (nothing changes on Android, nothing ships on iOS), `docs/ARCHITECTURE.md` (no new module), `docs/api/debug-api-reference.md` (no route change).
