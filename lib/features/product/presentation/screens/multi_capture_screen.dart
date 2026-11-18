import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:zytama_data/core/constants/app_colors.dart';
import '../../../../core/di/injection_container.dart';
import '../../data/services/live_object_detector.dart';
import '../../data/services/product_ocr_service.dart';
import '../../data/services/studio_image_service.dart';
import '../widgets/ai_box_painter.dart';

class _StepConfig {
  final String label;
  final String instruction;
  final IconData icon;
  final Color color;
  const _StepConfig({
    required this.label,
    required this.instruction,
    required this.icon,
    required this.color,
  });
}

class _SideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _SideButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = Colors.white.withValues(alpha: enabled ? 1 : 0.3);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: enabled ? 0.15 : 0.05),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class MultiCaptureScreen extends StatefulWidget {
  final String barcode;
  const MultiCaptureScreen({super.key, required this.barcode});

  @override
  State<MultiCaptureScreen> createState() => _MultiCaptureScreenState();
}

class _MultiCaptureScreenState extends State<MultiCaptureScreen>
    with WidgetsBindingObserver {
  static const _steps = [
    _StepConfig(
      label: 'Product Photo',
      instruction: 'Front of the product,\non a plain surface',
      icon: Icons.inventory_2_rounded,
      color: Color(0xff0A6475),
    ),
    _StepConfig(
      label: 'Ingredients Photo',
      instruction: 'Photograph the\ningredients label',
      icon: Icons.list_alt_rounded,
      color: Color(0xff7B2FBE),
    ),
    _StepConfig(
      label: 'Nutrition Photo',
      instruction: 'Photograph the\nnutrition facts label',
      icon: Icons.restaurant_menu_rounded,
      color: Color(0xffE07B29),
    ),
  ];

  CameraController? _ctrl;
  int _step = 0;
  final List<File?> _captured = List.filled(3, null);
  bool _taking = false;
  bool _flash = false;
  Timer? _sheetTimer;
  bool _sheetOpen = false;
  CameraDescription? _rearCamera;
  bool _pickerActive = false;

  /// Step was captured or skipped. Drives where [_advance] goes next, so a
  /// front-photo retake returns to the first unfinished step, not step 2.
  final List<bool> _handled = List.filled(3, false);

  // Studio version of each photo, started right after it's taken so it runs
  // while the agent shoots the next one. The thumbnail shows the latest.
  final List<StudioResult?> _studio = List.filled(3, null);
  final List<bool> _studioBusy = List.filled(3, false);
  final List<int> _studioRun = List.filled(3, 0);

  /// Retakes asked for per step. A blurry photo or a hand must be retaken;
  /// only after [_retakesBeforeOverride] tries can the agent use it anyway
  /// (some packs are genuinely hard, and they must never be stuck).
  final List<int> _retakes = List.filled(3, 0);
  static const _retakesBeforeOverride = 2;
  int? _thumbStep;

  /// Step whose studio image is being made right now. The agent stays on
  /// that step (shutter disabled, overlay shown) until it's ready.
  int? _processingStep;
  File? _processingPhoto;
  bool get _processing => _processingStep != null;
  bool get _busy => _taking || _processing;

  // ── Live product framing (TFLite segmentation on the preview) ──
  final _detector = LiveObjectDetector();

  /// Smoothed box of the product, normalised to the upright preview.
  Rect? _liveBox;

  int _missCount = 0;
  int _stableCount = 0;

  /// A hand is on the product in the live view (debounced over frames so
  /// the warning doesn't flicker).
  bool _handLive = false;
  int _handFrames = 0;

  /// Where focus/exposure was last locked (normalised), to avoid re-locking
  /// on every frame while the product sits still.
  Offset? _focusedOn;

  /// Tap-to-focus ring (screen position), shown briefly.
  Offset? _tapRing;
  Timer? _tapRingTimer;

  bool get _steady => _liveBox != null && _stableCount >= 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Both AI workers (live framing + studio photo) start in the background
    // while the camera opens: models are loaded before they're needed.
    _detector.warmUp();
    sl<StudioImageService>().warmUp();
    _initCamera();
  }

  Future<void> _initCamera() async {
    // Brief delay to let the previous scanner fully release the camera hardware
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final cameras = await availableCameras();
    if (cameras.isEmpty || !mounted) return;
    _rearCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    await _startController();
    if (mounted && _ctrl?.value.isInitialized == true) {
      _showStepSheet();
    }
  }

  Future<void> _startController() async {
    if (_rearCamera == null || !mounted) return;
    // Max resolution: label small print needs the pixels (the old `high`
    // preset was 720p, under 1 MP). The frame format is what ML Kit needs
    // for live detection: NV21 on Android, BGRA8888 on iOS.
    _ctrl = CameraController(
      _rearCamera!,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    try {
      await _ctrl!.initialize();
    } catch (_) {
      // Camera init can fail if hardware is still releasing; retry once
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      try {
        await _ctrl!.initialize();
      } catch (_) {}
    }
    final ctrl = _ctrl;
    if (ctrl != null && ctrl.value.isInitialized) {
      // Continuous autofocus/exposure until a product is found and locked.
      try {
        await ctrl.setFocusMode(FocusMode.auto);
        await ctrl.setExposureMode(ExposureMode.auto);
      } catch (_) {} // not every device supports both
      _startDetection();
    }
    if (mounted) setState(() {});
  }

  /// Live detection grabs ONE frame, stops the stream, analyses it, then
  /// asks for the next one a moment later. With the camera at max resolution
  /// a continuous stream would copy huge frames into Dart ~30×/s, starving
  /// the preview, the capture and the studio pipeline (black screen).
  void _startDetection() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || !mounted || _busy) {
      return;
    }
    if (_closing || ctrl.value.isStreamingImages) return;
    _frameTaken = false;
    // Tracked so closing can wait for it: a start still in flight when the
    // controller is disposed re-binds the camera natively and keeps it open
    // after this screen is gone (the barcode scanner then can't open it).
    _streamOp = ctrl.startImageStream(_onFrame).catchError((Object e) {
      debugPrint('[MultiCapture] live detection unavailable: $e');
    });
  }

  bool _frameTaken = false;
  Timer? _pulseTimer;
  Future<void>? _streamOp;

  /// Set once the screen starts handing the camera back; nothing may restart
  /// the stream after that.
  bool _closing = false;

  /// Stops detection, waits for any pending stream call, then disposes the
  /// controller, so the camera is fully free for the next screen.
  Future<void> _releaseCamera() async {
    _closing = true;
    _pulseTimer?.cancel();
    try {
      await _streamOp;
    } catch (_) {}
    await _pauseDetection();
    final ctrl = _ctrl;
    _ctrl = null;
    if (mounted) setState(() {});
    try {
      await ctrl?.dispose();
    } catch (_) {}
    // Let the camera hardware fully release before the next screen opens it.
    await Future.delayed(const Duration(milliseconds: 300));
  }

  void _onFrame(CameraImage image) {
    final ctrl = _ctrl;
    if (ctrl == null || _frameTaken) return;
    _frameTaken = true;
    _pauseDetection();
    if (_busy || !mounted) return;
    _detector
        .process(image, ctrl.description, ctrl.value.deviceOrientation)
        .then((d) {
      _onDetection(d);
      _pulseTimer?.cancel();
      if (_closing || !mounted) return;
      _pulseTimer =
          Timer(const Duration(milliseconds: 220), _startDetection);
    });
  }

  void _onDetection(LiveDetection? d) {
    if (d == null || !mounted || _busy) return; // frame skipped
    final box = d.box;
    if (box == null) {
      // Ride out a couple of missed frames so the outline doesn't flicker.
      if (++_missCount >= 3 && _liveBox != null) {
        setState(() {
          _liveBox = null;
          _stableCount = 0;
          _focusedOn = null;
          _handLive = false;
          _handFrames = 0;
        });
      }
      return;
    }
    _missCount = 0;
    // Warn after 2 frames with a hand; clear after 2 frames without.
    if (d.hand) {
      _handFrames = math.max(1, _handFrames + 1);
    } else {
      _handFrames = math.min(-1, _handFrames - 1);
    }
    final handLive = _handFrames >= 2 || (_handLive && _handFrames > -2);
    if (handLive && !_handLive) HapticFeedback.mediumImpact();
    final prev = _liveBox;
    final next = prev == null ? box : Rect.lerp(prev, box, 0.5)!;
    final moved = prev == null
        ? 1.0
        : (next.center - prev.center).distance +
            (next.width - prev.width).abs() +
            (next.height - prev.height).abs();
    setState(() {
      _liveBox = next;
      _stableCount = moved < 0.03 ? _stableCount + 1 : 0;
      _handLive = handLive;
    });
    // Product held still: lock focus + exposure on it (once per position).
    if (_steady &&
        (_focusedOn == null ||
            (_focusedOn! - next.center).distance > 0.08)) {
      _focusOn(next.center);
    }
  }

  Future<void> _focusOn(Offset normalised) async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    _focusedOn = normalised;
    try {
      await ctrl.setFocusPoint(normalised);
      await ctrl.setExposurePoint(normalised);
    } catch (_) {} // fixed-focus / unsupported devices
  }

  /// Agent taps the preview: focus there and show a ring.
  void _onTapFocus(Offset normalised, Offset screen) {
    _focusOn(normalised);
    _tapRingTimer?.cancel();
    setState(() => _tapRing = screen);
    _tapRingTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _tapRing = null);
    });
  }

  void _resetDetection() {
    _liveBox = null;
    _handLive = false;
    _handFrames = 0;
    _missCount = 0;
    _stableCount = 0;
    _focusedOn = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system gallery picker briefly backgrounds the app too; don't tear
    // the camera down for that transient, intentional pause.
    if (_pickerActive) return;
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pulseTimer?.cancel();
      _ctrl = null;
      if (mounted) setState(() {});
      // Wait for a pending stream start first, or it re-binds the camera.
      final pending = _streamOp ?? Future<void>.value();
      pending.catchError((_) {}).whenComplete(() async {
        try {
          if (ctrl.value.isStreamingImages) await ctrl.stopImageStream();
        } catch (_) {}
        await ctrl.dispose();
      });
    } else if (state == AppLifecycleState.resumed) {
      _startController();
    }
  }

  void _showStepSheet() {
    if (!mounted || _sheetOpen) return;
    _sheetOpen = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => _StepGuideSheet(
        step: _steps[_step],
        stepNumber: _step + 1,
        totalSteps: _steps.length,
        barcode: _step == 0 ? widget.barcode : null,
      ),
    ).then((_) {
      _sheetOpen = false;
      _sheetTimer?.cancel();
    });

    _sheetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _sheetOpen) Navigator.of(context).pop();
    });
  }

  Future<void> _disposeAndPop() async {
    if (!mounted || _closing) return;
    _sheetTimer?.cancel();
    await _releaseCamera();
    if (mounted) Navigator.of(context).pop(null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sheetTimer?.cancel();
    _tapRingTimer?.cancel();
    _pulseTimer?.cancel();
    _ctrl?.dispose(); // also stops the image stream
    _detector.close();
    super.dispose();
  }

  Future<void> _capture() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _busy) return;
    setState(() => _taking = true);
    // No frame analysis during the shot: the capture gets the full sensor.
    _pulseTimer?.cancel();
    await _pauseDetection();
    if (!mounted) return;

    // Sharpness first: if the product is in view but focus wasn't locked on
    // it yet, focus there and give the lens a moment to settle.
    final box = _liveBox;
    if (box != null && !_steady) {
      await _focusOn(box.center);
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
    }

    setState(() => _flash = true);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _flash = false);
    });

    XFile xFile;
    try {
      xFile = await ctrl.takePicture();
    } catch (e) {
      debugPrint('[MultiCapture] takePicture failed: $e');
      if (!mounted) return;
      setState(() => _taking = false);
      _startDetection();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't take the photo. Try again.")),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _taking = false);
    await _accept(File(xFile.path));
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    _pickerActive = true;
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 95,
    );
    _pickerActive = false;
    if (!mounted) return;
    // Fall back to re-initializing in case the OS disposed the camera
    // despite the guard above (e.g. a real backgrounding overlapped the pick).
    if (_ctrl == null || !_ctrl!.value.isInitialized) {
      await _startController();
      if (!mounted) return;
    }
    if (x == null) return;
    await _accept(File(x.path));
  }

  /// A photo was taken/picked for the current step: make its studio version
  /// and only move on once it's ready. A blurry photo, a hand on the pack or
  /// a failed cut-out asks for a retake first (the agent may still carry on).
  Future<void> _accept(File photo) async {
    final step = _step;
    _captured[step] = photo;
    final result = await _processAndWait(step, photo);
    if (!mounted || step != _step) return;
    if (result == null ||
        (result.file != null && !result.handDetected && !result.blurry)) {
      await _advance();
      return;
    }
    final retake = await _studioDialog(step);
    if (!mounted || step != _step) return;
    if (retake) {
      _retakes[step]++;
      setState(_resetDetection); // stay on this step; shutter is live again
      _startDetection();
      return;
    }
    await _advance();
  }

  /// Starts OCR (cached for the review screen) and makes the studio image,
  /// returning it once done. Null when studio isn't supported here.
  Future<StudioResult?> _processAndWait(int step, File photo) async {
    sl<ProductOcrService>().readText(photo, asTable: step == 2);
    if (!StudioImageService.isSupported) return null;
    final run = ++_studioRun[step];
    setState(() {
      _studio[step] = null;
      _studioBusy[step] = true;
      _thumbStep = step;
      _processingStep = step;
      _processingPhoto = photo;
      _resetDetection();
    });
    // Free the CPU for the models: live detection pauses meanwhile.
    _pulseTimer?.cancel();
    await _pauseDetection();
    // Never leave the agent stuck behind the overlay: if a slow phone takes
    // too long, move on and let the job finish in the background. It's
    // cached, so the review screen picks it up instead of failing.
    final job = sl<StudioImageService>().create(photo,
        kind: step == 0 ? StudioKind.product : StudioKind.label);
    var timedOut = false;
    final result = await job.timeout(const Duration(seconds: 60),
        onTimeout: () {
      timedOut = true;
      return StudioResult.none;
    });
    if (timedOut) {
      job.then((r) {
        if (!mounted || run != _studioRun[step]) return;
        setState(() {
          _studioBusy[step] = false;
          _studio[step] = r;
        });
      });
      if (mounted) {
        setState(() {
          _processingStep = null;
          _processingPhoto = null;
        });
      }
      return null; // carry on; the thumbnail keeps its spinner meanwhile
    }
    if (!mounted) return result;
    setState(() {
      if (run == _studioRun[step]) {
        _studioBusy[step] = false;
        _studio[step] = result;
      }
      _processingStep = null;
      _processingPhoto = null;
    });
    // Detection restarts only once the caller knows the screen stays open
    // (retake / next step), never right before it closes.
    return result;
  }

  Future<void> _pauseDetection() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (!ctrl.value.isStreamingImages) return;
    try {
      await ctrl.stopImageStream();
    } catch (_) {}
  }

  /// Leaves this step's photo empty (e.g. the product has no nutrition
  /// label) and moves on; the missing image is sent through as-is.
  Future<void> _skip() async {
    if (_busy) return;
    _captured[_step] = null;
    _studioRun[_step]++;
    _studio[_step] = null;
    _studioBusy[_step] = false;
    if (_thumbStep == _step) _thumbStep = null;
    await _advance();
  }

  Future<void> _advance() async {
    _handled[_step] = true;
    final next = _handled.indexOf(false);
    if (next != -1) {
      setState(() {
        _step = next;
        _resetDetection();
      });
      _startDetection();
      _showStepSheet();
      return;
    }
    if (_closing) return;
    await _releaseCamera();
    if (mounted) Navigator.of(context).pop(_captured);
  }

  /// Thumbnail tap: full-size look at an earlier step's studio version, with
  /// a one-tap retake of that photo while the product is still in hand.
  Future<void> _openStudioPreview(int step) async {
    final retake = await _studioDialog(step);
    if (!retake || !mounted) return;
    _retakes[step]++;
    _handled[step] = false;
    setState(() {
      _step = step;
      _resetDetection();
    });
    _showStepSheet();
  }

  /// Shows [step]'s studio result and any problems with it. True = retake.
  Future<bool> _studioDialog(int step) async {
    final r = _studio[step];
    final file = r?.file;
    final hand = r?.handDetected ?? false;
    final blurry = r?.blurry ?? false;
    final name = _steps[step].label.toLowerCase();
    final ok = file != null && !hand && !blurry;
    // Blur and hands aren't acceptable: retake is the only way on, until a
    // couple of tries have failed.
    final canUse = ok || _retakes[step] >= _retakesBeforeOverride;

    Widget warning(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: const Color(0xffB26A00)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(text, style: const TextStyle(fontSize: 13.5))),
            ],
          ),
        );

    final retake = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (blurry)
              warning(
                  Icons.blur_on_rounded,
                  'This photo looks blurry. Hold the phone still until the '
                  'frame turns teal, then retake.'),
            if (hand)
              warning(
                  Icons.back_hand_outlined,
                  'A hand was detected and removed, but anything the '
                  'fingers covered is missing. Retake with the pack '
                  'on a plain surface for the best result.'),
            if (file != null)
              Flexible(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(file, fit: BoxFit.contain),
                ),
              )
            else
              const Text(
                "Couldn't separate it from the background. Retake on a "
                'plain, contrasting surface.',
                style: TextStyle(fontSize: 14),
              ),
          ],
        ),
        actions: ok
            ? [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text('Retake $name'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Looks good'),
                ),
              ]
            : [
                if (canUse)
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Use anyway'),
                  ),
                ElevatedButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  icon: const Icon(Icons.camera_alt_rounded, size: 18),
                  label: Text('Retake $name'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
      ),
    );
    return retake == true;
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _ctrl?.value.isInitialized ?? false;
    final step = _steps[_step];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _disposeAndPop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
        fit: StackFit.expand,
        children: [
          if (initialized)
            _FramedPreview(
              controller: _ctrl!,
              box: _liveBox,
              steady: _steady,
              hand: _handLive,
              hint: _liveBox == null
                  ? 'Point at the ${_step == 0 ? 'product' : 'label'}'
                  : _handLive
                      ? 'Hand detected on the ${_step == 0 ? 'product' : 'label'}'
                          ' · hold it by the edges or set it down'
                  : _steady
                      ? 'Hold still · focused'
                      : '${_step == 0 ? 'Product' : 'Label'} found · hold steady',
              tapRing: _tapRing,
              onTapFocus: _onTapFocus,
            )
          else
            const Center(
                child: CircularProgressIndicator(color: Colors.white)),

          if (_flash) Container(color: Colors.white.withValues(alpha: 0.6)),

          // Top overlay
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: _disposeAndPop,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white, size: 22),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Step ${_step + 1} of ${_steps.length}  •  ${step.label}',
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                step.instruction.replaceAll('\n', ' '),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_steps.length, (i) {
                        final active = i == _step;
                        final done = _captured[i] != null;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: active ? 24 : 8,
                          height: 8,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: done
                                ? Colors.white.withValues(alpha: 0.5)
                                : active
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Barcode chip
          Positioned(
            top: 140,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.20)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.qr_code, size: 14, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(
                      widget.barcode,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_thumbStep case final t?)
            Positioned(
              top: 130,
              right: 16,
              child: _StudioThumb(
                image: _studio[t]?.file,
                busy: _studioBusy[t],
                failed: !_studioBusy[t] && _studio[t]?.file == null,
                hand: _studio[t]?.handDetected ?? false,
                blurry: _studio[t]?.blurry ?? false,
                onTap: _busy || _studioBusy[t] || _step == t
                    ? null
                    : () => _openStudioPreview(t),
              ),
            ),

          // Shutter button
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _SideButton(
                      icon: Icons.photo_library_rounded,
                      label: 'Gallery',
                      onTap: _busy ? null : _pickFromGallery,
                    ),
                    GestureDetector(
                      onTap: _busy ? null : _capture,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: _taking ? 36 : 54,
                            height: _taking ? 36 : 54,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _taking
                                  ? AppColors.primary.withValues(alpha: 0.6)
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    _SideButton(
                      icon: Icons.skip_next_rounded,
                      label: 'Skip',
                      onTap: _busy ? null : _skip,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Studio image in progress: blocks the screen until it's ready.
          if (_processingStep case final p?)
            Positioned.fill(
              child: _ProcessingOverlay(
                photo: _processingPhoto,
                box: _processingPhoto == null
                    ? null
                    : sl<StudioImageService>().boxFor(_processingPhoto!,
                        kind: p == 0 ? StudioKind.product : StudioKind.label),
                label: _steps[p].label,
                color: _steps[p].color,
                isLast: _handled.where((h) => !h).length <= 1,
              ),
            ),
        ],
      ),
      ),
    );
  }
}

// ── "Creating studio image" overlay ──────────────────────────────────────────

class _ProcessingOverlay extends StatelessWidget {
  final File? photo;

  /// AI box of the product in [photo]; arrives while the studio image is
  /// still being made. Same for in-app shots and gallery photos.
  final ValueListenable<StudioBox?>? box;
  final String label;
  final Color color;
  final bool isLast;

  const _ProcessingOverlay({
    required this.photo,
    required this.box,
    required this.label,
    required this.color,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: Container(
        color: Colors.black.withValues(alpha: 0.82),
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ValueListenableBuilder<StudioBox?>(
              valueListenable: box ?? ValueNotifier<StudioBox?>(null),
              builder: (context, found, _) =>
                  _BoxedPhoto(photo: photo, found: found, color: color),
            ),
            const SizedBox(height: 24),
            Text(
              'Creating studio image…',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                color: color,
                backgroundColor: Colors.white12,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Removing background and hands, checking sharpness',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              isLast
                  ? 'Keep the product handy in case a retake is needed.'
                  : 'Next photo opens when this is ready.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// The photo just taken or picked, with the AI's product box drawn on it
/// once found (spinner until then).
class _BoxedPhoto extends StatelessWidget {
  final File? photo;
  final StudioBox? found;
  final Color color;

  const _BoxedPhoto(
      {required this.photo, required this.found, required this.color});

  @override
  Widget build(BuildContext context) {
    final f = found;
    final screen = MediaQuery.sizeOf(context);
    final maxW = math.min(screen.width - 64, 300.0);
    final maxH = math.min(screen.height * 0.42, 360.0);
    // Photo shape once known (from the AI's working copy), square before.
    final aspect = f?.aspect ?? 1.0;
    var w = maxW, h = maxW / aspect;
    if (h > maxH) {
      h = maxH;
      w = maxH * aspect;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: f == null ? 168 : w,
      height: f == null ? 168 : h,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        color: Colors.white10,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photo case final file?)
            Image.file(file,
                fit: f == null ? BoxFit.cover : BoxFit.fill,
                cacheWidth: 600, // preview; don't decode 12 MP
                color: Colors.black.withValues(alpha: f == null ? 0.35 : 0.1),
                colorBlendMode: BlendMode.darken),
          if (f == null) ...[
            Center(
              child: SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(strokeWidth: 4, color: color),
              ),
            ),
            const Center(
              child: Icon(Icons.auto_awesome_rounded,
                  color: Colors.white, size: 26),
            ),
          ] else
            CustomPaint(painter: AiBoxPainter(f.box, aspect: f.aspect)),
        ],
      ),
    );
  }
}

// ── Step Guide Bottom Sheet ────────────────────────────────────────────────────

class _StepGuideSheet extends StatelessWidget {
  final _StepConfig step;
  final int stepNumber;
  final int totalSteps;
  final String? barcode;

  const _StepGuideSheet({
    required this.step,
    required this.stepNumber,
    required this.totalSteps,
    this.barcode,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 360,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipPath(
            clipper: _BottomSheetClipper(),
            child: Container(
              color: Colors.white,
              child: Column(
                children: [
                  const SizedBox(height: 36),

                  // Progress bars
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: List.generate(totalSteps, (i) {
                        final active = i + 1 == stepNumber;
                        final done = i + 1 < stepNumber;
                        return Expanded(
                          child: Container(
                            margin: EdgeInsets.only(
                                right: i < totalSteps - 1 ? 6 : 0),
                            height: 4,
                            decoration: BoxDecoration(
                              color: (active || done)
                                  ? step.color
                                  : Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Icon box
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: step.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(step.icon, size: 34, color: step.color),
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'Step $stepNumber of $totalSteps  •  ${step.label}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: step.color,
                    ),
                  ),

                  const SizedBox(height: 6),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      step.instruction,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: Color(0xff1A1A1A),
                      ),
                    ),
                  ),

                  if (barcode != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.qr_code,
                            size: 13, color: Colors.grey),
                        const SizedBox(width: 5),
                        Text(barcode!,
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Color(0xff1A1A1A))),
                      ]),
                    ),
                  ],

                  const Spacer(),

                  // Dismiss button
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        24, 0, 24, MediaQuery.paddingOf(context).bottom + 16),
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.camera_alt_rounded,
                            color: Colors.white, size: 20),
                        label: const Text(
                          'Open Camera',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xff4CC5B8),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Floating handle pill in the notch
          Positioned(
            top: -10,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 62,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 26,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Custom clipper ─────────────────────────────────────────────────────────────

class _BottomSheetClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    const double radius = 40;
    const double notchWidth = 110;
    const double notchDepth = 22;

    final path = Path();
    path.moveTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);

    final start = size.width / 2 - notchWidth / 2;
    final end = size.width / 2 + notchWidth / 2;

    path.lineTo(start, 0);
    path.cubicTo(start + 10, 0, start + 15, notchDepth, size.width / 2,
        notchDepth);
    path.cubicTo(end - 15, notchDepth, end - 10, 0, end, 0);

    path.lineTo(size.width - radius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, radius);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

// ── Studio cut-out thumbnail ──────────────────────────────────────────────────

class _StudioThumb extends StatelessWidget {
  final File? image;
  final bool busy;
  final bool failed;
  final bool hand;
  final bool blurry;
  final VoidCallback? onTap;

  const _StudioThumb({
    required this.image,
    required this.busy,
    required this.failed,
    required this.hand,
    this.blurry = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (busy) {
      content = const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      );
    } else if (image != null) {
      content = Image.file(image!, fit: BoxFit.cover);
    } else {
      content = const Icon(Icons.hide_image_outlined,
          color: Color(0xffFFB4A8), size: 24);
    }
    final caption = busy
        ? 'Studio…'
        : failed
            ? 'Not clear'
            : hand
                ? 'Hand!'
                : blurry
                    ? 'Blurry'
                    : 'Studio';

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: failed
                    ? const Color(0xffFFB4A8)
                    : hand || blurry
                        ? const Color(0xffF5C27A)
                        : Colors.white.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: content,
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ── Camera preview with live product outline ─────────────────────────────────

/// Fills the screen with the camera preview (cropped, never stretched) and
/// draws the live product outline, a guide frame when nothing is found, and
/// the tap-to-focus ring. Taps report a normalised point for focusing.
class _FramedPreview extends StatelessWidget {
  final CameraController controller;
  final Rect? box;
  final bool steady;

  /// A hand is on the product: frame and hint turn into a warning.
  final bool hand;
  final String hint;
  final Offset? tapRing;
  final void Function(Offset normalised, Offset screen) onTapFocus;

  const _FramedPreview({
    required this.controller,
    required this.box,
    required this.steady,
    required this.hand,
    required this.hint,
    required this.tapRing,
    required this.onTapFocus,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final screen = c.biggest;
      final ps = controller.value.previewSize ?? screen;
      // previewSize is in sensor (landscape) terms; the app is portrait.
      final upright = Size(math.min(ps.width, ps.height),
          math.max(ps.width, ps.height));
      final scale = math.max(
          screen.width / upright.width, screen.height / upright.height);
      final shown = Size(upright.width * scale, upright.height * scale);
      final area = Rect.fromLTWH((screen.width - shown.width) / 2,
          (screen.height - shown.height) / 2, shown.width, shown.height);

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final n = Offset(
            ((d.localPosition.dx - area.left) / area.width).clamp(0.0, 1.0),
            ((d.localPosition.dy - area.top) / area.height).clamp(0.0, 1.0),
          );
          onTapFocus(n, d.localPosition);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: OverflowBox(
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: SizedBox(
                  width: shown.width,
                  height: shown.height,
                  child: CameraPreview(controller),
                ),
              ),
            ),
            CustomPaint(
              painter: _FramePainter(
                area: area,
                box: box,
                steady: steady,
                hand: hand,
                tapRing: tapRing,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 150,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: EdgeInsets.symmetric(
                      horizontal: 14, vertical: hand ? 10 : 7),
                  decoration: BoxDecoration(
                    color: hand
                        ? AppColors.warning.withValues(alpha: 0.92)
                        : steady
                            ? AppColors.primary.withValues(alpha: 0.9)
                            : Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        hand
                            ? Icons.back_hand_outlined
                            : steady
                                ? Icons.center_focus_strong_rounded
                                : Icons.center_focus_weak_rounded,
                        color: Colors.white,
                        size: hand ? 18 : 16,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(hint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: hand ? 13 : 12.5,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _FramePainter extends CustomPainter {
  /// Where the (cropped) preview image sits on screen.
  final Rect area;

  /// Product box from the segmentation model, normalised to the preview.
  final Rect? box;

  final bool steady;

  /// A hand is on the product: the frame turns into a warning.
  final bool hand;
  final Offset? tapRing;

  _FramePainter({
    required this.area,
    required this.box,
    required this.steady,
    required this.hand,
    required this.tapRing,
  });

  /// Theme colours on the camera preview: product found → Tiffany Blue,
  /// held still and focused → the brand Blue Green.
  static const _found = AppColors.accent;
  static const _locked = AppColors.secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final b = box;
    if (b != null) {
      final r = Rect.fromLTRB(
        area.left + b.left * area.width,
        area.top + b.top * area.height,
        area.left + b.right * area.width,
        area.top + b.bottom * area.height,
      ).inflate(3); // hug the product, just clear of its edge
      final color = hand
          ? AppColors.warning
          : steady
              ? _locked
              : _found;

      // Thin outline + bold corner brackets only: nothing is laid over the
      // product, so the preview shows its true colours.
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(14)),
          Paint()
            ..color = color.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      _corners(canvas, r, color, 4, math.min(34, r.shortestSide * 0.22));

      // Centre crosshair: where focus/exposure lock.
      final c = r.center;
      final cross = Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(c - const Offset(10, 0), c + const Offset(10, 0), cross);
      canvas.drawLine(c - const Offset(0, 10), c + const Offset(0, 10), cross);
      canvas.drawCircle(
          c,
          16,
          Paint()
            ..color = color.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
    // Nothing found: no frame is drawn. Every box on screen comes from the
    // model; the hint text tells the agent to point at the product.

    if (tapRing case final t?) {
      canvas.drawCircle(
          t,
          34,
          Paint()
            ..color = AppColors.dashGlow
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  void _corners(Canvas canvas, Rect r, Color color, double width, double len) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx, corner.dy + len * dy)
          ..lineTo(corner.dx, corner.dy)
          ..lineTo(corner.dx + len * dx, corner.dy),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.box != box ||
      old.steady != steady ||
      old.hand != hand ||
      old.tapRing != tapRing ||
      old.area != area;
}
