import 'dart:io';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/gzip/deflate_common.dart'
    show distanceBase, distanceCode, lengthBase, lengthExtraBits, maxDistance;
import 'package:libcompress/src/gzip/deflate_reader.dart';
import 'package:libcompress/src/gzip/huffman_tables.dart';
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

    test('token buffer reuse across blocks', () {
      // A block of noise fills the token buffer (one literal per byte); the
      // zeros after it need only a few tokens, so a writer that read past the
      // token count would emit stale literals.
      final data = bytes([
        ...pseudoRandom(70000),
        ...Uint8List(70000),
        ...text,
      ]);
      for (final level in [1, 6]) {
        expect(
          raw.decode(DeflateCodec(level: level).compress(data)),
          equals(data),
          reason: 'level $level',
        );
      }
    });

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

    test('decode entries hold codes longer than the root table', () {
      // Symbol i has a code of i + 1 bits (a complete code up to 15 bits), so
      // codes from 8 bits (code lengths) or 11 bits (literals) need subtables.
      final lengths = [for (var i = 0; i < 15; i++) i + 1, 15];
      for (final alphabet in [Alphabet.plain, Alphabet.literals]) {
        final decoder = buildDecoder(lengths, alphabet: alphabet);
        final (bytes, codes) = canonical(lengths);
        final reader = DeflateReader(bytes);
        for (var symbol = 0; symbol < lengths.length; symbol++) {
          final entry = reader.decode(decoder);
          expect(entryValue(entry), symbol, reason: '$alphabet $symbol');
          expect(entry & entryLength, lengths[symbol]);
          expect(
            entry & entryLiteral != 0,
            alphabet == Alphabet.literals,
            reason: '$alphabet $symbol',
          );
        }
        expect(codes, lengths.length);
      }
    });

    test('decode entries carry length and distance bases', () {
      final literals = buildDecoder(
        List.filled(288, 9), // incomplete: 288 codes of 9 bits
        alphabet: Alphabet.literals,
        allowIncomplete: true,
      );
      final (bytes, _) = canonical(List.filled(288, 9));
      final reader = DeflateReader(bytes);
      for (var symbol = 0; symbol < 288; symbol++) {
        final entry = reader.decode(literals);
        final exception = entry & entryException != 0;
        if (symbol < 256) {
          expect(entry & entryLiteral, entryLiteral);
          expect(entryValue(entry), symbol);
        } else if (symbol == 256) {
          expect(entry & entryEnd, entryEnd, reason: 'end of block');
        } else if (symbol <= 285) {
          expect(exception, isFalse);
          expect(entryValue(entry), lengthBase[symbol - 257]);
          expect(entryExtra(entry), lengthExtraBits[symbol - 257]);
        } else {
          expect(exception, isTrue, reason: 'symbol $symbol');
          expect(entryValue(entry), symbol);
        }
      }
    });

    test('a single 1-bit distance code decodes, its unused code does not', () {
      final distances = buildDecoder([1], alphabet: Alphabet.distances);
      final entry = DeflateReader(Uint8List.fromList([0])).decode(distances);
      expect(entryValue(entry), 1);
      expect(entryExtra(entry), 0);
      expect(
        () => DeflateReader(Uint8List.fromList([1])).decode(distances),
        throwsA(isA<DeflateFormatException>()),
      );
    });

    test('distance codes match the RFC 1951 table for every distance', () {
      // The code is the last one whose base is at most the distance.
      var code = 0;
      for (var distance = 1; distance <= maxDistance; distance++) {
        while (code < 29 && distanceBase[code + 1] <= distance) {
          code++;
        }
        expect(distanceCode(distance), code, reason: 'distance $distance');
      }
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

/// Every symbol of the canonical code for [lengths] (RFC 1951 section
/// 3.2.2), in symbol order, written LSB-first as DEFLATE stores codes, and
/// the number of codes written.
(Uint8List, int) canonical(final List<int> lengths) {
  final counts = List.filled(16, 0);
  for (final length in lengths) {
    counts[length]++;
  }
  counts[0] = 0;
  final starts = List.filled(16, 0);
  var code = 0;
  for (var length = 1; length <= 15; length++) {
    code = (code + counts[length - 1]) << 1;
    starts[length] = code;
  }
  final out = <int>[];
  var hold = 0;
  var count = 0;
  var written = 0;
  for (final length in lengths) {
    if (length == 0) continue;
    final value = starts[length]++;
    for (var bit = length - 1; bit >= 0; bit--) {
      hold |= ((value >> bit) & 1) << count;
      if (++count == 8) {
        out.add(hold);
        hold = 0;
        count = 0;
      }
    }
    written++;
  }
  out
    ..add(hold)
    ..addAll([0, 0, 0]);
  return (Uint8List.fromList(out), written);
}
