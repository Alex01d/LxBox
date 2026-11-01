import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/tailscale_protected.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../parser/engine_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadEngineSections);
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_awg_guard_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await tmp.delete(recursive: true);
  });

  final template = WizardTemplate.fromJson(
    jsonDecode(File('assets/wizard_template.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final node = TailscaleSpec(
    id: 'ts',
    tag: 'private-net',
    label: '',
    body: const {},
  );
  final source = UserServer(
    id: 'ts-source',
    name: '',
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
    origin: UserSource.manual,
    rawBody: node.toUri(),
    nodes: [node],
    skipTailscalePresets: true,
  );
  CustomRulePreset guard({
    String target = 'private-net',
    String cidrs = '10.20.0.0/16\nfd00:143::/64',
    String suffix = 'internal.example\ninternal2.example',
  }) => CustomRulePreset(
    name: 'Protected',
    presetId: kTailscaleProtectedPreset,
    orderNum: 5000,
    varsValues: {
      'out': target,
      'protected_cidrs': cidrs,
      'private_dns_suffixes': suffix,
    },
  );

  Future<BuildResult> build(
    CustomRulePreset rule, {
    List<ServerList>? lists,
    bool includeOrdinaryTailscalePreset = false,
    List<Mixin> mixins = const [],
  }) => buildConfig(
    lists: lists ?? [source],
    template: template,
    settings: BuildSettings(
      mixins: mixins,
      customRules: [
        if (includeOrdinaryTailscalePreset)
          CustomRulePreset(
            name: 'Tailscale networks',
            presetId: 'tailscale',
            orderNum: 945,
          ),
        CustomRuleInline(
          name: 'Earlier public route',
          orderNum: 100,
          domainSuffixes: ['internal.example'],
          outbound: 'direct-out',
        ),
        rule,
      ],
    ),
  );

  test(
    'raw mixins cannot remove static private route and DNS protection',
    () async {
      final result = await build(
        guard(),
        mixins: [
          Mixin(
            target: 'route.rules',
            op: 'set',
            value: [
              {'outbound': 'direct-out'},
            ],
          ),
          Mixin(
            target: 'dns.rules',
            op: 'set',
            value: [
              {'server': 'google_doh'},
            ],
          ),
        ],
      );
      final routes = (result.config['route']['rules'] as List).cast<Map>();
      final dns = (result.config['dns']['rules'] as List).cast<Map>();
      expect(routes.first['ip_cidr'], contains('10.20.0.0/16'));
      expect(routes.first['outbound'], 'private-net');
      expect(dns.first['server'], 'private-net-protected-dns');
      expect(dns.first['domain_suffix'], contains('internal.example'));
      await expectLater(
        build(
          guard(),
          mixins: [Mixin(target: 'endpoints', op: 'set', value: [])],
        ),
        throwsA(isA<TailscaleProtectionFailure>()),
      );
    },
  );

  test(
    'explicit guards survive without login or live routes and precede public routing',
    () async {
      final result = await build(guard());
      final endpoint = (result.config['endpoints'] as List)
          .cast<Map>()
          .singleWhere((e) => e['tag'] == 'private-net');
      expect(endpoint.containsKey('auth_key'), isFalse);
      final routes = (result.config['route']['rules'] as List).cast<Map>();
      final privateIp = routes.indexWhere(
        (r) => r['outbound'] == 'private-net' && r.containsKey('ip_cidr'),
      );
      final privateName = routes.indexWhere(
        (r) => r['outbound'] == 'private-net' && r.containsKey('domain_suffix'),
      );
      final publicSet = (result.config['route']['rule_set'] as List)
          .whereType<Map>()
          .firstWhere(
            (s) => (s['rules'] as List).whereType<Map>().any(
              (r) => (r['domain_suffix'] as List? ?? const []).contains(
                'internal.example',
              ),
            ),
          );
      final public = routes.indexWhere(
        (r) =>
            r['outbound'] == 'direct-out' &&
            (r['rule_set'] == publicSet['tag'] ||
                (r['rule_set'] is List &&
                    (r['rule_set'] as List).contains(publicSet['tag']))),
      );
      expect(privateIp, greaterThanOrEqualTo(0));
      expect(routes[privateIp]['ip_cidr'], ['10.20.0.0/16', 'fd00:143::/64']);
      // Inspect every fragment: a valid final guard must not hide an older
      // template fragment containing a raw multiline value (core rejects it).
      for (final rule in routes) {
        for (final cidr in rule['ip_cidr'] as List? ?? const []) {
          final parts = (cidr as String).split('/');
          expect(parts, hasLength(2));
          expect(cidr, isNot(contains('\n')));
          expect(InternetAddress.tryParse(parts.first), isNotNull);
          expect(int.tryParse(parts.last), isNotNull);
        }
      }
      expect(privateName, lessThan(public));
      expect(public, greaterThanOrEqualTo(0));
      final dns = result.config['dns'] as Map;
      for (final rule in (dns['rules'] as List).whereType<Map>()) {
        for (final suffix in rule['domain_suffix'] as List? ?? const []) {
          expect(suffix, isNot(contains('\n')));
        }
      }
      expect((dns['rules'] as List).first, {
        'domain_suffix': ['internal.example', 'internal2.example'],
        'server': 'private-net-protected-dns',
      });
      expect(
        (dns['servers'] as List).whereType<Map>().any(
          (s) =>
              s['tag'] == 'private-net-protected-dns' &&
              s['endpoint'] == 'private-net',
        ),
        isTrue,
      );
    },
  );

  test('protected DNS coexists with the ordinary Tailscale preset', () async {
    final result = await build(
      guard(),
      lists: [source.copyWith(skipTailscalePresets: false)],
      includeOrdinaryTailscalePreset: true,
    );
    final dns = result.config['dns'] as Map;
    final protectedRule = (dns['rules'] as List).whereType<Map>().first;
    final selectedTag = protectedRule['server'];
    final selectedServers = (dns['servers'] as List)
        .whereType<Map>()
        .where((s) => s['tag'] == selectedTag)
        .toList();
    expect(selectedServers, hasLength(1));
    expect(selectedServers.single['type'], 'tailscale');
    expect(selectedServers.single['endpoint'], 'private-net');
    expect(selectedServers.single['accept_default_resolvers'], isNot(true));
    expect(
      (result.config['route']['rules'] as List).whereType<Map>().any(
        (r) => r['action'] == 'resolve' && r['server'] == selectedTag,
      ),
      isTrue,
    );
    expect(
      (dns['servers'] as List)
          .whereType<Map>()
          .where(
            (s) => s['type'] == 'tailscale' && s['endpoint'] == 'private-net',
          )
          .length,
      1,
    );
    // The ordinary preset's MagicDNS rule remains present alongside the
    // protected suffix rule; only endpoint-server selection is shared.
    expect(
      (dns['rules'] as List).whereType<Map>().any(
        (r) => r['preferred_by'] != null,
      ),
      isTrue,
    );
  });

  test(
    'missing or disabled endpoint rejects the complete configuration',
    () async {
      await expectLater(
        build(guard(target: 'missing')),
        throwsA(isA<TailscaleProtectionFailure>()),
      );
      await expectLater(
        build(guard(), lists: []),
        throwsA(isA<TailscaleProtectionFailure>()),
      );
    },
  );

  test('malformed lists and empty guards cannot silently disappear', () async {
    for (final rule in [
      guard(cidrs: '10.20.0.0/16,10.0.0.0/8'),
      guard(cidrs: '10.20.0.0/33'),
      guard(cidrs: 'fd00::/129'),
      guard(suffix: 'private.example,public.example'),
      guard(cidrs: '', suffix: ''),
    ]) {
      await expectLater(
        build(rule),
        throwsA(isA<TailscaleProtectionFailure>()),
      );
    }
  });

  Map<String, dynamic> finalConfig({bool badDns = false, String? bypass}) => {
    'endpoints': [
      {'tag': 'private-net', 'type': 'tailscale'},
    ],
    'dns': {
      'servers': [
        {
          'tag': 'private-net-protected-dns',
          'type': badDns ? 'udp' : 'tailscale',
          'endpoint': 'private-net',
        },
      ],
      'rules': [
        {
          'domain_suffix': ['internal.example'],
          'server': 'public',
        },
      ],
    },
    'route': {
      'rules': [
        {'action': 'sniff'},
        {'action': 'route', 'outbound': 'direct-out'},
      ],
    },
    'inbounds': [
      if (bypass != null)
        {
          'type': 'tun',
          'route_exclude_address': [bypass],
        },
    ],
  };
  const plan = TailscaleProtection(
    'private-net',
    ['10.20.0.0/16'],
    ['internal.example'],
  );

  test(
    'DNS mirror switches cannot put public DNS ahead of private suffixes',
    () {
      final config = finalConfig();
      enforceTailscaleProtection(config, [plan]);
      expect(config['route']['rules'][0]['action'], 'sniff');
      expect(config['route']['rules'][1]['outbound'], 'private-net');
      expect(config['dns']['rules'][0]['server'], 'private-net-protected-dns');
    },
  );

  test('DNS collision and overlapping OS tunnel bypass reject apply', () {
    expect(
      () => enforceTailscaleProtection(finalConfig(badDns: true), [plan]),
      throwsA(isA<TailscaleProtectionFailure>()),
    );
    for (final bypass in ['10.20.1.0/24', '10.0.0.0/8', '0.0.0.0/0']) {
      expect(
        () => enforceTailscaleProtection(finalConfig(bypass: bypass), [plan]),
        throwsA(isA<TailscaleProtectionFailure>()),
      );
    }
    enforceTailscaleProtection(finalConfig(bypass: '192.168.0.0/16'), [plan]);
  });

  test('unsafe or ambiguous endpoint DNS cannot satisfy protected DNS', () {
    final unsafe = finalConfig();
    unsafe['dns']['servers'] = [
      {
        'tag': 'private-net-dns',
        'type': 'tailscale',
        'endpoint': 'private-net',
        'accept_default_resolvers': true,
      },
    ];
    expect(
      () => enforceTailscaleProtection(unsafe, [plan]),
      throwsA(isA<TailscaleProtectionFailure>()),
    );

    final ambiguous = finalConfig();
    ambiguous['dns']['servers'] = [
      {
        'tag': 'private-net-dns',
        'type': 'tailscale',
        'endpoint': 'private-net',
      },
      {
        'tag': 'private-net-other-dns',
        'type': 'tailscale',
        'endpoint': 'private-net',
      },
    ];
    expect(
      () => enforceTailscaleProtection(ambiguous, [plan]),
      throwsA(isA<TailscaleProtectionFailure>()),
    );
  });

  test('DNS fallback is isolated to the selected endpoint', () {
    final config = finalConfig();
    config['endpoints'] = [
      {'tag': 'private-net', 'type': 'tailscale'},
      {'tag': 'other-net', 'type': 'tailscale'},
    ];
    config['dns']['servers'] = [
      {'tag': 'other-net-dns', 'type': 'tailscale', 'endpoint': 'other-net'},
    ];
    expect(
      () => enforceTailscaleProtection(config, [plan]),
      throwsA(isA<TailscaleProtectionFailure>()),
    );
  });
}
