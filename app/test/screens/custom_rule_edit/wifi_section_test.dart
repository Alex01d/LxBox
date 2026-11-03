import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/network_choice.dart';
import 'package:lxbox/screens/custom_rule_edit/sections/wifi_section.dart';
import 'package:lxbox/services/platform_features.dart';
import 'package:lxbox/widgets/wifi_entry.dart';

void main() {
  tearDown(() => PlatformFeatures.isIosForTesting = null);

  Future<void> pumpSection(
    WidgetTester tester, {
    required bool ios,
    NetworkChoice choice = NetworkChoice.wifi,
    List<WifiEntry> networks = const [],
  }) async {
    PlatformFeatures.isIosForTesting = ios;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WifiSection(
            choice: choice,
            onChoiceChanged: (_) {},
            metered: false,
            onMeteredChanged: (_) {},
            networks: networks,
            onRemoveAt: (_) {},
            onAddCurrent: () {},
            onPickSaved: () {},
            onManual: () {},
            onTapPermissionsHint: () {},
            hint: WifiHint.preciseLocation,
          ),
        ),
      ),
    ));
  }

  const homeNetwork = WifiEntry('HomeWiFi', '');

  testWidgets('Android shows the list of networks under Wi-Fi', (tester) async {
    await pumpSection(tester, ios: false, networks: const [homeNetwork]);

    expect(find.text('HomeWiFi'), findsOneWidget);
    expect(find.text('Add current'), findsOneWidget);
    expect(find.text('Pick saved'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
  });

  testWidgets('iOS hides the list and keeps network type and metered',
      (tester) async {
    await pumpSection(tester, ios: true, networks: const [homeNetwork]);

    expect(find.text('HomeWiFi'), findsNothing);
    expect(find.text('Add current'), findsNothing);
    expect(find.text('Pick saved'), findsNothing);
    expect(find.text('Manual'), findsNothing);
    expect(find.text('Precise location permission missing'), findsNothing);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Cellular'), findsOneWidget);
    expect(find.text('Metered networks only'), findsOneWidget);
  });

  testWidgets('Android hides the list under other network types',
      (tester) async {
    await pumpSection(tester, ios: false, choice: NetworkChoice.cellular);

    expect(find.text('Add current'), findsNothing);
  });
}
