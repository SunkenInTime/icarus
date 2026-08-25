import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('browser beta copy describes the supported cloud path',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: ShadApp(
          home: DemoDialog(),
        ),
      ),
    );

    expect(find.text('Browser beta'), findsOneWidget);
    expect(
      find.textContaining('cloud library and shared strategies'),
      findsOneWidget,
    );
    expect(find.text('Download app'), findsOneWidget);
    expect(find.textContaining('Microsoft Store'), findsNothing);
  });
}
