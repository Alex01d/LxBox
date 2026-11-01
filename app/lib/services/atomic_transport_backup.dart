import 'dart:convert';

import '../config/config_parse.dart' show canonicalJsonForSingbox;

/// Contract 1.2.0: explicit import barrier for atomic profiles/static guards.
/// This describes the file, not the capabilities of the currently loaded AAR;
/// offline import is allowed and applying the configuration is gated separately.
final class LxBackupRequirements {
  const LxBackupRequirements({
    required this.minContract,
    required this.coreBuildTags,
  });

  final String minContract;
  final List<String> coreBuildTags;

  Map<String, dynamic> toJson() => {
    'min_contract': minContract,
    'core_build_tags': coreBuildTags,
  };

  static LxBackupRequirements parse(Object? value) {
    if (value is! Map ||
        value['min_contract'] != '1.2.0' ||
        value['core_build_tags'] is! List ||
        (value['core_build_tags'] as List).isEmpty) {
      throw const FormatException(
        'Backup requires a newer or unsupported transport contract',
      );
    }
    final tags = value['core_build_tags'] as List;
    if (tags.any(
      (tag) => tag != 'with_tailscale' && tag != 'with_tailscale_awg',
    )) {
      throw const FormatException(
        'Backup requires an unsupported core capability',
      );
    }
    return LxBackupRequirements(
      minContract: '1.2.0',
      coreBuildTags: List<String>.unmodifiable(tags.cast<String>()),
    );
  }
}

/// Inspect the exported structure, including native JSON stored as origin text.
/// Do not inspect arbitrary string values (which can contain user secrets).
LxBackupRequirements? atomicTransportRequirements(Object? value) {
  var awg = false;
  var guard = false;
  void visit(Object? node) {
    if (node is Map) {
      if (node['type'] == 'tailscale' &&
          (node['awg'] != null || node['underlay_mode'] != null)) {
        awg = true;
      }
      if (node['ref'] == 'tailscale-protected') guard = true;
      if (node['kind'] == 'json' && node['raw'] is String) {
        try {
          visit(jsonDecode(canonicalJsonForSingbox(node['raw'] as String)));
        } on FormatException {
          // An invalid origin is retained by the ordinary backup path; it
          // cannot become a valid transport by ignoring a failed JSON parse.
        }
      }
      for (final child in node.values) {
        visit(child);
      }
    } else if (node is List) {
      for (final child in node) {
        visit(child);
      }
    }
  }

  visit(value);
  if (!awg && !guard) return null;
  return LxBackupRequirements(
    minContract: '1.2.0',
    coreBuildTags: [awg ? 'with_tailscale_awg' : 'with_tailscale'],
  );
}
