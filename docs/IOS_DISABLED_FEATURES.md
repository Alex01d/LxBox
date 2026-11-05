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
| Wi-Fi network list in the rule editor | A rule matches named networks. Add current, Pick saved, Manual | Hidden. Network type and Metered stay (§716 D2) | Needs the Wi-Fi information entitlement and a location prompt, left for its own task (§718 D6). A rule from an Android backup keeps its networks and never matches here |
| Automation tab | Tasker and other apps control L×Box through intents | Hidden | Android intents |
| Tunnel sleep mode | Pauses the tunnel in Doze or with the screen off | Hidden | Android Doze and screen events |
| Keep VPN on exit | VPN outlives the app, or stops on swipe when off | Hidden, always on in VPN mode | iOS does not reliably tell an app it was swiped away (§718) |
| Memory limit | Auto, 200, 384, 512, 768 MB | Hidden, along with the empty System tab in VPN Settings | The tunnel runs under the iOS limit of 50 MB, which the core detects (§718 D5) |
| Service notification and its buttons | Status, Stop, Restart, Send | None. Control Center and Settings → VPN show the connection | iOS has no such notification for a VPN (§718) |
| Allow VPN bypass | Apps may opt out of the tunnel | Hidden | Android `ConnectivityManager` |

## Different, not turned off

| Feature | On Android | On iOS |
|---|---|---|
| VPN mode | System-wide tunnel | Same on a real iPhone, through a tunnel extension (§718). Simulator fails with a reason and needs Proxy mode |
| Tunnel killed by the system | Restarts by itself, up to 3 times in 5 minutes | Stays down, traffic goes direct, and the app shows the reason at next open. Decided for now in §718 D3 |
| Local proxy | Runs in the VPN service | Runs inside the app (§711, §718 D2) |
| App in the background | Service keeps running | VPN mode keeps running. Proxy mode stops when the app leaves the foreground (§711) |
| Code editor | Native editor with highlighting, line numbers, search and wrap | Plain text field. Search opens a Find bar that stays at `0/0` (§718). The wrap button and Magnifier do nothing (§714 D4) |
| Closing the keyboard | Back button | A tap outside the field (§714 D5) |
| Back gesture on a screen that guards back | System back runs the screen's handler | A swipe from the left edge runs the same handler at the end of the drag. The screen does not follow the finger (§715 D1) |
| Paste from clipboard | No prompt | iOS asks to allow paste, once per clipboard content from another app. Don't Allow shows "Clipboard is empty" (§715 D4) |
| Quit & reopen, Restart now | Process ends, home screen shows | Same, through `exit(0)`, which can look like a crash (§714 D6) |
| Usage region, Auto | Country of the mobile network, then device locale | Device locale only. The network lookup is not ported, and a try logs `MissingPluginException` |
| Identity sent to panels | `LxBox-android/<version>`, OS `android` | `LxBox-ios/<version>`, OS `ios` (§714 D7) |
| Camera prompt language | System's own text | Our text in English, Russian or Chinese, by system language (§714 D8) |
| File picker | A tap returns the file | A tap, then Open. Left as is (§714 D9) |
| Sticky session by, Load balance | `process` and domain | `process` has no owner here, so the core hashes the domain alone (§716) |
| System DNS | Uses `LocalResolver` | The core's own lookup, `localDNSTransport` is nil (§716). With `local_dns_resolver` set, a node's domain name resolved through it in VPN mode on a phone (§718). The default resolver is `dns_shield`, which does not use it |
| Device sleep | Pauses only with Tunnel sleep mode set | The core pauses when iOS reports sleep, with no setting (§718 D7) |
| Another VPN check | From the network's VPN transport | From interfaces the system lists, so it can ask needlessly (§718 D4) |

## Still visible, not working, no decision yet

| Feature | State on iOS |
|---|---|
| Google push (FCM) preset | Off by default. Its default rule matches FCM ports and hosts. The option Limit to Google Play Services adds a package condition that never matches |
| Tailscale, Taildrop, OpenConnect screens | Native calls not ported. An OpenConnect node adds, starts with the rest and shows `ERR` on a fake server, with no crash. A real server is not tested (§718) |
| Send to TV | `Scan code` opens the camera on a phone. Sending is not tested, it needs a TV |
| TUN interface name | Has no effect, by code: the extension does not read it and iOS names the interface. Not run |
| Text in settings that stayed | Debug API mentions `adb forward`. System HTTP proxy mentions Android 10, though it works on iOS (§718). The Rules tab says rules can match by app. Metered says "in Android settings", though the condition works on iOS as cellular or personal hotspot. Ru internet segment says "Russian apps (by package name)", with a "Russian apps by package" option, and FCM says "Play region" (§716 D3). The drawer's App Settings subtitle says "automation". Usage region says Auto uses the mobile network. Haptic feedback names the "Touch feedback" setting. Certificate store names Android 7.x, Direct connect timeout describes Android's retries, and the core logs note says force-stop |
