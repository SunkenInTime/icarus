import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';

sealed class LibraryDragItem {
  const LibraryDragItem(this.id);

  final String id;
}

class FolderDragItem extends LibraryDragItem {
  const FolderDragItem(super.id);
}

class StrategyDragItem extends LibraryDragItem {
  const StrategyDragItem(super.id);
}

class LibraryPathItemData {
  const LibraryPathItemData({
    required this.id,
    required this.name,
  });

  final String? id;
  final String name;
}

class LibraryFolderItemData {
  const LibraryFolderItemData({
    required this.id,
    required this.name,
    required this.icon,
    required this.backgroundColor,
  });

  final String id;
  final String name;
  final IconData icon;
  final Color backgroundColor;
}

class LibraryStrategyItemData {
  const LibraryStrategyItemData({
    required this.id,
    required this.name,
    required this.mapName,
    required this.thumbnailAsset,
    required this.statusLabel,
    required this.statusColor,
    required this.updatedLabel,
    this.badgeLabel,
    this.agentTypes = const [],
  });

  final String id;
  final String name;
  final String mapName;
  final String thumbnailAsset;
  final String statusLabel;
  final Color statusColor;
  final String updatedLabel;
  final String? badgeLabel;
  final List<AgentType> agentTypes;
}
