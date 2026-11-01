import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/custom_search_field.dart';

void main() {
  testWidgets('a rebuilt search field shows the search still in force',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // What keeps the search alive in the app: the library reading it.
    final library = container.listen(strategySearchQueryProvider, (_, __) {});
    addTearDown(library.close);
    container.read(strategySearchQueryProvider.notifier).update('Corrode');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SearchTextField())),
      ),
    );

    expect(find.text('Corrode'), findsOneWidget);
    expect(container.read(strategySearchQueryProvider), 'Corrode');
  });
}
