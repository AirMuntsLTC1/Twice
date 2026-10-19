import 'package:flutter_test/flutter_test.dart';
import 'package:twice/main.dart';

void main() {
  testWidgets('Twice displays email sign-in when not configured', (WidgetTester tester) async {
    await tester.pumpWidget(const TwiceApp());
    await tester.pump();

    expect(find.textContaining('email', skipOffstage: false), findsWidgets);
    expect(find.text('Continue with Google'), findsNothing);
  });
}
