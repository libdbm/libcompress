/// XXH64 hash ([XXH64]) and incremental sink ([Xxh64Sink]).
///
/// Native platforms use wrapping 64-bit `int` arithmetic; JavaScript, which
/// lacks 64-bit integers, uses a [BigInt] implementation with the same API.
library;

export 'xxh64_web.dart' if (dart.library.io) 'xxh64_native.dart';
