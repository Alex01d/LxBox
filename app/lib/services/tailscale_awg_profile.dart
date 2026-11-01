import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// The profile is portable transport configuration. Node keys, routes and the
/// state directory are never part of this object. The authoritative schema is
/// mirrored by sync_contract.sh, rather than a second parameter dictionary.
const tailscaleAwgProfileMaxBytes = 1 << 20;

Future<Map<String, dynamic>> loadTailscaleAwgSchema() async =>
    jsonDecode(
          await rootBundle.loadString(
            'assets/contract/schema/tailscale_awg.schema.json',
          ),
        )
        as Map<String, dynamic>;

/// Errors deliberately contain no source text, unknown keys or shared keys.
Map<String, dynamic> parseTailscaleAwgProfile(
  String text,
  Map<String, dynamic> schema,
) {
  if (text.length > tailscaleAwgProfileMaxBytes ||
      utf8.encode(text).length > tailscaleAwgProfileMaxBytes) {
    throw const FormatException('AWG profile is too large');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('Invalid AWG profile JSON');
  }
  if (!_matchesSchema(decoded, schema) || decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid AWG profile');
  }
  // Return an owned, typed JSON value. Cross-field transport constraints are
  // still checked by the core before it starts the endpoint.
  return decoded;
}

bool _matchesSchema(Object? value, Map<String, dynamic> schema) {
  final oneOf = schema['oneOf'];
  if (oneOf is List) {
    return oneOf
            .whereType<Map<String, dynamic>>()
            .where((candidate) => _matchesSchema(value, candidate))
            .length ==
        1;
  }
  final choices = schema['enum'];
  if (choices is List && !choices.contains(value)) return false;
  switch (schema['type']) {
    case 'object':
      if (value is! Map<String, dynamic>) return false;
      final required = schema['required'];
      if (required is List && required.any((key) => !value.containsKey(key))) {
        return false;
      }
      final minProperties = schema['minProperties'];
      if (minProperties is int && value.length < minProperties) return false;
      final properties = schema['properties'] as Map<String, dynamic>? ?? {};
      for (final entry in value.entries) {
        final property = properties[entry.key];
        if (property is! Map<String, dynamic>) {
          if (schema['additionalProperties'] == false) return false;
        } else if (!_matchesSchema(entry.value, property)) {
          return false;
        }
      }
      return true;
    case 'integer':
      if (value is! int) return false;
      final min = schema['minimum'];
      final max = schema['maximum'];
      return (min is! num || value >= min) && (max is! num || value <= max);
    case 'boolean':
      return value is bool;
    case 'string':
      if (value is! String) return false;
      final pattern = schema['pattern'];
      return pattern is! String || RegExp(pattern).hasMatch(value);
    default:
      // A missing or newer schema must never silently accept a profile.
      return false;
  }
}

/// Change only the transport profile; the owning record and node identity stay
/// with their existing save path. null explicitly selects ordinary Tailscale.
Map<String, dynamic> withTailscaleAwgProfile(
  Map<String, dynamic> body,
  Map<String, dynamic>? profile,
) {
  final next = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
  if (profile == null) {
    next.remove('awg');
  } else {
    next['awg'] = jsonDecode(jsonEncode(profile));
  }
  return next;
}
