import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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
import 'package:icarus/const/settings.dart';

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
      color: Colors.transparent,
      child: Shortcuts(
        shortcuts: ShortcutInfo.textEditingOverrides,
        child: Container(
          decoration: BoxDecoration(
            color: Settings.tacticalVioletTheme.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Settings.tacticalVioletTheme.border,
              width: 2,
            ),
          ),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: LlmChatView(
                  provider: _provider,
                  enableAttachments: true,
                  enableVoiceNotes: false,
                  autofocus: true,
                  welcomeMessage:
                      "Helios here. I can review your current setup, round plan, spacing, and utility usage. If you want a visual read, ask me to take a screenshot of the map canvas.",
                  suggestions: const [
                    'Analyze the current round: win condition, first death, and trade plan.',
                    'Review spacing + crossfires on this page (use a screenshot).',
                    "Summarize this round's kill timing and tempo swing.",
                    'Find the biggest utility gap and give 3 repeatable fixes.',
                    'Check last 3 rounds for patterns + adjustment plan.',
                  ],
                  style: _chatStyle(context),
                ),
              ),
              Positioned(
                top: 10,
                left: 10,
                child: ListenableBuilder(
                  listenable: _provider,
                  builder: (context, _) {
                    final status = _provider.statusText;
                    if (status == null || status.trim().isEmpty) {
                      return const SizedBox.shrink();
                    }

                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        key: ValueKey(status),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Settings.tacticalVioletTheme.secondary,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Settings.tacticalVioletTheme.border,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Settings.tacticalVioletTheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Settings
                                          .tacticalVioletTheme.foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  LlmChatViewStyle _chatStyle(BuildContext context) {
    const scheme = Settings.tacticalVioletTheme;
    final base = LlmChatViewStyle.defaultStyle();

    final baseLlm = base.llmMessageStyle ?? LlmMessageStyle.defaultStyle();
    final baseUser = base.userMessageStyle ?? UserMessageStyle.defaultStyle();
    final baseInput = base.chatInputStyle ?? ChatInputStyle.defaultStyle();
    final baseSuggestion =
        base.suggestionStyle ?? SuggestionStyle.defaultStyle();

    const fontDelta = -1.0;

    final markdown = (baseLlm.markdownStyle ?? MarkdownStyleSheet()).copyWith(
      p: (baseLlm.markdownStyle?.p ?? const TextStyle()).copyWith(
        color: scheme.foreground,
        fontSize:
            ((baseLlm.markdownStyle?.p ?? const TextStyle()).fontSize ?? 14) +
                fontDelta,
        height: 1.25,
      ),
      strong: (baseLlm.markdownStyle?.strong ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      em: (baseLlm.markdownStyle?.em ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      a: (baseLlm.markdownStyle?.a ?? const TextStyle()).copyWith(
        color: scheme.primary,
      ),
      code: (baseLlm.markdownStyle?.code ?? const TextStyle()).copyWith(
        color: scheme.foreground,
        backgroundColor: scheme.background,
        fontSize:
            ((baseLlm.markdownStyle?.code ?? const TextStyle()).fontSize ??
                    13) +
                fontDelta,
      ),
      listBullet:
          (baseLlm.markdownStyle?.listBullet ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      blockquote:
          (baseLlm.markdownStyle?.blockquote ?? const TextStyle()).copyWith(
        color: scheme.mutedForeground,
      ),
      h1: (baseLlm.markdownStyle?.h1 ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      h2: (baseLlm.markdownStyle?.h2 ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      h3: (baseLlm.markdownStyle?.h3 ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      h4: (baseLlm.markdownStyle?.h4 ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      h5: (baseLlm.markdownStyle?.h5 ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
      h6: (baseLlm.markdownStyle?.h6 ?? const TextStyle()).copyWith(
        color: scheme.foreground,
      ),
    );

    ActionButtonStyle? button(ActionButtonStyle? s, {bool primary = false}) {
      if (s == null) return null;
      return ActionButtonStyle(
        icon: s.icon,
        iconColor: primary ? scheme.primaryForeground : scheme.foreground,
        iconDecoration: BoxDecoration(
          color: primary ? scheme.primary : scheme.secondary,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.border),
        ),
        text: s.text,
        textStyle: s.textStyle?.copyWith(
          color: scheme.foreground,
        ),
      );
    }

    return base.copyWith(
      backgroundColor: scheme.card,
      menuColor: scheme.popover,
      progressIndicatorColor: scheme.mutedForeground,
      padding: const EdgeInsets.only(top: 14, left: 12, right: 12),
      messageSpacing: 8,
      llmMessageStyle: baseLlm.copyWith(
        minWidth: 0,
        maxWidth: 520,
        // In the right sidebar, the toolkit's LLM row reserves a trailing
        // Flexible spacer. Increasing this flex lets Helios responses use more
        // of the available width (less "skinny" lines).
        flex: 20,
        icon: Icons.wb_sunny_outlined,
        iconColor: scheme.primaryForeground,
        iconDecoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
        ),
        markdownStyle: markdown,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.secondary,
          border: Border.all(color: scheme.border),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.zero,
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
      ),
      userMessageStyle: UserMessageStyle(
        textStyle: (baseUser.textStyle ?? const TextStyle()).copyWith(
          color: scheme.foreground,
          fontSize: ((baseUser.textStyle ?? const TextStyle()).fontSize ?? 14) +
              fontDelta,
        ),
        decoration: BoxDecoration(
          color: scheme.selection,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.zero,
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
      ),
      chatInputStyle: ChatInputStyle(
        textStyle: (baseInput.textStyle ?? const TextStyle()).copyWith(
          color: scheme.foreground,
          fontSize:
              ((baseInput.textStyle ?? const TextStyle()).fontSize ?? 14) +
                  fontDelta,
        ),
        hintStyle: (baseInput.hintStyle ?? const TextStyle()).copyWith(
          color: scheme.mutedForeground,
          fontSize:
              ((baseInput.hintStyle ?? const TextStyle()).fontSize ?? 14) +
                  fontDelta,
        ),
        hintText: "Ask Helios... (try 'use a screenshot')",
        backgroundColor: scheme.background,
        decoration: BoxDecoration(
          color: scheme.background,
          border: Border.all(width: 1, color: scheme.border),
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      actionButtonBarDecoration: BoxDecoration(
        color: scheme.background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.border),
      ),
      suggestionStyle: SuggestionStyle(
        textStyle: (baseSuggestion.textStyle ?? const TextStyle()).copyWith(
          color: scheme.foreground,
          fontSize:
              ((baseSuggestion.textStyle ?? const TextStyle()).fontSize ?? 13) +
                  fontDelta,
        ),
        decoration: BoxDecoration(
          color: scheme.secondary,
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          border: Border.all(color: scheme.border),
        ),
      ),
      addButtonStyle: button(base.addButtonStyle),
      attachFileButtonStyle: button(base.attachFileButtonStyle),
      cameraButtonStyle: button(base.cameraButtonStyle),
      galleryButtonStyle: button(base.galleryButtonStyle),
      stopButtonStyle: button(base.stopButtonStyle),
      submitButtonStyle: button(base.submitButtonStyle, primary: true),
      closeMenuButtonStyle: button(base.closeMenuButtonStyle),
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
          return const IcarusFunctionCallResult(
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
