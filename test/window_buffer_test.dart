import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/growable_buffer.dart';
import 'package:libcompress/src/util/window_buffer.dart';

void main() {
  group('WindowBuffer', () {
    // Replays a randomized append/back-reference op stream against both a
    // full GrowableBuffer (reference) and a windowed WindowBuffer (drained
    // periodically), and asserts the reconstructed output is identical.
    test('matches GrowableBuffer output with periodic draining', () {
      const window = 256;
      final random = Random(7);

      for (var trial = 0; trial < 50; trial++) {
        final reference = GrowableBuffer();
        final windowed = WindowBuffer(window);
        final drained = <int>[];

        var produced = 0;
        final ops = 200 + random.nextInt(200);
        for (var i = 0; i < ops; i++) {
          final roll = random.nextInt(10);
          if (produced == 0 || roll < 5) {
            // Append a literal run.
            final n = 1 + random.nextInt(20);
            final bytes = Uint8List.fromList(
              List.generate(n, (_) => random.nextInt(256)),
            );
            reference.addBytes(bytes);
            windowed.addBytes(bytes);
            produced += n;
          } else {
            // Back-reference within the window (and within produced bytes).
            final maxDistance = min(window, produced);
            final distance = 1 + random.nextInt(maxDistance);
            final length = 1 + random.nextInt(30); // may exceed distance (overlap)
            reference.copyFromHistory(distance, length);
            windowed.copyFromHistory(distance, length);
            produced += length;
          }

          if (random.nextInt(4) == 0) {
            drained.addAll(windowed.drain());
          }
        }
        drained.addAll(windowed.finish());

        expect(windowed.length, equals(reference.length));
        expect(
          drained,
          orderedEquals(reference.toBytes()),
          reason: 'trial $trial',
        );
      }
    });

    test('drain keeps the last `window` bytes referenceable', () {
      final buffer = WindowBuffer(4);
      buffer.addBytes(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      final first = buffer.drain(); // emits older-than-window prefix
      expect(first, orderedEquals([1, 2, 3, 4]));
      // The retained window is [5,6,7,8]; a distance-4 back-ref must still work.
      buffer.copyFromHistory(4, 4); // copies 5,6,7,8
      final rest = [...buffer.drain(), ...buffer.finish()];
      expect([...first, ...rest], orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 5, 6, 7, 8]));
    });

    test('enforces maxSize backstop', () {
      final buffer = WindowBuffer(8, maxSize: 10);
      expect(
        () => buffer.addBytes(Uint8List(11)),
        throwsStateError,
      );
    });

    test('rejects back-reference beyond retained window', () {
      final buffer = WindowBuffer(4);
      buffer.addBytes(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      buffer.drain(); // retains only last 4
      expect(() => buffer.copyFromHistory(5, 1), throwsArgumentError);
    });
  });
}
