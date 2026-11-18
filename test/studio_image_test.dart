import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zytama_data/features/product/data/services/live_object_detector.dart';
import 'package:zytama_data/features/product/data/services/product_ocr_service.dart';
import 'package:zytama_data/features/product/data/services/studio_image_service.dart';
import 'package:zytama_data/features/product/presentation/widgets/ai_box_painter.dart';
import 'package:flutter/painting.dart';

void main() {
  group('AI box on still photos', () {
    test('productBox hugs the product, normalised', () {
      const w = 40, h = 20;
      final m = Float32List(w * h);
      for (var y = 5; y < 15; y++) {
        for (var x = 10; x < 30; x++) {
          m[y * w + x] = 0.9;
        }
      }
      m[0] = 0.4; // soft edge below 0.5 is not product
      final b = productBox(m, w, h)!;
      expect(b.left, closeTo(0.25, 1e-9));
      expect(b.right, closeTo(0.75, 1e-9));
      expect(b.top, closeTo(0.25, 1e-9));
      expect(b.bottom, closeTo(0.75, 1e-9));
    });

    test('productBox is null for an empty or speck mask', () {
      expect(productBox(Float32List(100), 10, 10), isNull);
      final speck = Float32List(100 * 100)..[5050] = 1;
      expect(productBox(speck, 100, 100), isNull);
    });

    test('box follows the photo under cover / contain / fill', () {
      const size = Size(200, 100);
      // A 1:1 photo covering 200×100 is 200×200, centred: top cut by 50.
      expect(AiBoxPainter.photoRect(size, 1, BoxFit.cover),
          const Rect.fromLTWH(0, -50, 200, 200));
      expect(AiBoxPainter.photoRect(size, 1, BoxFit.contain),
          const Rect.fromLTWH(50, 0, 100, 100));
      expect(AiBoxPainter.photoRect(size, 1, BoxFit.fill),
          const Rect.fromLTWH(0, 0, 200, 100));
    });
  });

  // A 400×300 "photo": red product block on a busy blue background.
  img.Image photo() {
    final im = img.Image(width: 400, height: 300);
    img.fill(im, color: img.ColorRgb8(20, 60, 200));
    img.fillRect(im,
        x1: 150, y1: 80, x2: 250, y2: 220, color: img.ColorRgb8(220, 30, 30));
    return im;
  }

  // A 40×30 mask matching the product block (what the model would output).
  Float32List mask({bool flat = false}) {
    final m = Float32List(40 * 30);
    if (flat) return m..fillRange(0, m.length, 0.5);
    for (var y = 8; y <= 22; y++) {
      for (var x = 15; x <= 25; x++) {
        m[y * 40 + x] = 1;
      }
    }
    return m;
  }

  test('puts the masked product on a light backdrop shaped to fit it', () {
    final out = composeFromMask(photo(), mask(), 40, 30)!;
    // Tall pack (~100×140) → 3:4 portrait canvas, long side 1600.
    expect(out.height, 1600);
    expect(out.width, 1200);

    // Top corner is backdrop white; none of the blue background survives.
    final corner = out.getPixel(10, 10);
    expect([corner.r, corner.g, corner.b], everyElement(greaterThan(240)));

    // Centre of the canvas holds the red product.
    final centre = out.getPixel(out.width ~/ 2, out.height ~/ 2);
    expect(centre.r, greaterThan(180));
    expect(centre.b, lessThan(80));
  });

  test('product fills the canvas with only a slim margin', () {
    final out = composeFromMask(photo(), mask(), 40, 30)!;
    // Scan the middle row for the red product's horizontal extent.
    final y = out.height ~/ 2;
    var first = -1, last = -1;
    for (var x = 0; x < out.width; x++) {
      if (out.getPixel(x, y).r > 180 && out.getPixel(x, y).b < 80) {
        if (first < 0) first = x;
        last = x;
      }
    }
    // Height-limited (aspect clamped to 3:4), so ≥ 75% of the width.
    expect(last - first, greaterThan(out.width * 0.75));
  });

  test('stands up a product shot lying on its side', () {
    // Wide red bar (200×60) in the middle of the photo.
    final im = img.Image(width: 400, height: 300);
    img.fill(im, color: img.ColorRgb8(20, 60, 200));
    img.fillRect(im,
        x1: 100, y1: 120, x2: 300, y2: 180, color: img.ColorRgb8(220, 30, 30));
    final m = Float32List(40 * 30);
    for (var y = 12; y <= 18; y++) {
      for (var x = 10; x <= 30; x++) {
        m[y * 40 + x] = 1;
      }
    }
    // No text info → wide product is rotated upright.
    final auto = composeFromMask(im, m, 40, 30)!;
    expect(auto.height, greaterThan(auto.width));
    // OCR says the text is already upright → leave it wide.
    final kept = composeFromMask(im, m, 40, 30, quarterTurns: 0)!;
    expect(kept.width, greaterThan(kept.height));
    // OCR says rotate → rotated even if it were square.
    final turned = composeFromMask(im, m, 40, 30, quarterTurns: 1)!;
    expect(turned.height, greaterThan(turned.width));
  });

  test('rotateQuarter turns clockwise', () {
    final im = img.Image(width: 2, height: 1, numChannels: 4);
    im.setPixelRgba(0, 0, 255, 0, 0, 255); // red left
    im.setPixelRgba(1, 0, 0, 0, 255, 255); // blue right
    final cw = rotateQuarter(im, 1);
    expect(cw.width, 1);
    expect(cw.height, 2);
    expect(cw.getPixel(0, 0).r, 255); // left → top
    expect(cw.getPixel(0, 1).b, 255); // right → bottom
    final ccw = rotateQuarter(im, 3);
    expect(ccw.getPixel(0, 0).b, 255); // right → top
  });

  test('removes skin (a hand) from the cut-out', () {
    // Hand covers the bottom third of the product block.
    final skin = Float32List(40 * 30);
    for (var y = 18; y <= 22; y++) {
      for (var x = 15; x <= 25; x++) {
        skin[y * 40 + x] = 1;
      }
    }
    final withHand = composeFromMask(photo(), mask(), 40, 30,
        skin: skin, skinW: 40, skinH: 30, kind: StudioKind.label)!;
    final noHand = composeFromMask(photo(), mask(), 40, 30,
        kind: StudioKind.label)!;
    // The subject's bounding box shrinks: the hand rows are gone.
    expect(withHand.height, lessThan(noHand.height));
  });

  test('label layout keeps resolution and adds no shadow', () {
    final out =
        composeFromMask(photo(), mask(), 40, 30, kind: StudioKind.label)!;
    // ~100×140 product + 4% margin, not scaled up to the square canvas.
    expect(out.width, lessThan(200));
    final corner = out.getPixel(0, out.height - 1);
    expect([corner.r, corner.g, corner.b], everyElement(255));
  });

  test('handOverlapsObject flags skin on the product only', () {
    final object = (mask: mask(), w: 40, h: 30);
    final onProduct = Float32List(40 * 30)..fillRange(18 * 40, 23 * 40, 1);
    final faceInCorner = Float32List(40 * 30);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        faceInCorner[y * 40 + x] = 1;
      }
    }
    expect(handOverlapsObject(object, (mask: onProduct, w: 40, h: 30)),
        isTrue);
    expect(handOverlapsObject(object, (mask: faceInCorner, w: 40, h: 30)),
        isFalse);
  });

  test('returns null when the mask finds nothing salient', () {
    expect(composeFromMask(photo(), mask(flat: true), 40, 30), isNull);
  });

  test('refineObjectMask drops an arm blob reaching in from the edge', () {
    final m = mask();
    // "Arm": salient strip from the left edge, joined to the pack by a
    // one-cell-thin "wrist" (row 10, x 0..14).
    for (var y = 2; y <= 6; y++) {
      for (var x = 0; x <= 12; x++) {
        m[y * 40 + x] = 0.8;
      }
    }
    for (var x = 12; x <= 15; x++) {
      m[7 * 40 + x] = 0.8;
    }
    final r = refineObjectMask(m, 40, 30);
    expect(r[4 * 40 + 3], 0); // arm gone
    expect(r[15 * 40 + 20], greaterThan(0.9)); // pack kept
    // And the studio crop is the pack alone, so it's drawn big.
    final out =
        composeFromMask(photo(), m, 40, 30, kind: StudioKind.label)!;
    expect(out.width, lessThan(200));
  });

  test('laplacianVariance tells a sharp photo from a blurred one', () {
    // Text-like detail: a fine checker pattern.
    final sharp = img.Image(width: 300, height: 300);
    for (final px in sharp) {
      final on = ((px.x ~/ 4) + (px.y ~/ 4)).isEven;
      px
        ..r = on ? 240 : 20
        ..g = on ? 240 : 20
        ..b = on ? 240 : 20;
    }
    final blurred = img.gaussianBlur(sharp.clone(), radius: 6);
    expect(laplacianVariance(sharp), greaterThan(blurThreshold * 10));
    expect(laplacianVariance(blurred), lessThan(blurThreshold));
  });

  test('subjectBounds maps the mask to photo pixels with a margin', () {
    final b = subjectBounds(mask(), 40, 30, 400, 300)!;
    // Product block is x 150..250, y 80..220; one mask cell = 10 px margin.
    expect(b.x, lessThanOrEqualTo(150));
    expect(b.y, lessThanOrEqualTo(80));
    expect(b.x + b.w, greaterThanOrEqualTo(250));
    expect(b.y + b.h, greaterThanOrEqualTo(220));
    expect(b.w, lessThan(140)); // not the whole photo
  });

  test('product shot from a high-res photo is not soft (no upscaling)', () {
    // 4000×3000 photo, product ~1000×1400 px: fills the canvas by shrinking.
    final big = img.copyResize(photo(),
        width: 4000, height: 3000, interpolation: img.Interpolation.nearest);
    final out = composeFromMask(big, mask(), 40, 30)!;
    expect(out.height, 1600);
    // Edge between product and backdrop stays crisp: a strong step.
    final c = out.getPixel(out.width ~/ 2, out.height ~/ 2);
    expect(c.r, greaterThan(180));
  });

  test('trims a thumb stub off the outline but keeps the whole pack', () {
    // 80×80 grid, pack = 40×50 block, thumb = 8 long × 5 wide stub off its left side.
    const w = 80, h = 80;
    final m = Float32List(w * h);
    for (var y = 15; y < 65; y++) {
      for (var x = 20; x < 60; x++) {
        m[y * w + x] = 1;
      }
    }
    for (var y = 37; y < 42; y++) {
      for (var x = 12; x < 20; x++) {
        m[y * w + x] = 0.9;
      }
    }
    final r = refineObjectMask(m, w, h);
    expect(r[40 * w + 13], 0); // stub gone
    expect(r[16 * w + 21], greaterThan(0.75)); // pack corner kept
    expect(r[40 * w + 40], greaterThan(0.75)); // pack body kept
  });

  test('cuts off medium-saliency surroundings attached to the pack', () {
    // 80×80: pack (high confidence) x 20..49, y 20..59; a "web page" panel
    // (medium) joined to its right side, x 50..74, y 10..69.
    const w = 80, h = 80;
    final m = Float32List(w * h);
    for (var y = 10; y < 70; y++) {
      for (var x = 50; x < 75; x++) {
        m[y * w + x] = 0.6;
      }
    }
    for (var y = 20; y < 60; y++) {
      for (var x = 20; x < 50; x++) {
        m[y * w + x] = 1;
      }
    }
    final r = refineObjectMask(m, w, h);
    expect(r[40 * w + 35], greaterThan(0.75)); // pack kept
    expect(r[40 * w + 68], lessThan(0.4)); // panel gone
    expect(r[12 * w + 60], lessThan(0.4));
  });

  test('keeps a label\'s low-scoring white areas inside its outline', () {
    // Label 20..59 × 15..64: coloured bands score high, the white panel
    // between them only medium (as white print areas do).
    const w = 80, h = 80;
    final m = Float32List(w * h);
    for (var y = 15; y < 65; y++) {
      for (var x = 20; x < 60; x++) {
        final band = y < 25 || y >= 55 || x < 26 || x >= 54;
        m[y * w + x] = band ? 1 : 0.55;
      }
    }
    final r = refineObjectMask(m, w, h);
    expect(r[40 * w + 40], greaterThan(0.75)); // white panel kept, opaque
    expect(r[20 * w + 22], greaterThan(0.75)); // coloured band kept
  });

  test('cut across attached surroundings is a smooth line, not steps', () {
    // Pack tilted 45° (diamond) with a medium panel attached on the right.
    const w = 100, h = 100;
    final m = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 55; x < 95; x++) {
        if (y > 15 && y < 85) m[y * w + x] = 0.6;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if ((x - 40).abs() + (y - 50).abs() <= 28) m[y * w + x] = 1;
      }
    }
    final r = refineObjectMask(m, w, h);
    expect(r[50 * w + 40], greaterThan(0.75)); // pack centre
    expect(r[50 * w + 85], lessThan(0.4)); // panel far side gone
    // Each row must end in one clean edge: once it has faded out moving
    // right from the centre, nothing visible (alpha needs > 0.4) comes back
    // — no strip of the panel along the pack's side.
    for (var y = 20; y <= 80; y += 2) {
      var faded = false;
      for (var x = 40; x < w; x++) {
        final v = r[y * w + x];
        if (v < 0.1) faded = true;
        if (faded) expect(v, lessThan(0.3), reason: 'row $y x $x');
      }
    }
  });

  test('convexHull wraps the points', () {
    final hull = convexHull([
      for (final (x, y) in [(0, 0), (4, 0), (4, 4), (0, 4), (2, 2), (1, 3)])
        math.Point(x.toDouble(), y.toDouble()),
    ]);
    expect(hull.length, 4);
  });

  test('fills a glare hole inside the pack', () {
    final m = mask();
    m[15 * 40 + 20] = 0; // low-saliency spot in the middle
    m[15 * 40 + 21] = 0;
    final r = refineObjectMask(m, 40, 30);
    expect(r[15 * 40 + 20], greaterThanOrEqualTo(0.8));
  });

  test('skin-coloured print inside the pack is not treated as a hand', () {
    final object = (mask: mask(), w: 40, h: 30);
    // "Skin" patch fully inside the pack (pink print).
    final print = Float32List(40 * 30);
    for (var y = 12; y <= 16; y++) {
      for (var x = 18; x <= 22; x++) {
        print[y * 40 + x] = 0.9;
      }
    }
    final filtered = filterSkinToHands((mask: print, w: 40, h: 30), object);
    expect(filtered.every((v) => v == 0), isTrue);

    // A real hand reaches from the pack out to the frame edge.
    final hand = Float32List(40 * 30);
    for (var y = 18; y <= 22; y++) {
      for (var x = 20; x < 40; x++) {
        hand[y * 40 + x] = 0.9;
      }
    }
    final kept = filterSkinToHands((mask: hand, w: 40, h: 30), object);
    expect(kept[20 * 40 + 22], greaterThan(0.5));
  });

  test('textTurns reads the text direction', () {
    ({double dx, double dy, int chars}) line(double dx, double dy) =>
        (dx: dx, dy: dy, chars: 10);
    expect(ProductOcrService.textTurns([line(100, 2), line(80, -1)]), 0);
    // Reading downwards (product lying, top to the right) → 90° anticlockwise.
    expect(ProductOcrService.textTurns([line(1, 100), line(-2, 90)]), 3);
    // Reading upwards → 90° clockwise.
    expect(ProductOcrService.textTurns([line(0, -100), line(3, -80)]), 1);
    expect(ProductOcrService.textTurns([line(-100, 0), line(-90, 4)]), 2);
    // Too little text, or no majority → unknown.
    expect(ProductOcrService.textTurns([(dx: 0, dy: 50, chars: 4)]), isNull);
    expect(ProductOcrService.textTurns([line(100, 0), line(0, 100)]), isNull);
  });

  test('live detector boxes the product tightly from the model mask', () {
    // 64×64 saliency: product block x 20..39, y 10..49; empty elsewhere.
    final sal = Float32List(64 * 64);
    for (var y = 10; y < 50; y++) {
      for (var x = 20; x < 40; x++) {
        sal[y * 64 + x] = 0.95;
      }
    }
    final d = detectionFromSaliency(sal, 64, 64)!;
    expect(d.box!.left, closeTo(20 / 64, 0.04));
    expect(d.box!.right, closeTo(40 / 64, 0.04));
    expect(d.box!.top, closeTo(10 / 64, 0.04));
    expect(d.box!.bottom, closeTo(50 / 64, 0.04));
    expect(d.mask, isNotNull);
    // Nothing salient (empty table) → no box at all.
    expect(detectionFromSaliency(Float32List(64 * 64), 64, 64), isNull);
  });

  test('live detector flags a hand on the product, not skin-coloured print',
      () {
    final sal = Float32List(64 * 64);
    for (var y = 10; y < 50; y++) {
      for (var x = 20; x < 40; x++) {
        sal[y * 64 + x] = 0.95;
      }
    }
    // Fingers over the pack's right side, arm reaching in from the edge.
    final hand = Float32List(64 * 64);
    for (var y = 25; y < 35; y++) {
      for (var x = 30; x < 64; x++) {
        hand[y * 64 + x] = 0.9;
      }
    }
    final d = detectionFromSaliency(sal, 64, 64,
        skin: (mask: hand, w: 64, h: 64))!;
    expect(d.hand, isTrue);
    // The box still hugs the pack, not the arm.
    expect(d.box!.right, lessThan(44 / 64));

    // Pink print inside the pack (no skin outside it) is not a hand.
    final print = Float32List(64 * 64);
    for (var y = 20; y < 30; y++) {
      for (var x = 24; x < 34; x++) {
        print[y * 64 + x] = 0.9;
      }
    }
    expect(
        detectionFromSaliency(sal, 64, 64, skin: (mask: print, w: 64, h: 64))!
            .hand,
        isFalse);
    expect(detectionFromSaliency(sal, 64, 64)!.hand, isFalse);
  });

  test('LiveFrame samples an NV21 frame upright', () {
    // 4×2 frame: left half bright, right half dark; neutral chroma.
    final bytes = Uint8List(4 * 2 * 3 ~/ 2)..fillRange(8, 12, 128);
    for (final i in [0, 1, 4, 5]) {
      bytes[i] = 250;
    }
    // Sensor rotated 90°: the sensor's left edge becomes the top.
    final f = LiveFrame(bytes, 4, 2, 4, 90, nv21: true);
    final px = f.sample(2, 4); // upright 2×4
    expect(px[0], greaterThan(200)); // top-left bright
    expect(px[(3 * 2) * 3], lessThan(50)); // bottom-left dark
  });
}
