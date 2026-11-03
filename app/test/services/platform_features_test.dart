import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';
import 'package:lxbox/services/platform_features.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../parser/engine_test_setup.dart';

void main() {
  setUpAll(loadEngineSections);

  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_platform_features_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    PlatformFeatures.isIosForTesting = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('gates', () {
    test('Android and Linux keep every feature', () {
      PlatformFeatures.isIosForTesting = false;
      expect(PlatformFeatures.hasAndroidSystemSettings, isTrue);
      expect(PlatformFeatures.hasPerAppRouting, isTrue);
      expect(PlatformFeatures.canReadWifiName, isTrue);
      expect(PlatformFeatures.isPresetDisabled('unknown-traffic'), isFalse);
    });

    test('iOS turns them off', () {
      PlatformFeatures.isIosForTesting = true;
      expect(PlatformFeatures.hasAndroidSystemSettings, isFalse);
      expect(PlatformFeatures.hasPerAppRouting, isFalse);
      expect(PlatformFeatures.canReadWifiName, isFalse);
      expect(PlatformFeatures.isPresetDisabled('unknown-traffic'), isTrue);
      expect(PlatformFeatures.isPresetDisabled('bittorrent'), isFalse);
      expect(PlatformFeatures.isPresetDisabled(''), isFalse);
    });
  });

  group('Unknown traffic preset in the built config', () {
    final shipped =
        jsonDecode(File('assets/wizard_template.json').readAsStringSync())
            as Map<String, dynamic>;
    final preset = SelectableRule.fromJson((shipped['selectable_rules'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((rule) => rule['preset_id'] == 'unknown-traffic'));
    final template = WizardTemplate(
      groupTemplates: GroupTemplates(
        direction: DirectionTemplate(
          include: const ['direct', 'auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        auto: AutoTemplate(
          options: const {'url': 'https://x', 'interval': '30s'},
        ),
        defaultDirections: [
          DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
        ],
      ),
      vars: const [],
      varSections: const [],
      config: {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
        ],
        'route': {'rules': []},
      },
      selectableRules: [preset],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

    Future<String> buildWithPreset() async {
      final result = await buildConfig(
        lists: const [],
        template: template,
        settings: BuildSettings(
          enabledGroups: const {'vpn-1', kAutoOutboundTag},
          coreBuildTags: kCoreBuildTags,
          customRules: [
            CustomRulePreset(
              name: 'Unknown traffic',
              presetId: 'unknown-traffic',
              orderNum: 1150,
            ),
          ],
        ),
      );
      return jsonEncode(result.config);
    }

    test('stays on Android', () async {
      PlatformFeatures.isIosForTesting = false;
      expect(await buildWithPreset(), contains('unknown-apps'));
    });

    test('is dropped on iOS', () async {
      PlatformFeatures.isIosForTesting = true;
      expect(await buildWithPreset(), isNot(contains('unknown-apps')));
    });
  });
}
