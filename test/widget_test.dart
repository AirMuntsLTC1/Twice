import 'package:flutter_test/flutter_test.dart';
import 'package:twice/main.dart';

void main() {
  testWidgets('Twice displays its social feed and navigation',
      (WidgetTester tester) async {
    await tester.pumpWidget(const TwiceApp());

    expect(find.text('Twice'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('Create'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
  });
}
