import 'dart:typed_data';

import 'crc_tables.dart';

/// CRC32C (Castagnoli) checksum implementation
///
/// Implements the CRC-32C algorithm using the Castagnoli polynomial (0x82F63B78).
/// Used by Snappy framing format and other modern protocols.
///
/// The Castagnoli polynomial has better error detection properties for small
/// messages compared to the IEEE polynomial used in standard CRC32.
class Crc32c {
  static final CrcTables _tables = CrcTables(0x82F63B78);

  /// Computes CRC32C checksum of the given data
  ///
  /// Returns a 32-bit unsigned integer checksum. The same input will always
  /// produce the same checksum.
  ///
  /// Example:
  /// ```dart
  /// final data = Uint8List.fromList([1, 2, 3, 4, 5]);
  /// final checksum = Crc32c.hash(data);
  /// print('CRC32C: 0x${checksum.toRadixString(16)}');
  /// ```
  static int hash(final Uint8List data, [final int crc = 0xFFFFFFFF]) =>
      _tables.update(data, crc) ^ 0xFFFFFFFF;

  /// Computes CRC32C checksum from a `List<int>`
  ///
  /// Convenience method for lists that aren't already `Uint8List`.
  /// Values outside 0-255 range are masked to the lower 8 bits.
  static int hashFromList(final List<int> data, [final int crc = 0xFFFFFFFF]) =>
      _tables.updateList(data, crc) ^ 0xFFFFFFFF;

  /// Updates CRC32C checksum incrementally
  ///
  /// Allows computing CRC32C over multiple chunks of data without
  /// concatenating them. Pass the previous CRC value (or 0xFFFFFFFF
  /// for the first chunk) and get the updated value.
  ///
  /// Example:
  /// ```dart
  /// var crc = 0xFFFFFFFF;
  /// crc = Crc32c.update(chunk1, crc);
  /// crc = Crc32c.update(chunk2, crc);
  /// final checksum = crc ^ 0xFFFFFFFF;
  /// ```
  static int update(final Uint8List data, final int crc) =>
      _tables.update(data, crc);

  /// Masks the CRC32C checksum for Snappy framing format compatibility
  ///
  /// The Snappy framing format uses a "masked" CRC to avoid issues with
  /// CRC values that happen to look like frame markers.
  ///
  /// To unmask, use [unmask].
  static int mask(final int crc) {
    // 32-bit rotate-right-by-15, via multiplication so the result is exact and
    // non-negative on both the VM and dart2js (`crc << 17` would sign/truncate
    // on JS). Equivalent to ((crc >> 15) | (crc << 17)) on a uint32.
    final c = crc % 0x100000000;
    final rotated = (c ~/ 0x8000) + (c % 0x8000) * 0x20000;
    return (rotated + 0xa282ead8) % 0x100000000;
  }

  /// Unmasks a masked CRC32C checksum
  ///
  /// Reverses the masking applied by [mask].
  static int unmask(final int masked) {
    final rot = (masked - 0xa282ead8) % 0x100000000;
    // 32-bit rotate-left-by-15 (inverse of [mask]).
    return (rot ~/ 0x20000) + (rot % 0x20000) * 0x8000;
  }
}
