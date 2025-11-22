import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraWithOverlay extends StatefulWidget {
  final Function(Uint8List bytes) onImageCaptured;

  const CameraWithOverlay({super.key, required this.onImageCaptured});

  @override
  State<CameraWithOverlay> createState() => _CameraWithOverlayState();
}

class _CameraWithOverlayState extends State<CameraWithOverlay> {
  CameraController? _controller;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );

      _controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      debugPrint("Error iniciando cámara: $e");
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_controller == null || _busy) return;

    setState(() => _busy = true);

    try {
      final file = await _controller!.takePicture();
      final bytes = await File(file.path).readAsBytes();

      widget.onImageCaptured(bytes);
    } catch (e) {
      debugPrint("Error capturando imagen: $e");
    }

    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        CameraPreview(_controller!),

        // --- Overlay circular para guiar ---
        IgnorePointer(
          child: Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white70, width: 4),
                color: Colors.transparent,
              ),
            ),
          ),
        ),

        // --- Botón de captura ---
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Center(
            child: FloatingActionButton(
              heroTag: "snap",
              backgroundColor: Colors.white,
              onPressed: _busy ? null : _capture,
              child: _busy
                  ? const CircularProgressIndicator()
                  : const Icon(Icons.camera_alt, color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }
}
