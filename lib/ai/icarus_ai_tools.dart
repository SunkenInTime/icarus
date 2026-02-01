import 'package:firebase_ai/firebase_ai.dart';

class IcarusAiToolNames {
  static const getVisibleRound = 'get_visible_round';
  static const getActivePage = 'get_active_page';
  static const getRoster = 'get_roster';
  static const getRoundKills = 'get_round_kills';
  static const takeCurrentScreenshot = 'take_current_screenshot';
}

List<Tool> buildIcarusAiTools() {
  return [
    Tool.functionDeclarations([
      FunctionDeclaration(
        IcarusAiToolNames.getVisibleRound,
        'Get which Valorant round is currently selected/visible.',
        parameters: {},
      ),
      FunctionDeclaration(
        IcarusAiToolNames.getActivePage,
        'Get the currently active page and its match metadata if available.',
        parameters: {},
      ),
      FunctionDeclaration(
        IcarusAiToolNames.getRoster,
        'Get the match roster and which players are allies vs enemies.',
        parameters: {},
      ),
      FunctionDeclaration(
        IcarusAiToolNames.getRoundKills,
        'Get kill events (order + timing) for a round. If roundIndex is omitted, use the currently visible round.',
        parameters: {
          'roundIndex': Schema.integer(
            description: '0-based round index (optional).',
            nullable: true,
            minimum: 0,
          ),
        },
        optionalParameters: const ['roundIndex'],
      ),
      FunctionDeclaration(
        IcarusAiToolNames.takeCurrentScreenshot,
        'Capture a clean screenshot of the current map canvas (no UI chrome).',
        parameters: {},
      ),
    ]),
  ];
}
