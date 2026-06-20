/// Append-with-back-reference output target shared by [GrowableBuffer]
/// (whole-output) and [WindowBuffer] (sliding-window) so decoders can write to
/// either without caring whether the full output is retained.
abstract interface class ByteSink {
  /// Total bytes produced so far (including any already discarded by a window).
  int get length;

  /// Appends a single byte.
  void addByte(int byte);

  /// Appends [count] bytes of [bytes] starting at [offset].
  void addBytes(List<int> bytes, [int offset, int? count]);

  /// Copies [length] bytes from [distance] bytes back (handles overlap).
  void copyFromHistory(int distance, int length);
}
