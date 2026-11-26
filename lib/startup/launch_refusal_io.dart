import 'dart:io';

Future<Never> refuseLaunch(String why) async {
  stderr.writeln(why);
  await stderr.flush();
  exit(2);
}
