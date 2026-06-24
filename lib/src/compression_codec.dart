import 'dart:typed_data';

/// Codec capability modes
///
/// Used to query what features a codec supports via [CompressionCodec.supports].
enum CodecMode {
  /// Block-based (synchronous) compression/decompression
  ///
  /// All codecs support this mode - compress/decompress operate on
  /// complete byte arrays in memory.
  block,

  /// Stream-based compression/decompression
  ///
  /// Codec has a corresponding [CompressionStreamCodec] implementation
  /// that can process data incrementally via Dart streams.
  stream,
}

/// Base class for compression codecs
///
/// Provides both synchronous and asynchronous APIs for compressing
/// and decompressing data. Synchronous methods are suitable for small
/// data that fits in memory, while async methods allow better responsiveness
/// for large data or UI contexts.
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
/// All codecs throw specific exceptions on errors:
/// - **[Lz4FormatException]**: Invalid LZ4 frame/block structure
/// - **[GzipFormatException]**: Invalid GZIP header/trailer or CRC mismatch
/// - **[DeflateFormatException]**: Invalid DEFLATE block structure
/// - **[ZstdFormatException]**: Invalid Zstandard frame/block structure
/// - **[SnappyFormatException]**: Invalid Snappy block or framing format
/// - **[StateError]**: Internal decoder state issues (e.g., exhausted input)
/// - **[RangeError]**: Bounds violations (should be rare with valid input)
///
/// All format exceptions extend [CompressionFormatException] which extends
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
/// (e.g., `Lz4Codec(maxDecompressedSize: 10 * 1024 * 1024)`).
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
abstract class CompressionCodec {
  /// Compress data synchronously
  ///
  /// Takes a byte array and returns compressed data. The entire input
  /// must fit in memory. For large data, consider using streaming APIs.
  Uint8List compress(Uint8List data);

  /// Decompress data synchronously
  ///
  /// Takes compressed data and returns the original uncompressed bytes.
  /// Throws a [CompressionFormatException] if the data is corrupted or in an
  /// invalid format.
  ///
  /// This materializes the entire output (up to the codec's
  /// `maxDecompressedSize`) before validating the trailer/checksum, so for
  /// untrusted or large input prefer the streaming codec, which is incremental
  /// and bounded (`CompressionStreamCodec`, e.g. via `CodecFactory.streaming`).
  Uint8List decompress(Uint8List data);

  /// Get codec name (e.g., 'LZ4', 'GZIP', 'Snappy')
  String get name;

  /// Check if this codec supports a given mode
  ///
  /// Use this to query codec capabilities before attempting operations:
  /// ```dart
  /// if (codec.supports(CodecMode.stream)) {
  ///   final streamCodec = CodecFactory.streaming(CodecType.lz4);
  ///   // Use streaming API
  /// }
  /// ```
  ///
  /// All codecs support [CodecMode.block]. Override this method to
  /// indicate additional capabilities like [CodecMode.stream].
  bool supports(final CodecMode mode) => mode == CodecMode.block;
}
