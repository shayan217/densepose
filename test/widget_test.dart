import 'package:dense_pose/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows pose camera controls', (WidgetTester tester) async {
    await tester.pumpWidget(const PoseApp(cameras: []));
    await tester.pump();

    expect(find.text('Pose backend WebSocket'), findsOneWidget);
    expect(find.byIcon(Icons.accessibility_new), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });
}
