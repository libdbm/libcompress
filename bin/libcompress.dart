import 'dart:io';
import 'dart:typed_data';
import 'package:libcompress/libcompress.dart';

/// Exit code for usage errors: bad arguments, or an output that may not be
/// written. Processing failures (corrupt input, I/O errors) exit with 1.
const _usage = 2;

/// The path that means stdin (as input) or stdout (as output).
const _console = '-';

Future<void> main(final List<String> args) async {
  final Config? config;
  try {
    config = parse(args);
  } on UsageException catch (error) {
    stderr.writeln('Error: ${error.message}');
    stderr.writeln('Run with --help for usage.');
    exit(_usage);
  }
  if (config == null) {
    usage();
    exit(0);
  }

  final problem = _checkPaths(config);
  if (problem != null) {
    stderr.writeln('Error: $problem');
    exit(_usage);
  }

  try {
    if (config.streaming) {
      await _streaming(config);
    } else {
      await _buffered(config);
    }
  } catch (e) {
    // File output is written to a temp file and only renamed into place on
    // success, so a failure leaves no partial artifact at config.output.
    stderr.writeln('Error: $e');
    exit(1);
  }
}

/// Returns why the input and output paths cannot be used, or null.
String? _checkPaths(final Config config) {
  final input = config.input;
  final output = config.output;
  if (input != _console && !File(input).existsSync()) {
    return 'input file not found: $input';
  }
  if (output == _console) return null;
  if (FileSystemEntity.isDirectorySync(output)) {
    return 'output is a directory: $output';
  }
  if (input != _console && _same(input, output)) {
    return 'input and output are the same file: $input';
  }
  if (File(output).existsSync() && !config.force) {
    return 'output file exists (use -f to overwrite): $output';
  }
  return null;
}

bool _same(final String first, final String second) {
  final file = File(second);
  if (!file.existsSync()) return false;
  return File(first).resolveSymbolicLinksSync() ==
      file.resolveSymbolicLinksSync();
}

// Buffered (whole-input) processing.
Future<void> _buffered(final Config config) async {
  final data = config.input == _console
      ? await _collect(stdin)
      : File(config.input).readAsBytesSync();
  // Decode/encode first (may throw on corrupt input) before touching output.
  final result = config.decompress
      ? decompress(data, config)
      : compress(data, config);

  if (config.output == _console) {
    stdout.add(result);
    await stdout.flush();
  } else {
    final temp = _tempPath(config.output);
    try {
      File(temp).writeAsBytesSync(result);
      File(temp).renameSync(config.output); // atomic within a filesystem
    } catch (e) {
      _cleanup(temp);
      rethrow;
    }
  }
  _report(config, data.length, result.length);
}

// Streaming processing. File output goes to a temp file that is renamed into
// place on success and removed on any error, so a mid-stream failure (e.g. a
// checksum mismatch) never leaves a partial output file behind.
Future<void> _streaming(final Config config) async {
  var read = 0;
  final source = config.input == _console
      ? stdin
      : File(config.input).openRead();
  final input = source.map((final chunk) {
    read += chunk.length;
    return chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
  });
  final codec = _getStreamCodec(config);
  final stream = config.decompress
      ? codec.decompress(input)
      : codec.compress(input);

  var written = 0;
  if (config.output == _console) {
    await for (final chunk in stream) {
      stdout.add(chunk);
      written += chunk.length;
    }
    await stdout.flush();
  } else {
    final temp = _tempPath(config.output);
    final output = File(temp).openWrite();
    try {
      await for (final chunk in stream) {
        output.add(chunk);
        written += chunk.length;
      }
      await output.close();
      File(temp).renameSync(config.output);
    } catch (e) {
      try {
        await output.close();
      } catch (_) {
        // ignore secondary close errors
      }
      _cleanup(temp);
      rethrow;
    }
  }
  _report(config, read, written);
}

Future<Uint8List> _collect(final Stream<List<int>> input) async {
  final builder = BytesBuilder(copy: false);
  await input.forEach(builder.add);
  return builder.takeBytes();
}

/// Status goes to stderr, so stdout carries only data when it is the output.
void _report(final Config config, final int before, final int after) {
  final operation = config.decompress ? 'Decompressed' : 'Compressed';
  final mode = config.streaming ? ' (streaming)' : '';
  stderr.writeln(
    '$operation$mode ${config.input} -> ${config.output} '
    '($before -> $after bytes)',
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
    CodecType.snappy => SnappyStreamCodec(maxSize: config.maxSize),
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
    CodecType.noop => NoopStreamCodec(maxSize: config.maxSize),
  };
}

Uint8List compress(final Uint8List data, final Config config) {
  return switch (config.codec) {
    CodecType.lz4 => Lz4Codec(
      format: config.lz4Format,
      level: config.level,
      blockSize: config.lz4BlockSize,
    ).compress(data),
    CodecType.snappy => SnappyCodec(format: config.snappyFormat).compress(data),
    CodecType.gzip => GzipCodec(level: config.level).compress(data),
    CodecType.zstd => ZstdCodec(
      level: config.level,
      blockSize: config.zstdBlockSize,
    ).compress(data),
    CodecType.noop => data,
  };
}

Uint8List decompress(final Uint8List data, final Config config) {
  return switch (config.codec) {
    CodecType.lz4 => Lz4Codec(
      format: config.lz4Format,
      maxSize: config.maxSize,
    ).decompress(data),
    CodecType.snappy => SnappyCodec(
      format: config.snappyFormat,
      maxSize: config.maxSize,
    ).decompress(data),
    CodecType.gzip => GzipCodec(maxSize: config.maxSize).decompress(data),
    CodecType.zstd => ZstdCodec(maxSize: config.maxSize).decompress(data),
    CodecType.noop => NoopCodec(maxSize: config.maxSize).decompress(data),
  };
}

/// A command-line mistake, reported on stderr with exit code 2.
class UsageException implements Exception {
  UsageException(this.message);

  final String message;
}

/// Parses [args]. Returns null when help was requested; throws
/// [UsageException] for invalid arguments.
Config? parse(final List<String> args) {
  if (args.isEmpty) throw UsageException('input and output files required');

  var codec = CodecType.lz4;
  int? level;
  var decompress = false;
  var streaming = false; // Use streaming mode for large files
  var verified = false; // Withhold streamed output until checksums validate
  var force = false;
  var raw = false;
  var hadoop = false;
  var framing = false;
  var lz4BlockSize = 4 * 1024 * 1024; // 4MB default
  int? maxSize = CodecFactory.defaultMaxSize; // null = unlimited
  var zstdBlockSize = 128 * 1024; // 128KB default (Zstd max)
  String? input;
  String? output;

  String value(final int index, final String option) {
    if (index >= args.length) {
      throw UsageException('$option requires a value');
    }
    return args[index];
  }

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '-h' || '--help':
        return null;
      case '-d' || '--decompress':
        decompress = true;
      case '-c' || '--compress':
        decompress = false;
      case '-f' || '--force':
        force = true;
      case '--fast':
        level = 1;
      case '--best':
        level = 9;
      case '--level':
        final text = value(++i, arg);
        level = int.tryParse(text);
        if (level == null) throw UsageException('invalid level: $text');
      case '--lz4':
        codec = CodecType.lz4;
      case '--snappy':
        codec = CodecType.snappy;
      case '--gzip':
        codec = CodecType.gzip;
      case '--zstd':
        codec = CodecType.zstd;
      case '--raw':
        raw = true;
      case '--hadoop':
        hadoop = true;
      case '--framing':
        framing = true;
      case '--stream':
        streaming = true;
      case '--verified':
        verified = true;
      case '--block-size':
        final text = value(++i, arg);
        final size = switch (text.toUpperCase()) {
          '64K' => 64 * 1024,
          '128K' => 128 * 1024,
          '256K' => 256 * 1024,
          '1M' => 1024 * 1024,
          '4M' => 4 * 1024 * 1024,
          _ => int.tryParse(text) ?? -1,
        };
        if (size <= 0 || size > lz4BlockSize4M) {
          throw UsageException('invalid block size: $text (1 to 4M)');
        }
        lz4BlockSize = size;
        zstdBlockSize = size > 128 * 1024 ? 128 * 1024 : size;
      case '--max-size':
        final text = value(++i, arg);
        if (text.toLowerCase() == 'unlimited') {
          maxSize = null;
        } else {
          final parsed = int.tryParse(text);
          if (parsed == null || parsed <= 0) {
            throw UsageException('invalid max size: $text');
          }
          maxSize = parsed;
        }
      default:
        final digit = arg.length == 2 && arg.startsWith('-')
            ? int.tryParse(arg[1])
            : null;
        if (digit != null && digit >= 1) {
          level = digit;
        } else if (arg.startsWith('-') && arg != _console) {
          throw UsageException('unknown option: $arg');
        } else if (input == null) {
          input = arg;
        } else if (output == null) {
          output = arg;
        } else {
          throw UsageException('unexpected argument: $arg');
        }
    }
  }

  if (input == null || output == null) {
    throw UsageException('input and output files required');
  }

  if (raw && hadoop) {
    throw UsageException('--raw and --hadoop cannot be combined');
  }
  if (hadoop && codec != CodecType.lz4) {
    throw UsageException('--hadoop applies only to --lz4');
  }
  if (raw && codec != CodecType.lz4 && codec != CodecType.snappy) {
    throw UsageException('--raw applies only to --lz4 and --snappy');
  }
  if (framing && codec != CodecType.snappy) {
    throw UsageException('--framing applies only to --snappy');
  }
  if (framing && raw) {
    throw UsageException('--raw and --framing cannot be combined');
  }
  if (streaming && (raw || hadoop)) {
    throw UsageException('--stream needs a framed format, not --raw/--hadoop');
  }
  // Snappy has no levels, so any level is accepted and ignored.
  final most = codec == CodecType.zstd ? 22 : 9;
  if (level != null &&
      codec != CodecType.snappy &&
      (level < 1 || level > most)) {
    throw UsageException(
      'level $level is out of range for ${codec.name} (1-$most)',
    );
  }

  return Config(
    codec: codec,
    // Each codec's own default, so the CLI matches the library.
    level:
        level ??
        switch (codec) {
          CodecType.lz4 => Lz4Codec().level,
          CodecType.gzip => GzipCodec().level,
          CodecType.zstd => ZstdCodec().level,
          CodecType.snappy || CodecType.noop => 1,
        },
    decompress: decompress,
    streaming: streaming,
    verified: verified,
    force: force,
    input: input,
    output: output,
    lz4Format: raw
        ? Lz4Format.raw
        : hadoop
        ? Lz4Format.hadoop
        : Lz4Format.frame,
    // Framed by default, for snzip compatibility.
    snappyFormat: raw ? SnappyFormat.raw : SnappyFormat.framed,
    lz4BlockSize: lz4BlockSize,
    maxSize: maxSize,
    zstdBlockSize: zstdBlockSize,
  );
}

void usage() {
  print('libcompress - Compression codecs for Dart');
  print('');
  print('Usage: libcompress [options] <input> <output>');
  print('');
  print('Use - as <input> for stdin or as <output> for stdout. Status and');
  print('errors are written to stderr. Usage errors exit with 2, processing');
  print('failures with 1.');
  print('');
  print('Options:');
  print('  -c, --compress      Compress (default)');
  print('  -d, --decompress    Decompress');
  print('  -f, --force         Overwrite an existing output file');
  print('  -1, --fast          Fast compression (level 1)');
  print('  -9, --best          Best compression (level 9)');
  print('  -[2-8]              Compression level (default: the codec default)');
  print('  --level N           Compression level: 1-9, or 1-22 for --zstd');
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
  print('Formats (not with --stream):');
  print(
    '  --raw               LZ4 or Snappy raw block (Parquet LZ4_RAW, SNAPPY)',
  );
  print('  --hadoop            LZ4 Hadoop block framing (Parquet LZ4)');
  print('  --framing           Snappy framing format (default for --snappy)');
  print('');
  print('LZ4 Options:');
  print('  --block-size SIZE   Block size: 64K, 256K, 1M, 4M (default: 4M)');
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
  print('  libcompress --snappy input.txt output.sz');
  print('  libcompress -9 --gzip input.txt output.gz');
  print('  libcompress --zstd - - < input.txt > output.zst');
  print('  libcompress -d -f input.lz4 output.txt');
  print('  libcompress --stream large.bin large.lz4  # streaming mode');
}

class Config {
  Config({
    required this.codec,
    required this.level,
    required this.decompress,
    required this.streaming,
    required this.verified,
    required this.force,
    required this.input,
    required this.output,
    required this.lz4Format,
    required this.snappyFormat,
    required this.lz4BlockSize,
    required this.maxSize,
    required this.zstdBlockSize,
  });

  final CodecType codec;
  final int level;
  final bool decompress;
  final bool streaming;
  final bool verified;
  final bool force;
  final String input;
  final String output;
  final Lz4Format lz4Format;
  final SnappyFormat snappyFormat;
  final int lz4BlockSize;
  final int? maxSize; // null = unlimited
  final int zstdBlockSize;
}
