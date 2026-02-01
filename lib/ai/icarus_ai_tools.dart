import 'package:firebase_ai/firebase_ai.dart';

class IcarusAiToolNames {
  static const getVisibleRound = 'get_visible_round';
  static const getActivePage = 'get_active_page';
  static const getRoster = 'get_roster';
  static const getRoundKills = 'get_round_kills';
  static const takeCurrentScreenshot = 'take_current_screenshot';
  static const takePageScreenshot = 'take_page_screenshot';
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
      FunctionDeclaration(
        IcarusAiToolNames.takePageScreenshot,
        'Capture a clean screenshot of a specific page. Provide pageId, or (in match mode) roundIndex + orderInRound to target a page in that round.',
        parameters: {
          'pageId': Schema.string(
            description: 'StrategyPage.id to capture (optional).',
            nullable: true,
          ),
          'roundIndex': Schema.integer(
            description: '0-based round index (optional). Used in match mode.',
            nullable: true,
            minimum: 0,
          ),
          'orderInRound': Schema.integer(
            description:
                '0-based order of the event within the round (optional). Used in match mode.',
            nullable: true,
            minimum: 0,
          ),
          'eventType': Schema.enumString(
            enumValues: [
              'roundOverview',
              'kill',
              'note',
            ],
            description:
                'Optional filter when selecting by roundIndex + orderInRound.',
            nullable: true,
          ),
        },
        optionalParameters: const [
          'pageId',
          'roundIndex',
          'orderInRound',
          'eventType',
        ],
      ),
    ]),
  ];
}
