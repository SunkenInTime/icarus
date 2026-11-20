import 'dart:convert';

import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/drawing_provider.dart';

sealed class CloudElementReading {
  const CloudElementReading();
}

/// A [PlacedAgentNode], [PlacedAbility], [DrawingElement], [PlacedText],
/// [PlacedImage] or [PlacedUtility].
final class DrawnCloudElement extends CloudElementReading {
  const DrawnCloudElement(this.item);

  final Object item;
}

final class UnreadableCloudElement extends CloudElementReading {
  const UnreadableCloudElement(this.error);

  final Object error;
}

final class UnknownKindCloudElement extends CloudElementReading {
  const UnknownKindCloudElement();
}

/// [data] is the element's payload data.
CloudElementReading readCloudElement(
  String elementType,
  Map<String, dynamic> data,
) {
  final Object? Function()? decode = switch (elementType) {
    'agent' => () => PlacedAgentNode.fromJson(data),
    'ability' => () => PlacedAbility.fromJson(data),
    'drawing' => () => DrawingProvider.fromJson(jsonEncode([data])).firstOrNull,
    'text' => () => PlacedText.fromJson(data),
    'image' => () => PlacedImage.fromJson(data),
    'utility' => () => PlacedUtility.fromJson(data),
    _ => null,
  };
  if (decode == null) return const UnknownKindCloudElement();
  try {
    return switch (decode()) {
      final Object item => DrawnCloudElement(item),
      null => const UnreadableCloudElement('Decodes to nothing.'),
    };
  } on Object catch (error) {
    return UnreadableCloudElement(error);
  }
}
