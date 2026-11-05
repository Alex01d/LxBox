import Flutter
import UIKit

final class WifiHistoryBridge {
  private let channel: FlutterMethodChannel
  private var isEnabled = false
  private var activeObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.leadaxe.lxbox/wifi_history", binaryMessenger: messenger)
    activeObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.deliverWaitingNetworks()
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    NativePrefs.set(enabled, for: NativePrefs.autoRecordWifi)
    if enabled {
      deliverWaitingNetworks()
    } else {
      WifiSeenStore.discard()
    }
  }

  private func deliverWaitingNetworks() {
    guard isEnabled else { return }
    notifySeen(WifiSeenStore.drain()[...])
  }

  private func notifySeen(_ networks: ArraySlice<WifiSeen>) {
    guard let seen = networks.first else { return }
    channel.invokeMethod("onWifiSeen", arguments: ["ssid": seen.ssid, "bssid": seen.bssid]) { [weak self] _ in
      self?.notifySeen(networks.dropFirst())
    }
  }
}
