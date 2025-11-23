import 'dart:math';
import 'package:image/image.dart' as img;

/// Decodificador profesional optimizado.
/// - Oversampling angular
/// - Ventana ampliada (7x7)
/// - Threshold adaptativo por anillo
/// - Detección robusta en baja iluminación
class CircularCodeDecoder {
  final img.Image image;
  final int numSectors;
  final int dataBits;

  late int cx;
  late int cy;
  late int width;
  late int height;

  CircularCodeDecoder(
    this.image, {
    this.numSectors = 10,
    this.dataBits = 9,
  }) {
    width = image.width;
    height = image.height;
    cx = width ~/ 2;
    cy = height ~/ 2;
  }

  img.Pixel _safePixel(int x, int y) {
    x = x.clamp(0, width - 1);
    y = y.clamp(0, height - 1);
    return image.getPixelSafe(x, y);
  }

  /// ---------------------------
  /// THRESHOLD ADAPTATIVO GLOBAL
  /// ---------------------------
  double _calcGlobalMean(double r1, double r2) {
    double sum = 0;
    int count = 0;
    final int sampleCount = 40;

    for (int i = 0; i < sampleCount; i++) {
      double ang = 2 * pi * i / sampleCount;
      double radius = (r1 + r2) / 2;
      int x = (cx + radius * cos(ang)).round();
      int y = (cy + radius * sin(ang)).round();
      final pix = _safePixel(x, y);
      double lum = (pix.r + pix.g + pix.b) / 3.0;
      sum += lum;
      count++;
    }
    return sum / max(1, count);
  }

  /// ---------------------------
  /// DETECTOR DE MARCADOR ROJO
  /// ---------------------------
  int detectarInicio({
    required double r1,
    required double r2,
    double desplazamientoRelativo = 0.4,
  }) {
    for (int i = 0; i < numSectors; i++) {
      final ang = 2 * pi * (i + 0.5) / numSectors;
      final radius = r1 + desplazamientoRelativo * (r2 - r1);
      final x = (cx + radius * cos(ang)).round();
      final y = (cy + radius * sin(ang)).round();
      final pix = _safePixel(x, y);

      // Rojo = r alto, g bajo
      if (pix.r > 150 && pix.g < 100 && pix.b < 150) {
        return i;
      }
    }
    return 0;
  }

  /// ---------------------------
  /// OVERSAMPLING ANGULAR + 7x7
  /// ---------------------------
  List<int> extractBits({
    required double r1,
    required double r2,
    required String colorType,
    double desplazamientoRelativo = 0.4,
  }) {
    final bits = <int>[];

    // Luminancia global adaptativa
    final double globalMean = _calcGlobalMean(r1, r2);

    // Margen angular para oversampling
    const double delta = 2 * pi / 180; // ±2°

    // Ventana
    const int window = 7;
    const int half = window ~/ 2;

    for (int i = 0; i < numSectors; i++) {
      final ang0 = 2 * pi * (i + 0.5) / numSectors;

      // Oversampling angular en +2°, 0°, -2°
      final angles = [ang0 - delta, ang0, ang0 + delta];

      int sumSamples = 0;
      int sampleCount = 0;

      for (final ang in angles) {
        double radius = r1 + desplazamientoRelativo * (r2 - r1);
        int xc = (cx + radius * cos(ang)).round();
        int yc = (cy + radius * sin(ang)).round();

        // Promedio de ventana 7x7
        double localLum = 0;
        for (int dy = -half; dy <= half; dy++) {
          for (int dx = -half; dx <= half; dx++) {
            final pix = _safePixel(xc + dx, yc + dy);
            localLum += (pix.r + pix.g + pix.b) / 3.0;
            sampleCount++;
          }
        }
        localLum /= (window * window);

        // Clasificación provisional
        bool isOne = false;

        if (colorType == 'negro') {
          // Negro = luminosidad relativizada por media global
          isOne = localLum < globalMean * 0.75;
        } else if (colorType == 'amarillo') {
          // Amarillo = rojo y verde altos, azul bajo, relativo a media
          isOne = localLum > globalMean * 1.20;
        }

        sumSamples += isOne ? 1 : 0;
      }

      // Voto final por mayoría
      bits.add(sumSamples >= 2 ? 1 : 0);
    }

    return bits;
  }

  /// Rotación + inversión para orden correcto
  List<int> bitsDesdeIndice(List<int> bitsCompletos, int start) {
    final out = <int>[];
    for (int i = 1; i <= dataBits; i++) {
      out.add(bitsCompletos[(start + i) % numSectors]);
    }
    return out.reversed.toList();
  }
}
