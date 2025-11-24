// lib/widgets/live_scanner_screen.dart
// Final migrated & enhanced for image: 4.5.4
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
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
    this.throttleMs = 160,
    this.requiredDetections = 2,
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

  // stabilization & adaptive thresholding
  int _consecutiveDetections = 0;
  double _lastConfidence = 0.0;
  double _progress = 0.0;
  double _confidenceEMA = 0.0; // exponential moving average of confidence

  // DEBUG overlay vars (always active for now)
  double? _debugRInner;
  double? _debugROuter;
  int? _debugCenterX;
  int? _debugCenterY;
  int? _debugImageW;
  int? _debugImageH;

  // UI: overlay placement adjustments
  Size? _previewSize; // logical preview size (controller.value.previewSize)
  // overlay configuration
  final double _overlayDiameter = 320.0;

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
      _controller = CameraController(_camera!, ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await _controller!.initialize();

      // store preview size for overlay mapping if available
      final psize = _controller!.value.previewSize;
      if (psize != null) {
        // previewSize often reports rotated dimensions; map to logical
        _previewSize = Size(psize.height, psize.width);
      }

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

  // adaptive confidence threshold (mixture strategy):
  // base 0.65..0.85 depending on recent EMA: if EMA high, allow lower immediate threshold
  double _adaptiveConfidenceThreshold() {
    final ema = _confidenceEMA.clamp(0.0, 1.0);
    final base = 0.75; // default mid
    final adjust = (ema - 0.6) * 0.25; // small adaptive tweak
    return (base - adjust).clamp(0.60, 0.85);
  }

  void _updateConfidenceEMA(double c) {
    const alpha = 0.25;
    _confidenceEMA = alpha * c + (1 - alpha) * _confidenceEMA;
  }

  void _onCameraImage(CameraImage image) {
    if (!_scanningActive) return;
    if (_isProcessing) return;
    if (_throttleTimer?.isActive ?? false) return;

    _throttleTimer = Timer(Duration(milliseconds: widget.throttleMs), () {});
    _isProcessing = true;

    final payload = _CameraFramePayload.fromCameraImage(image, _controller!.description.sensorOrientation);
    compute<_CameraFramePayload, _ScanCandidate>(_analyzeFrameIsolate, payload).then((candidate) async {
      _isProcessing = false;
      if (!mounted || !_scanningActive) return;

      // update center immediately so overlay shows movement
      if (candidate != null) {
        _debugCenterX = candidate.centerX;
        _debugCenterY = candidate.centerY;
      }

      // update EMA regardless
      if (candidate != null) {
        _updateConfidenceEMA(candidate.confidence);
        _lastConfidence = candidate.confidence;
      }

      final threshold = _adaptiveConfidenceThreshold();

      // acceptance for "candidate" to increment detection
      if (candidate != null && candidate.confidence > threshold) {
        _consecutiveDetections++;
        _progress = min(1.0, _consecutiveDetections / widget.requiredDetections);
        setState(() {});

        if (_consecutiveDetections >= widget.requiredDetections && widget.autoCapture) {
          // Try fast preview decode if thumbnail available (plausibility checks)
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

                final onesProd = bitsProducto.where((b) => b == 1).length;

                // preview plausibility: not trivial and has some ones
                if (bitsProducto.length == 9 && onesProd > 0 && onesProd < bitsProducto.length) {
                  widget.onResult(productBits: bitsProducto, dateBits: bitsFecha, imageBytes: candidate.thumbnail!);
                  usedPreview = true;
                }
              }
            } catch (e) {
              debugPrint('Preview decode error: $e');
            }
          }

          if (!usedPreview) {
            final highConfidenceCut = 0.95;
            if ((_debugRInner != null && _debugROuter != null) || candidate.confidence > highConfidenceCut) {
              await _performHighResCapture();
            } else {
              if (candidate.thumbnail != null) {
                try {
                  final thumbImg = img.decodeImage(candidate.thumbnail!);
                  if (thumbImg != null) {
                    final thumbParams = autoCalcularRadios(thumbImg, thumbImg.width ~/ 2, thumbImg.height ~/ 2, steps: 80);
                    // store as hints for display mapping; full-res will override after capture
                    _debugRInner = thumbParams.rInner;
                    _debugROuter = thumbParams.rOuter;
                    await _performHighResCapture();
                  }
                } catch (e) {
                  debugPrint('Preview radial failed: $e');
                  await _performHighResCapture();
                }
              } else {
                await _performHighResCapture();
              }
            }
          }
        }
      } else {
        // decay detections gracefully
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

      // decode full-res and run Dart decoder
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('No se pudo decodificar la imagen capturada.');

      // Auto-calculate radial params on the captured image
      try {
        final params = autoCalcularRadios(decoded, decoded.width ~/ 2, decoded.height ~/ 2, steps: 180);
        _debugRInner = params.rInner;
        _debugROuter = params.rOuter;
        _debugImageW = decoded.width;
        _debugImageH = decoded.height;
        debugPrint('Auto radial: inner=${_debugRInner}, outer=${_debugROuter}');
      } catch (e) {
        debugPrint('autoCalcularRadios failed: $e');
      }

      final decoder = CircularCodeDecoder(decoded);

      final rExt1 = _debugRInner ?? (min(decoded.width, decoded.height) / 2 * 0.55);
      final rExt2 = _debugROuter ?? (min(decoded.width, decoded.height) / 2 * 0.85);
      final desplRel = 0.65;

      final inicioProducto = decoder.detectarInicio(r1: rExt1, r2: rExt2, desplazamientoRelativo: 0.2);

      final rInt2 = rExt1 * 0.9;
      final rInt1 = rInt2 * 0.45;

      final inicioFecha = decoder.detectarInicio(r1: rInt1, r2: rInt2, desplazamientoRelativo: 0.5);

      final bitsProducto = decoder.bitsDesdeIndice(
        decoder.extractBits(r1: rExt1, r2: rExt2, colorType: 'negro', desplazamientoRelativo: 0.2),
        inicioProducto,
      );

      final bitsFecha = decoder.bitsDesdeIndice(
        decoder.extractBits(r1: rInt1, r2: rInt2, colorType: 'amarillo', desplazamientoRelativo: 0.5),
        inicioFecha,
      );

      // basic plausibility: product bits not all same
      final onesProd = bitsProducto.where((b) => b == 1).length;
      if (!(onesProd > 0 && onesProd < bitsProducto.length)) {
        debugPrint('Plausibility failed on high-res decode, returning to scanning');
        _scanningActive = true;
        _consecutiveDetections = 0;
        _progress = 0.0;
        setState(() {});
        return;
      }

      // Create debug overlay image with sampling points and circles (returns JPEG bytes)
      final debugImageBytes = _drawSamplingOverlay(
        decoded,
        rExt1,
        rExt2,
        rInt1,
        rInt2,
        inicioProducto,
        inicioFecha,
        bitsProducto,
        bitsFecha,
      );

      widget.onResult(productBits: bitsProducto, dateBits: bitsFecha, imageBytes: debugImageBytes);

      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      debugPrint('Capture/Decode error: $e\n$st');
      _scanningActive = true;
      _consecutiveDetections = 0;
      _progress = 0.0;
      setState(() {});
    }
  }

  /// Draw sampling points, circles and bit numbers using image 4.5.4 API (Color class and named params)
  Uint8List _drawSamplingOverlay(
    img.Image source,
    double extR1,
    double extR2,
    double intR1,
    double intR2,
    int startExt,
    int startInt,
    List<int> bitsExt,
    List<int> bitsInt,
  ) {
    // clone original to avoid modifying it
    final out = img.Image.from(source);
    final w = out.width;
    final h = out.height;
    final cx = w ~/ 2;
    final cy = h ~/ 2;

    // helper color creators for image 4.x
    img.Color colorRgb(int r, int g, int b, [int a = 255]) {
      // img.ColorRgb8 exists and is preferred
      return img.ColorRgb8(r, g, b);
    }

    // Draw ring boundaries (thin)
    img.drawCircle(out,
        x: cx,
        y: cy,
        radius: extR1.round(),
        color: colorRgb(0, 200, 0)); // inner boundary of outer ring
    img.drawCircle(out,
        x: cx,
        y: cy,
        radius: extR2.round(),
        color: colorRgb(255, 165, 0)); // outer boundary of outer ring
    img.drawCircle(out,
        x: cx,
        y: cy,
        radius: intR1.round(),
        color: colorRgb(0, 180, 180));
    img.drawCircle(out,
        x: cx,
        y: cy,
        radius: intR2.round(),
        color: colorRgb(0, 180, 180));

    const int numSectors = 10;
    const double desplazExt = 0.2;
    const double desplazInt = 0.5;

    // Outer ring sampling points + bit numbers
    for (int i = 0; i < numSectors; i++) {
      final ang = 2 * pi * (i + 0.5) / numSectors;
      final radius = extR1 + desplazExt * (extR2 - extR1);
      final x = (cx + radius * cos(ang)).round();
      final y = (cy + radius * sin(ang)).round();

      final ptColor = bitsExt[i] == 1 ? colorRgb(255, 0, 0) : colorRgb(30, 30, 30);
      img.fillCircle(out, x: x, y: y, radius: 8, color: ptColor);

      // draw bit number near point (slightly offset)
      final nx = (x + (radius * 0.12 * cos(ang))).round();
      final ny = (y + (radius * 0.12 * sin(ang))).round();
      final bitLabel = i.toString();
      // use arial_24 font (present in image package)
      img.drawString(out, img.arial_24, nx, ny, bitLabel, color: colorRgb(255, 255, 255));
      // mark sector start
      if (i == startExt) {
        final x2 = (cx + (radius - 28) * cos(ang)).round();
        final y2 = (cy + (radius - 28) * sin(ang)).round();
        img.drawLine(out, x1: x2, y1: y2, x2: x, y2: y, color: colorRgb(255, 0, 255));
      }
    }

    // Inner ring sampling points + bit numbers
    for (int i = 0; i < numSectors; i++) {
      final ang = 2 * pi * (i + 0.5) / numSectors;
      final radius = intR1 + desplazInt * (intR2 - intR1);
      final x = (cx + radius * cos(ang)).round();
      final y = (cy + radius * sin(ang)).round();

      final ptColor = bitsInt[i] == 1 ? colorRgb(255, 255, 0) : colorRgb(40, 40, 40);
      img.fillCircle(out, x: x, y: y, radius: 6, color: ptColor);

      final nx = (x + (radius * 0.12 * cos(ang))).round();
      final ny = (y + (radius * 0.12 * sin(ang))).round();
      final bitLabel = i.toString();
      img.drawString(out, img.arial_24, nx, ny, bitLabel, color: colorRgb(255, 255, 255));

      if (i == startInt) {
        final x2 = (cx + (radius - 18) * cos(ang)).round();
        final y2 = (cy + (radius - 18) * sin(ang)).round();
        img.drawLine(out, x1: x2, y1: y2, x2: x, y2: y, color: colorRgb(255, 0, 255));
      }
    }

    // draw center marker
    img.fillCircle(out, x: cx, y: cy, radius: 6, color: colorRgb(255, 0, 0));

    // draw textual result area
    final prodText = 'Producto: ' + bitsExt.join();
    final dateText = 'Fecha   : ' + bitsInt.join();
    img.drawString(out, img.arial_24, 8, 8, prodText, color: colorRgb(255, 255, 255));
    img.drawString(out, img.arial_24, 8, 36, dateText, color: colorRgb(255, 255, 255));

    // encode to JPEG
    final jpg = img.encodeJpg(out, quality: 88);
    return Uint8List.fromList(jpg);
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // compute overlay translation so it aligns with the camera preview content
    final previewSize = _previewSize ?? Size(MediaQuery.of(context).size.width, MediaQuery.of(context).size.height);
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final previewAspect = previewSize.width / previewSize.height;
    final screenAspect = screenW / screenH;

    double scaleToFit;
    double offsetX = 0.0;
    double offsetY = 0.0;

    if (previewAspect > screenAspect) {
      // preview is wider -> fits screen width, black bars top/bottom
      scaleToFit = screenW / previewSize.width;
      final fittedHeight = previewSize.height * scaleToFit;
      offsetY = (screenH - fittedHeight) / 2;
    } else {
      // preview is taller -> fits screen height, black bars left/right
      scaleToFit = screenH / previewSize.height;
      final fittedWidth = previewSize.width * scaleToFit;
      offsetX = (screenW - fittedWidth) / 2;
    }

    // overlay center in screen coordinates
    final overlayLeft = ((screenW - _overlayDiameter) / 2) + offsetX;
    final overlayTop = ((screenH - _overlayDiameter) / 2) + offsetY;

    return Scaffold(
      appBar: AppBar(title: const Text('Escanear (Profesional — v3 final)')),
      body: Stack(
        children: [
          CameraPreview(_controller!),
          Positioned(
            left: overlayLeft,
            top: overlayTop,
            width: _overlayDiameter,
            height: _overlayDiameter,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 4),
                ),
                child: CustomPaint(
                  painter: _OverlayPainter(
                    debugCenterX: _debugCenterX,
                    debugCenterY: _debugCenterY,
                    debugRInner: _debugRInner,
                    debugROuter: _debugROuter,
                    debugImageW: _debugImageW,
                    debugImageH: _debugImageH,
                  ),
                ),
              ),
            ),
          ),
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
}

/// Painter for the overlay reticle
class _OverlayPainter extends CustomPainter {
  final int? debugCenterX;
  final int? debugCenterY;
  final double? debugRInner;
  final double? debugROuter;
  final int? debugImageW;
  final int? debugImageH;

  _OverlayPainter({
    this.debugCenterX,
    this.debugCenterY,
    this.debugRInner,
    this.debugROuter,
    this.debugImageW,
    this.debugImageH,
  });

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

    // debug center: map debugCenterX/Y to preview overlay center coordinates roughly
    if (debugCenterX != null && debugCenterY != null && debugImageW != null && debugImageH != null) {
      final imgMin = min(debugImageW!.toDouble(), debugImageH!.toDouble());
      final scaleFactor = (radius) / (imgMin / 2.0);
      final dx = (debugCenterX! - (debugImageW! / 2)) * scaleFactor;
      final dy = (debugCenterY! - (debugImageH! / 2)) * scaleFactor;
      final dotPos = center + Offset(dx, dy);
      final dotPaint = Paint()..color = Colors.redAccent..style = PaintingStyle.fill;
      canvas.drawCircle(dotPos, 5, dotPaint);
    } else if (debugCenterX != null && debugCenterY != null) {
      final dotPaint = Paint()..color = Colors.redAccent..style = PaintingStyle.fill;
      canvas.drawCircle(center, 4, dotPaint);
    }

    // draw debug radii mapped to overlay (if we have image dims)
    if (debugRInner != null && debugROuter != null && debugImageW != null && debugImageH != null) {
      final circlePaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 2;
      final imgMin = min(debugImageW!.toDouble(), debugImageH!.toDouble());
      final previewRadius = radius;
      final imgRadius = imgMin / 2.0;
      final scaleF = previewRadius / imgRadius;
      final innerR = (debugRInner! * scaleF).clamp(2.0, previewRadius);
      final outerR = (debugROuter! * scaleF).clamp(2.0, previewRadius);
      canvas.drawCircle(center, innerR, circlePaint..color = Colors.limeAccent);
      canvas.drawCircle(center, outerR, circlePaint..color = Colors.orangeAccent);
    } else if (debugRInner != null && debugROuter != null) {
      canvas.drawCircle(center, radius * 0.6, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.limeAccent);
      canvas.drawCircle(center, radius * 0.9, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.orangeAccent);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
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

/// Runs in an isolate: converts YUV -> RGB (fast), then does radial edge detection
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
    for (int j = 0; j < smallH; j++) {
      final srcJ = (j * downscale).round();
      for (int i = 0; i < smallW; i++) {
        final srcI = (i * downscale).round();
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
      }
    }

    // radial edge detection on small image
    final cx = smallW / 2;
    final cy = smallH / 2;
    const steps = 28;
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
