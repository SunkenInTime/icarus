import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/strategy_models.dart';

typedef CloudFolderEntry = ({Folder folder, String role});

typedef CloudStrategyEntry = ({
  StrategyData strategy,
  int revision,
  String role,
  String attackLabel,
});
