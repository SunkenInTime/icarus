import 'dart:convert';

import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/drawing_provider.dart';

/// The canvas item a cloud element of [elementType] with [data] (its
/// payload's data) hydrates into: a [PlacedAgentNode], [PlacedAbility],
/// [DrawingElement], [PlacedText], [PlacedImage] or [PlacedUtility]. Null
/// for a kind this build does not draw, or a drawing that decodes to
/// nothing. Throws when the data can't be read as its kind.
Object? decodeCloudElement(String elementType, Map<String, dynamic> data) {
  switch (elementType) {
    case 'agent':
      return PlacedAgentNode.fromJson(data);
    case 'ability':
      return PlacedAbility.fromJson(data);
    case 'drawing':
      return DrawingProvider.fromJson(jsonEncode([data])).firstOrNull;
    case 'text':
      return PlacedText.fromJson(data);
    case 'image':
      return PlacedImage.fromJson(data);
    case 'utility':
      return PlacedUtility.fromJson(data);
  }
  return null;
}
