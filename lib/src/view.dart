import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'platform/types.dart' show PreviewMetrics;

/// Renders the camera preview for [controller].
///
/// The preview is rotated upright and aspect-corrected from the platform's
/// [InstantBarcodeScanner.previewMetrics]; [fit] controls how it fills the
/// widget (`BoxFit.cover` by default). [overlayBuilder] is painted on top of
/// both the preview and the placeholder, and [placeholderBuilder] replaces
/// the default black frame until the texture exists.
class InstantBarcodeScannerView extends StatelessWidget {
  const InstantBarcodeScannerView({
    super.key,
    required this.controller,
    this.fit = BoxFit.cover,
    this.overlayBuilder,
    this.placeholderBuilder,
  });

  final InstantBarcodeScanner controller;

  /// How the upright preview fills the widget.
  final BoxFit fit;

  /// Painted over the preview (for reticles, hints, scan-window frames…).
  final WidgetBuilder? overlayBuilder;

  /// Shown until the texture exists. Defaults to black.
  final WidgetBuilder? placeholderBuilder;

  static const Color _background = Color(0xFF000000);

  @override
  Widget build(BuildContext context) {
    final overlay = overlayBuilder?.call(context);
    final placeholder =
        placeholderBuilder?.call(context) ??
        const ColoredBox(color: _background);

    return ValueListenableBuilder<int?>(
      valueListenable: controller.textureId,
      builder: (context, id, _) {
        Widget content = SizedBox.expand(
          child: id == null
              ? placeholder
              : ValueListenableBuilder<PreviewMetrics?>(
                  valueListenable: controller.previewMetrics,
                  builder: (context, metrics, _) {
                    return ColoredBox(
                      color: _background,
                      child: _preview(id, metrics),
                    );
                  },
                ),
        );
        if (overlay != null) {
          content = Stack(fit: StackFit.expand, children: [content, overlay]);
        }
        return content;
      },
    );
  }

  Widget _preview(int id, PreviewMetrics? metrics) {
    final texture = Texture(textureId: id, filterQuality: FilterQuality.low);
    if (metrics == null ||
        metrics.size.isEmpty ||
        metrics.rotationDegrees % 90 != 0) {
      return texture;
    }
    final turns = (metrics.rotationDegrees ~/ 90) % 4;
    Widget frame = SizedBox(
      width: metrics.size.width,
      height: metrics.size.height,
      child: texture,
    );
    if (turns != 0) {
      frame = RotatedBox(quarterTurns: turns, child: frame);
    }
    if (metrics.mirrored) {
      frame = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: frame,
      );
    }
    return ClipRect(
      child: FittedBox(fit: fit, clipBehavior: Clip.hardEdge, child: frame),
    );
  }
}
