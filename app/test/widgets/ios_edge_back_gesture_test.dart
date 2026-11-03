import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/ios_edge_back_gesture.dart';

void main() {
  late NavigatorObserver observer;
  late int backAttempts;

  Widget guarded(String label) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) backAttempts++;
        },
        child: Scaffold(body: Text(label)),
      );

  Future<void> pumpApp(WidgetTester tester, {Widget? home}) async {
    backAttempts = 0;
    observer = NavigatorObserver();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      navigatorObservers: [observer],
      builder: (_, child) =>
          IosEdgeBackGesture(observer: observer, child: child!),
      home: home ?? const Scaffold(body: Text('home')),
    ));
  }

  Future<void> push(WidgetTester tester, Widget page) async {
    observer.navigator!.push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  Future<void> swipe(WidgetTester tester, double fromX, double distance) async {
    await tester.dragFrom(Offset(fromX, 300), Offset(distance, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('edge swipe runs the back handler of a guarded screen',
      (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('guarded'));

    await swipe(tester, 5, 200);

    expect(backAttempts, 1);
    expect(find.text('guarded'), findsOneWidget);
  });

  testWidgets('short swipe does nothing', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('guarded'));

    await swipe(tester, 5, 40);

    expect(backAttempts, 0);
  });

  testWidgets('swipe away from the edge does nothing', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('guarded'));

    await swipe(tester, 100, 200);

    expect(backAttempts, 0);
  });

  testWidgets('first route does nothing', (tester) async {
    await pumpApp(tester, home: guarded('home'));

    await swipe(tester, 5, 200);

    expect(backAttempts, 0);
  });

  testWidgets('dialog on top does nothing', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('guarded'));
    showDialog<void>(
      context: observer.navigator!.context,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();

    await swipe(tester, 5, 200);

    expect(backAttempts, 0);
    expect(find.text('dialog'), findsOneWidget);
  });

  testWidgets('unguarded screen keeps the native swipe', (tester) async {
    await pumpApp(tester);
    await push(tester, const Scaffold(body: Text('plain')));

    await swipe(tester, 5, 700);

    expect(find.text('plain'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
