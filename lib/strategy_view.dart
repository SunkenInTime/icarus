import 'package:flutter/widgets.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/sidebar.dart';
import 'package:icarus/widgets/save_and_load_button.dart';

class StrategyView extends StatelessWidget {
  const StrategyView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: InteractiveMap(),
        ),
        Align(
          alignment: Alignment.topLeft,
          child: SaveButtonAndLoad(),
        ),
        SideBarUI()
      ],
    );
  }
}
