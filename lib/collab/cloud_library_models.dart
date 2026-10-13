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

/// The user's own cloud library as the server placed it in one moment:
/// each folder's parent and each strategy's folder, by public id. Null is
/// the top level.
typedef CloudLibraryInventory = ({
  Map<String, String?> folders,
  Map<String, String?> strategies,
});

typedef CloudStrategyEntry = ({
  StrategyData strategy,
  int revision,
  String role,
  String attackLabel,
});
