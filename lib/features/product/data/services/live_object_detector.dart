import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation, rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'studio_image_service.dart';

/// One analysed camera frame.
class LiveDetection {
  /// The product's tight bounding box, normalised to 0..1 in the upright
  /// (as-displayed) frame, or null when no product is in view.
  final Rect? box;

  /// The product's segmentation mask (alpha 0..255, row-major
  /// [maskW]×[maskH], upright frame), so the UI can highlight exactly the
  /// pixels the model thinks are the product.
  final Uint8List? mask;
  final int maskW, maskH;

  /// A hand (skin reaching in from outside the product) overlaps it. The
  /// box already excludes the hand; this lets the UI warn the agent, since
  /// whatever the fingers cover will be missing from the studio photo.
  final bool hand;

  const LiveDetection(this.box,
      {this.mask, this.maskW = 0, this.maskH = 0, this.hand = false});
  static const none = LiveDetection(null);
}

/// Finds the product in the live camera feed with the same TensorFlow Lite
/// models the studio photo uses, fully on-device:
///  * U²-Netp segments the salient object (the pack, bottle, label…);
///  * MediaPipe selfie-multiclass finds the hand holding it, which is cut
///    out, so the box hugs the product alone, not product + hand.
/// The box is the bounding box of that segmentation, so it fits the
/// product's real outline instead of a generic detector's loose box.
///
/// All work (frame conversion, both inferences, mask clean-up) runs in one
/// long-lived background isolate; the UI thread only hands over the frame.
/// At most one frame is in flight, and the pace adapts to the phone's speed.
class LiveObjectDetector {
  bool _busy = false;
  bool _closed = false;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  Future<_Worker?>? _worker;

  /// Lower bound between analysed frames; grows with measured latency.
  static const _minInterval = Duration(milliseconds: 150);

  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Returns null when the frame was skipped (busy/throttled/unsupported),
  /// otherwise a [LiveDetection] (whose box may be null: nothing found).
  Future<LiveDetection?> process(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) async {
    if (_busy || _closed || DateTime.now().isBefore(_next)) return null;
    final rotation = _rotation(camera, deviceOrientation);
    if (rotation == null || image.planes.length != 1) return null;
    final nv21 = image.format.group == ImageFormatGroup.nv21;
    final bgra = image.format.group == ImageFormatGroup.bgra8888;
    if (!nv21 && !bgra) return null;

    _busy = true;
    final started = DateTime.now();
    try {
      final worker = await (_worker ??= _Worker.start());
      if (worker == null || worker.dead) {
        // Failed to start or crashed: try a fresh one in a few seconds
        // instead of silently never detecting again.
        _worker = null;
        _next = DateTime.now().add(const Duration(seconds: 3));
        return null;
      }
      if (_closed) return null;
      final plane = image.planes.first;
      final result = await worker.analyse([
        TransferableTypedData.fromList([plane.bytes]),
        image.width,
        image.height,
        plane.bytesPerRow,
        rotation,
        nv21,
        camera.lensDirection == CameraLensDirection.front,
      ]);
      if (_closed) return null;
      // Analyse at most every 1.5× the last latency, so the preview and the
      // camera keep their share of the CPU on a slow phone.
      final took = DateTime.now().difference(started);
      final wait = took * 1.5 > _minInterval ? took * 1.5 : _minInterval;
      _next = DateTime.now().add(wait);
      return result;
    } catch (e) {
      debugPrint('[LiveObjectDetector] $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  /// Spawns the worker and loads the models while the camera starts, so
  /// the first frame is analysed straight away.
  void warmUp() {
    if (!_closed) _worker ??= _Worker.start();
  }

  Future<void> close() async {
    _closed = true;
    final w = _worker;
    _worker = null;
    (await w)?.close();
  }

  /// Clockwise degrees that turn the camera frame upright.
  int? _rotation(CameraDescription camera, DeviceOrientation deviceOrientation) {
    final sensor = camera.sensorOrientation;
    if (Platform.isIOS) return 0; // iOS streams frames already upright
    final comp = _orientations[deviceOrientation];
    if (comp == null) return null;
    return camera.lensDirection == CameraLensDirection.front
        ? (sensor + comp) % 360
        : (sensor - comp + 360) % 360;
  }
}

/// Background isolate holding both interpreters.
class _Worker {
  final Isolate _isolate;
  final ReceivePort _inbox;
  late final SendPort _port;
  var _id = 0;
  final _pending = <int, Completer<LiveDetection?>>{};
  bool dead = false;

  _Worker._(this._isolate, this._inbox);

  static Future<_Worker?> start() async {
    if (!StudioImageService.isSupported) return null;
    Future<Uint8List?> load(String asset) async {
      try {
        final d = await rootBundle.load(asset);
        return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      } catch (e) {
        debugPrint('[LiveObjectDetector] model missing: $asset ($e)');
        return null;
      }
    }

    final objectModel = await load(StudioImageService.objectModelAsset);
    if (objectModel == null) return null;
    final skinModel = await load(StudioImageService.handModelAsset);

    try {
      final inbox = ReceivePort();
      final isolate = await Isolate.spawn(
          _workerMain, [inbox.sendPort, objectModel, skinModel],
          debugName: 'live-product-detector',
          onError: inbox.sendPort,
          onExit: inbox.sendPort);
      final worker = _Worker._(isolate, inbox);
      final ready = Completer<SendPort?>();
      inbox.listen((msg) {
        if (msg is SendPort) {
          if (!ready.isCompleted) ready.complete(msg);
        } else if (msg is List && msg.isNotEmpty && msg[0] is int) {
          worker._pending.remove(msg[0] as int)?.complete(_decode(msg));
        } else {
          // onExit (null) or onError ([error, stack]): the worker is gone,
          // e.g. a model failed to load. Never leave callers waiting.
          debugPrint('[LiveObjectDetector] worker stopped: $msg');
          worker._fail();
          if (!ready.isCompleted) ready.complete(null);
        }
      });
      final port = await ready.future
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (port == null) {
        worker._fail();
        return null;
      }
      worker._port = port;
      return worker;
    } catch (e) {
      debugPrint('[LiveObjectDetector] worker failed to start: $e');
      return null;
    }
  }

  void _fail() {
    if (dead) return;
    dead = true;
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
    _inbox.close();
    _isolate.kill();
  }

  Future<LiveDetection?> analyse(List<Object> frame) {
    if (dead) return Future.value(null);
    final id = _id++;
    final c = Completer<LiveDetection?>();
    _pending[id] = c;
    _port.send([id, ...frame]);
    return c.future;
  }

  void close() {
    if (dead) return;
    dead = true;
    _port.send('close');
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
    _inbox.close();
    // Let it close its interpreters, then make sure it's gone.
    Timer(const Duration(seconds: 2), _isolate.kill);
  }

  /// [id] → failed; [id, null] → nothing found; else the box and mask.
  static LiveDetection? _decode(List msg) {
    if (msg.length < 2) return null;
    if (msg[1] == null) return LiveDetection.none;
    return LiveDetection(
      Rect.fromLTRB(msg[1] as double, msg[2] as double, msg[3] as double,
          msg[4] as double),
      mask: (msg[5] as TransferableTypedData).materialize().asUint8List(),
      maskW: msg[6] as int,
      maskH: msg[7] as int,
      hand: msg.length > 8 && msg[8] == true,
    );
  }
}

void _workerMain(List<Object?> args) {
  final reply = args[0] as SendPort;
  // Two threads: leave the rest for the camera pipeline and the UI.
  final object = Interpreter.fromBuffer(args[1] as Uint8List,
      options: InterpreterOptions()..threads = 2);
  Interpreter? skin;
  if (args[2] case final Uint8List bytes) {
    try {
      skin = Interpreter.fromBuffer(bytes,
          options: InterpreterOptions()..threads = 2);
    } catch (_) {} // hand removal is an extra
  }
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg == 'close') {
      object.close();
      skin?.close();
      inbox.close();
      return;
    }
    final m = msg as List;
    final id = m[0] as int;
    try {
      final frame = LiveFrame(
        (m[1] as TransferableTypedData).materialize().asUint8List(),
        m[2] as int,
        m[3] as int,
        m[4] as int,
        m[5] as int,
        nv21: m[6] as bool,
        mirror: m[7] as bool,
      );
      final d = _analyse(frame, object, skin);
      if (d == null) {
        reply.send([id, null]);
      } else {
        final b = d.box!;
        reply.send([
          id,
          b.left,
          b.top,
          b.right,
          b.bottom,
          TransferableTypedData.fromList([d.mask!]),
          d.maskW,
          d.maskH,
          d.hand,
        ]);
      }
    } catch (e) {
      debugPrint('[LiveObjectDetector] worker: $e');
      reply.send([id]);
    }
  });
}

LiveDetection? _analyse(LiveFrame f, Interpreter object, Interpreter? skin) {
  // U²-Netp: S×S RGB scaled by the frame max, ImageNet mean/std.
  final inShape = object.getInputTensor(0).shape;
  final nchw = inShape.length == 4 && inShape[1] == 3;
  final s = nchw ? inShape[2] : inShape[1];
  final rgb = f.sample(s, s);
  var maxV = 1;
  for (final v in rgb) {
    if (v > maxV) maxV = v;
  }
  const mean = [0.485, 0.456, 0.406];
  const std = [0.229, 0.224, 0.225];
  final x = Float32List(3 * s * s);
  final plane = s * s;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      final v = (rgb[i * 3 + c] / maxV - mean[c]) / std[c];
      x[nchw ? c * plane + i : i * 3 + c] = v;
    }
  }
  object.runInference([x.buffer.asUint8List()]);
  final sal = _floats(object.getOutputTensor(0).data);
  if (sal.length < plane) return null;

  SegMask? hands;
  if (skin != null) {
    final shape = skin.getInputTensor(0).shape;
    final sh = shape[1], sw = shape[2];
    final px = f.sample(sw, sh);
    final input = Float32List(sw * sh * 3);
    for (var i = 0; i < input.length; i++) {
      input[i] = px[i] / 255.0;
    }
    skin.runInference([input.buffer.asUint8List()]);
    final out = _floats(skin.getOutputTensor(0).data);
    if (out.length >= sw * sh * 6) {
      final sk = Float32List(sw * sh);
      for (var i = 0; i < sw * sh; i++) {
        final o = i * 6;
        var mx = out[o];
        for (var c = 1; c < 6; c++) {
          mx = math.max(mx, out[o + c]);
        }
        var sum = 0.0;
        for (var c = 0; c < 6; c++) {
          sum += math.exp(out[o + c] - mx);
        }
        sk[i] = (math.exp(out[o + 2] - mx) + math.exp(out[o + 3] - mx)) / sum;
      }
      hands = (mask: sk, w: sw, h: sh);
    }
  }
  return detectionFromSaliency(sal, s, s, skin: hands);
}

/// Turns the model outputs into the product's box and mask, or null when
/// nothing product-like is in view. Pure Dart, so it's unit-testable.
@visibleForTesting
LiveDetection? detectionFromSaliency(Float32List saliency, int w, int h,
    {SegMask? skin}) {
  // Raw U²-Netp output is a sigmoid: a real object scores well above 0.5
  // over a decent area. An empty table or wall doesn't.
  var strong = 0;
  for (var i = 0; i < w * h; i++) {
    if (saliency[i] > 0.5) strong++;
  }
  if (strong < w * h * 0.01) return null;

  // Half resolution is plenty for a box and keeps clean-up fast.
  final mw = w ~/ 2, mh = h ~/ 2;
  final half = Float32List(mw * mh);
  for (var y = 0; y < mh; y++) {
    for (var x = 0; x < mw; x++) {
      final i = 2 * y * w + 2 * x;
      half[y * mw + x] =
          (saliency[i] + saliency[i + 1] + saliency[i + w] + saliency[i + w + 1]) /
              4;
    }
  }
  final obj = (mask: half, w: mw, h: mh);
  final hands = skin == null ? null : filterSkinToHands(skin, obj);
  final refined = refineObjectMask(half, mw, mh,
      skin: hands, skinW: skin?.w ?? 0, skinH: skin?.h ?? 0);

  var x0 = mw, y0 = mh, x1 = -1, y1 = -1;
  final alpha = Uint8List(mw * mh);
  for (var y = 0; y < mh; y++) {
    for (var x = 0; x < mw; x++) {
      final v = refined[y * mw + x];
      alpha[y * mw + x] = (v.clamp(0.0, 1.0) * 255).round();
      if (v < 0.5) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) return null;
  final box = Rect.fromLTRB(x0 / mw, y0 / mh, (x1 + 1) / mw, (y1 + 1) / mh);
  if (box.width * box.height < 0.01) return null;
  // Same rule as the studio photo: only skin reaching in from outside the
  // product counts (pink/orange print isn't a hand).
  final hand = hands != null &&
      handOverlapsObject(obj, (mask: hands, w: skin!.w, h: skin.h));
  return LiveDetection(box, mask: alpha, maskW: mw, maskH: mh, hand: hand);
}

/// A camera frame, sampled as if it were upright.
@visibleForTesting
class LiveFrame {
  final Uint8List bytes;
  final int width, height, bytesPerRow;

  /// Clockwise degrees (0/90/180/270) that turn the frame upright.
  final int rotation;
  final bool nv21, mirror;

  LiveFrame(this.bytes, this.width, this.height, this.bytesPerRow,
      this.rotation,
      {required this.nv21, this.mirror = false});

  /// Nearest-neighbour RGB (interleaved, 0..255) of the upright frame at
  /// [ow]×[oh].
  Uint8List sample(int ow, int oh) {
    final out = Uint8List(ow * oh * 3);
    final uvStart = bytesPerRow * height;
    for (var oy = 0; oy < oh; oy++) {
      final v = (oy + 0.5) / oh;
      for (var ox = 0; ox < ow; ox++) {
        var u = (ox + 0.5) / ow;
        if (mirror) u = 1 - u;
        final double sxn, syn;
        switch (rotation) {
          case 90:
            sxn = v;
            syn = 1 - u;
          case 180:
            sxn = 1 - u;
            syn = 1 - v;
          case 270:
            sxn = 1 - v;
            syn = u;
          default:
            sxn = u;
            syn = v;
        }
        final sx = math.min(width - 1, (sxn * width).floor());
        final sy = math.min(height - 1, (syn * height).floor());
        final o = (oy * ow + ox) * 3;
        if (nv21) {
          final yv = bytes[sy * bytesPerRow + sx];
          final uv = uvStart + (sy >> 1) * bytesPerRow + (sx & ~1);
          final vv = bytes[uv] - 128, uu = bytes[uv + 1] - 128;
          out[o] = _clamp8(yv + 1.402 * vv);
          out[o + 1] = _clamp8(yv - 0.344 * uu - 0.714 * vv);
          out[o + 2] = _clamp8(yv + 1.772 * uu);
        } else {
          final i = sy * bytesPerRow + sx * 4; // BGRA
          out[o] = bytes[i + 2];
          out[o + 1] = bytes[i + 1];
          out[o + 2] = bytes[i];
        }
      }
    }
    return out;
  }
}

int _clamp8(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

Float32List _floats(Uint8List bytes) =>
    Uint8List.fromList(bytes).buffer.asFloat32List();
