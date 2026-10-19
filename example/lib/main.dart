import 'dart:async';

import 'package:flutter/material.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const ScannerExampleApp());
}

class ScannerExampleApp extends StatelessWidget {
  const ScannerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'instant_barcode_scanner example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ScannerPage(),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final InstantBarcodeScanner _scanner = InstantBarcodeScanner();
  StreamSubscription<ScanResult>? _scanSubscription;

  String _statusLine = 'starting';
  ScanResult? _last;
  int _streamedCount = 0;
  String? _error;
  bool _handoffActive = false;

  @override
  void initState() {
    super.initState();
    _scanner.status.addListener(_onStatusChanged);
    _scanSubscription = _scanner.scans.listen(_onStreamedBarcode);
    _warmUp();
  }

  @override
  void dispose() {
    _scanner.status.removeListener(_onStatusChanged);
    _scanSubscription?.cancel();
    unawaited(_scanner.dispose());
    super.dispose();
  }

  void _onStatusChanged() {
    final status = _scanner.status.value;
    if (!mounted) {
      return;
    }
    setState(() {
      _statusLine = status.hasError
          ? '${status.state} (${status.errorCode}: ${status.errorMessage})'
          : '${status.state}';
    });
  }

  void _onStreamedBarcode(ScanResult result) {
    if (!mounted) {
      return;
    }
    setState(() => _streamedCount++);
  }

  Future<void> _warmUp() async {
    try {
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        _setError('camera permission not granted');
        return;
      }
      await _scanner.warmUp();
    } catch (error) {
      _setError('warmUp failed: $error');
    }
  }

  Future<void> _scan() async {
    try {
      final result = await _scanner.scan();
      if (!mounted) {
        return;
      }
      setState(() {
        _last = result;
        _error = null;
      });
    } catch (error) {
      _setError('scan failed: $error');
    }
  }

  Future<void> _beginHandoff() async {
    setState(() => _handoffActive = true);
    try {
      await _scanner.beginNfcHandoff();
    } catch (error) {
      _setError('handoff failed: $error');
      if (mounted) {
        setState(() => _handoffActive = false);
      }
    }
  }

  Future<void> _endHandoff() async {
    try {
      await _scanner.endNfcHandoff();
    } catch (error) {
      _setError('handoff failed: $error');
    } finally {
      if (mounted) {
        setState(() => _handoffActive = false);
      }
    }
  }

  void _setError(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final result = _last;
    return Scaffold(
      appBar: AppBar(title: const Text('instant_barcode_scanner')),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child: InstantBarcodeScannerView(controller: _scanner),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('state: $_statusLine'),
                Text('streamed barcodes: $_streamedCount'),
                if (_handoffActive)
                  const Text(
                    'NFC handoff active: scanning is paused until End handoff',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                if (_error != null)
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                if (result != null) ...[
                  Text('format: ${result.format}'),
                  Text(
                    'raw bytes: ${result.rawBytes?.length ?? 0} '
                    '${_hexPreview(result.rawBytes)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text('text: ${result.text ?? '<none>'}'),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _handoffActive ? null : _scan,
                      child: const Text('Scan'),
                    ),
                    OutlinedButton(
                      onPressed: _scanner.warmUp,
                      child: const Text('Warm up'),
                    ),
                    OutlinedButton(
                      onPressed: _scanner.park,
                      child: const Text('Park'),
                    ),
                    OutlinedButton(
                      onPressed: _scanner.close,
                      child: const Text('Close'),
                    ),
                    OutlinedButton(
                      onPressed: _beginHandoff,
                      child: const Text('NFC handoff'),
                    ),
                    OutlinedButton(
                      onPressed: _endHandoff,
                      child: const Text('End handoff'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _hexPreview(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return '';
    }
    final head = bytes.take(16);
    return '(${head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}'
        '${bytes.length > 16 ? ' ...' : ''})';
  }
}
