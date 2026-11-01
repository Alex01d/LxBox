import 'package:flutter/foundation.dart' show visibleForTesting;

import 'core_chain_capability.dart';

/// AWG is an atomic transport choice: a version string is not proof that the
/// optional integration was compiled into the embedded core.
class CoreTransportCapability {
  CoreTransportCapability._();

  static Map<String, bool>? _cached;

  static Future<Set<String>> ensureTags(
    Future<Map<String, bool>?> Function() read,
  ) async {
    if (_cached == null) {
      try {
        _cached = await read();
      } catch (_) {
        // A failed probe is unknown. It can be retried, but cannot enable AWG.
      }
    }
    return {
      ...kCoreBuildTags,
      if (_cached?['with_tailscale_awg'] == true) 'with_tailscale_awg',
    };
  }

  @visibleForTesting
  static void resetForTest() => _cached = null;
}
