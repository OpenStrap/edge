// F-Droid stand-in for lib/scan/barcode_reader.dart: same API, flutter_zxing
// instead of mobile_scanner. Copied over the real one by wtf.openstrap.openstrap_edge.yml.

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

  @override
  void initState() {
    super.initState();
    // ReaderWidget stays on its loading state forever with zero cameras.
    availableCameras().then((cams) {
      if (cams.isEmpty && mounted) {
        setState(() => _error = const BarcodeReaderError(permissionDenied: false));
      }
    }, onError: (_) {});
  }

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
