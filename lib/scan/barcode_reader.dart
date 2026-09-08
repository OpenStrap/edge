// barcode_reader.dart — the ONLY file that imports mobile_scanner.
//
// Same pattern as lib/telemetry/firebase_bridge.dart: mobile_scanner bundles
// Google ML Kit on Android (checked its build.gradle directly — both the
// bundled and "unbundled" modes pull play-services-basement/base/tasks), so
// F-Droid's build recipe swaps this ONE file for
// docs/fdroid/barcode_reader.floss.dart (a flutter_zxing-backed stand-in
// with the identical API, zero Google deps) instead of touching the caller.
// iOS and the Play Store / GitHub-release Android build keep mobile_scanner
// unchanged — this only matters for the F-Droid recipe.
//
// Keep every mobile_scanner import confined to this file.

import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart' as ms;

/// Product-barcode formats this app ever scans. A QR code is not a food, so
/// it is deliberately not in this list — see scan_barcode.dart.
enum BarcodeFormat { ean13, ean8, upcA, upcE, dataBar, dataBarExpanded }

/// Why the reader can't show a preview — permission refused, or the device
/// simply has no usable camera.
class BarcodeReaderError {
  const BarcodeReaderError({required this.permissionDenied});
  final bool permissionDenied;
}

typedef BarcodeReaderErrorBuilder = Widget Function(BuildContext, BarcodeReaderError);

/// Camera preview that reports the first detected code and stops. Callers
/// own the sheet chrome; this widget only owns the camera.
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
  late final ms.MobileScannerController _controller =
      ms.MobileScannerController(formats: widget.formats.map(_map).toList());
  bool _done = false;

  static ms.BarcodeFormat _map(BarcodeFormat f) => switch (f) {
        BarcodeFormat.ean13 => ms.BarcodeFormat.ean13,
        BarcodeFormat.ean8 => ms.BarcodeFormat.ean8,
        BarcodeFormat.upcA => ms.BarcodeFormat.upcA,
        BarcodeFormat.upcE => ms.BarcodeFormat.upcE,
        BarcodeFormat.dataBar => ms.BarcodeFormat.dataBar,
        BarcodeFormat.dataBarExpanded => ms.BarcodeFormat.dataBarExpanded,
      };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(ms.BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.trim().isNotEmpty, orElse: () => null);
    if (code == null) return;
    _done = true;
    widget.onDetect(code.trim());
  }

  @override
  Widget build(BuildContext context) => ms.MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: (_, e) => widget.errorBuilder(
          context,
          BarcodeReaderError(
            permissionDenied: e.errorCode == ms.MobileScannerErrorCode.permissionDenied,
          ),
        ),
      );
}
