import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  group('Snappy maxSize contract (nullable, 256MB default)', () {
    final data = Uint8List.fromList(List.generate(200000, (i) => (i * 31 + 7) % 256));

    test('default is 256 MB and null means unlimited', () {
      expect(SnappyCodec().maxSize, 256 * 1024 * 1024);
      expect(SnappyStreamCodec().maxSize, 256 * 1024 * 1024);
      expect(SnappyCodec(maxSize: null).maxSize, isNull);
    });

    test('block: a small limit rejects, null allows', () {
      final comp = SnappyCodec().compress(data);
      expect(() => SnappyCodec(maxSize: 1000).decompress(comp),
          throwsA(isA<CompressionFormatException>()));
      expect(SnappyCodec(maxSize: null).decompress(comp), orderedEquals(data));
    });

    test('framed: a small limit rejects, null allows', () {
      final comp = SnappyCodec(framing: true).compress(data);
      expect(() => SnappyCodec(framing: true, maxSize: 1000).decompress(comp),
          throwsA(isA<CompressionFormatException>()));
      expect(SnappyCodec(framing: true, maxSize: null).decompress(comp),
          orderedEquals(data));
    });

    test('maxSize: 0 is still rejected at construction', () {
      expect(() => SnappyCodec(maxSize: 0), throwsArgumentError);
      expect(() => SnappyStreamCodec(maxSize: -1), throwsArgumentError);
    });
  });
}
