import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/folder_detail_screen.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../parser/engine_test_setup.dart';
import '../probe/probe_session_fake.dart';

Future<void> _until(WidgetTester tester, bool Function() cond,
    {String what = ''}) async {
  await tester.pump();
  for (var i = 0; i < 300 && !cond(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(cond(), isTrue, reason: 'never happened: $what');
  await tester.pump();
}

void main() {
  setUpAll(loadEngineSections);

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ppChannel = MethodChannel('plugins.flutter.io/path_provider');
  late FakeProbeSession fake;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_folder_probe_');
    fake = FakeProbeSession();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(ppChannel, (call) async => tmp.path);
    m.setMockMethodCallHandler(methods, fake.handle);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(ppChannel, null);
    m.setMockMethodCallHandler(methods, null);
    SettingsStorage.resetCacheForTesting();
    await tmp.delete(recursive: true);
  });

  testWidgets('a thrown probeStart shows the error and Start comes back',
      (tester) async {
    fake.throwingMethods.add('probeStart');
    final entry = SubscriptionEntry(
      list: FolderServers(
        id: 'folder-1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: 'vless://u1@h1.example:443?type=ws&security=tls#Alpha'),
        ],
      ),
    );
    final c = SubscriptionController()..debugSetEntries([entry]);
    await tester.pumpWidget(MaterialApp(
      home: FolderDetailScreen(entry: entry, controller: c),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.speed));
    await _until(tester, () => fake.callsOf('probeStart') == 1,
        what: 'probeStart called');
    await _until(tester, () => find.byIcon(Icons.speed).evaluate().isNotEmpty,
        what: 'Start available again');

    expect(find.textContaining('probeStart failed'), findsOneWidget);
    expect(find.textContaining('Testing…'), findsNothing);
    expect(find.text('Stopping…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 20));
  });
}
