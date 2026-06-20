/// Cumulative decompressed-output limit shared by the streaming decoders.
///
/// Streaming codecs decode a sequence of members/frames, each into its own
/// [WindowBuffer]. To enforce the public contract — *cumulative* output is
/// capped at [maxSize] — each member/frame's buffer is created with
/// `maxSize: limit.remaining` (the budget left after prior members), and the
/// bytes it emits are recorded via [record]. This mirrors the block path's
/// `remaining = maxSize - total` accounting so the two cannot diverge.
class OutputLimit {
  OutputLimit(this.maxSize);

  /// Cumulative cap across all members/frames, or null for unlimited.
  final int? maxSize;

  int _produced = 0;

  /// Total bytes emitted so far across all members/frames.
  int get produced => _produced;

  /// Budget remaining for the next member/frame's buffer, or null if
  /// unlimited. Never negative.
  int? get remaining {
    final max = maxSize;
    if (max == null) return null;
    final left = max - _produced;
    return left < 0 ? 0 : left;
  }

  /// Records [count] emitted bytes against the cumulative total.
  void record(final int count) => _produced += count;
}
