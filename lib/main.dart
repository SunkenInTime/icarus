import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/home_view.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_manager.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await getApplicationSupportDirectory();
  await Hive.initFlutter(directory.path);

  Hive.registerAdapters();

  await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    title: "Icarus: Valorant Strategies & Line ups",
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GlobalShortcuts(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Icarus',
        theme: ThemeData(
            colorScheme: const ColorScheme.dark(
              // primary: Color.fromARGB(255, 129, 75, 223),
              primary: Colors.deepPurpleAccent,
              secondary: Colors.teal,
              error: Colors.red,
              surface: Color(0xFF1B1B1B),
            ),
            dividerColor: Colors.transparent,
            useMaterial3: true,
            expansionTileTheme: const ExpansionTileThemeData(),
            textButtonTheme: TextButtonThemeData(
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
                // You can also set other properties like textStyle here if needed
                // textStyle: MaterialStateProperty.all<TextStyle>(
                //   const TextStyle(color: Colors.white),
                // ),
              ),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
                // You can also set other properties like textStyle here if needed
                // textStyle: MaterialStateProperty.all<TextStyle>(
                //   const TextStyle(color: Colors.white),
                // ),
              ),
            )),
        routes: {
          Routes.strategyManager: (context) => const StrategyManager(),
          Routes.strategyView: (context) => const StrategyView(),
        },
        home: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends ConsumerWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const HomeView();
  }
}
