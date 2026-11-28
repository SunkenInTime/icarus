import 'dart:async';
import 'dart:convert';
import 'dart:io';

const usage = '''
Runs the acceptance set of driver scripts, each on Hive (--library-store
off) and on the store (--library-store store), and reports how many are
clean in both, fail in both, and fail only on one. On Linux each run goes
through tool/drive/linux.dart; on Windows through tool/drive/run.ps1, which
needs --exe, a build from tool/drive/build.ps1, and the logged-in desktop.

  dart tool/drive/acceptance.dart --out DIR [--library DIR] [--workers N]
      [--only NAME,NAME] [--exe DIR] [--shard K/N]
  dart tool/drive/acceptance.dart --combine DIR,DIR,...

The set is every script under tool/drive/scripts that never signs in, less
those tool/drive/acceptance.json leaves out by name with a reason: those
waiting on a decision and those that cannot run on this system. That file
also says what each script starts on: a fixture written by
test/library_store/drive_fixtures_test.dart, the library given with
--library (a Hive store folder, copied, never opened itself), or what the
script before it left. Scripts that start after another run in the same
folder, after it, in each mode. --out must be new. --only runs the named
scripts and those they start after.

--shard K/N runs one of N parts of the set (K from 1): its chains, a
script and those that start after it, sorted by name and dealt out in
turn, each whole and in both modes. Every run writes verdicts.json beside
its report. --combine reads the verdicts of every part from those
folders, and prints one report for the whole set; it fails when a part is
missing, given twice, or did not cover the scripts it should have.

Exits 0 when every script in the set is clean in both modes, 1 otherwise,
and 2 when it cannot run.
''';

final class _UsageError implements Exception {
  const _UsageError(this.message);

  final String message;
}

Directory get _repo {
  final script = File(Platform.script.toFilePath());
  if (!script.path.endsWith('acceptance.dart')) {
    throw const _UsageError('run it as: dart tool/drive/acceptance.dart ...');
  }
  return script.parent.parent.parent;
}

const _modes = ['off', 'store'];

final class _Plan {
  _Plan(this.json);

  final Map<String, Object?> json;

  Map<String, String> get notOnLinux =>
      (json['notOnLinux']! as Map<String, Object?>).cast<String, String>();

  Set<String> get closesTheApp =>
      (json['closesTheApp']! as List).cast<String>().toSet();

  String? get closingExitNotJudgedOnWindows =>
      json['closingExitNotJudgedOnWindows'] as String?;

  Map<String, String> get notOnWindows =>
      (json['notOnWindows']! as Map<String, Object?>).cast<String, String>();

  Map<String, String> get waiting =>
      (json['waiting']! as Map<String, Object?>).cast<String, String>();

  Set<String> get storeOnly =>
      (json['storeOnly']! as List).cast<String>().toSet();

  Map<String, int> get slow => {
        for (final MapEntry(key: name, value: entry)
            in ((json['slow'] ?? const {}) as Map<String, Object?>).entries)
          name: switch (entry) {
            {'seconds': final int seconds, 'because': final String _} =>
              seconds,
            _ => throw _UsageError(
                'acceptance.json gives $name as slow without whole seconds '
                'and a reason'),
          },
      };

  Map<String, Map<String, Object?>> get starts =>
      (json['starts']! as Map<String, Object?>)
          .cast<String, Map<String, Object?>>();
}

final class _Start {
  const _Start({
    this.fixture,
    this.library = false,
    this.after,
    this.following,
    this.picture,
  });

  final String? fixture;
  final String? picture;
  final bool library;
  final String? after;
  final String? following;

  String? get before => after ?? following;

  static _Start of(Map<String, Object?>? json) => _Start(
        fixture: json?['fixture'] as String?,
        library: json?['library'] == true,
        after: json?['after'] as String?,
        following: json?['following'] as String?,
        picture: json?['picture'] as String?,
      );
}

final class _Outcome {
  const _Outcome(this.clean, this.line);

  final bool clean;
  final String line;
}

Map<String, String> _options(List<String> args) {
  const known = {'out', 'library', 'workers', 'only', 'exe', 'shard', 'combine'};
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) throw _UsageError('unexpected "$arg"');
    final name = arg.substring(2);
    if (!known.contains(name)) throw _UsageError('unknown option --$name');
    if (i + 1 >= args.length) throw _UsageError('--$name needs a value');
    options[name] = args[++i];
  }
  return options;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(usage);
    exit(args.isEmpty ? 2 : 0);
  }
  try {
    final options = _options(args);
    if (options['combine'] case final folders?) {
      final (:report, :clean) = combineParts(folders.split(','), _repo);
      stdout.writeln(report);
      exit(clean ? 0 : 1);
    }
    exit(await _accept(options));
  } on _UsageError catch (error) {
    stderr.writeln(error.message);
    exit(2);
  }
}

typedef AcceptanceSet = ({
  _Plan plan,
  List<String> set,
  Map<String, String> leftOut,
  Map<String, _Start> starts,
});

AcceptanceSet acceptanceSet(Directory repo, {required bool onWindows}) {
  final plan = _Plan(
    jsonDecode(
            File('${repo.path}/tool/drive/acceptance.json').readAsStringSync())
        as Map<String, Object?>,
  );
  final scripts = Directory('${repo.path}/tool/drive/scripts')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .where((file) => !file.readAsStringSync().contains('"signIn"'))
      .map((file) => file.uri.pathSegments.last.replaceAll('.json', ''))
      .toList()
    ..sort();
  final leftOut = {
    ...(onWindows ? plan.notOnWindows : plan.notOnLinux),
    ...plan.waiting,
  };
  for (final name in leftOut.keys) {
    if (!scripts.contains(name)) {
      throw _UsageError('acceptance.json leaves out $name, which is not a '
          'script that never signs in');
    }
  }
  final set = [
    for (final name in scripts)
      if (!leftOut.containsKey(name)) name,
  ];
  for (final name in plan.slow.keys) {
    if (!scripts.contains(name)) {
      throw _UsageError('acceptance.json gives $name as slow, which is not a '
          'script that never signs in');
    }
  }
  final starts = {for (final name in set) name: _Start.of(plan.starts[name])};
  for (final MapEntry(key: name, value: start) in starts.entries) {
    if (start.before case final before? when !set.contains(before)) {
      throw _UsageError('$name starts after $before, which is not in the set');
    }
  }
  return (plan: plan, set: set, leftOut: leftOut, starts: starts);
}

List<List<String>> chainsOf(
  List<String> names,
  String? Function(String name) before,
) {
  final sorted = [...names]..sort();
  final chains = <List<String>>[];
  for (final name in sorted) {
    if (before(name) != null) continue;
    final chain = [name];
    while (true) {
      final next = sorted.where((other) => before(other) == chain.last);
      if (next.isEmpty) break;
      chain.add(next.single);
    }
    chains.add(chain);
  }
  return chains;
}

List<List<String>> shardOf(List<List<String>> chains, int k, int n) {
  if (n < 1 || k < 1 || k > n) {
    throw ArgumentError('a shard is K/N with 1 <= K <= N, not $k/$n');
  }
  final sorted = [...chains]..sort((a, b) => a.first.compareTo(b.first));
  return [
    for (var index = 0; index < sorted.length; index++)
      if (index % n == k - 1) sorted[index],
  ];
}

({int k, int n}) _shardOption(String text) {
  final match = RegExp(r'^(\d+)/(\d+)$').firstMatch(text);
  final k = int.tryParse(match?.group(1) ?? '');
  final n = int.tryParse(match?.group(2) ?? '');
  if (k == null || n == null || n < 1 || k < 1 || k > n) {
    throw _UsageError('--shard is K/N with 1 <= K <= N, not "$text"');
  }
  return (k: k, n: n);
}

Future<int> _accept(Map<String, String> options) async {
  final repo = _repo;
  final outPath =
      options['out'] ?? (throw const _UsageError('--out is needed'));
  final out = Directory(outPath).absolute;
  if (out.existsSync() && out.listSync().isNotEmpty) {
    throw _UsageError('${out.path} is not new; give --out a new folder.');
  }
  final library = switch (options['library']) {
    final path? => Directory(path).absolute,
    null => null,
  };
  if (library != null && !library.existsSync()) {
    throw _UsageError('--library ${library.path} does not exist');
  }
  final workers =
      int.tryParse(options['workers'] ?? (Platform.isWindows ? '1' : '2')) ?? 0;
  if (workers < 1)
    throw const _UsageError('--workers is a whole number from 1');
  if (Platform.isWindows && workers > 1) {
    throw const _UsageError(
      'on Windows the runs share one desktop and one clipboard; run one at a '
      'time',
    );
  }

  final (:plan, :set, :leftOut, :starts) =
      acceptanceSet(repo, onWindows: Platform.isWindows);
  if (Platform.isWindows && options['exe'] == null) {
    throw const _UsageError('on Windows, give --exe a build from build.ps1');
  }

  final only = options['only']?.split(',').toSet();
  final chosen = <String>{};
  void choose(String name) {
    if (!chosen.add(name)) return;
    if (starts[name]!.before case final before?) choose(before);
  }

  for (final name in only ?? set) {
    if (!set.contains(name)) throw _UsageError('$name is not in the set');
    choose(name);
  }

  final shard = switch (options['shard']) {
    final text? => _shardOption(text),
    null => null,
  };
  final chains = switch (shard) {
    (:final k, :final n) => shardOf(
        chainsOf(set.where(chosen.contains).toList(),
            (name) => starts[name]!.before),
        k,
        n,
      ),
    null => chainsOf(
        set.where(chosen.contains).toList(), (name) => starts[name]!.before),
  };
  chosen
    ..clear()
    ..addAll(chains.expand((chain) => chain));
  if (library == null && chosen.any((name) => starts[name]!.library)) {
    throw const _UsageError(
      'some scripts start on a library; give --library a Hive store folder',
    );
  }

  out.createSync(recursive: true);
  final fixtures = <String, Directory>{};
  for (final fixture in {
    for (final name in chosen)
      if (starts[name]!.fixture case final fixture?) fixture,
  }) {
    final folder = Directory('${out.path}/fixtures/$fixture')
      ..createSync(recursive: true);
    stdout.writeln('writing fixture $fixture');
    final written = await Process.run(
      'flutter',
      ['test', 'test/library_store/drive_fixtures_test.dart'],
      workingDirectory: repo.path,
      environment: {fixture: folder.path},
      runInShell: Platform.isWindows,
    );
    if (written.exitCode != 0) {
      stderr
        ..writeln('the fixture $fixture was not written:')
        ..writeln(written.stdout)
        ..writeln(written.stderr);
      return 2;
    }
    fixtures[fixture] = folder;
  }

  final results = File('${out.path}/results.txt');
  final outcomes = <String, Map<String, _Outcome>>{};
  final jobs = [
    for (final chain in chains)
      for (final mode in _modes)
        if (mode == 'store' || !plan.storeOnly.contains(chain.first))
          (chain: chain, mode: mode),
  ];
  var next = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      final (:chain, :mode) = jobs[next++];
      for (final name in chain) {
        final start = starts[name]!;
        final hiveStore = switch (start) {
          _Start(:final after?) => '${out.path}/$mode/$after/store-main',
          _Start(:final fixture?) => fixtures[fixture]!.path,
          _Start(library: true) => library!.path,
          _ => null,
        };
        final runOut = '${out.path}/$mode/$name';
        final closes = plan.closesTheApp.contains(name);
        Directory('${out.path}/$mode').createSync(recursive: true);
        if (start.picture case final picture?) {
          File('${out.path}/$mode/$picture').writeAsBytesSync(_bitmap);
        }
        final run = Platform.isWindows
            ? await Process.run(
                'powershell',
                [
                  '-NoProfile',
                  '-ExecutionPolicy',
                  'Bypass',
                  '-File',
                  r'tool\drive\run.ps1',
                  '-Exe',
                  options['exe']!,
                  '-Script',
                  'tool\\drive\\scripts\\$name.json',
                  '-LibraryStore',
                  mode,
                  '-Out',
                  runOut,
                  if (hiveStore != null) ...['-HiveStore', hiveStore],
                  if (plan.slow[name] case final seconds?) ...[
                    '-TimeoutSeconds',
                    '$seconds',
                  ],
                  if (closes) ...['-EndsBy', 'close'],
                  if (closes)
                    if (plan.closingExitNotJudgedOnWindows case final why?) ...[
                      '-ExitNotJudged',
                      why
                    ],
                ],
                workingDirectory: repo.path,
              )
            : await Process.run(
                'dart',
                [
                  'tool/drive/linux.dart',
                  'run',
                  '--script',
                  'tool/drive/scripts/$name.json',
                  '--library-store',
                  mode,
                  '--out',
                  runOut,
                  if (hiveStore != null) ...['--hive-store', hiveStore],
                  if (options['exe'] case final exe?) ...['--exe', exe],
                  if (plan.slow[name] case final seconds?) ...[
                    '--timeout-seconds',
                    '$seconds',
                  ],
                  if (closes) ...['--ends-by', 'close'],
                ],
                workingDirectory: repo.path,
              );
        final said = '${run.stdout}'.split('\n');
        File('${out.path}/$mode/$name.launcher.txt')
            .writeAsStringSync('${run.stdout}\n${run.stderr}');
        final verdict = said
                .where((line) => closes
                    ? line.contains('the app after its window') ||
                        line.contains('did not close the app')
                    : line.contains('SUMMARY'))
                .lastOrNull
                ?.trim() ??
            'no SUMMARY (exit ${run.exitCode}): '
                '${_lines('${run.stderr}', '${run.stdout}')}';
        final outcome = _Outcome(
          run.exitCode == 0,
          [
            verdict,
            for (final line in said)
              if (line.contains('the Hive library file')) line.trim(),
          ].join('; '),
        );
        (outcomes[name] ??= {})[mode] = outcome;
        final line = '$name $mode ${outcome.clean ? 'CLEAN' : 'NOT CLEAN'}: '
            '${outcome.line}';
        results.writeAsStringSync('$line\n', mode: FileMode.append);
        stdout.writeln(line);
      }
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);

  bool clean(String name, String mode) => outcomes[name]?[mode]?.clean ?? false;
  final run = set.where(chosen.contains).toList();
  final inBoth = <String>[];
  final failBoth = <String>[];
  final onlyStore = <String>[];
  final onlyHive = <String>[];
  final storeAlone = <String>[];
  final storeAloneFailing = <String>[];
  for (final name in run) {
    final store = clean(name, 'store');
    if (plan.storeOnly.contains(name)) {
      (store ? storeAlone : storeAloneFailing).add(name);
      continue;
    }
    final hive = clean(name, 'off');
    switch ((hive, store)) {
      case (true, true):
        inBoth.add(name);
      case (false, false):
        failBoth.add(name);
      case (true, false):
        onlyStore.add(name);
      case (false, true):
        onlyHive.add(name);
    }
  }
  final report = [
    'set: ${run.length} scripts (${plan.storeOnly.where(run.contains).length} '
        'of them on the store alone)',
    'clean in both: ${inBoth.length}',
    'failing in both: ${failBoth.length}${_list(failBoth)}',
    'failing only on the store: ${onlyStore.length}${_list(onlyStore)}',
    'failing only on Hive: ${onlyHive.length}${_list(onlyHive)}',
    'on the store alone (they never run on Hive): ${storeAlone.length} clean, '
        '${storeAloneFailing.length} failing${_list(storeAloneFailing)}',
    'left out:',
    for (final MapEntry(key: name, value: reason) in leftOut.entries)
      '  $name: $reason',
  ].join('\n');
  File('${out.path}/report.txt').writeAsStringSync('$report\n');
  File('${out.path}/verdicts.json').writeAsStringSync(jsonEncode({
    'shard': switch (shard) {
      (:final k, :final n) => '$k/$n',
      null => '1/1',
    },
    'scripts': run,
    'cleanInBoth': inBoth,
    'failingInBoth': failBoth,
    'failingOnlyOnTheStore': onlyStore,
    'failingOnlyOnHive': onlyHive,
    'storeAloneClean': storeAlone,
    'storeAloneFailing': storeAloneFailing,
  }));
  stdout.writeln(report);
  return inBoth.length + storeAlone.length == run.length ? 0 : 1;
}

({String report, bool clean}) combineParts(
  List<String> folders,
  Directory repo,
) {
  final parts = <String, Map<String, Object?>>{};
  final problems = <String>[];
  int? count;
  for (final folder in folders) {
    final file = File('$folder/verdicts.json');
    if (!file.existsSync()) {
      problems.add('$folder holds no verdicts.json: that part did not finish');
      continue;
    }
    final verdicts = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final shard = verdicts['shard']! as String;
    final n = int.parse(shard.split('/').last);
    if (count != null && count != n) {
      problems.add('$folder is part $shard, but another part was one of $count');
    }
    count ??= n;
    if (parts.containsKey(shard)) problems.add('part $shard is given twice');
    parts[shard] = verdicts;
  }
  if (count != null) {
    for (var k = 1; k <= count; k++) {
      if (!parts.containsKey('$k/$count')) problems.add('part $k/$count is missing');
    }
  }
  List<String> all(String key) => [
        for (final verdicts in parts.values)
          ...(verdicts[key]! as List).cast<String>(),
      ]..sort();
  final (:set, :leftOut, plan: _, starts: _) =
      acceptanceSet(repo, onWindows: Platform.isWindows);
  final covered = all('scripts');
  final missing = set.where((name) => !covered.contains(name)).toList();
  final extra = covered.where((name) => !set.contains(name)).toList();
  final twice = {
    for (final name in covered)
      if (covered.where((other) => other == name).length > 1) name,
  };
  if (missing.isNotEmpty) problems.add('no part ran ${missing.join(', ')}');
  if (extra.isNotEmpty) problems.add('the parts ran ${extra.join(', ')}, which are not in the set');
  if (twice.isNotEmpty) problems.add('more than one part ran ${twice.join(', ')}');

  final failBoth = all('failingInBoth');
  final onlyStore = all('failingOnlyOnTheStore');
  final onlyHive = all('failingOnlyOnHive');
  final storeAloneFailing = all('storeAloneFailing');
  final report = [
    'set: ${covered.length} scripts in ${parts.length} parts '
        '(${all('storeAloneClean').length + storeAloneFailing.length} of them '
        'on the store alone)',
    'clean in both: ${all('cleanInBoth').length}',
    'failing in both: ${failBoth.length}${_list(failBoth)}',
    'failing only on the store: ${onlyStore.length}${_list(onlyStore)}',
    'failing only on Hive: ${onlyHive.length}${_list(onlyHive)}',
    'on the store alone (they never run on Hive): '
        '${all('storeAloneClean').length} clean, '
        '${storeAloneFailing.length} failing${_list(storeAloneFailing)}',
    for (final problem in problems) 'PART PROBLEM: $problem',
    'left out:',
    for (final MapEntry(key: name, value: reason) in leftOut.entries)
      '  $name: $reason',
  ].join('\n');
  final clean = problems.isEmpty &&
      failBoth.isEmpty &&
      onlyStore.isEmpty &&
      onlyHive.isEmpty &&
      storeAloneFailing.isEmpty;
  return (report: report, clean: clean);
}

String _list(List<String> names) =>
    names.isEmpty ? '' : ' (${names.join(', ')})';

const _pictureWidth = 640;
const _pictureHeight = 360;

final _bitmap = [
  ...'BM'.codeUnits,
  ..._le32(54 + _pictureWidth * _pictureHeight * 3),
  ..._le32(0),
  ..._le32(54),
  ..._le32(40),
  ..._le32(_pictureWidth),
  ..._le32(_pictureHeight),
  1,
  0,
  24,
  0,
  ..._le32(0),
  ..._le32(_pictureWidth * _pictureHeight * 3),
  ..._le32(2835),
  ..._le32(2835),
  ..._le32(0),
  ..._le32(0),
  for (var row = 0; row < _pictureHeight; row++)
    for (var column = 0; column < _pictureWidth; column++)
      ...(column < _pictureWidth ~/ 2
          ? const [200, 120, 40]
          : const [40, 120, 200]),
];

List<int> _le32(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

String _lines(String stderr, String stdout) {
  final said = [
    for (final line in '$stderr\n$stdout'.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  return said.isEmpty ? 'the launcher said nothing' : said.take(3).join(' / ');
}
