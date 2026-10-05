import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeleteFolderAlertDialog extends ConsumerStatefulWidget {
  const DeleteFolderAlertDialog({
    super.key,
    required this.folder,
    required this.workspace,
  });

  final Folder folder;
  final LibraryWorkspace workspace;

  @override
  ConsumerState<DeleteFolderAlertDialog> createState() =>
      _DeleteFolderAlertDialogState();
}

class _DeleteFolderAlertDialogState
    extends ConsumerState<DeleteFolderAlertDialog> {
  bool _isDeleting = false;
  String? _failureMessage;

  Future<void> _delete() async {
    if (_isDeleting) return;
    setState(() {
      _isDeleting = true;
      _failureMessage = null;
    });

    CloudLibraryActionResult? result;
    try {
      result = await ref.read(folderProvider.notifier).deleteFolder(
            widget.folder.id,
            workspace: widget.workspace,
          );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to delete a library folder.',
        source: 'folder_dialog:delete',
        error: error,
        stackTrace: stackTrace,
        promptUser: false,
      );
      if (mounted) {
        setState(() {
          _failureMessage = "Couldn't delete this folder. Try again.";
        });
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
    if (!mounted) return;
    if (result?.didSucceed == true) {
      Navigator.of(context).pop();
      return;
    }
    if (result != null) {
      setState(() => _failureMessage =
          result!.userMessage ?? "Couldn't delete this folder. Try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog.alert(
      title: Text("Delete '${widget.folder.name}'?"),
      description: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This also removes every strategy and subfolder inside it.',
          ),
          if (_failureMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _failureMessage!,
              key: const ValueKey('delete-folder-failure'),
              style: TextStyle(
                color: Settings.tacticalVioletTheme.destructive,
              ),
            ),
          ],
        ],
      ),
      actions: [
        ShadButton.secondary(
          onPressed: _isDeleting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          key: const ValueKey('delete-folder-confirm'),
          onPressed: _isDeleting ? null : _delete,
          child: Text(_isDeleting ? 'Deleting...' : 'Delete'),
        ),
      ],
    );
  }
}
