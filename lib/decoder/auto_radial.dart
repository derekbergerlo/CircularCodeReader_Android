// lib/decoder/auto_radial.dart
import 'dart:math';
import 'package:image/image.dart' as img;

class RadialParams {
  final double rInner;
  final double rOuter;
  final double relPos;
  RadialParams(this.rInner, this.rOuter, this.relPos);
}

/// Fast radial profiler: estimates inner/outer radii (pixels) and recommended relative read position.
/// - image: full-res image (image.getPixelSafe available)
/// - cx, cy: center estimate (image coordinates)
/// - steps: number of radial samples (120..240)
RadialParams autoCalcularRadios(img.Image image, int cx, int cy, {int steps = 120, int maxRadius = 0}) {
  final w = image.width;
  final h = image.height;
  if (maxRadius == 0) maxRadius = min(w, h) ~/ 2;

  List<double> inner = [];
  List<double> outer = [];

  double lumAt(int x, int y) {
    final p = image.getPixelSafe(x.clamp(0, w - 1), y.clamp(0, h - 1));
    return (p.r + p.g + p.b) / 3.0;
  }

  for (int s = 0; s < steps; s++) {
    final ang = 2 * pi * s / steps;
    double last = 255.0;
    int foundInner = -1;
    int foundOuter = -1;
    for (int r = 8; r < maxRadius - 2; r++) {
      final x = (cx + r * cos(ang)).round();
      final y = (cy + r * sin(ang)).round();
      final lum = lumAt(x, y);
      // inner edge = bright->dark
      if (foundInner == -1 && last > 160 && lum < 120) {
        foundInner = r;
      }
      // outer edge = dark->bright after inner
      if (foundInner != -1 && foundOuter == -1 && last < 120 && lum > 160) {
        foundOuter = r;
        break;
      }
      last = lum;
    }
    if (foundInner != -1 && foundOuter != -1 && (foundOuter - foundInner) > 6) {
      inner.add(foundInner.toDouble());
      outer.add(foundOuter.toDouble());
    }
  }

  if (inner.isEmpty || outer.isEmpty) {
    final scale = min(w, h) / 2.0;
    return RadialParams(scale * 0.55, scale * 0.85, 0.65);
  }

  inner.sort();
  outer.sort();
  double midInner = inner[inner.length ~/ 2];
  double midOuter = outer[outer.length ~/ 2];

  // filter outliers
  final filteredInner = <double>[];
  final filteredOuter = <double>[];
  for (int i = 0; i < inner.length; i++) {
    if ((inner[i] - midInner).abs() < midInner * 0.25) {
      filteredInner.add(inner[i]);
      filteredOuter.add(outer[i]);
    }
  }
  if (filteredInner.isNotEmpty) {
    filteredInner.sort();
    filteredOuter.sort();
    midInner = filteredInner[filteredInner.length ~/ 2];
    midOuter = filteredOuter[filteredOuter.length ~/ 2];
  }

  return RadialParams(midInner, midOuter, 0.65);
}
