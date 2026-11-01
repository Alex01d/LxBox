import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/atomic_transport_backup.dart';
import 'package:lxbox/services/builder/registry_gate.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/node_core_gate.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

import '../contract_paths.dart';

const _tags = {'with_tailscale', 'with_tailscale_awg'};
const _profile = {
  'version': 3,
  'profile_id': 'synthetic-test',
  'parameters': {
    'jc': 4,
    'jmin': 40,
    'jmax': 70,
    's1': 64,
    's2': 64,
    's3': 32,
    's4': 16,
    'h1': '100000-199999',
    'h2': '200000-299999',
    'h3': '300000-399999',
    'h4': '400000-499999',
    'random_trailers': true,
  },
};

Map<String, dynamic> _body({bool awg = true, bool carrier = false}) => {
  'type': 'tailscale',
  'tag': 'private-net',
  'control_url': 'https://headscale.example.invalid',
  if (awg) 'awg': jsonDecode(jsonEncode(_profile)),
  if (carrier) 'underlay_mode': 'derp',
};

UserServer _server(Map<String, dynamic> body) => UserServer(
  id: 'local-private-node',
  name: '',
  enabled: true,
  tagPrefix: '',
  detourPolicy: DetourPolicy.defaults,
  origin: UserSource.manual,
  rawBody: jsonEncode(body),
);

Future<Map<String, dynamic>> _export({
  Map<String, dynamic>? body,
  List<CustomRule> rules = const [],
}) async =>
    jsonDecode(
          (await buildLxBackup(
            lists: [if (body != null) _server(body)],
            rules: rules,
            vars: const {},
          )).json,
        )
        as Map<String, dynamic>;

void main() {
  setUpAll(loadTestRegistry);

  test(
    'authoritative registry declares atomic JSON and fatal capabilities',
    () {
      final fields = ContractRegistry.I.schemaFor('tailscale')!.fields;
      expect(fields['awg']!.type, 'json');
      for (final name in ['awg', 'underlay_mode']) {
        expect(fields[name]!.onCoreUnsupported!.failsBuild, isTrue);
        expect(fields[name]!.onCoreUnsupported!.dropsNode, isFalse);
        expect(fields[name]!.buildTag, 'with_tailscale_awg');
      }
    },
  );

  test('unknown and missing capabilities refuse before any entry mutation', () {
    for (final tags in <Set<String>?>[
      null,
      {},
      {'with_tailscale'},
    ]) {
      final ordinary = Outbound({
        'type': 'trojan',
        'tag': 'public',
        'server': 'example.invalid',
        'server_port': 443,
        'password': 'secret-public',
        'unknown_key_must_survive_failed_preflight': 42,
      });
      final atomic = Endpoint(_body()..['auth_key'] = 'secret-auth-sentinel');
      final before = jsonEncode([ordinary.map, atomic.map]);
      expect(
        () => applyRegistryGate(
          [ordinary, atomic],
          coreVersion: '1.14.4-lx.25',
          coreBuildTags: tags,
        ),
        throwsA(
          isA<CoreBuildFailure>()
              .having((e) => e.code, 'code', 'tailscale_awg_core_unsupported')
              .having(
                (e) => e.toString().contains('secret-'),
                'secrets',
                isFalse,
              ),
        ),
      );
      expect(jsonEncode([ordinary.map, atomic.map]), before);
    }
  });

  test('underlay-only requires the same confirmed capability', () {
    final body = _body(awg: false, carrier: true);
    expect(
      nodeCoreBuildFailure('tailscale', body, const CoreInfo())?.path,
      'underlay_mode',
    );
    expect(
      nodeCoreBuildFailure('tailscale', body, const CoreInfo(tags: _tags)),
      isNull,
    );
  });

  test('atomic profile keeps typed and unknown fields for core validation', () {
    final body = _body(carrier: true);
    (body['awg'] as Map)['future_invalid_key'] = {'sentinel': 7};
    final before = jsonDecode(jsonEncode(body));
    final endpoint = Endpoint(body);
    final report = applyRegistryGate(
      [endpoint],
      coreVersion: '1.14.4-lx.25',
      coreBuildTags: _tags,
    );
    expect(report.dropped, isEmpty);
    expect(report.warnings, isEmpty);
    expect(endpoint.map, before);
    final parameters = (endpoint.map['awg'] as Map)['parameters'] as Map;
    expect(parameters['jc'], isA<int>());
    expect(parameters['random_trailers'], isA<bool>());
    expect(parameters['h1'], isA<String>());
  });

  test('parser model edit and emitter preserve profile and local identity', () {
    final body = _body(carrier: true);
    final parsed = parseSingboxEntry(body)! as TailscaleSpec;
    final edited = parsed.copyWith(label: 'renamed');
    expect(edited.id, parsed.id);
    final emitted = edited.emitRaw(TemplateVars.empty).map;
    expect(emitted['awg'], _profile);
    expect(emitted['underlay_mode'], 'derp');
    expect((jsonDecode(edited.toUri()) as Map)['awg'], _profile);
  });

  test(
    'invalid atomic values survive sanitization for strict core refusal',
    () {
      for (final value in <Object?>['', true, 7, <String, dynamic>{}]) {
        final body = _body(awg: false)
          ..['awg'] = value
          ..['underlay_mode'] = value;
        final result = RegistrySanitizer.sanitize(
          body,
          scheme: 'tailscale',
          coreVersion: '1.14.4-lx.25',
        );
        expect(result.body!.containsKey('awg'), isTrue);
        expect(result.body!['awg'], value);
        expect(result.body!.containsKey('underlay_mode'), isTrue);
        expect(result.body!['underlay_mode'], value);
      }
    },
  );

  test(
    'plain Tailscale keeps legacy unknown and absent capability behavior',
    () {
      final body = _body(awg: false);
      expect(nodeCoreBuildFailure('tailscale', body, const CoreInfo()), isNull);
      expect(nodeCoreRefusal('tailscale', body, const CoreInfo()), isNull);
      expect(
        nodeCoreRefusal('tailscale', body, const CoreInfo(tags: {}))?.code,
        'tailscale_core_unsupported',
      );
      final clean = RegistrySanitizer.sanitize(
        body,
        scheme: 'tailscale',
        coreVersion: '1.14.4-lx.25',
      );
      expect(clean.body?['awg'], isNull);
    },
  );

  test(
    'ordinary exports remain marker 2 and atomic profiles become marker 3',
    () async {
      final ordinary = await _export(body: _body(awg: false));
      expect(ordinary['lx_backup'], 2);
      expect(ordinary.containsKey('requires'), isFalse);

      final atomic = await _export(body: _body(carrier: true));
      expect(atomic['lx_backup'], 3);
      expect(atomic['requires'], {
        'min_contract': '1.2.0',
        'core_build_tags': ['with_tailscale_awg'],
      });
      final imported = decodeLxBackup(jsonEncode(atomic));
      expect(imported.version, 3);
      expect(imported.requires!.toJson(), atomic['requires']);
      expect(imported.copyWith().requires!.toJson(), atomic['requires']);
      expect(
        gateLxBackupTargets(imported, {}).requires!.toJson(),
        atomic['requires'],
      );
      final merged = mergeBackupServers([], imported.servers);
      final again =
          jsonDecode(
                (await buildLxBackup(
                  lists: merged.lists,
                  rules: const [],
                  vars: const {},
                )).json,
              )
              as Map;
      expect(again['lx_backup'], 3);
      expect(again['requires'], atomic['requires']);
      final node = ((again['sources'] as List).single as Map)['body'] as Map;
      expect(node['awg'], _profile);
      expect(node['underlay_mode'], 'derp');
    },
  );

  test('carrier-only and protected guard exports also use marker 3', () async {
    final carrier = await _export(body: _body(awg: false, carrier: true));
    expect(carrier['lx_backup'], 3);
    expect((carrier['requires'] as Map)['core_build_tags'], [
      'with_tailscale_awg',
    ]);
    final guard = await _export(
      rules: [
        CustomRulePreset(
          name: 'Protected networks',
          presetId: 'tailscale-protected',
          orderNum: 944,
        ),
      ],
    );
    expect(guard['lx_backup'], 3);
    expect((guard['requires'] as Map)['core_build_tags'], ['with_tailscale']);
    expect(decodeLxBackup(jsonEncode(guard)).requires!.minContract, '1.2.0');
  });

  test('native profile in JSONC origin cannot evade the marker boundary', () {
    final requirements = atomicTransportRequirements({
      'kind': 'json',
      'raw': '{// source\n"endpoints": [${jsonEncode(_body())}]}',
    });
    expect(requirements!.coreBuildTags, ['with_tailscale_awg']);
  });

  test('unsupported marker and requirements reject before body import', () {
    for (final requirements in [
      null,
      {'min_contract': '1.2.0', 'core_build_tags': []},
      {
        'min_contract': '9.0.0',
        'core_build_tags': ['with_tailscale_awg'],
      },
      {
        'min_contract': '1.2.0',
        'core_build_tags': ['unknown_transport'],
      },
    ]) {
      expect(
        () => decodeLxBackup(
          jsonEncode({
            'lx_backup': 3,
            'requires': requirements,
            'sources': 'must not be decoded',
          }),
        ),
        throwsFormatException,
      );
    }
    expect(() => decodeLxBackup('{"lx_backup":4}'), throwsFormatException);
    expect(() => decodeLxBackup('{"lx_backup":"3"}'), throwsFormatException);
    expect(decodeLxBackup('{"lx_backup":1}').version, 1);
  });
}
