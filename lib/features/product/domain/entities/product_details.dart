import 'dart:convert';
import 'package:equatable/equatable.dart';

/// Nutrition rows we try to read off the label, in display order.
/// Keys are stable and sent to the backend as-is.
const Map<String, String> kNutritionFields = {
  'energy_kcal': 'Energy (kcal)',
  'protein_g': 'Protein (g)',
  'carbohydrate_g': 'Carbohydrate (g)',
  'total_sugar_g': 'Total sugar (g)',
  'added_sugar_g': 'Added sugar (g)',
  'total_fat_g': 'Total fat (g)',
  'saturated_fat_g': 'Saturated fat (g)',
  'trans_fat_g': 'Trans fat (g)',
  'cholesterol_mg': 'Cholesterol (mg)',
  'sodium_mg': 'Sodium (mg)',
  'dietary_fibre_g': 'Dietary fibre (g)',
};

/// Product details read from the label photos by OCR and then corrected by the
/// agent on the review screen. Every field is optional: a missing value is an
/// empty string, never a guess.
class ProductDetails extends Equatable {
  final String netQuantity;
  final String mrp;
  final String fssaiLicense;
  final String ingredients;
  final String allergens;

  /// Values per the label's basis (usually per 100 g / 100 ml), keyed by
  /// [kNutritionFields]. Values are kept as text so "<0.5" survives.
  final Map<String, String> nutrition;
  final String nutritionBasis;

  const ProductDetails({
    this.netQuantity = '',
    this.mrp = '',
    this.fssaiLicense = '',
    this.ingredients = '',
    this.allergens = '',
    this.nutrition = const {},
    this.nutritionBasis = '',
  });

  static const empty = ProductDetails();

  bool get isEmpty =>
      netQuantity.isEmpty &&
      mrp.isEmpty &&
      fssaiLicense.isEmpty &&
      ingredients.isEmpty &&
      allergens.isEmpty &&
      nutrition.values.every((v) => v.isEmpty);

  ProductDetails copyWith({
    String? netQuantity,
    String? mrp,
    String? fssaiLicense,
    String? ingredients,
    String? allergens,
    Map<String, String>? nutrition,
    String? nutritionBasis,
  }) =>
      ProductDetails(
        netQuantity: netQuantity ?? this.netQuantity,
        mrp: mrp ?? this.mrp,
        fssaiLicense: fssaiLicense ?? this.fssaiLicense,
        ingredients: ingredients ?? this.ingredients,
        allergens: allergens ?? this.allergens,
        nutrition: nutrition ?? this.nutrition,
        nutritionBasis: nutritionBasis ?? this.nutritionBasis,
      );

  Map<String, dynamic> toJson() => {
        'net_quantity': netQuantity,
        'mrp': mrp,
        'fssai_license': fssaiLicense,
        'ingredients': ingredients,
        'allergens': allergens,
        'nutrition_basis': nutritionBasis,
        'nutrition': {
          for (final e in nutrition.entries)
            if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
        },
      };

  factory ProductDetails.fromJson(Map<String, dynamic> json) => ProductDetails(
        netQuantity: json['net_quantity'] as String? ?? '',
        mrp: json['mrp'] as String? ?? '',
        fssaiLicense: json['fssai_license'] as String? ?? '',
        ingredients: json['ingredients'] as String? ?? '',
        allergens: json['allergens'] as String? ?? '',
        nutritionBasis: json['nutrition_basis'] as String? ?? '',
        nutrition: (json['nutrition'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            const {},
      );

  String encode() => jsonEncode(toJson());

  /// Returns [empty] for a blank or malformed string (e.g. an old offline row).
  static ProductDetails decode(String raw) {
    if (raw.trim().isEmpty) return empty;
    try {
      return ProductDetails.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return empty;
    }
  }

  @override
  List<Object?> get props => [
        netQuantity,
        mrp,
        fssaiLicense,
        ingredients,
        allergens,
        nutrition,
        nutritionBasis,
      ];
}
