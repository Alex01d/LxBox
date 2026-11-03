# What is turned off on iOS

L×Box on iOS is an internal build. This page lists what Android has and iOS does not, and why. Decisions come from [§714](spec/tasks/714-ios-platform-differences.md). The code gate is `app/lib/services/platform_features.dart`.

A hidden setting keeps its stored value, so a backup taken on iOS still restores on Android.

## Turned off

| Feature | On Android | On iOS | Why |
|---|---|---|---|
| Tunnel apps tab in Routing | Choose which apps go through the VPN | Hidden | iOS gives an app no list of other apps. Per-app VPN needs MDM, and a profile sets the rules, not the app |
| Apps section in the rule editor | A rule can match an app | Hidden | Same. iOS does not tell which app opened a connection |
| App row in URL Check | Test as if a given app connected | Hidden | Same |
| Unknown traffic preset | Traffic with no known app goes direct | Hidden, never applied | iOS reports no owner for any connection, so the rule would catch all tunnel traffic |
| Auto-start on boot | VPN starts when the device turns on | Hidden | No boot start for an app on iOS |
| Quick Settings tile, home-screen shortcut | One tap from the shade or icon | Hidden | Android system surfaces |
| Check for updates, update block in About | Finds a new APK | Hidden | Releases hold Android files only |
| Installed from, Where to get L×Box | Shows the install channel and links | Hidden | Android channels only |
| Battery, Notifications, Location, Nearby Wi-Fi, App info rows | Show real permission state, open system settings | Hidden | Android system services. On iOS they would always read as granted |
| Auto-record visited Wi-Fi networks | Remembers networks for Wi-Fi rules | Hidden | Needs native Wi-Fi reading that iOS does not have here |
| Automation tab | Tasker and other apps control L×Box through intents | Hidden | Android intents |
| Tunnel sleep mode | Pauses the tunnel in Doze or with the screen off | Hidden | Android Doze and screen events |
| Keep VPN on exit | VPN outlives the app | Hidden | The core stops with the app until the tunnel exists |
| Allow VPN bypass | Apps may opt out of the tunnel | Hidden | Android `ConnectivityManager` |

## Different, not turned off

| Feature | On Android | On iOS |
|---|---|---|
| VPN mode | System-wide tunnel | Fails with a reason. Only Local proxy works until a paid Apple team exists (§711) |
| App in the background | Service keeps running | The core stops when the app leaves the foreground (§711) |
| Code editor | Native editor with highlighting, line numbers, search and wrap | Plain text field. The search and wrap buttons do nothing (§714 D4) |
| Closing the keyboard | Back button | A tap outside the field (§714 D5) |
| Quit & reopen, Restart now | Process ends, home screen shows | Same, through `exit(0)`, which can look like a crash (§714 D6) |
| Usage region, Auto | Country of the mobile network, then device locale | Device locale only. The network lookup is not ported |
| Identity sent to panels | `LxBox-android/<version>`, OS `android` | `LxBox-ios/<version>`, OS `ios` (§714 D7) |
| Camera prompt language | System's own text | Our text in English, Russian or Chinese, by system language (§714 D8) |
| File picker | A tap returns the file | A tap, then Open. Left as is (§714 D9) |

## Still visible, not working, no decision yet

| Feature | State on iOS |
|---|---|
| Wi-Fi conditions in rules | iOS gives the core no Wi-Fi name, so these rules never match. Needs an entitlement and location permission |
| Google push (FCM) preset | Off by default. Its package condition never matches |
| Tailscale, Taildrop, OpenConnect screens | Native calls not ported |
| Send to TV | Depends on the camera, not tested |
| Text in settings that stayed | Debug API mentions `adb forward`. Memory limit says Auto sets no threshold, on iOS it means 50 MB. System HTTP proxy mentions Android 10. The Rules tab says rules can match by app |
