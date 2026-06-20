import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'test_utils.dart';

/// Feeds [compressed] to the streaming Zstd decoder in [chunkSize]-byte chunks
/// and returns the concatenated output.
Future<Uint8List> decodeFragmented(
  final Uint8List compressed,
  final int chunkSize, {
  final ZstdStreamCodec? codec,
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
      in (codec ?? ZstdStreamCodec()).decompress(Stream.fromIterable(chunks))) {
    output.addAll(chunk);
  }
  return Uint8List.fromList(output);
}

Uint8List _bytes(final Iterable<int> v) => Uint8List.fromList(v.toList());

Future<Uint8List> _streamCompress(
  final ZstdStreamCodec codec,
  final Uint8List data,
) async {
  final out = <int>[];
  await for (final c in codec.compress(Stream.value(data))) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('Zstd streaming - fragmented input', () {
    // Small blocks force multiple blocks per frame.
    final multiBlock = ZstdStreamCodec(blockSize: 16384);
    final withChecksum = ZstdStreamCodec(blockSize: 16384, checksum: true);

    test('round-trips multi-block compressible data one byte at a time', () async {
      const pattern = 'the quick brown fox jumps over the lazy dog. ';
      final original = _bytes(
        List.generate(120 * 1024, (i) => pattern.codeUnitAt(i % pattern.length)),
      );
      final compressed = await _streamCompress(multiBlock, original);
      final restored = await decodeFragmented(compressed, 1, codec: multiBlock);
      expect(restored, orderedEquals(original));
    });

    test('round-trips with content checksum fragmented', () async {
      final original = _bytes(List.generate(80 * 1024, (i) => (i * 31 + 7) % 251));
      final compressed = await _streamCompress(withChecksum, original);
      final restored = await decodeFragmented(compressed, 1, codec: withChecksum);
      expect(restored, orderedEquals(original));
    });

    test('round-trips small data fragmented', () async {
      final original = _bytes('Hello, Zstd streaming!'.codeUnits);
      final compressed = await _streamCompress(ZstdStreamCodec(), original);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(original));
    });

    test('round-trips concatenated frames fragmented', () async {
      final a = _bytes(List.generate(6000, (i) => i % 7));
      final b = _bytes(List.generate(9000, (i) => (i * 3) % 11));
      final codec = ZstdStreamCodec();
      final compressed = _bytes([
        ...await _streamCompress(codec, a),
        ...await _streamCompress(codec, b),
      ]);
      final restored = await decodeFragmented(compressed, 1);
      expect(restored, orderedEquals(_bytes([...a, ...b])));
    });

    test('decodes native-CLI .zst fixtures fragmented', () async {
      for (final path in standardFixtures) {
        final compressed = readCodecFixture('zstd', '$path.zst');
        final expected = readDataFixture(path);
        final restored = await decodeFragmented(compressed, 1);
        expect(restored, orderedEquals(expected), reason: path);
      }
    });

    test('whole-input and 1-byte-chunk decoding agree', () async {
      const pattern = 'abcabcabcdefdefdef0123456789';
      final original = _bytes(
        List.generate(100 * 1024, (i) => pattern.codeUnitAt(i % pattern.length)),
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
      final truncated = Uint8List.sublistView(compressed, 0, compressed.length - 5);
      expect(
        () => decodeFragmented(truncated, 1, codec: multiBlock),
        throwsA(isA<ZstdFormatException>()),
      );
    });
  });
}
