import Foundation
import Libbox
import NetworkExtension

private func runBlocking(_ block: @escaping () async throws -> Void) throws {
  let semaphore = DispatchSemaphore(value: 0)
  var failure: Error?
  Task.detached {
    do {
      try await block()
    } catch {
      failure = error
    }
    semaphore.signal()
  }
  semaphore.wait()
  if let failure { throw failure }
}

final class TunnelPlatform: CorePlatform {
  private unowned let provider: NEPacketTunnelProvider
  private var networkSettings: NEPacketTunnelNetworkSettings?

  init(_ provider: NEPacketTunnelProvider) {
    self.provider = provider
  }

  override func reset() {
    networkSettings = nil
    super.reset()
  }

  override func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    guard let options, let ret0_ else { throw Self.failure("Nil tun options") }
    let settings = try makeSettings(options)
    networkSettings = settings
    try runBlocking { [provider] in
      try await provider.setTunnelNetworkSettings(settings)
    }
    if let descriptor = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
      ret0_.pointee = descriptor
      return
    }
    let descriptor = LibboxGetTunnelFileDescriptor()
    guard descriptor != -1 else { throw Self.failure("Missing tun file descriptor") }
    ret0_.pointee = descriptor
  }

  private func makeSettings(_ options: LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    if options.getAutoRoute() {
      settings.mtu = NSNumber(value: options.getMTU())
      let ipv4 = makeIPv4Settings(options)
      settings.ipv4Settings = ipv4
      settings.ipv6Settings = makeIPv6Settings(options)
      settings.dnsSettings = try makeDNSSettings(options, ipv4: ipv4)
    }
    if options.isHTTPProxyEnabled() {
      settings.proxySettings = makeProxySettings(options)
    }
    return settings
  }

  private func makeIPv4Settings(_ options: LibboxTunOptionsProtocol) -> NEIPv4Settings {
    let addresses = prefixes(options.getInet4Address())
    let ipv4 = NEIPv4Settings(addresses: addresses.map { $0.address() }, subnetMasks: addresses.map { $0.mask() })
    let routes = prefixes(options.getInet4RouteAddress()).map(ipv4Route)
    ipv4.includedRoutes = routes.isEmpty ? [NEIPv4Route.default()] : routes
    ipv4.excludedRoutes = prefixes(options.getInet4RouteExcludeAddress()).map(ipv4Route)
    return ipv4
  }

  private func ipv4Route(_ prefix: LibboxRoutePrefix) -> NEIPv4Route {
    NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask())
  }

  private func makeIPv6Settings(_ options: LibboxTunOptionsProtocol) -> NEIPv6Settings {
    let addresses = prefixes(options.getInet6Address())
    let ipv6 = NEIPv6Settings(
      addresses: addresses.map { $0.address() },
      networkPrefixLengths: addresses.map { NSNumber(value: $0.prefix()) }
    )
    let routes = prefixes(options.getInet6RouteAddress()).map(ipv6Route)
    ipv6.includedRoutes = routes.isEmpty ? [NEIPv6Route.default()] : routes
    ipv6.excludedRoutes = prefixes(options.getInet6RouteExcludeAddress()).map(ipv6Route)
    return ipv6
  }

  private func ipv6Route(_ prefix: LibboxRoutePrefix) -> NEIPv6Route {
    NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix()))
  }

  private func makeDNSSettings(_ options: LibboxTunOptionsProtocol, ipv4: NEIPv4Settings) throws -> NEDNSSettings? {
    var servers: [String] = []
    let iterator = try options.getDNSServerAddress()
    while iterator.hasNext() {
      servers.append(iterator.next())
    }
    guard !servers.isEmpty else { return nil }
    let dns = NEDNSSettings(servers: servers)
    let hasDefaultRoute = ipv4.includedRoutes?.contains {
      $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
    } ?? false
    if !hasDefaultRoute {
      dns.matchDomains = [""]
      dns.matchDomainsNoSearch = true
    }
    return dns
  }

  private func makeProxySettings(_ options: LibboxTunOptionsProtocol) -> NEProxySettings {
    let proxy = NEProxySettings()
    let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
    proxy.httpServer = server
    proxy.httpsServer = server
    proxy.httpEnabled = true
    proxy.httpsEnabled = true
    return proxy
  }

  private func prefixes(_ iterator: LibboxRoutePrefixIteratorProtocol?) -> [LibboxRoutePrefix] {
    guard let iterator else { return [] }
    var result: [LibboxRoutePrefix] = []
    while iterator.hasNext() {
      if let prefix = iterator.next() { result.append(prefix) }
    }
    return result
  }

  override func underNetworkExtension() -> Bool { true }

  override func clearDNSCache() {
    guard let networkSettings else { return }
    try? runBlocking { [provider] in
      provider.reasserting = true
      defer { provider.reasserting = false }
      try await provider.setTunnelNetworkSettings(nil)
      try await provider.setTunnelNetworkSettings(networkSettings)
    }
  }

  override func serviceStop() throws {
    provider.cancelTunnelWithError(nil)
  }
}
