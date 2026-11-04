import Foundation
import Libbox
import Network

class CorePlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
  var onDebugMessage: ((String) -> Void)?
  var onServiceStop: (() -> Void)?
  var onServiceReload: (() -> Void)?
  var onInterfaceSwitch: (() -> Void)?

  private let lock = NSLock()
  private var monitor: NWPathMonitor?
  private var lastInterfaceName: String?

  func reset() {
    lock.lock()
    let current = monitor
    monitor = nil
    lastInterfaceName = nil
    lock.unlock()
    current?.cancel()
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "LxBox", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
  }

  func openTun(_: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    throw Self.failure("VPN mode does not run in Simulator. Select Local proxy in VPN Settings.")
  }

  func underNetworkExtension() -> Bool { false }
  func includeAllNetworks() -> Bool { false }
  func clearDNSCache() {}

  func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    guard let listener else { return }
    let monitor = NWPathMonitor()
    lock.lock()
    self.monitor = monitor
    lock.unlock()
    let semaphore = DispatchSemaphore(value: 0)
    monitor.pathUpdateHandler = { [weak self] path in
      self?.update(listener, path)
      semaphore.signal()
      monitor.pathUpdateHandler = { [weak self] path in
        self?.update(listener, path)
      }
    }
    monitor.start(queue: DispatchQueue.global())
    semaphore.wait()
  }

  private func update(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
    guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
      listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
      return
    }
    noteDefaultInterface(interface.name)
    listener.updateDefaultInterface(
      interface.name,
      interfaceIndex: Int32(interface.index),
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained
    )
  }

  private func noteDefaultInterface(_ name: String) {
    lock.lock()
    let previous = lastInterfaceName
    lastInterfaceName = name
    lock.unlock()
    if let previous, previous != name {
      onInterfaceSwitch?()
    }
  }

  func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
    reset()
  }

  func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
    lock.lock()
    let current = monitor
    lock.unlock()
    guard let current else { throw Self.failure("Path monitor not started") }
    let path = current.currentPath
    guard path.status != .unsatisfied else { return InterfaceIterator([]) }
    return InterfaceIterator(path.availableInterfaces.map { item in
      let interface = LibboxNetworkInterface()
      interface.name = item.name
      interface.index = Int32(item.index)
      switch item.type {
      case .wifi: interface.type = LibboxInterfaceTypeWIFI
      case .cellular: interface.type = LibboxInterfaceTypeCellular
      case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
      default: interface.type = LibboxInterfaceTypeOther
      }
      return interface
    })
  }

  private final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var current: LibboxNetworkInterface?

    init(_ interfaces: [LibboxNetworkInterface]) {
      iterator = interfaces.makeIterator()
    }

    func hasNext() -> Bool {
      current = iterator.next()
      return current != nil
    }

    func next() -> LibboxNetworkInterface? { current }
  }

  func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
  func usePlatformAutoDetectControl() -> Bool { false }
  func autoDetectControl(_: Int32) throws {}
  func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
    throw Self.failure("Not available on iOS")
  }
  func readWIFIState() -> LibboxWIFIState? { nil }
  func send(_: LibboxNotification?) throws {}
  func cancelNotification(_: String?, typeID _: Int32) throws {}
  func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
  func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
  func registerMyInterface(_: String?) {}
  func usePlatformShell() -> Bool { false }
  func checkPlatformShell() throws { throw Self.failure("Not available on iOS") }
  func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
    throw Self.failure("Not available on iOS")
  }
  func lookupUser(_: String?) throws -> LibboxPlatformUser { throw Self.failure("Not available on iOS") }
  func lookupSFTPServer(_: NSErrorPointer) -> String { "" }
  func readSystemSSHHostKey(_: NSErrorPointer) -> String { "" }
  func tailscaleHostname() -> String { "lxbox-ios" }
  func usePlatformBridge() -> Bool { false }
  func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
    throw Self.failure("Not available on iOS")
  }

  func serviceStop() throws { onServiceStop?() }
  func serviceReload() throws { onServiceReload?() }
  func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
  func setSystemProxyEnabled(_: Bool) throws {}
  func triggerNativeCrash() throws {}
  func writeDebugMessage(_ message: String?) {
    if let message { onDebugMessage?(message) }
  }
  func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws { throw Self.failure("Not available on iOS") }
}
