import 'dart:io';

import 'package:icarus/startup/app_instance.dart';

Future<Directory> strategyFoldersRoot() => appInstance.supportDirectory();
