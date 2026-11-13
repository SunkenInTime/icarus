import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/services/debug_breadcrumbs.dart';

/// The app's binding: Flutter's own, with the text input trace below on its
/// messenger. Create it first thing in main, in place of
/// `WidgetsFlutterBinding.ensureInitialized()`.
class IcarusBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      TextInputTraceMessenger(super.createBinaryMessenger());
}

/// Passes every platform message through unchanged, and writes the text
/// input ones to [DebugBreadcrumbs].
///
/// A text field talks to the system's text input (the keyboard, an IME)
/// over one channel: the app attaches a field with setClient, sends what
/// it holds with setEditingState, and lets go with clearClient; the system
/// sends back what the user typed. When the two sides disagree about which
/// field is attached, the system refuses a message, and Flutter reports it
/// with a stack that says nothing about which field or why. This trace is
/// the order those messages went in, so a debug report shows it.
///
/// It records the method, the client id and the text's length and
/// selection, never the text.
class TextInputTraceMessenger implements BinaryMessenger {
  TextInputTraceMessenger(this._inner);

  final BinaryMessenger _inner;

  static final String _channel = SystemChannels.textInput.name;
  static const MethodCodec _codec = JSONMethodCodec();

  /// Calls sent often enough to bury the rest, whose content never decides
  /// whether a field is attached.
  static const _quiet = {
    'TextInput.show',
    'TextInput.hide',
    'TextInput.requestAutofill',
    'TextInput.setEditableSizeAndTransform',
    'TextInput.setMarkedTextRect',
    'TextInput.setCaretRect',
    'TextInput.setSelectionRects',
    'TextInput.setStyle',
  };

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      _inner.handlePlatformMessage(channel, data, callback);

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    final reply = _inner.send(channel, message);
    if (channel != _channel) return reply;
    final call = _decode(message);
    if (call == null || _quiet.contains(call.method)) return reply;
    final what = 'app sent ${_shortName(call.method)}';
    DebugBreadcrumbs.add('text input', what, detail: describeCall(call));
    // Watch the reply beside the caller, without changing what it awaits.
    reply?.then((data) {
      if (data == null) return;
      try {
        _codec.decodeEnvelope(data);
      } on PlatformException catch (error) {
        DebugBreadcrumbs.add(
          'text input',
          'system refused ${_shortName(call.method)}',
          detail: '${error.code}: ${error.message}',
        );
      } catch (_) {
        // Not ours to judge; the caller sees the same reply.
      }
    }, onError: (Object _) {});
    return reply;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    if (channel != _channel || handler == null) {
      _inner.setMessageHandler(channel, handler);
      return;
    }
    _inner.setMessageHandler(channel, (data) {
      final call = _decode(data);
      if (call != null) {
        DebugBreadcrumbs.add(
          'text input',
          'system sent ${_shortName(call.method)}',
          detail: describeCall(call),
        );
      }
      return handler(data);
    });
  }

  static MethodCall? _decode(ByteData? data) {
    if (data == null) return null;
    try {
      return _codec.decodeMethodCall(data);
    } catch (_) {
      return null;
    }
  }

  static String _shortName(String method) =>
      method.substring(method.indexOf('.') + 1);

  /// The particulars of [call] worth reading, without the text it carries.
  @visibleForTesting
  static String? describeCall(MethodCall call) {
    final args = call.arguments;
    switch (call.method) {
      case 'TextInput.setClient':
        if (args is! List || args.length < 2) return null;
        final config = args[1];
        final type = config is Map ? config['inputType'] : null;
        return [
          'client ${args[0]}',
          if (type is Map && type['name'] != null) '${type['name']}',
          if (config is Map && config['viewId'] != null)
            'view ${config['viewId']}',
        ].join(', ');
      case 'TextInput.setEditingState':
        return args is Map ? _describeValue(args) : null;
      case 'TextInputClient.updateEditingState':
        if (args is! List || args.length < 2 || args[1] is! Map) return null;
        return 'client ${args[0]}, ${_describeValue(args[1] as Map)}';
      case 'TextInputClient.updateEditingStateWithDeltas':
        if (args is! List || args.isEmpty) return null;
        final deltas = args.length > 1 && args[1] is Map
            ? (args[1] as Map)['deltas']
            : null;
        return [
          'client ${args[0]}',
          if (deltas is List) '${deltas.length} changes',
        ].join(', ');
      case 'TextInputClient.performAction':
        if (args is! List || args.length < 2) return null;
        return 'client ${args[0]}, ${args[1]}';
      default:
        if (args is List && args.isNotEmpty && args[0] is int) {
          return 'client ${args[0]}';
        }
        return null;
    }
  }

  static String _describeValue(Map value) {
    final text = value['text'];
    String range(String start, String end) {
      final a = value[start];
      final b = value[end];
      if (a == null || b == null || (a == -1 && b == -1)) return 'none';
      return a == b ? '$a' : '$a-$b';
    }

    return [
      'length ${text is String ? text.length : '?'}',
      'selection ${range('selectionBase', 'selectionExtent')}',
      'composing ${range('composingBase', 'composingExtent')}',
    ].join(', ');
  }
}
