import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  // -O1 is the dart compile js default; -O4 drops checks that -O1 keeps.
  for (final level in ['-O1', '-O4']) {
    test(
      'all codecs match VM behavior when compiled to JavaScript ($level)',
      () async {
        if (!await cliAvailableCached('node')) {
          markTestSkipped('node is not available');
          return;
        }
        final output = await Directory.systemTemp.createTemp('libcompress_js_');
        addTearDown(() => output.delete(recursive: true));

        final vmResult = await Process.run('dart', <String>[
          'run',
          'test/support/web_codec_matrix_runner.dart',
        ], workingDirectory: Directory.current.path);
        expect(vmResult.exitCode, 0, reason: _processOutput(vmResult));

        final jsPath = '${output.path}/web_codec_matrix_runner.js';
        final compileResult = await Process.run('dart', <String>[
          'compile',
          'js',
          level,
          'test/support/web_codec_matrix_runner.dart',
          '-o',
          jsPath,
        ], workingDirectory: Directory.current.path);
        expect(
          compileResult.exitCode,
          0,
          reason: _processOutput(compileResult),
        );

        final jsResult = await Process.run('node', <String>[
          '-e',
          '''
globalThis.self = globalThis;
globalThis.dartPrint = (message) => console.log(message);
require(${jsonEncode(jsPath)});
''',
        ]);
        expect(jsResult.exitCode, 0, reason: _processOutput(jsResult));

        expect(
          jsonDecode((jsResult.stdout as String).trim()),
          equals(jsonDecode((vmResult.stdout as String).trim())),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }
}

String _processOutput(final ProcessResult result) {
  return <Object?>[
    result.stdout,
    result.stderr,
  ].where((final value) => value.toString().trim().isNotEmpty).join('\n');
}
