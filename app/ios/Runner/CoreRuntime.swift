import Foundation
import Libbox

enum CoreRuntime {
  private static let configFileName = "singbox_config.json"
  private static let crashReportName = "CrashReport-lxbox.log"
  private static let cacheDbName = "cache.db"
  private static let memoryLimitPresetsMb: Set<Int64> = [200, 384, 512, 768]

  private static let ready = DispatchGroup()
  private(set) static var setupError: String?

  static let filesDirectory: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = support.appendingPathComponent("lxbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }()

  private static let coreTempDirectory: URL = {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let directory = caches.appendingPathComponent("lxbox-core", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }()

  static var configFile: URL {
    filesDirectory.appendingPathComponent(configFileName)
  }

  static func setup() {
    dropConfigIfContainerMoved()
    ready.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { ready.leave() }
      recoverAfterCrash()
      var error: NSError?
      LibboxSetup(setupOptions(), &error)
      if let error {
        setupError = error.localizedDescription
        NSLog("[core] setup failed: %@", error.localizedDescription)
      }
    }
  }

  static func waitUntilReady() {
    ready.wait()
  }

  private static func dropConfigIfContainerMoved() {
    let key = "lxbox.container_home"
    let home = NSHomeDirectory()
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

  private static func setupOptions() -> LibboxSetupOptions {
    let options = LibboxSetupOptions()
    options.basePath = FileManager.default.temporaryDirectory.path
    options.workingPath = filesDirectory.path
    options.tempPath = coreTempDirectory.path
    #if targetEnvironment(simulator)
      options.commandServerListenPort = 54345
      options.commandServerSecret = UUID().uuidString
    #endif
    options.logMaxLines = 3000
    options.debug = NativePrefs.bool("core_logs_enabled", fallback: false)
    options.crashReportSource = "lxbox"
    options.oomKillerEnabled = true
    options.oomMemoryLimit = memoryLimitBytes()
    options.oomMemoryLimitHeap = true
    return options
  }

  private static func memoryLimitBytes() -> Int64 {
    guard let mb = Int64(NativePrefs.string("memory_limit", fallback: "auto")),
      memoryLimitPresetsMb.contains(mb)
    else { return 0 }
    return mb * 1024 * 1024
  }

  private static func recoverAfterCrash() {
    let report = filesDirectory.appendingPathComponent(crashReportName)
    let size = (try? FileManager.default.attributesOfItem(atPath: report.path)[.size] as? Int) ?? 0
    guard size > 0 else { return }
    NSLog("[core] §334 previous launch crashed, resetting core caches")
    deleteCacheDb()
    let entries = (try? FileManager.default.contentsOfDirectory(at: coreTempDirectory, includingPropertiesForKeys: nil)) ?? []
    for entry in entries {
      try? FileManager.default.removeItem(at: entry)
    }
  }
}

enum NativePrefs {
  private static let prefix = "lxbox.native_prefs."
  private static let defaults = UserDefaults.standard

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
