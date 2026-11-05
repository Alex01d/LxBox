import Flutter
import Foundation
import Libbox
import NetworkExtension
import UIKit

final class ChannelSink: NSObject, FlutterStreamHandler {
  var onListened: (() -> Void)?
  private var sink: FlutterEventSink?

  func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    onListened?()
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  var isListening: Bool { sink != nil }

  func send(_ value: Any) {
    sink?(value)
  }
}

final class CoreService {
  enum Status: String {
    case starting = "Starting"
    case started = "Started"
    case stopping = "Stopping"
    case stopped = "Stopped"
  }

  private static let stopWaitSeconds = 9.0
  private static let logQueueMax = 4096
  private static let logBatchMax = 200
  private static let revokedMessage = "Another VPN app took the system VPN slot (e.g. an always-on VPN). Start again to reconnect."
  private static let tunnelStoppedMessage = "The tunnel stopped unexpectedly."
  private static let revokingStopReasons: Set<NEProviderStopReason> = [
    .superceded, .configurationDisabled, .configurationRemoved, .userInitiated,
  ]

  let statusSink = ChannelSink()
  let logSink = ChannelSink()
  let client: CoreCommandClient
  let probe = CoreProbeSession()

  private(set) var status = Status.stopped
  private(set) var revoked = false
  private var startedAt: Date?
  private var stopWaiters: [FlutterResult] = []
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid

  private let queue = DispatchQueue(label: "lxbox.core", qos: .userInitiated)
  private let platform = CorePlatform()
  private let tunnel = TunnelController()
  private var inTunnel = false
  private var tunnelStartPending = false
  private var tunnelStopRequested = false
  private let serverLock = NSLock()
  private var server: LibboxCommandServer?

  private let logLock = NSLock()
  private var logQueue: [String] = []
  private var logDrainScheduled = false
  private var verboseLogs = NativePrefs.bool("core_logs_verbose", fallback: false)

  private static let ansiEscape = try? NSRegularExpression(pattern: "\\u001B\\[[0-9;]*[A-Za-z]|\\u001B")
  private static let traceOrDebug = try? NSRegularExpression(pattern: "\\b(TRACE|DEBUG)\\b")

  init(client: CoreCommandClient) {
    self.client = client
    platform.onDebugMessage = { [weak self] in self?.writeLog($0) }
    platform.onServiceStop = { [weak self] in
      DispatchQueue.main.async { self?.stop(nil) }
    }
    platform.onServiceReload = { [weak self] in self?.reloadOnQueue() }
    probe.onServiceStop = { [weak self] in
      self?.queue.async { self?.probe.stop() }
    }
    client.onLogLines = { [weak self] lines in lines.forEach { self?.writeLog($0) } }
    tunnel.onStatusChange = { [weak self] status in self?.tunnelStatusChanged(status) }
    tunnel.whenLoaded { [weak self] in self?.adoptTunnelOnLaunch() }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  var uptimeMs: Int {
    guard status == .started, let startedAt else { return 0 }
    return Int(Date().timeIntervalSince(startedAt) * 1000)
  }

  func setVerboseLogs(_ enabled: Bool) {
    logLock.lock()
    verboseLogs = enabled
    logLock.unlock()
  }

  func whenTunnelKnown(_ action: @escaping () -> Void) {
    tunnel.whenLoaded(action)
  }

  private var startsInTunnel: Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      return NativePrefs.bool("has_tun", fallback: true)
    #endif
  }

  func start(_ reply: @escaping FlutterResult) {
    guard status == .stopped, !tunnelStartPending else {
      reply(true)
      return
    }
    guard startsInTunnel else {
      setStatus(.starting)
      queue.async { [weak self] in self?.runStart() }
      reply(true)
      return
    }
    tunnelStartPending = true
    queue.async { [weak self] in
      self?.probe.stop()
      DispatchQueue.main.async { self?.startTunnel(reply) }
    }
  }

  private func startTunnel(_ reply: @escaping FlutterResult) {
    tunnel.start { [weak self] error in
      self?.tunnelStartPending = false
      if let error {
        NSLog("[tunnel] start failed: %@", error.localizedDescription)
        reply(false)
      } else {
        self?.inTunnel = true
        reply(true)
      }
    }
  }

  private func adoptTunnelOnLaunch() {
    if tunnel.isRunning {
      tunnelStatusChanged(tunnel.status)
      return
    }
    guard let record = TunnelStopRecord.take() else { return }
    if statusSink.isListening {
      reportTunnelStop(record)
    } else {
      statusSink.onListened = { [weak self] in
        self?.statusSink.onListened = nil
        self?.reportTunnelStop(record)
      }
    }
  }

  private func tunnelStatusChanged(_ vpnStatus: NEVPNStatus) {
    switch vpnStatus {
    case .connecting:
      guard adoptTunnelSession() else { return }
      if status == .stopped { setStatus(.starting) }
    case .connected, .reasserting:
      guard adoptTunnelSession(), status == .stopped || status == .starting else { return }
      startedAt = tunnel.connectedDate ?? Date()
      client.startStatus()
      if NativePrefs.bool("core_logs_enabled", fallback: false) { client.startLogs() }
      setStatus(.started)
    case .disconnecting:
      guard inTunnel, status == .starting || status == .started else { return }
      setStatus(.stopping)
      shutdownClientsOffMain()
    case .disconnected, .invalid:
      guard inTunnel else { return }
      finishTunnelSession()
    @unknown default:
      break
    }
  }

  private func adoptTunnelSession() -> Bool {
    guard inTunnel || currentServer() == nil else { return false }
    inTunnel = true
    return true
  }

  private func shutdownClientsOffMain() {
    queue.async { [client] in client.shutdownAll() }
  }

  private func finishTunnelSession() {
    inTunnel = false
    let requested = tunnelStopRequested
    tunnelStopRequested = false
    shutdownClientsOffMain()
    let record = TunnelStopRecord.take()
    if requested {
      setStatus(.stopped)
    } else {
      reportTunnelStop(record)
    }
  }

  private func reportTunnelStop(_ record: TunnelStopRecord?) {
    if let message = record?.error {
      setStatus(.stopped, error: message, coreError: record?.coreError)
      return
    }
    let reason = record?.reason.flatMap(NEProviderStopReason.init(rawValue:))
    if let reason, Self.revokingStopReasons.contains(reason) {
      setStatus(.stopped, error: Self.revokedMessage, revoked: true)
    } else if reason == NEProviderStopReason.none {
      setStatus(.stopped)
    } else {
      tunnel.fetchLastDisconnectError { [weak self] detail in
        self?.setStatus(.stopped, error: Self.tunnelStoppedMessage, coreError: detail)
      }
    }
  }

  private func runStart() {
    CoreRuntime.waitUntilReady()
    probe.stop()
    if let setupError = CoreRuntime.setupError {
      failStart("Core init failed: \(setupError)", coreError: setupError)
      return
    }
    let config = (try? String(contentsOf: CoreRuntime.configFile, encoding: .utf8)) ?? ""
    if config.isEmpty || config == "{}" {
      failStart("Empty configuration", coreError: nil)
      return
    }
    do {
      var error: NSError?
      guard let server = LibboxNewCommandServer(platform, platform, &error) else {
        throw error ?? NSError(domain: "LxBox", code: 0, userInfo: [NSLocalizedDescriptionKey: "No command server"])
      }
      setServer(server)
      try server.start()
      try server.startOrReloadService(config, options: LibboxOverrideOptions())
    } catch {
      failStart("Failed to start service: \(error.localizedDescription)", coreError: error.localizedDescription)
      return
    }
    DispatchQueue.main.async { [weak self] in self?.finishStart() }
  }

  private func finishStart() {
    guard status == .starting else { return }
    startedAt = Date()
    client.startStatus()
    setStatus(.started)
  }

  private func failStart(_ message: String, coreError: String?) {
    teardown()
    DispatchQueue.main.async { [weak self] in
      self?.setStatus(.stopped, error: message, coreError: coreError)
    }
  }

  func startProbe(config: String, _ reply: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      let answer = self.probeStartAnswer(config: config)
      DispatchQueue.main.async { reply(answer) }
    }
  }

  private func probeStartAnswer(config: String) -> [String: Any] {
    CoreRuntime.waitUntilReady()
    if let setupError = CoreRuntime.setupError {
      return CoreProbeSession.startResult(error: "Core init failed: \(setupError)")
    }
    if currentServer() != nil || tunnel.isRunning {
      return CoreProbeSession.startResult(error: "VPN is running")
    }
    return probe.start(config: config)
  }

  func stopProbe(runId: Int, _ reply: @escaping FlutterResult) {
    queue.async { [weak self] in
      self?.probe.stop(runId: runId)
      DispatchQueue.main.async { reply(nil) }
    }
  }

  func stop(_ reply: FlutterResult?) {
    if status == .stopped {
      reply?(true)
      return
    }
    if let reply {
      stopWaiters.append(reply)
    }
    if status == .stopping { return }
    setStatus(.stopping)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopWaitSeconds) { [weak self] in
      self?.finishStopWaiters(false)
    }
    if inTunnel {
      tunnelStopRequested = true
      shutdownClientsOffMain()
      tunnel.stop()
      return
    }
    queue.async { [weak self] in
      self?.teardown()
      DispatchQueue.main.async { self?.setStatus(.stopped) }
    }
  }

  func forceStop() {
    guard status != .stopped else { return }
    if inTunnel {
      tunnelStopRequested = true
      shutdownClientsOffMain()
      tunnel.stop()
    } else {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.teardown() }
    }
    setStatus(.stopped)
  }

  private func teardown() {
    client.shutdownAll()
    guard let server = takeServer() else {
      platform.reset()
      return
    }
    server.close()
    do {
      try server.closeService()
    } catch {
      NSLog("[core] closeService failed: %@", error.localizedDescription)
    }
    platform.reset()
  }

  private func setServer(_ server: LibboxCommandServer) {
    serverLock.lock()
    self.server = server
    serverLock.unlock()
  }

  private func currentServer() -> LibboxCommandServer? {
    serverLock.lock()
    defer { serverLock.unlock() }
    return server
  }

  private func takeServer() -> LibboxCommandServer? {
    serverLock.lock()
    defer { serverLock.unlock() }
    let current = server
    server = nil
    return current
  }

  func reload() {
    guard status == .started else { return }
    if inTunnel {
      tunnel.send(.reload)
      return
    }
    queue.async { [weak self] in self?.reloadOnQueue() }
  }

  private func reloadOnQueue() {
    guard let server = currentServer() else { return }
    let config = (try? String(contentsOf: CoreRuntime.configFile, encoding: .utf8)) ?? ""
    if config.isEmpty || config == "{}" {
      NSLog("[core] reload skipped: empty config")
      return
    }
    do {
      try server.startOrReloadService(config, options: LibboxOverrideOptions())
    } catch {
      server.setError("ios: reload: \(error.localizedDescription)")
    }
  }

  func applyAutoRecordWifi() {
    guard inTunnel else { return }
    tunnel.send(.autoRecordWifi)
  }

  func resetNetwork() {
    if inTunnel {
      tunnel.send(.resetNetwork)
      return
    }
    queue.async { [weak self] in self?.currentServer()?.resetNetwork() }
  }

  func clearDnsCache() {
    if inTunnel {
      tunnel.send(.clearDnsCache)
      return
    }
    CoreRuntime.deleteCacheDb()
    reload()
  }

  func memoryInfo(_ reply: @escaping FlutterResult) {
    guard inTunnel else {
      reply(CoreRuntime.memoryInfo())
      return
    }
    tunnel.send(.memoryInfo) { data in
      let info = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
      reply(info ?? ["totalPss": 0])
    }
  }

  private func setStatus(_ newStatus: Status, error: String? = nil, coreError: String? = nil, revoked: Bool = false) {
    if status == newStatus, error == nil { return }
    status = newStatus
    self.revoked = revoked
    if newStatus == .stopped {
      startedAt = nil
    }
    var event: [String: Any] = ["status": newStatus.rawValue]
    if let error {
      event["error"] = error
    }
    if let coreError, !coreError.isEmpty {
      event["core_error"] = coreError
    }
    if revoked {
      event["revoked"] = true
    }
    statusSink.send(event)
    if newStatus == .stopped {
      finishStopWaiters(true)
      endBackgroundTask()
    }
  }

  private func finishStopWaiters(_ stopped: Bool) {
    let waiters = stopWaiters
    stopWaiters = []
    waiters.forEach { $0(stopped) }
  }

  @objc private func didEnterBackground() {
    if status == .stopped, probe.isActive {
      closeProbeInBackground()
      return
    }
    guard !inTunnel, status == .started || status == .starting else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
      self?.forceStop()
      self?.endBackgroundTask()
    }
    stop(nil)
  }

  @objc private func didBecomeActive() {
    tunnel.whenLoaded { [weak self] in
      guard let self else { return }
      self.tunnelStatusChanged(self.tunnel.status)
    }
  }

  private func closeProbeInBackground() {
    backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
      self?.endBackgroundTask()
    }
    queue.async { [weak self] in
      self?.probe.stop()
      DispatchQueue.main.async { self?.endBackgroundTask() }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func writeLog(_ message: String) {
    let range = NSRange(message.startIndex..., in: message)
    let plain = Self.ansiEscape?.stringByReplacingMatches(in: message, range: range, withTemplate: "") ?? message
    let plainRange = NSRange(plain.startIndex..., in: plain)
    logLock.lock()
    defer { logLock.unlock() }
    if !verboseLogs, Self.traceOrDebug?.firstMatch(in: plain, range: plainRange) != nil { return }
    if logQueue.count >= Self.logQueueMax { return }
    logQueue.append(plain)
    if !logDrainScheduled {
      logDrainScheduled = true
      DispatchQueue.main.async { [weak self] in self?.drainLog() }
    }
  }

  private func drainLog() {
    logLock.lock()
    let batch = Array(logQueue.prefix(Self.logBatchMax))
    logQueue.removeFirst(batch.count)
    let more = !logQueue.isEmpty
    logDrainScheduled = more
    logLock.unlock()
    if logSink.isListening, !batch.isEmpty {
      logSink.send(batch)
    }
    if more {
      DispatchQueue.main.async { [weak self] in self?.drainLog() }
    }
  }
}
