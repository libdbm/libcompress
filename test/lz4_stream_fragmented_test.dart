import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Feeds [compressed] to the streaming LZ4 decoder in [chunkSize]-byte chunks
/// and returns the concatenated output. Small chunk sizes exercise the
/// incremental, per-block decode path.
Future<Uint8List> decodeFragmented(
  final Uint8List compressed,
  final int chunkSize, {
  final Lz4StreamCodec? codec,
}) async {
  final chunks = <Uint8List>[];
  for (var i = 0; i < compressed.length; i += chunkSize) {
    final end = (i + chunkSize) < compressed.length
        ? i + chunkSize
        : compressed.length;
    chunks.add(Uint8List.sublistView(compressed, i, end));
  }
  final output = <int>[];
  await for (final chunk
      in (codec ?? Lz4StreamCodec()).decompress(Stream.fromIterable(chunks))) {
    output.addAll(chunk);
  }
  return Uint8List.fromList(output);
}

Uint8List _bytes(final Iterable<int> v) => Uint8List.fromList(v.toList());

Future<Uint8List> _streamCompress(
  final Lz4StreamCodec codec,
  final Uint8List data,
) async {
  final out = <int>[];
  await for (final c in codec.compress(Stream.value(data))) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('LZ4 streaming - fragmented input', () {
    // 64 KB blocks force multiple blocks within a frame for inputs > 64 KB.
    final multiBlock = Lz4StreamCodec(blockSize: 65536);

    test('round-trips multi-block compressible data one byte at a time', () async {
      const pattern = 'the quick brown fox jumps over the lazy dog. ';
      final original = _bytes(
        List.generate(200 * 1024, (i) => pattern.codeUnitAt(i % pattern.length)),
      );
      final compressed = await _streamCompress(multiBlock, original);
      final restored = await decodeFragmented(compressed, 1, codec: multiBlock);
      expect(restored, orderedEquals(original));
    });

    test('round-trips incompressible (uncompressed-block) data fragmented', () async {
      var seed = 0x2468;
      final original = _bytes(List.generate(150 * 1024, (_) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed & 0xff;
      }));
      final compressed = await _streamCompress(multiBlock, original);
      final restored = await decodeFragmented(compressed, 1, codec: multiBlock);
      expect(restored, orderedEquals(original));
    });

    test('round-trips small data fragmented', () async {
      final original = _bytes('Hello, LZ4 streaming!'.codeUnits);
      final compressed = await _streamCompress(Lz4StreamCodec(), original);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(original));
    });

    test('round-trips concatenated frames fragmented', () async {
      final a = _bytes(List.generate(5000, (i) => i % 7));
      final b = _bytes(List.generate(7000, (i) => (i * 3) % 11));
      final codec = Lz4StreamCodec();
      final compressed = _bytes([
        ...await _streamCompress(codec, a),
        ...await _streamCompress(codec, b),
      ]);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(_bytes([...a, ...b])));
    });

    test('whole-input and 1-byte-chunk decoding agree', () async {
      const pattern = 'abcabcabcdefdefdef0123456789';
      final original = _bytes(
        List.generate(180 * 1024, (i) => pattern.codeUnitAt(i % pattern.length)),
      );
      final compressed = await _streamCompress(multiBlock, original);
      final whole = await decodeFragmented(compressed, compressed.length, codec: multiBlock);
      final fragmented = await decodeFragmented(compressed, 1, codec: multiBlock);
      expect(fragmented, orderedEquals(whole));
      expect(whole, orderedEquals(original));
    });

    test('truncated frame fed fragmented errors at end of stream', () async {
      final original = _bytes(List.generate(40000, (i) => i % 256));
      final compressed = await _streamCompress(multiBlock, original);
      final truncated = Uint8List.sublistView(compressed, 0, compressed.length - 6);
      expect(
        () => decodeFragmented(truncated, 1, codec: multiBlock),
        throwsA(isA<Lz4FormatException>()),
      );
    });
  });
}
