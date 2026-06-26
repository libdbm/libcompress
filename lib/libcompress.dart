/// Pure Dart implementations of common compression algorithms
///
/// This library provides pure Dart implementations of LZ4, Snappy, GZIP, and Zstd
/// compression, with no native dependencies. It supports both in-memory (block)
/// compression and stream-based processing.
///
/// ## Basic Usage
///
/// ```dart
/// import 'package:libcompress/libcompress.dart';
///
/// // Block-based compression
/// final codec = CodecFactory.codec(CodecType.lz4);
/// final compressed = codec.compress(data);
/// final decompressed = codec.decompress(compressed);
///
/// // Stream-based compression
/// final streamCodec = CodecFactory.streaming(CodecType.lz4);
/// final compressedStream = streamCodec.compress(inputStream);
/// ```
///
/// ## Available Codecs
///
/// - **LZ4**: Fast compression with good ratios. Supports levels 1-9 (HC mode).
/// - **Snappy**: Very fast compression. Supports raw block and framing formats.
/// - **GZIP**: Full DEFLATE implementation with GZIP framing (RFC 1952).
/// - **Zstd**: Full Zstandard support (RFC 8878) including compressed blocks
///   with Huffman/FSE encoding, sequence encoding, and repeat offsets.
///
/// All codecs are CLI-compatible with their respective command-line tools
/// (lz4, snzip, gzip, zstd).
library;

// Core compression interfaces
export 'src/compression_codec.dart';
export 'src/compression_options.dart';
export 'src/compression_stream_codec.dart';
export 'src/codec_factory.dart';

// Compression exceptions
export 'src/exceptions.dart';

// LZ4 codec
export 'src/lz4/lz4_codec.dart';
export 'src/lz4/lz4_stream_codec.dart';
export 'src/lz4/lz4_common.dart'
    show
        lz4BlockSize64K,
        lz4BlockSize256K,
        lz4BlockSize1M,
        lz4BlockSize4M,
        lz4DefaultBlockSize;

// Snappy codec
export 'src/snappy/snappy_codec.dart';
export 'src/snappy/snappy_stream_codec.dart';

// GZIP codec
export 'src/gzip/gzip_codec.dart';
export 'src/gzip/gzip_stream_codec.dart';

// Zstd codec
export 'src/zstd/zstd_codec.dart';
export 'src/zstd/zstd_stream_codec.dart';
export 'src/zstd/zstd_common.dart';

// Noop codec (pass-through, for testing)
export 'src/noop/noop_codec.dart';
export 'src/noop/noop_stream_codec.dart';

// Checksums
export 'src/util/crc32.dart';
export 'src/util/crc32c.dart';
