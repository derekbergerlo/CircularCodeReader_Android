// lib/widgets/live_scanner_screen.dart
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../decoder/bit_ring_decoder.dart';
import '../decoder/auto_radial.dart';

typedef OnScanResult = void Function({
  required List<int> productBits,
  required List<int> dateBits,
  required Uint8List imageBytes,
});

class LiveScannerScreen extends StatefulWidget {
  final OnScanResult onResult;
  final bool autoCapture;
  final int throttleMs; // ms between frame analyzes
  final int requiredDetections; // hysteresis count

  const LiveScannerScreen({
    Key? key,
    required this.onResult,
    this.autoCapture = true,
    this.throttleMs = 200,
    this.requiredDetections = 3,
  }) : super(key: key);

  @override
  State<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends State<LiveScannerScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  CameraDescription? _camera;
  bool _isProcessing = false;
  bool _scanningActive = true;
  Timer? _throttleTimer;

  // stabilization
  int _consecutiveDetections = 0;
  double _lastConfidence = 0.0;
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _throttleTimer?.cancel();
    _stopController();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      _camera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      _controller = CameraController(_camera!, ResolutionPreset.medium, enableAudio: false);
      await _controller!.initialize();

      // start stream
      await _controller!.startImageStream(_onCameraImage);
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('Camera init error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error iniciando cámara: $e')));
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _stopController() async {
    try {
      if (_controller != null) {
        await _controller!.stopImageStream();
        await _controller!.dispose();
      }
    } catch (_) {}
    _controller = null;
  }

  void _onCameraImage(CameraImage image) {
    if (!_scanningActive) return;
    if (_isProcessing) return;
    if (_throttleTimer?.isActive ?? false) return;

    _throttleTimer = Timer(Duration(milliseconds: widget.throttleMs), () {});
    _isProcessing = true;

    // Create payload for isolate
    final payload = _CameraFramePayload.fromCameraImage(image, _controller!.description.sensorOrientation);
    compute<_CameraFramePayload, _ScanCandidate>(_analyzeFrameIsolate, payload).then((candidate) async {
      _isProcessing = false;
      if (!mounted || !_scanningActive) return;

      if (candidate != null && candidate.confidence > 0.45) {
        _lastConfidence = candidate.confidence;
        _consecutiveDetections++;
        _progress = min(1.0, _consecutiveDetections / widget.requiredDetections);
        setState(() {});

        if (_consecutiveDetections >= widget.requiredDetections && widget.autoCapture) {
          // Try fast preview decode if thumbnail available
          bool usedPreview = false;
          if (candidate.thumbnail != null) {
            try {
              final thumbImg = img.decodeImage(candidate.thumbnail!);
              if (thumbImg != null) {
                final dec = CircularCodeDecoder(thumbImg);
                final scale = min(thumbImg.width, thumbImg.height) / 2;
                final rInt1 = scale * 0.2;
                final rInt2 = scale * 0.5;
                final rExt1 = scale * 0.55;
                final rExt2 = scale * 0.85;

                final inicioProducto = dec.detectarInicio(r1: rExt1, r2: rExt2, desplazamientoRelativo: 0.2);
                final inicioFecha = dec.detectarInicio(r1: rInt1, r2: rInt2, desplazamientoRelativo: 0.4);

                final bitsProducto = dec.bitsDesdeIndice(
                  dec.extractBits(r1: rExt1, r2: rExt2, colorType: 'negro', desplazamientoRelativo: 0.2),
                  inicioProducto,
                );
                final bitsFecha = dec.bitsDesdeIndice(
                  dec.extractBits(r1: rInt1, r2: rInt2, colorType: 'amarillo', desplazamientoRelativo: 0.4),
                  inicioFecha,
                );

                final onesProd = bitsProducto.where((b) => b==1).length;
                final onesDate = bitsFecha.where((b) => b==1).length;

                // simple plausibility checks: not all ones/zeros and some ones
                if (onesProd > 0 && onesProd < bitsProducto.length && onesDate >= 0 && onesDate <= bitsFecha.length) {
                  // accept preview result
                  widget.onResult(productBits: bitsProducto, dateBits: bitsFecha, imageBytes: candidate.thumbnail!);
                  usedPreview = true;
                }
              }
            } catch (e) {
              debugPrint('Preview decode error: $e');
            }
          }

          if (!usedPreview) {
            await _performHighResCapture();
          }
        }
      } else {
        // decay
        if (_consecutiveDetections > 0) _consecutiveDetections = max(0, _consecutiveDetections - 1);
        _progress = (_consecutiveDetections / widget.requiredDetections).clamp(0.0, 1.0);
        setState(() {});
      }
    }).catchError((e) {
      debugPrint('Compute error: $e');
      _isProcessing = false;
    });
  }

  Future<void> _performHighResCapture() async {
    if (_controller == null) return;
    _scanningActive = false;
    try {
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();

      // decode full-res and run your existing Dart decoder
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('No se pudo decodificar la imagen capturada.');

      // Auto-calculate radial params on the captured image
      final params = autoCalcularRadios(decoded, decoded.width ~/ 2, decoded.height ~/ 2, steps: 180);
      final decoder = CircularCodeDecoder(decoded);

      final rExt1 = params.rInner;
      final rExt2 = params.rOuter;
      final desplRel = params.relPos;

      final inicioProducto = decoder.detectarInicio(r1: rExt1, r2: rExt2, desplazamientoRelativo: desplRel);

      // For inner ring use proportional inner radii relative to detected outer ring
      // We'll estimate inner ring by scaling inward (~0.45 of outer radius)
      final centerScale = min(decoded.width, decoded.height)/2;
      final rInt2 = rExt1 * 0.9; // estimate inner outer boundary relative to outer ring
      final rInt1 = rInt2 * 0.45; // estimate inner inner boundary

      final inicioFecha = decoder.detectarInicio(r1: rInt1, r2: rInt2, desplazamientoRelativo: 0.5);

      final bitsProducto = decoder.bitsDesdeIndice(
        decoder.extractBits(r1: rExt1, r2: rExt2, colorType: 'negro', desplazamientoRelativo: desplRel),
        inicioProducto,
      );

      final bitsFecha = decoder.bitsDesdeIndice(
        decoder.extractBits(r1: rInt1, r2: rInt2, colorType: 'amarillo', desplazamientoRelativo: 0.5),
        inicioFecha,
      );

      // return result
      widget.onResult(productBits: bitsProducto, dateBits: bitsFecha, imageBytes: bytes);

      // pop screen
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      debugPrint('Capture/Decode error: $e\n$st');
      // resume scanning
      _scanningActive = true;
      _consecutiveDetections = 0;
      _progress = 0.0;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Escanear (Profesional)')),
      body: Stack(
        children: [
          CameraPreview(_controller!),
          Center(child: _buildOverlay()),
          Positioned(
            top: 16,
            left: 16,
            child: _statusChip(),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Column(
              children: [
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text('Confianza: ${(_lastConfidence * 100).toStringAsFixed(0)}% — Estabilidad: $_consecutiveDetections',
                    style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip() {
    return Card(
      color: Colors.black45,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6),
        child: Text(
          _scanningActive ? 'Escaneando...' : 'Procesando...',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildOverlay() {
    return IgnorePointer(
      child: Container(
        width: 320,
        height: 320,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white70, width: 4),
        ),
        child: CustomPaint(painter: _OverlayPainter()),
      ),
    );
  }
}

/// Painter for the overlay reticle
class _OverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white38;
    canvas.drawCircle(center, radius - 4, paint);

    final markPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.4;
    for (int i = 0; i < 16; i++) {
      final ang = 2 * pi * i / 16;
      final p1 = center + Offset(cos(ang), sin(ang)) * (radius - 6);
      final p2 = center + Offset(cos(ang), sin(ang)) * (radius - 20);
      canvas.drawLine(p1, p2, markPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// -------------------- ISOLATE / Payload / Analyzer --------------------

class _CameraFramePayload {
  final List<Uint8List> planes;
  final int width;
  final int height;
  final int rotation;

  _CameraFramePayload({
    required this.planes,
    required this.width,
    required this.height,
    required this.rotation,
  });

  factory _CameraFramePayload.fromCameraImage(CameraImage image, int rotation) {
    final planes = image.planes.map((p) => p.bytes).toList();
    return _CameraFramePayload(
      planes: planes.cast<Uint8List>(),
      width: image.width,
      height: image.height,
      rotation: rotation,
    );
  }
}


class _ScanCandidate {
  final double confidence;
  final int centerX;
  final int centerY;
  final Uint8List? thumbnail; // small jpeg/png for quick preview decoding

  _ScanCandidate({required this.confidence, required this.centerX, required this.centerY, this.thumbnail});
}

/// Runs in an isolate/// Runs in an isolate: converts YUV -> RGB (fast), then does radial edge detection
Future<_ScanCandidate> _analyzeFrameIsolate(_CameraFramePayload payload) async {
  try {
    final width = payload.width;
    final height = payload.height;
    final y = payload.planes[0];
    final u = payload.planes.length > 1 ? payload.planes[1] : Uint8List(0);
    final v = payload.planes.length > 2 ? payload.planes[2] : Uint8List(0);

    // create small working image (downscale for performance)
    final downscale = (min(width, height) / 240).clamp(1.0, 4.0);
    final smallW = (width / downscale).round();
    final smallH = (height / downscale).round();
    final imgSmall = img.Image(width: smallW, height: smallH);

    // fast approx YUV420->RGB on downscaled grid
    // note: plane strides vary across devices; we assume common layout
    int yp = 0;
    for (int j = 0; j < smallH; j++) {
      final srcJ = (j * downscale).round();
      for (int i = 0; i < smallW; i++) {
        final srcI = (i * downscale).round();
        // map to original index
        final yIndex = srcJ * width + srcI;
        final yVal = (y.length > yIndex) ? (y[yIndex] & 0xff) : 0;
        final uvIndex = ((srcJ ~/ 2) * (width ~/ 2) + (srcI ~/ 2));
        final uVal = (u.length > uvIndex) ? (u[uvIndex] & 0xff) : 128;
        final vVal = (v.length > uvIndex) ? (v[uvIndex] & 0xff) : 128;

        int r = (yVal + (1.370705 * (vVal - 128))).round();
        int g = (yVal - (0.337633 * (uVal - 128)) - (0.698001 * (vVal - 128))).round();
        int b = (yVal + (1.732446 * (uVal - 128))).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        imgSmall.setPixelRgb(i, j, r, g, b);
        yp++;
      }
    }

    // radial edge detection on small image
    final cx = smallW / 2;
    final cy = smallH / 2;
    final steps = 28;
    final maxR = min(smallW, smallH) ~/ 2;
    final edgePoints = <Point<double>>[];

    for (int s = 0; s < steps; s++) {
      final ang = 2 * pi * s / steps;
      int lastIntensity = 255;
      for (int r = 6; r < maxR; r++) {
        final x = (cx + r * cos(ang)).round();
        final yPos = (cy + r * sin(ang)).round();
        if (x < 0 || yPos < 0 || x >= smallW || yPos >= smallH) break;
        final pix = imgSmall.getPixelSafe(x, yPos);
        final intensity = ((pix.r + pix.g + pix.b) ~/ 3);
        if (lastIntensity > 160 && intensity < 90) {
          edgePoints.add(Point(x.toDouble(), yPos.toDouble()));
          break;
        }
        lastIntensity = intensity;
      }
    }

    if (edgePoints.isEmpty) {
      return _ScanCandidate(confidence: 0.0, centerX: (width / 2).round(), centerY: (height / 2).round());
    }

    double sx = 0.0, sy = 0.0;
    for (var p in edgePoints) {
      sx += p.x;
      sy += p.y;
    }
    final avgX = (sx / edgePoints.length) * downscale;
    final avgY = (sy / edgePoints.length) * downscale;

    final confidence = edgePoints.length / steps;

    
    // encode thumbnail (jpeg) from imgSmall for quick preview decode
    Uint8List? thumbBytes;
    try {
      final jpg = img.encodeJpg(imgSmall, quality: 75);
      thumbBytes = Uint8List.fromList(jpg);
    } catch (e) {
      thumbBytes = null;
    }

    return _ScanCandidate(
      confidence: confidence.clamp(0.0, 1.0),
      centerX: avgX.round(),
      centerY: avgY.round(),
      thumbnail: thumbBytes,
    );

  } catch (e, st) {
    debugPrint('analyze isolate error: $e\n$st');
    return _ScanCandidate(confidence: 0.0, centerX: (payload.width / 2).round(), centerY: (payload.height / 2).round(), thumbnail: null);
  }
}
