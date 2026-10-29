/// Whether ints are 64-bit, as on the VM. dart2js has 32-bit bitwise
/// operations, 53-bit integers and no 64-bit `ByteData` access, so code that
/// relies on any of them keeps a path for the web.
final bool wide = !identical(1, 1.0);
