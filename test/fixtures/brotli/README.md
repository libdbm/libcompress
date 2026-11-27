# Brotli fixtures

Made with the reference tool, `brotli` 1.2.1 (Homebrew), from the files of the
same name under `test/fixtures/data/`:

| Name | Command |
|------|---------|
| `<file>.q<N>.br` | `brotli -q <N> -c <file>` (default window, 22) |
| `<file>.q<N>.w<W>.br` | `brotli -q <N> -w <W> -c <file>` |

Qualities 0, 1, 5, 9 and 11 are used for every file except
`artificial/random.txt` (0 and 11 only). Windows 10, 16 and 24 are used for
`html` (qualities 1 and 9) and `canterbury/alice29.txt` (quality 9).
Every file was checked with `brotli -t`.
