import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/strategy_models.dart';

/// A cloud folder plus what the server says it holds across its subtree:
/// strategy count, the two most-used maps, and the agents in play. The
/// client never loads a folder's strategies to draw its card.
typedef CloudFolderEntry = ({
  Folder folder,
  String role,
  int strategyCount,
  List<MapValue> mapPeeks,
  List<AgentType> agentTypes,
});

typedef CloudStrategyEntry = ({
  StrategyData strategy,
  int revision,
  String role,
  String attackLabel,
});
