import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/probe/probe_lifecycle.dart';
import 'package:lxbox/services/probe/probe_runner.dart';

import '../parser/engine_test_setup.dart';
import 'probe_session_fake.dart';

NodeSpec _vless(String tag) => VlessSpec(
      id: tag,
      tag: tag,
      label: tag,
      server: '$tag.example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

Future<void> _until(bool Function() cond, {String what = ''}) async {
  for (var i = 0; i < 500 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(cond(), isTrue, reason: 'never happened: $what');
}

void main() {
  setUpAll(loadEngineSections);
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeProbeSession fake;
  final nodes = [for (var i = 1; i <= 8; i++) _vless('n$i')];

  Future<String> runOnce(ProbeRunner runner) => runner
      .run(nodes, url: '', timeoutMs: 0, onResult: (_, _) {})
      .timeout(const Duration(seconds: 2));

  setUp(() {
    fake = FakeProbeSession();
    messenger.setMockMethodCallHandler(channel, fake.handle);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a thrown probeStart ends the run with its error text', () async {
    fake.throwingMethods.add('probeStart');

    final err = await runOnce(ProbeRunner());

    expect(err, contains('probeStart failed'));
    expect(fake.callsOf('probeUrlTest'), 0);
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('a missing plugin ends the run with an error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCoreVersion') return 'v1.14.4-lx.30';
      throw MissingPluginException('No implementation for ${call.method}');
    });

    final err = await runOnce(ProbeRunner());

    expect(err, contains('No implementation found for method probeStart'));
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('a thrown probeUrlTest stops other workers and closes the session',
      () async {
    final results = <int, ProbeResult>{};
    final runner = ProbeRunner(concurrency: 6);
    final done = runner.run(nodes,
        url: '', timeoutMs: 0, onResult: (i, r) => results[i] = r);
    await _until(() => fake.pendingCount == 6, what: '6 tests in flight');

    fake.throwingMethods.add('probeUrlTest');
    fake.holdUrlTests = false;
    fake.releaseOk();
    final err = await done.timeout(const Duration(seconds: 2));

    expect(err, contains('probeUrlTest failed'));
    expect(fake.runIdsOf('probeCancel'), contains(1));
    expect(fake.runIdsOf('probeStop'), [1]);
    expect(fake.live, isNull);
    expect(results.values.map((r) => r.status),
        isNot(contains(ProbeStatus.failed)));
  });

  test('a thrown probeStop ends the run with its error text', () async {
    fake
      ..holdUrlTests = false
      ..throwingMethods.add('probeStop');

    final err = await runOnce(ProbeRunner());

    expect(err, contains('probeStop failed'));
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('Stop ends the run with an error when probeStart never replies',
      () async {
    fake.startGate = Completer<void>();
    final runner = ProbeRunner(stopDeadline: const Duration(milliseconds: 20));
    final done = runner.run(nodes, url: '', timeoutMs: 0, onResult: (_, _) {});
    await _until(() => fake.callsOf('probeStart') == 1,
        what: 'probeStart in flight');

    runner.cancel();
    final err = await done.timeout(const Duration(seconds: 2));

    expect(err, contains('timeout'));
    expect(ProbeLifecycle.I.isProbing, isFalse);

    fake.startGate!.complete();
    await _until(() => fake.callsOf('probeStop') == 1,
        what: 'late session closed');
    expect(fake.live, isNull);
    expect(fake.callsOf('probeUrlTest'), 0);
  });

  test('Stop ends the run with an error when a test never replies', () async {
    final runner = ProbeRunner(
      concurrency: 6,
      stopDeadline: const Duration(milliseconds: 20),
    );
    messenger.setMockMethodCallHandler(channel, (call) {
      if (call.method == 'probeUrlTest' || call.method == 'probeCancel') {
        fake.calls.add(call);
        return Completer<Object?>().future;
      }
      return fake.handle(call);
    });
    final done = runner.run(nodes, url: '', timeoutMs: 0, onResult: (_, _) {});
    await _until(() => fake.callsOf('probeUrlTest') == 6,
        what: '6 tests in flight');

    runner.cancel();
    final err = await done.timeout(const Duration(seconds: 2));

    expect(err, contains('timeout'));
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('a session closed by core Start leaves untested nodes without a verdict',
      () async {
    final results = <int, ProbeResult>{};
    final runner = ProbeRunner(concurrency: 6);
    final done = runner.run(nodes,
        url: '', timeoutMs: 0, onResult: (i, r) => results[i] = r);
    await _until(() => fake.pendingCount == 6, what: '6 tests in flight');
    fake.releaseOk();
    await _until(() => fake.pendingCount == 2, what: 'last 2 tests in flight');

    fake.closeForCoreStart();
    final err = await done.timeout(const Duration(seconds: 2));

    expect(err, isEmpty);
    expect(results.length, 6);
    expect(results.values.every((r) => r.status == ProbeStatus.ok), isTrue);
    expect(fake.callsOf('probeStart'), 1);
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('cancel() before a run does not abandon that run', () async {
    fake.holdUrlTests = false;
    final runner = ProbeRunner(stopDeadline: const Duration(milliseconds: 1));

    runner.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(await runOnce(runner), isEmpty);
    expect(fake.callsOf('probeUrlTest'), 8);
  });
}
