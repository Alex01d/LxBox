import 'dart:convert';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import 'preset_expand.dart';

const kTailscaleProtectedPreset = 'tailscale-protected';

class TailscaleProtectionFailure implements Exception {
  const TailscaleProtectionFailure(this.reason);
  final String reason;

  @override
  String toString() => 'tailscale_protection_invalid: $reason';
}

class TailscaleProtection {
  const TailscaleProtection(this.endpoint, this.cidrs, this.suffixes);
  final String endpoint;
  final List<String> cidrs;
  final List<String> suffixes;
  String get dnsTag => '$endpoint-protected-dns';

  List<Map<String, dynamic>> get routes => [
    if (cidrs.isNotEmpty)
      {'ip_cidr': cidrs, 'action': 'route', 'outbound': endpoint},
    if (suffixes.isNotEmpty) ...[
      {'domain_suffix': suffixes, 'action': 'resolve', 'server': dnsTag},
      {'domain_suffix': suffixes, 'action': 'route', 'outbound': endpoint},
    ],
  ];
}

/// Validate before expansion: a missing target or malformed fragment must not
/// quietly remove the only protection for private traffic.
List<TailscaleProtection> validateTailscaleProtection(
  List<CustomRule> rules,
  List<SelectableRule> presets,
  List<PresetNode> nodes, {
  Map<String, String> globalVars = const {},
}) {
  final result = <TailscaleProtection>[];
  for (final rule in rules.whereType<CustomRulePreset>()) {
    if (!rule.enabled || rule.presetId != kTailscaleProtectedPreset) continue;
    final preset = presets
        .where((p) => p.presetId == rule.presetId)
        .firstOrNull;
    if (preset == null) {
      throw const TailscaleProtectionFailure(
        'Protected preset is unavailable.',
      );
    }
    final resolved = presetVarsMap(rule, preset, globalVars: globalVars);
    final endpoint = '${resolved.vars['out'] ?? ''}'.trim();
    if (resolved.error != null ||
        endpoint.isEmpty ||
        !nodes.any((n) => n.tag == endpoint && n.body['type'] == 'tailscale')) {
      throw const TailscaleProtectionFailure(
        'Select an available Tailscale endpoint.',
      );
    }
    final cidrs = _lines(resolved.vars['protected_cidrs']);
    final suffixes = _lines(resolved.vars['private_dns_suffixes']);
    if (cidrs.isEmpty && suffixes.isEmpty) {
      throw const TailscaleProtectionFailure(
        'Enter a protected CIDR or private DNS suffix.',
      );
    }
    if (cidrs.any((c) => _Prefix.parse(c) == null)) {
      throw const TailscaleProtectionFailure('Invalid protected CIDR.');
    }
    final suffixPattern = RegExp(r'^[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\.?$');
    if (suffixes.any(
      (s) =>
          s.length > 253 ||
          !suffixPattern.hasMatch(s.startsWith('.') ? s.substring(1) : s),
    )) {
      throw const TailscaleProtectionFailure('Invalid private DNS suffix.');
    }
    result.add(TailscaleProtection(endpoint, cidrs, suffixes));
  }
  return result;
}

List<String> _lines(Object? value) => [
  for (final line
      in (value is List ? value.join('\n') : '${value ?? ''}')
          .replaceAll('\r\n', '\n')
          .split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// Final assembly boundary, after generic graph/DNS healing. Explicit private
/// protection takes priority over ordinary route and DNS rules, independent of
/// live peer maps, DNS-mirror switches and user preset ordering.
void enforceTailscaleProtection(
  Map<String, dynamic> config,
  List<TailscaleProtection> guards,
) {
  if (guards.isEmpty) return;
  final endpoints = (config['endpoints'] as List? ?? const []).whereType<Map>();
  final route = Map<String, dynamic>.from(config['route'] as Map? ?? const {});
  final dns = Map<String, dynamic>.from(config['dns'] as Map? ?? const {});
  final servers = (dns['servers'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final privateRoutes = <Map<String, dynamic>>[];
  final privateDns = <Map<String, dynamic>>[];
  for (final guard in guards) {
    if (!endpoints.any(
      (e) => e['tag'] == guard.endpoint && e['type'] == 'tailscale',
    )) {
      throw const TailscaleProtectionFailure(
        'Protected Tailscale endpoint was removed during assembly.',
      );
    }
    _checkTunnelExclusions(config, guard);
    var dnsTag = guard.dnsTag;
    if (guard.suffixes.isNotEmpty) {
      final tagged = servers.where((s) => s['tag'] == guard.dnsTag).toList();
      final endpointServers = servers
          .where(
            (s) => s['type'] == 'tailscale' && s['endpoint'] == guard.endpoint,
          )
          .toList();
      final Map<dynamic, dynamic>? selected;
      if (tagged.length == 1) {
        selected = tagged.single;
      } else if (tagged.isEmpty && endpointServers.length == 1) {
        // The ordinary Tailscale preset may have won the core's one-server-
        // per-endpoint limit. Reuse it for protected suffixes instead of
        // adding a second server or weakening the endpoint requirement.
        selected = endpointServers.single;
      } else {
        selected = null;
      }
      if (selected == null ||
          endpointServers.length != 1 ||
          selected['type'] != 'tailscale' ||
          selected['endpoint'] != guard.endpoint ||
          selected['tag'] is! String ||
          (selected['tag'] as String).isEmpty ||
          selected['accept_default_resolvers'] == true) {
        throw const TailscaleProtectionFailure(
          'Private DNS must use the selected Tailscale endpoint.',
        );
      }
      dnsTag = selected['tag'] as String;
      privateDns.add({'domain_suffix': guard.suffixes, 'server': dnsTag});
    }
    for (final protectedRoute in guard.routes) {
      privateRoutes.add({
        ...protectedRoute,
        if (protectedRoute['server'] == guard.dnsTag) 'server': dnsTag,
      });
    }
  }
  final routes = (route['rules'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final keys = privateRoutes.map(jsonEncode).toSet();
  final ordinary = routes.where((r) => !keys.contains(jsonEncode(r))).toList();
  // Keep initial protocol inspection/DNS interception ahead of destination
  // routing. Any earlier terminal direct/proxy rule moves behind the guard.
  var insertion = 0;
  while (insertion < ordinary.length &&
      const {'sniff', 'hijack-dns'}.contains(ordinary[insertion]['action'])) {
    insertion++;
  }
  route['rules'] = [
    ...ordinary.take(insertion),
    ...privateRoutes,
    ...ordinary.skip(insertion),
  ];
  final dnsKeys = privateDns.map(jsonEncode).toSet();
  dns['rules'] = [
    ...privateDns,
    for (final r in (dns['rules'] as List? ?? const []))
      if (!dnsKeys.contains(jsonEncode(r))) r,
  ];
  config['route'] = route;
  config['dns'] = dns;
}

void _checkTunnelExclusions(
  Map<String, dynamic> config,
  TailscaleProtection guard,
) {
  final protected = guard.cidrs.map(_Prefix.parse).whereType<_Prefix>();
  for (final tun
      in (config['inbounds'] as List? ?? const []).whereType<Map>()) {
    if (tun['type'] != 'tun') continue;
    for (final excluded
        in (tun['route_exclude_address'] as List? ?? const [])) {
      final prefix = excluded is String ? _Prefix.parse(excluded) : null;
      if (prefix != null && protected.any(prefix.overlaps)) {
        throw const TailscaleProtectionFailure(
          'A protected network overlaps a tunnel bypass range.',
        );
      }
    }
  }
}

class _Prefix {
  const _Prefix(this.bytes, this.bits);
  final List<int> bytes;
  final int bits;

  static _Prefix? parse(String value) {
    final parts = value.split('/');
    if (parts.length != 2 || !RegExp(r'^\d+$').hasMatch(parts[1])) return null;
    try {
      final bytes = parts[0].contains(':')
          ? Uri.parseIPv6Address(parts[0])
          : Uri.parseIPv4Address(parts[0]);
      final bits = int.tryParse(parts[1]);
      if (bits == null || bits > bytes.length * 8) return null;
      return _Prefix(bytes, bits);
    } on FormatException {
      return null;
    }
  }

  bool overlaps(_Prefix other) {
    if (bytes.length != other.bytes.length) return false;
    final common = bits < other.bits ? bits : other.bits;
    for (var bit = 0; bit < common; bit++) {
      final mask = 1 << (7 - bit % 8);
      if ((bytes[bit ~/ 8] & mask) != (other.bytes[bit ~/ 8] & mask)) {
        return false;
      }
    }
    return true;
  }
}
