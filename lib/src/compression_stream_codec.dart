import 'dart:async';
import 'dart:typed_data';

/// Base abstract class for streaming compression codecs
///
/// Provides stream-based compression and decompression for processing
/// large data that doesn't fit in memory. Implementations should handle
/// chunked input and output efficiently.
///
/// ## Stream Behavior
///
/// - **Chunk sizes**: Input chunks can be any size; the codec handles
///   buffering internally. Output chunk sizes depend on the algorithm's
///   block structure (e.g., LZ4 emits 4MB blocks, Snappy emits 64KB chunks).
///
/// - **Ordering**: Output chunks are emitted in order as input is processed.
///   Some buffering occurs to satisfy format requirements (headers, checksums).
///
/// - **Finalization**: The stream completes when the input stream closes.
///   Final data (trailers, checksums) is flushed automatically.
///
/// ## Cancellation
///
/// Stream operations can be cancelled by cancelling the output stream
/// subscription. This will propagate back and cancel the input stream.
/// Internal buffers are released when the stream terminates.
///
/// ```dart
/// final subscription = codec.compress(input).listen((chunk) {
///   output.add(chunk);
/// });
/// // Later, to cancel:
/// await subscription.cancel();
/// ```
///
/// ## Memory Guarantees
///
/// **Decompression** is incremental: input is consumed and output emitted as
/// data arrives, so retained memory is bounded by roughly the back-reference
/// window plus one block, not the whole frame:
/// - GZIP: ~32 KB window + the in-progress block
/// - LZ4: one block (independent blocks; typically 64 KB, up to 4 MB)
/// - Snappy: one chunk (≤ 64 KB)
/// - Zstd: the frame window (bounded for window-descriptor frames; equal to the
///   content size for single-segment frames, which declare they fit)
///
/// `maxDecompressedSize` caps cumulative output (across all concatenated
/// members/frames); `maxBufferSize` caps buffered compressed input. Malformed
/// or oversized input is rejected as a [CompressionFormatException].
///
/// ## Integrity
///
/// By default decompression emits output *as it decodes*, so for a corrupt
/// stream some bytes may already be emitted before the trailing CRC/checksum
/// fails — inherent to streaming (as in zlib). Callers piping directly to a
/// file or downstream parser that need all-or-nothing integrity can set the
/// codec's `verified: true`, which withholds each member/frame's output until
/// its trailer validates, then releases it (raising peak memory to one
/// member/frame's output, still bounded by `maxDecompressedSize`).
///
/// **Compression** preserves history across chunks where supported, producing
/// a single standard frame/member rather than one per chunk:
/// - GZIP: one member; DEFLATE matches span chunk boundaries (32 KB window)
/// - LZ4: one frame with linked blocks (64 KB window across blocks)
/// - Zstd: one window-descriptor frame; blocks share up to 128 KB of history
/// - Snappy: independent ≤64 KB chunks (per the framing spec)
///
/// Retained compression memory is roughly the window plus one chunk.
///
/// ## Error Handling
///
/// Errors during stream processing are delivered through the stream's
/// error channel. Subscribe with an `onError` handler:
/// ```dart
/// codec.decompress(input).listen(
///   (chunk) => output.add(chunk),
///   onError: (e) => print('Decompression failed: $e'),
/// );
/// ```
abstract class CompressionStreamCodec {
  /// The name of this codec (e.g., 'LZ4', 'GZIP', 'Snappy')
  String get name;

  /// Compresses a stream of data chunks
  ///
  /// Takes an input stream of byte chunks and returns a stream of compressed
  /// chunks. The implementation should buffer as needed to maintain format
  /// requirements (e.g., block boundaries).
  ///
  /// Example:
  /// ```dart
  /// final input = File('large.txt').openRead();
  /// final compressed = codec.compress(input);
  /// await compressed.pipe(File('large.txt.lz4').openWrite());
  /// ```
  Stream<Uint8List> compress(Stream<Uint8List> input);

  /// Decompresses a stream of compressed data chunks
  ///
  /// Takes a stream of compressed byte chunks and returns a stream of
  /// decompressed chunks. Handles format validation and checksum verification.
  ///
  /// Example:
  /// ```dart
  /// final input = File('large.txt.lz4').openRead();
  /// final decompressed = codec.decompress(input);
  /// await decompressed.pipe(File('large.txt').openWrite());
  /// ```
  Stream<Uint8List> decompress(Stream<Uint8List> input);

  /// Creates a stream transformer for compression
  ///
  /// Returns a StreamTransformer that can be used with Stream.transform()
  /// for composable stream processing.
  ///
  /// Example:
  /// ```dart
  /// await File('input.txt')
  ///     .openRead()
  ///     .transform(codec.compressor)
  ///     .pipe(File('output.lz4').openWrite());
  /// ```
  StreamTransformer<Uint8List, Uint8List> get compressor =>
      StreamTransformer.fromBind(compress);

  /// Creates a stream transformer for decompression
  ///
  /// Returns a StreamTransformer that can be used with Stream.transform()
  /// for composable stream processing.
  ///
  /// Example:
  /// ```dart
  /// await File('input.lz4')
  ///     .openRead()
  ///     .transform(codec.decompressor)
  ///     .pipe(File('output.txt').openWrite());
  /// ```
  StreamTransformer<Uint8List, Uint8List> get decompressor =>
      StreamTransformer.fromBind(decompress);
}
