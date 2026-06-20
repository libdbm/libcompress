import 'package:test/test.dart';
import 'package:libcompress/src/util/byte_utils.dart';

void main() {
  group('ByteUtils.mul32', () {
    int reference(final int a, final int b) =>
        (BigInt.from(a) * BigInt.from(b) & BigInt.from(0xFFFFFFFF)).toInt();

    test('matches BigInt low-32 reference across the 32-bit range', () {
      const multipliers = [2654435761, 0x1e35a7bd, 1, 0xFFFFFFFF];
      const samples = [
        0,
        1,
        0xFFFF,
        0x10000,
        0x7FFFFFFF,
        0x80000000,
        0xFFFFFFFF,
        0x12345678,
        0x9E3779B1,
        0xDEADBEEF,
      ];
      for (final b in multipliers) {
        for (final a in samples) {
          expect(
            ByteUtils.mul32(a, b),
            equals(reference(a, b)),
            reason: 'mul32(0x${a.toRadixString(16)}, 0x${b.toRadixString(16)})',
          );
        }
      }
    });

    test('result is always within unsigned 32-bit range', () {
      for (final a in [0, 0x80000000, 0xFFFFFFFF, 0x13572468]) {
        final r = ByteUtils.mul32(a, 2654435761);
        expect(r, inInclusiveRange(0, 0xFFFFFFFF));
      }
    });
  });
}
