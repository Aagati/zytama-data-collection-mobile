import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:zytama_data/features/product/data/services/product_details_parser.dart';
import 'package:zytama_data/features/product/data/services/product_ocr_service.dart';
import 'package:zytama_data/features/product/domain/entities/product_details.dart';

void main() {
  const parser = ProductDetailsParser();

  group('nutrition', () {
    test('reads a typical Indian per-100 g table', () {
      final d = parser.parse(nutritionText: '''
NUTRITIONAL INFORMATION (Approx.) Per 100 g
Energy 1650 kJ / 395 kcal
Protein 6.8 g
Carbohydrate 72.4 g
Total Sugars 24.1 g
Added Sugars 22 g
Total Fat 8.9 g
Saturated Fat 4.2 g
Trans Fat 0.1 g
Cholesterol 0 mg
Sodium 310 mg
''');
      expect(d.nutritionBasis, 'per 100 g');
      expect(d.nutrition, {
        'energy_kcal': '395',
        'protein_g': '6.8',
        'carbohydrate_g': '72.4',
        'total_sugar_g': '24.1',
        'added_sugar_g': '22',
        'total_fat_g': '8.9',
        'saturated_fat_g': '4.2',
        'trans_fat_g': '0.1',
        'cholesterol_mg': '0',
        'sodium_mg': '310',
      });
    });

    test('converts kJ-only energy and g sodium, keeps "<"', () {
      final d = parser.parse(nutritionText: '''
Energy 1000 kJ
Sodium 0.45 g
Fibre <0,5 g
''');
      expect(d.nutrition['energy_kcal'], '239');
      expect(d.nutrition['sodium_mg'], '450');
      expect(d.nutrition['dietary_fibre_g'], '<0.5');
    });
  });

  group('ingredients and allergens', () {
    test('stops the ingredient list at the allergen statement', () {
      final d = parser.parse(ingredientsText: '''
INGREDIENTS: Wheat flour (Atta), Sugar, Edible vegetable
oil (Palm), Milk solids, Raising agents [503(ii), 500(ii)],
Iodised salt.
ALLERGEN INFORMATION: Contains wheat, milk. May contain soy.
''');
      expect(
        d.ingredients,
        'Wheat flour (Atta), Sugar, Edible vegetable oil (Palm), Milk solids, '
        'Raising agents [503(ii), 500(ii)], Iodised salt.',
      );
      expect(d.allergens, 'Contains wheat, milk. May contain soy');
    });
  });

  group('front of pack', () {
    test('reads net quantity, MRP and a spaced FSSAI number', () {
      final d = parser.parse(frontText: '''
NET WT. 200g
M.R.P. ₹ 45.00 (Incl. of all taxes)
FSSAI Lic. No. 1001 2345 6789 01
''');
      expect(d.netQuantity, '200 g');
      expect(d.mrp, '45.00');
      expect(d.fssaiLicense, '10012345678901');
    });

    test('leaves fields empty rather than guessing', () {
      final d = parser.parse(frontText: 'CHOCO CRUNCH\nnew & improved');
      expect(d.isEmpty, isTrue);
    });
  });

  test('ProductDetails JSON round-trips and drops empty nutrition', () {
    const d = ProductDetails(
      mrp: '45',
      nutrition: {'protein_g': '6.8', 'sodium_mg': ''},
    );
    final back = ProductDetails.decode(d.encode());
    expect(back.mrp, '45');
    expect(back.nutrition, {'protein_g': '6.8'});
    expect(ProductDetails.decode('not json'), ProductDetails.empty);
  });

  test('groupIntoRows joins a label column with its value column', () {
    // ML Kit often returns all labels first, then all values.
    final rows = ProductOcrService.groupIntoRows([
      (box: const Rect.fromLTWH(10, 100, 80, 20), text: 'Protein'),
      (box: const Rect.fromLTWH(10, 130, 80, 20), text: 'Total Fat'),
      (box: const Rect.fromLTWH(200, 102, 40, 20), text: '6.8 g'),
      (box: const Rect.fromLTWH(200, 131, 40, 20), text: '8.9 g'),
    ]);
    expect(rows, 'Protein 6.8 g\nTotal Fat 8.9 g');
  });

  group('real-world OCR slips', () {
    test('%RDA column never yields a partial number', () {
      final d = parser.parse(nutritionText: '''
Protein 12% 6.8 g
Total Fat 15 %
''');
      expect(d.nutrition['protein_g'], '6.8');
      expect(d.nutrition.containsKey('total_fat_g'), isFalse);
    });

    test('MUFA / PUFA rows never land in saturated or total fat', () {
      final d = parser.parse(nutritionText: '''
Total Fat 25.0 g
Monounsaturated Fatty Acids 10.2 g
Polyunsaturated Fatty Acids 3.1 g
Saturated Fatty Acids 11.4 g
Trans Fatty Acids 0.1 g
''');
      expect(d.nutrition['total_fat_g'], '25.0');
      expect(d.nutrition['saturated_fat_g'], '11.4');
      expect(d.nutrition['trans_fat_g'], '0.1');
    });

    test('units printed in the row label are respected', () {
      final d = parser.parse(nutritionText: '''
Energy (kJ/kcal) 2120/507
Protein (g) 6.8
Sodium (g) 0.45
Cholesterol (mg) 0
''');
      expect(d.nutrition['energy_kcal'], '507');
      expect(d.nutrition['protein_g'], '6.8');
      expect(d.nutrition['sodium_mg'], '450');
      expect(d.nutrition['cholesterol_mg'], '0');
      expect(
          parser.parse(nutritionText: 'Energy (kJ) 2120').nutrition['energy_kcal'],
          '506.7');
      expect(
          parser.parse(nutritionText: 'Energy (kcal) 507 152 7.6%')
              .nutrition['energy_kcal'],
          '507');
    });

    test('letter O / l inside numbers and "Nil" values', () {
      final d = parser.parse(nutritionText: '''
Protein 1O.5 g
Total Sugars O.5 g
Sodium l20 mg
Trans Fat Nil
Cholesterol NIL
''');
      expect(d.nutrition['protein_g'], '10.5');
      expect(d.nutrition['total_sugar_g'], '0.5');
      expect(d.nutrition['sodium_mg'], '120');
      expect(d.nutrition['trans_fat_g'], '0');
      expect(d.nutrition['cholesterol_mg'], '0');
    });

    test('energy-from-fat row is not the energy value', () {
      final d = parser.parse(nutritionText: '''
Energy from Fat 90 kcal
Energy 395 kcal
''');
      expect(d.nutrition['energy_kcal'], '395');
    });

    test('a claim mentioning ingredients is not the ingredient list', () {
      final d = parser.parse(ingredientsText: '''
No artificial ingredients. Made with love.
INGREDIENTS: Corn meal, Edible vegetable oil, Spices, Salt.
''');
      expect(d.ingredients, 'Corn meal, Edible vegetable oil, Spices, Salt.');
    });

    test('OCR-garbled header and header-less list', () {
      expect(
          parser.parse(ingredientsText: 'lNGREDIENT5: Rice, Sugar, Salt')
              .ingredients,
          'Rice, Sugar, Salt');
      // Photo cropped below the header: the comma list is still found.
      expect(
          parser.parse(ingredientsText: '''
Saffola Crunchiez

Millet flour (31%), Corn meal, Rice bran oil, Spices, Salt, Sugar.

Allergen advice: contains soy.
''').ingredients,
          'Millet flour (31%), Corn meal, Rice bran oil, Spices, Salt, Sugar.');
      // A slogan with a comma isn't a list.
      expect(parser.parse(ingredientsText: 'Tasty, crunchy').ingredients, '');
    });

    test('net quantity variants and FSSAI with O/l slips', () {
      expect(parser.parse(frontText: 'NETT WT. 1 kg').netQuantity, '1 kg');
      expect(parser.parse(frontText: 'Net Weight (g): 70').netQuantity, '70 g');
      expect(
          parser.parse(frontText: 'FSSAI Lic. No. 1OO1 2345 6789 Ol')
              .fssaiLicense,
          '10012345678901');
    });
  });

  group('row rebuilding', () {
    // Corner points of a line of text [w]×[h] at (x, y), tilted by [deg].
    ({math.Point<int> tl, math.Point<int> tr, math.Point<int> br,
        math.Point<int> bl, String text}) line(
        double x, double y, double w, double h, double deg, String text) {
      final a = deg * math.pi / 180, c = math.cos(a), s = math.sin(a);
      math.Point<int> p(double dx, double dy) =>
          math.Point((x + dx * c - dy * s).round(), (y + dx * s + dy * c).round());
      return (tl: p(0, 0), tr: p(w, 0), br: p(w, h), bl: p(0, h), text: text);
    }

    // Rotates a whole table layout by [deg] around the origin.
    List<({math.Point<int> tl, math.Point<int> tr, math.Point<int> br,
        math.Point<int> bl, String text})> table(double deg) {
      final a = deg * math.pi / 180, c = math.cos(a), s = math.sin(a);
      final rows = [
        ('Energy', '395 kcal'),
        ('Protein', '6.8 g'),
        ('Carbohydrate', '72.4 g'),
        ('Total Fat', '8.9 g'),
      ];
      return [
        for (var i = 0; i < rows.length; i++) ...[
          // Label at x=0, value at x=600 (a wide table), rows 30 px apart.
          for (final (x, text) in [(0.0, rows[i].$1), (600.0, rows[i].$2)])
            line(x * c - (i * 30) * s, x * s + (i * 30) * c, 120, 20, deg, text),
        ],
      ];
    }

    for (final deg in [0.0, 4.0, -6.0, 90.0, -90.0]) {
      test('rebuilds rows on a table tilted ${deg.toStringAsFixed(0)}°', () {
        final rows = ProductOcrService.groupIntoRows(
            ProductOcrService.deskewLines(table(deg)));
        expect(rows,
            'Energy 395 kcal\nProtein 6.8 g\nCarbohydrate 72.4 g\nTotal Fat 8.9 g');
      });
    }

    test('without deskewing, a 4° tilt would scramble the rows', () {
      // Guards the reason deskewing exists: axis-aligned boxes of the
      // tilted table do not group correctly.
      final tilted = table(4);
      final naive = [
        for (final l in tilted)
          (
            box: Rect.fromPoints(
                Offset(l.tl.x.toDouble(), l.tl.y.toDouble()),
                Offset(l.br.x.toDouble(), l.br.y.toDouble())),
            text: l.text,
          ),
      ];
      expect(ProductOcrService.groupIntoRows(naive),
          isNot('Energy 395 kcal\nProtein 6.8 g\nCarbohydrate 72.4 g\nTotal Fat 8.9 g'));
    });
  });
}
