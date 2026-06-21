import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  group('Constructor validation (fail-fast at the API boundary)', () {
    test('block codecs reject out-of-range params', () {
      expect(() => GzipCodec(level: 0), throwsArgumentError);
      expect(() => GzipCodec(level: 10), throwsArgumentError);
      expect(() => GzipCodec(maxDecompressedSize: 0), throwsArgumentError);

      expect(() => Lz4Codec(level: 0), throwsArgumentError);
      expect(() => Lz4Codec(level: 10), throwsArgumentError);
      expect(() => Lz4Codec(blockSize: 0), throwsArgumentError);
      expect(() => Lz4Codec(blockSize: 8 * 1024 * 1024), throwsArgumentError);
      expect(() => Lz4Codec(maxDecompressedSize: -1), throwsArgumentError);

      expect(() => ZstdCodec(level: 0), throwsArgumentError);
      expect(() => ZstdCodec(level: 23), throwsArgumentError);
      expect(() => ZstdCodec(blockSize: 0), throwsArgumentError);
      expect(() => ZstdCodec(blockSize: 256 * 1024), throwsArgumentError);
      expect(() => ZstdCodec(maxDecompressedSize: 0), throwsArgumentError);

      expect(() => SnappyCodec(maxSize: 0), throwsArgumentError);
      expect(() => SnappyCodec(chunkSize: 0), throwsArgumentError);
      expect(() => SnappyCodec(chunkSize: 70000), throwsArgumentError);
    });

    test('stream codecs reject out-of-range params', () {
      expect(() => GzipStreamCodec(level: 0), throwsArgumentError);
      expect(() => GzipStreamCodec(maxBufferSize: 0), throwsArgumentError);
      expect(() => GzipStreamCodec(maxSize: 0), throwsArgumentError);

      expect(() => Lz4StreamCodec(level: 10), throwsArgumentError);
      expect(() => Lz4StreamCodec(blockSize: 8 * 1024 * 1024), throwsArgumentError);
      expect(() => Lz4StreamCodec(maxBufferSize: 0), throwsArgumentError);

      expect(() => ZstdStreamCodec(level: 23), throwsArgumentError);
      expect(() => ZstdStreamCodec(blockSize: 256 * 1024), throwsArgumentError);
      expect(() => ZstdStreamCodec(maxBufferSize: 0), throwsArgumentError);

      expect(() => SnappyStreamCodec(maxSize: 0), throwsArgumentError);
      expect(() => SnappyStreamCodec(maxBufferSize: 0), throwsArgumentError);
    });

    test('valid construction still works (incl. null = unlimited)', () {
      expect(GzipCodec(level: 9, maxDecompressedSize: null), isNotNull);
      expect(Lz4Codec(level: 9, blockSize: 64 * 1024, maxDecompressedSize: null), isNotNull);
      expect(ZstdCodec(level: 22, blockSize: 64 * 1024), isNotNull);
      expect(ZstdStreamCodec(level: 1, blockSize: 16 * 1024), isNotNull);
      expect(SnappyStreamCodec(), isNotNull);
    });
  });
}
