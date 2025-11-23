
import 'dart:math';
import 'package:image/image.dart' as img;

class RadialParams {
  final double rInner;
  final double rOuter;
  final double relPos;
  RadialParams(this.rInner, this.rOuter, this.relPos);
}

RadialParams autoCalcularRadios(img.Image image, int cx, int cy, {int steps = 180, int maxRadius = 0}) {
  final w = image.width;
  final h = image.height;
  if (maxRadius == 0) maxRadius = min(w, h) ~/ 2;

  List<double> innerRadii = [];
  List<double> outerRadii = [];

  double gray(int x, int y) {
    final p = image.getPixelSafe(x, y);
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
      if (x < 0 || y < 0 || x >= w || y >= h) break;
      final lum = gray(x, y);
      if (foundInner == -1 && last > 160 && lum < 120) {
        foundInner = r;
      }
      if (foundInner != -1 && foundOuter == -1 && last < 120 && lum > 160) {
        foundOuter = r;
        break;
      }
      last = lum;
    }
    if (foundInner != -1 && foundOuter != -1 && (foundOuter - foundInner) > 6) {
      innerRadii.add(foundInner.toDouble());
      outerRadii.add(foundOuter.toDouble());
    }
  }

  if (innerRadii.isEmpty || outerRadii.isEmpty) {
    final scale = min(w, h) / 2.0;
    final r1 = scale * 0.55;
    final r2 = scale * 0.85;
    return RadialParams(r1, r2, 0.65);
  }

  innerRadii.sort();
  outerRadii.sort();
  double medianInner = innerRadii[innerRadii.length ~/ 2];
  double medianOuter = outerRadii[outerRadii.length ~/ 2];

  final filteredInner = <double>[];
  final filteredOuter = <double>[];
  for (int i = 0; i < innerRadii.length; i++) {
    if ((innerRadii[i] - medianInner).abs() < medianInner * 0.25) {
      filteredInner.add(innerRadii[i]);
      filteredOuter.add(outerRadii[i]);
    }
  }
  if (filteredInner.isNotEmpty) {
    filteredInner.sort(); filteredOuter.sort();
    medianInner = filteredInner[filteredInner.length ~/ 2];
    medianOuter = filteredOuter[filteredOuter.length ~/ 2];
  }

  final rel = 0.65;
  return RadialParams(medianInner, medianOuter, rel);
}
