import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'decoder/bit_ring_decoder.dart';
import 'services/api_client.dart';

import 'widgets/camera_overlay.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CircularCodeApp());
}

class CircularCodeApp extends StatelessWidget {
  const CircularCodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Circular Code (Extended)',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Uint8List? _imageBytes;
  List<int>? _bitsProductoLocal;
  List<int>? _bitsFechaLocal;
  String? _bitsProductoApi;
  String? _bitsFechaApi;
  String _backendUrl = 'http://192.168.1.100:8000'; // <-- cambia a tu IP/LAN o dominio
  bool _busy = false;

  final _urlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = _backendUrl;
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _process(bytes);
  }

  Future<void> _takePhoto() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.camera);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _process(bytes);
  }

  Future<void> _process(Uint8List bytes) async {
    setState(() {
      _busy = true;
      _imageBytes = bytes;
      _bitsProductoLocal = null;
      _bitsFechaLocal = null;
      _bitsProductoApi = null;
      _bitsFechaApi = null;
      _backendUrl = _urlCtrl.text.trim().isEmpty ? _backendUrl : _urlCtrl.text.trim();
    });

    // Local decode (offline)
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        final dec = CircularCodeDecoder(decoded);
        final scale = min(decoded.width, decoded.height) / 2;
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

        setState(() {
          _bitsProductoLocal = bitsProducto;
          _bitsFechaLocal = bitsFecha;
        });
      }
    } catch (_) {}

    // Remote decode (backend)
    try {
      final api = ApiClient(baseUrl: _backendUrl);
      final resp = await api.decodeCircularCode(bytes);
      setState(() {
        _bitsProductoApi = resp['product_bits'] as String?;
        _bitsFechaApi = resp['date_bits'] as String?;
      });
    } catch (e) {
      // ignore but show a snack
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backend no disponible: $e')),
        );
      }
    }

    setState(() {
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Circular Code (Extended)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Backend URL (ej. http://IP:8000)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => setState(() => _backendUrl = _urlCtrl.text.trim()),
                  icon: const Icon(Icons.save),
                  tooltip: 'Guardar URL',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _busy ? null : _takePhoto,
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Tomar foto'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _pickImage,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Galería'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: const Text("Escanear código circular")),
                                body: CameraWithOverlay(
                                  onImageCaptured: (bytes) async {
                                    Navigator.of(context).pop(); // volvemos al Home
                                    await _process(bytes);      // procesamos la imagen
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text("Escanear cámara"),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            if (_imageBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(_imageBytes!, height: 280, fit: BoxFit.contain),
              ),
            const SizedBox(height: 16),
            if (_bitsProductoLocal != null && _bitsFechaLocal != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Resultado local (Dart):', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text('🔷 Producto: ${_bitsProductoLocal!.join()}'),
                      Text('📆 Fecha   : ${_bitsFechaLocal!.join()}'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_bitsProductoApi != null || _bitsFechaApi != null)
              Card(
                color: Colors.blueGrey.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Resultado backend:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text('🔷 Producto: ${_bitsProductoApi ?? "-"}'),
                      Text('📆 Fecha   : ${_bitsFechaApi ?? "-"}'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
