import 'dart:convert';
import 'dart:io';

import 'package:icarus_library/icarus_library.dart';

void main(List<String> args) {
  File(args.single).writeAsStringSync(jsonEncode(fieldRulesJson()));
}
