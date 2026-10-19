import 'package:flutter_test/flutter_test.dart';
import 'package:twice/main.dart';

void main() {
  testWidgets('Twice displays Google sign-in when not configured',
      (WidgetTester tester) async {
    await tester.pumpWidget(const TwiceApp());
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Twice'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });
}
