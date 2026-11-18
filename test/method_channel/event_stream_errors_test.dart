import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/src/method_channel/mobile_scanner_method_channel.dart';
import 'package:mobile_scanner/src/mobile_scanner_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('barcode error events', () {
    late MethodChannelMobileScanner platform;

    setUp(() {
      platform = MethodChannelMobileScanner();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            platform.eventChannel,
            MockStreamHandler.inline(
              onListen:
                  (_, events) => events.error(
                    code: MethodChannelMobileScanner.kBarcodeErrorEventName,
                    message: 'Waiting for the barcode module to be downloaded.',
                  ),
            ),
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(platform.eventChannel, null);
    });

    test(
      'do not surface on the torch, zoom, or scene luminance streams',
      () async {
        final uncaught = <Object>[];

        await runZonedGuarded(() async {
          final torch = platform.torchStateStream.listen((_) {});
          final zoom = platform.zoomScaleStateStream.listen((_) {});
          final luminance = platform.sceneLuminanceStream.listen((_) {});
          await pumpEventQueue();
          await torch.cancel();
          await zoom.cancel();
          await luminance.cancel();
        }, (error, _) => uncaught.add(error));

        expect(uncaught, isEmpty);
      },
    );

    test('still reach the barcodes stream', () async {
      await expectLater(
        platform.barcodesStream,
        emitsError(isA<MobileScannerBarcodeException>()),
      );
    });
  });
}
