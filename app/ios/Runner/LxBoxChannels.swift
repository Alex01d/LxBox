import Flutter
import Foundation

/// §708 — iOS side of the channel contract in `PlatformChannels`, only what app startup calls.
/// There is no tunnel and no core yet, so the status is always `Stopped`. Every other method
/// answers `FlutterMethodNotImplemented`, so missing native work stays visible in AppLog.
final class LxBoxChannels {
  private static let configFileName = "singbox_config.json"
  private static let prefsPrefix = "lxbox.native_prefs."

  /// Defaults match `docs/STORAGE.md`: native-to-JSON seeding runs once, so a wrong answer sticks.
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

  private let defaults = UserDefaults.standard
  private let silentStream = SilentStream()
  private var channels: [NSObject] = []

  private lazy var filesDirectory: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = support.appendingPathComponent("lxbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }()

  private var configFile: URL {
    filesDirectory.appendingPathComponent(Self.configFileName)
  }

  init(messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: "com.leadaxe.lxbox/methods", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handleMethods(call, result)
    }
    let utils = FlutterMethodChannel(name: "com.leadaxe.lxbox/utils", binaryMessenger: messenger)
    utils.setMethodCallHandler { [weak self] call, result in
      self?.handleUtils(call, result)
    }
    channels = [methods, utils]
    for name in ["com.leadaxe.lxbox/status_events", "lxbox/coreLog", "lxbox/cc/openconnect"] {
      let channel = FlutterEventChannel(name: name, binaryMessenger: messenger)
      channel.setStreamHandler(silentStream)
      channels.append(channel)
    }
  }

  private func handleMethods(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    if let getter = Self.boolGetters[call.method] {
      result(defaults.object(forKey: Self.prefsPrefix + getter.key) as? Bool ?? getter.fallback)
      return
    }
    if let key = Self.boolSetters[call.method] {
      defaults.set(arguments?["enabled"] as? Bool ?? false, forKey: Self.prefsPrefix + key)
      result(true)
      return
    }
    switch call.method {
    case "getFilesDir":
      result(filesDirectory.path)
    case "saveConfig":
      result(saveConfig(arguments?["config"] as? String ?? ""))
    case "getConfig":
      result((try? String(contentsOf: configFile, encoding: .utf8)) ?? "{}")
    case "getVpnStatus":
      result(["status": "Stopped", "revoked": false])
    case "getCoreVersion":
      result("")
    case "getBackgroundMode":
      result(defaults.string(forKey: Self.prefsPrefix + "background_mode") ?? "never")
    case "setBackgroundMode":
      defaults.set(arguments?["mode"] as? String ?? "never", forKey: Self.prefsPrefix + "background_mode")
      result(true)
    case "getMemoryLimit":
      result(defaults.string(forKey: Self.prefsPrefix + "memory_limit") ?? "auto")
    case "setMemoryLimit":
      defaults.set(arguments?["value"] as? String ?? "auto", forKey: Self.prefsPrefix + "memory_limit")
      result(true)
    case "setHasTun", "setAppLanguage", "setAutomationEnabled":
      result(true)
    case "getAppLanguageState":
      result(["supported": false])
    case "isIgnoringBatteryOptimizations":
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

  private func saveConfig(_ config: String) -> Bool {
    do {
      try Data(config.utf8).write(to: configFile, options: .atomic)
      return true
    } catch {
      return false
    }
  }
}

/// No tunnel means no status transitions and no core logs, so these streams never emit.
private final class SilentStream: NSObject, FlutterStreamHandler {
  func onListen(withArguments _: Any?, eventSink _: @escaping FlutterEventSink) -> FlutterError? {
    nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    nil
  }
}
