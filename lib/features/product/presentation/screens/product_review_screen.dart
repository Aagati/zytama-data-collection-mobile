import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/di/injection_container.dart';
import '../../../../core/utils/image_source_sheet.dart';
import '../../domain/usecases/get_categories_usecase.dart';
import '../bloc/product_bloc.dart';

class ProductReviewScreen extends StatefulWidget {
  final String barcode;
  final File? initialProductImage;
  final File? initialIngredientsImage;
  final File? initialNutritionImage;
  final VoidCallback onSuccess;
  final VoidCallback? onOfflineSuccess;

  const ProductReviewScreen({
    super.key,
    required this.barcode,
    required this.initialProductImage,
    required this.initialIngredientsImage,
    required this.initialNutritionImage,
    required this.onSuccess,
    this.onOfflineSuccess,
  });

  @override
  State<ProductReviewScreen> createState() => _ProductReviewScreenState();
}

// Age groups the product may be suitable for, spanning 0 months to 18 years.
const List<String> kAgeGroups = [
  '0-6 months',
  '6-12 months',
  '1-3 years',
  '3-5 years',
  '5-8 years',
  '8-12 years',
];

class _ProductReviewScreenState extends State<ProductReviewScreen> {
  File? _productImage;
  File? _ingredientsImage;
  File? _nutritionImage;
  String? _ageGroup;
  String? _category;
  List<String> _categories = const [];
  bool _loadingCategories = true;
  String? _categoriesError;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _productImage = widget.initialProductImage;
    _ingredientsImage = widget.initialIngredientsImage;
    _nutritionImage = widget.initialNutritionImage;
    _loadCategories();
  }

  /// Pulls the category list from the backend; the repository falls back to
  /// the last cached list when the agent is offline.
  Future<void> _loadCategories() async {
    setState(() {
      _loadingCategories = true;
      _categoriesError = null;
    });
    final result = await sl<GetCategoriesUseCase>()();
    if (!mounted) return;
    result.fold(
      (failure) => setState(() {
        _loadingCategories = false;
        _categoriesError = failure.message;
      }),
      (categories) => setState(() {
        _loadingCategories = false;
        _categories = categories;
        // Drop a stale selection if the list changed underneath it.
        if (_category != null && !categories.contains(_category)) {
          _category = null;
        }
      }),
    );
  }

  Future<void> _replaceImage(int index) async {
    final source =
        await ImageSourceSheet.show(context, title: 'Replace Photo');
    if (source == null || !mounted) return;

    final x = await _picker.pickImage(
      source: source,
      imageQuality: 85,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (x == null || !mounted) return;
    setState(() {
      switch (index) {
        case 0:
          _productImage = File(x.path);
        case 1:
          _ingredientsImage = File(x.path);
        case 2:
          _nutritionImage = File(x.path);
      }
    });
  }

  void _viewImage(File image, String label) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            SizedBox.expand(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6.0,
                child: Image.file(image, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 48, 16, 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.65),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Positioned(
              top: 44,
              right: 12,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.50),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.pinch_rounded, color: Colors.white70, size: 14),
                      SizedBox(width: 5),
                      Text('Pinch to zoom',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    context.read<ProductBloc>().add(SubmitProduct(
          productImage: _productImage,
          ingredientsImage: _ingredientsImage,
          nutritionImage: _nutritionImage,
          ageGroup: _ageGroup ?? '',
          category: _category ?? '',
        ));
  }

  Future<void> _showSuccessDialog({required bool offline}) {
    final color = offline ? const Color(0xffF59E0B) : Colors.green;
    final icon = offline ? Icons.cloud_off_rounded : Icons.check_circle_rounded;
    final title = offline ? 'Saved Offline' : 'Uploaded!';
    final message = offline
        ? 'Product saved locally. It will sync automatically when internet is restored.'
        : 'Product data has been uploaded successfully.';

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 8),
          Text(title),
        ]),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProductBloc, ProductState>(
      listener: (context, state) async {
        if (state is ProductUploadSuccess) {
          widget.onSuccess();
          await _showSuccessDialog(offline: false);
          if (!context.mounted) return;
          context.read<ProductBloc>().add(ResetProduct());
          Navigator.of(context).pop();
        } else if (state is ProductUploadSavedOffline) {
          if (widget.onOfflineSuccess != null) {
            widget.onOfflineSuccess!();
          } else {
            widget.onSuccess();
          }
          await _showSuccessDialog(offline: true);
          if (!context.mounted) return;
          context.read<ProductBloc>().add(ResetProduct());
          Navigator.of(context).pop();
        } else if (state is ProductError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Colors.red.shade700,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xffF8FBF8),
        body: BlocBuilder<ProductBloc, ProductState>(
          builder: (context, state) {
            final uploading = state is ProductUploading || state is ProductUploadSavedOffline || state is ProductUploadSuccess;
            return Stack(
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      // ── Header ────────────────────────────────────────
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 14),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xffDDF4E8),
                              Color(0xffEEF9F0),
                            ],
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () {
                                context
                                    .read<ProductBloc>()
                                    .add(ResetProduct());
                                Navigator.of(context).pop();
                              },
                              icon: const Icon(Icons.arrow_back_ios_new,
                                  size: 20),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'Review Product',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),

                      // ── Scrollable body ───────────────────────────────
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                          children: [
                            // Barcode card
                            _BarcodeCard(barcode: widget.barcode),

                            const SizedBox(height: 20),

                            // Category selector
                            _DropdownCard(
                              icon: Icons.category_outlined,
                              title: 'Product Category',
                              subtitle:
                                  'Category this product belongs to.',
                              hint: 'Select category',
                              value: _category,
                              items: _categories,
                              enabled: !uploading,
                              loading: _loadingCategories,
                              loadingLabel: 'Loading categories…',
                              error: _categoriesError,
                              emptyLabel: 'No categories available.',
                              onRetry: uploading ? null : _loadCategories,
                              onChanged: (v) => setState(() => _category = v),
                            ),

                            const SizedBox(height: 20),

                            // Age group selector
                            _DropdownCard(
                              icon: Icons.child_care,
                              title: 'Suitable Age',
                              subtitle:
                                  'Age range the product is suitable for (0 months – 18 years).',
                              hint: 'Select age group',
                              value: _ageGroup,
                              items: kAgeGroups,
                              enabled: !uploading,
                              onChanged: (v) => setState(() => _ageGroup = v),
                            ),

                            const SizedBox(height: 20),

                            // Captured Images title
                            const Row(
                              children: [
                                Icon(Icons.image,
                                    color: Color(0xff0A6475), size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'Captured Images',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),

                            const SizedBox(height: 14),

                            _CaptureCard(
                              number: '01',
                              title: 'Product\nPhoto',
                              color: const Color(0xff88DDD6),
                              image: _productImage,
                              onTap: _productImage != null
                                  ? () => _viewImage(
                                      _productImage!, 'Product Photo')
                                  : (uploading ? null : () => _replaceImage(0)),
                              onReplace:
                                  uploading ? null : () => _replaceImage(0),
                            ),

                            const SizedBox(height: 12),

                            _CaptureCard(
                              number: '02',
                              title: 'Ingredients\nPhoto',
                              color: const Color(0xffB39DDB),
                              image: _ingredientsImage,
                              onTap: _ingredientsImage != null
                                  ? () => _viewImage(
                                      _ingredientsImage!, 'Ingredients Photo')
                                  : (uploading ? null : () => _replaceImage(1)),
                              onReplace:
                                  uploading ? null : () => _replaceImage(1),
                            ),

                            const SizedBox(height: 12),

                            _CaptureCard(
                              number: '03',
                              title: 'Nutrition\nPhoto',
                              color: const Color(0xffFFCC80),
                              image: _nutritionImage,
                              onTap: _nutritionImage != null
                                  ? () => _viewImage(
                                      _nutritionImage!, 'Nutrition Photo')
                                  : (uploading ? null : () => _replaceImage(2)),
                              onReplace:
                                  uploading ? null : () => _replaceImage(2),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Submit bar ────────────────────────────────────────────
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                        16, 12, 16, MediaQuery.paddingOf(context).bottom + 12),
                    color: Colors.white,
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed:
                            (uploading || _ageGroup == null || _category == null)
                                ? null
                                : _submit,
                        icon: uploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.upload_outlined, size: 20),
                        label: Text(
                          uploading ? 'Uploading…' : 'Submit Product',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xff4CC6B7),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              const Color(0xff4CC6B7).withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Upload overlay ────────────────────────────────────────
                if (uploading)
                  Container(
                    color: Colors.black.withValues(alpha: 0.35),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 14),
                          Text('Uploading…',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Barcode card ──────────────────────────────────────────────────────────────

class _BarcodeCard extends StatelessWidget {
  final String barcode;
  const _BarcodeCard({required this.barcode});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff4BD0C0), Color(0xffA6F3D9)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.qr_code_2,
                size: 40, color: Color(0xff0A6475)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check, color: Colors.green, size: 14),
                      SizedBox(width: 4),
                      Text('Scanned Successfully',
                          style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                              fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Scanned Barcode',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  barcode,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.verified, color: Colors.green, size: 28),
          ),
        ],
      ),
    );
  }
}

// ── Dropdown card (category / age group) ──────────────────────────────────────

class _DropdownCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String hint;
  final String? value;
  final List<String> items;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  /// Async-list extras — unused by selectors backed by a constant list.
  final bool loading;
  final String loadingLabel;
  final String? error;
  final String emptyLabel;
  final VoidCallback? onRetry;

  const _DropdownCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.value,
    required this.items,
    required this.enabled,
    required this.onChanged,
    this.loading = false,
    this.loadingLabel = 'Loading…',
    this.error,
    this.emptyLabel = 'Nothing to select.',
    this.onRetry,
  });

  static const _accent = Color(0xff0A6475);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.07), blurRadius: 10),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: _accent, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              Text('*',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade400)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12.5, color: Color(0xff6B7B7E)),
          ),
          const SizedBox(height: 12),
          _field(),
        ],
      ),
    );
  }

  Widget _field() {
    if (loading) return _shell(child: _statusRow(loadingLabel, spinner: true));

    final message = error ?? (items.isEmpty ? emptyLabel : null);
    if (message != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _shell(child: _statusRow(message, isError: true)),
          if (onRetry != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(
                  foregroundColor: _accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
        ],
      );
    }

    return _shell(
      horizontalPadding: 14,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          // Guard against a selection that no longer exists in the list.
          value: items.contains(value) ? value : null,
          hint: Text(hint,
              style: const TextStyle(
                  fontSize: 14.5, color: Color(0xff9AA7A9))),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _accent),
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: Color(0xff20343A)),
          onChanged: enabled ? onChanged : null,
          items: [
            for (final item in items)
              DropdownMenuItem(value: item, child: Text(item)),
          ],
        ),
      ),
    );
  }

  Widget _shell({required Widget child, double horizontalPadding = 14}) =>
      Container(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        decoration: BoxDecoration(
          color: const Color(0xffF3F8F7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _accent.withValues(alpha: 0.20)),
        ),
        child: child,
      );

  Widget _statusRow(String label, {bool spinner = false, bool isError = false}) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          if (spinner)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
            )
          else
            Icon(Icons.error_outline_rounded,
                size: 17, color: Colors.red.shade400),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isError
                    ? Colors.red.shade400
                    : const Color(0xff6B7B7E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Capture card ──────────────────────────────────────────────────────────────

class _CaptureCard extends StatelessWidget {
  final String number;
  final String title;
  final Color color;
  final File? image;
  final VoidCallback? onTap;
  final VoidCallback? onReplace;

  const _CaptureCard({
    required this.number,
    required this.title,
    required this.color,
    required this.image,
    required this.onTap,
    required this.onReplace,
  });

  @override
  Widget build(BuildContext context) {
    final missing = image == null;
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.07), blurRadius: 10),
        ],
      ),
      child: Row(
        children: [
          // Left info panel
          Container(
            width: 110,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                bottomLeft: Radius.circular(18),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  number,
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: color.withValues(alpha: 0.85),
                      height: 1.0),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, height: 1.3),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const Spacer(),
                if (onReplace != null)
                  SizedBox(
                    height: 30,
                    child: OutlinedButton.icon(
                      onPressed: onReplace,
                      icon: Icon(
                          missing ? Icons.add_a_photo_outlined : Icons.refresh,
                          size: 13),
                      label: Text(missing ? 'Add Photo' : 'Replace',
                          style: const TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: color.withValues(alpha: 0.9),
                        side: BorderSide(
                            color: color.withValues(alpha: 0.5), width: 1),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Right image
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(18),
                      bottomRight: Radius.circular(18),
                    ),
                    child: missing
                        ? Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: color.withValues(alpha: 0.10),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.no_photography_outlined,
                                    color: color.withValues(alpha: 0.7),
                                    size: 26),
                                const SizedBox(height: 6),
                                Text('No Photo',
                                    style: TextStyle(
                                        color: color.withValues(alpha: 0.85),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          )
                        : Image.file(
                            image!,
                            width: double.infinity,
                            height: double.infinity,
                            fit: BoxFit.cover,
                          ),
                  ),
                  if (!missing)
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.48),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.zoom_in_rounded,
                                color: Colors.white, size: 12),
                            SizedBox(width: 3),
                            Text('Zoom',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
