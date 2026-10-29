import 'dart:typed_data';

/// Base class for compression codecs
///
/// Compresses and decompresses whole byte arrays synchronously. For large
/// or untrusted input, see [CompressionStreamCodec].
///
/// ## Thread Safety
///
/// Codec instances are generally **not** thread-safe for concurrent use.
/// Each codec maintains internal state (buffers, hash tables) that could
/// be corrupted by concurrent access. For parallel processing:
/// - Create a separate codec instance per isolate
/// - Use `Isolate.run()` with a fresh codec for background work
///
/// ## Exception Behavior
///
/// Malformed input raises a codec-specific exception:
/// - **[Lz4FormatException]**: Invalid LZ4 frame/block structure
/// - **[GzipFormatException]**: Invalid GZIP header/trailer or CRC mismatch
/// - **[DeflateFormatException]**: Invalid DEFLATE block structure (a
///   [GzipFormatException])
/// - **[ZstdFormatException]**: Invalid Zstandard frame/block structure
/// - **[SnappyFormatException]**: Invalid Snappy block or framing format
///
/// Exceeding a limit (`maxSize`, an expected `size`, or a stream's
/// `maxBufferSize`) raises [LimitException], naming the limit.
///
/// All of these extend [CompressionFormatException] which extends
/// [FormatException], allowing catch-all error handling:
/// ```dart
/// try {
///   final data = codec.decompress(compressed);
/// } on CompressionFormatException catch (e) {
///   print('Invalid compressed data: $e');
/// }
/// ```
///
/// ## Memory Limits
///
/// Each codec supports a maximum decompressed size limit to prevent
/// decompression bomb attacks. Configure via codec-specific constructors
/// (e.g., `Lz4Codec(maxSize: 10 * 1024 * 1024)`).
///
/// The constructors default to a sane cap. Passing `null` (or
/// `maxSize: null`) means **unlimited output** and removes that protection —
/// use it only with **trusted input**. For untrusted/attacker-controlled data,
/// always keep a finite limit.
///
/// ## Offloading large jobs
///
/// [compress]/[decompress] are synchronous and run on the calling isolate. For
/// truly non-blocking processing of large inputs, either run the call on a
/// separate isolate (`Isolate.run(() => codec.compress(data))`, VM only) or use
/// the chunked streaming APIs ([CompressionStreamCodec]). (There are no
/// `*Async` convenience methods — a microtask wrapper would not actually offload
/// the work.)
abstract base class CompressionCodec {
  /// Compress data synchronously
  ///
  /// Takes a byte array and returns compressed data. The entire input
  /// must fit in memory. For large data, consider using streaming APIs.
  Uint8List compress(final Uint8List data);

  /// Decompress data synchronously
  ///
  /// Takes compressed data and returns the original uncompressed bytes.
  /// Throws a [CompressionFormatException] if the data is corrupted or in an
  /// invalid format.
  ///
  /// This materializes the entire output (up to the codec's
  /// `maxSize`) before validating the trailer/checksum, so for
  /// untrusted or large input prefer the streaming codec, which is incremental
  /// and bounded (`CompressionStreamCodec`, e.g. via `CodecFactory.streaming`).
  ///
  /// When the uncompressed length is known, as for a Parquet page, pass it as
  /// [size]: decoding stops once output would exceed it, and output of any
  /// other length is rejected as a [CompressionFormatException]. A negative
  /// [size] is an [ArgumentError].
  Uint8List decompress(final Uint8List data, {final int? size});

  /// The codec's name in upper case: 'NOOP', 'SNAPPY', 'GZIP', 'LZ4' or 'ZSTD'.
  String get name;
}
