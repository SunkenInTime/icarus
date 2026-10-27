import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/local_image_file.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:uuid/uuid.dart';

/// A picture shown by something copied, carried as its bytes so a paste
/// can place it in another strategy.
typedef CopiedPicture = ({Uint8List bytes, String fileExtension});

/// The most picture bytes one copy carries. Past it, the rest are left out
/// and the copy pastes into its own strategy only.
const _maxCopiedPictureBytes = 200 * 1024 * 1024;

/// What Ctrl+C took: copies of the selected items as they were, from the
/// strategy and map they were on. It lives in this window only, never on
/// the system clipboard, so nothing copied ever has to be read back by
/// another version of Icarus.
class CanvasClipboard {
  CanvasClipboard({
    required this.map,
    required this.strategyId,
    required this.agents,
    required this.abilities,
    required this.texts,
    required this.images,
    required this.utilities,
    required this.drawings,
    required this.lineups,
    required this.pictures,
  });

  final MapValue map;
  final String? strategyId;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedText> texts;
  final List<PlacedImage> images;
  final List<PlacedUtility> utilities;
  final List<DrawingElement> drawings;
  final LineUpGraph lineups;

  /// The bytes of every picture these show, by picture id, read after the
  /// copy; null for one that could not be read (still uploading, offline,
  /// or past the copy's limit). Only a paste into another strategy waits
  /// for them.
  final Future<Map<String, CopiedPicture?>> pictures;

  int get itemCount =>
      agents.length +
      abilities.length +
      texts.length +
      images.length +
      utilities.length +
      drawings.length +
      lineups.links.length;
}

/// Why a paste put nothing on the page, for the editor to say.
enum PasteRefusal {
  /// What was copied belongs on another map.
  otherMap,

  /// A picture in it could not be read when it was copied.
  picturesMissing,

  /// A picture in it is larger than a cloud strategy takes.
  pictureTooLarge,

  /// The page on screen changed while its pictures were saved.
  pageChanged,
}

final canvasClipboardProvider =
    NotifierProvider<CanvasClipboardNotifier, CanvasClipboard?>(
  CanvasClipboardNotifier.new,
);

class CanvasClipboardNotifier extends Notifier<CanvasClipboard?> {
  static const _uuid = Uuid();

  @override
  CanvasClipboard? build() {
    // What one account copied never pastes into another's strategies.
    ref.listen(cloudMediaAccountIdProvider, (previous, next) {
      if (previous != next) state = null;
    });
    return null;
  }

  /// Puts copies of the selected items on the clipboard. [readPictures]
  /// fetches the bytes behind the pictures they show (see
  /// [readCopiedPictures]). Returns how many items were copied.
  int copySelection(
    Future<Map<String, CopiedPicture?>> Function(Map<String, String>)
        readPictures,
  ) {
    final ids = {for (final item in ref.read(canvasSelectionProvider)) item.id};
    if (ids.isEmpty) return 0;
    bool picked(PlacedWidget item) => ids.contains(item.id);
    final images = [
      for (final image in ref.read(placedImageProvider).images)
        if (picked(image)) clonePlacedImage(image),
    ];
    final lineups = ref.read(lineUpProvider).graph.linksWithSpots(ids);
    final clipboard = CanvasClipboard(
      map: ref.read(mapProvider).currentMap,
      strategyId: ref.read(strategyProvider).strategyId,
      agents: [
        for (final agent in ref.read(agentProvider))
          if (picked(agent)) clonePlacedAgentNode(agent),
      ],
      abilities: [
        for (final ability in ref.read(abilityProvider))
          if (picked(ability)) clonePlacedAbility(ability),
      ],
      texts: [
        for (final text in ref.read(textProvider))
          if (picked(text)) clonePlacedText(text),
      ],
      images: images,
      utilities: [
        for (final utility in ref.read(utilityProvider))
          if (picked(utility)) clonePlacedUtility(utility),
      ],
      drawings: [
        for (final drawing in ref.read(drawingProvider).elements)
          if (ids.contains(drawing.id)) cloneDrawingElement(drawing),
      ],
      lineups: lineups.deepCopy(),
      pictures: readPictures({
        for (final image in images) image.pictureId: image.fileExtension ?? '',
        for (final link in lineups.links)
          for (final image in link.images) image.id: image.fileExtension,
      }),
    );
    if (clipboard.itemCount == 0) return 0;
    state = clipboard;
    return clipboard.itemCount;
  }

  /// Puts copies of what is on the clipboard on the page on screen, where
  /// they were on the page they came from, as one undo step, and selects
  /// them. Pasted into the strategy they came from, they show the same
  /// pictures while those are still there; every other picture is saved
  /// anew from the bytes the copy carried, as an image dropped on the map
  /// is. Returns why nothing was pasted, or null.
  Future<PasteRefusal?> paste() async {
    final clipboard = state;
    if (clipboard == null || !_canEdit) return null;
    if (clipboard.map != ref.read(mapProvider).currentMap) {
      return PasteRefusal.otherMap;
    }
    final strategy = ref.read(strategyProvider);
    final strategyId = strategy.strategyId;
    if (strategyId == null) return null;
    final isCloud = strategy.source == StrategySource.cloud;
    // Everything lands on this page or not at all.
    final pageId = ref.read(strategyPageSessionProvider).activePageId;
    bool stillHere() =>
        ref.read(strategyProvider).strategyId == strategyId &&
        ref.read(strategyPageSessionProvider).activePageId == pageId &&
        _canEdit;

    // Each picture by id, with its file extension.
    final pictureIds = <String, String>{
      for (final image in clipboard.images)
        image.pictureId: image.fileExtension ?? '',
      for (final link in clipboard.lineups.links)
        for (final image in link.images) image.id: image.fileExtension,
    };
    // A picture's new id, by its id where it was copied. A picture keeps
    // its id only in the strategy it came from, and only while it is still
    // there: once its last use is cut, its file is cleaned up and its cloud
    // copy swept, and the paste puts it back from the bytes it carried.
    final newPictureIds = <String, String>{};
    final keep = clipboard.strategyId == strategyId;
    final renew = [
      for (final MapEntry(key: id, value: extension) in pictureIds.entries)
        if (!keep || _gone(id, extension)) id,
    ];
    if (renew.isNotEmpty) {
      final pictures = await clipboard.pictures;
      // The editor may have moved on while the pictures were read.
      if (!stillHere()) return PasteRefusal.pageChanged;
      if (renew.any((id) => pictures[id] == null)) {
        return PasteRefusal.picturesMissing;
      }
      final uploads = isCloud || !ref.read(imageFilesOnDeviceProvider);
      if (uploads &&
          renew.any((id) => pictures[id]!.bytes.length > maxCloudImageBytes)) {
        return PasteRefusal.pictureTooLarge;
      }
      for (final id in renew) {
        newPictureIds[id] = _uuid.v4();
      }
    }
    // Made before anything is written, so a copy that can't be made leaves
    // nothing behind.
    final pasted = _copies(clipboard, newPictureIds);

    if (newPictureIds.isNotEmpty) {
      final pictures = await clipboard.pictures;
      final images = ref.read(placedImageProvider.notifier);
      for (final MapEntry(key: id, value: newId) in newPictureIds.entries) {
        final picture = pictures[id]!;
        await images.saveSecureImage(
          picture.bytes,
          newId,
          picture.fileExtension,
          strategyId: strategyId,
        );
      }
      if (isCloud) await _stageUploads(clipboard, newPictureIds, strategyId);
      if (!stillHere()) {
        if (isCloud) {
          final queue = ref.read(cloudMediaUploadQueueProvider.notifier);
          for (final id in newPictureIds.values) {
            await queue.discardStagedUpload(id);
          }
        }
        return PasteRefusal.pageChanged;
      }
    }

    ref.read(actionProvider.notifier).performTransaction(
      groups: const [],
      mutation: () {
        for (final agent in pasted.agents) {
          ref.read(agentProvider.notifier).addAgent(agent);
        }
        for (final ability in pasted.abilities) {
          ref.read(abilityProvider.notifier).addAbility(ability);
        }
        for (final text in pasted.texts) {
          ref.read(textProvider.notifier).addText(text);
        }
        for (final image in pasted.images) {
          ref.read(placedImageProvider.notifier).addImageCopy(image);
        }
        for (final utility in pasted.utilities) {
          ref.read(utilityProvider.notifier).addUtility(utility);
        }
        ref.read(drawingProvider.notifier).addDrawings(pasted.drawings);
        ref.read(lineUpProvider.notifier).addCopies(pasted.lineups);
      },
    );
    ref.read(canvasSelectionProvider.notifier).select([
      for (final agent in pasted.agents)
        (kind: SelectableKind.agent, id: agent.id),
      for (final ability in pasted.abilities)
        (kind: SelectableKind.ability, id: ability.id),
      for (final text in pasted.texts) (kind: SelectableKind.text, id: text.id),
      for (final image in pasted.images)
        (kind: SelectableKind.image, id: image.id),
      for (final utility in pasted.utilities)
        (kind: SelectableKind.utility, id: utility.id),
      for (final drawing in pasted.drawings)
        (kind: SelectableKind.drawing, id: drawing.id),
      for (final link in pasted.lineups.links)
        (kind: SelectableKind.lineup, id: link.id),
    ]);

    if (isCloud && newPictureIds.isNotEmpty) {
      try {
        await ref
            .read(cloudMediaUploadQueueProvider.notifier)
            .commitStagedMediaReferences(
              strategyPublicId: strategyId,
              assetPublicIds: newPictureIds.values,
            );
      } catch (error, stackTrace) {
        // The pictures stay staged on this device; the sync menu shows
        // them, as it does any image upload that is waiting.
        AppErrorReporter.reportError(
          'Pasted pictures could not be marked for upload: $error',
          error: error,
          stackTrace: stackTrace,
          source: 'canvas_clipboard.paste',
        );
      }
    }
    return null;
  }

  bool get _canEdit =>
      ref.read(currentStrategyCapabilitiesProvider).canEditPages;

  /// Whether picture [id] can no longer be shown in the strategy on screen.
  /// One still uploading is on its way, so it is not gone.
  bool _gone(String id, String fileExtension) => readStrategyImageSourceOf(
        ref,
        (id: id, fileExtension: fileExtension),
      ) is ImageFailed;

  /// Stages the upload of every picture saved anew, as placing an image or
  /// a lineup screenshot does; [paste] then commits them with the items
  /// that show them.
  Future<void> _stageUploads(
    CanvasClipboard clipboard,
    Map<String, String> newPictureIds,
    String strategyId,
  ) async {
    final queue = ref.read(cloudMediaUploadQueueProvider.notifier);
    final lineupPictures = <SimpleImageData>[];
    final placedPictures = {
      for (final image in clipboard.images) image.pictureId,
    };
    for (final link in clipboard.lineups.links) {
      for (final image in link.images) {
        if (placedPictures.contains(image.id)) continue;
        lineupPictures.add(image.copyWith(id: newPictureIds[image.id]));
      }
    }
    for (final image in clipboard.images) {
      if (!placedPictures.remove(image.pictureId)) continue;
      await queue.enqueuePlacedImageUpload(
        strategyPublicId: strategyId,
        imagePublicId: newPictureIds[image.pictureId]!,
        fileExtension: image.fileExtension,
      );
    }
    if (lineupPictures.isNotEmpty) {
      await queue.enqueueLineupMediaJobs(
        strategyPublicId: strategyId,
        images: lineupPictures,
      );
    }
  }

  /// Copies of everything on [clipboard] under ids of their own (see
  /// newStorableCopyId: a pasted item keeps its root, so a page transition
  /// still pairs it with the item it was copied from). Pictures are renamed by
  /// [newPictureIds]: the first image showing a picture takes the picture's
  /// id, as an image placed fresh does, and the rest point at it.
  ({
    List<PlacedAgentNode> agents,
    List<PlacedAbility> abilities,
    List<PlacedText> texts,
    List<PlacedImage> images,
    List<PlacedUtility> utilities,
    List<DrawingElement> drawings,
    LineUpGraph lineups,
  }) _copies(CanvasClipboard clipboard, Map<String, String> newPictureIds) {
    final placedPictures = <String>{};
    PlacedImage imageCopy(PlacedImage image) {
      final picture = newPictureIds[image.pictureId];
      if (picture == null) {
        return image.copyWith(
          id: newStorableCopyId(image.id),
          assetId: image.pictureId,
        );
      }
      final first = placedPictures.add(picture);
      return PlacedImage(
        position: image.position,
        id: first ? picture : newStorableCopyId(image.id),
        aspectRatio: image.aspectRatio,
        scale: image.scale,
        fileExtension: image.fileExtension,
        sizeVersion: image.sizeVersion,
        tagColorValue: image.tagColorValue,
        assetId: first ? null : picture,
      )..link = image.link;
    }

    final lineups = clipboard.lineups.copyOfLinks({
      for (final link in clipboard.lineups.links) link.id,
    }, newId: newStorableCopyId);
    return (
      agents: [
        for (final agent in clipboard.agents)
          switch (agent) {
            PlacedAgent() => agent.copyWith(id: newStorableCopyId(agent.id)),
            PlacedViewConeAgent() =>
              agent.copyWith(id: newStorableCopyId(agent.id)),
            PlacedCircleAgent() =>
              agent.copyWith(id: newStorableCopyId(agent.id)),
          },
      ],
      abilities: [
        for (final ability in clipboard.abilities)
          ability.copyWith(id: newStorableCopyId(ability.id)),
      ],
      texts: [
        for (final text in clipboard.texts)
          text.copyWith(id: newStorableCopyId(text.id), text: text.text),
      ],
      images: [for (final image in clipboard.images) imageCopy(image)],
      utilities: [
        for (final utility in clipboard.utilities)
          utility.copyWith(id: newStorableCopyId(utility.id)),
      ],
      drawings: [
        for (final drawing in clipboard.drawings) _drawingCopy(drawing),
      ],
      lineups: newPictureIds.isEmpty
          ? lineups
          : LineUpGraph(
              origins: lineups.origins,
              landings: lineups.landings,
              links: [
                for (final link in lineups.links)
                  link.copyWith(
                    images: [
                      for (final image in link.images)
                        image.copyWith(id: newPictureIds[image.id]),
                    ],
                  ),
              ],
            ),
    );
  }
}

DrawingElement _drawingCopy(DrawingElement drawing) {
  // Through JSON text: the saved form holds objects (its bounding box)
  // that reading it back expects as maps.
  final json = jsonDecode(jsonEncode(DrawingProvider.elementToJson(drawing)))
      as Map<String, dynamic>;
  final copy = DrawingProvider.elementFromJson({
    ...json,
    'id': newStorableCopyId(drawing.id),
  });
  if (copy is FreeDrawing) copy.rebuildPath(CoordinateSystem.instance);
  return copy;
}

/// Reads the bytes behind each picture in [pictures] (picture id to file
/// extension) the way the editor shows it: from its file, from bytes still
/// uploading, or downloaded from the cloud. A picture that cannot be read
/// comes back null.
Future<Map<String, CopiedPicture?>> readCopiedPictures(
  WidgetRef ref,
  Map<String, String> pictures,
) async {
  final strategyId = ref.read(strategyProvider).strategyId;
  final sources = {
    for (final MapEntry(key: id, value: fileExtension) in pictures.entries)
      id: readStrategyImageSource(ref, (id: id, fileExtension: fileExtension)),
  };
  final read = <String, CopiedPicture?>{};
  var carried = 0;
  for (final MapEntry(key: id, value: source) in sources.entries) {
    Uint8List? bytes;
    try {
      bytes = switch (source) {
        LocalImageFile(:final path) => await readLocalImageFile(path)
            .fold(
                BytesBuilder(copy: false), (bytes, chunk) => bytes..add(chunk))
            .then((bytes) => bytes.takeBytes()),
        ImageBytes(:final bytes) => bytes,
        RemoteImageUrl(:final url) => await downloadCloudImageBytes(
            url,
            freshUrl: () {
              if (strategyId == null) return Future.value(null);
              final linkView = ref.read(shareLinkViewProvider);
              return ref
                  .read(convexStrategyRepositoryProvider)
                  .getImageAssetUrl(
                    strategyPublicId: strategyId,
                    assetPublicId: id,
                    shareToken: linkView?.strategyPublicId == strategyId
                        ? linkView!.token
                        : null,
                  );
            },
          ),
        ImageLoading() || ImageFailed() => null,
      };
    } catch (error) {
      AppErrorReporter.reportInfo(
        'Copied picture $id could not be read: $error',
        source: 'canvas_clipboard.copy',
      );
    }
    if (bytes != null && carried + bytes.length <= _maxCopiedPictureBytes) {
      carried += bytes.length;
      read[id] = (bytes: bytes, fileExtension: pictures[id]!);
    } else {
      read[id] = null;
    }
  }
  return read;
}
