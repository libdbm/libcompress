import 'dart:typed_data';

/// The decode cap when the caller expects exactly [size] output bytes: the
/// smaller of [size] and the codec's [limit] (null means unlimited), so a
/// stream that runs past [size] stops at it instead of at [limit].
int? capFor(final int? limit, final int? size) {
  if (size == null) return limit;
  if (size < 0) {
    throw ArgumentError.value(size, 'size', 'Must not be negative');
  }
  return limit == null || size < limit ? size : limit;
}

/// Returns [output], or throws the error built by [wrap] when [size] is given
/// and [output] has a different length.
Uint8List checkSize(
  final Uint8List output,
  final int? size,
  final Object Function(String message) wrap,
) {
  if (size != null && output.length != size) {
    throw wrap('Decompressed size ${output.length} != expected size $size');
  }
  return output;
}
