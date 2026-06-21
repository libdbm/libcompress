import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  group('fromOptions preserves maxDecompressedSize', () {
    final data = Uint8List.fromList(List.generate(50000, (i) => (i * 31 + 7) % 256));

    test('GZIP', () {
      final codec = GzipCodec.fromOptions(GzipOptions(maxDecompressedSize: 1000));
      expect(codec.maxDecompressedSize, 1000);
      final comp = GzipCodec().compress(data); // default codec to make the blob
      expect(() => codec.decompress(comp), throwsA(isA<CompressionFormatException>()));
    });

    test('LZ4', () {
      final codec = Lz4Codec.fromOptions(Lz4Options(maxDecompressedSize: 1000));
      expect(codec.maxDecompressedSize, 1000);
      final comp = Lz4Codec().compress(data);
      expect(() => codec.decompress(comp), throwsA(isA<CompressionFormatException>()));
    });

    test('Zstd', () {
      final codec = ZstdCodec.fromOptions(ZstdOptions(maxDecompressedSize: 1000));
      expect(codec.maxDecompressedSize, 1000);
      final comp = ZstdCodec().compress(data);
      expect(() => codec.decompress(comp), throwsA(isA<CompressionFormatException>()));
    });

    test('default options keep the 256MB limit (behaviour unchanged)', () {
      expect(GzipCodec.fromOptions(GzipOptions()).maxDecompressedSize, 256 * 1024 * 1024);
      expect(Lz4Codec.fromOptions(Lz4Options()).maxDecompressedSize, 256 * 1024 * 1024);
      expect(ZstdCodec.fromOptions(ZstdOptions()).maxDecompressedSize, 256 * 1024 * 1024);
    });
  });
}
