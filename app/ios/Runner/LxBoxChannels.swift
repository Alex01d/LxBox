import Flutter
import Foundation
import Libbox
import UIKit

final class LxBoxChannels {
  private static let boolGetters: [String: (key: String, fallback: Bool)] = [
    "getAutoStart": ("auto_start", false),
    "getKeepOnExit": ("keep_on_exit", true),
    "getCoreLogsEnabled": ("core_logs_enabled", false),
    "getCoreLogsVerbose": ("core_logs_verbose", false),
    "getAllowBypass": ("allow_bypass", false),
    "getAutoRedirect": ("auto_redirect", false),
  ]
  private static let boolSetters: [String: String] = [
    "setAutoStart": "auto_start",
    "setKeepOnExit": "keep_on_exit",
    "setCoreLogsEnabled": "core_logs_enabled",
    "setCoreLogsVerbose": "core_logs_verbose",
    "setAllowBypass": "allow_bypass",
    "setAutoRedirect": "auto_redirect",
  ]

  private let client = CoreCommandClient()
  private let service: CoreService
  private let silentStream = ChannelSink()
  private var channels: [NSObject] = []

  init(messenger: FlutterBinaryMessenger) {
    CoreRuntime.setup()
    service = CoreService(client: client)

    let methods = FlutterMethodChannel(name: "com.leadaxe.lxbox/methods", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handleMethods(call, result)
    }
    let utils = FlutterMethodChannel(name: "com.leadaxe.lxbox/utils", binaryMessenger: messenger)
    utils.setMethodCallHandler { [weak self] call, result in
      self?.handleUtils(call, result)
    }
    channels = [methods, utils]

    client.connectionsEmitter.sink.onListened = { [weak self] in
      DispatchQueue.global(qos: .userInitiated).async { self?.client.reEmitConnections() }
    }
    addEventChannel("com.leadaxe.lxbox/status_events", service.statusSink, messenger)
    addEventChannel("lxbox/coreLog", service.logSink, messenger)
    addEventChannel("lxbox/cc/status", client.statusEmitter.sink, messenger)
    addEventChannel("lxbox/cc/outbounds", client.outboundsEmitter.sink, messenger)
    addEventChannel("lxbox/cc/groups", client.groupsEmitter.sink, messenger)
    addEventChannel("lxbox/cc/connections", client.connectionsEmitter.sink, messenger)
    addEventChannel("lxbox/cc/dns", client.dnsQueriesEmitter.sink, messenger)
    addEventChannel("lxbox/cc/connection_test", client.connectionTestEmitter.sink, messenger)
    addEventChannel("lxbox/cc/openconnect", silentStream, messenger)
  }

  private func addEventChannel(_ name: String, _ handler: FlutterStreamHandler & NSObjectProtocol, _ messenger: FlutterBinaryMessenger) {
    let channel = FlutterEventChannel(name: name, binaryMessenger: messenger)
    channel.setStreamHandler(handler)
    channels.append(channel)
  }

  private func handleMethods(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    if let getter = Self.boolGetters[call.method] {
      result(NativePrefs.bool(getter.key, fallback: getter.fallback))
      return
    }
    if let key = Self.boolSetters[call.method] {
      let enabled = arguments?["enabled"] as? Bool ?? false
      NativePrefs.set(enabled, for: key)
      if call.method == "setCoreLogsVerbose" {
        service.setVerboseLogs(enabled)
      }
      result(true)
      return
    }
    switch call.method {
    case "getFilesDir":
      result(CoreRuntime.filesDirectory.path)
    case "saveConfig":
      result(saveConfig(arguments?["config"] as? String ?? ""))
    case "getConfig":
      result((try? String(contentsOf: CoreRuntime.configFile, encoding: .utf8)) ?? "{}")
    case "checkConfig":
      let text = arguments?["config"] as? String ?? ""
      respondOffMain(result) { Self.checkConfig(text) }
    case "formatConfig":
      let text = arguments?["config"] as? String ?? ""
      respondOffMain(result) { Self.formatConfig(text) }

    case "startVPN":
      service.start()
      result(true)
    case "stopVPN":
      service.stop(result)
    case "forceStopVPN":
      service.forceStop()
      result(true)
    case "reloadVPN":
      service.reload()
      result(true)
    case "resetNetwork":
      service.resetNetwork()
      result(true)
    case "clearDnsCache":
      service.clearDnsCache()
      result(true)
    case "getVpnStatus":
      result(["status": service.status.rawValue, "revoked": false])
    case "getTunnelUptimeMs":
      result(service.uptimeMs)
    case "getCoreVersion":
      result(LibboxVersion())
    case "getMemoryInfo":
      result(Self.memoryInfo())

    case "getBackgroundMode":
      result(NativePrefs.string("background_mode", fallback: "never"))
    case "setBackgroundMode":
      NativePrefs.set(arguments?["mode"] as? String ?? "never", for: "background_mode")
      result(true)
    case "getMemoryLimit":
      result(NativePrefs.string("memory_limit", fallback: "auto"))
    case "setMemoryLimit":
      NativePrefs.set(arguments?["value"] as? String ?? "auto", for: "memory_limit")
      CoreRuntime.reloadMemoryLimit()
      result(true)

    case "ccResyncForReopen":
      client.resyncForReopen()
      result(true)
    case "ccConnectScreen":
      client.connectScreenRef()
      result(true)
    case "ccDisconnectScreen":
      client.disconnectScreenRef()
      result(true)
    case "ccConnectProfiler":
      client.connectProfiler()
      result(true)
    case "ccDisconnectProfiler":
      client.disconnectProfiler()
      result(true)
    case "ccStartConnectionTest":
      let link = arguments?["link"] as? String ?? ""
      let packageName = arguments?["package_name"] as? String ?? ""
      let depth = Int32(arguments?["depth"] as? Int ?? 0)
      let fresh = arguments?["fresh"] as? Bool ?? false
      let alive = client.isAlive
      if alive {
        client.startConnectionTest(link: link, packageName: packageName, depth: depth, fresh: fresh)
      }
      result(alive)
    case "ccStopConnectionTest":
      client.stopConnectionTest()
      result(true)
    case "ccPauseClients":
      client.pauseClients()
      result(true)
    case "ccResumeClients":
      client.resumeClients()
      result(true)
    case "ccSetStatusFast":
      client.setStatusFast(arguments?["fast"] as? Bool ?? false)
      result(true)
    case "ccCancelPing":
      respondOffMain(result) { [client] in
        client.cancelPing()
        return true
      }
    case "ccGetGroups":
      respondOffMain(result) { [client] in client.isAlive ? client.getGroups() : nil }
    case "ccGetOutbounds":
      respondOffMain(result) { [client] in client.isAlive ? client.getOutbounds() : nil }
    case "ccGetRunningConfig":
      respondOffMain(result) { [client] in client.isAlive ? client.getRunningConfig() : nil }
    case "ccSelectOutbound":
      let group = arguments?["group"] as? String ?? ""
      let tag = arguments?["tag"] as? String ?? ""
      respondOffMain(result) { [client] in client.selectOutbound(group: group, tag: tag) }
    case "ccUrlTestOutbound":
      let tag = arguments?["tag"] as? String ?? ""
      let link = arguments?["link"] as? String ?? ""
      let timeoutMs = Int32(arguments?["timeoutMs"] as? Int ?? 0)
      respondOffMain(result) { [client] in client.urlTestOutbound(tag: tag, link: link, timeoutMs: timeoutMs) }
    case "ccUrlTestGroup":
      let tag = arguments?["tag"] as? String ?? ""
      respondOffMain(result) { [client] in client.urlTestGroup(tag: tag) }
    case "ccCloseConnection":
      let id = arguments?["id"] as? String ?? ""
      respondOffMain(result) { [client] in client.closeConnection(id: id) }
    case "ccCloseConnections":
      respondOffMain(result) { [client] in client.closeConnections() }

    case "probeStart":
      service.startProbe(config: arguments?["config"] as? String ?? "", result)
    case "probeUrlTest":
      let runId = arguments?["runId"] as? Int ?? 0
      let tag = arguments?["tag"] as? String ?? ""
      let link = arguments?["link"] as? String ?? ""
      let timeoutMs = Int32(arguments?["timeoutMs"] as? Int ?? 0)
      respondOffMain(result) { [probe = service.probe] in
        probe.urlTest(runId: runId, tag: tag, link: link, timeoutMs: timeoutMs)
      }
    case "probeGetUrl":
      let runId = arguments?["runId"] as? Int ?? 0
      let tag = arguments?["tag"] as? String ?? ""
      let link = arguments?["link"] as? String ?? ""
      let timeoutMs = Int32(arguments?["timeoutMs"] as? Int ?? 0)
      let maxBytes = Int32(arguments?["maxBytes"] as? Int ?? 0)
      let userAgent = arguments?["userAgent"] as? String ?? ""
      respondOffMain(result) { [probe = service.probe] in
        probe.getUrl(runId: runId, tag: tag, link: link, timeoutMs: timeoutMs, maxBytes: maxBytes, userAgent: userAgent)
      }
    case "probeCancel":
      let runId = arguments?["runId"] as? Int ?? 0
      respondOffMain(result) { [probe = service.probe] in
        probe.cancel(runId: runId)
        return nil
      }
    case "probeStop":
      service.stopProbe(runId: arguments?["runId"] as? Int ?? 0, result)

    case "setHasTun", "setAppLanguage", "setAutomationEnabled", "setAutomationActiveState",
      "setNotificationTitle", "setNotificationText":
      result(true)
    case "isForeignVpnActive", "getCurrentSessionAllowBypass":
      result(false)
    case "getAppLanguageState":
      result(["supported": false])
    case "isIgnoringBatteryOptimizations", "areNotificationsEnabled":
      result(true)
    case "requestAddTile":
      result("unsupported")
    case "ccGetOpenConnectStatus", "ccTakeOpenConnectOpenRequest", "ccTakeTaildropOpenRequest":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleUtils(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "openUrl":
      openUrl(call.arguments as? [String: Any], result)
    case "installSource":
      result(nil)
    case "isTelevision":
      result(false)
    case "checkNotificationPermission":
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func openUrl(_ arguments: [String: Any]?, _ result: @escaping FlutterResult) {
    guard let url = arguments?["url"] as? String else {
      result(FlutterError(code: "INVALID_URL", message: "URL is null", details: nil))
      return
    }
    let fallback = arguments?["fallbackUrl"] as? String
    open(url) { [weak self] opened in
      if opened {
        result(nil)
      } else if let fallback {
        self?.open(fallback) { opened in
          result(opened ? nil : Self.noHandlerError(url))
        }
      } else {
        result(Self.noHandlerError(url))
      }
    }
  }

  private func open(_ link: String, _ completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: link) else {
      completion(false)
      return
    }
    UIApplication.shared.open(url, options: [:], completionHandler: completion)
  }

  private static func noHandlerError(_ url: String) -> FlutterError {
    FlutterError(code: "NO_ACTIVITY", message: "No handler for \(url)", details: nil)
  }

  private func respondOffMain(_ result: @escaping FlutterResult, _ work: @escaping () -> Any?) {
    DispatchQueue.global(qos: .userInitiated).async {
      let value = work()
      DispatchQueue.main.async { result(value) }
    }
  }

  private func saveConfig(_ config: String) -> Bool {
    do {
      try Data(config.utf8).write(to: CoreRuntime.configFile, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func checkConfig(_ text: String) -> [String: Any] {
    var error: NSError?
    LibboxCheckConfig(text, &error)
    if let error {
      return ["ok": false, "error": error.localizedDescription]
    }
    return ["ok": true]
  }

  private static func formatConfig(_ text: String) -> String? {
    guard !text.isEmpty else { return nil }
    var error: NSError?
    return LibboxFormatConfig(text, &error)?.value
  }

  private static func memoryInfo() -> [String: Any] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return ["totalPss": status == KERN_SUCCESS ? Int(info.phys_footprint) : 0]
  }
}
