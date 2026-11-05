import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/network_choice.dart';
import 'package:lxbox/screens/custom_rule_edit/sections/wifi_section.dart';
import 'package:lxbox/widgets/wifi_entry.dart';

void main() {
  Future<void> pumpSection(
    WidgetTester tester, {
    NetworkChoice choice = NetworkChoice.wifi,
    List<WifiEntry> networks = const [],
  }) async {
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

  testWidgets('shows the list of networks under Wi-Fi', (tester) async {
    await pumpSection(tester, networks: const [homeNetwork]);

    expect(find.text('HomeWiFi'), findsOneWidget);
    expect(find.text('Add current'), findsOneWidget);
    expect(find.text('Pick saved'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Metered networks only'), findsOneWidget);
  });

  testWidgets('hides the list under other network types', (tester) async {
    await pumpSection(tester, choice: NetworkChoice.cellular);

    expect(find.text('Add current'), findsNothing);
  });
}
