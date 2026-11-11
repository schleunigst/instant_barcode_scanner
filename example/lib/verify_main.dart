// Hardware verification app for the S10 rotation / scan-window checks.
//
// Build:
//   flutter build apk --debug \
//     --target lib/verify_main.dart --target-platform android-arm64
//
// Three screens, switched from the bottom bar:
//   1. Back  — landscape/portrait orientation check on the rear camera.
//   2. Front — mirror + orientation check on the front camera.
//   3. Window — scan-window filtering (full vs. offset windows).
//
// The camera is kept `live` the whole time (30-minute idle policy) so the
// preview streams continuously while you rotate the phone and swap windows.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

void main() {
  runApp(const VerifyApp());
}

class VerifyApp extends StatelessWidget {
  const VerifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scanner verification',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const VerifyHome(),
    );
  }
}

class VerifyHome extends StatefulWidget {
  const VerifyHome({super.key});

  @override
  State<VerifyHome> createState() => _VerifyHomeState();
}

class _VerifyHomeState extends State<VerifyHome> {
  late final InstantBarcodeScanner _scanner;
  StreamSubscription<ScanResult>? _sub;

  int _tab = 0;
  bool _ready = false;
  String _error = '';
  CameraFacing _facing = CameraFacing.back;
  Rect? _window;
  final List<String> _log = [];
  int _decoded = 0;
  bool _loopRunning = false;

  @override
  void initState() {
    super.initState();
    _scanner = InstantBarcodeScanner(
      policy: const ScannerPolicy(
        parkAfter: Duration(minutes: 30),
        closeAfter: Duration(minutes: 30),
      ),
    );
    _sub = _scanner.scans.listen(_onResult);
    _boot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_scanner.dispose());
    super.dispose();
  }

  Future<void> _boot() async {
    // The plugin owns the CAMERA prompt; this screen does not request it.
    try {
      await _scanner.warmUp();
      if (!mounted) return;
      setState(() => _ready = true);
      _startKeepLive();
    } catch (e) {
      if (mounted) setState(() => _error = 'boot failed: $e');
    }
  }

  void _startKeepLive() {
    if (_loopRunning) return;
    _loopRunning = true;
    unawaited(_keepLive());
  }

  // Keeps the camera streaming so orientation/mirror/window checks see a live
  // image. The 30-minute idle policy means `live` never auto-parks mid-check.
  Future<void> _keepLive() async {
    while (mounted) {
      try {
        await _scanner.scan(timeout: const Duration(seconds: 5));
      } catch (_) {
        // Timeout or a cancelled scan: re-issue to stay live.
      }
    }
  }

  void _onResult(ScanResult result) {
    if (!mounted) return;
    setState(() {
      _decoded++;
      _log.insert(
        0,
        '$_decoded: ${result.text ?? _hex(result.rawBytes)} '
        '(${result.format.name})${_window != null ? '  [window]' : ''}',
      );
      if (_log.length > 40) _log.removeLast();
    });
  }

  void _logMessage(String message) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, message);
      if (_log.length > 40) _log.removeLast();
    });
  }

  Future<void> _setFacing(CameraFacing facing) async {
    try {
      await _scanner.switchCamera(facing: facing);
      if (mounted) setState(() => _facing = facing);
    } catch (e) {
      _logMessage('switchCamera($facing) failed: $e');
    }
  }

  Future<void> _setWindow(Rect? window) async {
    setState(() => _window = window);
    try {
      await _scanner.updateScanWindow(window);
      _logMessage(
        window == null
            ? 'scan window cleared (decode everywhere)'
            : 'window set: ${window.left.toStringAsFixed(2)},'
                  '${window.top.toStringAsFixed(2)} → '
                  '${window.right.toStringAsFixed(2)},'
                  '${window.bottom.toStringAsFixed(2)}',
      );
    } catch (e) {
      _logMessage('updateScanWindow failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner verification'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                _facing == CameraFacing.back ? 'BACK' : 'FRONT',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(scanner: _scanner),
          Expanded(child: _buildBody()),
          _buildControls(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.crop_portrait), label: 'Back'),
          NavigationDestination(icon: Icon(Icons.face), label: 'Front'),
          NavigationDestination(icon: Icon(Icons.crop_free), label: 'Window'),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error, style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    switch (_tab) {
      case 0:
        return _orientationBody(mirrorHint: false);
      case 1:
        return _orientationBody(mirrorHint: true);
      default:
        return _windowBody();
    }
  }

  // A live preview with a fixed screen-space compass overlay. The compass is
  // always drawn upright in the UI, so whatever the camera sees should align
  // with it: the test card's TOP belongs at the TOP marker in every rotation.
  Widget _orientationBody({required bool mirrorHint}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InstantBarcodeScannerView(
          controller: _scanner,
          fit: BoxFit.cover,
          placeholderBuilder: (context) => const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
        IgnorePointer(child: _compass(mirrorHint: mirrorHint)),
      ],
    );
  }

  Widget _compass({required bool mirrorHint}) {
    final label = TextStyle(
      color: Colors.white,
      fontSize: 18,
      fontWeight: FontWeight.bold,
      shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
    );
    return Column(
      children: [
        Expanded(
          child: Center(
            child: mirrorHint
                ? const Text(
                    'FRONT CAMERA CHECK\n'
                    'Point at some text or a QR code.\n'
                    'Text should read NORMALLY (un-mirrored),\n'
                    'matching mobile_scanner and other scanners.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_upward,
                        color: Colors.red,
                        size: 40,
                      ),
                      Text('TOP', style: label),
                    ],
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('LEFT', style: label),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!mirrorHint) ...[
                    const Icon(
                      Icons.arrow_downward,
                      color: Colors.red,
                      size: 30,
                    ),
                    Text('BOTTOM', style: label),
                  ],
                ],
              ),
              Text('RIGHT', style: label),
            ],
          ),
        ),
      ],
    );
  }

  Widget _windowBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        InstantBarcodeScannerView(
          controller: _scanner,
          fit: BoxFit.cover,
          overlayBuilder: (context) => IgnorePointer(
            child: SizedBox.expand(
              child: CustomPaint(painter: _WindowPainter(_window)),
            ),
          ),
          placeholderBuilder: (context) => const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 180),
            color: Colors.black54,
            padding: const EdgeInsets.all(8),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Text(
                  'decoded: $_decoded${_window != null ? '  (window active)' : '  (full frame)'}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                for (final line in _log.take(12))
                  Text(
                    line,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    if (!_ready) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('requesting permission…'),
      );
    }
    switch (_tab) {
      case 0:
      case 1:
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => _setFacing(CameraFacing.back),
                child: const Text('Back camera'),
              ),
              FilledButton(
                onPressed: () => _setFacing(CameraFacing.front),
                child: const Text('Front camera'),
              ),
            ],
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => _setWindow(null),
                child: const Text('Full frame'),
              ),
              FilledButton(
                onPressed: () =>
                    _setWindow(const Rect.fromLTRB(0.35, 0.35, 0.65, 0.65)),
                child: const Text('Center 30%'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _setWindow(const Rect.fromLTRB(0, 0, 0.5, 0.5)),
                child: const Text('Top-left half'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _setWindow(const Rect.fromLTRB(0.5, 0.5, 1, 1)),
                child: const Text('Bottom-right half'),
              ),
            ],
          ),
        );
    }
  }

  String _hex(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return '<no bytes>';
    final head = bytes.take(8);
    return head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.scanner});

  final InstantBarcodeScanner scanner;

  @override
  Widget build(BuildContext context) {
    final style = const TextStyle(color: Colors.white, fontSize: 12);
    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: ValueListenableBuilder<ScannerStatus>(
              valueListenable: scanner.status,
              builder: (context, status, _) => Text(
                'state: ${status.state.name}',
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          ValueListenableBuilder<PreviewMetrics?>(
            valueListenable: scanner.previewMetrics,
            builder: (context, metrics, _) => Text(
              'rot: ${metrics?.rotationDegrees ?? '?'}°  '
              'mirror: ${metrics?.mirrored ?? '?'}  '
              '${metrics?.size.width.round()}x${metrics?.size.height.round()}',
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowPainter extends CustomPainter {
  const _WindowPainter(this.window);

  final Rect? window;

  @override
  void paint(Canvas canvas, Size size) {
    final w = window;
    if (w == null) {
      // Draw a thin frame hint so the user can aim a QR anywhere.
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.green;
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    final rect = Rect.fromLTRB(
      w.left * size.width,
      w.top * size.height,
      w.right * size.width,
      w.bottom * size.height,
    );
    canvas.drawRect(
      rect,
      Paint()..color = Colors.yellow.withValues(alpha: 0.15),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.yellow,
    );
  }

  @override
  bool shouldRepaint(_WindowPainter oldDelegate) =>
      oldDelegate.window != window;
}
