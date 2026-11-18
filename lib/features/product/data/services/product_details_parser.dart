import 'package:flutter/foundation.dart' show visibleForTesting;
import '../../domain/entities/product_details.dart';

/// Turns raw OCR text from the three label photos into [ProductDetails].
///
/// This is rule-based on purpose: it runs offline, is fast on low-end phones
/// and is easy to adjust when a new label layout turns up. It only fills a
/// field when it is reasonably sure; the agent corrects the rest on screen.
///
/// Each input is the OCR text of one photo with table rows already rebuilt
/// into single lines (see `ProductOcrService`), e.g. "Protein 5.2 g".
class ProductDetailsParser {
  const ProductDetailsParser();

  ProductDetails parse({
    String frontText = '',
    String ingredientsText = '',
    String nutritionText = '',
  }) {
    final all = [frontText, ingredientsText, nutritionText].join('\n');
    // Ingredients are usually on their own photo, but some packs print them
    // next to the nutrition table, so fall back to everything we read.
    // No header found (photo cropped below it, or OCR missed it): take the
    // comma-separated paragraph of the ingredients photo.
    final ingredients = _ingredients(ingredientsText)
        .ifEmpty(() => _ingredients(all))
        .ifEmpty(() => _ingredients(ingredientsText, guess: true));
    return ProductDetails(
      netQuantity: _netQuantity(all),
      mrp: _mrp(all),
      fssaiLicense: _fssai(all),
      ingredients: ingredients,
      allergens: _allergens(ingredientsText).ifEmpty(() => _allergens(all)),
      nutrition: _nutrition(nutritionText.ifEmpty(() => all)),
      nutritionBasis: _basis(nutritionText.ifEmpty(() => all)),
    );
  }

  // ── Number helpers ──────────────────────────────────────────────────────

  /// A label number: "12", "12.5", "12,5" (EU comma) or "<0.5".
  static const _num = r'(<\s*)?(\d+(?:[.,]\d+)?)';

  static String _cleanNumber(String? lessThan, String n) =>
      '${lessThan != null ? '<' : ''}${n.replaceAll(',', '.')}';

  // ── Nutrition ───────────────────────────────────────────────────────────

  /// Most specific label first, so "Saturated fat" never lands in total fat.
  /// Each rebuilt line is assigned to at most one field.
  /// Keys starting with "_" claim a line without storing anything, so e.g.
  /// a MUFA row can't fall through to "total fat".
  static final List<(String, RegExp, String)> _nutritionRules = [
    // Energy-from-fat rows must not be read as energy or fat.
    ('_energy_from_fat', RegExp(r'(energy|calories)\s*from\s*fat', caseSensitive: false), ''),
    // Not "monounsaturated" / "polyunsaturated" / "unsaturated".
    ('saturated_fat_g', RegExp(r'(?<![a-z])saturated|\bsat\.?\s*fat|\bsfa\b', caseSensitive: false), 'g'),
    ('_unsaturated', RegExp(r'unsaturated|\bmufa\b|\bpufa\b', caseSensitive: false), ''),
    ('trans_fat_g', RegExp(r'trans\s*-?\s*fat|\btfa\b|trans fatty', caseSensitive: false), 'g'),
    ('added_sugar_g', RegExp(r'added\s*sugar', caseSensitive: false), 'g'),
    ('total_sugar_g', RegExp(r'\bsugars?\b', caseSensitive: false), 'g'),
    ('dietary_fibre_g', RegExp(r'fib(re|er)', caseSensitive: false), 'g'),
    ('carbohydrate_g', RegExp(r'carbo\s*hydrates?|\bcarbs\b', caseSensitive: false), 'g'),
    ('protein_g', RegExp(r'protein', caseSensitive: false), 'g'),
    ('cholesterol_mg', RegExp(r'cholesterol', caseSensitive: false), 'mg'),
    ('sodium_mg', RegExp(r'sodium', caseSensitive: false), 'mg'),
    ('total_fat_g', RegExp(r'\bfats?\b|\blipids?\b', caseSensitive: false), 'g'),
    ('energy_kcal', RegExp(r'energy|calories|\bkcal\b', caseSensitive: false), 'kcal'),
  ];

  Map<String, String> _nutrition(String text) {
    final out = <String, String>{};
    for (final raw in _lines(text)) {
      final line = fixOcrDigits(raw);
      for (final (key, label, unit) in _nutritionRules) {
        final m = label.firstMatch(line);
        if (m == null) continue;
        if (key.startsWith('_')) break; // claimed, not stored
        if (out.containsKey(key)) break; // first row wins (per 100 g table)
        final rest = line.substring(m.end);
        final value = key == 'energy_kcal'
            ? _energyKcal(line, rest)
            : _valueAfter(rest, unit, hint: _unitHint(rest));
        if (value != null) out[key] = value;
        break; // one field per line
      }
    }
    return out;
  }

  /// Unit printed in the row label instead of after the number:
  /// "Sodium (mg) 310", "Protein (g) 6.8", "Energy (kcal) 507".
  String? _unitHint(String rest) {
    final m = RegExp(r'^\s*[(\[]\s*(mg|g|gm|mcg|µg|kcal|kj)\s*[)\]]',
            caseSensitive: false)
        .firstMatch(rest);
    final u = m?.group(1)?.toLowerCase();
    return u == 'gm' ? 'g' : u;
  }

  /// Fixes the usual OCR slips inside numbers: "O.5"/"1O" → 0, "l2"/"I2"
  /// → 12. Only touches letters that sit against digits or a decimal point,
  /// so words are left alone.
  @visibleForTesting
  static String fixOcrDigits(String line) => line
      .replaceAllMapped(RegExp(r'(?<=\d)[oO](?=[\d.,]|\s|g\b|mg\b|$)'), (_) => '0')
      .replaceAllMapped(RegExp(r'(?<![a-zA-Z])[oO](?=[.,]\d)'), (_) => '0')
      .replaceAllMapped(RegExp(r'(?<=\d)[lI|](?=\d)'), (_) => '1')
      .replaceAllMapped(RegExp(r'(?<![a-zA-Z\d])[lI](?=\d)'), (_) => '1');

  /// A whole number token with its unit. Never matches part of a number
  /// ("12%" can't yield "1"), and "%" is captured so %RDA columns can be
  /// skipped.
  static final _token = RegExp(
    r'(<\s*)?(?<![\d.,])(\d+(?:[.,]\d+)?)(?![\d])\s*(mcg|µg|mg|kcal|kj|gm|g|%)?(?![a-z])',
    caseSensitive: false,
  );

  /// Picks the first value after the label (not a % column), converting
  /// g ↔ mg when the label uses a different unit than the field. [hint] is a
  /// unit printed in the row label, used when the number has none.
  String? _valueAfter(String rest, String fieldUnit, {String? hint}) {
    for (final m in _token.allMatches(rest)) {
      var unit = m.group(3)?.toLowerCase();
      if (unit == '%') continue;
      if (unit == 'gm') unit = 'g';
      unit ??= hint;
      final lt = m.group(1);
      final raw = m.group(2)!;
      final n = double.tryParse(raw.replaceAll(',', '.'));
      if (n == null) continue;
      if (fieldUnit == 'mg' && unit == 'g') return _fmt(lt, n * 1000);
      if (fieldUnit == 'g' && unit == 'mg') return _fmt(lt, n / 1000);
      if (fieldUnit == 'g' && (unit == 'mcg' || unit == 'µg')) {
        return _fmt(lt, n / 1e6);
      }
      if (fieldUnit == 'mg' && (unit == 'mcg' || unit == 'µg')) {
        return _fmt(lt, n / 1000);
      }
      return _cleanNumber(lt, raw);
    }
    // "Trans Fat Nil", "Cholesterol NIL": printed zero.
    if (RegExp(r'^\W*(nil|none|not detected|n\.?d\.?)\b', caseSensitive: false)
        .hasMatch(rest)) {
      return '0';
    }
    return null;
  }

  /// Energy is often printed as "1650 kJ / 395 kcal"; prefer the kcal figure,
  /// fall back to converting kJ, then to the bare first number.
  String? _energyKcal(String line, String rest) {
    // A number with its own unit: "395 kcal", "1650 kJ".
    final kcal = RegExp('$_num\\s*k\\s*cal', caseSensitive: false).firstMatch(line);
    if (kcal != null) return _cleanNumber(kcal.group(1), kcal.group(2)!);
    final kj = RegExp('$_num\\s*kj', caseSensitive: false).firstMatch(line);
    if (kj != null) {
      final n = double.tryParse(kj.group(2)!.replaceAll(',', '.'));
      if (n != null) return _fmt(kj.group(1), n / 4.184);
    }
    // Units only in the label: "Energy (kJ/kcal) 2120/507",
    // "Energy (kcal) 507", "Energy (kJ) 2120".
    final nums = [
      for (final m in _token.allMatches(rest))
        if (m.group(3) != '%') (lt: m.group(1), raw: m.group(2)!),
    ];
    if (nums.isEmpty) return null;
    final lower = rest.toLowerCase();
    final kjAt = lower.indexOf('kj'), kcalAt = lower.indexOf('kcal');
    if (kjAt >= 0 && kcalAt >= 0 && nums.length >= 2) {
      final v = kcalAt < kjAt ? nums[0] : nums[1];
      return _cleanNumber(v.lt, v.raw);
    }
    if (kjAt >= 0 && kcalAt < 0) {
      final n = double.tryParse(nums.first.raw.replaceAll(',', '.'));
      if (n != null) return _fmt(nums.first.lt, n / 4.184);
    }
    return _cleanNumber(nums.first.lt, nums.first.raw);
  }

  String _fmt(String? lt, double n) {
    // 1 dp is plenty for label values (3 dp below 1 so "0.045 g" survives);
    // then strip trailing zeros and a bare trailing dot: 239.0 → 239.
    final s = n
        .toStringAsFixed(n < 1 ? 3 : 1)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    return '${lt != null ? '<' : ''}$s';
  }

  String _basis(String text) {
    final m = RegExp(
      r'per\s*(\d+\s*(?:g|gm|ml)|serv(?:e|ing)[^\n]{0,15})',
      caseSensitive: false,
    ).firstMatch(text);
    return m == null ? '' : 'per ${m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim()}';
  }

  // ── Ingredients & allergens ─────────────────────────────────────────────

  /// Where the ingredient list ends on most Indian / EU packs.
  static final _ingredientStop = RegExp(
    r'(allerg|contains\s*:|may contain|nutrition|nutritional|manufactured|mfd|'
    r'marketed by|packed by|best before|use by|storage|store in|net\s*(wt|weight|qty|quantity)|'
    r'm\.?\s*r\.?\s*p|fssai|customer care)',
    caseSensitive: false,
  );

  /// "INGREDIENTS:" as OCR reads it: "lngredients", "INGREDIENT5", "Ingredients;".
  static const _ingredientWord = r'[il1|]ngred[il1|]ents?|[il1|]ngred[il1|]ent5';

  String _ingredients(String text, {bool guess = false}) {
    // Prefer the real header: followed by ":" / "-", or starting a line.
    // "No artificial ingredients" in a claim must not be taken as the start.
    final start = RegExp('(?:$_ingredientWord)\\s*[:;\\-]',
                caseSensitive: false)
            .firstMatch(text) ??
        RegExp('(?:^|\\n)\\s*(?:$_ingredientWord)\\b\\s*',
                caseSensitive: false)
            .firstMatch(text);
    if (start == null) return guess ? _listParagraph(text) : '';
    var body = text.substring(start.end);
    final stop = _ingredientStop.firstMatch(body);
    if (stop != null) body = body.substring(0, stop.start);
    return _squash(body).replaceFirst(RegExp(r'^[\s:.\-]+'), '').replaceFirst(RegExp(r'[\s,;]+$'), '');
  }

  /// The paragraph that looks most like an ingredient list (several
  /// comma-separated items), cut at the usual end markers; '' if none does.
  String _listParagraph(String text) {
    final cut = _ingredientStop.firstMatch(text);
    final body = cut == null ? text : text.substring(0, cut.start);
    var best = '';
    var bestCommas = 0;
    for (final para in body.split(RegExp(r'\n\s*\n'))) {
      final squashed = _squash(para);
      final commas = ','.allMatches(squashed).length;
      if (commas > bestCommas) {
        best = squashed;
        bestCommas = commas;
      }
    }
    // A real list has several items; fewer is more likely a slogan.
    return bestCommas >= 3 ? best.replaceFirst(RegExp(r'[\s,;]+$'), '') : '';
  }

  String _allergens(String text) {
    final m = RegExp(
      r'(?:allergen(?:\s*information)?|allergy\s*advice|contains)\s*[:\-]\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return '';
    return _squash(m.group(1)!).replaceFirst(RegExp(r'[.\s]+$'), '');
  }

  // ── Front-of-pack fields ────────────────────────────────────────────────

  static const _qtyUnit = r'kg|g|gm|gms|grams?|ml|l|ltr|litres?|liters?';

  String _netQuantity(String text) {
    final label = r'nett?\s*\.?\s*(?:wt|weight|qty|quantity|content|vol(?:ume)?)\.?';
    // "Net Wt. 200g", "NETT WT: 1 kg"
    final m = RegExp(
      '$label\\s*[:\\-]?\\s*(\\d+(?:[.,]\\d+)?)\\s*($_qtyUnit)\\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) {
      return '${m.group(1)!.replaceAll(',', '.')} ${_unit(m.group(2)!)}';
    }
    // "Net Weight (g): 70"
    final p = RegExp(
      '$label\\s*[(\\[]\\s*($_qtyUnit)\\s*[)\\]]\\s*[:\\-]?\\s*(\\d+(?:[.,]\\d+)?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (p != null) {
      return '${p.group(2)!.replaceAll(',', '.')} ${_unit(p.group(1)!)}';
    }
    return '';
  }

  String _unit(String u) {
    final l = u.toLowerCase();
    if (l.startsWith('g')) return 'g';
    if (l == 'kg') return 'kg';
    if (l == 'ml') return 'ml';
    return 'L';
  }

  String _mrp(String text) {
    final m = RegExp(
      r'm\.?\s*r\.?\s*p\.?[^0-9₹]{0,25}(?:₹|rs\.?|inr)?\s*(\d+(?:[.,]\d{1,2})?)',
      caseSensitive: false,
    ).firstMatch(text);
    return m == null ? '' : m.group(1)!.replaceAll(',', '.');
  }

  /// FSSAI licence numbers are 14 digits; OCR often splits them with spaces.
  String _fssai(String text) {
    final m = RegExp(
      r'(?:fssai|lic(?:ence|ense)?\.?\s*no)[^0-9oOlI]{0,20}((?:[\doOlI][\s-]?){14})',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return '';
    // OCR often reads 0 as O and 1 as l/I inside long numbers.
    final digits = m
        .group(1)!
        .replaceAll(RegExp('[oO]'), '0')
        .replaceAll(RegExp('[lI]'), '1')
        .replaceAll(RegExp(r'\D'), '');
    return digits.length == 14 ? digits : '';
  }

  // ── Text helpers ────────────────────────────────────────────────────────

  Iterable<String> _lines(String text) =>
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);

  String _squash(String s) => s
      .replaceAll(RegExp(r'-\n'), '') // re-join words hyphenated across lines
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

extension on String {
  String ifEmpty(String Function() fallback) => isEmpty ? fallback() : this;
}
