import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Which photo is being cleaned up; decides the output layout.
enum StudioKind {
  /// Front of pack → square catalogue shot, product centred, floor shadow.
  product,

  /// Ingredients / nutrition → tight crop of the label on white, kept at high
  /// resolution so small print stays readable. No shadow, no squaring.
  label,
}

/// Outcome of one studio run.
class StudioResult {
  /// The cleaned-up JPEG, or null when no clear product/label was found.
  final File? file;

  /// A hand (skin) overlaps the product. Its pixels are removed from [file],
  /// but anything the fingers covered is gone, so the UI suggests a retake.
  final bool handDetected;

  /// The product area of the original photo is out of focus or shaken
  /// (low Laplacian variance), so the UI suggests a retake.
  final bool blurry;

  const StudioResult(
      {this.file, this.handDetected = false, this.blurry = false});
  static const none = StudioResult();
}

/// Where the AI found the product in a photo, known a moment before the
/// studio image itself is ready, so the UI can draw it on the photo.
class StudioBox {
  /// Product bounds, normalised (0..1) to the upright photo.
  final Rect box;

  /// Upright photo size (pixels of the working copy; only the ratio matters).
  final int photoW, photoH;

  const StudioBox(this.box, this.photoW, this.photoH);

  double get aspect => photoW / photoH;
}

/// Builds "studio" versions of the capture photos fully on-device with two
/// TensorFlow Lite models (both Apache-2.0):
///  * U²-Netp (`u2netp.tflite`) finds the product / label (salient object);
///  * MediaPipe selfie-multiclass (`selfie_multiclass_256x256.tflite`) finds
///    skin, which is subtracted so hands holding the pack are removed.
///
/// Hand detection is best-effort: the skin model is trained on people, so it
/// catches clearly visible hands/fingers well but can miss a thumb in shadow.
/// Missing models degrade gracefully (no hand model → no hand removal; no
/// U²-Netp → no studio photo). The originals are always uploaded too.
class StudioImageService {
  static const objectModelAsset = 'assets/models/u2netp.tflite';
  static const handModelAsset = 'assets/models/selfie_multiclass_256x256.tflite';

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Clockwise quarter turns that make the photo's text upright (from OCR),
  /// or null when unknown. Used to stand up a product shot lying down.
  final Future<int?> Function(File photo)? uprightTurns;

  StudioImageService({this.uprightTurns});

  /// Background isolate that keeps both models loaded between photos.
  Future<_StudioWorker?>? _worker;

  /// Runs one at a time: each run holds two models and a large image in a
  /// background isolate, too much to multiply on a low-end phone.
  Future<void> _queue = Future.value();

  /// path|kind → result, so the review screen reuses what capture started.
  final _cache = <String, Future<StudioResult>>{};
  static const _cacheLimit = 9;

  /// path|kind → the product box of that photo, once the AI has found it.
  final _boxes = <String, ValueNotifier<StudioBox?>>{};

  /// The product box of [photo], filled in as soon as segmentation is done
  /// (before the studio image is composed). Null until then, or when no
  /// product was found. Works for camera shots and gallery photos alike.
  ValueListenable<StudioBox?> boxFor(File photo,
          {StudioKind kind = StudioKind.product}) =>
      _boxes['${photo.path}|${kind.name}'] ??= ValueNotifier(null);

  Future<_StudioWorker?> _ensureWorker() {
    final w = _worker ??= _StudioWorker.start();
    // A worker that failed to start (or died) is retried next time.
    return w.then((v) {
      if (v == null || v.dead) _worker = null;
      return v != null && !v.dead ? v : null;
    });
  }

  /// Starts the worker and loads the models ahead of the first photo, so
  /// the agent's first shot doesn't pay for it. Safe to call repeatedly.
  void warmUp() {
    if (isSupported) _ensureWorker();
  }

  /// Cached per photo and kind; [force] runs it again ("Try again").
  /// Never throws.
  Future<StudioResult> create(
    File original, {
    StudioKind kind = StudioKind.product,
    bool force = false,
  }) {
    final key = '${original.path}|${kind.name}';
    if (!force) {
      final hit = _cache.remove(key);
      if (hit != null) return _cache[key] = hit; // re-insert = most recent
    }
    final box = _boxes[key] ??= ValueNotifier(null);
    box.value = null;
    final job = _queue.then((_) => _create(original, kind, box));
    _queue = job.then((_) {}, onError: (_) {});
    _cache[key] = job;
    while (_cache.length > _cacheLimit) {
      _boxes.remove(_cache.keys.first);
      _cache.remove(_cache.keys.first);
    }
    return job;
  }

  Future<StudioResult> _create(
      File original, StudioKind kind, ValueNotifier<StudioBox?> box) async {
    if (!isSupported) return StudioResult.none;
    final worker = await _ensureWorker();
    if (worker == null) return StudioResult.none;
    try {
      // Which way is up (OCR text direction); never block long on it.
      int? turns;
      try {
        turns = await uprightTurns
            ?.call(original)
            .timeout(const Duration(seconds: 8), onTimeout: () => null);
      } catch (_) {}
      final bytes = await original.readAsBytes();
      final dir = await getTemporaryDirectory();
      final out = p.join(dir.path,
          'studio_${kind.name}_${DateTime.now().microsecondsSinceEpoch}.jpg');
      // Decode natively (hardware-accelerated, EXIF rotation applied and
      // downscaled while decoding): many times faster than decoding a 12 MP
      // JPEG in Dart. Falls back to the Dart decoder if that fails.
      final raw = await _decodeNative(bytes, _workingMaxFor(kind));
      final input = raw == null
          ? _PipelineInput.encoded(bytes)
          : _PipelineInput.raw(raw.rgba, raw.w, raw.h);
      // Two inferences and compositing take a few seconds on a low-end
      // phone, so they run in the background worker, which keeps both
      // models loaded: no isolate start-up or model loading per photo.
      final r = await worker.run(input, out, kind, turns,
          onBox: (b) => box.value = b);
      return StudioResult(
        file: r.ok ? File(out) : null,
        handDetected: r.hand,
        blurry: r.blurry,
      );
    } catch (e) {
      debugPrint('[StudioImageService] failed: $e');
      return StudioResult.none;
    }
  }

  /// Engine-side JPEG decode to RGBA, long side capped at [_workingMax].
  static Future<({TransferableTypedData rgba, int w, int h})?> _decodeNative(
      Uint8List bytes, int maxSide) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await ui.instantiateImageCodecWithSize(buffer,
          getTargetSize: (w, h) {
        final s = maxSide / math.max(w, h);
        // Width only keeps the aspect ratio whatever EXIF rotation does.
        return s < 1
            ? ui.TargetImageSize(width: (w * s).round())
            : const ui.TargetImageSize();
      });
      final frame = await codec.getNextFrame();
      codec.dispose();
      final image = frame.image;
      final data =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (data == null) return null;
      return (
        rgba: TransferableTypedData.fromList([data.buffer.asUint8List()]),
        w: w,
        h: h,
      );
    } catch (e) {
      debugPrint('[StudioImageService] native decode failed: $e');
      return null;
    }
  }
}

/// Photo handed to the isolate: raw RGBA from the engine, or the original
/// JPEG bytes when native decoding wasn't possible.
class _PipelineInput {
  final TransferableTypedData? rgba;
  final int w, h;
  final Uint8List? encoded;
  _PipelineInput.raw(TransferableTypedData this.rgba, this.w, this.h)
      : encoded = null;
  _PipelineInput.encoded(Uint8List this.encoded)
      : rgba = null,
        w = 0,
        h = 0;

  img.Image? toImage() {
    final t = rgba;
    if (t != null) {
      final bytes = t.materialize().asUint8List();
      return img.Image.fromBytes(
          width: w,
          height: h,
          bytes: bytes.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba);
    }
    final decoded = img.decodeImage(encoded!);
    if (decoded == null) return null;
    // Camera JPEGs often carry rotation in EXIF only; apply it first.
    return img.bakeOrientation(decoded);
  }
}

/// Long-lived background isolate running [_pipeline]. Loading the two
/// models (~20 MB) and spawning an isolate took a noticeable part of every
/// studio run; here it happens once and the interpreters are reused.
class _StudioWorker {
  final Isolate _isolate;
  final ReceivePort _inbox;
  late final SendPort _port;
  var _id = 0;
  final _pending =
      <int, Completer<({bool ok, bool hand, bool blurry})>>{};
  final _onBox = <int, void Function(StudioBox)>{};
  bool dead = false;

  _StudioWorker._(this._isolate, this._inbox);

  static Future<_StudioWorker?> start() async {
    Future<Uint8List?> load(String asset) async {
      try {
        final d = await rootBundle.load(asset);
        return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      } catch (e) {
        debugPrint('[StudioImageService] model missing: $asset ($e)');
        return null;
      }
    }

    final objectModel = await load(StudioImageService.objectModelAsset);
    if (objectModel == null) return null;
    final handModel = await load(StudioImageService.handModelAsset);
    try {
      final inbox = ReceivePort();
      final isolate = await Isolate.spawn(
          _studioWorkerMain, [inbox.sendPort, objectModel, handModel],
          debugName: 'studio-image-worker',
          onExit: inbox.sendPort,
          onError: inbox.sendPort);
      final worker = _StudioWorker._(isolate, inbox);
      final ready = Completer<SendPort?>();
      inbox.listen((msg) {
        if (msg is SendPort) {
          ready.complete(msg);
        } else if (msg is List && msg.length == 7 && msg[0] == 'box') {
          // Early message: the product's box, before the image is composed.
          worker._onBox[msg[1] as int]?.call(StudioBox(
              Rect.fromLTRB(msg[2] as double, msg[3] as double,
                  msg[4] as double, msg[5] as double),
              (msg[6] as List)[0] as int,
              (msg[6] as List)[1] as int));
        } else if (msg is List && msg.length == 4 && msg[0] is int) {
          worker._onBox.remove(msg[0] as int);
          worker._pending.remove(msg[0] as int)?.complete(
              (ok: msg[1] as bool, hand: msg[2] as bool, blurry: msg[3] as bool));
        } else if (msg == null || msg is List) {
          // Exited or crashed (e.g. out of memory): fail what's waiting and
          // let the service start a fresh worker next time.
          worker._die();
          if (!ready.isCompleted) ready.complete(null);
        }
      });
      final port = await ready.future;
      if (port == null) return null;
      worker._port = port;
      return worker;
    } catch (e) {
      debugPrint('[StudioImageService] worker failed to start: $e');
      return null;
    }
  }

  Future<({bool ok, bool hand, bool blurry})> run(
      _PipelineInput input, String out, StudioKind kind, int? turns,
      {void Function(StudioBox)? onBox}) {
    if (dead) return Future.value((ok: false, hand: false, blurry: false));
    final id = _id++;
    final c = Completer<({bool ok, bool hand, bool blurry})>();
    _pending[id] = c;
    if (onBox != null) _onBox[id] = onBox;
    _port.send([id, input, out, kind.index, turns]);
    return c.future;
  }

  void _die() {
    if (dead) return;
    dead = true;
    for (final c in _pending.values) {
      c.complete((ok: false, hand: false, blurry: false));
    }
    _pending.clear();
    _onBox.clear();
    _inbox.close();
    _isolate.kill();
  }
}

void _studioWorkerMain(List<Object?> args) {
  final reply = args[0] as SendPort;
  final object = Interpreter.fromBuffer(args[1] as Uint8List,
      options: InterpreterOptions()..threads = 4);
  Interpreter? hand;
  if (args[2] case final Uint8List bytes) {
    try {
      hand = Interpreter.fromBuffer(bytes,
          options: InterpreterOptions()..threads = 4);
    } catch (e) {
      // Hand removal is an extra: never fail the studio photo because of it.
      debugPrint('[StudioImageService] hand model failed to load: $e');
    }
  }
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((msg) {
    final m = msg as List;
    final id = m[0] as int;
    try {
      final r = _pipeline(object, hand, m[1] as _PipelineInput, m[2] as String,
          StudioKind.values[m[3] as int], m[4] as int?,
          onBox: (b, w, h) => reply.send(
              ['box', id, b.left, b.top, b.right, b.bottom, [w, h]]));
      reply.send([id, r.ok, r.hand, r.blurry]);
    } catch (e) {
      debugPrint('[StudioImageService] failed: $e');
      reply.send([id, false, false, false]);
    }
  });
}

// ── Background-isolate pipeline ─────────────────────────────────────────────

/// Long side the photo is reduced to before processing. High enough that the
/// product itself is never upscaled into the 1600 px canvas (that upscaling
/// was what made studio shots soft), low enough to stay fast on a 12–50 MP
/// phone. Labels keep more pixels so small print stays readable.
int _workingMaxFor(StudioKind kind) =>
    kind == StudioKind.product ? 2400 : 2800;

/// Laplacian variance below this (measured on the product area at ~1000 px)
/// means camera shake or missed focus. Sharp packs score in the hundreds.
const double blurThreshold = 55;

({bool ok, bool hand, bool blurry}) _pipeline(
    Interpreter objectModel,
    Interpreter? handModel,
    _PipelineInput input,
    String outPath,
    StudioKind kind,
    int? turns,
    {void Function(Rect box, int photoW, int photoH)? onBox}) {
  var photo = input.toImage();
  if (photo == null) return (ok: false, hand: false, blurry: false);
  final maxSide = _workingMaxFor(kind);
  final longSide = math.max(photo.width, photo.height);
  if (longSide > maxSide) {
    final s = maxSide / longSide;
    photo = img.copyResize(photo,
        width: (photo.width * s).round(),
        height: (photo.height * s).round(),
        interpolation: img.Interpolation.average);
  }

  final object = _runObjectModel(objectModel, photo);
  if (object == null) return (ok: false, hand: false, blurry: false);
  final people = handModel == null ? null : _runSkinModel(handModel, photo);
  // Skin-coloured print (pink/orange packs) isn't a hand: only skin that
  // reaches out past the product is kept, so the pack's own colours are
  // never erased into washed-out patches.
  final rawSkin = people?.skin;
  final skin = rawSkin == null
      ? null
      : (mask: filterSkinToHands(rawSkin, object), w: rawSkin.w, h: rawSkin.h);

  final hand = skin != null && handOverlapsObject(object, skin);
  // Sleeves/arms only matter (and are only cut) when a hand holds the pack;
  // otherwise a fabric-like label could be mistaken for clothes.
  final person = hand ? people?.person : null;

  // The product alone: hand, arm and sleeve, and any stray salient blobs,
  // are dropped at mask level before anything else.
  final refined = refineObjectMask(object.mask, object.w, object.h,
      skin: skin?.mask, person: person, skinW: skin?.w ?? 0,
      skinH: skin?.h ?? 0);

  // Tell the UI where the product is right away; composing takes longer.
  if (onBox != null) {
    final b = productBox(refined, object.w, object.h);
    if (b != null) onBox(b, photo.width, photo.height);
  }

  // Sharpness of the product area only (the background may be soft on
  // purpose); downscaled to a fixed size so phones with different sensors
  // score alike.
  var blurry = false;
  final box = subjectBounds(refined, object.w, object.h,
      photo.width, photo.height);
  if (box != null) {
    blurry = laplacianVariance(photo, region: box) < blurThreshold;
  }

  final result = composeFromMask(photo, refined, object.w, object.h,
      skin: skin?.mask,
      person: person,
      skinW: skin?.w ?? 0,
      skinH: skin?.h ?? 0,
      kind: kind,
      quarterTurns: turns);
  if (result == null) return (ok: false, hand: hand, blurry: blurry);
  File(outPath).writeAsBytesSync(img.encodeJpg(result, quality: 95));
  return (ok: true, hand: hand, blurry: blurry);
}

/// Variance of the 4-neighbour Laplacian of the luma: the standard focus
/// measure. Low = few sharp edges = blurry. Measured on [region] (default
/// the whole image), box-averaged down to ~1000 px so phones with different
/// sensors score alike.
@visibleForTesting
double laplacianVariance(img.Image im,
    {({int x, int y, int w, int h})? region}) {
  final r = region ?? (x: 0, y: 0, w: im.width, h: im.height);
  final step = math.max(1, (math.max(r.w, r.h) / 1000).ceil());
  final w = r.w ~/ step, h = r.h ~/ step;
  if (w < 3 || h < 3) return 0;
  final luma = Float32List(w * h);
  final raw = _rawUint8(im);
  if (raw != null) {
    final nc = im.numChannels, row = im.width * nc;
    final inv = 1 / (step * step);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var s = 0.0;
        for (var dy = 0; dy < step; dy++) {
          var i = (r.y + y * step + dy) * row + (r.x + x * step) * nc;
          for (var dx = 0; dx < step; dx++, i += nc) {
            s += 0.299 * raw[i] + 0.587 * raw[i + 1] + 0.114 * raw[i + 2];
          }
        }
        luma[y * w + x] = s * inv;
      }
    }
  } else {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final px = im.getPixel(r.x + x * step, r.y + y * step);
        luma[y * w + x] = 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
      }
    }
  }
  var sum = 0.0, sumSq = 0.0;
  var n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final l = luma[i - 1] + luma[i + 1] + luma[i - w] + luma[i + w] -
          4 * luma[i];
      sum += l;
      sumSq += l * l;
      n++;
    }
  }
  final mean = sum / n;
  return sumSq / n - mean * mean;
}

/// Tight box of the product in a refined mask (cells ≥ 0.5), normalised to
/// 0..1, or null when nothing is left or it's a speck.
@visibleForTesting
Rect? productBox(Float32List mask, int w, int h) {
  var x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (mask[y * w + x] < 0.5) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) return null;
  final r = Rect.fromLTRB(x0 / w, y0 / h, (x1 + 1) / w, (y1 + 1) / h);
  return r.width * r.height < 0.005 ? null : r;
}

/// Bounding box (in photo pixels, with a one-cell margin) of the salient
/// area of a low-res [mask], or null if nothing stands out.
@visibleForTesting
({int x, int y, int w, int h})? subjectBounds(
    Float32List mask, int maskW, int maskH, int photoW, int photoH) {
  var lo = double.infinity, hi = -double.infinity;
  for (var i = 0; i < maskW * maskH; i++) {
    lo = math.min(lo, mask[i]);
    hi = math.max(hi, mask[i]);
  }
  if (hi - lo < 0.2) return null;
  var x0 = maskW, y0 = maskH, x1 = -1, y1 = -1;
  for (var y = 0; y < maskH; y++) {
    for (var x = 0; x < maskW; x++) {
      if ((mask[y * maskW + x] - lo) / (hi - lo) < 0.25) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) return null;
  final cw = photoW / maskW, ch = photoH / maskH;
  final left = ((x0 - 1) * cw).floor().clamp(0, photoW - 1);
  final top = ((y0 - 1) * ch).floor().clamp(0, photoH - 1);
  final right = ((x1 + 2) * cw).ceil().clamp(left + 1, photoW);
  final bottom = ((y1 + 2) * ch).ceil().clamp(top + 1, photoH);
  return (x: left, y: top, w: right - left, h: bottom - top);
}

/// A low-res probability map, row-major w×h, values 0..1.
typedef SegMask = ({Float32List mask, int w, int h});

/// U²-Netp: resize to S×S, scale by the image max, ImageNet mean/std.
/// Output is a sigmoid saliency map; returned min-max normalised to 0..1.
SegMask? _runObjectModel(Interpreter it, img.Image photo) {
  {
    final input = it.getInputTensor(0);
    if (input.type != TensorType.float32) return null;
    final shape = input.shape; // [1,3,S,S] (NCHW) or [1,S,S,3] (NHWC)
    final nchw = shape.length == 4 && shape[1] == 3;
    final size = nchw ? shape[2] : shape[1];

    final small = img.copyResize(photo,
        width: size, height: size, interpolation: img.Interpolation.linear);
    var maxV = 1.0;
    for (final px in small) {
      maxV = math.max(maxV, math.max(px.r, math.max(px.g, px.b)).toDouble());
    }
    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    final x = Float32List(3 * size * size);
    final plane = size * size;
    for (final px in small) {
      final i = px.y * size + px.x;
      final rgb = [px.r / maxV, px.g / maxV, px.b / maxV];
      for (var c = 0; c < 3; c++) {
        final v = (rgb[c] - mean[c]) / std[c];
        if (nchw) {
          x[c * plane + i] = v;
        } else {
          x[i * 3 + c] = v;
        }
      }
    }
    it.runInference([x.buffer.asUint8List()]);
    final out = _floats(it.getOutputTensor(0).data);
    if (out.length < plane) return null;

    var lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < plane; i++) {
      lo = math.min(lo, out[i]);
      hi = math.max(hi, out[i]);
    }
    if (hi - lo < 0.2) return null; // flat: nothing salient
    final m = Float32List(plane);
    for (var i = 0; i < plane; i++) {
      m[i] = (out[i] - lo) / (hi - lo);
    }
    return (mask: m, w: size, h: size);
  }
}

/// MediaPipe selfie-multiclass: NHWC 256×256 RGB in [0,1]; output is 6 class
/// logits per pixel (background, hair, body-skin, face-skin, clothes,
/// other). Returns skin = P(body-skin) + P(face-skin) and person = skin +
/// hair + clothes (an arm's sleeve) after softmax, both at the same size.
({SegMask skin, Float32List person})? _runSkinModel(
    Interpreter it, img.Image photo) {
  try {
    {
      final input = it.getInputTensor(0);
      final h = input.shape[1], w = input.shape[2];
      final small = img.copyResize(photo,
          width: w, height: h, interpolation: img.Interpolation.linear);
      final x = Float32List(w * h * 3);
      for (final px in small) {
        final i = (px.y * w + px.x) * 3;
        x[i] = px.r / 255.0;
        x[i + 1] = px.g / 255.0;
        x[i + 2] = px.b / 255.0;
      }
      it.runInference([x.buffer.asUint8List()]);
      final out = _floats(it.getOutputTensor(0).data);
      const classes = 6;
      if (out.length < w * h * classes) return null;
      final skin = Float32List(w * h);
      final person = Float32List(w * h);
      for (var i = 0; i < w * h; i++) {
        final o = i * classes;
        var mx = out[o];
        for (var c = 1; c < classes; c++) {
          mx = math.max(mx, out[o + c]);
        }
        var sum = 0.0;
        final e = List<double>.filled(classes, 0);
        for (var c = 0; c < classes; c++) {
          e[c] = math.exp(out[o + c] - mx);
          sum += e[c];
        }
        skin[i] = (e[2] + e[3]) / sum;
        person[i] = (e[1] + e[2] + e[3] + e[4]) / sum;
      }
      return (skin: (mask: skin, w: w, h: h), person: person);
    }
  } catch (e) {
    // Hand removal is an extra: never fail the studio photo because of it.
    debugPrint('[StudioImageService] skin model failed: $e');
    return null;
  }
}

Float32List _floats(Uint8List bytes) =>
    Uint8List.fromList(bytes).buffer.asFloat32List();

/// True when confident skin sits on or right next to the product: that's a
/// hand holding it, not a face in the background. Shared with the live
/// camera detector, so its hand warning matches the studio photo.
bool handOverlapsObject(SegMask object, SegMask skin) {
  var overlap = 0;
  for (var y = 0; y < skin.h; y++) {
    for (var x = 0; x < skin.w; x++) {
      if (skin.mask[y * skin.w + x] < 0.5) continue;
      final o = _bilinear(object.mask, object.w, object.h,
          x * object.w / skin.w, y * object.h / skin.h);
      if (o > 0.3) overlap++;
    }
  }
  return overlap > skin.w * skin.h * 0.004; // ~260 px of 65k
}

/// Keeps only the product in a low-res saliency [mask] (returned normalised
/// 0..1, same size), so a held pack comes out clean:
///  * cells that are skin, or (when [person] is given) arm/sleeve/hair, are
///    cut, with a small margin so a wrist's rim goes too;
///  * a morphological opening breaks thin bridges (fingers, a wrist) that
///    still join the pack to the arm;
///  * of what's left, the single best blob is kept: the biggest, with
///    blobs touching the photo edge (an arm entering the frame) penalised.
/// Stray soft blobs (the ghostly arm smear) disappear with it.
Float32List refineObjectMask(
  Float32List mask,
  int w,
  int h, {
  Float32List? skin,
  Float32List? person,
  int skinW = 0,
  int skinH = 0,
}) {
  final n = w * h;
  var lo = double.infinity, hi = -double.infinity;
  for (var i = 0; i < n; i++) {
    lo = math.min(lo, mask[i]);
    hi = math.max(hi, mask[i]);
  }
  if (hi - lo < 0.2) return mask; // nothing salient; caller bails out
  final m = Float32List(n);
  for (var i = 0; i < n; i++) {
    m[i] = (mask[i] - lo) / (hi - lo);
  }

  // People cells (skin, plus sleeve/hair when a hand is holding the pack).
  var cut = Uint8List(n);
  if (skin != null && skinW > 0 && skinH > 0) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final sx = (x + 0.5) * skinW / w - 0.5, sy = (y + 0.5) * skinH / h - 0.5;
        final s = _bilinear(skin, skinW, skinH, sx, sy);
        final p = person == null ? 0.0 : _bilinear(person, skinW, skinH, sx, sy);
        if (s > 0.4 || p > 0.6) cut[y * w + x] = 1;
      }
    }
    cut = _morph(cut, w, h, 2, dilate: true);
  }

  var solid = Uint8List(n);
  for (var i = 0; i < n; i++) {
    solid[i] = m[i] >= 0.5 && cut[i] == 0 ? 1 : 0;
  }
  solid = _morph(_morph(solid, w, h, 1, dilate: false), w, h, 1, dilate: true);

  // Connected components (4-neighbour), pick the best one.
  final label = Int32List(n)..fillRange(0, n, -1);
  final stack = <int>[];
  var best = -1;
  var bestScore = 0.0;
  var next = 0;
  for (var start = 0; start < n; start++) {
    if (solid[start] == 0 || label[start] >= 0) continue;
    final id = next++;
    var area = 0;
    var edge = false;
    label[start] = id;
    stack.add(start);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      area++;
      final x = i % w, y = i ~/ w;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) edge = true;
      void visit(int j) {
        if (solid[j] == 1 && label[j] < 0) {
          label[j] = id;
          stack.add(j);
        }
      }

      if (x > 0) visit(i - 1);
      if (x < w - 1) visit(i + 1);
      if (y > 0) visit(i - w);
      if (y < h - 1) visit(i + w);
    }
    final score = area * (edge ? 0.35 : 1.0);
    if (score > bestScore) {
      bestScore = score;
      best = id;
    }
  }
  final out = Float32List(n);
  if (best < 0) return out; // all cut away: caller reports "not clear"

  var body = Uint8List(n);
  for (var i = 0; i < n; i++) {
    body[i] = label[i] == best ? 1 : 0;
  }
  // Only the product: drop attached surroundings outside its confident
  // outline ([hull] is a smooth 0..1 weight, null when not applied).
  final core = _coreHull(body, m, w, h);
  final hull = core?.weight;
  if (core != null) body = core.body;

  // Fill holes: glare or a low-contrast patch inside the pack must not show
  // the backdrop through it. Holes left by a hand (cut cells) stay open.
  final outside = Uint8List(n);
  final flood = <int>[];
  void seed(int i) {
    if (body[i] == 0 && outside[i] == 0) {
      outside[i] = 1;
      flood.add(i);
    }
  }

  for (var x = 0; x < w; x++) {
    seed(x);
    seed((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    seed(y * w);
    seed(y * w + w - 1);
  }
  while (flood.isNotEmpty) {
    final i = flood.removeLast();
    final x = i % w, y = i ~/ w;
    if (x > 0) seed(i - 1);
    if (x < w - 1) seed(i + 1);
    if (y > 0) seed(i - w);
    if (y < h - 1) seed(i + w);
  }
  for (var i = 0; i < n; i++) {
    if (body[i] == 0 && outside[i] == 0 && cut[i] == 0) body[i] = 1;
  }

  // Trim stubs sticking out of the outline (a thumb in shadow the skin model
  // missed, a sliver of table): an opening sized to the product finds parts
  // narrower than ~16% of it; of those, only sizeable pieces are dropped, so
  // the small slivers an opening shaves off corners stay and the pack keeps
  // its exact shape.
  var x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (var i = 0; i < n; i++) {
    if (body[i] == 0) continue;
    final x = i % w, y = i ~/ w;
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
  }
  final r = math.max(2, (math.min(x1 - x0 + 1, y1 - y0 + 1) * 0.08).round());
  final opened =
      _morph(_morph(body, w, h, r, dilate: false), w, h, r, dilate: true);
  final stub = Uint8List(n);
  for (var i = 0; i < n; i++) {
    stub[i] = body[i] == 1 && opened[i] == 0 ? 1 : 0;
  }
  final drop = Uint8List(n);
  final stubs = _components(stub, w, h);
  for (var i = 0; i < n; i++) {
    final c = stubs.label[i];
    if (c >= 0 && stubs.area[c] > r * r) drop[i] = 1;
  }
  for (var i = 0; i < n; i++) {
    if (drop[i] == 1) body[i] = 0;
  }

  // Grow the kept blob back over its soft edge (not into people cells or
  // dropped stubs), so the pixel-level alpha gets a smooth, accurate
  // outline. Inside the body the mask is solid, so the pack is fully opaque.
  final keep = _morph(body, w, h, 2, dilate: true);
  // Soft (blurred) keep weight instead of a hard cell-by-cell cut, so where
  // the outline is decided by the clean-up rather than the model (a removed
  // stub, a hand, the edge of the core), it comes out smooth, not as
  // staircase steps.
  final weight = Float32List(n);
  for (var i = 0; i < n; i++) {
    if (keep[i] == 1 && cut[i] == 0 && drop[i] == 0) weight[i] = 1;
  }
  final soft = _boxBlur(weight, w, h, 1);
  for (var i = 0; i < n; i++) {
    if (soft[i] == 0) continue;
    out[i] = (body[i] == 1 ? math.max(m[i], 0.8) : m[i]) *
        soft[i] *
        (hull == null ? 1.0 : hull[i]);
  }
  return out;
}

/// The model is most certain about the product itself; things around it
/// that merely look interesting (a web page or packaging around the pack on
/// a screen, a shelf edge, a printed backdrop) often score medium and touch
/// it. The product's confident parts (its "core") are found, and everything
/// outside their convex outline (bar the product's own ~1-cell soft edge) is
/// cut. Inside the outline nothing is cut, so a label's white areas (which
/// score lower than its coloured print) stay.
///
/// Returns the restricted body and a smooth 0..1 weight (1 inside, 0 more
/// than a margin outside), so the cut is a straight clean line rather than
/// cell-sized steps. Null when the object has no clear core (uniformly
/// medium saliency), in which case nothing is cut.
({Uint8List body, Float32List weight})? _coreHull(
    Uint8List body, Float32List m, int w, int h) {
  final n = w * h;
  var area = 0;
  final core = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (body[i] == 0) continue;
    area++;
    if (m[i] >= 0.8) core[i] = 1;
  }
  final comps = _components(core, w, h);
  if (comps.area.isEmpty) return null;
  final biggest = comps.area.reduce(math.max);
  var total = 0;
  final use = <bool>[
    for (final a in comps.area) a >= biggest * 0.1,
  ];
  for (var c = 0; c < use.length; c++) {
    if (use[c]) total += comps.area[c];
  }
  if (total < area * 0.3) return null;

  // Hull of the used core parts: per row, the leftmost and rightmost cells.
  final pts = <math.Point<double>>[];
  for (var y = 0; y < h; y++) {
    var l = -1, r = -1;
    for (var x = 0; x < w; x++) {
      final c = comps.label[y * w + x];
      if (c < 0 || !use[c]) continue;
      if (l < 0) l = x;
      r = x;
    }
    if (l < 0) continue;
    pts
      ..add(math.Point(l.toDouble(), y.toDouble()))
      ..add(math.Point(r.toDouble(), y.toDouble()));
  }
  final hull = convexHull(pts);
  if (hull.length < 3) return null;

  final weight = Float32List(n);
  final out = Uint8List(n);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = _insideDistance(hull, x.toDouble(), y.toDouble());
      final i = y * w + x;
      // Solid product only inside the outline. Just outside it, the model's
      // own soft edge fades out within ~1 cell: enough for a natural edge,
      // too little for a strip of the surroundings to survive.
      weight[i] = (d + 1.5).clamp(0.0, 1.0);
      if (body[i] == 1 && d >= -0.25) out[i] = 1;
    }
  }
  return (body: out, weight: weight);
}

/// Convex hull (Andrew's monotone chain), counter-clockwise in a y-up sense.
@visibleForTesting
List<math.Point<double>> convexHull(List<math.Point<double>> points) {
  final p = [...points]
    ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  if (p.length < 3) return p;
  double cross(math.Point<double> o, math.Point<double> a,
          math.Point<double> b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <math.Point<double>>[];
  for (final q in p) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  final upper = <math.Point<double>>[];
  for (final q in p.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Signed distance from (x, y) to the edges of a convex [hull] (as returned
/// by [convexHull]): positive inside, negative outside (exact near edges,
/// which is all that matters for the soft margin).
double _insideDistance(List<math.Point<double>> hull, double x, double y) {
  var d = double.infinity;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    final ex = b.x - a.x, ey = b.y - a.y;
    final len = math.sqrt(ex * ex + ey * ey);
    if (len == 0) continue;
    // Monotone chain's order has the interior on the left of each edge.
    final e = (ex * (y - a.y) - ey * (x - a.x)) / len;
    if (e < d) d = e;
  }
  return d;
}

/// Separable box blur with radius [r] (edges clamp to zero outside).
Float32List _boxBlur(Float32List src, int w, int h, int r) {
  final tmp = Float32List(w * h), out = Float32List(w * h);
  final k = 1 / (2 * r + 1);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var d = -r; d <= r; d++) {
        final xx = x + d;
        if (xx >= 0 && xx < w) s += src[y * w + xx];
      }
      tmp[y * w + x] = s * k;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var d = -r; d <= r; d++) {
        final yy = y + d;
        if (yy >= 0 && yy < h) s += tmp[yy * w + x];
      }
      out[y * w + x] = s * k;
    }
  }
  return out;
}

/// 4-connected components of a binary grid: per-cell label (−1 = off) and
/// each component's area.
({Int32List label, List<int> area}) _components(Uint8List bin, int w, int h) {
  final n = w * h;
  final label = Int32List(n)..fillRange(0, n, -1);
  final area = <int>[];
  final stack = <int>[];
  for (var start = 0; start < n; start++) {
    if (bin[start] == 0 || label[start] >= 0) continue;
    final id = area.length;
    var a = 0;
    label[start] = id;
    stack.add(start);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      a++;
      final x = i % w, y = i ~/ w;
      void visit(int j) {
        if (bin[j] == 1 && label[j] < 0) {
          label[j] = id;
          stack.add(j);
        }
      }

      if (x > 0) visit(i - 1);
      if (x < w - 1) visit(i + 1);
      if (y > 0) visit(i - w);
      if (y < h - 1) visit(i + w);
    }
    area.add(a);
  }
  return (label: label, area: area);
}

/// Keeps only skin regions that reach out past the product: a hand holding
/// a pack always extends beyond it (the palm, the wrist), while skin-like
/// print on a pink or orange pack lies entirely inside it. Those inside-only
/// regions are zeroed so they're neither cut out nor reported as a hand.
Float32List filterSkinToHands(SegMask skin, SegMask object) {
  final w = skin.w, h = skin.h, n = w * h;
  final bin = Uint8List(n);
  for (var i = 0; i < n; i++) {
    bin[i] = skin.mask[i] > 0.4 ? 1 : 0;
  }
  final comps = _components(bin, w, h);
  final outsideCells = List<int>.filled(comps.area.length, 0);
  for (var i = 0; i < n; i++) {
    final c = comps.label[i];
    if (c < 0) continue;
    final x = i % w, y = i ~/ w;
    final o = _bilinear(object.mask, object.w, object.h,
        (x + 0.5) * object.w / w - 0.5, (y + 0.5) * object.h / h - 0.5);
    if (o < 0.3) outsideCells[c]++;
  }
  final out = Float32List.fromList(skin.mask);
  // Everything not on or right next to a real hand is zeroed, including the
  // weak skin values around a dropped region, so no faint fringe remains.
  final kept = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final c = comps.label[i];
    if (c >= 0 && outsideCells[c] >= 4) kept[i] = 1;
  }
  final near = _morph(kept, w, h, 3, dilate: true);
  for (var i = 0; i < n; i++) {
    if (near[i] == 0) out[i] = 0;
  }
  return out;
}

/// Square-window binary dilation/erosion with radius [r].
Uint8List _morph(Uint8List src, int w, int h, int r, {required bool dilate}) {
  // Separable: rows then columns.
  final tmp = Uint8List(w * h), out = Uint8List(w * h);
  final hit = dilate ? 1 : 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 1 - hit;
      for (var k = -r; k <= r && v != hit; k++) {
        final xx = x + k;
        // Outside the image counts as background for both operations.
        final s = xx < 0 || xx >= w ? 0 : src[y * w + xx];
        if (s == hit) v = hit;
      }
      tmp[y * w + x] = v;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 1 - hit;
      for (var k = -r; k <= r && v != hit; k++) {
        final yy = y + k;
        final s = yy < 0 || yy >= h ? 0 : tmp[yy * w + x];
        if (s == hit) v = hit;
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

/// Long side of the [StudioKind.product] canvas.
const int _canvas = 1600;

/// Turns [photo] plus a low-res saliency [mask] (0..1, row-major
/// [maskW]×[maskH]) into the studio image, or null if no clear subject.
/// When [skin] is given, skin pixels are cut out so hands disappear.
/// [quarterTurns] (clockwise) stands the product upright; null = unknown,
/// in which case a product clearly lying on its side is stood up.
/// Pure Dart, so it's unit-testable without the TFLite runtime.
@visibleForTesting
img.Image? composeFromMask(
  img.Image photo,
  Float32List mask,
  int maskW,
  int maskH, {
  Float32List? skin,
  Float32List? person,
  int skinW = 0,
  int skinH = 0,
  StudioKind kind = StudioKind.product,
  int? quarterTurns,
}) {
  // Product only: drops hands/arms/stray blobs (idempotent if the caller
  // already refined it).
  mask = refineObjectMask(mask, maskW, maskH,
      skin: skin, person: person, skinW: skinW, skinH: skinH);

  // Normalise defensively (callers/tests may pass raw values).
  var lo = double.infinity, hi = -double.infinity;
  for (var i = 0; i < maskW * maskH; i++) {
    lo = math.min(lo, mask[i]);
    hi = math.max(hi, mask[i]);
  }
  if (hi - lo < 0.2) return null;
  final invRange = 1 / (hi - lo);

  // Only the product's neighbourhood is processed, at the photo's full
  // working resolution: fast, and every output pixel is a real camera pixel.
  final region = subjectBounds(mask, maskW, maskH, photo.width, photo.height);
  if (region == null) return null;
  var crop = img.copyCrop(photo,
      x: region.x, y: region.y, width: region.w, height: region.h);
  if (crop.numChannels != 4 ||
      crop.format != img.Format.uint8 ||
      crop.hasPalette) {
    crop = crop.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  }

  // Alpha = object × (1 − skin), written straight into the pixel buffer
  // (per-pixel objects are ~10× slower, and this loop covers millions of
  // pixels). The mask is ~10× coarser than the photo, so a narrow
  // smoothstep keeps the outline crisp without stair-steps.
  final buf = crop.toUint8List();
  final rw = crop.width, rh = crop.height;
  final hasSkin = skin != null && skinW > 0 && skinH > 0;
  final mx = _axis(rw, region.x, maskW / photo.width, maskW);
  final my = _axis(rh, region.y, maskH / photo.height, maskH);
  final kx = hasSkin ? _axis(rw, region.x, skinW / photo.width, skinW) : null;
  final ky = hasSkin ? _axis(rh, region.y, skinH / photo.height, skinH) : null;
  var minX = rw, minY = rh, maxX = -1, maxY = -1;
  for (var y = 0; y < rh; y++) {
    final r0 = my.i0[y] * maskW, r1 = my.i1[y] * maskW;
    final fy = my.f[y];
    final s0 = hasSkin ? ky!.i0[y] * skinW : 0;
    final s1 = hasSkin ? ky!.i1[y] * skinW : 0;
    final sfy = hasSkin ? ky!.f[y] : 0.0;
    var p = y * rw * 4 + 3;
    for (var x = 0; x < rw; x++, p += 4) {
      final x0 = mx.i0[x], x1 = mx.i1[x];
      final fx = mx.f[x];
      final top = mask[r0 + x0] + (mask[r0 + x1] - mask[r0 + x0]) * fx;
      final bot = mask[r1 + x0] + (mask[r1 + x1] - mask[r1 + x0]) * fx;
      var a = _smoothstep(0.4, 0.6, (top + (bot - top) * fy - lo) * invRange);
      if (hasSkin && a > 0) {
        final a0 = kx!.i0[x], a1 = kx.i1[x];
        final sfx = kx.f[x];
        final st = skin[s0 + a0] + (skin[s0 + a1] - skin[s0 + a0]) * sfx;
        final sb = skin[s1 + a0] + (skin[s1 + a1] - skin[s1 + a0]) * sfx;
        // Narrow band: skin is cut cleanly, never half-faded into a smear.
        a *= 1 - _smoothstep(0.45, 0.55, st + (sb - st) * sfy);
      }
      final av = (a * 255).round();
      buf[p] = av;
      if (av >= 128) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return null;
  final boxW = maxX - minX + 1, boxH = maxY - minY + 1;
  // A tiny "subject" is almost always a false hit on clutter.
  if (boxW * boxH < photo.width * photo.height * 0.03) return null;

  var subject =
      img.copyCrop(crop, x: minX, y: minY, width: boxW, height: boxH);

  // Stand it up: OCR says which way the text reads; without text, a
  // product much wider than tall was shot lying down.
  var turns = quarterTurns ?? 0;
  if (quarterTurns == null &&
      kind == StudioKind.product &&
      boxW > boxH * 1.4) {
    turns = 3;
  }
  subject = rotateQuarter(subject, turns);

  return kind == StudioKind.product
      ? _productCanvas(subject)
      : _labelCanvas(subject);
}

/// Per output column (or row) [i] in 0..n: the two mask cells around it and
/// the blend factor, for bilinear sampling without per-pixel clamping.
({Int32List i0, Int32List i1, Float32List f}) _axis(
    int n, int offset, double scale, int size) {
  final i0 = Int32List(n), i1 = Int32List(n);
  final f = Float32List(n);
  for (var i = 0; i < n; i++) {
    final c = ((i + offset + 0.5) * scale - 0.5).clamp(0.0, size - 1.0);
    final a = c.floor();
    i0[i] = a;
    i1[i] = math.min(a + 1, size - 1);
    f[i] = c - a;
  }
  return (i0: i0, i1: i1, f: f);
}

/// Raw interleaved pixel bytes (a live view), when the image is plain 8-bit
/// RGB/RGBA; null otherwise.
Uint8List? _rawUint8(img.Image im) => im.format == img.Format.uint8 &&
        !im.hasPalette &&
        im.numChannels >= 3
    ? im.toUint8List()
    : null;

/// Rotates by [turns] × 90° clockwise, copying bytes directly.
@visibleForTesting
img.Image rotateQuarter(img.Image src, int turns) {
  turns %= 4;
  if (turns == 0) return src;
  final raw = _rawUint8(src);
  if (raw == null) return img.copyRotate(src, angle: 90 * turns);
  final w = src.width, h = src.height, nc = src.numChannels;
  final dw = turns == 2 ? w : h, dh = turns == 2 ? h : w;
  final dst = img.Image(width: dw, height: dh, numChannels: nc);
  final out = dst.toUint8List();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final int tx, ty;
      switch (turns) {
        case 1:
          tx = h - 1 - y;
          ty = x;
        case 2:
          tx = w - 1 - x;
          ty = h - 1 - y;
        default:
          tx = y;
          ty = w - 1 - x;
      }
      final s = (y * w + x) * nc, d = (ty * dw + tx) * nc;
      for (var c = 0; c < nc; c++) {
        out[d + c] = raw[s + c];
      }
    }
  }
  return dst;
}

/// Resize to exactly [w]×[h]. Enlarging: bicubic (smoother than bilinear,
/// no blocky pixels). Shrinking: bilinear, or area-average when shrinking
/// more than 2× (no aliasing), then a light unsharp mask to win back the
/// crispness resampling costs.
img.Image _resizeTo(img.Image im, int w, int h, double sharpen) {
  if (w == im.width && h == im.height) return im;
  final s = w / im.width;
  if (s >= 1) {
    return img.copyResize(im,
        width: w, height: h, interpolation: img.Interpolation.cubic);
  }
  return _sharpen(
      img.copyResize(im,
          width: w,
          height: h,
          interpolation: s < 0.5
              ? img.Interpolation.average
              : img.Interpolation.linear),
      sharpen);
}

/// Draws RGBA [src] over [dst] at ([dx], [dy]) with straight alpha.
void _blendOnto(img.Image dst, img.Image src, int dx, int dy) {
  final d = _rawUint8(dst), s = _rawUint8(src);
  if (d == null || s == null || src.numChannels != 4) {
    img.compositeImage(dst, src, dstX: dx, dstY: dy);
    return;
  }
  final dn = dst.numChannels;
  for (var y = 0; y < src.height; y++) {
    final ty = dy + y;
    if (ty < 0 || ty >= dst.height) continue;
    for (var x = 0; x < src.width; x++) {
      final tx = dx + x;
      if (tx < 0 || tx >= dst.width) continue;
      final si = (y * src.width + x) * 4;
      final a = s[si + 3];
      if (a == 0) continue;
      final di = (ty * dst.width + tx) * dn;
      if (a == 255) {
        d[di] = s[si];
        d[di + 1] = s[si + 1];
        d[di + 2] = s[si + 2];
      } else {
        for (var c = 0; c < 3; c++) {
          d[di + c] = (d[di + c] + (s[si + c] - d[di + c]) * a / 255).round();
        }
      }
    }
  }
}

/// Labels are kept at camera resolution up to this long side (small print
/// stays readable; beyond it the file just grows).
const int _labelMax = 2800;

/// Label: the cut-out on plain white with a thin margin, at full working
/// resolution (never upscaled, so small print stays readable and crisp).
img.Image _labelCanvas(img.Image subject) {
  final long = math.max(subject.width, subject.height);
  if (long > _labelMax) {
    final s = _labelMax / long;
    subject = _resizeTo(subject, math.max(1, (subject.width * s).round()),
        math.max(1, (subject.height * s).round()), 0.35);
  }
  final pad = math.max(4, (math.max(subject.width, subject.height) * 0.015)
      .round());
  final canvas = img.Image(
      width: subject.width + pad * 2,
      height: subject.height + pad * 2,
      numChannels: 3);
  canvas.toUint8List().fillRange(0, canvas.width * canvas.height * 3, 255);
  _blendOnto(canvas, subject, pad, pad);
  return canvas;
}

/// Product: on a white-to-light-grey backdrop with a contact shadow. The
/// canvas follows the product's shape (between 3:4 and 4:3, long side
/// [_canvas]) and the product fills it edge to edge bar a slim margin, so a
/// tall bottle or a wide box isn't lost in white space.
img.Image _productCanvas(img.Image subject) {
  final bw = subject.width, bh = subject.height;
  final aspect = (bw / bh).clamp(0.75, 4 / 3);
  final cw = aspect >= 1 ? _canvas : (_canvas * aspect).round();
  final ch = aspect >= 1 ? (_canvas / aspect).round() : _canvas;
  const side = 0.04, top = 0.035, bottom = 0.06;
  final availW = cw * (1 - 2 * side), availH = ch * (1 - top - bottom);
  final scale = math.min(availW / bw, availH / bh);
  final pw = math.max(1, (bw * scale).round());
  final ph = math.max(1, (bh * scale).round());
  final product = _resizeTo(subject, pw, ph, 0.45);

  final dx = ((cw - pw) / 2).round();
  final dy = (ch * top + (availH - ph) / 2).round();
  final floorY = dy + ph;

  final canvas = img.Image(width: cw, height: ch, numChannels: 3);
  final out = canvas.toUint8List();
  final cx = cw / 2;
  final rx = pw * 0.50;
  final ry = math.max(10.0, pw * 0.065);
  const shadow = (r: 38, g: 48, b: 54);
  final sx0 = math.max(0, (cx - rx).floor()), sx1 = math.min(cw, (cx + rx).ceil());
  for (var y = 0; y < ch; y++) {
    final t = _smoothstep(0.35, 1.0, y / ch);
    final bgR = 255 - 18 * t, bgG = 255 - 14 * t, bgB = 255 - 12 * t;
    final rowStart = y * cw * 3;
    final r8 = bgR.round(), g8 = bgG.round(), b8 = bgB.round();
    for (var i = rowStart; i < rowStart + cw * 3; i += 3) {
      out[i] = r8;
      out[i + 1] = g8;
      out[i + 2] = b8;
    }
    final ey = (y - floorY) / ry;
    if (ey.abs() >= 1) continue;
    for (var x = sx0; x < sx1; x++) {
      final ex = (x - cx) / rx;
      final d2 = ex * ex + ey * ey;
      if (d2 >= 1) continue;
      final a = 0.38 * math.pow(1 - math.sqrt(d2), 1.6);
      final i = rowStart + x * 3;
      out[i] = (bgR * (1 - a) + shadow.r * a).round();
      out[i + 1] = (bgG * (1 - a) + shadow.g * a).round();
      out[i + 2] = (bgB * (1 - a) + shadow.b * a).round();
    }
  }
  _blendOnto(canvas, product, dx, dy);
  return canvas;
}

/// Light unsharp mask on RGB (alpha untouched, so cut-out edges don't ring):
/// out = px + amount × (px − mean of its 4 neighbours).
img.Image _sharpen(img.Image im, double amount) {
  final w = im.width, h = im.height;
  if (w < 3 || h < 3 || im.format != img.Format.uint8 || im.hasPalette) {
    return im;
  }
  final nc = im.numChannels;
  if (nc < 3) return im;
  final dst = im.toUint8List(); // live view of the pixel buffer
  final src = Uint8List.fromList(dst);
  final row = w * nc;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * row + x * nc;
      if (nc == 4 && src[i + 3] == 0) continue;
      for (var c = 0; c < 3; c++) {
        final v = src[i + c];
        final avg = (src[i + c - nc] +
                src[i + c + nc] +
                src[i + c - row] +
                src[i + c + row]) /
            4;
        final o = (v + amount * (v - avg)).round();
        dst[i + c] = o < 0 ? 0 : (o > 255 ? 255 : o);
      }
    }
  }
  return im;
}

double _bilinear(Float32List m, int w, int h, double x, double y) {
  x = x.clamp(0, w - 1).toDouble();
  y = y.clamp(0, h - 1).toDouble();
  final x0 = x.floor(), y0 = y.floor();
  final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
  final fx = x - x0, fy = y - y0;
  final top = m[y0 * w + x0] * (1 - fx) + m[y0 * w + x1] * fx;
  final bot = m[y1 * w + x0] * (1 - fx) + m[y1 * w + x1] * fx;
  return top * (1 - fy) + bot * fy;
}

double _smoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}
