import 'dart:io';
import 'dart:typed_data';
import 'package:libcompress/libcompress.dart';
import 'package:test/test.dart';

/// Exercises the CLI entrypoint (bin/libcompress.dart) end-to-end, focusing on
/// the atomic-output safety contract: a failed decompression must never leave a
/// partial/corrupt artifact at the output path.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('libcompress_cli'));
  tearDown(() => dir.deleteSync(recursive: true));

  String p(final String name) => '${dir.path}/$name';

  ProcessResult run(final List<String> args) =>
      Process.runSync('dart', ['run', 'bin/libcompress.dart', ...args]);

  final sample = Uint8List.fromList(
    List.generate(
      50000,
      (final i) => 'the quick brown fox '.codeUnitAt(i % 20),
    ),
  );

  /// Runs the CLI with [input] on stdin and returns its stdout bytes.
  Future<(int, Uint8List, String)> pipe(
    final List<String> args,
    final Uint8List input,
  ) async {
    final process = await Process.start('dart', [
      'run',
      'bin/libcompress.dart',
      ...args,
    ]);
    final output = BytesBuilder(copy: false);
    final done = process.stdout.forEach(output.add);
    final errors = process.stderr.transform(systemEncoding.decoder).join();
    process.stdin.add(input);
    await process.stdin.close();
    await done;
    return (await process.exitCode, output.takeBytes(), await errors);
  }

  test('--help exits 0 and prints usage on stdout', () {
    final r = run(['--help']);
    expect(r.exitCode, 0);
    expect(r.stdout.toString(), contains('Usage: libcompress'));
  });

  test('usage errors go to stderr with exit code 2', () {
    for (final args in [
      <String>[],
      ['--levle', 'in', 'out'],
      ['in'],
      ['in', 'out', 'extra'],
    ]) {
      final r = run(args);
      expect(r.exitCode, 2, reason: '$args');
      expect(r.stdout.toString(), isEmpty, reason: '$args');
      expect(r.stderr.toString(), contains('Error:'), reason: '$args');
    }
    expect(run(['--levle', 'in', 'out']).stderr, contains('--levle'));
  });

  test('an existing output needs -f; the input is never the output', () {
    File(p('in.txt')).writeAsBytesSync(sample);
    File(p('out.lz4')).writeAsStringSync('KEEP');
    expect(run([p('in.txt'), p('out.lz4')]).exitCode, 2);
    expect(File(p('out.lz4')).readAsStringSync(), 'KEEP');
    expect(run(['-f', p('in.txt'), p('out.lz4')]).exitCode, 0);
    expect(
      File(p('out.lz4')).readAsBytesSync(),
      isNot(orderedEquals('KEEP'.codeUnits)),
    );

    final r = run(['-f', p('in.txt'), p('in.txt')]);
    expect(r.exitCode, 2);
    expect(File(p('in.txt')).readAsBytesSync(), orderedEquals(sample));
  });

  test('a directory output or an out-of-range block size is a usage error', () {
    File(p('in.txt')).writeAsBytesSync(sample);
    Directory(p('out')).createSync();
    for (final args in [
      [p('in.txt'), p('out')],
      ['--stream', p('in.txt'), p('out')],
      ['--block-size', '8388608', p('in.txt'), p('x.lz4')],
    ]) {
      final r = run(args);
      expect(r.exitCode, 2, reason: '$args ${r.stderr}');
    }
    expect(
      Directory(
        dir.path,
      ).listSync().where((final e) => e.path.contains('.tmp-')),
      isEmpty,
    );
  });

  test('--level reaches every level a codec supports', () async {
    final (code, packed, _) = await pipe([
      '--zstd',
      '--level',
      '19',
      '-',
      '-',
    ], sample);
    expect(code, 0);
    expect(packed, orderedEquals(ZstdCodec(level: 19).compress(sample)));
    for (final args in [
      ['--zstd', '--level', '23'],
      ['--lz4', '--level', '10'],
      ['--gzip', '--level', '0'],
      ['--zstd', '--level', 'x'],
      ['--level'],
    ]) {
      final r = run([...args, '-', '-']);
      expect(r.exitCode, 2, reason: '$args ${r.stderr}');
    }
  });

  test('- reads stdin and writes stdout, with status on stderr', () async {
    for (final codec in ['--lz4', '--snappy', '--gzip', '--zstd']) {
      for (final stream in [
        <String>[],
        ['--stream'],
      ]) {
        final (code, packed, _) = await pipe([
          codec,
          ...stream,
          '-',
          '-',
        ], sample);
        expect(code, 0, reason: '$codec $stream');
        final (back, restored, _) = await pipe([
          codec,
          ...stream,
          '-d',
          '-',
          '-',
        ], packed);
        expect(back, 0, reason: '$codec $stream');
        expect(restored, orderedEquals(sample), reason: '$codec $stream');
      }
    }
  });

  test('defaults and formats match the library', () async {
    final cases = <List<String>, Uint8List>{
      ['--lz4']: Lz4Codec().compress(sample),
      ['--lz4', '--raw']: Lz4Codec(format: Lz4Format.raw).compress(sample),
      ['--lz4', '--hadoop']: Lz4Codec(
        format: Lz4Format.hadoop,
      ).compress(sample),
      ['--snappy']: SnappyCodec(format: SnappyFormat.framed).compress(sample),
      ['--snappy', '--raw']: SnappyCodec().compress(sample),
      ['--gzip']: GzipCodec().compress(sample),
      ['--zstd']: ZstdCodec().compress(sample),
    };
    for (final entry in cases.entries) {
      final (code, packed, _) = await pipe([...entry.key, '-', '-'], sample);
      expect(code, 0, reason: '${entry.key}');
      expect(packed, orderedEquals(entry.value), reason: '${entry.key}');
    }
  });

  test('format flags are checked against the codec and --stream', () {
    for (final args in [
      ['--stream', '--raw'],
      ['--stream', '--hadoop'],
      ['--snappy', '--stream', '--raw'],
      ['--gzip', '--raw'],
      ['--snappy', '--hadoop'],
      ['--lz4', '--framing'],
      ['--raw', '--hadoop'],
    ]) {
      final r = run([...args, '-', '-']);
      expect(r.exitCode, 2, reason: '$args');
      expect(r.stderr.toString(), contains('Error:'), reason: '$args');
    }
  });

  test('streaming round-trip works and renames into place', () {
    File(p('in.txt')).writeAsBytesSync(sample);
    expect(run(['--gzip', '--stream', p('in.txt'), p('c.gz')]).exitCode, 0);
    expect(
      run(['--gzip', '--stream', '-d', p('c.gz'), p('out.txt')]).exitCode,
      0,
    );
    expect(File(p('out.txt')).readAsBytesSync(), orderedEquals(sample));
    expect(
      Directory(
        dir.path,
      ).listSync().where((final e) => e.path.contains('.tmp-')),
      isEmpty,
    );
  });

  test('corrupt input fails without leaving output or temp files', () {
    File(p('in.txt')).writeAsBytesSync(sample);
    expect(run(['--gzip', '--stream', p('in.txt'), p('c.gz')]).exitCode, 0);

    // Flip a payload byte so the CRC check fails mid-stream.
    final bytes = File(p('c.gz')).readAsBytesSync();
    bytes[bytes.length ~/ 2] ^= 0xFF;
    File(p('c.gz')).writeAsBytesSync(bytes);

    // A pre-existing output file must be left untouched.
    File(p('out.txt')).writeAsStringSync('STALE');

    final r = run(['--gzip', '--stream', '-d', '-f', p('c.gz'), p('out.txt')]);
    expect(r.exitCode, 1);
    expect(
      File(p('out.txt')).readAsStringSync(),
      'STALE',
      reason: 'failed decompress must not overwrite the existing output',
    );
    expect(
      Directory(
        dir.path,
      ).listSync().where((final e) => e.path.contains('.tmp-')),
      isEmpty,
      reason: 'temp file must be cleaned up on error',
    );
  });

  test('--verified round-trips valid data', () {
    File(p('in.txt')).writeAsBytesSync(sample);
    expect(run(['--zstd', '--stream', p('in.txt'), p('c.zst')]).exitCode, 0);
    final r = run([
      '--zstd',
      '--stream',
      '-d',
      '--verified',
      p('c.zst'),
      p('out.txt'),
    ]);
    expect(r.exitCode, 0);
    expect(File(p('out.txt')).readAsBytesSync(), orderedEquals(sample));
  });
}
