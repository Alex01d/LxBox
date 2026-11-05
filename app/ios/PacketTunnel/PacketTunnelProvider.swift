import Foundation
import Libbox
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private static let interfaceSwitchResetDelay = 1.5

  private let queue = DispatchQueue(label: "lxbox.tunnel", qos: .userInitiated)
  private var server: LibboxCommandServer?
  private var interfaceSwitchReset: DispatchWorkItem?
  private let wifiObserver = WifiNetworkObserver()
  private lazy var platform = makePlatform()

  private func makePlatform() -> TunnelPlatform {
    let platform = TunnelPlatform(self)
    platform.onServiceReload = { [weak self] in self?.queue.async { self?.reloadCore() } }
    platform.onInterfaceSwitch = { [weak self] in self?.scheduleInterfaceSwitchReset() }
    return platform
  }

  override func startTunnel(options _: [String: NSObject]?) async throws {
    TunnelStopRecord().write()
    try queue.sync { try startCore() }
    applyAutoRecordWifi()
  }

  private func applyAutoRecordWifi() {
    if NativePrefs.bool(NativePrefs.autoRecordWifi, fallback: false) {
      wifiObserver.start()
    } else {
      wifiObserver.stop()
    }
  }

  private func startCore() throws {
    do {
      try CoreRuntime.setupTunnel()
    } catch {
      throw failStart("Core init failed: \(error.localizedDescription)", coreError: error.localizedDescription)
    }
    guard let config = readConfig() else {
      throw failStart("Empty configuration", coreError: nil)
    }
    do {
      var error: NSError?
      guard let server = LibboxNewCommandServer(platform, platform, &error) else {
        throw error ?? CorePlatform.failure("No command server")
      }
      self.server = server
      try server.start()
      try server.startOrReloadService(config, options: LibboxOverrideOptions())
    } catch {
      closeCore()
      throw failStart("Failed to start service: \(error.localizedDescription)", coreError: error.localizedDescription)
    }
  }

  private func failStart(_ message: String, coreError: String?) -> NSError {
    TunnelStopRecord(error: message, coreError: coreError).write()
    return CorePlatform.failure(coreError ?? message)
  }

  private func readConfig() -> String? {
    let config = (try? String(contentsOf: CoreRuntime.configFile, encoding: .utf8)) ?? ""
    return config.isEmpty || config == "{}" ? nil : config
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    var record = TunnelStopRecord.read() ?? TunnelStopRecord()
    record.reason = reason.rawValue
    record.write()
    queue.sync { closeCore() }
  }

  private func closeCore() {
    wifiObserver.stop()
    interfaceSwitchReset?.cancel()
    interfaceSwitchReset = nil
    guard let server else {
      platform.reset()
      return
    }
    self.server = nil
    server.close()
    do {
      try server.closeService()
    } catch {
      NSLog("[tunnel] closeService failed: %@", error.localizedDescription)
    }
    platform.reset()
  }

  override func sleep() async {
    queue.sync { server?.pause() }
  }

  override func wake() {
    queue.async { [weak self] in self?.server?.wake() }
  }

  override func handleAppMessage(_ messageData: Data) async -> Data? {
    guard let message = TunnelMessage(rawValue: String(decoding: messageData, as: UTF8.self)) else { return nil }
    switch message {
    case .reload:
      queue.async { [weak self] in self?.reloadCore() }
    case .resetNetwork:
      queue.async { [weak self] in self?.server?.resetNetwork() }
    case .clearDnsCache:
      queue.async { [weak self] in
        CoreRuntime.deleteCacheDb()
        self?.reloadCore()
      }
    case .memoryInfo:
      return try? JSONSerialization.data(withJSONObject: CoreRuntime.memoryInfo())
    case .autoRecordWifi:
      applyAutoRecordWifi()
    }
    return nil
  }

  private func reloadCore() {
    guard let server else { return }
    guard let config = readConfig() else {
      NSLog("[tunnel] reload skipped: empty config")
      return
    }
    do {
      try server.startOrReloadService(config, options: LibboxOverrideOptions())
    } catch {
      server.setError("ios: reload: \(error.localizedDescription)")
    }
  }

  private func scheduleInterfaceSwitchReset() {
    queue.async { [self] in
      interfaceSwitchReset?.cancel()
      let reset = DispatchWorkItem { [weak self] in self?.server?.resetNetwork() }
      interfaceSwitchReset = reset
      queue.asyncAfter(deadline: .now() + Self.interfaceSwitchResetDelay, execute: reset)
    }
  }
}
