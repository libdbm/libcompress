# Parquet LZ4 fixtures

Copied unchanged from [apache/parquet-testing](https://github.com/apache/parquet-testing/tree/master/data)
(Apache License 2.0):

| File | Writer | Codec |
|------|--------|-------|
| `hadoop_lz4_compressed.parquet` | parquet-mr 1.10.1 | `LZ4` (Hadoop block framing) |
| `hadoop_lz4_compressed_larger.parquet` | parquet-mr 1.11.1 | `LZ4` (Hadoop block framing) |
| `lz4_raw_compressed.parquet` | parquet-cpp 1.5.1 | `LZ4_RAW` |
| `lz4_raw_compressed_larger.parquet` | parquet-cpp 1.5.1 | `LZ4_RAW` |
| `non_hadoop_lz4_compressed.parquet` | parquet-cpp 1.5.1 | `LZ4`, written as bare blocks without Hadoop framing |

The expected page sizes and CRC-32s in `test/lz4_codec_test.dart` come from decoding each page with the LZ4
reference library (python `lz4.block`).
