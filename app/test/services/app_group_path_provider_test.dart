import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/app_group_path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _SystemPaths extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => '/system/tmp';

  @override
  Future<String?> getApplicationCachePath() async => '/system/cache';

  @override
  Future<String?> getLibraryPath() async => '/system/library';
}

void main() {
  late Directory group;
  late AppGroupPathProvider provider;

  setUp(() {
    group = Directory.systemTemp.createTempSync('app_group_paths');
    provider = AppGroupPathProvider(group.path, _SystemPaths());
  });

  tearDown(() => group.deleteSync(recursive: true));

  test('documents and support live under Library in the App Group', () async {
    expect(await provider.getApplicationDocumentsPath(),
        '${group.path}/Library/Documents');
    expect(await provider.getApplicationSupportPath(),
        '${group.path}/Library/Application Support');
  });

  test('createFolders makes both folders', () async {
    await provider.createFolders();
    expect(Directory('${group.path}/Library/Documents').existsSync(), isTrue);
    expect(Directory('${group.path}/Library/Application Support').existsSync(),
        isTrue);
  });

  test('other paths stay with the system provider', () async {
    expect(await provider.getTemporaryPath(), '/system/tmp');
    expect(await provider.getApplicationCachePath(), '/system/cache');
    expect(await provider.getLibraryPath(), '/system/library');
  });
}
