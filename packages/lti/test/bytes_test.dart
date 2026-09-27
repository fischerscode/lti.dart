import 'dart:async';

import 'package:lti/src/bytes.dart';
import 'package:test/test.dart';

void main() {
  test('accepts chunks totaling exactly the byte limit', () async {
    expect(
      await readBoundedBytes(
        Stream.fromIterable([
          [1, 2],
          <int>[],
          [3],
        ]),
        maxBytes: 3,
      ),
      [1, 2, 3],
    );
  });

  test('cancels the stream when accumulated chunks exceed the limit', () async {
    var cancelled = false;
    final controller = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final result = readBoundedBytes(controller.stream, maxBytes: 3);
    final assertion = expectLater(result, throwsFormatException);
    controller
      ..add([1, 2])
      ..add([3, 4]);
    await assertion;
    expect(cancelled, isTrue);
    await controller.close();
  });

  test('copies chunks when the producer reuses its buffer', () async {
    Stream<List<int>> reusedBuffer() async* {
      final buffer = [1, 2];
      yield buffer;
      buffer[0] = 3;
      yield buffer;
    }

    expect(await readBoundedBytes(reusedBuffer(), maxBytes: 4), [1, 2, 3, 2]);
  });
}
