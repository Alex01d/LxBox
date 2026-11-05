import Foundation
import Network
import NetworkExtension

final class WifiNetworkObserver {
  private static let stickinessThreshold: TimeInterval = 300

  private let queue = DispatchQueue(label: "lxbox.wifi-observer")
  private var monitor: NWPathMonitor?
  private var pending: WifiSeen?
  private var pendingTimer: DispatchWorkItem?

  func start() {
    queue.async { [self] in
      guard monitor == nil else { return }
      let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
      monitor.pathUpdateHandler = { [weak self] path in self?.handlePathUpdate(path) }
      monitor.start(queue: queue)
      self.monitor = monitor
    }
  }

  func stop() {
    queue.async { [self] in
      monitor?.cancel()
      monitor = nil
      cancelPending()
    }
  }

  private func handlePathUpdate(_ path: Network.NWPath) {
    guard path.status == .satisfied else {
      cancelPending()
      return
    }
    NEHotspotNetwork.fetchCurrent { [weak self] network in
      guard let self, let network, !network.ssid.isEmpty else { return }
      let seen = WifiSeen(ssid: network.ssid, bssid: network.bssid)
      self.queue.async { self.handlePending(seen) }
    }
  }

  private func handlePending(_ seen: WifiSeen) {
    guard monitor != nil, seen != pending else { return }
    cancelPending()
    pending = seen
    let timer = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.pendingTimer = nil
      WifiSeenStore.append(seen)
    }
    pendingTimer = timer
    queue.asyncAfter(deadline: .now() + Self.stickinessThreshold, execute: timer)
  }

  private func cancelPending() {
    pendingTimer?.cancel()
    pendingTimer = nil
    pending = nil
  }
}
