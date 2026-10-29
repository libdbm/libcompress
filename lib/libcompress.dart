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
/// // A Parquet page, whose uncompressed size is known
/// final page = Lz4Codec(format: Lz4Format.raw).decompress(bytes, size: n);
///
/// // Stream-based compression
/// final streamCodec = CodecFactory.streaming(CodecType.lz4);
/// final compressedStream = streamCodec.compress(inputStream);
/// ```
///
/// ## Available Codecs
///
/// - **LZ4**: Fast compression with good ratios. Levels 1-9: level 1 is the
///   fast compressor, 2-9 high-compression (HC) mode. Frame, raw block
///   (Parquet `LZ4_RAW`) and Hadoop (Parquet `LZ4`) formats.
/// - **Snappy**: Very fast compression. Raw block and framing formats.
/// - **GZIP**: Full DEFLATE implementation with GZIP framing (RFC 1952).
/// - **Zstd**: Zstandard (RFC 8878) without dictionaries, including compressed
///   blocks with Huffman/FSE encoding and sequence encoding.
///
/// The framed formats interoperate with the command-line tools (lz4, snzip,
/// gzip, zstd); stream codecs use the framed formats.
library;

// Core compression interfaces
export 'src/compression_codec.dart';
export 'src/compression_options.dart'
    hide
        defaultMaxSize,
        defaultMaxBufferSize,
        validateLevel,
        validateRange,
        validatePositive,
        validateOptionalPositive;
export 'src/compression_stream_codec.dart';
export 'src/codec_factory.dart';

// Compression exceptions
export 'src/exceptions.dart' hide guardFormat;

// LZ4 codec
export 'src/lz4/lz4_codec.dart';
export 'src/lz4/lz4_stream_codec.dart' show Lz4StreamCodec;
export 'src/lz4/lz4_common.dart'
    show
        lz4BlockSize64K,
        lz4BlockSize256K,
        lz4BlockSize1M,
        lz4BlockSize4M,
        lz4DefaultBlockSize,
        Lz4Format;

// Snappy codec
export 'src/snappy/snappy_codec.dart';
export 'src/snappy/snappy_stream_codec.dart' show SnappyStreamCodec;

// GZIP codec
export 'src/gzip/gzip_codec.dart' show GzipCodec, GzipOptions;
export 'src/gzip/gzip_stream_codec.dart' show GzipStreamCodec;

// Zstd codec
export 'src/zstd/zstd_codec.dart';
export 'src/zstd/zstd_stream_codec.dart' show ZstdStreamCodec;

// Noop codec (pass-through, for testing)
export 'src/noop/noop_codec.dart';
export 'src/noop/noop_stream_codec.dart';

// Checksums
export 'src/util/crc32.dart';
export 'src/util/crc32c.dart';
