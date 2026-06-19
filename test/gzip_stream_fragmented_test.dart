import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Feeds [compressed] to the streaming GZIP decoder in [chunkSize]-byte chunks
/// and returns the concatenated output. Small chunk sizes exercise the
/// resumable, zero-copy DEFLATE boundary scan across many arrivals.
Future<Uint8List> decodeFragmented(
  final Uint8List compressed,
  final int chunkSize,
) async {
  final chunks = <Uint8List>[];
  for (var i = 0; i < compressed.length; i += chunkSize) {
    final end = (i + chunkSize) < compressed.length
        ? i + chunkSize
        : compressed.length;
    chunks.add(Uint8List.sublistView(compressed, i, end));
  }
  final output = <int>[];
  await for (final chunk
      in GzipStreamCodec().decompress(Stream.fromIterable(chunks))) {
    output.addAll(chunk);
  }
  return Uint8List.fromList(output);
}

Uint8List _bytes(final Iterable<int> values) => Uint8List.fromList(values.toList());

void main() {
  group('GZIP streaming - fragmented input', () {
    test('round-trips compressible text fed one byte at a time', () async {
      const pattern = 'the quick brown fox jumps over the lazy dog. ';
      final original = _bytes(
        List.generate(8 * 1024, (i) => pattern.codeUnitAt(i % pattern.length)),
      );
      final compressed = GzipCodec().compress(original);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(original));
    });

    test('round-trips incompressible (stored-block) data fragmented', () async {
      // Pseudo-random, incompressible -> DEFLATE stored blocks.
      var seed = 0x1234;
      final original = _bytes(List.generate(4 * 1024, (_) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed & 0xff;
      }));
      final compressed = GzipCodec().compress(original);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(original));
    });

    test('round-trips small data fragmented', () async {
      final original = _bytes('Hello, GZIP streaming!'.codeUnits);
      final compressed = GzipCodec().compress(original);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(original));
    });

    test('round-trips concatenated members fragmented', () async {
      final a = _bytes(List.generate(2000, (i) => i % 7));
      final b = _bytes(List.generate(3000, (i) => (i * 3) % 11));
      final compressed = _bytes([
        ...GzipCodec().compress(a),
        ...GzipCodec().compress(b),
      ]);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(_bytes([...a, ...b])));
    });

    test('whole-input and 1-byte-chunk decoding agree', () async {
      const pattern = 'abcabcabcdefdefdef0123456789';
      final original = _bytes(
        List.generate(6 * 1024, (i) => pattern.codeUnitAt(i % pattern.length)),
      );
      final compressed = GzipCodec().compress(original);
      final whole = await decodeFragmented(compressed, compressed.length);
      final fragmented = await decodeFragmented(compressed, 1);
      expect(fragmented, orderedEquals(whole));
    });

    test('truncated member fed fragmented errors at end of stream', () async {
      final original = _bytes(List.generate(4096, (i) => i % 256));
      final compressed = GzipCodec().compress(original);
      final truncated = Uint8List.sublistView(
        compressed,
        0,
        compressed.length - 4,
      );
      expect(
        () => decodeFragmented(truncated, 1),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });
}
