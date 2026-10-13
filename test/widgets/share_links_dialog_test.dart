import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

const _editToken = 'ICR-EDIT-0000-0000-0000';
const _viewToken = 'ICR-VIEW-0000-0000-0000';

ShareMember _member(
  String id,
  String name, {
  String role = 'viewer',
  String? token,
  String? folder,
}) =>
    ShareMember(
      memberId: id,
      displayName: name,
      avatarUrl: null,
      role: role,
      joinedAt: DateTime.now().subtract(const Duration(days: 2)),
      shareLinkToken: token,
      inheritedFromFolderName: folder,
    );

class _ShareRepository extends Fake implements ConvexStrategyRepository {
  _ShareRepository(this.members);

  List<ShareMember> members;
  bool failMembers = false;
  bool failRoleChange = false;
  final List<String> roleChanges = [];
  final List<String> removed = [];
  final List<(String, bool)> revoked = [];

  @override
  Future<List<ShareLinkSummary>> listShareLinks({
    required String targetType,
    required String targetPublicId,
  }) async =>
      [
        ShareLinkSummary(
          token: _editToken,
          role: 'editor',
          createdAt: DateTime.now().subtract(const Duration(days: 4)),
        ),
        ShareLinkSummary(
          token: _viewToken,
          role: 'viewer',
          createdAt: DateTime.now().subtract(const Duration(hours: 3)),
        ),
      ];

  @override
  Future<List<ShareMember>> listShareMembers({
    required String targetType,
    required String targetPublicId,
  }) async {
    if (failMembers) throw Exception('shares:listMembers is not deployed');
    return members;
  }

  @override
  Future<void> setShareMemberRole({
    required String targetType,
    required String targetPublicId,
    required String memberId,
    required String role,
  }) async {
    roleChanges.add('$memberId:$role');
    if (failRoleChange) throw Exception('Forbidden');
    members = [
      for (final m in members)
        m.memberId == memberId
            ? _member(m.memberId, m.displayName!,
                role: role, token: m.shareLinkToken)
            : m,
    ];
  }

  @override
  Future<void> removeShareMember({
    required String targetType,
    required String targetPublicId,
    required String memberId,
  }) async {
    removed.add(memberId);
    members = members.where((m) => m.memberId != memberId).toList();
  }

  @override
  Future<void> revokeShareLink({
    required String targetType,
    required String targetPublicId,
    required String token,
    bool removeMembers = false,
  }) async {
    revoked.add((token, removeMembers));
  }
}

class _SignedInAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

Future<_ShareRepository> _pumpDialog(
  WidgetTester tester, {
  void Function(_ShareRepository)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = _ShareRepository([
    _member('m-vex', 'Vex', role: 'editor', token: _editToken),
    _member('m-kyra', 'Kyra', role: 'editor', token: _editToken),
    _member('m-ren', 'Renyxx', token: _viewToken),
    _member('m-folder', 'Mav', role: 'editor', folder: 'Team plans'),
  ]);
  setUp?.call(repository);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(_SignedInAuth.new),
      ],
      child: const ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(
            body: Center(
              child: ShareLinksDialog(
                targetType: 'strategy',
                targetPublicId: 'strategy-1',
                title: 'Ascent B retake',
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  testWidgets('people come first; folder members carry no controls',
      (tester) async {
    await _pumpDialog(tester);

    final people = tester.getTopLeft(find.text('People with access')).dy;
    final links = tester.getTopLeft(find.text('Active links')).dy;
    expect(people, lessThan(links));

    expect(find.text('Joined through an edit link · 2d ago'), findsNWidgets(2));
    expect(find.text('Joined through a view link · 2d ago'), findsOneWidget);
    expect(find.text('Through the folder "Team plans"'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-member-remove-m-vex')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('share-member-remove-m-folder')),
        findsNothing);
    expect(find.text('Created 4d ago · 2 joined'), findsOneWidget);
    expect(find.text('Created 3h ago · 1 joined'), findsOneWidget);
  });

  testWidgets('removing someone asks first, then removes only them',
      (tester) async {
    final repository = await _pumpDialog(tester);

    await tester.tap(find.byKey(const ValueKey('share-member-remove-m-vex')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Vex?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-alert-confirm')));
    await tester.pumpAndSettle();

    expect(repository.removed, ['m-vex']);
    expect(find.text('Vex'), findsNothing);
    expect(find.text('Kyra'), findsOneWidget);
  });

  testWidgets(
      'disabling a link offers to remove who joined through it, on by default',
      (tester) async {
    final repository = await _pumpDialog(tester);

    await tester
        .tap(find.byKey(const ValueKey('share-link-disable-$_editToken')));
    await tester.pumpAndSettle();
    expect(find.text('Also remove the 2 people who joined through it'),
        findsOneWidget);
    expect(find.text('Vex, Kyra'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('share-link-disable-confirm')));
    await tester.pumpAndSettle();
    expect(repository.revoked, [(_editToken, true)]);

    // Unticked, the link stops and everyone stays.
    await tester
        .tap(find.byKey(const ValueKey('share-link-disable-$_viewToken')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('share-link-disable-remove-joined')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-link-disable-confirm')));
    await tester.pumpAndSettle();
    expect(repository.revoked.last, (_viewToken, false));
  });

  testWidgets('picking Can edit for a new link shows the warning',
      (tester) async {
    await _pumpDialog(tester);
    expect(find.byKey(const ValueKey('share-link-edit-warning')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('share-link-role-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Can edit').last);
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('share-link-edit-warning')), findsOneWidget);
  });

  testWidgets('a role change the server refuses shows the role it kept',
      (tester) async {
    final repository =
        await _pumpDialog(tester, setUp: (r) => r.failRoleChange = true);
    final row = find.byKey(const ValueKey('share-member-m-vex'));

    await tester.tap(find.descendant(of: row, matching: find.text('Can edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opens every page, changes nothing').last);
    await tester.pumpAndSettle();
    toastification.dismissAll(delayForAnimation: false);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(repository.roleChanges, ['m-vex:viewer']);
    expect(find.descendant(of: row, matching: find.text('Can edit')),
        findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Can view')),
        findsNothing);
  });

  testWidgets('without the people list, the links still work', (tester) async {
    await _pumpDialog(tester, setUp: (r) => r.failMembers = true);

    expect(find.text("Couldn't load who else has access."), findsOneWidget);
    expect(find.byKey(const ValueKey('share-link-disable-$_editToken')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('share-link-create-and-copy')),
        findsOneWidget);
  });
}
