import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../models/debug_entry.dart';
import 'app_log.dart';
import 'url_mask.dart';

abstract final class CrashReporting {
  static const _dsn = String.fromEnvironment('SENTRY_DSN');

  static bool get isEnabled => Platform.isIOS && _dsn.isNotEmpty;

  static Future<void> start() async {
    if (!isEnabled) return;
    try {
      await SentryFlutter.init((options) {
        options.dsn = _dsn;
        options.replay.onErrorSampleRate = 1.0;
        options.beforeSend = (event, hint) => maskEvent(event);
        options.beforeBreadcrumb = (breadcrumb, hint) =>
            breadcrumb == null ? null : maskBreadcrumb(breadcrumb);
      });
      AppLog.I.errorReporter = _reportLoggedError;
    } catch (e) {
      AppLog.I.error('Sentry start failed: $e');
    }
  }

  static Widget wrap(Widget app) => isEnabled ? SentryWidget(child: app) : app;

  static SentryEvent maskEvent(SentryEvent event) {
    final message = event.message;
    if (message != null) message.formatted = maskSecrets(message.formatted);
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      final value = exception.value;
      if (value != null) exception.value = maskSecrets(value);
    }
    for (final breadcrumb in event.breadcrumbs ?? const <Breadcrumb>[]) {
      maskBreadcrumb(breadcrumb);
    }
    return event;
  }

  static Breadcrumb maskBreadcrumb(Breadcrumb breadcrumb) {
    final message = breadcrumb.message;
    if (message != null) breadcrumb.message = maskSecrets(message);
    return breadcrumb;
  }

  static void _reportLoggedError(String message, DebugSource source) {
    unawaited(Sentry.captureMessage(
      message,
      level: SentryLevel.error,
      withScope: (scope) => scope.setTag('log_source', source.name),
    ));
  }
}
