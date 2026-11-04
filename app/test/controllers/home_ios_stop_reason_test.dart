// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/platform_features.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => tempRoot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const unexpectedStop = 'The tunnel stopped unexpectedly.';

  late Directory tempDir;
  late HomeController controller;

  TunnelStatusEvent stopped({String? reason}) => TunnelStatusEvent(
        status: TunnelStatus.disconnected,
        raw: 'Stopped',
        errorReason: reason,
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_ios_stop_reason_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    messenger.setMockMethodCallHandler(methods, (call) async => null);
    controller = HomeController();
  });

  tearDown(() async {
    PlatformFeatures.isIosForTesting = null;
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    messenger.setMockMethodCallHandler(methods, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('iOS shows the reason a tunnel stopped while the app was closed', () {
    PlatformFeatures.isIosForTesting = true;
    expect(controller.state.tunnel, TunnelStatus.disconnected);

    controller.debugHandleStatusEvent(stopped(reason: unexpectedStop));

    expect(controller.state.lastStartError, contains(unexpectedStop));
    expect(controller.state.lastError, isNotNull);
  });

  test('a repeated Stopped on Android stays ignored', () {
    PlatformFeatures.isIosForTesting = false;

    controller.debugHandleStatusEvent(stopped(reason: unexpectedStop));

    expect(controller.state.lastStartError, isEmpty);
    expect(controller.state.lastError, isNull);
  });

  test('a Stopped with no reason shows nothing on iOS', () {
    PlatformFeatures.isIosForTesting = true;

    controller.debugHandleStatusEvent(stopped());

    expect(controller.state.lastStartError, isEmpty);
    expect(controller.state.lastError, isNull);
  });
}
