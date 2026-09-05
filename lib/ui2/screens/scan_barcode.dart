// The camera, for exactly as long as it takes to read one barcode.
//
// It opens on a tap, it closes on the first code, and it has no other job.
// Nothing is recorded, nothing is written, and the picture never leaves the
// widget — [BarcodeCapture.image] is not requested, so there is no frame to
// leak in the first place.
//
// Product formats only. A QR code is not a food, and reading one here would
// send whatever a stranger's sticker says to openfoodfacts.org.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../scan/barcode_reader.dart';
import '../ui2.dart';

/// Read one barcode. Resolves the digits, or null if the sheet was closed,
/// the camera was refused, or there is no camera at all.
Future<String?> scanBarcode(BuildContext c) => showModalBottomSheet<String>(
      context: c,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(c),
      backgroundColor: P.of(c).card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
      ),
      builder: (_) => const _ScanSheet(),
    );

class _ScanSheet extends StatefulWidget {
  const _ScanSheet();

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  /// The formats printed on packaged food. `all` would also read QR codes,
  /// which are not products.
  static const _formats = [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
    BarcodeFormat.dataBar,
    BarcodeFormat.dataBarExpanded,
  ];

  /// One code per sheet. The detector fires repeatedly on the same packet, and
  /// without this each repeat would be another pop and another lookup.
  bool _done = false;

  void _onDetect(String code) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(S.x5, S.x4, S.x5, S.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(l?.scanBarcodeTitle ?? 'Scan the barcode',
                      style: F.t2.copyWith(color: p.ink)),
                ),
                Pressable(
                  semanticLabel: l?.scanBarcodeClose ?? 'Close',
                  onTap: () => Navigator.of(c).pop(),
                  child: Icon(LucideIcons.x, size: 20, color: p.ink3),
                ),
              ],
            ),
            const SizedBox(height: S.x4),
            ClipRRect(
              borderRadius: R.rLg,
              child: AspectRatio(
                aspectRatio: 1,
                child: BarcodeReaderWidget(
                  formats: _formats,
                  onDetect: _onDetect,
                  errorBuilder: (_, e) => _CameraProblem(e),
                ),
              ),
            ),
            const SizedBox(height: S.x4),
            Text(
              l?.scanBarcodeInstructions ??
                  'Hold the barcode inside the frame. Nothing is recorded — '
                      'the digits are all this reads.',
              style: F.cap.copyWith(color: p.ink3, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

/// No camera, or no permission. Both end the same way — type the numbers —
/// so the card says which one happened and stops there.
class _CameraProblem extends StatelessWidget {
  const _CameraProblem(this.error);
  final BarcodeReaderError error;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final denied = error.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(S.x4),
        child: StatusCard(
          denied
              ? (l?.scanBarcodeNoAccessTitle ?? 'No camera access')
              : (l?.scanBarcodeCameraFailedTitle ?? 'The camera did not start'),
          denied
              ? (l?.scanBarcodeNoAccessBody ??
                  'Scanning needs the camera, and this app has not been '
                      'given it.')
              : (l?.scanBarcodeCameraFailedBody ??
                  'This device would not open its camera for the scanner.'),
          fix: l?.scanBarcodeTypeInstead ?? 'Type the numbers instead',
          icon: LucideIcons.cameraOff,
          onFix: () => Navigator.of(c).pop(),
        ),
      ),
    );
  }
}
