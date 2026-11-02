import 'dart:io';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  final text = Uint8List.fromList(
    List.filled(
      200,
      'A quick brown fox jumps over the lazy dog. ',
    ).join().codeUnits,
  );
  final noise = pseudoRandom(100000);
  final raw = ZLibCodec(raw: true);

  group('DEFLATE block', () {
    for (final level in [1, 6, 9]) {
      test('round-trips text and noise at level $level', () {
        final codec = DeflateCodec(level: level);
        for (final data in [text, noise]) {
          expect(codec.decompress(codec.compress(data)), equals(data));
        }
      });

      test('zlib reads what level $level writes', () {
        final codec = DeflateCodec(level: level);
        for (final data in [text, noise]) {
          expect(raw.decode(codec.compress(data)), equals(data));
        }
      });
    }

    test('reads what zlib writes', () {
      for (final data in [text, noise]) {
        expect(
          DeflateCodec().decompress(Uint8List.fromList(raw.encode(data))),
          equals(data),
        );
      }
    });

    test('writes no GZIP header or trailer', () {
      final compressed = DeflateCodec().compress(text);
      expect(compressed.take(2), isNot(equals([0x1F, 0x8B])));
      expect(compressed.length, GzipCodec().compress(text).length - 18);
    });

    test('decodes to the expected size', () {
      final compressed = DeflateCodec().compress(text);
      expect(
        DeflateCodec().decompress(compressed, size: text.length),
        equals(text),
      );
    });

    test('reports its name', () {
      expect(DeflateCodec().name, 'DEFLATE');
    });

    test('takes its level and limit from options', () {
      final codec = DeflateCodec.fromOptions(
        DeflateOptions(level: 9, maxSize: 1024),
      );
      expect(codec.level, 9);
      expect(codec.maxSize, 1024);
    });
  });

  group('DEFLATE limits & validation', () {
    test('rejects output past maxSize', () {
      final compressed = DeflateCodec().compress(text);
      expect(
        () => DeflateCodec(maxSize: 100).decompress(compressed),
        throwsA(isA<LimitException>()),
      );
    });

    test('rejects output longer than the expected size', () {
      final compressed = DeflateCodec().compress(text);
      expect(
        () => DeflateCodec().decompress(compressed, size: text.length - 1),
        throwsA(isA<LimitException>()),
      );
    });

    test('rejects output shorter than the expected size', () {
      final compressed = DeflateCodec().compress(text);
      expect(
        () => DeflateCodec().decompress(compressed, size: text.length + 1),
        throwsA(isA<DeflateFormatException>()),
      );
    });

    test('rejects bytes after the final block', () {
      final compressed = DeflateCodec().compress(text);
      expect(
        () => DeflateCodec().decompress(bytes([...compressed, 0])),
        throwsA(isA<DeflateFormatException>()),
      );
    });

    test('rejects empty input', () {
      expect(
        () => DeflateCodec().decompress(Uint8List(0)),
        throwsA(isA<DeflateFormatException>()),
      );
    });

    test('rejects truncated input', () {
      final compressed = DeflateCodec().compress(noise);
      expect(
        () => DeflateCodec().decompress(
          Uint8List.sublistView(compressed, 0, compressed.length ~/ 2),
        ),
        throwsA(isA<DeflateFormatException>()),
      );
    });

    test('rejects an invalid block type', () {
      // BFINAL 1, BTYPE 11, which RFC 1951 reserves.
      expect(
        () => DeflateCodec().decompress(bytes([0x07])),
        throwsA(isA<DeflateFormatException>()),
      );
    });

    test('rejects a level outside 1 to 9', () {
      expect(() => DeflateCodec(level: 0), throwsArgumentError);
      expect(() => DeflateCodec(level: 10), throwsArgumentError);
      expect(() => DeflateOptions(level: 10), throwsArgumentError);
    });

    test('rejects a maxSize that is not positive', () {
      expect(() => DeflateCodec(maxSize: 0), throwsArgumentError);
    });
  });
}
