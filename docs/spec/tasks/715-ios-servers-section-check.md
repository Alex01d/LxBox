# 715 — iOS: Servers section check and back swipe

| Field | Value |
|-------|-------|
| Status | Check done. Back swipe implemented, not merged |
| Start date | 2026-11-03 |
| End date | |
| Commits | |
| Related specs | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.md) ([add-source](../features/001-SUBSCRIPTIONS/FUNCTIONS/add-source.md), [auto-update](../features/001-SUBSCRIPTIONS/FUNCTIONS/auto-update.md)), [007-NODE_LIST](../features/007-NODE_LIST/FUNCTIONS/server-folders.md), [008-NODE_EDITOR](../features/008-NODE_EDITOR/FEATURE.md) ([add-server-wizard](../features/008-NODE_EDITOR/FUNCTIONS/add-server-wizard.md), [node-settings](../features/008-NODE_EDITOR/FUNCTIONS/node-settings.md)), [020-APP_SHELL](../features/020-APP_SHELL/FUNCTIONS/navigation.md); tasks [626](626-unsaved-changes-everywhere.md), [711](711-ios-core-in-app-no-vpn.md), [713](713-ios-flows-from-android.md), [714](714-ios-platform-differences.md) |

## Goals

Go through the Servers section on iPhone 17 Simulator: every button, input and import, whether configs get saved, whether the behaviour matches Android. Pavel decides each difference. This is the first section of a section-by-section pass.

## Non-goals

- New behaviour. The one change here, the back swipe, brings iOS to what Android and §626 already do.
- Fixes for what Pavel chose to record or defer below.

## Decisions

Made by Pavel on 2026-11-03.

| # | Question | Answer |
|---|---|---|
| D1 | Swipe from the left edge does nothing on screens that guard back | Same as Android: the swipe does what the arrow does. No edits, the screen closes. Edits, the dialog |
| D2 | Server moved out of a folder, or kept on folder delete, is written to the end of the list | Record only. No code change |
| D3 | Long subscription error overflows its row. Mode buttons in the Auto form break words | Skip for now |
| D4 | iOS asks to allow paste. Don't Allow then shows "Clipboard is empty" | Leave as is, record the difference |

## Differences from Android

| What | Android | iOS | Decision |
|---|---|---|---|
| Back gesture on a screen with `PopScope(canPop: false)` | System back runs the screen's handler | Flutter turns off the swipe on such a route, so nothing happens | D1 |
| Paste from clipboard | No prompt | System prompt, once per clipboard content from another app. Don't Allow returns nothing, so the app says "Clipboard is empty" | D4 |
| Magnifier in the editor menu | Native editor | Plain field, the item has no effect. Same family as §714 D4 | Recorded |
| Identity row icon | Android robot | Android robot beside `x-device-os: ios`. Cosmetic | Not asked yet |

Android was not run. Where this document says Android, it means the shared Dart code and the Kotlin source.

## Solution: back swipe

`app/lib/widgets/ios_edge_back_gesture.dart`, placed around the Navigator through `MaterialApp.builder`, on iOS only.

- A strip 20 points wide on the left edge listens for pointer down. It is translucent, so taps go through.
- The drag recognizer starts only when the top route is a page, is not the first route, and its `popDisposition` is `doNotPop`. These are the routes where Flutter's own swipe is off. On every other route the native swipe stays as it is, following the finger.
- A drag of 80 points or more calls `Navigator.maybePop()`. On such a route that runs `onPopInvokedWithResult`, the same handler system back runs on Android, so the existing dialogs work with no change to any screen.

The screen does not follow the finger. It closes at the end of the drag.

Home is the first route, so the widget leaves it alone and the swipe opens the side menu, as it did before. A dialog or sheet on top is not a page, so a swipe there does nothing.

Android: the widget is not in the tree.

## Known bugs, recorded by D2

**Order after Move out and Keep servers.** Spec [server-folders](../features/007-NODE_LIST/FUNCTIONS/server-folders.md): a member moved out becomes a server right after the folder. `ungroupMemberAt` and `deleteFolderAt` insert at the right place in `_entries`, but `_persist` goes through `saveServerLists`, and `_replaceKind` puts entries with new keys at the end of `sources[]`. The next save writes the right order, since old keys keep their slots.

Reproduced: folder `Order`, then `zz-after`. Move out `zz-folder-paste`, read the file: `Order, zz-after, zz-folder-paste`. Kill and relaunch: the list stays in that order. After Keep servers the list showed the servers at the end, and they moved to the folder's place after the next add.

The code is shared, so Android should do the same. Not run there.

## Deferred, by D3

- **Long error in a subscription row.** `Server returned a web page…` gives `BOTTOM OVERFLOWED BY 17 PIXELS` and cuts the `(1 fails)` line. The row is a `ListTile` in `IntrinsicHeight`, and `ListTile.computeMinIntrinsicHeight` measures the subtitle at the full width, wider than the real one. Shared code.
- **Mode buttons in the Auto form.** `Fastes/t`, `Manua/l`, `Load balan/ce`, and `Hold until failure` is clipped. Four segments with icons in about 92 points each. `direction_edit_screen.dart` and `source_replace_screen.dart` have the same labels and were not looked at. Android uses another font, not compared.

## Found, no decision yet

- **`oom-killer` resets the network.** Core log 30 s after Start on the debug Simulator build: `memory threshold reached, usage: 321 MB, available: 0 B, resetting network`. The killer counts the app's own memory, because the core runs in the app (§711). Debug inflates that number and Flutter has no release mode on Simulators, so this needs the phone. Not a Servers matter, it belongs to VPN Settings.
- **Share .conf leaves the file in temp.** `_shareIni` writes `<tag>.conf` with the private key to the temporary folder and never removes it. Android does the same by code.
- **Empty subscription.** `1 dropped` opens a sheet saying "The core rejected this server. Its technical message: empty body", though no server was involved. Shared code.
- **`1 servers`.** Folder and picker counts have no singular. Shared code.
- **Specs behind the code.** [add-server-wizard](../features/008-NODE_EDITOR/FUNCTIONS/add-server-wizard.md) says five tabs, the code has six with OpenConnect (§654). [add-source](../features/001-SUBSCRIPTIONS/FUNCTIONS/add-source.md) lists "Get Public Test Servers", but `CommunityServersLoader.enabled` is `false` on all platforms. Left for Pavel, not edited here.

## Verification

### Servers section

Debug build on iPhone 17 Simulator with iOS 26.5, Flutter 3.47.9, core `v1.14.4-lx.30`, before the swipe change. A local server gave subscription answers. Fixtures and server were removed and app data restored after.

| Area | Checked | Result |
|---|---|---|
| Input and `+` | Paste URL with confirm dialog, typed link, junk rejected, Discard input guard | Pass |
| Import from file | 2 nodes become a file subscription, `.conf`, outbound JSON, empty file, junk, 2 files give a folder | Pass |
| List | Toggle and drag persist. `127.0.0.1` shown for an unnamed URL | Pass |
| Subscription menu | Share URL, Update, Edit source to `/404` keeps the old one, Local file, Reset fail count, which clears the freeze and keeps the shown count as spec says | Pass |
| Fetch results | `/500` retries 3 times then errors. `/empty` and `/html` stay as entries with a reason. `base64:` title decoded. Emoji prefix `🗽` and `🗽2` in the config | Pass |
| Subscription detail | Prefix, identity, UA, TLS override, Replace with a group, Filters, inline rename, node menu and Inspect, Test and session close, Delete | Pass |
| Subscription source tab | Copy URL, Re-fetch live headers, Copy headers, Web page, Support icon. Decode base64 is on by default, off shows the raw body, and Copy takes what is shown | Pass |
| Subscription settings | Update interval, On update, Refresh now, detour picker all saved | Pass |
| Top menu | Add hop chain with save and delete, New folder, Auto-update, Subscription settings, Get WARP opens, refresh | Pass. WARP Register not tapped, it creates a real device |
| Wizard | SOCKS5 with `--` and `"` kept in the config. HTTP with TLS. Paste JSON with a comment. Port, host, auth key, OpenConnect required fields. Input kept across tabs. Cancel | Pass |
| Node editor | Tag, palette, detour, invalid Source, Unsaved changes, INI Copy and Share, Edit INI, JSON Copy and Edit, Masquerade, incoming switch, Diagnostics with core stopped | Pass. Share .conf name comes from the tag, emoji dropped |
| Folder | Rename, Add by URL snapshot, Paste, Import from files, auto node with rule and invalid regex, Move in and out, filters, Test, Disable unreachable, member Delete, prefix, detour with policy, Keep servers, Delete with servers | Pass, except order (D2) |
| Saved config | Return to Home rebuilds: `Config rebuilt: 38 nodes`, edited address present, disabled node absent. Relaunch keeps everything | Pass |
| Core | Start with that config: `Connected`, 40 nodes with real pings, masquerade keys in the WireGuard endpoint, Stop | Pass, see `oom-killer` |
| Back swipe | Edge swipe on node screen does nothing. Same swipe on App Settings pops, so the tool is fine | Fail, fixed below (D1) |

Not checked: Android; a valid add through Paste URI in the wizard, Tailscale and OpenConnect; Disable slower and Sort by ping with reachable nodes; TLS and Replace with a group on a folder; Scan QR on Simulator, see §714 for the phone.

### Back swipe

1. Node screen, no edit: swipe closes it.
2. Node screen, edited Tag: swipe shows Unsaved changes. Keep stays, Discard leaves.
3. Servers with text in the input: swipe shows Discard input.
4. Folder and Config Editor: swipe closes them.
5. Home: side menu opens. Open dialog: nothing.
6. App Settings: native swipe follows the finger, once.
7. Node tabs: a swipe away from the edge changes tabs. Folder drag handles still work.
8. Android: no change under `app/android/`, the widget is not built. `flutter analyze` has no issues. `ios_edge_back_gesture_test.dart` passes.

#### Results

Debug build on iPhone 17 Simulator with iOS 26.5.

| # | Result | Evidence |
|---|---|---|
| 1 | Pass | `spike-fake`, swipe from x=10: one pop, back on Servers |
| 2 | Pass | Tag `spike-fakex`, swipe: Unsaved changes. Keep stays. Swipe again from the Source tab: the dialog, no tab change. Discard leaves, the file still says `spike-fake` |
| 3 | Pass | `abc` in the input: Discard input. Stay stays. Discard goes Home |
| 4 | Pass | `WARP GENERATOR` and Config Editor each pop once |
| 5 | Pass | Home: side menu opens. Swipe over the Unsaved changes dialog: nothing changes |
| 6 | Pass | App Settings: the page follows the finger, a short drag snaps back, a full one pops once to Servers |
| 7 | Pass | Node screen: swipes from x=340 and x=100 change tabs. Folder: a vertical drag at x=19, where the 20-point strip overlaps the handle, moves the row |
| 8 | Pass, full suite pending | Nothing under `app/android/`. `flutter analyze` on the 3 changed Dart files: no issues. 6 tests in `ios_edge_back_gesture_test.dart` and 4 in `double_back_to_exit_test.dart` pass. Full suite runs on CI, which a push to `ios-app` does not start |

Not checked: subscription, chain and rule editor screens by swipe. They use the same handler. A real iPhone. Android.

## Docs to update

- `docs/IOS_DISABLED_FEATURES.md`: back swipe, paste prompt, Magnifier.
- `docs/spec/features/020-APP_SHELL/FUNCTIONS/navigation.md` and `.ru.md`: iOS note and a Revisions row.
- `docs/ARCHITECTURE.md`: the widget in the iOS paragraph.

Stated as none: `CHANGELOG.md` and release notes (nothing changes on Android, nothing ships on iOS), `docs/api/debug-api-reference.md` (no route change), §626 (its text already says gesture).
