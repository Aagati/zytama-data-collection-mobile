import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../../core/constants/app_colors.dart';

/// Full-screen crop: drag the corners to resize, drag inside to move.
/// Pops with the cropped JPEG [File], or null when cancelled.
///
/// Pure Flutter (no native cropper), so it needs no Android/iOS setup.
class ImageCropScreen extends StatefulWidget {
  final File image;
  final String title;
  const ImageCropScreen({super.key, required this.image, this.title = 'Crop'});

  /// Convenience: push the screen and return the cropped file (or null).
  static Future<File?> open(BuildContext context, File image,
          {String title = 'Crop'}) =>
      Navigator.of(context).push<File>(MaterialPageRoute(
        builder: (_) => ImageCropScreen(image: image, title: title),
      ));

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  /// Image size as displayed (EXIF orientation already applied by Flutter).
  Size? _imageSize;

  /// Crop rect in normalised image coordinates (0..1 on both axes).
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);
  bool _saving = false;

  static const _minFraction = 0.1;
  static const _handleHit = 36.0;

  @override
  void initState() {
    super.initState();
    final stream = FileImage(widget.image).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (mounted) {
        setState(() => _imageSize = Size(
            info.image.width.toDouble(), info.image.height.toDouble()));
      }
      stream.removeListener(listener);
    }, onError: (error, stackTrace) {
      if (mounted) Navigator.of(context).pop();
    });
    stream.addListener(listener);
  }

  /// Where the image sits inside the available box (BoxFit.contain).
  Rect _imageRect(Size box) {
    final s = _imageSize!;
    final scale = math.min(box.width / s.width, box.height / s.height);
    final w = s.width * scale, h = s.height * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Rect _toScreen(Rect img) => Rect.fromLTRB(
        img.left + _crop.left * img.width,
        img.top + _crop.top * img.height,
        img.left + _crop.right * img.width,
        img.top + _crop.bottom * img.height,
      );

  /// Which part of the crop box a drag started on.
  _Grip _gripAt(Offset pos, Rect box) {
    bool near(Offset a) => (a - pos).distance <= _handleHit;
    if (near(box.topLeft)) return _Grip.topLeft;
    if (near(box.topRight)) return _Grip.topRight;
    if (near(box.bottomLeft)) return _Grip.bottomLeft;
    if (near(box.bottomRight)) return _Grip.bottomRight;
    if (box.contains(pos)) return _Grip.move;
    return _Grip.none;
  }

  _Grip _grip = _Grip.none;

  void _onDrag(DragUpdateDetails d, Rect img) {
    final dx = d.delta.dx / img.width, dy = d.delta.dy / img.height;
    var r = _crop;
    switch (_grip) {
      case _Grip.none:
        return;
      case _Grip.move:
        final mx = dx.clamp(-r.left, 1 - r.right);
        final my = dy.clamp(-r.top, 1 - r.bottom);
        r = r.shift(Offset(mx, my));
      case _Grip.topLeft:
        r = Rect.fromLTRB(
            (r.left + dx).clamp(0, r.right - _minFraction),
            (r.top + dy).clamp(0, r.bottom - _minFraction),
            r.right,
            r.bottom);
      case _Grip.topRight:
        r = Rect.fromLTRB(
            r.left,
            (r.top + dy).clamp(0, r.bottom - _minFraction),
            (r.right + dx).clamp(r.left + _minFraction, 1),
            r.bottom);
      case _Grip.bottomLeft:
        r = Rect.fromLTRB(
            (r.left + dx).clamp(0, r.right - _minFraction),
            r.top,
            r.right,
            (r.bottom + dy).clamp(r.top + _minFraction, 1));
      case _Grip.bottomRight:
        r = Rect.fromLTRB(
            r.left,
            r.top,
            (r.right + dx).clamp(r.left + _minFraction, 1),
            (r.bottom + dy).clamp(r.top + _minFraction, 1));
    }
    setState(() => _crop = r);
  }

  Future<void> _done() async {
    if (_crop == const Rect.fromLTRB(0, 0, 1, 1)) {
      Navigator.of(context).pop(); // nothing to crop
      return;
    }
    setState(() => _saving = true);
    final dir = await getTemporaryDirectory();
    final out = p.join(
        dir.path, 'crop_${DateTime.now().microsecondsSinceEpoch}.jpg');
    final src = widget.image.path;
    final c = _crop;
    // Decoding a 12 MP photo takes a moment; keep the UI responsive.
    final ok = await Isolate.run(() => _cropFile(src, out, c));
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(File(out));
    } else {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't crop this photo.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () => setState(() => _crop = const Rect.fromLTRB(0, 0, 1, 1)),
            child: const Text('Reset', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _imageSize == null
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white))
                  : Padding(
                      padding: const EdgeInsets.all(20),
                      child: LayoutBuilder(builder: (context, c) {
                        final img = _imageRect(c.biggest);
                        final box = _toScreen(img);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) =>
                              _grip = _gripAt(d.localPosition, box),
                          onPanUpdate: (d) => _onDrag(d, img),
                          onPanEnd: (_) => _grip = _Grip.none,
                          child: Stack(
                            children: [
                              Positioned.fromRect(
                                rect: img,
                                child: Image.file(widget.image,
                                    fit: BoxFit.fill),
                              ),
                              Positioned.fill(
                                child: CustomPaint(
                                    painter: _CropPainter(image: img, box: box)),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, MediaQuery.paddingOf(context).bottom + 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        minimumSize: const Size.fromHeight(48),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed:
                          _saving || _imageSize == null ? null : _done,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.crop_rounded, size: 18),
                      label: Text(_saving ? 'Cropping…' : 'Crop'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.secondary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Grip { none, move, topLeft, topRight, bottomLeft, bottomRight }

/// Dims outside the crop box, draws its border, thirds grid and corners.
class _CropPainter extends CustomPainter {
  final Rect image;
  final Rect box;
  _CropPainter({required this.image, required this.box});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(image),
          Path()..addRect(box)),
      dim,
    );

    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = box.left + box.width * i / 3;
      final y = box.top + box.height * i / 3;
      canvas.drawLine(Offset(x, box.top), Offset(x, box.bottom), line);
      canvas.drawLine(Offset(box.left, y), Offset(box.right, y), line);
    }
    canvas.drawRect(
        box,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    final corner = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 20.0;
    for (final (c, sx, sy) in [
      (box.topLeft, 1.0, 1.0),
      (box.topRight, -1.0, 1.0),
      (box.bottomLeft, 1.0, -1.0),
      (box.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(c, c + Offset(l * sx, 0), corner);
      canvas.drawLine(c, c + Offset(0, l * sy), corner);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.box != box || old.image != image;
}

/// Runs in a background isolate. [crop] is normalised (0..1) against the
/// EXIF-oriented image, matching what the screen displayed.
bool _cropFile(String src, String out, Rect crop) {
  final decoded = img.decodeImage(File(src).readAsBytesSync());
  if (decoded == null) return false;
  final photo = img.bakeOrientation(decoded);
  final x = (crop.left * photo.width).round();
  final y = (crop.top * photo.height).round();
  final w = (crop.width * photo.width).round();
  final h = (crop.height * photo.height).round();
  if (w < 8 || h < 8) return false;
  final cropped = img.copyCrop(photo, x: x, y: y, width: w, height: h);
  File(out).writeAsBytesSync(img.encodeJpg(cropped, quality: 95));
  return true;
}
