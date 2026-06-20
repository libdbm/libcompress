import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/xxh32.dart';

void main() {
  group('Xxh32Sink', () {
    test('matches one-shot XXH32.hash for many lengths and chunkings', () {
      final random = Random(11);
      for (final length in [0, 1, 4, 15, 16, 17, 31, 32, 33, 100, 1000, 4096, 5000]) {
        final data = Uint8List.fromList(
          List.generate(length, (_) => random.nextInt(256)),
        );
        final expected = XXH32.hash(data);

        // Feed in a variety of chunk sizes.
        for (final chunk in [1, 3, 7, 16, 64, length == 0 ? 1 : length]) {
          final sink = Xxh32Sink();
          for (var i = 0; i < length; i += chunk) {
            sink.add(data, i, min(chunk, length - i));
          }
          expect(
            sink.digest(),
            equals(expected),
            reason: 'length=$length chunk=$chunk',
          );
        }
      }
    });

    test('respects a non-zero seed', () {
      final data = Uint8List.fromList(List.generate(50, (i) => i));
      final sink = Xxh32Sink(0xCAFE);
      sink.add(data, 0, 20);
      sink.add(data, 20);
      expect(sink.digest(), equals(XXH32.hash(data, 0xCAFE)));
    });
  });
}
