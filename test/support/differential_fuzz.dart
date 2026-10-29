import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// Set RUN_FUZZ=1 to run the differential fuzz tests (they need the codec CLIs).
final fuzzEnabled = Platform.environment['RUN_FUZZ'] == '1';

/// Mutants per frame and the first seed, overridable with FUZZ_COUNT and
/// FUZZ_SEED for a longer or different run than the default.
final _count = int.tryParse(Platform.environment['FUZZ_COUNT'] ?? '') ?? 300;
final _seed = int.tryParse(Platform.environment['FUZZ_SEED'] ?? '') ?? 1;

/// Skip reason for differential fuzz tests when [fuzzEnabled] is false.
final fuzzSkip = fuzzEnabled ? null : 'set RUN_FUZZ=1 to run differential fuzz';

/// A command-line tool used as the reference implementation, reading stdin
/// and writing stdout.
final class Reference {
  const Reference(this.tool, this.decoding);

  final String tool;

  /// Arguments that make [tool] decode stdin to stdout.
  final List<String> decoding;

  /// Runs [tool] with [arguments] on [input]; returns stdout, or null when the
  /// tool exits non-zero.
  Future<Uint8List?> run(
    final List<String> arguments,
    final Uint8List input,
  ) async {
    final process = await Process.start(tool, arguments);
    final output = BytesBuilder(copy: false);
    final done = process.stdout.forEach(output.add);
    final errors = process.stderr.drain<void>();
    process.stdin.add(input);
    // A tool may exit before reading all of a corrupt input.
    await process.stdin.close().catchError((_) {});
    await Future.wait([done, errors]);
    final code = await process.exitCode;
    return code == 0 ? output.takeBytes() : null;
  }

  /// Compresses [data] with [tool] using [arguments].
  Future<Uint8List> encode(
    final List<String> arguments,
    final Uint8List data,
  ) async {
    final result = await run(arguments, data);
    if (result == null) {
      throw StateError('$tool ${arguments.join(' ')} failed to compress');
    }
    return result;
  }

  /// Decodes [data] with [tool]; null when the tool rejects it.
  Future<Uint8List?> decode(final Uint8List data) => run(decoding, data);
}

/// Outcome of one of our decoders on one input.
final class Outcome {
  const Outcome.accepted(this.output) : error = null;
  const Outcome.rejected(this.error) : output = null;

  final Uint8List? output;
  final Object? error;

  bool get accepted => output != null;
}

Outcome _block(
  final Uint8List Function(Uint8List) decode,
  final Uint8List data,
) {
  try {
    return Outcome.accepted(decode(data));
  } catch (error) {
    return Outcome.rejected(error);
  }
}

Future<Outcome> _stream(
  final Stream<Uint8List> Function(Stream<Uint8List>) decode,
  final Uint8List data,
) async {
  const size = 1000;
  final chunks = [
    for (var start = 0; start < data.length; start += size)
      Uint8List.sublistView(data, start, min(start + size, data.length)),
  ];
  try {
    final output = BytesBuilder(copy: false);
    await decode(Stream.fromIterable(chunks)).forEach(output.add);
    return Outcome.accepted(output.takeBytes());
  } catch (error) {
    return Outcome.rejected(error);
  }
}

/// Produces [count] mutants of [frame] (bit flip, byte overwrite or
/// truncation), deterministically from [seed]. Empty mutants are skipped.
List<Uint8List> mutate(final Uint8List frame, final int count, final int seed) {
  final random = Random(seed);
  final mutants = <Uint8List>[];
  while (mutants.length < count) {
    final mutant = Uint8List.fromList(frame);
    final position = random.nextInt(frame.length);
    switch (random.nextInt(3)) {
      case 0:
        mutant[position] ^= 1 << random.nextInt(8);
        mutants.add(mutant);
      case 1:
        mutant[position] = random.nextInt(256);
        mutants.add(mutant);
      default:
        if (position > 0) {
          mutants.add(Uint8List.sublistView(mutant, 0, position));
        }
    }
  }
  return mutants;
}

bool _equal(final Uint8List left, final Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

String _describe(final Outcome outcome, final Uint8List? expected) {
  if (!outcome.accepted) return 'rejected (${outcome.error})';
  final output = outcome.output!;
  return 'accepted ${output.length} bytes'
      '${expected == null ? '' : ', reference ${expected.length} bytes'}';
}

/// Decodes every mutant of [frame] with our [block] and [stream] decoders and
/// with [reference], returning one description per divergence:
///
/// - an exception other than [CompressionFormatException] escaped; or
/// - we accepted a mutant the reference rejects, or decoded it to different
///   bytes than the reference.
///
/// Rejecting a mutant the reference accepts is allowed (we may be stricter).
/// Each divergent mutant is written under the system temp directory so it can
/// be replayed.
Future<List<String>> differentialFuzz({
  required final String name,
  required final Uint8List frame,
  required final Reference reference,
  required final Uint8List Function(Uint8List) block,
  required final Stream<Uint8List> Function(Stream<Uint8List>) stream,
  final int count = 300,
  final int seed = 1,
}) async {
  final divergences = <String>[];
  final mutants = mutate(frame, count, seed);
  final directory = Directory.systemTemp.createTempSync('libcompress_fuzz_');
  const batch = 8;
  for (var start = 0; start < mutants.length; start += batch) {
    final end = min(start + batch, mutants.length);
    final expected = await Future.wait([
      for (var index = start; index < end; index++)
        reference.decode(mutants[index]),
    ]);
    for (var index = start; index < end; index++) {
      final mutant = mutants[index];
      final truth = expected[index - start];
      final outcomes = {
        'block': _block(block, mutant),
        'stream': await _stream(stream, mutant),
      };
      for (final entry in outcomes.entries) {
        final outcome = entry.value;
        final error = outcome.error;
        final String? problem;
        if (error != null && error is! CompressionFormatException) {
          problem = 'escaped ${error.runtimeType}: $error';
        } else if (outcome.accepted && truth == null) {
          problem = 'accepted a mutant the reference rejects';
        } else if (outcome.accepted && !_equal(outcome.output!, truth!)) {
          problem = 'decoded differently from the reference';
        } else {
          problem = null;
        }
        if (problem != null) {
          final file = File('${directory.path}/$name-$seed-$index.bin')
            ..writeAsBytesSync(mutant);
          divergences.add(
            '$name mutant $index (${entry.key}): $problem; '
            'ours ${_describe(outcome, truth)}; replay ${file.path}',
          );
        }
      }
    }
  }
  if (divergences.isEmpty) directory.deleteSync(recursive: true);
  return divergences;
}

/// Defines a `<title> differential fuzz` group with one test per entry in
/// [frames]: each builds a valid frame, mutates it, and expects no
/// [differentialFuzz] divergence against [reference]. Skipped unless RUN_FUZZ=1,
/// and per test when the reference CLI is missing.
void defineDifferentialFuzz({
  required final String title,
  required final Reference reference,
  required final Map<String, Future<Uint8List> Function()> frames,
  required final Uint8List Function(Uint8List) block,
  required final Stream<Uint8List> Function(Stream<Uint8List>) stream,
}) {
  group('$title differential fuzz', () {
    for (final entry in frames.entries) {
      test(entry.key, () async {
        if (!await cliAvailableCached(reference.tool)) {
          markTestSkipped('${reference.tool} CLI tool not available');
          return;
        }
        final divergences = await differentialFuzz(
          name: entry.key.replaceAll(RegExp('[^A-Za-z0-9]+'), '_'),
          frame: await entry.value(),
          reference: reference,
          block: block,
          stream: stream,
          count: _count,
          seed: _seed,
        );
        expect(
          divergences.take(10).toList(),
          isEmpty,
          reason: '${divergences.length} divergent decodes',
        );
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }, skip: fuzzSkip);
}
