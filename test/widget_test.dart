import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


import 'package:simple_flutterble/main.dart' as app;

void main() {
  testWidgets('Can build app and find Water Pump button', (WidgetTester tester) async {
    app.main(isTest: true); 
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('btn:Water Pump On'));
    expect(button, findsOneWidget);
  });
}
