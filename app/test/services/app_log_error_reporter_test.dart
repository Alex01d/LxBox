// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/services/app_log.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  late List<(String, DebugSource)> reported;

  setUp(() {
    AppLog.I.resetForTesting();
    reported = [];
    AppLog.I.errorReporter =
        (message, source) => reported.add((message, source));
  });

  tearDown(() => AppLog.I.resetForTesting());

  test('app error entry is reported with its source', () {
    AppLog.I.error('addWarp failed: timeout');

    expect(reported, [('addWarp failed: timeout', DebugSource.app)]);
  });

  test('core batch reports only its error lines', () {
    AppLog.I.logBatch(
      ['ERROR dial tcp: refused', 'INFO started', 'WARN slow'],
      (line) => line.startsWith('ERROR') ? DebugLevel.error : DebugLevel.info,
      source: DebugSource.core,
    );

    expect(reported, [('ERROR dial tcp: refused', DebugSource.core)]);
  });

  test('warnings and lower levels are not reported', () {
    AppLog.I.warning('slow');
    AppLog.I.info('fine');
    AppLog.I.debug('detail');

    expect(reported, isEmpty);
  });

  test('already reported error stays in AppLog but is not reported again', () {
    AppLog.I.error('Uncaught async: boom', alreadyReported: true);

    expect(reported, isEmpty);
    expect(AppLog.I.entriesForSource(DebugSource.app).single.message,
        'Uncaught async: boom');
  });

  test('errors from the previous session are not reported', () async {
    final dir = await Directory.systemTemp.createTemp('applog_reporter');
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final line = jsonEncode({
      'time': DateTime(2026, 11, 6).toIso8601String(),
      'source': 'app',
      'level': 'error',
      'message': 'old failure',
    });
    await File('${dir.path}/applog.txt').writeAsString('$line\n');

    await AppLog.I.initPersistent();

    expect(AppLog.I.entriesForSource(DebugSource.app).single.message,
        'old failure');
    expect(reported, isEmpty);
  });
}
