import 'dart:math';
import 'package:image/image.dart' as img;

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

      if (x < 0 || y < 0 || x >= width || y >= height) continue;

      final pixel = image.getPixel(x, y); // Pixel object
      final r = pixel.r;
      final g = pixel.g;

      if (r > 150 && g < 100) return i;
    }
    return 0;
  }

  List<int> extractBits({
    required double r1,
    required double r2,
    required String colorType,
    double desplazamientoRelativo = 0.4,
  }) {
    final bits = <int>[];

    for (int i = 0; i < numSectors; i++) {
      final ang = 2 * pi * (i + 0.5) / numSectors;
      final radius = r1 + desplazamientoRelativo * (r2 - r1);
      final x = (cx + radius * cos(ang)).round();
      final y = (cy + radius * sin(ang)).round();

      if (x < 0 || y < 0 || x >= width || y >= height) {
        bits.add(0);
        continue;
      }

      final pixel = image.getPixel(x, y);
      final r = pixel.r;
      final g = pixel.g;
      final b = pixel.b;

      int val = 0;

      if (colorType == 'negro') {
        val = ((r + g + b) / 3 < 100) ? 1 : 0;
      } else if (colorType == 'amarillo') {
        val = (r > 200 && g > 200 && b < 150) ? 1 : 0;
      }

      bits.add(val);
    }

    return bits;
  }

  List<int> bitsDesdeIndice(List<int> bitsCompletos, int start) {
    final out = <int>[];
    for (int i = 1; i <= dataBits; i++) {
      out.add(bitsCompletos[(start + i) % numSectors]);
    }
    return out.reversed.toList();
  }
}
