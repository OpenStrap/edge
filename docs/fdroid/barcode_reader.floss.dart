// barcode_reader.dart (F-Droid / FLOSS variant) — flutter_zxing-backed
// stand-in with the exact API of lib/scan/barcode_reader.dart, zero Google
// dependencies (mobile_scanner's ML Kit pulls play-services-basement/base/
// tasks on Android either way — checked its build.gradle directly).
//
// Not compiled by default. The F-Droid build recipe (see
// docs/fdroid/wtf.openstrap.openstrap_edge.yml) copies this over
// lib/scan/barcode_reader.dart and adds flutter_zxing + camera to
// pubspec.yaml before building. scan_barcode.dart (the only caller) is
// unaffected — it only ever sees this API.
//
// flutter_zxing (pub.dev, 2.3.0, Apache-2.0, pure Dart FFI over the ZXing
// C++ library via the `camera` plugin — no Google Play Services / ML Kit)
// verified to cover every format this app scans: Format.ean13/ean8/upca/
// upce/dataBar/dataBarExpanded all exist (lib/src/models/format.dart).
// ReaderWidget's error surface is onControllerCreated(controller, error) —
// a non-null error there is how the underlying `camera` plugin reports
// camera failures, including permission denial via a CameraException whose
// `code` is 'CameraAccessDenied' (or 'CameraAccessDeniedWithoutPrompt' on
// iOS, kept here for API parity though this file only ever ships on
// Android).

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_zxing/flutter_zxing.dart' as zx;

enum BarcodeFormat { ean13, ean8, upcA, upcE, dataBar, dataBarExpanded }

class BarcodeReaderError {
  const BarcodeReaderError({required this.permissionDenied});
  final bool permissionDenied;
}

typedef BarcodeReaderErrorBuilder = Widget Function(BuildContext, BarcodeReaderError);

class BarcodeReaderWidget extends StatefulWidget {
  const BarcodeReaderWidget({
    super.key,
    required this.formats,
    required this.onDetect,
    required this.errorBuilder,
  });

  final List<BarcodeFormat> formats;
  final ValueChanged<String> onDetect;
  final BarcodeReaderErrorBuilder errorBuilder;

  @override
  State<BarcodeReaderWidget> createState() => _BarcodeReaderWidgetState();
}

class _BarcodeReaderWidgetState extends State<BarcodeReaderWidget> {
  bool _done = false;
  BarcodeReaderError? _error;

  static const Map<BarcodeFormat, int> _formatBits = {
    BarcodeFormat.ean13: zx.Format.ean13,
    BarcodeFormat.ean8: zx.Format.ean8,
    BarcodeFormat.upcA: zx.Format.upca,
    BarcodeFormat.upcE: zx.Format.upce,
    BarcodeFormat.dataBar: zx.Format.dataBar,
    BarcodeFormat.dataBarExpanded: zx.Format.dataBarExpanded,
  };

  int get _codeFormat =>
      widget.formats.fold(0, (acc, f) => acc | (_formatBits[f] ?? 0));

  void _onScan(zx.Code code) {
    if (_done || !code.isValid) return;
    final text = code.text;
    if (text == null || text.trim().isEmpty) return;
    _done = true;
    widget.onDetect(text.trim());
  }

  void _onControllerCreated(CameraController? controller, Exception? error) {
    if (error == null) return;
    final denied = error is CameraException &&
        (error.code == 'CameraAccessDenied' ||
            error.code == 'CameraAccessDeniedWithoutPrompt');
    if (mounted) setState(() => _error = BarcodeReaderError(permissionDenied: denied));
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    if (err != null) return widget.errorBuilder(context, err);
    return zx.ReaderWidget(
      codeFormat: _codeFormat,
      onScan: _onScan,
      onControllerCreated: _onControllerCreated,
      showFlashlight: false,
      showToggleCamera: false,
      showGallery: false,
      allowPinchZoom: false,
    );
  }
}
