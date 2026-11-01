import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/tailscale_awg_profile.dart';
import 'package:lxbox/vpn/cc_channel.dart';

void main() {
  final schema =
      jsonDecode(
            File(
              'assets/contract/schema/tailscale_awg.schema.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  Map<String, dynamic> profile(int version) => {
    'version': version,
    'profile_id': 'test-profile',
    'parameters': {
      'jc': 4,
      's1': 64,
      'h1': '100000-199999',
      'h2': 4294967295,
      if (version == 3) ...{
        'header_protection_key': 'synthetic-shared-key',
        'content_padding_addition': '10-40',
        'random_trailers': true,
      },
    },
  };

  test('AWG2/AWG3 share the authoritative typed profile without identity', () {
    for (final version in [2, 3]) {
      final input = profile(version);
      final parsed = parseTailscaleAwgProfile(jsonEncode(input), schema);
      expect(parsed, input);
      expect(parsed['parameters']['jc'], isA<int>());
      expect(parsed['parameters']['h1'], isA<String>());
      expect(parsed['parameters']['h2'], 4294967295);
      if (version == 3) {
        expect(parsed['parameters']['random_trailers'], isA<bool>());
      }
      expect(
        parsed.keys,
        unorderedEquals(['version', 'profile_id', 'parameters']),
      );
    }
  });

  test(
    'invalid shape, types and unknown fields fail without exposing values',
    () {
      const secret = 'SECRET_SENTINEL_PRIVATE_IDENTITY';
      final bad = <Object?>[
        [],
        {
          'version': 4,
          'parameters': {'s1': 64},
        },
        {
          'version': '3',
          'parameters': {'s1': 64},
        },
        {'version': 2, 'parameters': {}},
        {
          'version': 2,
          'parameters': {'s1': '64'},
        },
        {
          'version': 2,
          'parameters': {'s1': 4.0},
        },
        {
          'version': 2,
          'parameters': {'s1': -1},
        },
        {
          'version': 2,
          'parameters': {'s1': 4294967296},
        },
        {
          'version': 2,
          'parameters': {'h1': 'invalid-$secret'},
        },
        {
          'version': 3,
          'parameters': {'random_trailers': 1},
        },
        {
          'version': 2,
          'parameters': {'private_key': secret},
        },
        {
          'version': 2,
          'parameters': {'i1': 'value\n$secret'},
        },
        {...profile(2), 'state_directory': secret},
        {...profile(2), 'profile_id': 'label with spaces'},
        {...profile(2), secret: secret},
      ];
      for (final input in bad) {
        try {
          parseTailscaleAwgProfile(jsonEncode(input), schema);
          fail('Accepted invalid profile');
        } on FormatException catch (error) {
          expect(error.toString(), isNot(contains(secret)));
          expect(error.source, isNull);
        }
      }
      expect(
        () => parseTailscaleAwgProfile('{"$secret":', schema),
        throwsFormatException,
      );
      expect(
        () => parseTailscaleAwgProfile(jsonEncode(profile(2)), {}),
        throwsFormatException,
      );
      expect(
        () => parseTailscaleAwgProfile(
          ' ' * (tailscaleAwgProfileMaxBytes + 1),
          schema,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'transport edits preserve node identity and carrier, ordinary removes awg',
    () {
      final initial = TailscaleSpec(
        id: 'existing-node-identity',
        tag: 'private-net',
        label: 'Private network',
        body: {
          'control_url': 'https://headscale.example.invalid',
          'underlay_mode': 'derp',
          'accept_routes': true,
          'awg': profile(2),
        },
      );
      final changed = initial.copyWith(
        body: withTailscaleAwgProfile(initial.body, profile(3)),
      );
      expect(changed.id, initial.id);
      expect(changed.tag, initial.tag);
      expect(initial.body['awg']['version'], 2);
      expect(changed.body['underlay_mode'], 'derp');
      expect(changed.emit(TemplateVars.empty).map['awg'], profile(3));
      expect(jsonDecode(changed.toUri())['awg'], profile(3));
      final ordinary = withTailscaleAwgProfile(changed.body, null);
      expect(ordinary.containsKey('awg'), isFalse);
      expect(ordinary['underlay_mode'], 'derp');
      expect(ordinary['control_url'], initial.body['control_url']);
      expect(changed.body['awg'], profile(3));
    },
  );

  test('transport status is optional and distinct from control/peer state', () {
    Map<String, dynamic> base() => {
      'tag': 'private-net',
      'backend_state': 'Running',
      'state_text': 'running',
    };
    expect(CcTailscaleStatus.fromMap(base()).transport, isNull);
    final ready = CcTailscaleStatus.fromMap({
      ...base(),
      'transport': {
        'configured_mode': 'awg3',
        'applied_mode': 'awg3',
        'profile_id': 'test-profile',
        'profile_fingerprint': 'test-fingerprint',
        'applied': true,
        'last_error': '',
      },
    });
    expect(ready.peers, isEmpty);
    expect(ready.transport!.configuredMode, 'awg3');
    expect(ready.transport!.applied, isTrue);
    expect(ready.transport!.profileFingerprint, 'test-fingerprint');
    final failed = CcTailscaleStatus.fromMap({
      ...base(),
      'transport': {
        'configured_mode': 'awg2',
        'applied_mode': '',
        'applied': false,
        'last_error': 'awg_profile_invalid',
      },
    });
    expect(failed.backendState, 'Running');
    expect(failed.transport!.applied, isFalse);
    expect(failed.transport!.lastError, 'awg_profile_invalid');
    final malformed = CcTailscaleTransport.fromMap({
      'configured_mode': {'secret': 'do not stringify'},
      'applied': 'true',
    });
    expect(malformed.configuredMode, isEmpty);
    expect(malformed.applied, isFalse);
  });
}
