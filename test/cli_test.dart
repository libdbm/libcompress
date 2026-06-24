import 'dart:io';
import 'dart:typed_data';
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
    List.generate(50000, (i) => 'the quick brown fox '.codeUnitAt(i % 20)),
  );

  test('dart run :libcompress --help exits and prints usage', () {
    final r = run(['--help']);
    expect(r.stdout.toString(), contains('Usage: libcompress'));
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
      Directory(dir.path).listSync().where((e) => e.path.contains('.tmp-')),
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

    final r = run(['--gzip', '--stream', '-d', p('c.gz'), p('out.txt')]);
    expect(r.exitCode, isNot(0));
    expect(
      File(p('out.txt')).readAsStringSync(),
      'STALE',
      reason: 'failed decompress must not overwrite the existing output',
    );
    expect(
      Directory(dir.path).listSync().where((e) => e.path.contains('.tmp-')),
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
