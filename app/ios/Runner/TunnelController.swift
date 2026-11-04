import Foundation
import NetworkExtension

final class TunnelController {
  private static let displayName = "L×Box"
  private static let extensionSuffix = ".PacketTunnel"

  var onStatusChange: ((NEVPNStatus) -> Void)?

  private var manager: NETunnelProviderManager?
  private var loaded = false
  private var loadWaiters: [() -> Void] = []
  private var statusObserver: NSObjectProtocol?

  init() {
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.onStatusChange?(self.status)
    }
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      DispatchQueue.main.async { self?.finishLoading(managers?.first, error) }
    }
  }

  private func finishLoading(_ manager: NETunnelProviderManager?, _ error: Error?) {
    if let error {
      NSLog("[tunnel] loading preferences failed: %@", error.localizedDescription)
    }
    self.manager = manager
    loaded = true
    let waiters = loadWaiters
    loadWaiters = []
    waiters.forEach { $0() }
  }

  func whenLoaded(_ action: @escaping () -> Void) {
    if loaded {
      action()
    } else {
      loadWaiters.append(action)
    }
  }

  var status: NEVPNStatus {
    manager?.connection.status ?? .invalid
  }

  var isRunning: Bool {
    status != .invalid && status != .disconnected
  }

  var connectedDate: Date? {
    manager?.connection.connectedDate
  }

  func start(_ completion: @escaping (Error?) -> Void) {
    whenLoaded { [self] in
      let manager = manager ?? NETunnelProviderManager()
      manager.protocolConfiguration = makeProtocol()
      manager.localizedDescription = Self.displayName
      manager.isEnabled = true
      manager.saveToPreferences { [self] error in
        DispatchQueue.main.async {
          if let error {
            completion(error)
          } else {
            reloadAndConnect(manager, completion)
          }
        }
      }
    }
  }

  private func makeProtocol() -> NETunnelProviderProtocol {
    let provider = NETunnelProviderProtocol()
    provider.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + Self.extensionSuffix
    provider.serverAddress = Self.displayName
    return provider
  }

  private func reloadAndConnect(_ manager: NETunnelProviderManager, _ completion: @escaping (Error?) -> Void) {
    manager.loadFromPreferences { [self] error in
      DispatchQueue.main.async {
        if let error {
          completion(error)
          return
        }
        self.manager = manager
        do {
          try manager.connection.startVPNTunnel()
          completion(nil)
        } catch {
          completion(error)
        }
      }
    }
  }

  func stop() {
    manager?.connection.stopVPNTunnel()
  }

  func send(_ message: TunnelMessage, reply: @escaping (Data?) -> Void = { _ in }) {
    guard let session = manager?.connection as? NETunnelProviderSession else {
      reply(nil)
      return
    }
    do {
      try session.sendProviderMessage(Data(message.rawValue.utf8)) { data in
        DispatchQueue.main.async { reply(data) }
      }
    } catch {
      NSLog("[tunnel] message %@ failed: %@", message.rawValue, error.localizedDescription)
      reply(nil)
    }
  }

  func fetchLastDisconnectError(_ completion: @escaping (String?) -> Void) {
    guard #available(iOS 16.0, *), let connection = manager?.connection else {
      completion(nil)
      return
    }
    connection.fetchLastDisconnectError { error in
      DispatchQueue.main.async { completion(error?.localizedDescription) }
    }
  }
}
