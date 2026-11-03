import Foundation
import Libbox

final class CoreCommandClient {
  private static let statusIntervalNormal: Int64 = 500_000_000
  private static let statusIntervalFast: Int64 = 100_000_000
  private static let reconnectDelay = 0.5
  private static let endpointErrorCodes = [
    "NotFound": "not_found",
    "InvalidArgument": "invalid_argument",
    "FailedPrecondition": "failed_precondition",
    "Unavailable": "unavailable",
  ]

  let statusEmitter = SnapshotEmitter()
  let outboundsEmitter = SnapshotEmitter()
  let groupsEmitter = SnapshotEmitter()
  let connectionsEmitter = SnapshotEmitter()
  let dnsQueriesEmitter = BatchEmitter()
  let connectionTestEmitter = BatchEmitter()

  private let ops = DispatchQueue(label: "lxbox.core.client", qos: .userInitiated)
  private let lock = NSLock()

  private var statusClient: LibboxCommandClient?
  private var screenClient: LibboxCommandClient?
  private var pingClient: LibboxCommandClient?
  private var profilerClient: LibboxCommandClient?
  private var connectionTestClient: LibboxCommandClient?
  private var connectionTestSession: LibboxConnectionTestSession?
  private var statusHandler: ClientHandler?
  private var screenHandler: ClientHandler?
  private var profilerHandler: ClientHandler?
  private var connectionTestHandler: ConnectionTestHandler?
  private let pingHandler = ClientHandler()

  private var tunnelAlive = false
  private var statusPaused = false
  private var screenPaused = false
  private var screenRefs = 0
  private var statusInterval = statusIntervalNormal
  private var statusGeneration = 0
  private var screenGeneration = 0
  private var profilerGeneration = 0
  private var connectionTestGeneration = 0

  private let connectionsLock = NSLock()
  private var connections: LibboxConnections?
  private var profilerConnections: LibboxConnections?

  var isAlive: Bool { locked { tunnelAlive } }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  func startStatus() {
    locked {
      tunnelAlive = true
      statusPaused = false
    }
    ops.async { [self] in connectStatus() }
  }

  func setStatusFast(_ fast: Bool) {
    let want = fast ? Self.statusIntervalFast : Self.statusIntervalNormal
    let reconnect: Bool = locked {
      if statusInterval == want { return false }
      statusInterval = want
      return tunnelAlive && !statusPaused
    }
    if reconnect {
      ops.async { [self] in connectStatus() }
    }
  }

  func pauseClients() {
    ops.async { [self] in
      locked {
        statusPaused = true
        screenPaused = true
      }
      disconnect(takeStatusClient())
      disconnect(takeScreenClient())
    }
  }

  func resumeClients() {
    ops.async { [self] in
      let (status, screen): (Bool, Bool) = locked {
        statusPaused = false
        screenPaused = false
        return (tunnelAlive, tunnelAlive && screenRefs > 0)
      }
      if status { connectStatus() }
      if screen { connectScreen() }
    }
  }

  func connectScreenRef() {
    ops.async { [self] in
      let connect: Bool = locked {
        screenRefs += 1
        return screenRefs == 1 && !screenPaused && tunnelAlive
      }
      if connect { connectScreen() }
    }
  }

  func disconnectScreenRef() {
    ops.async { [self] in
      let close: Bool = locked {
        screenRefs = max(0, screenRefs - 1)
        return screenRefs == 0
      }
      if close { disconnect(takeScreenClient()) }
    }
  }

  func resyncForReopen() {
    ops.async { [self] in
      let alive: Bool = locked {
        screenRefs = 0
        screenPaused = false
        statusPaused = false
        statusInterval = Self.statusIntervalNormal
        return tunnelAlive
      }
      disconnect(takeScreenClient())
      disconnect(takeProfilerClient())
      cancelPing()
      if alive { connectStatus() }
    }
  }

  func shutdownAll() {
    ops.sync { [self] in
      locked {
        tunnelAlive = false
        screenRefs = 0
        screenPaused = false
        statusPaused = false
        statusInterval = Self.statusIntervalNormal
        statusGeneration += 1
        screenGeneration += 1
        profilerGeneration += 1
      }
      disconnect(takeStatusClient())
      disconnect(takeScreenClient())
      disconnect(takeProfilerClient())
      cancelPing()
      closeConnectionTest()
      connectionsLock.lock()
      connections = nil
      profilerConnections = nil
      connectionsLock.unlock()
    }
  }

  private func takeStatusClient() -> LibboxCommandClient? {
    locked {
      let client = statusClient
      statusClient = nil
      return client
    }
  }

  private func takeScreenClient() -> LibboxCommandClient? {
    locked {
      let client = screenClient
      screenClient = nil
      return client
    }
  }

  private func takeProfilerClient() -> LibboxCommandClient? {
    locked {
      let client = profilerClient
      profilerClient = nil
      return client
    }
  }

  private func disconnect(_ client: LibboxCommandClient?) {
    try? client?.disconnect()
  }

  private func connectStatus() {
    let setup: (Int, Int64)? = locked {
      guard tunnelAlive, !statusPaused else { return nil }
      statusGeneration += 1
      return (statusGeneration, statusInterval)
    }
    guard let (generation, interval) = setup else { return }
    let handler = ClientHandler()
    handler.onDisconnected = { [weak self] in self?.statusDisconnected(generation) }
    handler.onStatus = { [weak self] message in self?.emitStatus(message, generation) }
    let options = LibboxCommandClientOptions()
    options.addCommand(LibboxCommandStatus)
    options.statusInterval = interval
    guard let client = LibboxNewCommandClient(handler, options) else { return }
    do {
      try client.connect()
      let previous: LibboxCommandClient? = locked {
        let current = statusClient
        statusClient = client
        statusHandler = handler
        return current
      }
      disconnect(previous)
    } catch {
      NSLog("[core] status client failed: %@", error.localizedDescription)
      scheduleStatusReconnect()
    }
  }

  private func statusDisconnected(_ generation: Int) {
    let reconnect = locked { generation == statusGeneration && tunnelAlive }
    if reconnect { scheduleStatusReconnect() }
  }

  private func scheduleStatusReconnect() {
    ops.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
      self?.connectStatus()
    }
  }

  private func connectScreen() {
    let generation: Int = locked {
      screenGeneration += 1
      return screenGeneration
    }
    connectionsLock.lock()
    if connections == nil {
      connections = LibboxConnections()
    }
    connectionsLock.unlock()
    let handler = ClientHandler()
    handler.onOutbounds = { [weak self] items in self?.emitOutbounds(items, generation) }
    handler.onGroups = { [weak self] groups in self?.emitGroups(groups, generation) }
    handler.onConnectionEvents = { [weak self] events in self?.applyConnectionEvents(events, generation) }
    let options = LibboxCommandClientOptions()
    options.addCommand(LibboxCommandOutbounds)
    options.addCommand(LibboxCommandGroup)
    options.addCommand(LibboxCommandConnections)
    guard let client = LibboxNewCommandClient(handler, options) else { return }
    do {
      try client.connect()
      let previous: LibboxCommandClient? = locked {
        let current = screenClient
        screenClient = client
        screenHandler = handler
        return current
      }
      disconnect(previous)
    } catch {
      NSLog("[core] screen client failed: %@", error.localizedDescription)
    }
  }

  func connectProfiler() {
    ops.async { [self] in connectProfilerClient() }
  }

  func disconnectProfiler() {
    ops.async { [self] in disconnect(takeProfilerClient()) }
  }

  private func connectProfilerClient() {
    let setup: Int? = locked {
      guard tunnelAlive else { return nil }
      profilerGeneration += 1
      return profilerGeneration
    }
    guard let generation = setup else { return }
    connectionsLock.lock()
    if profilerConnections == nil {
      profilerConnections = LibboxConnections()
    }
    connectionsLock.unlock()
    let handler = ClientHandler()
    handler.onConnectionEvents = { [weak self] events in self?.applyProfilerConnectionEvents(events, generation) }
    handler.onDnsQuery = { [weak self] query in self?.emitDnsQuery(query) }
    let options = LibboxCommandClientOptions()
    options.addCommand(LibboxCommandConnections)
    options.addCommand(LibboxCommandDNS)
    options.dnsIncludeAnswers = true
    guard let client = LibboxNewCommandClient(handler, options) else { return }
    do {
      try client.connect()
      let previous: LibboxCommandClient? = locked {
        let current = profilerClient
        profilerClient = client
        profilerHandler = handler
        return current
      }
      disconnect(previous)
    } catch {
      NSLog("[core] profiler client failed: %@", error.localizedDescription)
    }
  }

  func startConnectionTest(link: String, packageName: String, depth: Int32, fresh: Bool) {
    ops.async { [self] in
      closeConnectionTest()
      let generation: Int = locked {
        connectionTestGeneration += 1
        return connectionTestGeneration
      }
      let handler = ConnectionTestHandler { [weak self] event in
        guard let self, self.locked({ generation == self.connectionTestGeneration }) else { return }
        self.connectionTestEmitter.offer(event)
      }
      guard let client = LibboxNewCommandClient(ClientHandler(), LibboxCommandClientOptions()) else { return }
      guard let request = LibboxNewConnectionTestRequest() else { return }
      request.setLink(link)
      if !packageName.isEmpty {
        request.setPackageName(packageName)
      }
      request.setAppDNS(true)
      request.setDepth(depth)
      request.setFresh(fresh)
      do {
        try client.connect()
        let session = try client.startConnectionTest(request, handler: handler)
        locked {
          connectionTestClient = client
          connectionTestSession = session
          connectionTestHandler = handler
        }
      } catch {
        disconnect(client)
        connectionTestEmitter.offer(["event": "error", "message": error.localizedDescription])
      }
    }
  }

  func stopConnectionTest() {
    ops.async { [self] in closeConnectionTest() }
  }

  private func closeConnectionTest() {
    let (client, session): (LibboxCommandClient?, LibboxConnectionTestSession?) = locked {
      connectionTestGeneration += 1
      let current = (connectionTestClient, connectionTestSession)
      connectionTestClient = nil
      connectionTestSession = nil
      connectionTestHandler = nil
      return current
    }
    session?.cancel()
    disconnect(client)
  }

  private func ensurePingClient() -> LibboxCommandClient? {
    lock.lock()
    defer { lock.unlock() }
    if let pingClient { return pingClient }
    guard tunnelAlive else { return nil }
    guard let client = LibboxNewCommandClient(pingHandler, LibboxCommandClientOptions()) else { return nil }
    do {
      try client.connect()
      pingClient = client
      return client
    } catch {
      NSLog("[core] ping client failed: %@", error.localizedDescription)
      return nil
    }
  }

  func cancelPing() {
    let client: LibboxCommandClient? = locked {
      let current = pingClient
      pingClient = nil
      return current
    }
    disconnect(client)
  }

  func urlTestOutbound(tag: String, link: String, timeoutMs: Int32) -> [String: Any] {
    guard let client = ensurePingClient() else {
      return ["delay": 0, "error": "command client not connected"]
    }
    do {
      let result = try client.urlTestOutbound(tag, link: link, timeout: timeoutMs)
      return ["delay": result.delay, "error": result.error]
    } catch {
      return ["delay": 0, "error": error.localizedDescription]
    }
  }

  func urlTestGroup(tag: String) -> Bool {
    run { try $0.urlTest(tag) }
  }

  func selectOutbound(group: String, tag: String) -> Bool {
    run { try $0.selectOutbound(group, outboundTag: tag) }
  }

  func closeConnection(id: String) -> Bool {
    run { try $0.closeConnection(id) }
  }

  func closeConnections() -> Bool {
    run { try $0.closeConnections() }
  }

  private func run(_ action: (LibboxCommandClient) throws -> Void) -> Bool {
    guard let client = ensurePingClient() else { return false }
    do {
      try action(client)
      return true
    } catch {
      NSLog("[core] rpc failed: %@", error.localizedDescription)
      return false
    }
  }

  func getGroups() -> [[String: Any]]? {
    guard let client = ensurePingClient(), let iterator = try? client.getGroups() else { return nil }
    var groups: [[String: Any]] = []
    while iterator.hasNext() {
      if let group = iterator.next() {
        groups.append(Self.serialize(group))
      }
    }
    return groups
  }

  func getOutbounds() -> [[String: Any]]? {
    guard let client = ensurePingClient(), let iterator = try? client.getOutbounds() else { return nil }
    var items: [[String: Any]] = []
    while iterator.hasNext() {
      guard let item = iterator.next() else { continue }
      var map = Self.serialize(item)
      map["endpointState"] = item.endpointState
      map["idleSinceSeconds"] = item.idleSinceSeconds
      items.append(map)
    }
    return items
  }

  func getRunningConfig() -> String? {
    guard let client = ensurePingClient(), let config = try? client.getRunningConfig() else { return nil }
    let content = config.content()
    return content.isEmpty ? nil : content
  }

  func getUrlViaOutbound(tag: String, link: String, timeoutMs: Int32, maxBytes: Int32, userAgent: String) -> [String: Any] {
    guard let client = ensurePingClient() else {
      return ["error": "command client not connected"]
    }
    return Self.getUrl(client, tag: tag, link: link, timeoutMs: timeoutMs, maxBytes: maxBytes, userAgent: userAgent)
  }

  static func getUrl(_ client: LibboxCommandClient, tag: String, link: String, timeoutMs: Int32, maxBytes: Int32, userAgent: String) -> [String: Any] {
    let headers = userAgent.isEmpty ? nil : LibboxNewHTTPHeaders()
    headers?.add("User-Agent", value: userAgent)
    do {
      let result = try client.getURLViaOutbound(tag, link: link, timeout: timeoutMs, maxBytes: maxBytes, headers: headers)
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

  func getRules() -> [[String: Any]]? {
    guard let client = ensurePingClient(), let iterator = try? client.getRules() else { return nil }
    var rules: [[String: Any]] = []
    while iterator.hasNext() {
      if let rule = iterator.next() {
        rules.append(["type": rule.type, "payload": rule.payload, "action": rule.action, "isDNS": rule.isDNS])
      }
    }
    return rules
  }

  func getDnsGroups() -> [[String: Any]]? {
    guard let client = ensurePingClient(), let iterator = try? client.getDNSGroups() else { return nil }
    var groups: [[String: Any]] = []
    while iterator.hasNext() {
      if let group = iterator.next() {
        groups.append(["tag": group.tag, "mode": group.mode, "current": group.current, "members": Self.members(group.members())])
      }
    }
    return groups
  }

  private static func members(_ iterator: LibboxDnsGroupMemberIteratorProtocol?) -> [[String: Any]] {
    guard let iterator else { return [] }
    var members: [[String: Any]] = []
    while iterator.hasNext() {
      guard let member = iterator.next() else { continue }
      members.append([
        "tag": member.tag,
        "serverType": member.serverType,
        "clean": member.clean,
        "liveErrors": member.liveErrors,
        "lastErrorAgeMs": member.lastErrorAgeMs,
        "liveWins": member.liveWins,
        "current": member.current,
        "lastRttMs": member.lastRTTMs,
      ])
    }
    return members
  }

  func getPool(tag: String) -> [[String: Any]]? {
    guard let client = ensurePingClient(), let iterator = try? client.getPool(tag) else { return nil }
    var slots: [[String: Any]] = []
    while iterator.hasNext() {
      if let slot = iterator.next() {
        slots.append(["slot": slot.slot, "tag": slot.tag, "delay": slot.delay])
      }
    }
    return slots
  }

  func setEndpointEnabled(tag: String, enabled: Bool) -> [String: String] {
    guard let client = ensurePingClient() else {
      return ["error": "error", "message": "no command client"]
    }
    do {
      return ["state": try client.setEndpointEnabled(tag, enabled: enabled).state]
    } catch {
      let message = error.localizedDescription
      return ["error": Self.endpointErrorCode(message), "message": message]
    }
  }

  func getWireGuardStatus(tag: String) -> [String: Any] {
    guard let client = ensurePingClient() else {
      return ["error": "error", "message": "no command client"]
    }
    do {
      let status = try client.getWireGuardStatus(tag)
      return [
        "endpoint_state": status.endpointState,
        "idle_since_seconds": status.idleSinceSeconds,
        "peers": Self.peers(status.peers()),
      ]
    } catch {
      let message = error.localizedDescription
      let code = message.contains("code = Unimplemented") ? "unimplemented" : Self.endpointErrorCode(message)
      return ["error": code, "message": message]
    }
  }

  private static func peers(_ iterator: LibboxPeerStatusIteratorProtocol?) -> [[String: Any]] {
    guard let iterator else { return [] }
    var peers: [[String: Any]] = []
    while iterator.hasNext() {
      guard let peer = iterator.next() else { continue }
      peers.append([
        "public_key": peer.publicKey,
        "endpoint": peer.endpoint,
        "last_handshake_unix": peer.lastHandshakeUnix,
        "rx_bytes": peer.rxBytes,
        "tx_bytes": peer.txBytes,
        "session_rx_bytes": peer.sessionRxBytes,
        "session_tx_bytes": peer.sessionTxBytes,
      ])
    }
    return peers
  }

  private static func endpointErrorCode(_ message: String) -> String {
    guard let range = message.range(of: #"code = \w+"#, options: .regularExpression) else { return "error" }
    return endpointErrorCodes[String(message[range].dropFirst("code = ".count))] ?? "error"
  }

  private func emitStatus(_ message: LibboxStatusMessage, _ generation: Int) {
    guard locked({ generation == statusGeneration }) else { return }
    statusEmitter.offer([
      "uplink": message.uplink,
      "downlink": message.downlink,
      "uplinkTotal": message.uplinkTotal,
      "downlinkTotal": message.downlinkTotal,
      "memory": message.memory,
      "memoryRuntime": message.memoryRuntime,
      "goroutines": message.goroutines,
      "connectionsIn": message.connectionsIn,
      "connectionsOut": message.connectionsOut,
    ] as [String: Any])
  }

  private func emitOutbounds(_ iterator: LibboxOutboundGroupItemIteratorProtocol, _ generation: Int) {
    guard locked({ generation == screenGeneration }) else { return }
    var items: [[String: Any]] = []
    while iterator.hasNext() {
      if let item = iterator.next() {
        items.append(Self.serialize(item))
      }
    }
    outboundsEmitter.offer(items)
  }

  private func emitGroups(_ iterator: LibboxOutboundGroupIteratorProtocol, _ generation: Int) {
    guard locked({ generation == screenGeneration }) else { return }
    var groups: [[String: Any]] = []
    while iterator.hasNext() {
      if let group = iterator.next() {
        groups.append(Self.serialize(group))
      }
    }
    groupsEmitter.offer(groups)
  }

  private func applyConnectionEvents(_ events: LibboxConnectionEvents, _ generation: Int) {
    guard locked({ generation == screenGeneration }) else { return }
    connectionsLock.lock()
    defer { connectionsLock.unlock() }
    guard let connections else { return }
    connections.apply(events)
    connections.filterState(Int32(LibboxConnectionStateAll))
    connectionsEmitter.offer(Self.serialize(connections))
  }

  private func applyProfilerConnectionEvents(_ events: LibboxConnectionEvents, _ generation: Int) {
    guard locked({ generation == profilerGeneration }) else { return }
    connectionsLock.lock()
    defer { connectionsLock.unlock() }
    guard let profilerConnections else { return }
    profilerConnections.apply(events)
    profilerConnections.filterState(Int32(LibboxConnectionStateAll))
    connectionsEmitter.offer(Self.serialize(profilerConnections))
  }

  private func emitDnsQuery(_ query: LibboxDnsQuery) {
    var answers: [[String: Any]] = []
    if let iterator = query.answers() {
      while iterator.hasNext() {
        if let answer = iterator.next() {
          answers.append(["name": answer.name, "type": answer.type, "rdata": answer.rData, "ttl": answer.ttl])
        }
      }
    }
    var attempts: [[String: Any]] = []
    if let iterator = query.attempts() {
      while iterator.hasNext() {
        if let attempt = iterator.next() {
          attempts.append([
            "server": attempt.server,
            "serverType": attempt.serverType,
            "outcome": attempt.outcome,
            "rttMs": attempt.rttMs,
          ])
        }
      }
    }
    dnsQueriesEmitter.offer([
      "domain": query.domain,
      "queryType": query.queryType,
      "rcode": query.rcode,
      "ttl": query.ttl,
      "source": query.source,
      "failed": query.failed,
      "error": query.error,
      "packageName": Self.strings(query.processInfo?.packageNames()).first ?? "",
      "processPath": query.processInfo?.processPath ?? "",
      "dnsServer": query.dnsServer,
      "dnsServerType": query.dnsServerType,
      "outbound": Self.strings(query.outbound()).filter { !$0.isEmpty },
      "answers": answers,
      "groupPath": Self.strings(query.groupPath()).filter { !$0.isEmpty },
      "attempts": attempts,
      "fanned": query.fanned,
      "survival": query.survival,
    ] as [String: Any])
  }

  func reEmitConnections() {
    connectionsLock.lock()
    defer { connectionsLock.unlock() }
    guard let connections else { return }
    connectionsEmitter.offer(Self.serialize(connections))
  }

  private static func serialize(_ item: LibboxOutboundGroupItem) -> [String: Any] {
    [
      "tag": item.tag,
      "type": item.type,
      "urlTestDelay": item.urlTestDelay,
      "urlTestTime": item.urlTestTime,
    ]
  }

  private static func serialize(_ group: LibboxOutboundGroup) -> [String: Any] {
    var items: [[String: Any]] = []
    if let iterator = group.getItems() {
      while iterator.hasNext() {
        if let item = iterator.next() {
          items.append(serialize(item))
        }
      }
    }
    return [
      "tag": group.tag,
      "type": group.type,
      "selectable": group.selectable,
      "selected": group.selected,
      "isExpand": group.isExpand,
      "items": items,
    ]
  }

  private static func serialize(_ connections: LibboxConnections) -> [[String: Any]] {
    var list: [[String: Any]] = []
    guard let iterator = connections.iterator() else { return list }
    while iterator.hasNext() {
      guard let connection = iterator.next() else { continue }
      list.append([
        "id": connection.id_,
        "network": connection.network,
        "domain": connection.domain,
        "destination": connection.destination,
        "source": connection.source,
        "inbound": connection.inbound,
        "inboundType": connection.inboundType,
        "rule": connection.rule,
        "uplink": connection.uplinkTotal,
        "downlink": connection.downlinkTotal,
        "uplinkDelta": connection.uplink,
        "downlinkDelta": connection.downlink,
        "outbound": connection.outbound,
        "outboundType": connection.outboundType,
        "protocol": connection.protocol,
        "chains": strings(connection.chain()),
        "detours": strings(connection.detour()),
        "packageName": strings(connection.processInfo?.packageNames()).first ?? "",
        "processPath": connection.processInfo?.processPath ?? "",
        "createdAt": connection.createdAt,
        "closedAt": connection.closedAt,
      ])
    }
    return list
  }

  private static func strings(_ iterator: LibboxStringIteratorProtocol?) -> [String] {
    guard let iterator else { return [] }
    var values: [String] = []
    while iterator.hasNext() {
      values.append(iterator.next())
    }
    return values
  }
}

final class SnapshotEmitter {
  let sink = ChannelSink()
  private let lock = NSLock()
  private var pending: Any?
  private var scheduled = false

  func offer(_ snapshot: Any) {
    lock.lock()
    pending = snapshot
    let schedule = !scheduled
    scheduled = true
    lock.unlock()
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      lock.lock()
      let latest = pending
      pending = nil
      scheduled = false
      lock.unlock()
      if let latest {
        sink.send(latest)
      }
    }
  }
}

final class BatchEmitter {
  private static let queueMax = 4096

  let sink = ChannelSink()
  private let lock = NSLock()
  private var queue: [Any] = []
  private var scheduled = false

  func offer(_ event: Any) {
    lock.lock()
    if queue.count < Self.queueMax {
      queue.append(event)
    }
    let schedule = !scheduled
    scheduled = true
    lock.unlock()
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      lock.lock()
      let batch = queue
      queue = []
      scheduled = false
      lock.unlock()
      if !batch.isEmpty {
        sink.send(batch)
      }
    }
  }
}

final class ConnectionTestHandler: NSObject, LibboxConnectionTestHandlerProtocol {
  private let emit: ([String: Any]) -> Void

  init(emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
  }

  func onStage(_ stage: LibboxConnectionTestStage?) {
    guard let stage else { return }
    emit([
      "event": "stage",
      "id": stage.id_(),
      "parent": stage.parent(),
      "kind": stage.kind(),
      "subject": stage.subject(),
      "start_ms": stage.startMs(),
      "duration_ms": stage.durationMs(),
      "result": stage.result(),
      "error": stage.errorMessage(),
      "attrs": Self.attributes(stage.attrs()),
    ])
  }

  func onResult(_ result: LibboxConnectionTestResult?) {
    guard let result else { return }
    emit([
      "event": "result",
      "error": result.errorMessage(),
      "root_cause": result.rootCause(),
      "findings": Self.findings(result.findings()),
      "http_status": result.httpStatus(),
      "content_type": result.contentType(),
      "body_bytes": result.body()?.count ?? 0,
      "truncated": result.truncated(),
      "elapsed_ms": result.elapsedMs(),
      "stages_truncated": result.stagesTruncated(),
    ])
  }

  func onError(_ message: String?) {
    emit(["event": "error", "message": message ?? "failed"])
  }

  private static func attributes(_ iterator: LibboxConnectionTestAttrIteratorProtocol?) -> [[String: String]] {
    guard let iterator else { return [] }
    var attributes: [[String: String]] = []
    while iterator.hasNext() {
      if let attribute = iterator.next() {
        attributes.append(["key": attribute.key(), "value": attribute.value()])
      }
    }
    return attributes
  }

  private static func findings(_ iterator: LibboxConnectionTestFindingIteratorProtocol?) -> [[String: Any]] {
    guard let iterator else { return [] }
    var findings: [[String: Any]] = []
    while iterator.hasNext() {
      guard let finding = iterator.next() else { continue }
      findings.append([
        "code": finding.code(),
        "level": finding.level(),
        "stages": stages(finding.stages()),
        "attrs": attributes(finding.attrs()),
      ])
    }
    return findings
  }

  private static func stages(_ iterator: LibboxInt32IteratorProtocol?) -> [Int32] {
    guard let iterator else { return [] }
    var stages: [Int32] = []
    while iterator.hasNext() {
      stages.append(iterator.next())
    }
    return stages
  }
}

final class ClientHandler: NSObject, LibboxCommandClientHandlerProtocol {
  var onDisconnected: (() -> Void)?
  var onStatus: ((LibboxStatusMessage) -> Void)?
  var onOutbounds: ((LibboxOutboundGroupItemIteratorProtocol) -> Void)?
  var onGroups: ((LibboxOutboundGroupIteratorProtocol) -> Void)?
  var onConnectionEvents: ((LibboxConnectionEvents) -> Void)?
  var onDnsQuery: ((LibboxDnsQuery) -> Void)?

  func connected() {}
  func disconnected(_: String?) { onDisconnected?() }
  func setDefaultLogLevel(_: Int32) {}
  func clearLogs() {}
  func writeLogs(_: (any LibboxLogIteratorProtocol)?) {}
  func writeStatus(_ message: LibboxStatusMessage?) {
    if let message { onStatus?(message) }
  }
  func writeGroups(_ groups: (any LibboxOutboundGroupIteratorProtocol)?) {
    if let groups { onGroups?(groups) }
  }
  func writeOutbounds(_ outbounds: (any LibboxOutboundGroupItemIteratorProtocol)?) {
    if let outbounds { onOutbounds?(outbounds) }
  }
  func initializeClashMode(_: (any LibboxStringIteratorProtocol)?, currentMode _: String?) {}
  func updateClashMode(_: String?) {}
  func write(_ events: LibboxConnectionEvents?) {
    if let events { onConnectionEvents?(events) }
  }
  func write(_ query: LibboxDnsQuery?) {
    if let query { onDnsQuery?(query) }
  }
}
