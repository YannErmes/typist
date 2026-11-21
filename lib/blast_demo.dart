import 'dart:convert';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'blast_model.dart';

/// Sample picture bundles for trying the Blast game without collecting
/// real images first. Every picture is drawn in code as a small PNG data
/// URL, so the demo works identically in the browser and on desktop.
enum _Kind {
  circle,
  square,
  triangle,
  star,
  diamond,
  ring,
  cross,
  hexagon,
  oval,
  bar,
  stripes,
  dots,
  checker,
}

class _Spec {
  final String name;
  final _Kind kind;
  final List<int> rgb;
  const _Spec(this.name, this.kind, this.rgb);
}

const _shapeSpecs = <_Spec>[
  _Spec('red circle', _Kind.circle, [214, 60, 52]),
  _Spec('blue square', _Kind.square, [52, 105, 196]),
  _Spec('green triangle', _Kind.triangle, [52, 150, 82]),
  _Spec('yellow star', _Kind.star, [232, 183, 38]),
  _Spec('orange diamond', _Kind.diamond, [230, 126, 34]),
  _Spec('purple ring', _Kind.ring, [137, 86, 168]),
  _Spec('teal cross', _Kind.cross, [38, 156, 156]),
  _Spec('brown hexagon', _Kind.hexagon, [139, 94, 58]),
  _Spec('pink oval', _Kind.oval, [219, 106, 152]),
  _Spec('black bar', _Kind.bar, [46, 44, 40]),
];

const _colorSpecs = <_Spec>[
  _Spec('crimson', _Kind.square, [200, 44, 60]),
  _Spec('ocean blue', _Kind.circle, [40, 96, 190]),
  _Spec('forest green', _Kind.square, [40, 130, 76]),
  _Spec('golden yellow', _Kind.circle, [236, 184, 42]),
  _Spec('violet', _Kind.square, [132, 76, 180]),
  _Spec('coral', _Kind.circle, [240, 126, 110]),
  _Spec('deep teal', _Kind.square, [26, 132, 140]),
  _Spec('slate grey', _Kind.circle, [112, 118, 128]),
  _Spec('hot magenta', _Kind.square, [204, 52, 140]),
  _Spec('olive green', _Kind.circle, [128, 142, 54]),
];

const _patternSpecs = <_Spec>[
  _Spec('red stripes', _Kind.stripes, [200, 62, 58]),
  _Spec('blue dots', _Kind.dots, [48, 104, 196]),
  _Spec('green checker', _Kind.checker, [48, 146, 84]),
  _Spec('amber ring', _Kind.ring, [214, 148, 30]),
  _Spec('navy star', _Kind.star, [38, 62, 120]),
  _Spec('rose diamond', _Kind.diamond, [206, 88, 122]),
  _Spec('grey cross', _Kind.cross, [104, 106, 108]),
  _Spec('cyan hexagon', _Kind.hexagon, [42, 158, 172]),
  _Spec('amber circle', _Kind.circle, [214, 148, 30]),
  _Spec('lime square', _Kind.square, [150, 196, 52]),
];

final List<BlastBundle> _cache = _build();

List<BlastBundle> blastDemoBundles() => _cache;

List<BlastBundle> _build() {
  return [
    _make('demo-shapes', 'Shape shots', _shapeSpecs, 1000),
    _make('demo-colors', 'Color chips', _colorSpecs, 2000),
    _make('demo-patterns', 'Pattern pack', _patternSpecs, 3000),
  ];
}

BlastBundle _make(String id, String title, List<_Spec> specs, int stamp) {
  return BlastBundle(
    id: id,
    title: title,
    createdAt: stamp,
    items: [for (final s in specs) BlastItem(word: s.name, image: _picture(s))],
  );
}

String _picture(_Spec spec) {
  const size = 160;
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(250, 247, 239));
  final color = img.ColorRgb8(spec.rgb[0], spec.rgb[1], spec.rgb[2]);
  const c = size / 2;
  const r = 62.0;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x - c;
      final dy = y - c;
      final dist = math.sqrt(dx * dx + dy * dy);
      final theta = math.atan2(dy, dx);
      bool inside;
      switch (spec.kind) {
        case _Kind.circle:
          inside = dist < r;
        case _Kind.square:
          inside = dx.abs() < r * 0.9 && dy.abs() < r * 0.9;
        case _Kind.triangle:
          inside = dy > -r && dy < r * 0.7 &&
              dx.abs() < (r - dy) * 0.62;
        case _Kind.star:
          final edge = r * (0.58 + 0.42 * math.cos(5 * theta).abs());
          inside = dist < edge;
        case _Kind.diamond:
          inside = dx.abs() + dy.abs() < r * 1.15;
        case _Kind.ring:
          inside = dist > r * 0.55 && dist < r;
        case _Kind.cross:
          inside = (dx.abs() < r * 0.3 && dy.abs() < r) ||
              (dy.abs() < r * 0.3 && dx.abs() < r);
        case _Kind.hexagon:
          inside = math.max(dx.abs() * 0.87 + dy.abs() * 0.5,
                  dy.abs()) < r * 0.92;
        case _Kind.oval:
          inside = math.pow(dx / (r * 0.75), 2) +
                  math.pow(dy / r, 2) <
              1;
        case _Kind.bar:
          inside = dx.abs() < r && dy.abs() < r * 0.36;
        case _Kind.stripes:
          inside = dist < r && (x ~/ 14).isEven;
        case _Kind.dots:
          inside = dist < r && x % 30 < 13 && y % 30 < 13;
        case _Kind.checker:
          inside = dist < r && ((x ~/ 18) + (y ~/ 18)).isEven;
      }
      if (inside) image.setPixel(x, y, color);
    }
  }
  return 'data:image/png;base64,${base64Encode(img.encodePng(image))}';
}
