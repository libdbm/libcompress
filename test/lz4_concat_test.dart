import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  group('LZ4 block decode accepts concatenated frames (#3)', () {
    final a = Uint8List.fromList(List.generate(3000, (i) => (i * 7) % 251));
    final b = Uint8List.fromList(List.generate(2000, (i) => (i * 13 + 5) % 251));

    test('single frame still round-trips', () {
      expect(Lz4Codec().decompress(Lz4Codec().compress(a)), orderedEquals(a));
    });

    test('two concatenated frames decode to the concatenation', () {
      final cat = Uint8List.fromList(
          [...Lz4Codec().compress(a), ...Lz4Codec().compress(b)]);
      expect(Lz4Codec().decompress(cat), orderedEquals([...a, ...b]));
    });

    test('maxDecompressedSize is enforced cumulatively across frames', () {
      final cat = Uint8List.fromList(
          [...Lz4Codec().compress(a), ...Lz4Codec().compress(b)]); // 5000 bytes
      // Each frame is < 4000, but the total is 5000 — must still be rejected.
      expect(() => Lz4Codec(maxDecompressedSize: 4000).decompress(cat),
          throwsA(isA<CompressionFormatException>()));
    });
  });
}
