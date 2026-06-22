import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Set BENCHMARK_VERBOSE=1 to enable detailed output
final _verbose = Platform.environment['BENCHMARK_VERBOSE'] == '1';

/// Set RUN_BENCHMARKS=1 to enable full benchmarks (including CLI tests)
final _benchmarks = Platform.environment['RUN_BENCHMARKS'] == '1';

/// Set RUN_CLI_BENCHMARKS=1 to enable CLI tool benchmarks
/// (requires lz4, gzip, snzip, zstd to be installed)
final _cliBenchmarks = Platform.environment['RUN_CLI_BENCHMARKS'] == '1';

void main() {
  group('Comprehensive Compression Benchmark', () {
    // Wall-clock "best of 5" timing is slow (~minute) and not a reliable CI
    // signal, so this is gated out of the default suite. Deterministic
    // compression-ratio floors live in perf_budget_test.dart, which always runs.
    test('generate detailed performance comparison report', () {
      final report = BenchmarkReport(
        verbose: _verbose,
        runCli: _benchmarks || _cliBenchmarks,
      );
      report.run();
      report.print();

      // A green benchmark must mean every round-trip actually verified
      // (excludes CLI tools that weren't available, marked error 'N/A').
      final failed =
          report.results.where((r) => !r.valid && r.error != 'N/A').toList();
      expect(
        failed,
        isEmpty,
        reason: 'codec round-trip failures: '
            '${failed.map((f) => '${f.implementation} ${f.codec}/${f.dataset}: ${f.error ?? 'invalid'}').join('; ')}',
      );
    }, skip: !_benchmarks ? 'set RUN_BENCHMARKS=1 to run benchmarks' : null);
  });
}

class BenchmarkReport {
  final bool verbose;
  final bool runCli;
  final testDatasets = <Dataset>[];
  final results = <BenchmarkResult>[];

  BenchmarkReport({this.verbose = false, this.runCli = false});

  void run() {
    _prepareDatasets();
    _runDartBenchmarks();
    if (runCli) {
      _runCliBenchmarks();
    }
  }

  void _prepareDatasets() {
    // Small datasets (< 10KB)
    testDatasets.add(Dataset(
      name: 'Empty',
      category: 'Small',
      data: Uint8List(0),
    ));

    testDatasets.add(Dataset(
      name: 'Tiny Text',
      category: 'Small',
      data: Uint8List.fromList('Hello, World! This is a test.'.codeUnits),
    ));

    testDatasets.add(Dataset(
      name: '1KB Random',
      category: 'Small',
      data: Uint8List.fromList(List.generate(1024, (i) => (i * 7 + 13) % 256)),
    ));

    testDatasets.add(Dataset(
      name: '1KB Zeros',
      category: 'Small',
      data: Uint8List(1024),
    ));

    testDatasets.add(Dataset(
      name: '1KB Repeated',
      category: 'Small',
      data: Uint8List.fromList(List.filled(1024, 65)),
    ));

    // Medium datasets (10KB - 100KB)
    if (File('test/fixtures/data/html').existsSync()) {
      final html = File('test/fixtures/data/html').readAsBytesSync();
      testDatasets.add(Dataset(
        name: 'HTML (${_formatBytes(html.length)})',
        category: 'Medium',
        data: html,
      ));
    }

    testDatasets.add(Dataset(
      name: '64KB Random',
      category: 'Medium',
      data: Uint8List.fromList(List.generate(65536, (i) => (i * 7 + 13) % 256)),
    ));

    testDatasets.add(Dataset(
      name: '64KB Pattern',
      category: 'Medium',
      data: Uint8List.fromList(List.generate(65536, (i) => (i % 256))),
    ));

    // Large datasets (> 100KB)
    if (File('test/fixtures/data/canterbury/alice29.txt').existsSync()) {
      final alice = File('test/fixtures/data/canterbury/alice29.txt').readAsBytesSync();
      testDatasets.add(Dataset(
        name: 'Alice29 (${_formatBytes(alice.length)})',
        category: 'Large',
        data: alice,
      ));
    }

    if (File('test/fixtures/data/calgary/paper1').existsSync()) {
      final paper = File('test/fixtures/data/calgary/paper1').readAsBytesSync();
      testDatasets.add(Dataset(
        name: 'Paper1 (${_formatBytes(paper.length)})',
        category: 'Large',
        data: paper,
      ));
    }

    testDatasets.add(Dataset(
      name: '1MB Random',
      category: 'Large',
      data: Uint8List.fromList(List.generate(1024 * 1024, (i) => (i * 7 + 13) % 256)),
    ));

    // Multi-MB fixtures (exercise multi-block + deep-match cost at high levels)
    for (final spec in const [
      ['Bible', 'large/bible.txt'],
      ['E.coli', 'large/E.coli'],
      ['URLs', 'urls.10K'],
    ]) {
      final path = 'test/fixtures/data/${spec[1]}';
      if (File(path).existsSync()) {
        final data = File(path).readAsBytesSync();
        testDatasets.add(Dataset(
          name: '${spec[0]} (${_formatBytes(data.length)})',
          category: 'Large',
          data: data,
        ));
      }
    }
  }

  void _runDartBenchmarks() {
    for (final dataset in testDatasets) {
      // LZ4
      _benchmarkDartCodec(dataset, 'LZ4-Fast', Lz4Codec(level: 1));
      _benchmarkDartCodec(dataset, 'LZ4-HC', Lz4Codec(level: 9));

      // Snappy
      _benchmarkDartCodec(dataset, 'Snappy-Raw', SnappyCodec(framing: false));
      _benchmarkDartCodec(dataset, 'Snappy-Framing', SnappyCodec(framing: true));

      // Gzip
      _benchmarkDartCodec(dataset, 'Gzip-1', GzipCodec(level: 1));
      _benchmarkDartCodec(dataset, 'Gzip-6', GzipCodec(level: 6));
      _benchmarkDartCodec(dataset, 'Gzip-9', GzipCodec(level: 9));

      // Zstd across levels (search depth scales steeply: 32 -> 128 -> 1024)
      for (final level in _zstdLevels) {
        _benchmarkDartCodec(dataset, 'Zstd-$level', ZstdCodec(level: level));
      }
    }
  }

  static const _zstdLevels = [3, 9, 19];

  void _benchmarkDartCodec(final Dataset dataset, final String codecName, final CompressionCodec codec) {
    if (dataset.data.isEmpty) {
      // Skip empty for timing accuracy
      final compressed = codec.compress(dataset.data);
      final decompressed = codec.decompress(compressed);

      results.add(BenchmarkResult(
        dataset: dataset.name,
        codec: codecName,
        implementation: 'Dart',
        originalSize: 0,
        compressedSize: compressed.length,
        compressTimeMs: 0,
        decompressTimeMs: 0,
        compressionRatio: 0,
        valid: decompressed.isEmpty,
      ));
      return;
    }

    try {
      // Warmup
      var compressed = codec.compress(dataset.data);
      codec.decompress(compressed);

      // Measure compression (5 runs, take best)
      var bestCompressMs = double.infinity;
      for (var i = 0; i < 5; i++) {
        final start = DateTime.now();
        compressed = codec.compress(dataset.data);
        final end = DateTime.now();
        final ms = end.difference(start).inMicroseconds / 1000.0;
        if (ms < bestCompressMs) bestCompressMs = ms;
      }

      // Measure decompression (5 runs, take best)
      var bestDecompressMs = double.infinity;
      Uint8List? decompressed;
      for (var i = 0; i < 5; i++) {
        final start = DateTime.now();
        decompressed = codec.decompress(compressed);
        final end = DateTime.now();
        final ms = end.difference(start).inMicroseconds / 1000.0;
        if (ms < bestDecompressMs) bestDecompressMs = ms;
      }

      final valid = decompressed != null && _arraysEqual(decompressed, dataset.data);
      final ratio = dataset.data.isEmpty ? 0.0 :
          (dataset.data.length - compressed.length) * 100.0 / dataset.data.length;

      results.add(BenchmarkResult(
        dataset: dataset.name,
        codec: codecName,
        implementation: 'Dart',
        originalSize: dataset.data.length,
        compressedSize: compressed.length,
        compressTimeMs: bestCompressMs,
        decompressTimeMs: bestDecompressMs,
        compressionRatio: ratio,
        valid: valid,
      ));
    } catch (e) {
      results.add(BenchmarkResult(
        dataset: dataset.name,
        codec: codecName,
        implementation: 'Dart',
        originalSize: dataset.data.length,
        compressedSize: 0,
        compressTimeMs: 0,
        decompressTimeMs: 0,
        compressionRatio: 0,
        valid: false,
        error: e.toString(),
      ));
    }
  }

  void _runCliBenchmarks() {
    // Use platform-agnostic temp directory
    final tmpDir = Directory.systemTemp;

    for (final dataset in testDatasets) {
      if (dataset.data.isEmpty) continue; // CLI tools don't handle empty well

      // Create temp file with sanitized name
      final safeName = dataset.name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final tmpFile = File('${tmpDir.path}/benchmark_$safeName.dat');
      tmpFile.writeAsBytesSync(dataset.data);

      try {
        _benchmarkCli(dataset, 'LZ4-Fast', 'lz4', ['-1', '-f'], '.lz4', tmpFile);
        _benchmarkCli(dataset, 'LZ4-HC', 'lz4', ['-9', '-f'], '.lz4', tmpFile);
        _benchmarkCli(dataset, 'Gzip-1', 'gzip', ['-1', '-f', '-k'], '.gz', tmpFile);
        _benchmarkCli(dataset, 'Gzip-6', 'gzip', ['-6', '-f', '-k'], '.gz', tmpFile);
        _benchmarkCli(dataset, 'Gzip-9', 'gzip', ['-9', '-f', '-k'], '.gz', tmpFile);

        // Snappy via snzip if available
        final snzipAvailable = Process.runSync('which', ['snzip']).exitCode == 0;
        if (snzipAvailable) {
          _benchmarkCli(dataset, 'Snappy-Raw', 'snzip', ['-t', 'snappy', '-k'], '.snappy', tmpFile);
        }

        // Zstd if available
        final zstdAvailable = Process.runSync('which', ['zstd']).exitCode == 0;
        if (zstdAvailable) {
          for (final level in _zstdLevels) {
            _benchmarkCli(
              dataset, 'Zstd-$level', 'zstd', ['-$level', '-f'], '.zst', tmpFile);
          }
        }
      } finally {
        if (tmpFile.existsSync()) tmpFile.deleteSync();
        final lz4 = File('${tmpFile.path}.lz4');
        if (lz4.existsSync()) lz4.deleteSync();
        final gz = File('${tmpFile.path}.gz');
        if (gz.existsSync()) gz.deleteSync();
        final snappy = File('${tmpFile.path}.snappy');
        if (snappy.existsSync()) snappy.deleteSync();
        final zst = File('${tmpFile.path}.zst');
        if (zst.existsSync()) zst.deleteSync();
      }
    }
  }

  void _benchmarkCli(
    final Dataset dataset,
    final String codecName,
    final String command,
    final List<String> args,
    final String extension,
    final File tmpFile,
  ) {
    try {
      final compressedFile = File('${tmpFile.path}$extension');

      // Warmup
      Process.runSync(command, [...args, tmpFile.path]);
      compressedFile.deleteSync();

      // Measure compression (3 runs, take best)
      var bestCompressMs = double.infinity;
      for (var i = 0; i < 3; i++) {
        final start = DateTime.now();
        final result = Process.runSync(command, [...args, tmpFile.path]);
        final end = DateTime.now();

        if (result.exitCode != 0) {
          throw Exception('Compression failed: ${result.stderr}');
        }

        final ms = end.difference(start).inMicroseconds / 1000.0;
        if (ms < bestCompressMs) bestCompressMs = ms;

        if (i < 2) compressedFile.deleteSync();
      }

      final compressedSize = compressedFile.lengthSync();

      // Decompress to verify and measure
      final tmpDir = Directory.systemTemp;
      final decompressedFile = File('${tmpDir.path}/benchmark_decompressed.dat');
      var bestDecompressMs = double.infinity;

      final decompressCmd = _getDecompressCommand(command);
      final decompressArgs = _getDecompressArgs(command, compressedFile.path, decompressedFile.path);

      for (var i = 0; i < 3; i++) {
        final start = DateTime.now();
        final result = Process.runSync(decompressCmd, decompressArgs);
        final end = DateTime.now();

        if (result.exitCode != 0) {
          throw Exception('Decompression failed: ${result.stderr}');
        }

        // Handle stdout redirect for gzip/snzip
        if (_needsStdoutRedirect(decompressCmd)) {
          decompressedFile.writeAsBytesSync(result.stdout as List<int>);
        }

        final ms = end.difference(start).inMicroseconds / 1000.0;
        if (ms < bestDecompressMs) bestDecompressMs = ms;

        if (i < 2 && decompressedFile.existsSync()) decompressedFile.deleteSync();
      }

      final decompressed = decompressedFile.readAsBytesSync();
      final valid = _arraysEqual(decompressed, dataset.data);

      final ratio = (dataset.data.length - compressedSize) * 100.0 / dataset.data.length;

      results.add(BenchmarkResult(
        dataset: dataset.name,
        codec: codecName,
        implementation: 'CLI',
        originalSize: dataset.data.length,
        compressedSize: compressedSize,
        compressTimeMs: bestCompressMs,
        decompressTimeMs: bestDecompressMs,
        compressionRatio: ratio,
        valid: valid,
      ));

      if (compressedFile.existsSync()) compressedFile.deleteSync();
      if (decompressedFile.existsSync()) decompressedFile.deleteSync();
    } catch (e) {
      // CLI tool not available or failed
      results.add(BenchmarkResult(
        dataset: dataset.name,
        codec: codecName,
        implementation: 'CLI',
        originalSize: dataset.data.length,
        compressedSize: 0,
        compressTimeMs: 0,
        decompressTimeMs: 0,
        compressionRatio: 0,
        valid: false,
        error: 'N/A',
      ));
    }
  }

  String _getDecompressCommand(final String compressCmd) {
    switch (compressCmd) {
      case 'lz4':
        return 'lz4';
      case 'gzip':
        return 'gzip';
      case 'snzip':
        return 'snzip';
      case 'zstd':
        return 'zstd';
      default:
        return compressCmd;
    }
  }

  List<String> _getDecompressArgs(final String compressCmd, final String input, final String output) {
    switch (compressCmd) {
      case 'lz4':
        return ['-d', input, output];
      case 'gzip':
        return ['-d', '-c', input, output]; // Note: will redirect stdout manually
      case 'snzip':
        return ['-d', '-c', input, output];
      case 'zstd':
        return ['-d', input, '-o', output];
      default:
        return ['-d', input, output];
    }
  }

  bool _needsStdoutRedirect(final String cmd) {
    return cmd == 'gzip' || cmd == 'snzip';
  }

  void print() {
    final valid = results.where((r) => r.valid).length;
    final total = results.length;
    final failed = results.where((r) => !r.valid && r.error != 'N/A').toList();

    if (!verbose) {
      // Summary mode (default)
      stdout.writeln('Benchmark: $valid/$total passed');
      if (failed.isNotEmpty) {
        for (final f in failed) {
          stdout.writeln('  FAIL: ${f.codec}/${f.implementation} on ${f.dataset}');
        }
      }
      return;
    }

    // Verbose mode - full report
    stdout.writeln('\n${'=' * 120}');
    stdout.writeln('COMPREHENSIVE COMPRESSION BENCHMARK REPORT');
    stdout.writeln('=' * 120);
    stdout.writeln('');

    // Print datasets summary
    stdout.writeln('DATASETS:');
    for (final category in ['Small', 'Medium', 'Large']) {
      final datasets = testDatasets.where((d) => d.category == category).toList();
      if (datasets.isNotEmpty) {
        stdout.writeln('  $category:');
        for (final dataset in datasets) {
          stdout.writeln('    ${dataset.name.padRight(30)} ${_formatBytes(dataset.data.length)}');
        }
      }
    }
    stdout.writeln('');

    // Group results by dataset and codec
    final codecNames = results.map((r) => r.codec).toSet().toList()..sort();
    final datasetNames = results.map((r) => r.dataset).toSet().toList();

    for (final dataset in datasetNames) {
      stdout.writeln('-' * 120);
      stdout.writeln('DATASET: $dataset');
      stdout.writeln('-' * 120);
      stdout.writeln('');

      // Header
      final header = '${'Codec'.padRight(20)} ${'Impl'.padRight(6)} '
          '${'Ratio'.padLeft(8)} ${'Compressed'.padLeft(12)} '
          '${'Comp(ms)'.padLeft(10)} ${'Decomp(ms)'.padLeft(10)} '
          '${'Comp(MB/s)'.padLeft(12)} ${'Decomp(MB/s)'.padLeft(12)} Status';
      stdout.writeln(header);
      stdout.writeln('-' * 120);

      for (final codec in codecNames) {
        final dartResult = results.where((r) => r.dataset == dataset && r.codec == codec && r.implementation == 'Dart').firstOrNull;
        final cliResult = results.where((r) => r.dataset == dataset && r.codec == codec && r.implementation == 'CLI').firstOrNull;

        if (dartResult != null) {
          stdout.writeln(_formatLine(dartResult));
        }
        if (cliResult != null && cliResult.error != 'N/A') {
          stdout.writeln(_formatLine(cliResult));
        }
      }

      stdout.writeln('');
    }

    stdout.writeln('=' * 120);
    stdout.writeln('');
  }

  String _formatLine(final BenchmarkResult result) {
    final codecImpl = '${result.codec.padRight(20)} ${result.implementation.padRight(6)}';
    final ratio = '${result.compressionRatio.toStringAsFixed(1)}%'.padLeft(8);
    final compressed = _formatBytes(result.compressedSize).padLeft(12);

    final compressMs = result.compressTimeMs < 0.01 ? '<0.01' : result.compressTimeMs.toStringAsFixed(2);
    final decompressMs = result.decompressTimeMs < 0.01 ? '<0.01' : result.decompressTimeMs.toStringAsFixed(2);

    final compressMbps = result.compressTimeMs > 0
        ? (result.originalSize / (result.compressTimeMs / 1000.0) / (1024 * 1024)).toStringAsFixed(1)
        : 'N/A';
    final decompressMbps = result.decompressTimeMs > 0
        ? (result.originalSize / (result.decompressTimeMs / 1000.0) / (1024 * 1024)).toStringAsFixed(1)
        : 'N/A';

    final status = result.valid ? '✓' : (result.error != null ? 'ERROR' : '✗');

    return '$codecImpl $ratio $compressed ${compressMs.padLeft(10)} ${decompressMs.padLeft(10)} '
        '${compressMbps.padLeft(12)} ${decompressMbps.padLeft(12)} $status';
  }

  bool _arraysEqual(final Uint8List a, final Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _formatBytes(final int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

class Dataset {
  final String name;
  final String category;
  final Uint8List data;

  Dataset({
    required this.name,
    required this.category,
    required this.data,
  });
}

class BenchmarkResult {
  final String dataset;
  final String codec;
  final String implementation;
  final int originalSize;
  final int compressedSize;
  final double compressTimeMs;
  final double decompressTimeMs;
  final double compressionRatio;
  final bool valid;
  final String? error;

  BenchmarkResult({
    required this.dataset,
    required this.codec,
    required this.implementation,
    required this.originalSize,
    required this.compressedSize,
    required this.compressTimeMs,
    required this.decompressTimeMs,
    required this.compressionRatio,
    required this.valid,
    this.error,
  });
}
