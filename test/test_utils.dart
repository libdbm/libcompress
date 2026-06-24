import 'dart:io';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:test/test.dart';

/// Wraps any byte iterable as a [Uint8List] (shared shorthand for tests).
Uint8List bytes(final Iterable<int> values) =>
    Uint8List.fromList(values.toList());

/// Deterministic pseudo-random bytes (LCG) — incompressible-ish, reproducible.
Uint8List pseudoRandom(final int length, [final int seed = 0x12345678]) {
  final out = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = (state >> 16) & 0xFF;
  }
  return out;
}

/// Shared edge-case inputs so every codec exercises the same set.
Map<String, Uint8List> standardEdgeCases() => {
  'empty': Uint8List(0),
  'single byte': bytes([0x42]),
  'all zeros': Uint8List(4096),
  'incompressible': pseudoRandom(4096),
  'all byte values': bytes(List.generate(256, (i) => i)),
  'large repetitive': bytes(
    List.generate(200000, (i) => 'the quick brown fox '.codeUnitAt(i % 20)),
  ),
};

/// Block round-trip: compress then decompress must reproduce [data] exactly.
void expectRoundTrip(final CompressionCodec codec, final Uint8List data) {
  expect(
    codec.decompress(codec.compress(data)),
    orderedEquals(data),
    reason: 'block round-trip (${data.length} bytes)',
  );
}

/// Drains a byte stream into a single [Uint8List].
Future<Uint8List> collect(final Stream<Uint8List> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Streaming round-trip: compress [chunks], then decompress, expecting the
/// concatenation of the inputs back.
Future<void> expectStreamRoundTrip(
  final CompressionStreamCodec codec,
  final List<Uint8List> chunks,
) async {
  final original = bytes(chunks.expand((c) => c));
  final compressed = await collect(codec.compress(Stream.fromIterable(chunks)));
  final restored = await collect(codec.decompress(Stream.value(compressed)));
  expect(restored, orderedEquals(original), reason: 'streaming round-trip');
}

/// Fragmented round-trip: compress [data], then decompress feeding the
/// compressed bytes one at a time — exercises chunk-boundary handling.
Future<void> expectFragmentedRoundTrip(
  final CompressionStreamCodec codec,
  final Uint8List data,
) async {
  final compressed = await collect(codec.compress(Stream.value(data)));
  final oneByte = [
    for (var i = 0; i < compressed.length; i++)
      Uint8List.sublistView(compressed, i, i + 1),
  ];
  final restored = await collect(
    codec.decompress(Stream.fromIterable(oneByte)),
  );
  expect(
    restored,
    orderedEquals(data),
    reason: 'fragmented (1-byte) round-trip (${data.length} bytes)',
  );
}

/// Check if a CLI tool is available on the system
///
/// Returns true if the tool can be executed, false otherwise.
/// This allows tests to skip gracefully when CLI tools aren't installed.
Future<bool> cliAvailable(final String tool) async {
  try {
    final result = await Process.run(tool, ['--version']);
    // Most tools return 0 on --version, some return 1
    return result.exitCode == 0 || result.exitCode == 1;
  } catch (_) {
    return false;
  }
}

/// Cache for CLI availability to avoid repeated checks
final Map<String, bool> _cliCache = {};

/// Check CLI availability with caching
Future<bool> cliAvailableCached(final String tool) async {
  if (_cliCache.containsKey(tool)) {
    return _cliCache[tool]!;
  }
  final available = await cliAvailable(tool);
  _cliCache[tool] = available;
  return available;
}

/// Read a fixture file as bytes
Uint8List readFixture(final String path) {
  return Uint8List.fromList(File(path).readAsBytesSync());
}

/// Read a data fixture (test/fixtures/data/...)
Uint8List readDataFixture(final String name) {
  return readFixture('test/fixtures/data/$name');
}

/// Read a codec fixture (test/fixtures/{codec}/...)
Uint8List readCodecFixture(final String codec, final String name) {
  return readFixture('test/fixtures/$codec/$name');
}

/// Standard fixture paths for testing
const standardFixtures = <String>[
  'empty.txt',
  'zeros.bin',
  'random.bin',
  'html',
  'artificial/aaa.txt',
  'artificial/alphabet.txt',
  'canterbury/alice29.txt',
  'calgary/paper1',
];

/// Clean up temporary test files
Future<void> cleanup(final List<String> paths) async {
  for (final path in paths) {
    try {
      await File(path).delete();
    } catch (_) {
      // Ignore errors on cleanup
    }
  }
}
