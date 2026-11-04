import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../vpn/box_vpn_client.dart';
import 'platform_features.dart';

class AppGroupPathProvider extends PathProviderPlatform {
  AppGroupPathProvider(String groupPath, this._system)
      : _documents = '$groupPath/Library/Documents',
        _support = '$groupPath/Library/Application Support';

  final PathProviderPlatform _system;
  final String _documents;
  final String _support;

  Future<void> createFolders() async {
    await Directory(_documents).create(recursive: true);
    await Directory(_support).create(recursive: true);
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => _documents;

  @override
  Future<String?> getApplicationSupportPath() async => _support;

  @override
  Future<String?> getTemporaryPath() => _system.getTemporaryPath();

  @override
  Future<String?> getLibraryPath() => _system.getLibraryPath();

  @override
  Future<String?> getApplicationCachePath() => _system.getApplicationCachePath();

  @override
  Future<String?> getExternalStoragePath() => _system.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() => _system.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _system.getExternalStoragePaths(type: type);

  @override
  Future<String?> getDownloadsPath() => _system.getDownloadsPath();
}

Future<void> useAppGroupFoldersOnIos() async {
  if (!PlatformFeatures.isIos) return;
  final groupPath = await BoxVpnClient().getAppGroupPath();
  if (groupPath == null || groupPath.isEmpty) return;
  final provider = AppGroupPathProvider(groupPath, PathProviderPlatform.instance);
  await provider.createFolders();
  PathProviderPlatform.instance = provider;
}
