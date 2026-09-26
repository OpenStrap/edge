// A bounded ring of the most recent live samples for the capture screen's
// "Live signal preview". RAM only, fixed size, no per-push allocation and
// no whole-buffer copies: the painter reads the ring through [operator []]
// in oldest-first order. Repaints are scheduled by [EcgPreviewScheduler],
// not by pushes — a burst of packets inside one tick is one repaint.
//
// Pure Dart (a ChangeNotifier-free Listenable would drag Flutter in; the
// scheduler is a tiny listener set instead).

import 'dart:typed_data';

class EcgWaveformBuffer {
  /// 8 s at 100 Hz.
  static const int defaultCapacity = 800;

  final Int16List _ring;
  int _write = 0;
  int _length = 0;
  int _version = 0;

  EcgWaveformBuffer({int capacity = defaultCapacity})
    : _ring = Int16List(capacity);

  int get capacity => _ring.length;

  /// Samples currently held (≤ capacity).
  int get length => _length;

  /// Bumps on every push; a painter can skip a repaint when unchanged.
  int get version => _version;

  bool get isEmpty => _length == 0;

  /// The i-th oldest sample of the visible window.
  int operator [](int i) {
    if (i < 0 || i >= _length) throw RangeError.index(i, this);
    final start = (_write - _length + _ring.length) % _ring.length;
    return _ring[(start + i) % _ring.length];
  }

  /// Append [samples] (oldest first), dropping the oldest held samples when
  /// the ring is full.
  void push(Int16List samples) {
    if (samples.isEmpty) return;
    for (final s in samples) {
      _ring[_write] = s;
      _write = (_write + 1) % _ring.length;
      if (_length < _ring.length) _length++;
    }
    _version++;
  }

  void clear() {
    _write = 0;
    _length = 0;
    _version++;
  }

  /// Largest |sample| in the window, or 0 when empty.
  int maxAbs() {
    var m = 0;
    for (var i = 0; i < _length; i++) {
      final v = this[i].abs();
      if (v > m) m = v;
    }
    return m;
  }
}

/// Coalesces "the buffer changed" into at most one notification per tick.
/// The SCREEN drives [tick] from its clock (a Ticker when motion is on, a
/// 1 Hz timer otherwise); frames only [markDirty].
class EcgPreviewScheduler {
  final List<void Function()> _listeners = [];
  bool _dirty = false;

  bool get isDirty => _dirty;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void markDirty() => _dirty = true;

  /// Notify once if anything changed since the last tick. Returns whether a
  /// notification went out.
  bool tick() {
    if (!_dirty) return false;
    _dirty = false;
    for (final l in List.of(_listeners)) {
      l();
    }
    return true;
  }
}
