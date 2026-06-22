import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/zstd/compressed_block_encoder.dart';
import 'package:libcompress/src/zstd/zstd_encoder.dart';
import 'package:libcompress/src/zstd/streaming_zstd_encoder.dart';

void main() {
  group('Zstd compressed-block fallback observability (#1)', () {
    // Real, compressible text. If the corpus is absent, a repetitive synthetic
    // buffer still compresses well via FSE/Huffman.
    final path = 'test/fixtures/data/canterbury/alice29.txt';
    final data = File(path).existsSync()
        ? File(path).readAsBytesSync()
        : Uint8List.fromList(
            List.generate(200000, (i) => 'the quick brown fox '.codeUnitAt(i % 20)));

    test('healthy block compression: zero fallbacks and actually compresses', () {
      final encoder = ZstdEncoder(level: 3);
      final out = encoder.compress(data);
      expect(encoder.fallbacks, 0,
          reason: 'a silent FSE/Huffman regression would raise this');
      expect(out.length, lessThan(data.length));
    });

    test('healthy streaming compression: zero fallbacks and compresses', () {
      final encoder = StreamingZstdEncoder(level: 3);
      final body = encoder.addChunk(data);
      encoder.finish();
      expect(encoder.fallbacks, 0);
      expect(body.length, lessThan(data.length));
    });

    // White-box trigger: from: -1 forces an out-of-bounds read inside
    // encodeBlock's try, exercising the unexpected-error fallback path.
    Uint8List bad() => Uint8List(100);

    test('unexpected encode error is counted and invokes onFallback (non-strict)', () {
      Object? seen;
      final encoder = CompressedBlockEncoder(onFallback: (e, st) => seen = e);
      final result = encoder.encodeBlock(bad(), from: -1);
      expect(result, isEmpty, reason: 'fell back to a raw block');
      expect(encoder.fallbacks, 1);
      expect(seen, isNotNull, reason: 'onFallback must fire so it is not silent');
    });

    test('strict mode rethrows instead of silently falling back', () {
      final encoder = CompressedBlockEncoder(strict: true);
      expect(() => encoder.encodeBlock(bad(), from: -1), throwsA(anything));
      expect(encoder.fallbacks, 1);
    });

    test('defaults are non-strict, no hook, zero count', () {
      final encoder = CompressedBlockEncoder();
      expect(encoder.strict, isFalse);
      expect(encoder.onFallback, isNull);
      expect(encoder.fallbacks, 0);
    });
  });
}
