import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';

class CustomSquareWidget extends StatelessWidget {
  const CustomSquareWidget(
      {super.key, required this.color, required this.abilityInfo});

  final Color color;
  final AbilityInfo abilityInfo;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;

    return Column(
      children: [
        SizedBox(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 20,
              height: 20,
              color: Colors.white,
            ),
            onTap: () {
              log("u");
            },
            onPanStart: (details) => {},
            onPanEnd: (details) => {},
            onPanUpdate: (details) => {},
          ),
        ),
        IgnorePointer(
          child: Container(
            width: 200,
            height: 100,
            color: Colors.red,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: coordinateSystem.scale(25),
            height: coordinateSystem.scale(25),
            padding: EdgeInsets.all(coordinateSystem.scale(3)),
            decoration: const BoxDecoration(
              color: Color(0xFF1B1B1B),
            ),
            child: Image.asset(
              abilityInfo.iconPath,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }
}
