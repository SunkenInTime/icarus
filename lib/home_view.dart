import 'package:flutter/material.dart';
import 'package:icarus/widgets/folder_navigator.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  @override
  Widget build(BuildContext context) {
    return const FolderNavigator();
  }
}
