// lib/decoder/bit_ring_decoder.dart
import 'dart:math';
import 'package:image/image.dart' as img;

/// Circular code decoder v3
/// - Oversampling angular (±delta)
/// - Window sampling (NxN, default 7x7)
/// - Adaptive per-angle luminance baseline
/// - Improved yellow classifier (robust to shadows)
/// - Configurable thresholds for tuning
class CircularCodeDecoder {
  final img.Image image;
  final int numSectors;
  final int dataBits;

  late int cx;
  late int cy;
  late int width;
  late int height;

  /// Tunable parameters
  final int window; // sampling window (odd)
  final double angularDeltaDeg; // oversampling delta in degrees
  final double blackFactor; // e.g. 0.75 (localLum < localMean * blackFactor -> black)
  final double yellowFactor; // e.g. 1.08 (localLum > localMean * yellowFactor -> yellow)
  final int meanSampleSteps; // how many samples to compute local mean along radial

  CircularCodeDecoder(
    this.image, {
    this.numSectors = 10,
    this.dataBits = 9,
    this.window = 7,
    this.angularDeltaDeg = 2.0,
    this.blackFactor = 0.75,
    this.yellowFactor = 1.08,
    this.meanSampleSteps = 5,
  }) {
    width = image.width;
    height = image.height;
    cx = width ~/ 2;
    cy = height ~/ 2;
    if (window % 2 == 0) {
      throw ArgumentError('window must be odd (e.g. 7)');
    }
  }

  // safe pixel getter (returns img.Pixel)
  img.Pixel _safePixel(int x, int y) {
    x = x.clamp(0, width - 1);
    y = y.clamp(0, height - 1);
    return image.getPixelSafe(x, y);
  }

  // quick luminance
  double _lum(img.Pixel p) => (p.r + p.g + p.b) / 3.0;

  /// Compute a robust local mean luminance for a given sector angle (ang)
  /// Samples along the radial between r1..r2 at a few fractional positions.
  double _calcMeanForAngle(double r1, double r2, double ang) {
    double sum = 0.0;
    int count = 0;
    final int steps = max(2, meanSampleSteps);
    for (int i = 0; i < steps; i++) {
      final t = 0.25 + 0.5 * (i / (steps - 1)); // sample between 25%..75% of thickness
      final r = r1 + t * (r2 - r1);
      final x = (cx + r * cos(ang)).round();
      final y = (cy + r * sin(ang)).round();
      final pix = _safePixel(x, y);
      sum += _lum(pix);
      count++;
    }
    return (count > 0) ? (sum / count) : 128.0;
  }

  /// Detect red triangular marker index on a ring
  /// More robust red detection (r strong, r>g and r> b, and absolute r threshold)
  int detectarInicio({
    required double r1,
    required double r2,
    double desplazamientoRelativo = 0.4,
  }) {
    final radius = r1 + desplazamientoRelativo * (r2 - r1);
    for (int i = 0; i < numSectors; i++) {
      final ang = 2 * pi * (i + 0.5) / numSectors;
      final x = (cx + radius * cos(ang)).round();
      final y = (cy + radius * sin(ang)).round();
      final pix = _safePixel(x, y);
      // robust red: high R, and R significantly > G,B
      if (pix.r > 140 && pix.r > pix.g + 30 && pix.r > pix.b + 30) {
        return i;
      }
    }
    return 0;
  }

  /// Main extraction function with adaptive local mean and improved color checks.
  List<int> extractBits({
    required double r1,
    required double r2,
    required String colorType, // 'negro' or 'amarillo'
    double desplazamientoRelativo = 0.4,
  }) {
    final bits = <int>[];

    final double delta = (angularDeltaDeg * pi) / 180.0; // convert deg to rad
    final int half = window ~/ 2;

    for (int i = 0; i < numSectors; i++) {
      final ang0 = 2 * pi * (i + 0.5) / numSectors;

      // local mean computed per angle (more robust than global)
      final double localMean = _calcMeanForAngle(r1, r2, ang0);

      // oversampling angles (center, ±delta)
      final angles = [ang0, ang0 - delta, ang0 + delta];

      int positiveVotes = 0;
      for (final ang in angles) {
        final radius = r1 + desplazamientoRelativo * (r2 - r1);
        final baseX = (cx + radius * cos(ang)).round();
        final baseY = (cy + radius * sin(ang)).round();

        // sample window NxN, compute average RGB and average luminance
        double sumR = 0.0, sumG = 0.0, sumB = 0.0;
        int samples = 0;
        for (int dy = -half; dy <= half; dy++) {
          for (int dx = -half; dx <= half; dx++) {
            final pix = _safePixel(baseX + dx, baseY + dy);
            sumR += pix.r;
            sumG += pix.g;
            sumB += pix.b;
            samples++;
          }
        }
        final avgR = sumR / samples;
        final avgG = sumG / samples;
        final avgB = sumB / samples;
        final avgLum = (avgR + avgG + avgB) / 3.0;

        bool isOne = false;

        if (colorType == 'negro') {
          // black if local luminance significantly below local mean
          isOne = avgLum < (localMean * blackFactor);
        } else if (colorType == 'amarillo') {
          // Two-stage yellow detection:
          // 1) color shape: R and G must be predominant vs B
          // 2) brightness must exceed a factor of local mean
          final bool chromaYellow = (avgR > 130 && avgG > 110 && avgR > avgB + 20 && avgG > avgB + 10);
          final bool chromaDarkYellow = (avgR > 120 && avgG > 105 && avgR > avgB + 10);
          isOne = (chromaYellow && (avgLum > localMean * yellowFactor)) ||
                  (chromaDarkYellow && (avgLum > localMean * (yellowFactor + 0.05)));
          // keep a safety fallback: very strong R&G can also be considered
          if (!isOne && avgR > 220 && avgG > 180 && avgB < 150 && avgLum > localMean * 1.0) {
            isOne = true;
          }
        }

        // vote
        if (isOne) positiveVotes++;
      }

      // majority vote (2/3) from angles
      bits.add(positiveVotes >= 2 ? 1 : 0);
    }

    return bits;
  }

  /// Rotate bits so that the first data bit after the start marker is first,
  /// then reverse to match MSB->LSB convention (like your Python sample).
  List<int> bitsDesdeIndice(List<int> bitsCompletos, int start) {
    final out = <int>[];
    for (int i = 1; i <= dataBits; i++) {
      out.add(bitsCompletos[(start + i) % numSectors]);
    }
    return out.reversed.toList();
  }
}
