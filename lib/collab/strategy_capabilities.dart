class StrategyCapabilities {
  const StrategyCapabilities({
    required this.canRenameStrategy,
    required this.canDeleteStrategy,
    required this.canDuplicateStrategy,
    required this.canMoveStrategy,
    required this.canEditPages,
    required this.canAddPage,
    required this.canRenamePage,
    required this.canDeletePage,
    required this.canReorderPages,
    required this.canCreateFolder,
    required this.canEditFolder,
    required this.canDeleteFolder,
    required this.canMoveFolder,
  });

  final bool canRenameStrategy;
  final bool canDeleteStrategy;
  final bool canDuplicateStrategy;
  final bool canMoveStrategy;
  final bool canEditPages;
  final bool canAddPage;
  final bool canRenamePage;
  final bool canDeletePage;
  final bool canReorderPages;
  final bool canCreateFolder;
  final bool canEditFolder;
  final bool canDeleteFolder;
  final bool canMoveFolder;

  factory StrategyCapabilities.fullAccess() {
    return const StrategyCapabilities(
      canRenameStrategy: true,
      canDeleteStrategy: true,
      canDuplicateStrategy: true,
      canMoveStrategy: true,
      canEditPages: true,
      canAddPage: true,
      canRenamePage: true,
      canDeletePage: true,
      canReorderPages: true,
      canCreateFolder: true,
      canEditFolder: true,
      canDeleteFolder: true,
      canMoveFolder: true,
    );
  }

  factory StrategyCapabilities.fromCloudRole(String? role) {
    final normalized = role ?? 'viewer';
    final canEdit = normalized == 'owner' || normalized == 'editor';
    final isOwner = normalized == 'owner';
    return StrategyCapabilities(
      canRenameStrategy: canEdit,
      canDeleteStrategy: isOwner,
      canDuplicateStrategy: canEdit,
      canMoveStrategy: isOwner,
      canEditPages: canEdit,
      canAddPage: canEdit,
      canRenamePage: canEdit,
      canDeletePage: canEdit,
      canReorderPages: canEdit,
      canCreateFolder: isOwner,
      canEditFolder: isOwner,
      canDeleteFolder: isOwner,
      canMoveFolder: isOwner,
    );
  }
}
