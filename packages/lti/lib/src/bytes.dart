import 'dart:typed_data';

/// Collects a byte stream without buffering more than [maxBytes].
///
/// Throws [FormatException] and cancels the subscription when a chunk would
/// exceed the limit. Chunks are copied because a producer may reuse its buffers.
/// The caller retains responsibility for request deadlines and transport aborts.
/// Internal transport helper; not exported from the package entry point.
Future<Uint8List> readBoundedBytes(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  final bytes = BytesBuilder();
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Response exceeds byte limit.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
