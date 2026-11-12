// User-supplied image update (WHOOP 5 only, opt-in builds only).
//
// Stage the whole file, verify it, then stop and wait. The commit (0x90) is
// sent only by an explicit [commit] call after the user confirms. Nothing here
// retries a command: a repeated commit is not safe, and a dropped link means
// start over from the top.
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ble_engine.dart';
import 'ble_state.dart';

enum FlashPhase { idle, staging, verified, committing, committed, failed }

/// The slice of the engine the flow needs (a seam so the flow is testable).
abstract class FlashLink {
  bool get canFlash;
  double? get batteryPct;
  bool begin();
  void end();
  Future<CorrelatedResponse?> command(int opcode, List<int> payload,
      {Duration timeout});
}

class EngineFlashLink implements FlashLink {
  EngineFlashLink(this._e);
  final BleEngine _e;
  @override
  bool get canFlash => _e.canFlashFirmware;
  @override
  double? get batteryPct => _e.state.batteryPct;
  @override
  bool begin() => _e.beginFirmwareFlash();
  @override
  void end() => _e.endFirmwareFlash();
  @override
  Future<CorrelatedResponse?> command(int opcode, List<int> payload,
          {Duration timeout = const Duration(seconds: 5)}) =>
      _e.firmwareCommand(opcode, payload, timeout: timeout);
}

class FirmwareFlashController extends ChangeNotifier {
  FirmwareFlashController(this._link);
  final FlashLink _link;

  /// Below this the flash is refused: a strap that dies mid-write is the one
  /// failure the user cannot recover from.
  static const double minBatteryPct = 50;

  FlashPhase phase = FlashPhase.idle;
  String? error;
  Uint8List? _image;
  String? fileName;
  String? sha;
  int chunksDone = 0;
  int chunksTotal = 0;
  bool _cancel = false;

  int get imageBytes => _image?.length ?? 0;
  double get progress => chunksTotal == 0 ? 0 : chunksDone / chunksTotal;
  bool get busy =>
      phase == FlashPhase.staging || phase == FlashPhase.committing;

  void load(String name, Uint8List bytes) {
    if (busy) return;
    _image = bytes;
    fileName = name;
    sha = sha256.convert(bytes).toString();
    phase = FlashPhase.idle;
    error = null;
    chunksDone = 0;
    chunksTotal = FwUpdate.chunkCount(bytes.length);
    notifyListeners();
  }

  /// Reason staging cannot start, or null when it can.
  String? get blocker {
    if (_image == null || _image!.isEmpty) return 'Choose an image file first.';
    if (!_link.canFlash) {
      return 'Connect a WHOOP 5 and wait for any sync to finish.';
    }
    final b = _link.batteryPct;
    if (b == null) return 'Battery level unknown. Wait for it to be read.';
    if (b < minBatteryPct) {
      return 'Battery is ${b.round()}%. Charge to at least '
          '${minBatteryPct.round()}% first.';
    }
    return null;
  }

  void cancel() => _cancel = true;

  /// Start load, stage every chunk, verify. Ends at [FlashPhase.verified].
  Future<void> stage() async {
    if (busy || blocker != null) return;
    if (!_link.begin()) return _fail('Could not take over the connection.');
    _cancel = false;
    phase = FlashPhase.staging;
    error = null;
    chunksDone = 0;
    notifyListeners();
    final image = _image!;
    if (!await _ok(FwUpdate.startLoad, FwUpdate.rev1)) {
      return _fail('The strap did not accept the start of the update.');
    }
    for (var off = 0; off < image.length; off += FwUpdate.chunk) {
      if (_cancel) return _fail('Cancelled. Nothing was committed.');
      final end = off + FwUpdate.chunk > image.length
          ? image.length
          : off + FwUpdate.chunk;
      if (!await _ok(FwUpdate.loadData,
          FwUpdate.loadDataPayload(off, image.sublist(off, end)))) {
        return _fail('The strap rejected data at byte $off. '
            'Nothing was committed.');
      }
      chunksDone++;
      notifyListeners();
    }
    if (!await _ok(FwUpdate.verifyImage, FwUpdate.rev1)) {
      return _fail('The strap did not verify the image. '
          'Nothing was committed.');
    }
    // The link stays claimed through the user's decision so no heartbeat or
    // ACK lands between verify and commit. Released by commit, abandon,
    // failure or dispose.
    phase = FlashPhase.verified;
    notifyListeners();
  }

  /// Send the commit. Call only after the user confirmed.
  Future<void> commit() async {
    if (phase != FlashPhase.verified) return;
    phase = FlashPhase.committing;
    notifyListeners();
    final ok = await _ok(FwUpdate.processImage, FwUpdate.rev1);
    _link.end();
    if (!ok) return _fail('The strap did not accept the commit.');
    phase = FlashPhase.committed;
    notifyListeners();
  }

  /// The user backed out after verify. Nothing is committed.
  void abandon() {
    if (phase != FlashPhase.verified) return;
    _link.end();
    phase = FlashPhase.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancel = true;
    _link.end();
    super.dispose();
  }

  Future<bool> _ok(int op, List<int> payload) async {
    final r = await _link.command(op, payload);
    return r != null && r.status == CommandAwaiter.statusSuccess;
  }

  void _fail(String why) {
    _link.end();
    error = why;
    phase = FlashPhase.failed;
    notifyListeners();
  }
}
