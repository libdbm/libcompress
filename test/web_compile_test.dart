import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'public package entrypoint compiles to JavaScript',
    () async {
      final output = await Directory.systemTemp.createTemp('libcompress_js_');
      addTearDown(() => output.delete(recursive: true));

      final result = await Process.run('dart', <String>[
        'compile',
        'js',
        'example/example.dart',
        '-o',
        '${output.path}/example.js',
      ], workingDirectory: Directory.current.path);

      expect(
        result.exitCode,
        0,
        reason: [
          result.stdout,
          result.stderr,
        ].where((line) => line.toString().trim().isNotEmpty).join('\n'),
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
