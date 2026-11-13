import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/debug_breadcrumb_sources.dart';
import 'package:icarus/services/debug_breadcrumbs.dart';
import 'package:icarus/services/text_input_trace.dart';

const _codec = JSONMethodCodec();

/// Answers every message with [reply] and remembers what reached it.
class _FakeMessenger implements BinaryMessenger {
  _FakeMessenger({this.reply});

  final ByteData? reply;
  final sent = <String>[];
  final handlers = <String, MessageHandler?>{};

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    sent.add(channel);
    return Future.value(reply);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      handlers[channel] = handler;

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) async {}
}

ByteData _call(String method, [Object? args]) =>
    _codec.encodeMethodCall(MethodCall(method, args));

Map<String, Object> _editingState(String text) => {
      'text': text,
      'selectionBase': text.length,
      'selectionExtent': text.length,
      'composingBase': -1,
      'composingExtent': -1,
    };

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final textInput = SystemChannels.textInput.name;

  setUp(DebugBreadcrumbs.clear);

  group('DebugBreadcrumbs', () {
    test('a step repeated back to back is one line with a count', () {
      DebugBreadcrumbs.add('canvas', 'addition text');
      DebugBreadcrumbs.add('text input', 'system sent updateEditingState',
          detail: 'length 1');
      DebugBreadcrumbs.add('text input', 'system sent updateEditingState',
          detail: 'length 2');
      DebugBreadcrumbs.add('focus', 'nothing');

      final lines = DebugBreadcrumbs.describe()!.split('\n');
      expect(lines, hasLength(3));
      expect(lines[0], endsWith('canvas: addition text'));
      expect(lines[1], contains('updateEditingState (length 2) x2, last '));
      expect(lines[2], endsWith('focus: nothing'));
    });

    test('keeps only the latest steps', () {
      for (var i = 0; i < DebugBreadcrumbs.capacity + 5; i++) {
        DebugBreadcrumbs.add('canvas', 'step $i');
      }
      final lines = DebugBreadcrumbs.describe()!.split('\n');
      expect(lines, hasLength(DebugBreadcrumbs.capacity));
      expect(lines.first, endsWith('step 5'));
      expect(lines.last, endsWith('step ${DebugBreadcrumbs.capacity + 4}'));
    });
  });

  group('TextInputTraceMessenger', () {
    test('records what the app sends, without the text', () async {
      final inner = _FakeMessenger(reply: _codec.encodeSuccessEnvelope(null));
      final messenger = TextInputTraceMessenger(inner);

      await messenger.send(
        textInput,
        _call('TextInput.setClient', [
          7,
          {
            'inputType': {'name': 'TextInputType.multiline'},
            'viewId': 0,
          },
        ]),
      );
      await messenger.send(
        textInput,
        _call('TextInput.setEditingState', _editingState('Smoke B main')),
      );
      await messenger.send(textInput, _call('TextInput.clearClient'));
      await _settle();

      final trail = DebugBreadcrumbs.describe()!;
      expect(
          trail,
          contains(
              'app sent setClient (client 7, TextInputType.multiline, view 0)'));
      expect(
          trail,
          contains('app sent setEditingState '
              '(length 12, selection 12, composing none)'));
      expect(trail, contains('app sent clearClient'));
      expect(trail, isNot(contains('Smoke')));
      expect(inner.sent, [textInput, textInput, textInput]);
    });

    test('records a message the system refused, and passes it on', () async {
      final refusal = _codec.encodeErrorEnvelope(
        code: 'Internal Consistency Error',
        message: 'Set editing state has been invoked, but no client is set.',
      );
      final messenger = TextInputTraceMessenger(_FakeMessenger(reply: refusal));

      final reply = await messenger.send(
        textInput,
        _call('TextInput.setEditingState', _editingState('A')),
      );
      await _settle();

      expect(reply, same(refusal));
      expect(
        DebugBreadcrumbs.describe(),
        contains('system refused setEditingState (Internal Consistency Error: '
            'Set editing state has been invoked, but no client is set.)'),
      );
    });

    test('records what the system sends, without the text', () async {
      final inner = _FakeMessenger();
      final messenger = TextInputTraceMessenger(inner);
      final received = <MethodCall>[];
      messenger.setMessageHandler(textInput, (data) async {
        received.add(_codec.decodeMethodCall(data));
        return null;
      });

      await inner.handlers[textInput]!(
        _call('TextInputClient.updateEditingState', [7, _editingState('Hi')]),
      );

      expect(received.single.method, 'TextInputClient.updateEditingState');
      expect(
        DebugBreadcrumbs.describe(),
        contains('system sent updateEditingState '
            '(client 7, length 2, selection 2, composing none)'),
      );
      expect(DebugBreadcrumbs.describe(), isNot(contains('Hi')));
    });

    test('leaves other channels and per-frame calls out', () async {
      final inner = _FakeMessenger();
      final messenger = TextInputTraceMessenger(inner);
      void handler(ByteData? _) {}
      Future<ByteData?> otherHandler(ByteData? data) async {
        handler(data);
        return null;
      }

      await messenger.send('flutter/platform', _call('Clipboard.setData'));
      await messenger.send(
        textInput,
        _call('TextInput.setEditableSizeAndTransform', {'width': 10}),
      );
      messenger.setMessageHandler('flutter/keyevent', otherHandler);

      expect(DebugBreadcrumbs.describe(), isNull);
      expect(inner.handlers['flutter/keyevent'], same(otherHandler));
    });
  });

  group('debug report', () {
    tearDown(() => AppErrorReporter.describeSession = null);

    test('opens with the build and the session, fenced for pasting', () {
      AppErrorReporter.describeSession = () => ['Account: signed out'];
      DebugBreadcrumbs.add('canvas', 'addition text');

      final report = AppErrorReporter.buildClipboardReport([
        DebugLogEntry(
          timestamp: DateTime(2026, 11, 13, 2, 34, 19),
          level: DebugLogLevel.info,
          message: 'Started',
        ),
      ]);

      expect(report, startsWith('```text\nIcarus Debug Report\n'));
      expect(report, endsWith('\n```'));
      expect(
        report,
        contains('App version: ${Settings.versionName} '
            '(build ${Settings.versionNumber})'),
      );
      expect(report, contains('Platform: '));
      expect(report, contains('Account: signed out'));
      expect(report, contains('[2026-11-13 02:34:19] INFO'));
      expect(report, contains('Recent activity (oldest first):\n'));
      expect(report, contains('canvas: addition text'));
    });

    test('a fence inside the report cannot end the block early', () {
      expect(
        AppErrorReporter.asCodeBlock('named ```plant```'),
        "```text\nnamed '''plant'''\n```",
      );
    });

    test('an error keeps what came just before it', () {
      DebugBreadcrumbs.add('focus', 'TextField < _EditableTextWidget');
      final entry = AppErrorReporter.addDebugLog(
        'A UI error occurred.',
        level: DebugLogLevel.error,
        recentActivity: DebugBreadcrumbs.describe(),
      );
      DebugBreadcrumbs.add('canvas', 'later step');

      final text = entry.toClipboardText();
      expect(text, contains('Just before (oldest first):'));
      expect(text, contains('focus: TextField < _EditableTextWidget'));
      expect(text, isNot(contains('later step')));
    });

    test("a Flutter error says where it happened, in Flutter's words", () {
      final described = AppErrorReporter.describeFlutterError(
        FlutterErrorDetails(
          exception: PlatformException(code: 'Internal Consistency Error'),
          library: 'services library',
          context: ErrorDescription('while setting text input editing state'),
        ),
      );

      expect(
        described,
        'A UI error occurred while setting text input editing state. '
        '(services library)',
      );
    });

    test('a widget key, which can be what the user typed, is left out', () {
      final described = AppErrorReporter.describeFlutterError(
        FlutterErrorDetails(
          exception: StateError('boom'),
          library: 'widgets library',
          context: ErrorDescription(
            "building _FeedbackTextWidget-[<'Smoke ]B main'>](dirty)",
          ),
          informationCollector: () => [
            ErrorDescription('RenderParagraph text: "Smoke B main"'),
          ],
        ),
      );

      expect(
        described,
        'A UI error occurred building _FeedbackTextWidget. (widgets library)',
      );
    });
  });

  group('describeFocus', () {
    test('says nothing has focus', () {
      expect(describeFocus(null), 'nothing');
    });

    testWidgets('names the field and where it is, not what it holds',
        (tester) async {
      final controller = TextEditingController(text: 'Smoke B main');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              child: TextField(controller: controller),
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      final described = describeFocus(FocusManager.instance.primaryFocus);
      expect(described, startsWith('TextField at 0,'));
      expect(described, contains(' 200x'));
      expect(described, endsWith(' on MaterialPageRoute'));
      expect(described, isNot(contains('Smoke')));
    });
  });
}
