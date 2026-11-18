import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zytama_data/core/constants/app_colors.dart';

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _hasScanned = false;
  bool _isVerifying = false;
  bool? _permissionGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  Future<void> _initCamera() async {
    // Give a camera the previous screen just released a moment to close.
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (status.isGranted) {
      _controller = MobileScannerController();
      setState(() => _permissionGranted = true);
    } else {
      setState(() => _permissionGranted = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controller?.stop();
    } else if (state == AppLifecycleState.resumed) {
      _controller?.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ── Camera-busy recovery ──
  static const _maxRetries = 4;
  int _retries = 0;
  Timer? _retryTimer;

  void _scheduleRetry() {
    if (_retries >= _maxRetries || (_retryTimer?.isActive ?? false)) return;
    _retries++;
    _retryTimer = Timer(Duration(milliseconds: 700 * _retries), () {
      if (mounted) _restartScanner();
    });
  }

  /// Full reset: after a failed start the plugin's native side can still
  /// think it's running (every later start() then fails with "Called start()
  /// while already started"), and the Dart controller won't stop it because
  /// it believes it never started. So stop natively, then use a brand-new
  /// controller.
  Future<void> _restartScanner() async {
    final old = _controller;
    if (old == null) return;
    setState(() => _controller = null);
    try {
      await old.dispose();
    } catch (_) {}
    try {
      await _scannerChannel.invokeMethod<void>('stop');
    } catch (_) {} // "already stopped" is fine
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => _controller = MobileScannerController());
  }

  static const _scannerChannel =
      MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_hasScanned) return;
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || value.isEmpty) return;
    _hasScanned = true;
    setState(() => _isVerifying = true);
    await Future.delayed(const Duration(milliseconds: 400));
    // Stop and dispose the scanner before popping so the camera hardware
    // is released before the next screen tries to use it.
    await _controller?.stop();
    _controller?.dispose();
    _controller = null;
    await Future.delayed(const Duration(milliseconds: 200));
    if (mounted) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        title: const Text('Scan Barcode'),
        actions: [
          if (_permissionGranted == true) ...[
            IconButton(
              tooltip: 'Toggle flash',
              icon: const Icon(Icons.flash_on_rounded),
              onPressed: () => _controller?.toggleTorch(),
            ),
            IconButton(
              tooltip: 'Flip camera',
              icon: const Icon(Icons.flip_camera_ios_rounded),
              onPressed: () => _controller?.switchCamera(),
            ),
          ],
        ],
      ),
      body: _permissionGranted == null ||
              (_permissionGranted == true && _controller == null)
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _permissionGranted == false
              ? _PermissionDeniedView(onRetry: _initCamera)
              : Stack(

        children: [
          MobileScanner(
            key: ObjectKey(_controller),
            controller: _controller!,
            onDetect: _onDetect,
            errorBuilder: (context, error, _) {
              // Camera can still be busy for a moment after the photo
              // screen; retry quietly a few times before showing an error.
              _scheduleRetry();
              return _ScannerErrorView(
                retrying: _retries < _maxRetries,
                message: error.errorDetails?.message ??
                    error.errorCode.name,
                onRetry: () {
                  _retries = 0;
                  _restartScanner();
                },
              );
            },
          ),

          // Scan frame
          Center(
            child: Builder(builder: (context) {
              final scanSize = (MediaQuery.sizeOf(context).width * 0.65)
                  .clamp(200.0, 300.0);
              return Container(
              width: scanSize,
              height: scanSize,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.secondary, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Stack(
                children: [
                  for (final alignment in [
                    Alignment.topLeft,
                    Alignment.topRight,
                    Alignment.bottomLeft,
                    Alignment.bottomRight,
                  ])
                    Align(
                      alignment: alignment,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: AppColors.secondary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                ],
              ),
            );
            }),
          ),

          // Instruction text
          Positioned(
            bottom: 48,
            left: 0,
            right: 0,
            child: Column(
              children: [
                const Icon(Icons.qr_code_scanner,
                    color: Colors.white54, size: 28),
                const SizedBox(height: 8),
                Text(
                  'Align the barcode within the frame',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8), fontSize: 15),
                ),
              ],
            ),
          ),

          // Verifying overlay — shown after barcode is detected
          if (_isVerifying)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 36, vertical: 28),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppColors.secondary.withValues(alpha: 0.4)),
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        color: AppColors.secondary,
                        strokeWidth: 3,
                      ),
                      SizedBox(height: 20),
                      Text(
                        'Checking product…',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Please wait',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScannerErrorView extends StatelessWidget {
  final bool retrying;
  final String message;
  final VoidCallback onRetry;
  const _ScannerErrorView({
    required this.retrying,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (retrying) ...[
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 16),
                const Text('Starting camera…',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
              ] else ...[
                const Icon(Icons.no_photography_outlined,
                    color: Colors.white70, size: 48),
                const SizedBox(height: 12),
                const Text("Couldn't open the camera",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(message,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  final VoidCallback onRetry;
  const _PermissionDeniedView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 64),
            const SizedBox(height: 20),
            const Text(
              'Camera permission required',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Please allow camera access to scan barcodes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: () async {
                await openAppSettings();
                onRetry();
              },
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open Settings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.secondary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
