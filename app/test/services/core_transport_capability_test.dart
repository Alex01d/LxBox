import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/core_transport_capability.dart';
import 'package:lxbox/vpn/box_vpn_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(CoreTransportCapability.resetForTest);

  test(
    'AWG requires positive native capability evidence, not a release name',
    () async {
      expect(
        await CoreTransportCapability.ensureTags(() async => null),
        isNot(contains('with_tailscale_awg')),
      );
      expect(
        await CoreTransportCapability.ensureTags(
          () async => {'with_tailscale_awg': true},
        ),
        contains('with_tailscale_awg'),
      );
      expect(
        await CoreTransportCapability.ensureTags(
          () async => throw StateError('busy'),
        ),
        contains('with_tailscale_awg'),
      );
    },
  );

  test('old AAR false stays false and unknown probes can retry', () async {
    expect(
      await CoreTransportCapability.ensureTags(
        () async => throw StateError('unavailable'),
      ),
      isNot(contains('with_tailscale_awg')),
    );
    expect(
      await CoreTransportCapability.ensureTags(
        () async => {'with_tailscale_awg': false},
      ),
      isNot(contains('with_tailscale_awg')),
    );
  });

  test('native bridge decodes only boolean capabilities', () async {
    const channel = MethodChannel('lxbox/awg-capability-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getCoreCapabilities');
          return {'with_tailscale_awg': true, 'untrusted': 'true'};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    expect(await BoxVpnClient.forTest(methods: channel).getCoreCapabilities(), {
      'with_tailscale_awg': true,
    });
  });
}
