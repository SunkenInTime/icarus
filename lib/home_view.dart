import 'package:flutter/material.dart';
import 'package:icarus/strategy_manager.dart';
import 'package:icarus/strategy_view.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  @override
  Widget build(BuildContext context) {
    return const StrategyManager();
    // return const StrategyView();
  }
}
