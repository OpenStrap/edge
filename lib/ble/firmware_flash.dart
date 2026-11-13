// User-supplied image update (WHOOP 5 only).
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

enum FlashPhase {
  idle,
  staging,
  verified,
  committing,
  committed,

  /// The commit was sent and nothing came back. The strap may or may not have
  /// taken it, so nothing here offers a retry.
  commitUnknown,
  failed,
}

/// Why staging cannot start yet.
enum FlashBlock { noImage, tooLarge, noLink, batteryUnknown, batteryLow }

/// Why a run ended without a committed image.
enum FlashFailure {
  takeover,
  start,
  data,
  verify,
  cancelled,
  commitRejected,
  commitUnknown,
}

/// The slice of the engine the flow needs (a seam so the flow is testable).
abstract class FlashLink {
  bool get canFlash;
  double? get batteryPct;

  /// A commit was sent earlier and never answered (kept beyond this screen).
  bool get commitUnresolved;
  void markCommitUnresolved();
  void acknowledgeCommit();
  bool begin();
  void end();
  Future<CorrelatedResponse?> command(int opcode, List<int> payload,
      {Duration timeout});
}

/// Holds the engine's ownership token for ONE claim. Only this instance's own
/// claim is ever released or used to send, so a controller that outlives its
/// screen cannot touch a newer screen's claim.
class EngineFlashLink implements FlashLink {
  EngineFlashLink(this._e);
  final BleEngine _e;
  Object? _token;
  @override
  bool get canFlash => _e.canFlashFirmware;
  @override
  double? get batteryPct => _e.flashBatteryPct;
  @override
  bool get commitUnresolved => _e.flashCommitUnresolved;
  @override
  void markCommitUnresolved() => _e.markFlashCommitUnresolved();
  @override
  void acknowledgeCommit() => _e.acknowledgeFlashCommit();
  @override
  bool begin() {
    final t = _e.beginFirmwareFlash();
    if (t == null) return false;
    _token = t;
    return true;
  }

  @override
  void end() {
    final t = _token;
    if (t == null) return;
    _token = null;
    _e.endFirmwareFlash(t);
  }

  @override
  Future<CorrelatedResponse?> command(int opcode, List<int> payload,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final t = _token;
    if (t == null) return null;
    return _e.firmwareCommand(t, opcode, payload, timeout: timeout);
  }
}

enum _Reply { ok, rejected, none }

class FirmwareFlashController extends ChangeNotifier {
  FirmwareFlashController(this._link) {
    if (_link.commitUnresolved) {
      phase = FlashPhase.commitUnknown;
      failure = FlashFailure.commitUnknown;
    }
  }

  /// Upper bound on a staged file, so a wrong pick can't fill memory.
  static const int maxImageBytes = 4 * 1024 * 1024;
  final FlashLink _link;

  /// Below this the flash is refused: a strap that dies mid-write is the one
  /// failure the user cannot recover from.
  static const double minBatteryPct = 50;

  FlashPhase phase = FlashPhase.idle;
  FlashFailure? failure;

  /// The byte offset the strap rejected, for [FlashFailure.data].
  int failureOffset = 0;
  Uint8List? _image;
  String? fileName;
  String? sha;
  int chunksDone = 0;
  int chunksTotal = 0;
  bool _cancel = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _claimed = false;

  int get imageBytes => _image?.length ?? 0;
  double get progress => chunksTotal == 0 ? 0 : chunksDone / chunksTotal;
  bool get busy =>
      phase == FlashPhase.staging || phase == FlashPhase.committing;

  /// A finished commit, or one whose outcome is unknown, ends the flow: no new
  /// image can be picked or staged from here.
  bool get settled =>
      phase == FlashPhase.committed ||
      phase == FlashPhase.commitUnknown ||
      _link.commitUnresolved;

  /// Current battery on this link, for the blocker's wording.
  double? get batteryNow => _link.batteryPct;

  void load(String name, Uint8List bytes) {
    if (busy || settled || _disposed) return;
    // A new pick after verify drops the claim the old image held.
    if (phase == FlashPhase.verified) _release();
    _image = bytes;
    fileName = name;
    sha = sha256.convert(bytes).toString();
    phase = FlashPhase.idle;
    failure = null;
    chunksDone = 0;
    chunksTotal = bytes.isEmpty ? 0 : FwUpdate.chunkCount(bytes.length);
    _notify();
  }

  /// Reason staging cannot start, or null when it can.
  FlashBlock? get blocker {
    final image = _image;
    if (image == null || image.isEmpty) return FlashBlock.noImage;
    if (image.length > maxImageBytes) return FlashBlock.tooLarge;
    if (!_link.canFlash) return FlashBlock.noLink;
    final b = _link.batteryPct;
    if (b == null) return FlashBlock.batteryUnknown;
    if (b < minBatteryPct) return FlashBlock.batteryLow;
    return null;
  }

  void cancel() => _cancel = true;

  /// Start load, stage every chunk, verify. Ends at [FlashPhase.verified].
  Future<void> stage() async {
    if (busy || settled || _disposed || blocker != null) return;
    if (!_link.begin()) return _fail(FlashFailure.takeover);
    _claimed = true;
    _cancel = false;
    phase = FlashPhase.staging;
    failure = null;
    chunksDone = 0;
    _notify();
    final image = _image!;
    final start = await _cmd(FwUpdate.startLoad, FwUpdate.rev1);
    if (_disposed) return _release();
    if (start != _Reply.ok) return _fail(FlashFailure.start);
    for (var off = 0; off < image.length; off += FwUpdate.chunk) {
      if (_cancel) return _fail(FlashFailure.cancelled);
      final end = off + FwUpdate.chunk > image.length
          ? image.length
          : off + FwUpdate.chunk;
      final r = await _cmd(FwUpdate.loadData,
          FwUpdate.loadDataPayload(off, image.sublist(off, end)));
      if (_disposed) return _release();
      if (r != _Reply.ok) {
        failureOffset = off;
        return _fail(FlashFailure.data);
      }
      chunksDone++;
      _notify();
    }
    // Stop pressed while the last chunk was in flight.
    if (_cancel) return _fail(FlashFailure.cancelled);
    final v = await _cmd(FwUpdate.verifyImage, FwUpdate.rev1);
    if (_disposed) return _release();
    if (v != _Reply.ok) return _fail(FlashFailure.verify);
    if (_cancel) return _fail(FlashFailure.cancelled);
    // The link stays claimed through the user's decision so no heartbeat or
    // ACK lands between verify and commit. Released by commit, abandon,
    // failure or dispose.
    phase = FlashPhase.verified;
    _notify();
  }

  /// Send the commit. Call only after the user confirmed.
  Future<void> commit() async {
    if (phase != FlashPhase.verified || _disposed) return;
    phase = FlashPhase.committing;
    _notify();
    final r = await _cmd(FwUpdate.processImage, FwUpdate.rev1);
    _release();
    if (_disposed) return;
    switch (r) {
      case _Reply.ok:
        phase = FlashPhase.committed;
        _notify();
      case _Reply.rejected:
        _fail(FlashFailure.commitRejected);
      case _Reply.none:
        // Sent, and no answer: not a rejection. Never offer a retry.
        _link.markCommitUnresolved();
        failure = FlashFailure.commitUnknown;
        phase = FlashPhase.commitUnknown;
        _notify();
    }
  }

  /// The user checked the firmware version after an unanswered commit and
  /// accepts a new install. The only way out of [FlashPhase.commitUnknown].
  void acknowledgeUnresolved() {
    if (phase != FlashPhase.commitUnknown && !_link.commitUnresolved) return;
    _link.acknowledgeCommit();
    phase = FlashPhase.idle;
    failure = null;
    _notify();
  }

  /// The user backed out after verify. Nothing is committed.
  void abandon() {
    if (phase != FlashPhase.verified) return;
    _release();
    phase = FlashPhase.idle;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel = true;
    // A command still in flight keeps the claim until it returns; the staging
    // loop releases it then. Freeing it now would let ordinary writes
    // interleave with a half-sent transfer.
    if (!_inFlight) _release();
    super.dispose();
  }

  Future<_Reply> _cmd(int op, List<int> payload) async {
    _inFlight = true;
    try {
      final r = await _link.command(op, payload);
      if (r == null) return _Reply.none;
      return r.status == CommandAwaiter.statusSuccess
          ? _Reply.ok
          : _Reply.rejected;
    } finally {
      _inFlight = false;
    }
  }

  void _release() {
    if (!_claimed) return;
    _claimed = false;
    _link.end();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _fail(FlashFailure why) {
    _release();
    failure = why;
    phase = FlashPhase.failed;
    _notify();
  }
}
