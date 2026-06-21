import 'dart:io';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Compression-ratio regression gate.
///
/// Compression ratio is a deterministic function of the algorithm and the
/// input, so these floors are machine-independent and non-flaky (unlike
/// throughput, which the gated benchmark files report separately). Floors are
/// set a few points below the measured savings, so a genuine algorithmic
/// regression trips the gate while routine, byte-shifting tweaks do not.
void main() {
  group('Compression-ratio budgets', () {
    // Minimum % size reduction per corpus file per codec.
    final budgets = <String, Map<String, double>>{
      'canterbury/alice29.txt': {'gzip': 58, 'lz4': 39, 'zstd': 54, 'snappy': 38},
      'calgary/paper1': {'gzip': 61, 'lz4': 43, 'zstd': 56, 'snappy': 43},
      'large/bible.txt': {'gzip': 65, 'lz4': 46, 'zstd': 63, 'snappy': 47},
    };

    CompressionCodec codecFor(final String name) => switch (name) {
          'gzip' => GzipCodec(),
          'lz4' => Lz4Codec(),
          'zstd' => ZstdCodec(),
          'snappy' => SnappyCodec(framing: true),
          _ => throw ArgumentError('unknown codec $name'),
        };

    budgets.forEach((file, perCodec) {
      perCodec.forEach((name, floor) {
        test('$name keeps >= $floor% savings on $file', () {
          final path = 'test/fixtures/data/$file';
          if (!File(path).existsSync()) {
            markTestSkipped('fixture missing: $path');
            return;
          }
          final data = File(path).readAsBytesSync();
          final compressed = codecFor(name).compress(data);
          final savings = (data.length - compressed.length) * 100.0 / data.length;
          expect(
            savings,
            greaterThanOrEqualTo(floor),
            reason: '$name on $file: ${savings.toStringAsFixed(1)}% savings '
                'fell below the $floor% floor — compression-ratio regression',
          );
        });
      });
    });
  });
}
