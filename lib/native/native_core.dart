// NativeCore — dart:ffi binding to the OpenStrap Rust core (`osc_edge` glue crate:
// protocol decoder + analytics). One C entry point `osc_call(name, json) -> json`
// (+ `osc_free`). This is the LOCAL-mode compute engine; cloud mode uses the same
// Rust compiled to wasm server-side, so numbers match by construction.
//
// CONTRACT (matches the glue dispatcher):
//   • decode fns (decode_r24/decode_record/realtime_rr/frame_accel) take the RAW HEX
//     string directly (NOT JSON-wrapped).
//   • analytics fns (calc_*, time_domain_hrv, …) take a JSON object string.
//   • all return a JSON string ({"error":...} on failure).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _OscCallC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _OscCallDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _OscFreeC = Void Function(Pointer<Utf8>);
typedef _OscFreeDart = void Function(Pointer<Utf8>);

class NativeCore {
  final _OscCallDart _call;
  final _OscFreeDart _free;
  NativeCore._(this._call, this._free);

  /// Open the native lib. Resolution order:
  ///   explicit [libPath] → iOS (statically linked, DynamicLibrary.process())
  ///   → Android (libosc_edge.so) → host/macOS dylib (for `flutter test`).
  factory NativeCore.open({String? libPath}) {
    final lib = _load(libPath);
    return NativeCore._(
      lib.lookupFunction<_OscCallC, _OscCallDart>('osc_call'),
      lib.lookupFunction<_OscFreeC, _OscFreeDart>('osc_free'),
    );
  }

  static DynamicLibrary _load(String? libPath) {
    if (libPath != null) return DynamicLibrary.open(libPath);
    if (Platform.isIOS || Platform.isMacOS) {
      // iOS: symbols are linked into the app binary (staticlib). On a host test
      // pass libPath explicitly to the debug dylib instead.
      try {
        return DynamicLibrary.process();
      } catch (_) {
        return DynamicLibrary.executable();
      }
    }
    if (Platform.isAndroid) return DynamicLibrary.open('libosc_edge.so');
    // Linux/Windows host fallbacks.
    return DynamicLibrary.open(Platform.isWindows ? 'osc_edge.dll' : 'libosc_edge.so');
  }

  /// Raw call → raw JSON string out.
  String _raw(String name, String payload) {
    final np = name.toNativeUtf8();
    final pp = payload.toNativeUtf8();
    try {
      final out = _call(np, pp);
      final s = out.toDartString();
      _free(out);
      return s;
    } finally {
      malloc.free(np);
      malloc.free(pp);
    }
  }

  /// Decode a raw band frame (hex string in → decoded map out). Null on decode failure.
  Map<String, dynamic>? decode(String fn, String hex) {
    final out = jsonDecode(_raw(fn, hex));
    return out is Map<String, dynamic> ? out : null;
  }

  /// Call an analytics function with a JSON-able request → decoded result.
  dynamic analytics(String fn, Map<String, dynamic> request) {
    return jsonDecode(_raw(fn, jsonEncode(request)));
  }
}
