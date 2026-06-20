import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

final _compiledRoundTripPrograms = <String, Future<String>>{};
final _compiledDecompressPrograms = <String, Future<String>>{};

Future<void> expectWebRoundTrip({
  required final String codecExpression,
  required final Uint8List data,
}) async {
  final jsPath = await _compiledRoundTripPrograms.putIfAbsent(
    codecExpression,
    () => _compileRoundTripProgram(codecExpression),
  );

  final payloadDirectory = await Directory.systemTemp.createTemp(
    'libcompress_web_payload_',
  );
  try {
    final payloadPath = '${payloadDirectory.path}/payload.base64';
    await File(payloadPath).writeAsString(base64Encode(data));

    final jsResult = await Process.run('node', <String>[
      '-e',
      '''
const fs = require("fs");
const payload = fs.readFileSync(process.argv[1], "utf8");
globalThis.self = globalThis;
globalThis.dartPrint = (message) => console.log(message);
globalThis.dartMainRunner = (main, args) => main([payload]);
require(${jsonEncode(jsPath)});
''',
      payloadPath,
    ]);
    expect(jsResult.exitCode, 0, reason: _processOutput(jsResult));

    final result =
        jsonDecode((jsResult.stdout as String).trim()) as Map<String, Object?>;
    expect(result['decompressedLength'], data.length);
  } finally {
    await payloadDirectory.delete(recursive: true);
  }
}

Future<void> expectWebDecompresses({
  required final String codecExpression,
  required final Uint8List compressed,
  required final Uint8List expected,
}) async {
  final jsPath = await _compiledDecompressPrograms.putIfAbsent(
    codecExpression,
    () => _compileDecompressProgram(codecExpression),
  );

  final payloadDirectory = await Directory.systemTemp.createTemp(
    'libcompress_web_payload_',
  );
  try {
    final compressedPath = '${payloadDirectory.path}/compressed.base64';
    final expectedPath = '${payloadDirectory.path}/expected.base64';
    await File(compressedPath).writeAsString(base64Encode(compressed));
    await File(expectedPath).writeAsString(base64Encode(expected));

    final jsResult = await Process.run('node', <String>[
      '-e',
      '''
const fs = require("fs");
const compressed = fs.readFileSync(process.argv[1], "utf8");
const expected = fs.readFileSync(process.argv[2], "utf8");
globalThis.self = globalThis;
globalThis.dartPrint = (message) => console.log(message);
globalThis.dartMainRunner = (main, args) => main([compressed, expected]);
require(${jsonEncode(jsPath)});
''',
      compressedPath,
      expectedPath,
    ]);
    expect(jsResult.exitCode, 0, reason: _processOutput(jsResult));
  } finally {
    await payloadDirectory.delete(recursive: true);
  }
}

Future<String> _compileRoundTripProgram(String codecExpression) async {
  return _compileWebProgram('web_round_trip', '''
import 'dart:convert';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

void main(List<String> args) {
  final codec = $codecExpression;
  final original = base64Decode(args.single);
  final compressed = codec.compress(original);
  final decompressed = codec.decompress(compressed);
  final mismatch = _firstMismatch(decompressed, original);
  if (mismatch != -1) {
    final actual =
        mismatch < decompressed.length ? decompressed[mismatch] : null;
    final expected = mismatch < original.length ? original[mismatch] : null;
    throw StateError(
      'web round trip failed: '
      'originalLength=\${original.length}, '
      'decompressedLength=\${decompressed.length}, '
      'firstMismatch=\$mismatch, '
      'expected=\$expected, '
      'actual=\$actual',
    );
  }
  print(jsonEncode(<String, int>{
    'compressedLength': compressed.length,
    'decompressedLength': decompressed.length,
  }));
}

${_firstMismatchSource()}
''');
}

Future<String> _compileDecompressProgram(String codecExpression) async {
  return _compileWebProgram('web_decompress', '''
import 'dart:convert';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

void main(List<String> args) {
  final codec = $codecExpression;
  final compressed = base64Decode(args[0]);
  final expected = base64Decode(args[1]);
  final decompressed = codec.decompress(compressed);
  final mismatch = _firstMismatch(decompressed, expected);
  if (mismatch != -1) {
    final actual =
        mismatch < decompressed.length ? decompressed[mismatch] : null;
    final wanted = mismatch < expected.length ? expected[mismatch] : null;
    throw StateError(
      'web decompression failed: '
      'expectedLength=\${expected.length}, '
      'decompressedLength=\${decompressed.length}, '
      'firstMismatch=\$mismatch, '
      'expected=\$wanted, '
      'actual=\$actual',
    );
  }
}

${_firstMismatchSource()}
''');
}

Future<String> _compileWebProgram(String name, String source) async {
  final output = await Directory.systemTemp.createTemp('libcompress_web_');
  final sourcePath = '${output.path}/$name.dart';
  final jsPath = '${output.path}/$name.js';
  await File(sourcePath).writeAsString(source);

  final compileResult = await Process.run('dart', <String>[
    'compile',
    'js',
    '-O1',
    '--packages=${Directory.current.path}/.dart_tool/package_config.json',
    sourcePath,
    '-o',
    jsPath,
  ], workingDirectory: Directory.current.path);
  expect(compileResult.exitCode, 0, reason: _processOutput(compileResult));
  return jsPath;
}

String _firstMismatchSource() {
  return r'''
int _firstMismatch(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return left.length < right.length ? left.length : right.length;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return index;
    }
  }
  return -1;
}
''';
}

String _processOutput(ProcessResult result) {
  return <Object?>[
    result.stdout,
    result.stderr,
  ].where((value) => value.toString().trim().isNotEmpty).join('\n');
}
