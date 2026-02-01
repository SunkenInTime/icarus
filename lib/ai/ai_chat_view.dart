import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/ai_models.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/ai/icarus_ai_system_prompt.dart';
import 'package:icarus/ai/icarus_ai_tools.dart';
import 'package:icarus/ai/icarus_firebase_provider.dart';
import 'package:icarus/ai/screenshot_capture_service.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/valorant_match_mappings.dart';
import 'package:icarus/providers/active_page_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/valorant_round_provider.dart';
import 'package:icarus/valorant/valorant_match_strategy_data.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';

class AiChatView extends ConsumerStatefulWidget {
  const AiChatView({super.key});

  @override
  ConsumerState<AiChatView> createState() => _AiChatViewState();
}

class _AiChatViewState extends ConsumerState<AiChatView> {
  late final IcarusFirebaseProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = IcarusFirebaseProvider(
      model: FirebaseAI.googleAI().generativeModel(
        model: AiModels.geminiFlash,
        systemInstruction: Content.system(icarusAiSystemPrompt),
        tools: buildIcarusAiTools(),
      ),
      onFunctionCall: _onFunctionCall,
    );
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Shortcuts(
        shortcuts: ShortcutInfo.textEditingOverrides,
        child: LlmChatView(
          provider: _provider,
          enableAttachments: true,
          enableVoiceNotes: false,
          autofocus: true,
          welcomeMessage:
              'Ask for review (round, spacing, win condition), or ask for a visual read of the current map canvas.',
        ),
      ),
    );
  }

  Future<IcarusFunctionCallResult?> _onFunctionCall(
      FunctionCall functionCall) async {
    switch (functionCall.name) {
      case IcarusAiToolNames.getVisibleRound:
        return IcarusFunctionCallResult(response: _getVisibleRound());
      case IcarusAiToolNames.getActivePage:
        return IcarusFunctionCallResult(response: _getActivePage());
      case IcarusAiToolNames.getRoster:
        return IcarusFunctionCallResult(response: _getRoster());
      case IcarusAiToolNames.getRoundKills:
        return IcarusFunctionCallResult(
          response: _getRoundKills(functionCall.args),
        );
      case IcarusAiToolNames.takeCurrentScreenshot:
        final bytes = await captureCleanMapScreenshot(ref);
        return IcarusFunctionCallResult(
          response: {
            'status': 'captured',
            'mimeType': 'image/png',
            'width': CoordinateSystem.screenShotSize.width.toInt(),
            'height': CoordinateSystem.screenShotSize.height.toInt(),
          },
          extraParts: [
            const TextPart('Current map canvas screenshot (image/png).'),
            InlineDataPart('image/png', bytes),
          ],
        );
      case IcarusAiToolNames.takePageScreenshot:
        final targetPageId = _resolveScreenshotTargetPageId(functionCall.args);
        if (targetPageId == null || targetPageId.trim().isEmpty) {
          return IcarusFunctionCallResult(
            response: {
              'error':
                  'Missing target. Provide pageId, or (in match mode) roundIndex + orderInRound.'
            },
          );
        }
        final bytes =
            await captureCleanMapScreenshotForPageId(ref, targetPageId);
        return IcarusFunctionCallResult(
          response: {
            'status': 'captured',
            'pageId': targetPageId,
            'mimeType': 'image/png',
            'width': CoordinateSystem.screenShotSize.width.toInt(),
            'height': CoordinateSystem.screenShotSize.height.toInt(),
          },
          extraParts: [
            TextPart('Screenshot for pageId=$targetPageId (image/png).'),
            InlineDataPart('image/png', bytes),
          ],
        );
      default:
        return IcarusFunctionCallResult(
          response: {'error': 'Unknown function: ${functionCall.name}'},
        );
    }
  }

  String? _resolveScreenshotTargetPageId(Map<String, Object?> args) {
    final pageId = args['pageId'] as String?;
    if (pageId != null && pageId.trim().isNotEmpty) return pageId;

    final strat = _loadStrategyFromHive();
    final match = strat?.valorantMatch;
    if (match == null) return null;

    final roundIndex = (args['roundIndex'] as num?)?.toInt();
    final orderInRound = (args['orderInRound'] as num?)?.toInt();
    if (roundIndex == null || orderInRound == null) return null;

    final eventTypeStr = args['eventType'] as String?;
    ValorantEventType? eventType;
    if (eventTypeStr != null && eventTypeStr.trim().isNotEmpty) {
      for (final t in ValorantEventType.values) {
        if (t.name == eventTypeStr) {
          eventType = t;
          break;
        }
      }
    }

    for (final m in match.pageMeta) {
      if (m.roundIndex != roundIndex) continue;
      if (m.orderInRound != orderInRound) continue;
      if (eventType != null && m.type != eventType) continue;
      return m.pageId;
    }
    return null;
  }

  Map<String, Object?> _getVisibleRound() {
    final strat = _loadStrategyFromHive();
    final match = strat?.valorantMatch;
    if (match == null) {
      return {
        'inMatchMode': false,
        'roundIndex': null,
        'roundNumber': null,
      };
    }

    final roundIndex = ref.read(valorantRoundProvider) ?? 0;
    return {
      'inMatchMode': true,
      'roundIndex': roundIndex,
      'roundNumber': roundIndex + 1,
    };
  }

  Map<String, Object?> _getActivePage() {
    final strat = _loadStrategyFromHive();
    final pageId = ref.read(activePageProvider);
    if (strat == null || pageId == null) {
      return {
        'pageId': pageId,
        'pageName': null,
        'inMatchMode': strat?.valorantMatch != null,
        'meta': null,
      };
    }

    String? pageName;
    for (final p in strat.pages) {
      if (p.id == pageId) {
        pageName = p.name;
        break;
      }
    }
    final match = strat.valorantMatch;
    ValorantPageMeta? meta;
    if (match != null) {
      for (final m in match.pageMeta) {
        if (m.pageId == pageId) {
          meta = m;
          break;
        }
      }
    }

    return {
      'pageId': pageId,
      'pageName': pageName,
      'inMatchMode': match != null,
      'meta': meta == null
          ? null
          : {
              'roundIndex': meta.roundIndex,
              'roundNumber': meta.roundIndex + 1,
              'orderInRound': meta.orderInRound,
              'type': meta.type.name,
              'roundTimeMs': meta.roundTimeMs,
              'gameTimeMs': meta.gameTimeMs,
            },
    };
  }

  Map<String, Object?> _getRoster() {
    final strat = _loadStrategyFromHive();
    final match = strat?.valorantMatch;
    if (match == null) {
      return {
        'inMatchMode': false,
        'allyTeamId': null,
        'players': const [],
        'allies': const [],
        'enemies': const [],
      };
    }

    final players = <Map<String, Object?>>[];
    final allies = <Map<String, Object?>>[];
    final enemies = <Map<String, Object?>>[];

    for (final p in match.players) {
      final isAlly = p.teamId.isNotEmpty && p.teamId == match.allyTeamId;
      final agentType =
          ValorantMatchMappings.agentTypeFromCharacterId(p.characterId);
      final agentName = AgentData.agents[agentType]?.name ?? 'Unknown';
      final entry = <String, Object?>{
        'subject': p.subject,
        'gameName': p.gameName,
        'tagLine': p.tagLine,
        'riotId': '${p.gameName}#${p.tagLine}',
        'teamId': p.teamId,
        'isAlly': isAlly,
        'agentName': agentName,
      };
      players.add(entry);
      if (isAlly) {
        allies.add(entry);
      } else {
        enemies.add(entry);
      }
    }

    return {
      'inMatchMode': true,
      'allyTeamId': match.allyTeamId,
      'players': players,
      'allies': allies,
      'enemies': enemies,
    };
  }

  Map<String, Object?> _getRoundKills(Map<String, Object?> args) {
    final strat = _loadStrategyFromHive();
    final match = strat?.valorantMatch;
    if (match == null) {
      return {
        'inMatchMode': false,
        'roundIndex': null,
        'roundNumber': null,
        'kills': const [],
      };
    }

    final requestedRound = (args['roundIndex'] as num?)?.toInt();
    final roundIndex = requestedRound ?? (ref.read(valorantRoundProvider) ?? 0);

    final kills = <Map<String, Object?>>[];
    for (final m in match.pageMeta) {
      if (m.type != ValorantEventType.kill) continue;
      if (m.roundIndex != roundIndex) continue;

      final killerAgent = _agentNameForSubject(match, m.killerSubject);
      final victimAgent = _agentNameForSubject(match, m.victimSubject);

      kills.add({
        'pageId': m.pageId,
        'orderInRound': m.orderInRound,
        'roundIndex': m.roundIndex,
        'roundNumber': m.roundIndex + 1,
        'roundTimeMs': m.roundTimeMs,
        'gameTimeMs': m.gameTimeMs,
        'timeLabel': _formatTimeLabel(m.roundTimeMs ?? m.gameTimeMs),
        'killerSubject': m.killerSubject,
        'victimSubject': m.victimSubject,
        'assistantSubjects': m.assistantSubjects,
        'killerAgent': killerAgent,
        'victimAgent': victimAgent,
        'killerX': m.killerX,
        'killerY': m.killerY,
        'victimX': m.victimX,
        'victimY': m.victimY,
      });
    }

    kills.sort((a, b) {
      final ao = (a['orderInRound'] as num?)?.toInt() ?? 0;
      final bo = (b['orderInRound'] as num?)?.toInt() ?? 0;
      return ao.compareTo(bo);
    });

    return {
      'inMatchMode': true,
      'roundIndex': roundIndex,
      'roundNumber': roundIndex + 1,
      'kills': kills,
    };
  }

  StrategyData? _loadStrategyFromHive() {
    final id = ref.read(strategyProvider).id;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    var strat = box.get(id);
    if (strat != null) return strat;
    for (final s in box.values) {
      if (s.id == id) return s;
    }
    return null;
  }

  String _agentNameForSubject(
      ValorantMatchStrategyData match, String? subject) {
    if (subject == null || subject.isEmpty) return 'Unknown';
    for (final p in match.players) {
      if (p.subject != subject) continue;
      final t = ValorantMatchMappings.agentTypeFromCharacterId(p.characterId);
      return AgentData.agents[t]?.name ?? 'Unknown';
    }
    return 'Unknown';
  }

  String? _formatTimeLabel(int? ms) {
    if (ms == null || ms < 0) return null;
    final totalSeconds = (ms / 1000).floor();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
