// Run with: dart run benchmark/codec_benchmark.dart [filter]
//
// Reports median throughput in MB/s of uncompressed bytes (larger is better)
// for every codec and format over the standard fixtures and Parquet-sized page
// slices: compress, decompress, and decompress with the expected `size` (as a
// Parquet reader would call it). An optional [filter] keeps only codecs whose label contains it, for
// example `dart run benchmark/codec_benchmark.dart lz4`.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

/// Minimum wall time per sample; operations repeat until it is reached.
const _budget = Duration(milliseconds: 200);

/// Samples per measurement; the median is reported.
const _samples = 5;

int _observed = 0;

/// A codec under test, with the label it is reported under.
final class Subject {
  const Subject(this.label, this.codec);

  final String label;
  final CompressionCodec codec;
}

List<Subject> _subjects() {
  final lz4 = Lz4Codec();
  final raw = Lz4Codec(format: Lz4Format.raw);
  final hc = Lz4Codec(level: 9);
  final snappy = SnappyCodec();
  final framed = SnappyCodec(format: SnappyFormat.framed);
  final fast = GzipCodec(level: 1);
  final gzip = GzipCodec(level: 6);
  final zstd = ZstdCodec();
  return [
    Subject('lz4 frame L1', lz4),
    Subject('lz4 frame L9', hc),
    Subject('lz4 raw L1', raw),
    Subject('snappy raw', snappy),
    Subject('snappy framed', framed),
    Subject('gzip L1', fast),
    Subject('gzip L6', gzip),
    Subject('zstd L3', zstd),
  ];
}

Map<String, Uint8List> _inputs() {
  final root = File.fromUri(
    Platform.script,
  ).parent.parent.uri.resolve('test/fixtures/data/');
  Uint8List read(final String path) =>
      File.fromUri(root.resolve(path)).readAsBytesSync();

  final world = read('large/world192.txt');
  final random = Random(123);
  return {
    'world192.txt': world,
    'bible.txt': read('large/bible.txt'),
    'house.jpg': read('house.jpg'),
    'geo.protodata': read('geo.protodata'),
    'random 1M': Uint8List.fromList(
      List.generate(1 << 20, (_) => random.nextInt(256)),
    ),
    'zeros 1M': Uint8List(1 << 20),
    'period7 1M': Uint8List.fromList(
      List.generate(1 << 20, (final i) => i % 7),
    ),
    'page 1K': Uint8List.sublistView(world, 0, 1 << 10),
    'page 8K': Uint8List.sublistView(world, 0, 8 << 10),
    'page 64K': Uint8List.sublistView(world, 0, 64 << 10),
  };
}

/// Median MB/s of [operation] over [size] uncompressed bytes per call.
double _measure(final Uint8List Function() operation, final int size) {
  final rates = <double>[];
  for (var sample = 0; sample < _samples; sample++) {
    final watch = Stopwatch()..start();
    var count = 0;
    while (watch.elapsed < _budget) {
      _observed += operation().length;
      count++;
    }
    watch.stop();
    rates.add(size * count / watch.elapsedMicroseconds);
  }
  rates.sort();
  return rates[rates.length ~/ 2];
}

void _verify(
  final String label,
  final Uint8List data,
  final Uint8List decoded,
) {
  if (decoded.length != data.length) {
    throw StateError('$label: round-trip length mismatch');
  }
  for (var i = 0; i < data.length; i++) {
    if (decoded[i] != data[i]) {
      throw StateError('$label: round-trip mismatch at $i');
    }
  }
}

String _cell(final Object value, final int width) =>
    value.toString().padLeft(width);

void main(final List<String> arguments) {
  final filter = arguments.isEmpty ? '' : arguments.first;
  final subjects = _subjects()
      .where((final subject) => subject.label.contains(filter))
      .toList();
  final inputs = _inputs();

  print(
    '| input | codec | ratio | compress MB/s | decompress MB/s '
    '| decompress size: MB/s |\n'
    '|---|---|---:|---:|---:|---:|',
  );
  for (final input in inputs.entries) {
    final data = input.value;
    for (final subject in subjects) {
      final label = '${input.key} / ${subject.label}';
      final codec = subject.codec;
      final packed = codec.compress(data);
      _verify(label, data, codec.decompress(packed));
      _verify(label, data, codec.decompress(packed, size: data.length));

      final compress = _measure(() => codec.compress(data), data.length);
      final decompress = _measure(() => codec.decompress(packed), data.length);
      final sized = _measure(
        () => codec.decompress(packed, size: data.length),
        data.length,
      );
      final ratio = data.length / packed.length;
      print(
        '| ${input.key} | ${subject.label} '
        '| ${_cell(ratio.toStringAsFixed(2), 6)} '
        '| ${_cell(compress.toStringAsFixed(1), 8)} '
        '| ${_cell(decompress.toStringAsFixed(1), 8)} '
        '| ${_cell(sized.toStringAsFixed(1), 8)} |',
      );
    }
  }
  stderr.writeln('Observed bytes: $_observed');
}
