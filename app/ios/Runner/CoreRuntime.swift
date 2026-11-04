import Foundation
import Libbox

enum CoreHost {
  case app
  case tunnel

  fileprivate var crashReportSource: String {
    switch self {
    case .app: return "lxbox-app"
    case .tunnel: return "lxbox"
    }
  }
}

enum CoreRuntime {
  static let appGroupId = "group.com.gglprojects.lxbox"

  private static let configFileName = "singbox_config.json"
  private static let cacheDbName = "cache.db"
  private static let memoryLimitPresetsMb: Set<Int64> = [200, 384, 512, 768]

  private static let ready = DispatchGroup()
  private(set) static var setupError: String?

  static let appGroupDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)

  private static let sandboxLibrary = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
  private static let sharedLibrary = appGroupDirectory?.appendingPathComponent("Library", isDirectory: true) ?? sandboxLibrary

  static let filesDirectory = makeDirectory(sharedLibrary.appendingPathComponent("Application Support/lxbox", isDirectory: true))

  private static func makeDirectory(_ directory: URL) -> URL {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func tempDirectory(_ host: CoreHost) -> URL {
    let library = host == .app ? sandboxLibrary : sharedLibrary
    return makeDirectory(library.appendingPathComponent("Caches/lxbox-core", isDirectory: true))
  }

  static var configFile: URL {
    filesDirectory.appendingPathComponent(configFileName)
  }

  static func setup() {
    dropConfigIfContainerMoved()
    ready.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { ready.leave() }
      recoverAfterCrash(.app)
      var error: NSError?
      LibboxSetup(setupOptions(.app), &error)
      if let error {
        setupError = error.localizedDescription
        NSLog("[core] setup failed: %@", error.localizedDescription)
      }
    }
  }

  static func setupTunnel() throws {
    recoverAfterCrash(.tunnel)
    var error: NSError?
    LibboxSetup(setupOptions(.tunnel), &error)
    if let error { throw error }
  }

  static func waitUntilReady() {
    ready.wait()
  }

  private static func dropConfigIfContainerMoved() {
    let key = "lxbox.container_home"
    let home = filesDirectory.path
    guard UserDefaults.standard.string(forKey: key) != home else { return }
    try? FileManager.default.removeItem(at: configFile)
    UserDefaults.standard.set(home, forKey: key)
  }

  static func reloadMemoryLimit() {
    DispatchQueue.global(qos: .utility).async {
      waitUntilReady()
      let options = LibboxSetupOptions()
      options.oomKillerEnabled = true
      options.oomMemoryLimit = memoryLimitBytes()
      options.oomMemoryLimitHeap = true
      LibboxReloadSetupOptions(options)
    }
  }

  static func deleteCacheDb() {
    try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(cacheDbName))
  }

  private static func setupOptions(_ host: CoreHost) -> LibboxSetupOptions {
    let options = LibboxSetupOptions()
    options.basePath = appGroupDirectory?.path ?? FileManager.default.temporaryDirectory.path
    options.workingPath = filesDirectory.path
    options.tempPath = tempDirectory(host).path
    #if targetEnvironment(simulator)
      options.commandServerListenPort = 54345
      options.commandServerSecret = UUID().uuidString
    #endif
    options.logMaxLines = 3000
    options.debug = NativePrefs.bool("core_logs_enabled", fallback: false)
    options.crashReportSource = host.crashReportSource
    options.oomKillerEnabled = true
    options.oomMemoryLimit = host == .app ? memoryLimitBytes() : 0
    options.oomMemoryLimitHeap = host == .app
    return options
  }

  private static func memoryLimitBytes() -> Int64 {
    guard let mb = Int64(NativePrefs.string("memory_limit", fallback: "auto")),
      memoryLimitPresetsMb.contains(mb)
    else { return 0 }
    return mb * 1024 * 1024
  }

  private static func recoverAfterCrash(_ host: CoreHost) {
    let report = filesDirectory.appendingPathComponent("CrashReport-\(host.crashReportSource).log")
    let size = (try? FileManager.default.attributesOfItem(atPath: report.path)[.size] as? Int) ?? 0
    guard size > 0 else { return }
    NSLog("[core] §334 previous launch crashed, resetting core caches")
    deleteCacheDb()
    let temp = tempDirectory(host)
    let entries = (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
    for entry in entries {
      try? FileManager.default.removeItem(at: entry)
    }
  }

  static func memoryInfo() -> [String: Any] {
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

enum NativePrefs {
  private static let prefix = "lxbox.native_prefs."
  private static let defaults = UserDefaults(suiteName: CoreRuntime.appGroupId) ?? .standard

  static func bool(_ key: String, fallback: Bool) -> Bool {
    defaults.object(forKey: prefix + key) as? Bool ?? fallback
  }

  static func string(_ key: String, fallback: String) -> String {
    defaults.string(forKey: prefix + key) ?? fallback
  }

  static func set(_ value: Any, for key: String) {
    defaults.set(value, forKey: prefix + key)
  }
}

enum TunnelMessage: String {
  case reload
  case resetNetwork
  case clearDnsCache
  case memoryInfo
}

struct TunnelStopRecord: Codable {
  var reason: Int?
  var error: String?
  var coreError: String?

  private static var file: URL {
    CoreRuntime.filesDirectory.appendingPathComponent("tunnel_stop.json")
  }

  static func read() -> TunnelStopRecord? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(TunnelStopRecord.self, from: data)
  }

  static func take() -> TunnelStopRecord? {
    let record = read()
    try? FileManager.default.removeItem(at: file)
    return record
  }

  func write() {
    guard let data = try? JSONEncoder().encode(self) else { return }
    try? data.write(to: Self.file, options: .atomic)
  }
}
