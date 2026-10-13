/// The file didn't make it into the Recycle Bin.
class RecycleBinUnavailable implements Exception {
  const RecycleBinUnavailable(this.path, {this.hresult, this.deleted = false});

  final String path;

  /// The file is gone anyway: Windows deleted it instead of recycling it.
  /// Otherwise it is still where it was.
  final bool deleted;

  /// The shell's error, when it gave one.
  final int? hresult;

  @override
  String toString() => 'RecycleBinUnavailable($path'
      '${hresult == null ? '' : ', 0x${hresult!.toUnsigned(32).toRadixString(16)}'})';
}
