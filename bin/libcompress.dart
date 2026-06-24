import 'dart:io';
import 'dart:typed_data';
import 'package:libcompress/libcompress.dart';

Future<void> main(final List<String> args) async {
  final config = parse(args);

  if (config == null) {
    usage();
    exit(1);
  }

  final file = File(config.input);
  if (!file.existsSync()) {
    stderr.writeln('Error: input file not found: ${config.input}');
    exit(1);
  }

  try {
    if (config.streaming) {
      await _streaming(file, config);
    } else {
      await _buffered(file, config);
    }
  } catch (e) {
    // Output is written to a temp file and only renamed into place on success,
    // so a failure here leaves no partial/corrupt artifact at config.output.
    stderr.writeln('Error: $e');
    exit(1);
  }
}

// Buffered (whole-file) processing.
Future<void> _buffered(final File file, final Config config) async {
  final data = file.readAsBytesSync();
  // Decode/encode first (may throw on corrupt input) before touching the output.
  final result = config.decompress
      ? decompress(data, config)
      : compress(data, config);

  final temp = _tempPath(config.output);
  try {
    File(temp).writeAsBytesSync(result);
    File(temp).renameSync(config.output); // atomic within a filesystem
  } catch (e) {
    _cleanup(temp);
    rethrow;
  }

  final operation = config.decompress ? 'Decompressed' : 'Compressed';
  print(
    '$operation ${config.input} -> ${config.output} '
    '(${data.length} -> ${result.length} bytes)',
  );
}

// Streaming processing: write to a temp file, atomically rename on success, and
// clean up the temp file on any error so a mid-stream failure (e.g. a checksum
// mismatch) never leaves a partial output file behind.
Future<void> _streaming(final File file, final Config config) async {
  final temp = _tempPath(config.output);
  final input = file.openRead().cast<Uint8List>();
  final output = File(temp).openWrite();

  var bytes = 0;
  try {
    final codec = _getStreamCodec(config);
    final stream = config.decompress
        ? codec.decompress(input)
        : codec.compress(input);

    await for (final chunk in stream) {
      output.add(chunk);
      bytes += chunk.length;
    }
    await output.close();
  } catch (e) {
    try {
      await output.close();
    } catch (_) {
      // ignore secondary close errors
    }
    _cleanup(temp);
    rethrow;
  }

  File(temp).renameSync(config.output);

  final size = await file.length();
  final operation = config.decompress ? 'Decompressed' : 'Compressed';
  print(
    '$operation (streaming) ${config.input} -> ${config.output} '
    '($size -> $bytes bytes)',
  );
}

/// Sibling temp path for atomic output (same directory, so rename stays within
/// the filesystem). The pid keeps concurrent runs from colliding.
String _tempPath(final String output) => '$output.tmp-$pid';

void _cleanup(final String temp) {
  final f = File(temp);
  if (f.existsSync()) {
    try {
      f.deleteSync();
    } catch (_) {
      // best-effort cleanup
    }
  }
}

CompressionStreamCodec _getStreamCodec(final Config config) {
  return switch (config.codec) {
    CodecType.lz4 => Lz4StreamCodec(
      level: config.level,
      blockSize: config.lz4BlockSize,
      maxSize: config.maxSize,
      verified: config.verified,
    ),
    CodecType.snappy => SnappyStreamCodec(maxSize: config.maxSize ?? (1 << 30)),
    CodecType.gzip => GzipStreamCodec(
      level: config.level,
      maxSize: config.maxSize,
      verified: config.verified,
    ),
    CodecType.zstd => ZstdStreamCodec(
      level: config.level,
      blockSize: config.zstdBlockSize,
      maxSize: config.maxSize,
      verified: config.verified,
    ),
    CodecType.noop => NoopStreamCodec(),
  };
}

Uint8List compress(final Uint8List data, final Config config) {
  return switch (config.codec) {
    CodecType.lz4 => Lz4Codec(
      level: config.level,
      blockSize: config.lz4BlockSize,
    ).compress(data),
    CodecType.snappy => SnappyCodec(
      framing: config.snappyStreaming,
    ).compress(data),
    CodecType.gzip => GzipCodec(level: config.level).compress(data),
    CodecType.zstd => ZstdCodec(
      level: config.level,
      blockSize: config.zstdBlockSize,
    ).compress(data),
    CodecType.noop => data,
  };
}

Uint8List decompress(final Uint8List data, final Config config) {
  // Snappy doesn't support null maxSize, use a large value instead
  final snappyMax = config.maxSize ?? 1 << 30; // 1GB if unlimited
  return switch (config.codec) {
    CodecType.lz4 => Lz4Codec(
      maxDecompressedSize: config.maxSize,
    ).decompress(data),
    CodecType.snappy => SnappyCodec(
      framing: config.snappyStreaming,
      maxSize: snappyMax,
    ).decompress(data),
    CodecType.gzip => GzipCodec(
      maxDecompressedSize: config.maxSize,
    ).decompress(data),
    CodecType.zstd => ZstdCodec(
      maxDecompressedSize: config.maxSize,
    ).decompress(data),
    CodecType.noop => data,
  };
}

Config? parse(final List<String> args) {
  if (args.isEmpty) return null;

  var codec = CodecType.lz4;
  var level = 6;
  var decompress = false;
  var streaming = false; // Use streaming mode for large files
  var verified = false; // Withhold streamed output until checksums validate
  var lz4BlockSize = 4 * 1024 * 1024; // 4MB default
  var snappyStreaming = true; // Default to framing for snzip compatibility
  int? maxSize = 256 * 1024 * 1024; // 256MB default (null = unlimited)
  var zstdBlockSize = 128 * 1024; // 128KB default (Zstd max)
  String? input;
  String? output;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];

    if (arg == '-d' || arg == '--decompress') {
      decompress = true;
    } else if (arg == '-c' || arg == '--compress') {
      decompress = false;
    } else if (arg == '-1' || arg == '--fast') {
      level = 1;
    } else if (arg == '-9' || arg == '--best') {
      level = 9;
    } else if (arg.startsWith('-') && arg.length == 2) {
      final digit = int.tryParse(arg[1]);
      if (digit != null && digit >= 1 && digit <= 9) {
        level = digit;
      } else {
        print('Error: unknown option: $arg');
        return null;
      }
    } else if (arg == '--lz4') {
      codec = CodecType.lz4;
    } else if (arg == '--snappy') {
      codec = CodecType.snappy;
    } else if (arg == '--gzip') {
      codec = CodecType.gzip;
    } else if (arg == '--zstd') {
      codec = CodecType.zstd;
    } else if (arg == '--block-size') {
      if (i + 1 >= args.length) {
        print('Error: --block-size requires a value');
        return null;
      }
      i++;
      final blockSize = switch (args[i].toUpperCase()) {
        '64K' => 64 * 1024,
        '128K' => 128 * 1024,
        '256K' => 256 * 1024,
        '1M' => 1024 * 1024,
        '4M' => 4 * 1024 * 1024,
        _ => int.tryParse(args[i]) ?? -1,
      };
      if (blockSize <= 0) {
        print('Error: invalid block size: ${args[i]}');
        return null;
      }
      // Apply to both LZ4 and Zstd (which codec is being used)
      lz4BlockSize = blockSize;
      zstdBlockSize = blockSize > 128 * 1024 ? 128 * 1024 : blockSize;
    } else if (arg == '--raw') {
      snappyStreaming = false;
    } else if (arg == '--framing') {
      snappyStreaming = true;
    } else if (arg == '--max-size') {
      if (i + 1 >= args.length) {
        print('Error: --max-size requires a value');
        return null;
      }
      i++;
      if (args[i].toLowerCase() == 'unlimited') {
        maxSize = null;
      } else {
        final parsed = int.tryParse(args[i]);
        if (parsed == null || parsed <= 0) {
          print('Error: invalid max size: ${args[i]}');
          return null;
        }
        maxSize = parsed;
      }
    } else if (arg == '--stream') {
      streaming = true;
    } else if (arg == '--verified') {
      verified = true;
    } else if (arg == '-h' || arg == '--help') {
      return null;
    } else {
      // Positional arguments
      if (input == null) {
        input = arg;
      } else if (output == null) {
        output = arg;
      } else {
        print('Error: unexpected argument: $arg');
        return null;
      }
    }
  }

  if (input == null || output == null) {
    print('Error: input and output files required');
    return null;
  }

  return Config(
    codec: codec,
    level: level,
    decompress: decompress,
    streaming: streaming,
    verified: verified,
    input: input,
    output: output,
    lz4BlockSize: lz4BlockSize,
    snappyStreaming: snappyStreaming,
    maxSize: maxSize,
    zstdBlockSize: zstdBlockSize,
  );
}

void usage() {
  print('libcompress - Compression codecs for Dart');
  print('');
  print('Usage: libcompress [options] <input> <output>');
  print('');
  print('Options:');
  print('  -c, --compress      Compress (default)');
  print('  -d, --decompress    Decompress');
  print('  -1, --fast          Fast compression (level 1)');
  print('  -9, --best          Best compression (level 9, enables LZ4 HC)');
  print('  -[2-8]              Compression level (2-8)');
  print('  --lz4               Use LZ4 codec (default)');
  print('  --snappy            Use Snappy codec');
  print('  --gzip              Use GZIP codec');
  print('  --zstd              Use Zstd codec');
  print('  --stream            Use streaming mode for large files');
  print(
    '  --verified          Withhold streamed output until checksums validate',
  );
  print(
    '                      (all-or-nothing; buffers up to one frame of output)',
  );
  print('  -h, --help          Show this help');
  print('');
  print('LZ4 Options:');
  print('  --block-size SIZE   Block size: 64K, 256K, 1M, 4M (default: 4M)');
  print('');
  print('Snappy Options:');
  print('  --raw               Use raw block format (default: framing)');
  print('  --framing           Use framing format (compatible with snzip)');
  print('');
  print('Decompression Options (all codecs):');
  print('  --max-size BYTES    Max decompressed size (default: 256MB)');
  print('  --max-size unlimited  Disable size limit (use with trusted input)');
  print('');
  print('Zstd Options:');
  print('  --block-size SIZE   Block size: 64K, 128K (default: 128K max)');
  print('');
  print('Examples:');
  print('  libcompress input.txt output.lz4');
  print('  libcompress -9 --block-size 1M input.txt output.lz4');
  print('  libcompress --snappy --framing input.txt output.sz');
  print('  libcompress -9 --gzip input.txt output.gz');
  print('  libcompress --zstd input.txt output.zst');
  print('  libcompress -d input.lz4 output.txt');
  print('  libcompress --stream large.bin large.lz4  # streaming mode');
}

class Config {
  Config({
    required this.codec,
    required this.level,
    required this.decompress,
    required this.streaming,
    required this.verified,
    required this.input,
    required this.output,
    required this.lz4BlockSize,
    required this.snappyStreaming,
    required this.maxSize,
    required this.zstdBlockSize,
  });

  final CodecType codec;
  final int level;
  final bool decompress;
  final bool streaming;
  final bool verified;
  final String input;
  final String output;
  final int lz4BlockSize;
  final bool snappyStreaming;
  final int? maxSize; // null = unlimited
  final int zstdBlockSize;
}
