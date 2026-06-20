import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/byte_pending.dart';

Uint8List _b(final List<int> v) => Uint8List.fromList(v);

void main() {
  group('BytePending', () {
    test('append, index, slice, length', () {
      final p = BytePending(4);
      p.add(_b([1, 2, 3]));
      p.add(_b([4, 5, 6, 7]));
      expect(p.length, 7);
      expect([for (var i = 0; i < p.length; i++) p[i]], [1, 2, 3, 4, 5, 6, 7]);
      expect(p.slice(2, 5), orderedEquals([3, 4, 5]));
    });

    test('discard shifts the remainder to the front', () {
      final p = BytePending();
      p.add(_b([1, 2, 3, 4, 5]));
      p.discard(2);
      expect(p.length, 3);
      expect([for (var i = 0; i < p.length; i++) p[i]], [3, 4, 5]);
      p.add(_b([6, 7]));
      expect([for (var i = 0; i < p.length; i++) p[i]], [3, 4, 5, 6, 7]);
    });

    test('bytes backing matches valid range and grows correctly', () {
      final p = BytePending(2);
      final expected = <int>[];
      final random = Random(3);
      for (var i = 0; i < 200; i++) {
        final n = random.nextInt(20);
        final chunk = _b(List.generate(n, (_) => random.nextInt(256)));
        p.add(chunk);
        expected.addAll(chunk);
        if (random.nextBool() && expected.length > 5) {
          final d = random.nextInt(5);
          p.discard(d);
          expected.removeRange(0, d);
        }
      }
      expect(p.length, expected.length);
      expect(Uint8List.sublistView(p.bytes, 0, p.length), orderedEquals(expected));
    });
  });
}
