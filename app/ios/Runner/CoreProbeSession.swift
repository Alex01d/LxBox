import Foundation
import Libbox

final class CoreProbeSession {
  private static let staleRun = "stale run"
  private static let closeWaitSeconds = 3.0

  private final class Session {
    let runId: Int
    let server: LibboxCommandServer
    let client: LibboxCommandClient
    let platform: CorePlatform
    var cancelled = false
    private let clientLock = NSLock()
    private var clientClosed = false

    init(runId: Int, server: LibboxCommandServer, client: LibboxCommandClient, platform: CorePlatform) {
      self.runId = runId
      self.server = server
      self.client = client
      self.platform = platform
    }

    func disconnectClient() {
      clientLock.lock()
      let alreadyClosed = clientClosed
      clientClosed = true
      clientLock.unlock()
      if !alreadyClosed {
        try? client.disconnect()
      }
    }
  }

  var onServiceStop: (() -> Void)?

  private let lock = NSLock()
  private var session: Session?
  private var lastRunId = 0

  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return session != nil
  }

  static func startResult(error: String, runId: Int = 0) -> [String: Any] {
    ["error": error, "runId": runId]
  }

  func start(config: String) -> [String: Any] {
    stop()
    let platform = CorePlatform()
    platform.onDebugMessage = { NSLog("[probe] %@", $0) }
    platform.onServiceStop = { [weak self] in self?.onServiceStop?() }
    var error: NSError?
    guard let server = LibboxNewCommandServer(platform, platform, &error) else {
      return Self.startResult(error: error?.localizedDescription ?? "No command server")
    }
    do {
      try server.start()
      try server.startOrReloadService(config, options: LibboxOverrideOptions())
    } catch {
      close(server, platform)
      return Self.startResult(error: error.localizedDescription)
    }
    guard let client = LibboxNewCommandClient(ClientHandler(), LibboxCommandClientOptions()) else {
      close(server, platform)
      return Self.startResult(error: "No command client")
    }
    do {
      try client.connect()
    } catch {
      close(server, platform)
      return Self.startResult(error: error.localizedDescription)
    }
    return Self.startResult(error: "", runId: remember(server: server, client: client, platform: platform))
  }

  private func remember(server: LibboxCommandServer, client: LibboxCommandClient, platform: CorePlatform) -> Int {
    lock.lock()
    defer { lock.unlock() }
    lastRunId += 1
    session = Session(runId: lastRunId, server: server, client: client, platform: platform)
    return lastRunId
  }

  private func liveSession(_ runId: Int) -> (session: Session?, refusal: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let session else { return (nil, "probe session not running") }
    if session.runId != runId { return (nil, Self.staleRun) }
    if session.cancelled { return (nil, "probe run cancelled") }
    return (session, "")
  }

  func urlTest(runId: Int, tag: String, link: String, timeoutMs: Int32) -> [String: Any] {
    let (session, refusal) = liveSession(runId)
    guard let session else { return ["delay": 0, "error": refusal] }
    let measured = measure(session, tag: tag, link: link, timeoutMs: timeoutMs)
    if measured.error.isEmpty {
      return ["delay": measured.delay, "error": ""]
    }
    let closedReason = liveSession(runId).refusal
    return ["delay": measured.delay, "error": closedReason.isEmpty ? measured.error : closedReason]
  }

  private func measure(_ session: Session, tag: String, link: String, timeoutMs: Int32) -> (delay: Int32, error: String) {
    do {
      let result = try session.client.urlTestOutbound(tag, link: link, timeout: timeoutMs)
      return (result.delay, result.error)
    } catch {
      return (0, error.localizedDescription)
    }
  }

  func getUrl(runId: Int, tag: String, link: String, timeoutMs: Int32, maxBytes: Int32, userAgent: String) -> [String: Any] {
    let (session, refusal) = liveSession(runId)
    guard let session else { return ["error": refusal] }
    let headers = userAgent.isEmpty ? nil : LibboxNewHTTPHeaders()
    headers?.add("User-Agent", value: userAgent)
    do {
      let result = try session.client.getURLViaOutbound(tag, link: link, timeout: timeoutMs, maxBytes: maxBytes, headers: headers)
      return [
        "status": result.status(),
        "content": result.content(),
        "truncated": result.truncated(),
        "contentType": result.contentType(),
        "remoteAddr": result.remoteAddr(),
        "elapsedMs": result.elapsedMs(),
        "error": "",
      ]
    } catch {
      return ["error": error.localizedDescription]
    }
  }

  func cancel(runId: Int) {
    lock.lock()
    let current = session?.runId == runId ? session : nil
    current?.cancelled = true
    lock.unlock()
    current?.disconnectClient()
  }

  func stop(runId: Int) {
    lock.lock()
    let isStale = session != nil && session?.runId != runId
    lock.unlock()
    if !isStale {
      stop()
    }
  }

  func stop() {
    lock.lock()
    let current = session
    session = nil
    lock.unlock()
    guard let current else { return }
    current.disconnectClient()
    close(current.server, current.platform)
  }

  private func close(_ server: LibboxCommandServer, _ platform: CorePlatform) {
    let closed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      server.close()
      do {
        try server.closeService()
      } catch {
        NSLog("[probe] closeService failed: %@", error.localizedDescription)
      }
      platform.reset()
      closed.signal()
    }
    if closed.wait(timeout: .now() + Self.closeWaitSeconds) == .timedOut {
      NSLog("[probe] close timed out, session released")
    }
  }
}
