import 'dart:typed_data';

import 'crc_tables.dart';

/// CRC32 checksum implementation for data integrity verification
///
/// Implements the CRC-32 algorithm used in GZIP, ZIP, PNG, and other formats.
/// Uses the IEEE 802.3 polynomial: 0xEDB88320 (reversed).
class Crc32 {
  static final CrcTables _tables = CrcTables(0xEDB88320);

  /// Computes CRC32 checksum of the given data
  ///
  /// Returns a 32-bit unsigned integer checksum. The same input will always
  /// produce the same checksum. Different inputs are highly likely to produce
  /// different checksums.
  ///
  /// Example:
  /// ```dart
  /// final data = Uint8List.fromList([1, 2, 3, 4, 5]);
  /// final checksum = Crc32.hash(data);
  /// print('CRC32: 0x${checksum.toRadixString(16)}');
  /// ```
  static int hash(final Uint8List data, [final int crc = 0xFFFFFFFF]) =>
      _tables.update(data, crc) ^ 0xFFFFFFFF;

  /// Computes CRC32 checksum from a `List<int>`
  ///
  /// Convenience method for lists that aren't already `Uint8List`.
  /// Values outside 0-255 range are masked to the lower 8 bits.
  static int hashFromList(final List<int> data, [final int crc = 0xFFFFFFFF]) =>
      _tables.updateList(data, crc) ^ 0xFFFFFFFF;

  /// Updates CRC32 checksum incrementally
  ///
  /// Allows computing CRC32 over multiple chunks of data without
  /// concatenating them. Pass the previous CRC value (or 0xFFFFFFFF
  /// for the first chunk) and get the updated value.
  ///
  /// Example:
  /// ```dart
  /// var crc = 0xFFFFFFFF;
  /// crc = Crc32.update(chunk1, crc);
  /// crc = Crc32.update(chunk2, crc);
  /// final final_crc = crc ^ 0xFFFFFFFF;
  /// ```
  static int update(final Uint8List data, final int crc) =>
      _tables.update(data, crc);
}
