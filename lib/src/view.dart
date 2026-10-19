import 'package:flutter/widgets.dart';

import 'controller.dart';

/// Renders the camera preview for [controller].
///
/// Shows black until the controller has a texture (see
/// [InstantBarcodeScanner.warmUp]). The preview has no orientation or
/// aspect-ratio correction yet; full-bleed cover behavior comes later.
class InstantBarcodeScannerView extends StatelessWidget {
  const InstantBarcodeScannerView({super.key, required this.controller});

  final InstantBarcodeScanner controller;

  static const Color _background = Color(0xFF000000);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: controller.textureId,
      builder: (context, id, _) {
        if (id == null) {
          return const ColoredBox(color: _background);
        }
        return ColoredBox(
          color: _background,
          child: Texture(textureId: id, filterQuality: FilterQuality.low),
        );
      },
    );
  }
}
