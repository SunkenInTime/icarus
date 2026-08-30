import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:discord_rich_presence/discord_rich_presence.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// The privacy-safe information Icarus publishes to Discord.
///
/// Strategy and page names are intentionally excluded because Discord Rich
/// Presence is public profile data.
class DiscordPresenceData {
  const DiscordPresenceData({
    required this.details,
    required this.state,
    this.largeImageKey,
    this.largeImageText,
    this.smallImageKey,
    this.smallImageText,
  });

  factory DiscordPresenceData.fromAppState({
    required StrategyState strategy,
    required MapState map,
    int agentCount = 0,
    int abilityCount = 0,
  }) {
    if (strategy.stratName == null) {
      return const DiscordPresenceData(
        details: 'Browsing the strategy library',
        state: 'Valorant strategy planner',
        largeImageKey: 'icarus_logo',
        largeImageText: 'Icarus',
      );
    }

    final rawMapName = Maps.mapNames[map.currentMap] ?? map.currentMap.name;
    final mapName = rawMapName.isEmpty
        ? rawMapName
        : '${rawMapName[0].toUpperCase()}${rawMapName.substring(1)}';

    return DiscordPresenceData(
      details: map.isAttack
          ? 'Planning an attack on $mapName'
          : 'Planning a defense on $mapName',
      state: _boardSummary(agentCount: agentCount, abilityCount: abilityCount),
      largeImageKey: '${map.currentMap.name}_thumbnail',
      largeImageText: mapName,
      smallImageKey: 'icarus_logo',
      smallImageText: 'Icarus',
    );
  }

  /// A live tally of what is on the board, e.g. "4 agents · 12 abilities".
  static String _boardSummary({
    required int agentCount,
    required int abilityCount,
  }) {
    final parts = [
      if (agentCount > 0) '$agentCount agent${agentCount == 1 ? '' : 's'}',
      if (abilityCount > 0)
        '$abilityCount abilit${abilityCount == 1 ? 'y' : 'ies'}',
    ];
    if (parts.isEmpty) return 'Starting from an empty board';
    return '${parts.join(' · ')} on the board';
  }

  final String details;
  final String state;
  final String? largeImageKey;
  final String? largeImageText;
  final String? smallImageKey;
  final String? smallImageText;

  @override
  bool operator ==(Object other) =>
      other is DiscordPresenceData &&
      other.details == details &&
      other.state == state &&
      other.largeImageKey == largeImageKey &&
      other.largeImageText == largeImageText &&
      other.smallImageKey == smallImageKey &&
      other.smallImageText == smallImageText;

  @override
  int get hashCode => Object.hash(
        details,
        state,
        largeImageKey,
        largeImageText,
        smallImageKey,
        smallImageText,
      );
}

/// Owns the local Discord RPC connection for the lifetime of the application.
///
/// Basic Rich Presence uses the public application ID only. It never uses a
/// Discord client secret or authenticates the user.
class DiscordPresenceService {
  DiscordPresenceService({
    this.applicationId = defaultApplicationId,
    Client Function(String applicationId)? clientFactory,
  }) : _clientFactory = clientFactory ??
            ((applicationId) => Client(clientId: applicationId));

  static const String defaultApplicationId = '1478874408528642101';

  final String applicationId;
  final Client Function(String applicationId) _clientFactory;
  final DateTime _sessionStartedAt = DateTime.now();

  Client? _client;
  DiscordPresenceData? _lastPublished;
  Future<void> _operationQueue = Future<void>.value();
  bool _connected = false;
  bool _disposed = false;

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  Future<void> update(DiscordPresenceData presence) {
    if (!isSupported || _disposed || presence == _lastPublished) {
      return Future<void>.value();
    }

    return _enqueue(() async {
      if (_disposed || presence == _lastPublished) return;

      try {
        await _ensureConnected();
        if (!_connected || _client == null) return;

        await _client!.setActivity(
          Activity(
            name: 'Icarus',
            details: presence.details,
            state: presence.state,
            timestamps: ActivityTimestamps(start: _sessionStartedAt),
            assets:
                presence.largeImageKey == null && presence.smallImageKey == null
                    ? null
                    : ActivityAssets(
                        largeImage: presence.largeImageKey,
                        largeText: presence.largeImageText,
                        smallImage: presence.smallImageKey,
                        smallText: presence.smallImageText,
                      ),
          ),
        );
        _lastPublished = presence;
      } catch (error, stackTrace) {
        _connected = false;
        _lastPublished = null;
        await _disconnectClient();
        developer.log(
          'Discord Rich Presence is unavailable.',
          name: 'DiscordPresenceService.update',
          error: error,
          stackTrace: stackTrace,
          level: 700,
        );
      }
    });
  }

  Future<void> clear() {
    if (!isSupported || _disposed) return Future<void>.value();

    return _enqueue(() async {
      _lastPublished = null;
      await _disconnectClient();
    });
  }

  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;

    return _enqueue(() async {
      _lastPublished = null;
      await _disconnectClient();
    });
  }

  Future<void> _ensureConnected() async {
    if (_connected) return;

    final client = _clientFactory(applicationId);
    await client.connect();
    _client = client;
    _connected = true;
  }

  Future<void> _disconnectClient() async {
    final client = _client;
    _client = null;
    _connected = false;
    if (client == null) return;

    try {
      await client.disconnect();
    } catch (error, stackTrace) {
      developer.log(
        'Discord Rich Presence cleanup failed.',
        name: 'DiscordPresenceService.disconnect',
        error: error,
        stackTrace: stackTrace,
        level: 700,
      );
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operationQueue.then((_) => operation());
    _operationQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  @visibleForTesting
  DiscordPresenceData? get lastPublished => _lastPublished;
}
