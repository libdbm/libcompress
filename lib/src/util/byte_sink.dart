import 'dart:typed_data';

/// Append-with-back-reference output target shared by [GrowableBuffer]
/// (whole-output) and [WindowBuffer] (sliding-window) so decoders can write to
/// either without caring whether the full output is retained.
abstract interface class ByteSink {
  /// Total bytes produced so far (including any already discarded by a window).
  int get length;

  /// Appends a single byte.
  void addByte(final int byte);

  /// Appends [count] bytes of [bytes] starting at [offset].
  void addBytes(final List<int> bytes, [final int offset, final int? count]);

  /// Copies [length] bytes from [distance] bytes back (handles overlap).
  void copyFromHistory(final int distance, final int length);
}

/// A [ByteSink] whose array a decoder's fast loop may write directly: bytes go
/// at [position] in [bytes], up to [room], after which [reserve] must be
/// called.
abstract interface class DirectSink implements ByteSink {
  /// The array holding the output; replaced by [reserve].
  Uint8List get bytes;

  /// Index in [bytes] of the next byte to write; set it after writing.
  int get position;
  set position(final int value);

  /// Index in [bytes] of the oldest byte a back-reference may read.
  int get floor;

  /// Index in [bytes] up to which bytes may be written without [reserve].
  int get room;

  /// Makes room for [count] more bytes at [position], or throws once that
  /// would exceed the output limit. May move the bytes in [bytes], and
  /// [position] and [floor] with them.
  void reserve(final int count);
}
