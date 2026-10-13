import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:icarus/replay/recycle_bin_unavailable.dart';
import 'package:win32/win32.dart';

/// Moves [path] to the Windows Recycle Bin, where the user can restore it.
///
/// Never deletes it outright: when Windows would delete the file
/// permanently instead (a drive with no Recycle Bin, a file too big for it,
/// a network share), this throws [RecycleBinUnavailable] and leaves the file
/// where it is.
Future<void> moveToRecycleBin(String path) {
  if (!Platform.isWindows) {
    return Future.error(RecycleBinUnavailable(path));
  }
  // Its own thread, so COM can be set up the way the shell needs it.
  return Isolate.run(() => _recycle(path));
}

const _clsidFileOperation = '{3ad05575-8857-4850-9277-11b85bdb8e09}';
const _iidFileOperation = '{947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8}';
const _iidProgressSink = '{04b0f1a7-9490-44bc-96e1-4296a31252e2}';

/// `TSF_DELETE_RECYCLE_IF_POSSIBLE`: the shell's flag on a delete that will
/// go to the Recycle Bin. A delete without it is permanent.
const _recycleIfPossible = 0x80;

const _sOk = 0;
const _eAbort = -2147467260; // E_ABORT
const _eNoInterface = -2147467262; // E_NOINTERFACE
const _eFail = -2147467259; // E_FAIL

/// What the shell told the progress sink. One recycle runs per isolate, so
/// these belong to it alone.
var _refusedPermanentDelete = false;
var _recycled = false;

void _recycle(String path) {
  try {
    _recycleOrThrow(path);
  } on WindowsException catch (error) {
    throw RecycleBinUnavailable(path, hresult: error.hr);
  }
}

void _recycleOrThrow(String path) {
  final init = CoInitializeEx(
      nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  if (FAILED(init)) throw WindowsException(init);
  final arena = Arena();
  Pointer? operation;
  Pointer? item;
  try {
    final operationOut = arena<Pointer>();
    _check(
      CoCreateInstance(
        GUIDFromString(_clsidFileOperation, allocator: arena),
        nullptr,
        CLSCTX_INPROC_SERVER,
        GUIDFromString(_iidFileOperation, allocator: arena),
        operationOut,
      ),
    );
    operation = operationOut.value;

    _check(
      _method(operation, 5) // SetOperationFlags
          .cast<NativeFunction<Int32 Function(Pointer, Uint32)>>()
          .asFunction<int Function(Pointer, int)>()(
        operation,
        FOF_SILENT |
            FOF_NOCONFIRMATION |
            FOF_NOERRORUI |
            FOF_NOCONFIRMMKDIR |
            FOF_ALLOWUNDO |
            FOFX_RECYCLEONDELETE |
            FOFX_EARLYFAILURE,
      ),
    );

    final itemOut = arena<Pointer>();
    _check(
      SHCreateItemFromParsingName(
        path.toNativeUtf16(allocator: arena),
        nullptr,
        GUIDFromString(IID_IShellItem, allocator: arena),
        itemOut,
      ),
    );
    item = itemOut.value;

    _check(
      _method(operation, 18) // DeleteItem
          .cast<NativeFunction<Int32 Function(Pointer, Pointer, Pointer)>>()
          .asFunction<int Function(Pointer, Pointer, Pointer)>()(
        operation,
        item,
        _progressSink(arena),
      ),
    );

    _refusedPermanentDelete = false;
    _recycled = false;
    final performed = _method(operation, 21) // PerformOperations
        .cast<NativeFunction<Int32 Function(Pointer)>>()
        .asFunction<int Function(Pointer)>()(operation);
    if (_refusedPermanentDelete) throw RecycleBinUnavailable(path);
    if (FAILED(performed) || !_recycled) {
      throw RecycleBinUnavailable(path, hresult: performed);
    }
  } finally {
    if (item != null) _release(item);
    if (operation != null) _release(operation);
    arena.releaseAll();
    CoUninitialize();
  }
}

void _check(int hresult) {
  if (FAILED(hresult)) throw WindowsException(hresult);
}

/// The address of method [slot] of the COM interface at [object].
Pointer _method(Pointer object, int slot) =>
    (object.cast<Pointer<Pointer>>().value + slot).value;

void _release(Pointer object) => _method(object, 2)
    .cast<NativeFunction<Uint32 Function(Pointer)>>()
    .asFunction<int Function(Pointer)>()(object);

/// An `IFileOperationProgressSink` that stops any delete the shell would do
/// permanently, and notes whether the file reached the Recycle Bin.
Pointer _progressSink(Allocator allocator) {
  final vtable = allocator<IntPtr>(19);
  final slots = <Pointer>[
    Pointer.fromFunction<
        Int32 Function(
            Pointer, Pointer<GUID>, Pointer<Pointer>)>(_queryInterface, _eFail),
    Pointer.fromFunction<Uint32 Function(Pointer)>(_addRefOrRelease, 0),
    Pointer.fromFunction<Uint32 Function(Pointer)>(_addRefOrRelease, 0),
    Pointer.fromFunction<Int32 Function(Pointer)>(_ok0, _eFail), // Start
    Pointer.fromFunction<Int32 Function(Pointer, Int32)>(
        _ok1, _eFail), // Finish
    Pointer.fromFunction<Int32 Function(Pointer, Uint32, Pointer, Pointer)>(
        _ok3, _eFail),
    Pointer.fromFunction<
            Int32 Function(Pointer, Uint32, Pointer, Pointer, Int32, Pointer)>(
        _ok5, _eFail), // PostRenameItem
    Pointer.fromFunction<
            Int32 Function(Pointer, Uint32, Pointer, Pointer, Pointer)>(
        _ok4, _eFail), // PreMoveItem
    Pointer.fromFunction<
        Int32 Function(Pointer, Uint32, Pointer, Pointer, Pointer, Int32,
            Pointer)>(_ok6, _eFail), // PostMoveItem
    Pointer.fromFunction<
            Int32 Function(Pointer, Uint32, Pointer, Pointer, Pointer)>(
        _ok4, _eFail), // PreCopyItem
    Pointer.fromFunction<
        Int32 Function(Pointer, Uint32, Pointer, Pointer, Pointer, Int32,
            Pointer)>(_ok6, _eFail), // PostCopyItem
    Pointer.fromFunction<Int32 Function(Pointer, Uint32, Pointer)>(
        _preDeleteItem, _eAbort),
    Pointer.fromFunction<
        Int32 Function(
            Pointer, Uint32, Pointer, Int32, Pointer)>(_postDeleteItem, _eFail),
    Pointer.fromFunction<Int32 Function(Pointer, Uint32, Pointer, Pointer)>(
        _ok3, _eFail),
    Pointer.fromFunction<
        Int32 Function(Pointer, Uint32, Pointer, Pointer, Pointer, Uint32,
            Int32, Pointer)>(_ok7, _eFail), // PostNewItem
    Pointer.fromFunction<Int32 Function(Pointer, Uint32, Uint32)>(
        _ok2, _eFail), // UpdateProgress
    Pointer.fromFunction<Int32 Function(Pointer)>(_ok0, _eFail), // ResetTimer
    Pointer.fromFunction<Int32 Function(Pointer)>(_ok0, _eFail), // PauseTimer
    Pointer.fromFunction<Int32 Function(Pointer)>(_ok0, _eFail), // ResumeTimer
  ];
  for (var i = 0; i < slots.length; i++) {
    vtable[i] = slots[i].address;
  }
  final object = allocator<IntPtr>();
  object.value = vtable.address;
  return object;
}

int _queryInterface(Pointer self, Pointer<GUID> iid, Pointer<Pointer> out) {
  final asked = iid.ref.toString().toLowerCase();
  if (asked == IID_IUnknown || asked == _iidProgressSink) {
    out.value = self;
    return _sOk;
  }
  out.value = nullptr;
  return _eNoInterface;
}

/// The sink lives in the recycle's arena, which outlasts the operation.
int _addRefOrRelease(Pointer self) => 1;

int _preDeleteItem(Pointer self, int flags, Pointer item) {
  if (flags & _recycleIfPossible != 0) return _sOk;
  _refusedPermanentDelete = true;
  return _eAbort;
}

int _postDeleteItem(
  Pointer self,
  int flags,
  Pointer item,
  int result,
  Pointer recycledItem,
) {
  _recycled = SUCCEEDED(result) && recycledItem.address != 0;
  return _sOk;
}

int _ok0(Pointer self) => _sOk;
int _ok1(Pointer self, int a) => _sOk;
int _ok2(Pointer self, int a, int b) => _sOk;
int _ok3(Pointer self, int a, Pointer b, Pointer c) => _sOk;
int _ok4(Pointer self, int a, Pointer b, Pointer c, Pointer d) => _sOk;
int _ok5(Pointer self, int a, Pointer b, Pointer c, int d, Pointer e) => _sOk;
int _ok6(
  Pointer self,
  int a,
  Pointer b,
  Pointer c,
  Pointer d,
  int e,
  Pointer f,
) =>
    _sOk;
int _ok7(
  Pointer self,
  int a,
  Pointer b,
  Pointer c,
  Pointer d,
  int e,
  int f,
  Pointer g,
) =>
    _sOk;
