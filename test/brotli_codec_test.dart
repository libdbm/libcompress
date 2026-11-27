import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/brotli/bit_reader.dart';
import 'package:libcompress/src/brotli/bit_writer.dart' as encoder;
import 'package:libcompress/src/brotli/brotli_decoder.dart';
import 'package:libcompress/src/brotli/brotli_encoder.dart';
import 'package:libcompress/src/brotli/dictionary.dart';
import 'package:libcompress/src/brotli/meta_block.dart';
import 'package:libcompress/src/brotli/prefix_code.dart';
import 'package:libcompress/src/brotli/prefix_writer.dart' show PrefixCodes;
import 'package:libcompress/src/brotli/streaming_brotli_encoder.dart';
import 'package:libcompress/src/util/huffman.dart';
import 'package:test/test.dart';

import 'support/brotli_writer.dart';
import 'support/differential_fuzz.dart';
import 'support/parquet_pages.dart';
import 'test_utils.dart';

/// Every `.br` fixture, as a path relative to `test/fixtures/brotli/`.
List<String> brotliFixtures() {
  const root = 'test/fixtures/brotli/';
  return Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .map((final file) => file.path.substring(root.length))
      .where((final path) => path.endsWith('.br'))
      .toList()
    ..sort();
}

/// The source file a fixture was made from: `html.q9.w10.br` is `html`.
String brotliSource(final String fixture) =>
    fixture.replaceFirst(RegExp(r'\.q\d+(\.w\d+)?\.br$'), '');

Uint8List hex(final String value) => bytes([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

Uint8List decode(final Uint8List data, {final int? maxSize}) =>
    BrotliDecoder(maxSize: maxSize).decompress(data);

/// Reads the complex code lengths [writer] holds: HSKIP, then the lengths.
Uint8List complexLengths(final BitWriter writer, final int alphabet) {
  final reader = writer.reader();
  final skip = reader.bits(2);
  return readLengths(reader, alphabet, skip);
}

/// Writes [symbols] with the canonical code for [lengths].
void writeSymbols(
  final BitWriter writer,
  final List<int> lengths,
  final List<int> symbols,
) {
  final codes = canonical(lengths);
  for (final symbol in symbols) {
    writer.put(codes[symbol], lengths[symbol]);
  }
}

void main() {
  group('Brotli block', () {
    test('round-trips standard fixtures', () {
      final codec = BrotliCodec();
      for (final path in standardFixtures) {
        expectRoundTrip(codec, readDataFixture(path));
      }
    });

    test('round-trips standard edge cases', () {
      final codec = BrotliCodec();
      standardEdgeCases().forEach((final name, final data) {
        expect(
          codec.decompress(codec.compress(data)),
          orderedEquals(data),
          reason: name,
        );
      });
    });

    test('round-trips every window size', () {
      final data = readDataFixture('html');
      for (var window = 10; window <= 24; window++) {
        expectRoundTrip(BrotliCodec(window: window), data);
      }
    });

    test('round-trips input longer than one meta-block', () {
      expectRoundTrip(BrotliCodec(), pseudoRandom((1 << 24) + 1000));
    });

    test('decodes with the expected size', () {
      final data = readDataFixture('html');
      final compressed = BrotliCodec().compress(data);
      expect(
        BrotliCodec().decompress(compressed, size: data.length),
        orderedEquals(data),
      );
      for (final size in [data.length - 1, data.length + 1]) {
        expect(
          () => BrotliCodec().decompress(compressed, size: size),
          throwsA(isA<CompressionFormatException>()),
          reason: 'size $size',
        );
      }
      expect(
        () => BrotliCodec().decompress(compressed, size: -1),
        throwsArgumentError,
      );
    });

    test('is named BROTLI', () {
      expect(BrotliCodec().name, 'BROTLI');
    });

    test('decodes every reference fixture', () {
      final fixtures = brotliFixtures();
      expect(fixtures, hasLength(66));
      for (final path in fixtures) {
        expect(
          decode(readCodecFixture('brotli', path)),
          orderedEquals(readDataFixture(brotliSource(path))),
          reason: path,
        );
      }
    });
  });

  group('Brotli streaming', () {
    Stream<Uint8List> pieces(final Uint8List data, final int size) =>
        Stream.fromIterable([
          for (var start = 0; start < data.length; start += size)
            Uint8List.sublistView(
              data,
              start,
              start + size < data.length ? start + size : data.length,
            ),
        ]);

    test(
      'decodes every reference fixture in one and in random chunks',
      () async {
        final random = Random(23);
        for (final path in brotliFixtures()) {
          final data = readCodecFixture('brotli', path);
          final expected = readDataFixture(brotliSource(path));
          expect(
            await collect(BrotliStreamCodec().decompress(Stream.value(data))),
            orderedEquals(expected),
            reason: '$path whole',
          );
          expect(
            await collect(
              BrotliStreamCodec().decompress(
                pieces(data, random.nextInt(5000) + 1),
              ),
            ),
            orderedEquals(expected),
            reason: '$path random chunks',
          );
        }
      },
    );

    test('decodes 1-byte chunks', () async {
      for (final path in [
        'html.q1.w10.br',
        'canterbury/alice29.txt.q11.br',
        'random.bin.q0.br',
        'lorem.txt.q5.br',
      ]) {
        expect(
          await collect(
            BrotliStreamCodec().decompress(
              pieces(readCodecFixture('brotli', path), 1),
            ),
          ),
          orderedEquals(readDataFixture(brotliSource(path))),
          reason: path,
        );
      }
    });

    test('round-trips standard fixtures and edge cases', () async {
      final codec = BrotliStreamCodec();
      for (final path in standardFixtures) {
        await expectStreamRoundTrip(codec, [readDataFixture(path)]);
      }
      for (final data in standardEdgeCases().values) {
        await expectStreamRoundTrip(codec, [data]);
      }
    });

    test('round-trips 1-byte compressed input', () async {
      await expectFragmentedRoundTrip(
        BrotliStreamCodec(),
        readDataFixture('calgary/paper1'),
      );
    });

    test('compresses the same however the input is split', () async {
      final data = readDataFixture('canterbury/alice29.txt');
      final large = bytes([...data, ...data, ...data]);
      for (final level in [1, 6, 11]) {
        final block = BrotliCodec(level: level).compress(large);
        for (final size in [1, 64, 70000, large.length]) {
          expect(
            await collect(
              BrotliStreamCodec(level: level).compress(pieces(large, size)),
            ),
            orderedEquals(block),
            reason: 'level $level, $size-byte chunks',
          );
        }
      }
    });

    test('compresses an empty stream', () async {
      final compressed = await collect(
        BrotliStreamCodec().compress(const Stream.empty()),
      );
      expect(BrotliCodec().decompress(compressed), isEmpty);
    });

    test('brotli -d reads streamed output', () async {
      if (!await cliAvailableCached('brotli')) {
        return markTestSkipped('brotli CLI tool not available');
      }
      final data = readDataFixture('calgary/book1');
      final compressed = await collect(
        BrotliStreamCodec().compress(pieces(data, 1000)),
      );
      expect(await referenceDecode(compressed), orderedEquals(data));
    });

    test('rejects empty input', () async {
      await expectEmptyRejected<BrotliFormatException>(
        BrotliCodec(),
        BrotliStreamCodec(),
      );
    });

    test('rejects a truncated stream at the end of input', () async {
      final compressed = BrotliCodec().compress(readDataFixture('html'));
      for (final cut in [1, compressed.length ~/ 2, compressed.length - 1]) {
        await expectLater(
          collect(
            BrotliStreamCodec().decompress(
              Stream.value(Uint8List.sublistView(compressed, 0, cut)),
            ),
          ),
          throwsA(isA<BrotliFormatException>()),
          reason: 'cut at $cut',
        );
      }
    });

    test(
      'rejects bytes after the stream, in the same or a later chunk',
      () async {
        final compressed = BrotliCodec().compress(readDataFixture('html'));
        for (final input in [
          Stream.value(bytes([...compressed, 0])),
          Stream.fromIterable([
            compressed,
            bytes([0]),
          ]),
        ]) {
          await expectLater(
            collect(BrotliStreamCodec().decompress(input)),
            throwsA(isA<BrotliFormatException>()),
          );
        }
      },
    );

    test('enforces maxSize across meta-blocks', () async {
      final data = pseudoRandom(600000);
      final compressed = BrotliCodec().compress(data);
      await expectLater(
        collect(
          BrotliStreamCodec(
            maxSize: 500000,
          ).decompress(pieces(compressed, 7000)),
        ),
        throwsA(isA<LimitException>()),
      );
      expect(
        await collect(
          BrotliStreamCodec(
            maxSize: 600000,
          ).decompress(Stream.value(compressed)),
        ),
        hasLength(600000),
      );
    });

    test('enforces maxBufferSize', () async {
      // One uncompressed meta-block of 256 KB cannot decode from a 64 KB
      // buffer.
      final compressed = BrotliCodec().compress(pseudoRandom(300000));
      await expectLater(
        collect(
          BrotliStreamCodec(
            maxBufferSize: 1 << 16,
          ).decompress(pieces(compressed, 4096)),
        ),
        throwsA(isA<LimitException>()),
      );
    });

    test(
      'decodes a meta-block that fits maxBufferSize after a retry',
      () async {
        // The first meta-block is about 262 KB, stored. An attempt at 256 KB
        // runs out of input; the retry must still happen within the 300 KB
        // buffer limit. 16-byte chunks fill the buffer to exactly the limit;
        // 7000-byte chunks overshoot it first.
        final data = pseudoRandom(300000);
        final compressed = BrotliCodec().compress(data);
        for (final size in [16, 7000]) {
          expect(
            await collect(
              BrotliStreamCodec(
                maxBufferSize: 300000,
              ).decompress(pieces(compressed, size)),
            ),
            orderedEquals(data),
            reason: '$size-byte chunks',
          );
        }
      },
    );

    test('emits output before the stream ends', () async {
      final data = readDataFixture('calgary/book1');
      final compressed = BrotliCodec().compress(data);
      var outputs = 0;
      await BrotliStreamCodec()
          .decompress(pieces(compressed, 4096))
          .forEach((_) => outputs++);
      expect(outputs, greaterThan(1));
    });

    group('constructor fail-fast', () {
      test('rejects invalid arguments', () {
        expect(() => BrotliStreamCodec(level: 0), throwsArgumentError);
        expect(() => BrotliStreamCodec(level: 12), throwsArgumentError);
        expect(() => BrotliStreamCodec(window: 25), throwsArgumentError);
        expect(() => BrotliStreamCodec(maxSize: 0), throwsArgumentError);
        expect(() => BrotliStreamCodec(maxBufferSize: 0), throwsArgumentError);
      });

      test('builds from options', () {
        final codec = BrotliStreamCodec.fromOptions(
          BrotliOptions(level: 3, window: 18, maxSize: 1000),
        );
        expect(codec.level, 3);
        expect(codec.window, 18);
        expect(codec.maxSize, 1000);
        expect(codec.name, 'BROTLI');
      });
    });
  });

  defineDifferentialFuzz(
    title: 'Brotli',
    reference: const Reference('brotli', ['-d', '-c']),
    frames: {
      for (final quality in [1, 5, 11])
        'brotli CLI -q $quality': () => const Reference('brotli', []).encode([
          '-c',
          '-q',
          '$quality',
        ], readDataFixture('canterbury/alice29.txt')),
      'libcompress encoder': () async =>
          BrotliCodec().compress(readDataFixture('canterbury/alice29.txt')),
    },
    block: BrotliCodec().decompress,
    stream: BrotliStreamCodec().decompress,
  );

  // Pages of a real Parquet file (test/fixtures/parquet): sizes and CRC-32s
  // are from the reference brotli tool. Two pages decode to just over 1 GB, so
  // they are streamed with a running CRC instead of materialized.
  group('Parquet BROTLI pages', () {
    const brotli = 4; // CompressionCodec.BROTLI
    const expected = [
      (1073741828, 0x1a7e920c),
      (15, 0xeaf2b06f),
      (1073741840, 0xa47c13c4),
      (4, 0x99f8b879),
      (15, 0x63e14f6f),
    ];
    final pages = parquetPages(
      readFixture('test/fixtures/parquet/large_string_map.brotli.parquet'),
    );

    test('large_string_map decodes', () async {
      expect(pages.map((final page) => page.codec), everyElement(brotli));
      expect(pages.map((final page) => page.size), [
        for (final (size, _) in expected) size,
      ]);
      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        final int crc;
        if (page.size < 1 << 20) {
          crc = Crc32.hash(
            BrotliCodec().decompress(page.data, size: page.size),
          );
        } else {
          var running = 0xFFFFFFFF;
          var length = 0;
          await BrotliStreamCodec(
            maxSize: null,
          ).decompress(Stream.value(page.data)).forEach((final chunk) {
            running = Crc32.update(chunk, running);
            length += chunk.length;
          });
          expect(length, page.size, reason: 'page $i');
          crc = running ^ 0xFFFFFFFF;
        }
        expect(crc, expected[i].$2, reason: 'page $i');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the default maxSize rejects the 1 GB pages', () {
      expect(
        () => BrotliCodec().decompress(pages[0].data, size: pages[0].size),
        throwsA(isA<LimitException>()),
      );
    });
  });

  group('Brotli limits & validation', () {
    test('caps an expected size by maxSize before allocating', () {
      // A 2^40-byte buffer cannot be allocated, so the hint must be capped by
      // maxSize first. The stream then decodes, and its 5000 bytes are
      // rejected as the wrong size.
      final compressed = BrotliCodec().compress(Uint8List(5000));
      expect(
        () => BrotliCodec().decompress(compressed, size: 1 << 40),
        throwsA(isA<BrotliFormatException>()),
      );
    });

    test('enforces maxSize through the codec', () {
      final compressed = BrotliCodec().compress(Uint8List(5000));
      expect(
        () => BrotliCodec(maxSize: 4999).decompress(compressed),
        throwsA(isA<LimitException>()),
      );
      expect(
        BrotliCodec(maxSize: 5000).decompress(compressed),
        hasLength(5000),
      );
      expect(
        BrotliCodec(maxSize: null).decompress(compressed),
        hasLength(5000),
      );
    });

    group('fromOptions', () {
      test('preserves options', () {
        final codec = BrotliCodec.fromOptions(
          BrotliOptions(level: 9, window: 16, maxSize: 500),
        );
        expect(codec.level, 9);
        expect(codec.window, 16);
        expect(codec.maxSize, 500);
      });

      test('applies defaults', () {
        final codec = BrotliCodec.fromOptions(BrotliOptions());
        expect(codec.level, 6);
        expect(codec.window, 22);
        expect(codec.maxSize, CodecFactory.defaultMaxSize);
      });
    });

    group('constructor fail-fast', () {
      test('rejects level out of 1-11', () {
        for (final level in [0, 12]) {
          expect(() => BrotliCodec(level: level), throwsArgumentError);
          expect(() => BrotliOptions(level: level), throwsArgumentError);
        }
      });

      test('rejects window out of 10-24', () {
        for (final window in [9, 25]) {
          expect(() => BrotliCodec(window: window), throwsArgumentError);
          expect(() => BrotliOptions(window: window), throwsArgumentError);
        }
      });

      test('rejects a non-positive maxSize', () {
        expect(() => BrotliCodec(maxSize: 0), throwsArgumentError);
      });
    });

    test('rejects a compressed meta-block above maxSize', () {
      final stream = brotliStream([command('hello'.codeUnits)], size: 5);
      expect(() => decode(stream, maxSize: 4), throwsA(isA<LimitException>()));
      expect(decode(stream, maxSize: 5), orderedEquals('hello'.codeUnits));
    });

    test('checks maxSize before decoding a meta-block', () {
      // MLEN claims 16 MB; the commands are never read.
      final stream = brotliStream([command('x'.codeUnits)], size: 1 << 24);
      expect(
        () => decode(stream, maxSize: 1 << 20),
        throwsA(isA<LimitException>()),
      );
    });

    test('rejects an uncompressed meta-block above maxSize', () {
      // 'hello' stored, then the final empty meta-block.
      expect(
        () => decode(hex('40001068656c6c6f03'), maxSize: 4),
        throwsA(isA<LimitException>()),
      );
      expect(decode(hex('40001068656c6c6f03'), maxSize: 5), hasLength(5));
    });
  });

  // Each stream below was checked against `brotli -d` 1.2.1: the valid ones
  // decode there and the invalid ones are reported as corrupt input.
  group('Brotli format', () {
    test('decodes the minimal empty stream', () {
      expect(decode(hex('06')), isEmpty);
    });

    test('reads every window size', () {
      for (final (stream, bits) in [
        ('06', 16),
        ('8101', 17),
        ('a101', 10),
        ('3f', 24),
      ]) {
        expect(readWindowBits(BitReader(hex(stream))), bits, reason: stream);
        expect(decode(hex(stream)), isEmpty, reason: stream);
      }
    });

    test('decodes an uncompressed meta-block', () {
      expect(
        decode(hex('40001068656c6c6f03')),
        orderedEquals('hello'.codeUnits),
      );
    });

    test('skips metadata meta-blocks', () {
      expect(decode(hex('2c0161626303')), isEmpty, reason: '3 bytes');
      expect(decode(hex('0c03')), isEmpty, reason: 'no bytes');
      expect(decode(hex('5a02616263')), isEmpty, reason: 'as the last block');
      final long = Uint8List(4 + 258)
        ..setAll(0, hex('cc800000'))
        ..[261] = 0x03;
      expect(decode(long), isEmpty, reason: 'two-byte MSKIPLEN');
    });

    test('rejects bytes after a last metadata meta-block', () {
      expect(
        () => decode(bytes([...hex('5a02616263'), 0])),
        throwsA(isA<BrotliFormatException>()),
      );
    });
  });

  group('Brotli invalid fields', () {
    final cases = {
      'large-window header': '9101',
      'reserved metadata bit': '1c03',
      'MSKIPLEN leading zero byte': 'cc0000000003',
      'MLEN leading zero nibble': '4400000168656c6c6f03',
      'non-zero padding before stored bytes': '40003068656c6c6f03',
      'non-zero padding at the end': 'fe',
      'trailing byte': '0600',
      'truncated stored bytes': '40001068656c',
      'no last meta-block': '00001078',
      'empty input': '',
    };
    cases.forEach((final name, final stream) {
      test('rejects $name', () {
        expect(
          () => decode(hex(stream)),
          throwsA(isA<BrotliFormatException>()),
        );
      });
    });
  });

  group('Brotli prefix codes', () {
    // Simple code: HSKIP = 1, then NSYM - 1, then the symbols.
    BitWriter simple(final int alphabet, final List<int> symbols) {
      final width = (alphabet - 1).bitLength;
      final writer = BitWriter()
        ..put(1, 2)
        ..put(symbols.length - 1, 2);
      for (final symbol in symbols) {
        writer.put(symbol, width);
      }
      return writer;
    }

    test('reads a one-symbol simple code with zero-bit symbols', () {
      final reader = (simple(256, [65])..put(0x5, 3)).reader();
      final code = readPrefixCode(reader, 256);
      expect([code.read(reader), code.read(reader)], [65, 65]);
      expect(reader.bits(3), 0x5);
    });

    test('reads simple codes with two, three and four symbols', () {
      for (final (symbols, select, lengths) in [
        ([7, 3], null, {3: 1, 7: 1}),
        ([9, 300, 2], null, {9: 1, 2: 2, 300: 2}),
        ([5, 1, 700, 6], 0, {1: 2, 5: 2, 6: 2, 700: 2}),
        ([5, 1, 700, 6], 1, {5: 1, 1: 2, 6: 3, 700: 3}),
      ]) {
        final writer = simple(704, symbols);
        if (select != null) writer.put(select, 1);
        final full = List.filled(704, 0);
        lengths.forEach((final symbol, final length) => full[symbol] = length);
        final order = [...symbols, ...symbols.reversed];
        writeSymbols(writer, full, order);
        final reader = writer.reader();
        final code = readPrefixCode(reader, 704);
        expect(
          [for (final _ in order) code.read(reader)],
          order,
          reason: '$symbols select $select',
        );
      }
    });

    test('rejects a duplicate simple-code symbol', () {
      expect(
        () => readPrefixCode(simple(256, [4, 9, 4]).reader(), 256),
        throwsA(isA<BrotliFormatException>()),
      );
    });

    test('rejects a simple-code symbol outside the alphabet', () {
      expect(
        () => readPrefixCode(simple(26, [3, 30]).reader(), 26),
        throwsA(isA<BrotliFormatException>()),
      );
    });

    test('reads a complex code and decodes with it', () {
      final lengths = List.filled(256, 0);
      for (var i = 0; i < 256; i++) {
        lengths[i] = 8;
      }
      final writer = BitWriter();
      writeLengths(writer, lengths);
      final message = 'brotli'.codeUnits;
      writeSymbols(writer, lengths, message);
      final reader = writer.reader();
      final code = readPrefixCode(reader, 256);
      expect([for (final _ in message) code.read(reader)], message);
    });

    test('honors HSKIP 2 and 3', () {
      // Code-length symbols 8 and 1 at length 1 form a complete code. HSKIP
      // 2 drops symbols 1 and 2 from the order, so 8 and 3 are used; HSKIP 3
      // drops 1, 2 and 3, so 8 and 4 are used.
      for (final (skip, other) in [(2, 3), (3, 4)]) {
        final lengthLengths = List.filled(18, 0)
          ..[8] = 1
          ..[other] = 1;
        final count = 1 << other;
        final writer = BitWriter();
        writeComplex(writer, lengthLengths, [
          for (var i = 0; i < count; i++) (other, 0),
        ], skip: skip);
        final lengths = complexLengths(writer, 256);
        expect(lengths.sublist(0, count), everyElement(other));
        expect(lengths.sublist(count), everyElement(0));
      }
    });

    test('repeats the previous length with code 16', () {
      // Before any length, 16 repeats the default length 8. Consecutive 16s
      // continue the run: 5, then (5 - 2) * 4 + 2 + 3 = 17, then 65, then
      // (65 - 2) * 4 + 1 + 3 = 256. Code-length symbol 16 is the only one, so
      // it takes zero bits and only the extra bits are written.
      final defaults = BitWriter();
      writeComplex(defaults, List.filled(18, 0)..[16] = 1, [
        (16, 2),
        (16, 2),
        (16, 2),
        (16, 1),
      ]);
      expect(complexLengths(defaults, 256), everyElement(8));

      // A 4, then 16 (3 + 2 = 5 fours), then 16 continuing the run to
      // (5 - 2) * 4 + 0 + 3 = 15: 16 fours, a complete code.
      final previous = BitWriter();
      writeComplex(
        previous,
        List.filled(18, 0)
          ..[4] = 1
          ..[16] = 1,
        [(4, 0), (16, 2), (16, 0)],
      );
      final lengths = complexLengths(previous, 26);
      expect(lengths.sublist(0, 16), everyElement(4));
      expect(lengths.sublist(16), everyElement(0));
    });

    test('accumulates consecutive repeat codes', () {
      // 4 x length 2 fills the code (4/4), but first: one length-2 symbol,
      // a 17 run of zeros (7 + 3 = 10), a second 17 that continues it
      // ((10 - 2) << 3 + 5 + 3 = 72, 62 more), then three more length-2
      // symbols through 16 (3 + 0 = 3 repeats of the previous length, 2).
      final lengthLengths = List.filled(18, 0)
        ..[2] = 1
        ..[16] = 2
        ..[17] = 2;
      final writer = BitWriter();
      writeComplex(writer, lengthLengths, [(2, 0), (17, 7), (17, 5), (16, 0)]);
      final lengths = complexLengths(writer, 256);
      expect(lengths[0], 2);
      expect(lengths.sublist(1, 73), everyElement(0));
      expect(lengths.sublist(73, 76), everyElement(2));
      expect(lengths.sublist(76), everyElement(0));
    });

    test('rejects a repeat that runs past the alphabet', () {
      final lengthLengths = List.filled(18, 0)
        ..[1] = 1
        ..[17] = 1;
      final writer = BitWriter();
      writeComplex(writer, lengthLengths, [(1, 0), (17, 7), (17, 7)]);
      expect(
        () => complexLengths(writer, 26),
        throwsA(isA<BrotliFormatException>()),
      );
    });

    test('rejects incomplete and over-subscribed complex codes', () {
      final incomplete = BitWriter();
      writeLengths(
        incomplete,
        List.filled(256, 0)
          ..[0] = 1
          ..[1] = 2,
      );
      final over = BitWriter();
      writeLengths(
        over,
        List.filled(256, 0)
          ..[0] = 1
          ..[1] = 2
          ..[2] = 1,
      );
      for (final writer in [incomplete, over]) {
        expect(
          () => readPrefixCode(writer.reader(), 256),
          throwsA(isA<BrotliFormatException>()),
        );
      }
    });

    test('rejects a code-length code that is not complete', () {
      // Code-length symbols 1 and 2 at length 2: half the space left over.
      final lengthLengths = List.filled(18, 0)
        ..[1] = 2
        ..[2] = 2;
      final writer = BitWriter();
      writeComplex(writer, lengthLengths, [(1, 0)]);
      expect(
        () => readPrefixCode(writer.reader(), 256),
        throwsA(isA<BrotliFormatException>()),
      );
    });

    test('accepts a code-length code with a single symbol', () {
      // One code-length symbol (8) at any length is read with zero bits, so
      // 256 symbols of length 8 need no further bits.
      final lengthLengths = List.filled(18, 0)..[8] = 3;
      final writer = BitWriter();
      writeComplex(writer, lengthLengths, [
        for (var i = 0; i < 256; i++) (8, 0),
      ]);
      expect(complexLengths(writer, 256), everyElement(8));
    });

    test('decodes codes up to 15 bits through second-level tables', () {
      final random = Random(7);
      for (final alphabet in [26, 256, 704]) {
        for (var round = 0; round < 20; round++) {
          // Exponential frequencies give long codes.
          final frequencies = [
            for (var i = 0; i < alphabet; i++)
              random.nextInt(3) == 0 ? 0 : 1 << random.nextInt(20),
          ];
          frequencies[0] = 1;
          frequencies[1] = 1;
          final lengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
            frequencies,
            15,
          );
          final symbols = [
            for (var i = 0; i < 500; i++)
              (() {
                while (true) {
                  final symbol = random.nextInt(alphabet);
                  if (lengths[symbol] > 0) return symbol;
                }
              })(),
          ];
          final writer = BitWriter();
          writeLengths(writer, lengths);
          writeSymbols(writer, lengths, symbols);
          final reader = writer.reader();
          final code = readPrefixCode(reader, alphabet);
          expect(
            [for (final _ in symbols) code.read(reader)],
            symbols,
            reason: 'alphabet $alphabet round $round',
          );
        }
      }
    });
  });

  // Streams that reach features the reference fixtures do not (context mode
  // MSB6, NPOSTFIX 2, OmitFirst transforms, uppercasing of multi-byte UTF-8).
  // The reference decoder is the oracle.
  group('Brotli hand-built streams', () {
    late final bool available;
    setUpAll(() async => available = await cliAvailableCached('brotli'));

    Future<void> expectReference(final Uint8List stream) async {
      final ours = decode(stream);
      if (!available) {
        markTestSkipped('brotli CLI tool not available');
        return;
      }
      final reference = await referenceDecode(stream);
      expect(reference, isNotNull, reason: 'brotli -d rejected the stream');
      expect(ours, orderedEquals(reference!));
    }

    test('selects literal trees in every context mode', () async {
      final random = Random(3);
      for (var mode = 0; mode < 4; mode++) {
        final map = [for (var c = 0; c < 64; c++) random.nextInt(4)];
        await expectReference(
          brotliStream(
            [command(List.filled(300, 0))],
            size: 300,
            mode: mode,
            trees: [0x20, 0x61, 0xC3, 0x8F],
            map: map,
          ),
        );
      }
    });

    test('decodes distances under every NPOSTFIX and NDIRECT', () async {
      final random = Random(5);
      final literals = [for (var i = 0; i < 200; i++) random.nextInt(256)];
      for (var postfix = 0; postfix < 4; postfix++) {
        for (final direct in [0, 1 << postfix, 15 << postfix]) {
          final commands = [
            command(literals, copy: 30000, distance: 200),
            for (final distance in [1, 2, 3, 7, 16, 17, 100, 1000, 30199])
              command([random.nextInt(256)], copy: 5, distance: distance),
            command([1]),
          ];
          final size = 200 + 30000 + 9 * 6 + 1;
          await expectReference(
            brotliStream(
              commands,
              size: size,
              postfix: postfix,
              direct: direct,
            ),
          );
        }
      }
    });

    test('decodes all 16 short distance codes', () async {
      final literals = List.generate(200, (final i) => i);
      // A literals-only command (copy 0) may only end the meta-block, so the
      // literals come with the first copy.
      final commands = [
        command(literals, copy: 3, distance: 50),
        for (final distance in [60, 70, 80])
          command([], copy: 3, distance: distance),
        for (var code = 0; code < 16; code++)
          command([code], copy: 3, short: code),
        command([], copy: 4, implicit: true),
        command([9]),
      ];
      final stream = brotliStream(commands, size: 200 + 4 * 3 + 16 * 4 + 4 + 1);
      await expectReference(stream);
    });

    test('decodes every transform, including multi-byte words', () async {
      // Word indices per length: the first word, a two-byte UTF-8 word and a
      // three-byte UTF-8 word, where the dictionary has them.
      final words = <(int, int)>[];
      for (final length in [4, 5, 9, 13, 24]) {
        final count = 1 << dictionaryBits[length];
        words.add((length, 0));
        for (final (low, high) in [(0xC0, 0xE0), (0xE0, 0x100)]) {
          for (var index = 0; index < count; index++) {
            final byte = dictionary[dictionaryOffsets[length] + index * length];
            if (byte >= low && byte < high) {
              words.add((length, index));
              break;
            }
          }
        }
      }
      final commands = <Command>[];
      var size = 0;
      for (var transform = 0; transform < 121; transform++) {
        for (final (length, index) in words) {
          commands.add(
            command(
              [],
              copy: length,
              distance: wordDistance(length, index, transform, size),
            ),
          );
          size += wordLength(length, transform);
        }
      }
      await expectReference(brotliStream(commands, size: size));
    });
  });

  group('Brotli invalid commands', () {
    late final bool available;
    setUpAll(() async => available = await cliAvailableCached('brotli'));

    final literals = List.generate(10, (final i) => 65 + i);
    final cases = <String, Uint8List Function()>{
      'a dictionary word shorter than 4': () =>
          brotliStream([command(literals, copy: 3, distance: 11)], size: 13),
      'a dictionary transform above 120': () => brotliStream([
        command([], copy: 4, distance: wordDistance(4, 0, 121, 0)),
      ], size: 10),
      // After a copy from distance 1, code 4 (last distance - 1) is 0.
      'a short distance code below 1': () => brotliStream([
        command(literals, copy: 2, distance: 1),
        command([], copy: 2, short: 4),
      ], size: 14),
      'a copy past MLEN': () =>
          brotliStream([command(literals, copy: 8, distance: 5)], size: 14),
      'an insert past MLEN': () => brotliStream([command(literals)], size: 9),
      'a dictionary word past MLEN': () => brotliStream([
        command([], copy: 4, distance: wordDistance(4, 0, 0, 0)),
      ], size: 3),
    };
    cases.forEach((final name, final build) {
      test('rejects $name', () async {
        final stream = build();
        expect(() => decode(stream), throwsA(isA<BrotliFormatException>()));
        if (available) {
          expect(await referenceDecode(stream), isNull, reason: 'brotli -d');
        }
      });
    });
  });

  group('Brotli context maps', () {
    BitWriter header(final int run) {
      final writer = BitWriter();
      if (run == 0) {
        writer.put(0, 1);
      } else {
        writer
          ..put(1, 1)
          ..put(run - 1, 4);
      }
      return writer;
    }

    test('expands zero runs and applies inverse move-to-front', () {
      // Two trees, RLEMAX 1: symbols 0 (a zero), 1 (a run of 2 + extra zeros)
      // and 2..3 (tree 1..2 shifted by RLEMAX).
      final writer = header(1);
      final symbols = [0, 1, 2, 3];
      writeSimple(writer, 4, symbols);
      final lengths = simpleLengths(4, symbols);
      // map: 2 (tree 1), run of 3 zeros (symbol 1, extra 1), 3 (tree 2), 0.
      writeSymbols(writer, lengths, [2]);
      writeSymbols(writer, lengths, [1]);
      writer.put(1, 1);
      writeSymbols(writer, lengths, [3, 0]);
      writer.put(0, 1); // no IMTF
      expect(readContextMap(writer.reader(), 6, 3), [1, 0, 0, 0, 2, 0]);
    });

    test('applies the inverse move-to-front transform', () {
      final writer = header(0);
      final symbols = [0, 1, 2];
      writeSimple(writer, 3, symbols);
      writeSymbols(writer, simpleLengths(3, symbols), [1, 1, 0, 2]);
      writer.put(1, 1); // IMTF
      // Indices 1, 1, 0, 2 into the order 0, 1, 2, ... give 1, 0, 0, 2.
      expect(readContextMap(writer.reader(), 4, 3), [1, 0, 0, 2]);
    });

    test('rejects a zero run past the end of the map', () {
      final writer = header(3);
      final symbols = [0, 3];
      writeSimple(writer, 5, symbols);
      final lengths = simpleLengths(5, symbols);
      writeSymbols(writer, lengths, [0, 3]);
      writer.put(0, 3); // a run of 8 zeros after one entry, in a map of 8
      expect(
        () => readContextMap(writer.reader(), 8, 2),
        throwsA(isA<BrotliFormatException>()),
      );
    });
  });

  group('Brotli fuzzing / malformed input', () {
    Matcher expected() =>
        anyOf(isA<BrotliFormatException>(), isA<LimitException>());

    test('mutated fixtures decode or throw a format exception', () {
      final random = Random(11);
      for (final path in brotliFixtures()) {
        final data = readCodecFixture('brotli', path);
        if (data.length < 2) continue;
        for (var i = 0; i < 20; i++) {
          final mutant = Uint8List.fromList(data);
          final position = random.nextInt(data.length);
          if (random.nextBool()) {
            mutant[position] ^= 1 << random.nextInt(8);
          } else {
            mutant[position] = random.nextInt(256);
          }
          try {
            decode(mutant, maxSize: 4 << 20);
          } on Object catch (error) {
            expect(error, expected(), reason: '$path mutant $i at $position');
          }
        }
      }
    });

    test('rejects truncation', () {
      final random = Random(13);
      for (final path in brotliFixtures()) {
        final data = readCodecFixture('brotli', path);
        final cuts = data.length <= 512
            ? [for (var i = 0; i < data.length; i++) i]
            : [for (var i = 0; i < 64; i++) random.nextInt(data.length)];
        for (final cut in cuts) {
          expect(
            () => decode(Uint8List.sublistView(data, 0, cut)),
            throwsA(isA<BrotliFormatException>()),
            reason: '$path cut at $cut',
          );
        }
      }
    });

    test('rejects or decodes random noise without other errors', () {
      final random = Random(17);
      for (var i = 0; i < 2000; i++) {
        final noise = pseudoRandom(random.nextInt(300) + 1, i + 1);
        try {
          decode(noise, maxSize: 1 << 20);
        } on Object catch (error) {
          expect(error, expected(), reason: 'noise $i');
        }
      }
    });
  });

  group('Brotli CLI compatibility', () {
    late final bool available;
    setUpAll(() async => available = await cliAvailableCached('brotli'));

    Future<void> expectReadable(
      final BrotliCodec codec,
      final Uint8List data,
      final String reason,
    ) async {
      final decoded = await referenceDecode(codec.compress(data));
      expect(decoded, isNotNull, reason: '$reason: brotli -d rejected it');
      expect(decoded, orderedEquals(data), reason: reason);
    }

    test('brotli -d reads our output for every level', () async {
      if (!available) return markTestSkipped('brotli CLI tool not available');
      for (var level = 1; level <= 11; level++) {
        for (final path in standardFixtures) {
          await expectReadable(
            BrotliCodec(level: level),
            readDataFixture(path),
            'level $level $path',
          );
        }
      }
    });

    test('brotli -d reads our output for every window', () async {
      if (!available) return markTestSkipped('brotli CLI tool not available');
      final data = readDataFixture('canterbury/alice29.txt');
      for (var window = 10; window <= 24; window++) {
        await expectReadable(
          BrotliCodec(window: window),
          data,
          'window $window',
        );
      }
    });

    test('encodes empty input as the minimal stream', () {
      expect(BrotliCodec(window: 16).compress(Uint8List(0)), [0x06]);
    });
  });

  group('Brotli encoder', () {
    void expectReadBack(final List<int> counts, final String reason) {
      final codes = PrefixCodes.build(counts);
      final used = [
        for (var i = 0; i < counts.length; i++)
          if (counts[i] > 0) i,
      ];
      final writer = encoder.BitWriter();
      codes.describe(writer);
      for (final symbol in used) {
        codes.put(writer, symbol);
      }
      writer.bits(0x2A5, 10);
      final reader = BitReader(writer.finish());
      final code = readPrefixCode(reader, counts.length);
      expect([for (final _ in used) code.read(reader)], used, reason: reason);
      expect(reader.bits(10), 0x2A5, reason: '$reason: trailing bits');
    }

    test('writes prefix codes the decoder reads back', () {
      final random = Random(19);
      for (final alphabet in [26, 64, 256, 704]) {
        for (var round = 0; round < 40; round++) {
          final density = random.nextInt(4) + 1;
          final counts = [
            for (var i = 0; i < alphabet; i++)
              random.nextInt(density + 1) == 0 ? 0 : 1 << random.nextInt(16),
          ];
          expectReadBack(counts, 'alphabet $alphabet round $round');
        }
      }
    });

    // The shortest codes go to the largest symbols, so the simple codes must
    // list symbols by length rather than by value.
    test('writes small and degenerate prefix codes', () {
      for (final (name, counts) in [
        ('no symbol', List.filled(64, 0)),
        ('one symbol', List.filled(256, 0)..[200] = 9),
        (
          'two symbols',
          List.filled(26, 0)
            ..[3] = 1
            ..[25] = 5,
        ),
        (
          'three symbols',
          List.filled(704, 0)
            ..[0] = 1
            ..[1] = 1
            ..[700] = 9,
        ),
        (
          'four equal',
          List.filled(256, 0)
            ..[1] = 1
            ..[2] = 1
            ..[3] = 1
            ..[4] = 1,
        ),
        (
          'four skewed',
          List.filled(256, 0)
            ..[1] = 1
            ..[2] = 1
            ..[3] = 4
            ..[4] = 8,
        ),
        ('all equal', List.filled(256, 1)),
        // Zero runs of exactly 11 and repeats of exactly 7 take special paths.
        ('zero run of 11', [for (var i = 0; i < 64; i++) i % 12 == 0 ? 1 : 0]),
        (
          'repeat of 7',
          [for (var i = 0; i < 64; i++) i < 8 ? 4 : (i < 40 ? 1 : 0)],
        ),
      ]) {
        expectReadBack(counts, name);
      }
    });

    test('rewinds the bit writer', () {
      final writer = encoder.BitWriter(16)..bits(0x5, 3);
      final mark = writer.position;
      writer.bits(0xFFFFFF, 24);
      writer.bits(0x3, 2);
      writer.rewind(mark);
      writer.bits(0x1, 1);
      expect(writer.finish(), [0xD]);
      final partial = encoder.BitWriter()..bits(0x3, 2);
      partial
        ..rewind(1)
        ..bits(0, 1);
      expect(partial.finish(), [0x1]);
    });

    test('is no larger than GZIP on text at the default level', () {
      for (final path in [
        'canterbury/alice29.txt',
        'calgary/book1',
        'html',
        'geo.protodata',
        'canterbury/kennedy.xls',
      ]) {
        final data = readDataFixture(path);
        expect(
          BrotliCodec().compress(data).length,
          lessThanOrEqualTo(GzipCodec().compress(data).length),
          reason: path,
        );
      }
    });

    test('falls back to uncompressed meta-blocks on random data', () {
      final data = pseudoRandom(100000);
      expect(BrotliCodec().compress(data).length, lessThan(data.length + 16));
    });

    test('rebases match positions without changing output across splits', () {
      // With a 2 MB threshold, 9 MB of input rebases several times. The
      // streaming encoder must still give the block encoder's bytes for any
      // split, and the output must decode.
      final text = readDataFixture('canterbury/alice29.txt');
      final data = Uint8List(9 << 20);
      for (var i = 0; i < data.length; i += text.length) {
        final count = data.length - i < text.length
            ? data.length - i
            : text.length;
        data.setRange(i, i + count, text);
        data[i] = i & 0xFF; // vary each copy a little
      }
      for (final (level, window) in [(1, 16), (6, 20)]) {
        final block = BrotliEncoder(
          level: level,
          window: window,
          rebase: 1 << 21,
        ).compress(data);
        expect(BrotliCodec().decompress(block), orderedEquals(data));
        for (final size in [1 << 20, (3 << 20) + 7, 100003]) {
          final encoder = StreamingBrotliEncoder(
            level: level,
            window: window,
            rebase: 1 << 21,
          );
          final out = BytesBuilder(copy: false)..add(encoder.header());
          for (var i = 0; i < data.length; i += size) {
            final end = i + size < data.length ? i + size : data.length;
            out.add(encoder.addChunk(Uint8List.sublistView(data, i, end)));
          }
          out.add(encoder.finish());
          expect(
            out.takeBytes(),
            orderedEquals(block),
            reason: 'level $level window $window, $size-byte chunks',
          );
        }
      }
    });

    test(
      'streams over 1 GiB the same however the input is split',
      () async {
        final text = readDataFixture('canterbury/alice29.txt');
        final data = Uint8List((1 << 30) + (8 << 20));
        for (var i = 0; i < data.length; i += text.length) {
          final count = data.length - i < text.length
              ? data.length - i
              : text.length;
          data.setRange(i, i + count, text);
        }
        Future<(int, int)> stream(final int size) async {
          var crc = 0xFFFFFFFF;
          var length = 0;
          await BrotliStreamCodec(level: 1, window: 16)
              .compress(
                Stream.fromIterable([
                  for (var i = 0; i < data.length; i += size)
                    Uint8List.sublistView(
                      data,
                      i,
                      i + size < data.length ? i + size : data.length,
                    ),
                ]),
              )
              .forEach((final chunk) {
                crc = Crc32.update(chunk, crc);
                length += chunk.length;
              });
          return (length, crc ^ 0xFFFFFFFF);
        }

        final block = BrotliCodec(level: 1, window: 16).compress(data);
        final expected = (block.length, Crc32.hash(block));
        expect(await stream(1 << 20), expected);
        expect(await stream((3 << 20) + 7), expected);
      },
      timeout: const Timeout(Duration(minutes: 10)),
      skip: Platform.environment['RUN_LARGE'] == '1'
          ? false
          : 'set RUN_LARGE=1 to run large tests',
    );

    test('returns output that does not hold the whole encode buffer', () {
      // 1 MB of repeated text compresses to a few KB; the encoder's buffer
      // starts at half the input.
      final data = bytes(
        List.generate(
          1 << 20,
          (final i) => 'the quick brown fox '.codeUnitAt(i % 20),
        ),
      );
      final compressed = BrotliCodec().compress(data);
      expect(
        compressed.buffer.lengthInBytes,
        lessThanOrEqualTo(2 * compressed.length),
      );
    });

    test('compresses deterministically', () {
      final data = readDataFixture('html');
      expect(BrotliCodec().compress(data), BrotliCodec().compress(data));
    });
  });

  group('Brotli bit reader', () {
    test('reads least significant bits first', () {
      final reader = BitReader(bytes([0xB4, 0x01]));
      expect(reader.bits(2), 0);
      expect(reader.bits(3), 5);
      expect(reader.bits(4), 0xD);
      expect(reader.position, 9);
      expect(reader.align(), 0);
      expect(reader.done, isTrue);
    });

    test('reads 24-bit fields across bytes', () {
      final reader = BitReader(bytes([0xFF, 0x12, 0x34, 0x56, 0x78]));
      expect(reader.bits(4), 0xF);
      expect(reader.bits(24), 0x63412F);
      expect(reader.bits(12), 0x785);
      expect(reader.done, isTrue);
    });

    test('copies and discards bytes at a boundary', () {
      final reader = BitReader(bytes(List.generate(40, (final i) => i)));
      expect(reader.bits(8), 0);
      final target = Uint8List(10);
      reader.copy(target, 0, 10);
      expect(target, orderedEquals(List.generate(10, (final i) => i + 1)));
      reader.discard(20);
      expect(reader.bits(8), 31);
      expect(() => reader.discard(9), throwsStateError);
    });

    test('signals exhausted input with StateError', () {
      final reader = BitReader(bytes([0xFF]));
      expect(reader.bits(6), 0x3F);
      expect(() => reader.bits(3), throwsStateError);
    });
  });
}
