import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

void main() async {
  final data = Uint8List.fromList(
    'Hello, World! This is a test of compression algorithms.'.codeUnits,
  );

  // Block-based compression using CodecFactory
  print('=== Block-based Compression ===');

  for (final type in [
    CodecType.lz4,
    CodecType.snappy,
    CodecType.gzip,
    CodecType.zstd,
  ]) {
    final codec = CodecFactory.codec(type);
    final compressed = codec.compress(data);
    final decompressed = codec.decompress(compressed);

    print(
      '${type.name}: ${data.length} -> ${compressed.length} bytes '
      '(${(compressed.length / data.length * 100).toStringAsFixed(1)}%)',
    );
    assert(
      decompressed.length == data.length,
      'Round-trip failed for ${type.name}',
    );
  }

  // Direct codec instantiation with options
  print('\n=== Codec with Options ===');

  final zstd = ZstdCodec(level: 9, checksum: true);
  final zstdCompressed = zstd.compress(data);
  print('Zstd level 9: ${zstdCompressed.length} bytes');

  final lz4 = Lz4Codec(level: 9, blockSize: lz4BlockSize64K);
  final lz4Compressed = lz4.compress(data);
  print('LZ4 HC level 9: ${lz4Compressed.length} bytes');

  // Parquet LZ4_RAW page with a known uncompressed size
  final page = Lz4Codec(format: Lz4Format.raw);
  final restored = page.decompress(page.compress(data), size: data.length);
  print('LZ4 raw page: ${restored.length} bytes restored');

  // Stream-based compression
  print('\n=== Stream-based Compression ===');

  final stream = CodecFactory.streaming(CodecType.lz4);
  final input = Stream.value(data);
  final chunks = <Uint8List>[];

  await for (final chunk in stream.compress(input)) {
    chunks.add(chunk);
  }

  final total = chunks.fold<int>(
    0,
    (final sum, final chunk) => sum + chunk.length,
  );
  print('LZ4 stream: $total bytes in ${chunks.length} chunk(s)');
}
