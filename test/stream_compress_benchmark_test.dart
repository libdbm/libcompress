import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Quantifies streaming-COMPRESS overhead (per-chunk window re-hash + per-block
/// table builds + allocations) by comparing whole-buffer block compression to
/// streaming compression on the same data. Gated: RUN_BENCHMARKS=1 to print.
final bool _verbose =
    Platform.environment['RUN_BENCHMARKS'] == '1' ||
    Platform.environment['BENCHMARK_VERBOSE'] == '1';

Future<int> _timeStreamCompress(
  final CompressionStreamCodec codec,
  final List<Uint8List> chunks,
) async {
  var produced = 0;
  await for (final c in codec.compress(Stream.fromIterable(chunks))) {
    produced += c.length;
  }
  return produced;
}

double _mbps(final int bytes, final double ms) => (bytes / 1e6) / (ms / 1000.0);

void main() {
  group('Streaming compress throughput vs block', () {
    const path = 'test/fixtures/data/large/bible.txt';
    final exists = File(path).existsSync();
    final data = exists ? File(path).readAsBytesSync() : Uint8List(0);
    final chunks = <Uint8List>[
      if (exists)
        for (var i = 0; i < data.length; i += 65536)
          Uint8List.sublistView(
            data,
            i,
            (i + 65536) < data.length ? i + 65536 : data.length,
          ),
    ];

    final cases = <String, (CompressionCodec, CompressionStreamCodec)>{
      'GZIP': (GzipCodec(), GzipStreamCodec()),
      'LZ4': (Lz4Codec(), Lz4StreamCodec()),
      'Zstd': (ZstdCodec(), ZstdStreamCodec()),
    };

    for (final entry in cases.entries) {
      test('${entry.key} streaming compress completes', () async {
        if (!exists) {
          markTestSkipped('fixture missing');
          return;
        }
        final (block, stream) = entry.value;
        final runs = _verbose ? 3 : 1;

        block.compress(data); // warmup
        var bestBlock = double.infinity;
        for (var i = 0; i < runs; i++) {
          final sw = Stopwatch()..start();
          block.compress(data);
          sw.stop();
          bestBlock = sw.elapsedMicroseconds / 1000.0 < bestBlock
              ? sw.elapsedMicroseconds / 1000.0
              : bestBlock;
        }

        await _timeStreamCompress(stream, chunks); // warmup
        var bestStream = double.infinity;
        var produced = 0;
        for (var i = 0; i < runs; i++) {
          final sw = Stopwatch()..start();
          produced = await _timeStreamCompress(stream, chunks);
          sw.stop();
          bestStream = sw.elapsedMicroseconds / 1000.0 < bestStream
              ? sw.elapsedMicroseconds / 1000.0
              : bestStream;
        }

        expect(produced, greaterThan(0));

        if (_verbose) {
          // ignore: avoid_print
          print(
            '${entry.key}: block ${_mbps(data.length, bestBlock).toStringAsFixed(1)} MB/s, '
            'stream ${_mbps(data.length, bestStream).toStringAsFixed(1)} MB/s '
            '(stream ${(bestStream / bestBlock).toStringAsFixed(2)}x slower)',
          );
        }
      });
    }
  });
}
