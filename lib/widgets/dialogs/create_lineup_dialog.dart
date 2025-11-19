import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/strategy/line_up_media_page.dart';
import 'package:icarus/widgets/dialogs/strategy/line_up_selection.dart';

class CreateLineupDialog extends ConsumerStatefulWidget {
  const CreateLineupDialog({super.key});

  @override
  ConsumerState<CreateLineupDialog> createState() => _CreateLineupDialogState();
}

class _CreateLineupDialogState extends ConsumerState<CreateLineupDialog> {
  int _currentPage = 0;
  AgentData? _selectedAgent;
  AbilityInfo? _selectedAbility;
  final TextEditingController _youtubeLinkController = TextEditingController();

  @override
  void dispose() {
    _youtubeLinkController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_selectedAgent != null && _selectedAbility != null) {
      setState(() {
        _currentPage = 1;
      });
    }
  }

  void _prevPage() {
    setState(() {
      _currentPage = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isNextEnabled =
        _selectedAgent != null && _selectedAbility != null;

    return AlertDialog(
      backgroundColor: Settings.sideBarColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Settings.highlightColor, width: 2),
      ),
      titlePadding: const EdgeInsets.all(16),
      title: const _DialogHeader(),
      content: SizedBox(
        width: 600,
        height: 404,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: _currentPage == 0
              ? LineupSelectionPage(
                  selectedAgent: _selectedAgent,
                  selectedAbility: _selectedAbility,
                  onAgentSelected: (agent) {
                    setState(() {
                      _selectedAgent = agent;
                      _selectedAbility = null;
                    });
                  },
                  onAbilitySelected: (ability) {
                    setState(() {
                      _selectedAbility = ability;
                    });
                  },
                )
              : LineupMediaPage(
                  youtubeLinkController: _youtubeLinkController,
                  imagePaths: const [
                    "assets/agents/Astra/1.webp",
                    "assets/agents/Astra/2.webp",
                    "assets/agents/Astra/3.webp",
                  ],
                  onAddImage: () {},
                  onRemoveImage: (index) {},
                ),
        ),
      ),
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_currentPage == 1) ...[
              CustomButton(
                onPressed: _prevPage,
                height: 40,
                width: 100,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                label: "Back",
                backgroundColor: Colors.grey.shade800,
              ),
              const SizedBox(width: 16),
            ],
            if (_currentPage == 0)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                child: CustomButton(
                  onPressed: isNextEnabled ? _nextPage : null,
                  height: 40,
                  width: 100,
                  label: "Next",
                  isIconRight: true,
                  icon: const Icon(Icons.arrow_forward, color: Colors.white),
                  // Explicitly set grey if disabled, otherwise purple
                  backgroundColor: isNextEnabled
                      ? Colors.deepPurpleAccent
                      : Colors.grey.withOpacity(0.3),
                  labelColor: isNextEnabled ? Colors.white : Colors.white38,
                ),
              )
            else
              CustomButton(
                onPressed: () {
                  // TODO: Implement creation logic
                  Navigator.of(context).pop();
                },
                height: 40,
                width: 100,
                label: "Done",
                icon: const Icon(Icons.check, color: Colors.white),
                backgroundColor: Colors.deepPurpleAccent,
              ),
          ],
        ),
      ],
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text("Create Line Up", style: TextStyle(color: Colors.white)),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, color: Colors.white),
          tooltip: "Close",
        ),
      ],
    );
  }
}

class _LineupMediaPage extends StatelessWidget {
  final TextEditingController youtubeLinkController;

  const _LineupMediaPage({
    required this.youtubeLinkController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Youtube link", style: TextStyle(color: Colors.white)),
        const SizedBox(height: 8),
        CustomTextField(
          controller: youtubeLinkController,
          hintText: "Paste YouTube link here...",
        ),
        const SizedBox(height: 24),
        Expanded(
          child: GestureDetector(
            onTap: () {
              // Placeholder for image picking
            },
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Settings.abilityBGColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Settings.highlightColor),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined,
                      size: 48, color: Colors.white54),
                  SizedBox(height: 8),
                  Text(
                    "Click here to add image",
                    style: TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
