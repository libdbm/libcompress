import 'dart:typed_data';

/// Variable-length integer encoding utilities
///
/// Implements Protocol Buffers-style varint encoding where integers are
/// encoded using 7 bits per byte, with the high bit indicating continuation.
///
/// Used by Snappy for encoding uncompressed lengths. Can be used by other
/// codecs that need compact integer representation.
class Varint {
  /// Encodes an unsigned integer as a varint
  ///
  /// Returns a list of bytes representing the varint encoding.
  /// Smaller values use fewer bytes:
  /// - 0-127: 1 byte
  /// - 128-16383: 2 bytes
  /// - etc.
  ///
  /// Example:
  /// ```dart
  /// Varint.encode(300);  // Returns [0xAC, 0x02]
  /// ```
  static List<int> encode(int value) {
    if (value < 0) {
      throw ArgumentError('Value must be non-negative');
    }

    final bytes = <int>[];

    while (value > 127) {
      bytes.add(0x80 | (value & 0x7f));
      value >>= 7;
    }
    bytes.add(value);

    return bytes;
  }

  /// Encodes an unsigned integer as a varint into an existing buffer
  ///
  /// Appends the varint-encoded bytes to [output].
  /// Returns the number of bytes written.
  static int encodeInto(List<int> output, int value) {
    if (value < 0) {
      throw ArgumentError('Value must be non-negative');
    }

    var count = 0;

    while (value > 127) {
      output.add(0x80 | (value & 0x7f));
      value >>= 7;
      count++;
    }
    output.add(value);
    count++;

    return count;
  }

  /// Decodes a varint from a byte array
  ///
  /// Reads from [data] starting at [offset] and returns a [VarintResult]
  /// containing the decoded value and the number of bytes consumed.
  ///
  /// Throws FormatException if the varint is invalid (e.g., too many continuation bytes).
  ///
  /// Example:
  /// ```dart
  /// final data = Uint8List.fromList([0xAC, 0x02]);
  /// final result = Varint.decode(data, 0);
  /// print(result.value);  // 300
  /// print(result.bytesRead);  // 2
  /// ```
  /// [maxBytes] caps the encoding length (e.g. 5 for a 32-bit Snappy preamble),
  /// rejecting over-long varints. Accumulation uses multiplication rather than
  /// `<< shift`, so the result is exact and non-negative on both the VM and
  /// dart2js (a shifted value past bit 31 would wrap/sign on JS, yielding a
  /// negative size that could slip past a bounds check).
  static VarintResult decode(Uint8List data, int offset, {int maxBytes = 10}) {
    var value = 0;
    var multiplier = 1;
    var bytesRead = 0;

    while (true) {
      if (offset + bytesRead >= data.length) {
        throw FormatException('Incomplete varint at offset $offset');
      }

      if (bytesRead >= maxBytes) {
        throw FormatException('Varint too long at offset $offset');
      }

      final byte = data[offset + bytesRead];
      bytesRead++;

      value += (byte & 0x7f) * multiplier;

      if ((byte & 0x80) == 0) {
        // No continuation bit, we're done
        return VarintResult(value, bytesRead);
      }

      multiplier *= 128;
    }
  }

  /// Decodes a varint and returns only the value
  ///
  /// Convenience method when you don't need to know how many bytes were consumed.
  /// Starts reading from [offset] in [data].
  static int decodeValue(Uint8List data, int offset) {
    return decode(data, offset).value;
  }

  /// Calculates the encoded size of a value without actually encoding it
  ///
  /// Returns the number of bytes that would be used to encode [value].
  static int encodedSize(int value) {
    if (value < 0) {
      throw ArgumentError('Value must be non-negative');
    }

    var size = 1;
    while (value > 127) {
      value >>= 7;
      size++;
    }
    return size;
  }
}

/// Result of decoding a varint
class VarintResult {
  /// The decoded integer value
  final int value;

  /// The number of bytes consumed from the input
  final int bytesRead;

  const VarintResult(this.value, this.bytesRead);

  @override
  String toString() => 'VarintResult(value: $value, bytesRead: $bytesRead)';
}
