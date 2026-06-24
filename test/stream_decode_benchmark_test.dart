import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Measures streaming-DECODE throughput (previously only block decode was
/// benchmarked). Gated: set RUN_BENCHMARKS=1 for MB/s output; otherwise it just
/// verifies streaming decode round-trips on a large fixture.
final bool _verbose =
    Platform.environment['RUN_BENCHMARKS'] == '1' ||
    Platform.environment['BENCHMARK_VERBOSE'] == '1';

Future<Uint8List> _decodeStream(
  final CompressionStreamCodec codec,
  final Uint8List compressed,
  final int chunkSize,
) async {
  final chunks = <Uint8List>[];
  for (var i = 0; i < compressed.length; i += chunkSize) {
    final end = (i + chunkSize) < compressed.length
        ? i + chunkSize
        : compressed.length;
    chunks.add(Uint8List.sublistView(compressed, i, end));
  }
  final out = BytesBuilder(copy: false);
  await for (final c in codec.decompress(Stream.fromIterable(chunks))) {
    out.add(c);
  }
  return out.takeBytes();
}

void main() {
  group('Streaming decode throughput', () {
    const path = 'test/fixtures/data/large/bible.txt';
    final exists = File(path).existsSync();
    final data = exists ? File(path).readAsBytesSync() : Uint8List(0);

    final cases = <String, (CompressionCodec, CompressionStreamCodec)>{
      'GZIP': (GzipCodec(), GzipStreamCodec()),
      'LZ4': (Lz4Codec(), Lz4StreamCodec()),
      'Zstd': (ZstdCodec(), ZstdStreamCodec()),
      'Snappy': (SnappyCodec(framing: true), SnappyStreamCodec()),
    };

    for (final entry in cases.entries) {
      test('${entry.key} streaming decode round-trips (large)', () async {
        if (!exists) {
          markTestSkipped('fixture missing');
          return;
        }
        final (block, stream) = entry.value;
        final compressed = block.compress(data);

        var best = double.infinity;
        late Uint8List restored;
        final runs = _verbose ? 5 : 1;
        for (var i = 0; i < runs; i++) {
          final sw = Stopwatch()..start();
          restored = await _decodeStream(stream, compressed, 64 * 1024);
          sw.stop();
          final ms = sw.elapsedMicroseconds / 1000.0;
          if (ms < best) best = ms;
        }
        expect(restored, orderedEquals(data));

        if (_verbose) {
          final mbps = (data.length / 1e6) / (best / 1000.0);
          // ignore: avoid_print
          print(
            '${entry.key} streaming decode: '
            '${best.toStringAsFixed(1)}ms  ${mbps.toStringAsFixed(1)} MB/s',
          );
        }
      });
    }
  });
}
