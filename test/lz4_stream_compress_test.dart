import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

Uint8List _bytes(final Iterable<int> v) => Uint8List.fromList(v.toList());

Future<Uint8List> _streamCompress(final List<Uint8List> chunks) async {
  final out = <int>[];
  await for (final c
      in Lz4StreamCodec(blockSize: 65536).compress(Stream.fromIterable(chunks))) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

Future<Uint8List> _streamDecompress(final Uint8List compressed) async {
  final chunks = [
    for (var i = 0; i < compressed.length; i++)
      Uint8List.sublistView(compressed, i, i + 1),
  ];
  final out = <int>[];
  await for (final c in Lz4StreamCodec().decompress(Stream.fromIterable(chunks))) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('LZ4 streaming compression (block-linked, cross-chunk history)', () {
    test('round-trips multi-chunk input', () async {
      final chunks = [
        _bytes(List.generate(5000, (i) => i % 256)),
        _bytes('the quick brown fox '.codeUnits),
        _bytes(List.generate(9000, (i) => (i * 7) % 13)),
      ];
      final original = _bytes(chunks.expand((c) => c));
      final compressed = await _streamCompress(chunks);
      expect(Lz4Codec().decompress(compressed), orderedEquals(original));
      expect(await _streamDecompress(compressed), orderedEquals(original));
    });

    test('cross-chunk history compresses repeated chunks well', () async {
      final block = _bytes(List.generate(8192, (i) => (i * 31 + 7) % 256));
      final chunks = List.generate(8, (_) => block);
      final compressed = await _streamCompress(chunks);
      final single = await _streamCompress([block]);
      // Without cross-chunk history this would be ~8x a single block; with it,
      // chunks 2..8 are mostly long back-references into the window.
      expect(compressed.length, lessThan(single.length * 4),
          reason: '8 identical chunks should be far less than 8x one chunk');
      expect(await _streamDecompress(compressed),
          orderedEquals(_bytes(chunks.expand((c) => c))));
    });

    test('round-trips empty stream', () async {
      final compressed = await _streamCompress([]);
      expect(Lz4Codec().decompress(compressed), isEmpty);
      expect(await _streamDecompress(compressed), isEmpty);
    });

    test('output frame uses linked blocks (independent-blocks flag cleared)', () async {
      final compressed = await _streamCompress([
        _bytes(List.generate(20000, (i) => (i * 3) % 97)),
      ]);
      // FLG byte is at offset 4; bit 0x20 = independent blocks, must be clear.
      expect(compressed[4] & 0x20, equals(0));
    });
  });
}
