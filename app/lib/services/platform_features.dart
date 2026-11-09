import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

class PlatformFeatures {
  PlatformFeatures._();

  static const _unknownTrafficPreset = 'unknown-traffic';

  @visibleForTesting
  static bool? isIosForTesting;

  static bool get isIos => isIosForTesting ?? Platform.isIOS;

  static bool get hasAndroidSystemSettings => !isIos;

  static bool get hasPerAppRouting => !isIos;

  static bool get canFindConnectionOwner => !isIos;

  static bool isPresetDisabled(String presetId) =>
      isIos && presetId == _unknownTrafficPreset;
}
