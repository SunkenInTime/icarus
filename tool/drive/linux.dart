import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const usage = '''
Builds Icarus with the verification driver on Linux and runs driver scripts
against it, each run on a screen of its own. Linux is for fast iteration:
Icarus ships to Windows, macOS and the web, so final checks still happen on
Windows with tool/drive/build.ps1 and run.ps1. tool/drive/README.md says more.

  dart tool/drive/linux.dart build [--out DIR] [--mode release|debug] [--convex URL]
  dart tool/drive/linux.dart run --script FILE [--account EMAIL]
      [--companion FILE] [--companion-account EMAIL] [--exe DIR] [--out DIR]
      [--accounts-file FILE] [--accounts-host HOST] [--timeout-seconds N]
      [--hive-store DIR] [--library-store off|shadow|mirror|read|ops|store]
      [--cloud-store send] [--second-account EMAIL]
      [--kill-after-seconds S] [--main-scope UNIT]

build   Builds this checkout into --out (default build/drive-linux). Without
        --convex it talks to the dev deployment; production is refused.
run     Runs --script, and --companion beside it when given, against the
        build in --exe (default build/drive-linux). Each run starts its own
        Xvfb screen, and each instance gets its own store, session, app data
        and log under --out (default drive-<run> beside --exe), which must be
        new. Scripts that sign in need --account; the companion uses
        --companion-account, or --account when that is missing.
        Passwords come from --accounts-file when it exists (default
        ~/.agents/secrets/icarus/test-accounts.md), otherwise over ssh from
        that file on --accounts-host (default windows). They only reach the
        app's environment.
        --hive-store starts the main instance on a copy of DIR, which is
        never opened itself. --library-store passes --library-store=VALUE to
        every instance; shadow copies the library into the store as it
        starts, mirror also writes the store after every save, read
        also draws the library list and folders from the store, and ops
        also commits each editor action's ops to the store as it happens
        and checks the store against the canvas after every turn. store
        moves the library into the store once, as the app will when it
        runs on the store, and leaves the Hive files as they were; with
        store, the run also fails when an instance's Hive library files
        (strategy_box.hive, folder_box.hive) are not byte for byte what
        they were when it started.
        --cloud-store send passes --cloud-store=send to every instance: the
        store reads the open cloud strategy and sends its queue to the
        server.
        --second-account gives the main instance a second account, which a
        {"signIn": "second"} step signs in to.
        --kill-after-seconds kills the main instance with SIGKILL S seconds
        after it starts, the way a crash stops it, and counts that as a
        pass; an app that finished first is judged as usual. Start the next
        run with --hive-store <this run's out>/store-main to see what it
        left.
        --main-scope starts the main instance in a systemd user scope of
        that name, apart from the companion, so a harness can cut its
        network alone (tool/drive/linux-cloud-store-late.sh).

run exits 0 when every instance finished its script with SUMMARY ... CLEAN
and quit before the timeout (default 900 s), 1 when anything else happened,
and 2 when the script cannot run here or the command was wrong.
''';

const productionDeployment = 'basic-dove-69';

const linuxRefusedSteps = {
  'clipboard':
      'puts a picture on the Windows clipboard through PowerShell; run it on '
          'Windows with tool/drive/run.ps1',
};

const windowsOnlyEnvironment = {'ICARUS_DRIVE_SET_CLIPBOARD'};

const _accountsPath = '.agents/secrets/icarus/test-accounts.md';

class UsageError implements Exception {
  UsageError(this.message);
  final String message;
  @override
  String toString() => message;
}

List<String> convexDefines(String? url) {
  if (url == null) return const [];
  final match =
      RegExp(r'^https://([a-z0-9-]+)\.convex\.cloud/?$').firstMatch(url);
  if (match == null) {
    throw UsageError(
      '--convex must be a https://<deployment>.convex.cloud URL, got "$url"',
    );
  }
  final deployment = match.group(1)!;
  if (deployment == productionDeployment) {
    throw UsageError('$deployment is production; driver builds never use it.');
  }
  return [
    '--dart-define=ICARUS_CONVEX_DEPLOYMENT_URL=https://$deployment.convex.cloud',
    '--dart-define=ICARUS_CONVEX_CLIENT_ID=dev:$deployment',
  ];
}

Map<String, String> parseOptions(Iterable<String> args, Set<String> known) {
  final options = <String, String>{};
  final queue = args.toList();
  for (var i = 0; i < queue.length; i++) {
    final arg = queue[i];
    if (!arg.startsWith('--')) throw UsageError('unexpected "$arg"');
    final eq = arg.indexOf('=');
    final name = eq < 0 ? arg.substring(2) : arg.substring(2, eq);
    if (!known.contains(name)) throw UsageError('unknown option --$name');
    if (options.containsKey(name)) throw UsageError('--$name given twice');
    if (eq >= 0) {
      options[name] = arg.substring(eq + 1);
    } else if (i + 1 < queue.length && !queue[i + 1].startsWith('--')) {
      options[name] = queue[++i];
    } else {
      throw UsageError('--$name needs a value');
    }
  }
  return options;
}

String? passwordFor(String email, String accountsTable) {
  for (final line in const LineSplitter().convert(accountsTable)) {
    final cells = line.split('|');
    if (cells.length > 2 &&
        cells[0].trim().isEmpty &&
        cells[1].trim() == email) {
      return cells[2].trim();
    }
  }
  return null;
}

List<String> refusalsFor(String scriptName, List<Object?> steps) => <String>{
      for (final step in steps)
        if (step is Map && step.isNotEmpty)
          if (linuxRefusedSteps[step.keys.first] case final String why)
            '$scriptName uses the ${step.keys.first} step, which $why.',
    }.toList();

bool signsIn(List<Object?> steps) =>
    steps.any((step) => step is Map && step.containsKey('signIn'));

bool exportsMp4(String scriptText) => RegExp(r'\.mp4"').hasMatch(scriptText);

final _summaryLine = RegExp(r'^\d\d:\d\d:\d\d\.\d{3} SUMMARY ');
final _cleanSummary = RegExp(
  r'^\d\d:\d\d:\d\d\.\d{3} SUMMARY '
  r'steps=\d+ failed=0 flutterErrors=0 misplaced=0 CLEAN$',
);

String? lastSummary(List<String> logLines) {
  final last = logLines.lastWhere(
    (line) => line.trim().isNotEmpty,
    orElse: () => '',
  );
  return _summaryLine.hasMatch(last) ? last : null;
}

bool isCleanSummary(String summary) => _cleanSummary.hasMatch(summary);

Directory get _repo {
  final script = File(Platform.script.toFilePath());
  if (!script.path.endsWith('linux.dart')) {
    throw UsageError('run it as: dart tool/drive/linux.dart ...');
  }
  return script.parent.parent.parent;
}

String _absolute(String path) => File(path).absolute.path;

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(usage);
    exit(args.isEmpty ? 2 : 0);
  }
  try {
    if (!Platform.isLinux) {
      throw UsageError(
        'This runner is for Linux. On Windows use tool/drive/build.ps1 and '
        'tool/drive/run.ps1.',
      );
    }
    final rest = args.skip(1);
    switch (args.first) {
      case 'build':
        exit(await _build(parseOptions(rest, {'out', 'mode', 'convex'})));
      case 'run':
        exit(await runScripts(parseOptions(rest, {
          'exe',
          'script',
          'account',
          'companion',
          'companion-account',
          'out',
          'accounts-file',
          'accounts-host',
          'timeout-seconds',
          'hive-store',
          'library-store',
          'cloud-store',
          'second-account',
          'kill-after-seconds',
          'main-scope',
        })));
      default:
        throw UsageError('no command called "${args.first}"; see --help');
    }
  } on UsageError catch (error) {
    stderr.writeln(error.message);
    exit(2);
  }
}

Future<int> _build(Map<String, String> options) async {
  final mode = options['mode'] ?? 'release';
  if (mode != 'release' && mode != 'debug') {
    throw UsageError('--mode is release or debug, not "$mode"');
  }
  if (options.containsKey('convex') && options['convex']!.isEmpty) {
    throw UsageError('--convex is empty.');
  }
  final defines = convexDefines(options['convex']);
  final repo = _repo;
  final out = Directory(
    _absolute(options['out'] ?? '${repo.path}/build/drive-linux'),
  );
  if (out.existsSync() &&
      out.listSync().isNotEmpty &&
      !File('${out.path}/icarus').existsSync()) {
    throw UsageError(
      '${out.path} holds something other than a driver build; '
      'give --out a new folder.',
    );
  }
  final flutter = await Process.start(
    'flutter',
    [
      'build',
      'linux',
      '--$mode',
      '--dart-define=ICARUS_DRIVE=true',
      '--dart-define=ICARUS_CLOUD_ENVIRONMENT=development',
      ...defines,
    ],
    workingDirectory: repo.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final built = await flutter.exitCode;
  if (built != 0) return built;
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.parent.createSync(recursive: true);
  final copy = await Process.run('cp', [
    '-a',
    '--reflink=auto',
    '${repo.path}/build/linux/x64/$mode/bundle',
    out.path,
  ]);
  if (copy.exitCode != 0) {
    stderr.write(copy.stderr);
    return copy.exitCode;
  }
  stdout.writeln('built ${out.path}');
  return 0;
}

bool signsInAsSecond(List<Object?> steps) =>
    steps.any((step) => step is Map && step['signIn'] == 'second');

class _Instance {
  _Instance(this.name, this.script, this.email, {this.second});
  final String name;
  final String script;
  final String? email;
  final String? second;
  Process? process;
  var timedOut = false;
  var killed = false;
  final exited = Completer<int>();
}

List<String> storeArgs(Map<String, String> options) {
  final libraryStore = options['library-store'];
  if (libraryStore != null &&
      !const {'off', 'shadow', 'mirror', 'read', 'ops', 'store'}
          .contains(libraryStore)) {
    throw UsageError(
      '--library-store is off, shadow, mirror, read or ops, not "$libraryStore"',
    );
  }
  final cloudStore = options['cloud-store'];
  if (cloudStore != null && cloudStore != 'send') {
    throw UsageError('--cloud-store is send, not "$cloudStore"');
  }
  return [
    if (libraryStore != null) '--library-store=$libraryStore',
    if (cloudStore != null) '--cloud-store=$cloudStore',
  ];
}

Future<int> runScripts(Map<String, String> options) async {
  final appArgs = storeArgs(options);
  final scriptPath =
      options['script'] ?? (throw UsageError('run needs --script; see --help'));
  final timeout = int.tryParse(options['timeout-seconds'] ?? '900') ??
      (throw UsageError('--timeout-seconds takes a whole number'));
  final killAfter = switch (options['kill-after-seconds']) {
    null => null,
    final text => double.tryParse(text) ??
        (throw UsageError('--kill-after-seconds takes a number')),
  };
  final exeOption = options['exe'] ?? '${_repo.path}/build/drive-linux';
  final exe = FileSystemEntity.isDirectorySync(exeOption)
      ? '${_absolute(exeOption)}/icarus'
      : _absolute(exeOption);
  if (!File(exe).existsSync()) {
    throw UsageError(
      'No driver build at $exe; make one with: dart tool/drive/linux.dart build',
    );
  }

  final instances = [
    _Instance(
      'main',
      _absolute(scriptPath),
      options['account'],
      second: options['second-account'],
    ),
    if (options['companion'] case final String companion)
      _Instance(
        'companion',
        _absolute(companion),
        options['companion-account'] ?? options['account'],
      ),
  ];
  final refusals = <String>[];
  final needsPassword = <String>{};
  for (final instance in instances) {
    final file = File(instance.script);
    if (!file.existsSync()) throw UsageError('No script at ${instance.script}');
    final text = file.readAsStringSync();
    final List<Object?> steps;
    try {
      steps = jsonDecode(text) as List<Object?>;
    } catch (error) {
      throw UsageError('${instance.script} is not a list of steps: $error');
    }
    final name = instance.script.split('/').last;
    refusals.addAll(refusalsFor(name, steps));
    if (exportsMp4(text) && !_onPath('ffmpeg')) {
      refusals.add(
        '$name exports MP4, and the app finds no ffmpeg on PATH; '
        'install it with: sudo apt-get install -y ffmpeg',
      );
    }
    if (signsIn(steps)) {
      final email = instance.email ??
          (throw UsageError(
            '$name signs in; give the account with --account '
            '(or --companion-account for the companion).',
          ));
      needsPassword.add(email);
    }
    if (signsInAsSecond(steps)) {
      needsPassword.add(
        instance.second ??
            (throw UsageError(
              '$name signs in to a second account; give it with '
              '--second-account.',
            )),
      );
    }
  }
  if (refusals.isNotEmpty) {
    stderr.writeln('Cannot run this on Linux:');
    for (final refusal in refusals) {
      stderr.writeln('  $refusal');
    }
    return 2;
  }
  if (!_onPath('Xvfb')) {
    throw UsageError('Xvfb is missing: sudo apt-get install -y xvfb');
  }

  final passwords = await _passwords(needsPassword, options);

  final run = List.generate(8, (_) => Random.secure().nextInt(16))
      .map((digit) => digit.toRadixString(16))
      .join();
  final out = Directory(
    _absolute(options['out'] ?? '${File(exe).parent.parent.path}/drive-$run'),
  );
  out.createSync(recursive: true);
  try {
    File('${out.path}/run-id').createSync(exclusive: true);
  } on FileSystemException {
    throw UsageError('${out.path} is not empty; give each run a new --out');
  }
  File('${out.path}/run-id').writeAsStringSync(run);
  if (out.listSync().length != 1) {
    throw UsageError('${out.path} is not empty; give each run a new --out');
  }
  Directory('${out.path}/signals').createSync();
  if (options['hive-store'] case final String seed) {
    if (!Directory(seed).existsSync()) {
      throw UsageError('No Hive store at $seed');
    }
    final copy = await Process.run('cp', [
      '-r',
      '--reflink=auto',
      '${_absolute(seed)}/.',
      '${out.path}/store-main',
    ]);
    if (copy.exitCode != 0) {
      throw UsageError('Could not copy $seed: ${copy.stderr}');
    }
  }

  _Screen? screen;
  Future<void> stopAll() async {
    await Future.wait([for (final instance in instances) _stop(instance)]);
    await screen?.stop();
  }

  final stopping = [
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
      signal.watch().listen((_) async {
        stderr.writeln('stopping run $run');
        await stopAll();
        exit(1);
      }),
  ];

  final hiveLibrary = options['library-store'] == 'store'
      ? {
          for (final instance in instances)
            for (final box in hiveLibraryFiles)
              if (File('${out.path}/store-${instance.name}/$box')
                  case final file when file.existsSync())
                file.path: file.readAsBytesSync(),
        }
      : const <String, List<int>>{};

  try {
    screen = await _Screen.launch(out.path);
    final display = await screen.display();
    for (final instance in instances) {
      await _start(
        instance,
        exe,
        out.path,
        run,
        display,
        passwords,
        appArgs,
        scope: instance.name == 'main' ? options['main-scope'] : null,
      );
    }
    if (killAfter != null) {
      final main = instances.first;
      unawaited(
        Future<void>.delayed(
          Duration(milliseconds: (killAfter * 1000).round()),
          () {
            if (main.exited.isCompleted) return;
            main.killed = true;
            Process.killPid(-main.process!.pid, ProcessSignal.sigkill);
          },
        ),
      );
    }
    await Future.wait([
      for (final instance in instances)
        instance.exited.future.timeout(
          Duration(seconds: timeout),
          onTimeout: () {
            instance.timedOut = true;
            return _stop(instance);
          },
        ),
    ]);
    var clean = true;
    for (final instance in instances) {
      clean = await _report(instance, out.path, timeout) && clean;
    }
    for (final MapEntry(key: path, value: before) in hiveLibrary.entries) {
      final file = File(path);
      if (!file.existsSync() || !_sameBytes(file.readAsBytesSync(), before)) {
        stdout.writeln('the store mode changed the Hive library file $path');
        clean = false;
      }
    }
    stdout.writeln('logs and shots: ${out.path}');
    return clean ? 0 : 1;
  } finally {
    for (final subscription in stopping) {
      await subscription.cancel();
    }
    await stopAll();
  }
}

bool _onPath(String program) =>
    Process.runSync('sh', ['-c', 'command -v "\$1"', 'sh', program]).exitCode ==
    0;

Future<Map<String, String>> _passwords(
  Set<String> emails,
  Map<String, String> options,
) async {
  if (emails.isEmpty) return const {};
  final file = File(
    options['accounts-file'] ??
        '${Platform.environment['HOME']}/$_accountsPath',
  );
  final String table;
  if (file.existsSync()) {
    table = file.readAsStringSync();
  } else if (options.containsKey('accounts-file')) {
    throw UsageError('No accounts file at ${file.path}');
  } else {
    final host = options['accounts-host'] ?? 'windows';
    final read = await Process.run('ssh', [
      '-o',
      'BatchMode=yes',
      '-o',
      'LogLevel=ERROR',
      host,
      'type %USERPROFILE%\\${_accountsPath.replaceAll('/', '\\')}',
    ]);
    if (read.exitCode != 0) {
      throw UsageError(
        'Could not read the test accounts over ssh from $host '
        '(exit ${read.exitCode}). Pass --accounts-file or --accounts-host.',
      );
    }
    table = read.stdout as String;
  }
  return {
    for (final email in emails)
      email: passwordFor(email, table) ??
          (throw UsageError('No row for $email in the test accounts file')),
  };
}

class _Screen {
  _Screen(this._process, this._out);
  final Process _process;
  final String _out;

  static Future<_Screen> launch(String out) async {
    final process = await Process.start('Xvfb', [
      '-displayfd',
      '1',
      '-screen',
      '0',
      '3840x2160x24',
      '-nolisten',
      'tcp',
      '-noreset',
    ]);
    unawaited(process.stderr.pipe(File('$out/xvfb.log').openWrite()));
    return _Screen(process, out);
  }

  Future<String> display() async {
    final number = await _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 20), onTimeout: () => '');
    if (int.tryParse(number.trim()) == null) {
      throw StateError('Xvfb did not start; see $_out/xvfb.log');
    }
    return ':${number.trim()}';
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

Future<void> _start(
  _Instance instance,
  String exe,
  String out,
  String run,
  String display,
  Map<String, String> passwords,
  List<String> appArgs, {
  String? scope,
}) async {
  final name = instance.name;
  final home = '$out/home-$name';
  final email = instance.email;
  final command = [
    'setsid',
    exe,
    '--hive-store-dir=$out/store-$name',
    ...appArgs
  ];
  final process = await Process.start(
    scope == null ? command.first : 'systemd-run',
    scope == null
        ? command.skip(1).toList()
        : ['--user', '--scope', '--quiet', '--unit=$scope', ...command],
    workingDirectory: out,
    environment: {
      'DISPLAY': display,
      'GDK_BACKEND': 'x11',
      'WAYLAND_DISPLAY': '',
      'NO_AT_BRIDGE': '1',
      'XDG_DATA_HOME': '$home/data',
      'XDG_CONFIG_HOME': '$home/config',
      'XDG_CACHE_HOME': '$home/cache',
      'ICARUS_DRIVE_SCRIPT': instance.script,
      'ICARUS_DRIVE_LOG': '$out/$name.log',
      'ICARUS_DRIVE_RUN': run,
      'ICARUS_DRIVE_OUT': out,
      'ICARUS_DRIVE_SIGNALS': '$out/signals',
      'ICARUS_DRIVE_SESSION': '$out/session-$name.json',
      if (email != null) 'ICARUS_DRIVE_EMAIL': email,
      if (passwords[email] case final String password)
        'ICARUS_DRIVE_PASSWORD': password,
      if (instance.second case final String second)
        'ICARUS_DRIVE_EMAIL_2': second,
      if (passwords[instance.second] case final String password)
        'ICARUS_DRIVE_PASSWORD_2': password,
    },
  );
  instance.process = process;
  unawaited(process.stdout.pipe(File('$out/$name-app.out').openWrite()));
  unawaited(process.stderr.pipe(File('$out/$name-app.err').openWrite()));
  unawaited(process.exitCode.then(instance.exited.complete));
}

Future<int> _stop(_Instance instance) async {
  final process = instance.process;
  if (process == null) return -1;
  Future<int> leaderExit(int seconds) => instance.exited.future
      .timeout(Duration(seconds: seconds), onTimeout: () => -1);
  Process.killPid(-process.pid, ProcessSignal.sigterm);
  await leaderExit(5);
  Process.killPid(-process.pid, ProcessSignal.sigkill);
  return leaderExit(2);
}

Future<bool> _report(_Instance instance, String out, int timeout) async {
  final name = instance.name;
  if (instance.killed) {
    stdout.writeln('$name: killed with SIGKILL as asked');
    return true;
  }
  final log = File('$out/$name.log');
  final lines = log.existsSync() ? log.readAsLinesSync() : const <String>[];
  for (final line in lines) {
    if (RegExp(r' (FAIL|FLUTTER-ERROR|MISPLACED) ').hasMatch(line)) {
      stdout.writeln('$name: $line');
    }
  }
  final summary = lastSummary(lines);
  stdout.writeln(
    '$name: ${summary ?? 'no SUMMARY (the script never finished)'}',
  );
  final exitCode =
      instance.process == null ? null : await instance.exited.future;
  if (instance.timedOut) {
    stdout.writeln('$name: timed out after $timeout s');
  } else if (exitCode != 0) {
    stdout.writeln(
      '$name: the app quit with '
      '${exitCode == null ? 'no process started' : _describeExit(exitCode)}',
    );
  }
  if (summary == null) {
    for (final error in _appErrors(out, name)) {
      stdout.writeln('$name: the app reported $error');
    }
  }
  return summary != null &&
      isCleanSummary(summary) &&
      !instance.timedOut &&
      exitCode == 0;
}

const hiveLibraryFiles = ['strategy_box.hive', 'folder_box.hive'];

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _describeExit(int code) =>
    code < 0 ? 'signal ${-code}' : 'exit code $code';

Iterable<String> _appErrors(String out, String name) {
  final log = File('$out/home-$name/data/com.example.icarus/icarus_debug.log');
  if (!log.existsSync()) return const [];
  return log
      .readAsLinesSync()
      .where((line) => line.startsWith('Error: '))
      .take(5);
}
