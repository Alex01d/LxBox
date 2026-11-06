import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:lxbox/services/crash_reporting.dart';

void main() {
  test('event message, exception values and breadcrumbs are masked', () {
    final event = SentryEvent(
      message: SentryMessage('GET https://sub.example.com/abc?token=x failed'),
      exceptions: [
        SentryException(type: 'SocketException', value: 'dial tcp 1.2.3.4:443'),
      ],
      breadcrumbs: [
        Breadcrumb(message: 'uuid b831381d-6324-4d53-ad4f-8cda48b30811'),
      ],
    );

    final masked = CrashReporting.maskEvent(event);

    expect(masked.message!.formatted, 'GET https://sub.example.com/*** failed');
    expect(masked.exceptions!.single.value, 'dial tcp ***:443');
    expect(masked.breadcrumbs!.single.message, 'uuid ***');
  });

  test('event without message, exceptions or breadcrumbs passes through', () {
    final event = SentryEvent();

    expect(CrashReporting.maskEvent(event), same(event));
  });

  test('breadcrumb is masked as it is added', () {
    final breadcrumb = Breadcrumb(message: 'open vless://secret@1.2.3.4:443');

    expect(CrashReporting.maskBreadcrumb(breadcrumb).message, 'open vless://***');
  });
}
