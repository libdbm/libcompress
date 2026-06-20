import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/xxh64.dart';

void main() {
  group('Xxh64Sink', () {
    test('matches one-shot XXH64 for many lengths and chunkings', () {
      final random = Random(13);
      for (final length in [0, 1, 8, 31, 32, 33, 63, 64, 65, 100, 1000, 8192, 9001]) {
        final data = Uint8List.fromList(
          List.generate(length, (_) => random.nextInt(256)),
        );
        final expectedFull = XXH64.hash(data);
        final expectedLow = XXH64.hashLow32(data);

        for (final chunk in [1, 5, 8, 32, 100, length == 0 ? 1 : length]) {
          final sink = Xxh64Sink();
          for (var i = 0; i < length; i += chunk) {
            sink.add(data, i, min(chunk, length - i));
          }
          expect(sink.digest(), equals(expectedFull),
              reason: 'full length=$length chunk=$chunk');
          expect(sink.digestLow32(), equals(expectedLow),
              reason: 'low32 length=$length chunk=$chunk');
        }
      }
    });

    test('respects a non-zero seed', () {
      final data = Uint8List.fromList(List.generate(80, (i) => i));
      final sink = Xxh64Sink(0xBEEF);
      sink.add(data, 0, 33);
      sink.add(data, 33);
      expect(sink.digest(), equals(XXH64.hash(data, 0xBEEF)));
    });
  });
}
