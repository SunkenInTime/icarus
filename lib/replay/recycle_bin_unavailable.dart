/// The file couldn't go to the Recycle Bin, so it was left where it was.
class RecycleBinUnavailable implements Exception {
  const RecycleBinUnavailable(this.path, {this.hresult});

  final String path;

  /// The shell's error, when it gave one.
  final int? hresult;

  @override
  String toString() => 'RecycleBinUnavailable($path'
      '${hresult == null ? '' : ', 0x${hresult!.toUnsigned(32).toRadixString(16)}'})';
}
