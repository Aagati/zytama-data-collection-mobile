import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../../domain/entities/product_details.dart';
import 'product_details_parser.dart';

/// On-device OCR for the label photos (Google ML Kit, Latin script).
///
/// Runs fully offline; nothing leaves the phone except what the agent submits.
///
/// Each photo is read once and the result cached by file path, so the capture
/// screen can start reading a label the moment it's shot ([readText]) and the
/// review screen later picks up the finished (or still running) result
/// instead of reading it again.
class ProductOcrService {
  final ProductDetailsParser _parser;
  ProductOcrService([this._parser = const ProductDetailsParser()]);

  TextRecognizer? _recognizer;

  /// Calls run one at a time: cheaper on low-end phones than parallel native
  /// sessions, and keeps the live camera preview smooth during capture.
  Future<void> _queue = Future.value();

  /// path|mode → text. Small cap: only the current product's photos matter.
  final _cache = <String, Future<String>>{};
  static const _cacheLimit = 12;

  /// OCR text of one photo. Paragraph text (front of pack, ingredients) reads
  /// best in ML Kit's own block order; [asTable] rebuilds rows for nutrition
  /// tables (rebuilding would interleave side-by-side paragraphs).
  /// Never throws: a failed read yields ''. [force] ignores the cache.
  Future<String> readText(File file,
      {bool asTable = false, bool force = false}) {
    final key = '${file.path}|$asTable';
    if (!force) {
      final hit = _cache.remove(key);
      if (hit != null) return _cache[key] = hit; // re-insert = most recent
    }
    final job = _queue.then((_) => _read(file, asTable));
    _queue = job.then((_) {}, onError: (_) {});
    final text = job.then((r) => r.text);
    _cache[key] = text;
    _turns.remove(file.path);
    _turns[file.path] = job.then((r) => r.turns);
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    while (_turns.length > _cacheLimit) {
      _turns.remove(_turns.keys.first);
    }
    return text;
  }

  /// path → clockwise quarter turns that make the text upright.
  final _turns = <String, Future<int?>>{};

  /// Clockwise quarter turns (0–3) that make [file]'s text read upright, or
  /// null when there's too little text to tell. Reuses a read already
  /// started for this photo; otherwise reads it. Never throws.
  Future<int?> uprightTurns(File file) {
    final hit = _turns[file.path];
    if (hit != null) return hit;
    readText(file);
    return _turns[file.path]!;
  }

  Future<({String text, int? turns})> _read(File file, bool asTable) async {
    try {
      final recognizer = _recognizer ??=
          TextRecognizer(script: TextRecognitionScript.latin);
      final result =
          await recognizer.processImage(InputImage.fromFilePath(file.path));
      return (
        text: asTable ? rebuildRows(result) : result.text,
        turns: textTurns([
          for (final block in result.blocks)
            for (final line in block.lines)
              if (line.cornerPoints.length == 4)
                (
                  dx: (line.cornerPoints[1].x - line.cornerPoints[0].x)
                      .toDouble(),
                  dy: (line.cornerPoints[1].y - line.cornerPoints[0].y)
                      .toDouble(),
                  chars: line.text.trim().length,
                ),
        ]),
      );
    } catch (e) {
      debugPrint('[ProductOcrService] OCR failed for ${file.path}: $e');
      return (text: '', turns: null);
    }
  }

  /// Votes on reading direction: each line's top-left → top-right edge
  /// points the way its text reads, weighted by its length. Returns the
  /// clockwise quarter turns that make the winning direction point right,
  /// or null if there's too little text or no clear majority.
  @visibleForTesting
  static int? textTurns(List<({double dx, double dy, int chars})> lines) {
    final votes = List<double>.filled(4, 0);
    var total = 0.0;
    for (final l in lines) {
      if (l.chars < 3 || (l.dx == 0 && l.dy == 0)) continue;
      // Direction in image coords (y down): 0 = right, 1 = down, 2 = left,
      // 3 = up. Text reading down needs 3 turns (= 90° anticlockwise).
      final dir = ((math.atan2(l.dy, l.dx) / (math.pi / 2)).round()) % 4;
      final turns = (4 - dir) % 4;
      votes[turns] += l.chars;
      total += l.chars;
    }
    if (total < 12) return null;
    var best = 0;
    for (var i = 1; i < 4; i++) {
      if (votes[i] > votes[best]) best = i;
    }
    return votes[best] >= total * 0.6 ? best : null;
  }

  /// Reads all available photos (cached where already read) and parses them
  /// into [ProductDetails]. Never throws.
  Future<ProductDetails> extract({
    File? frontImage,
    File? ingredientsImage,
    File? nutritionImage,
    bool force = false,
  }) async {
    Future<String> read(File? f, {bool asTable = false}) =>
        f == null ? Future.value('') : readText(f, asTable: asTable, force: force);
    final texts = await Future.wait([
      read(frontImage),
      read(ingredientsImage),
      read(nutritionImage, asTable: true),
    ]);
    final details = _parser.parse(
      frontText: texts[0],
      ingredientsText: texts[1],
      nutritionText: texts[2],
    );
    _log(texts[1], texts[2], details);
    return details;
  }

  /// Debug only: prints exactly what OCR read off the ingredients and
  /// nutrition photos, then what the parser made of it, so a wrong field can
  /// be traced to the read or the parse. One debugPrint per line keeps
  /// logcat from truncating long text.
  static void _log(
      String ingredientsText, String nutritionText, ProductDetails d) {
    if (!kDebugMode) return;
    void block(String title, String body) {
      debugPrint('[OCR] ===== $title =====');
      if (body.trim().isEmpty) {
        debugPrint('[OCR] (nothing read)');
      } else {
        for (final line in body.split('\n')) {
          debugPrint('[OCR] $line');
        }
      }
    }

    block('INGREDIENTS (raw OCR)', ingredientsText);
    block('NUTRITION FACTS TABLE (raw OCR, rows rebuilt)', nutritionText);
    block('PARSED INGREDIENTS', d.ingredients);
    block('PARSED ALLERGENS', d.allergens);
    block(
      'PARSED NUTRITION ${d.nutritionBasis.isEmpty ? '' : '(${d.nutritionBasis})'}',
      [
        for (final e in kNutritionFields.entries)
          '${e.value.padRight(20)} ${d.nutrition[e.key] ?? '—'}',
      ].join('\n'),
    );
    debugPrint('[OCR] ===== END =====');
  }

  /// ML Kit returns text block by block, and on a nutrition table that often
  /// means the label column first and the values column after it. Grouping
  /// lines whose vertical centres line up, then sorting each group left to
  /// right, turns it back into "Protein 5.2 g" rows the parser can read.
  ///
  /// Rows are matched in the text's own frame, not the photo's: a label shot
  /// a few degrees tilted puts the value at the far right of a wide table
  /// tens of pixels above or below its label (enough to land on the
  /// neighbouring row), and one shot sideways has no horizontal rows at all.
  @visibleForTesting
  static String rebuildRows(RecognizedText result) {
    final raw = <({List<math.Point<int>> c, String text})>[
      for (final block in result.blocks)
        for (final line in block.lines)
          if (line.text.trim().isNotEmpty && line.cornerPoints.length == 4)
            (c: line.cornerPoints, text: line.text.trim()),
    ];
    return groupIntoRows(deskewLines([
      for (final l in raw)
        (
          tl: l.c[0], tr: l.c[1], br: l.c[2], bl: l.c[3], text: l.text,
        ),
    ]));
  }

  /// Rotates text lines (ML Kit corner points: top-left, top-right,
  /// bottom-right, bottom-left in reading order) so their common reading
  /// direction points right, and returns them as upright boxes.
  @visibleForTesting
  static List<({Rect box, String text})> deskewLines(
      List<
              ({
                math.Point<int> tl,
                math.Point<int> tr,
                math.Point<int> br,
                math.Point<int> bl,
                String text
              })>
          lines) {
    // Dominant reading direction: length-weighted mean of the lines' unit
    // vectors (long lines are measured most precisely).
    var vx = 0.0, vy = 0.0;
    for (final l in lines) {
      final dx = (l.tr.x - l.tl.x).toDouble(), dy = (l.tr.y - l.tl.y).toDouble();
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;
      vx += dx; // = unit vector × length
      vy += dy;
    }
    final a = (vx == 0 && vy == 0) ? 0.0 : math.atan2(vy, vx);
    final cosA = math.cos(-a), sinA = math.sin(-a);
    Offset rot(math.Point<int> p) =>
        Offset(p.x * cosA - p.y * sinA, p.x * sinA + p.y * cosA);
    return [
      for (final l in lines)
        () {
          final pts = [rot(l.tl), rot(l.tr), rot(l.br), rot(l.bl)];
          var left = pts.first.dx, right = left, top = pts.first.dy, bottom = top;
          for (final q in pts) {
            left = math.min(left, q.dx);
            right = math.max(right, q.dx);
            top = math.min(top, q.dy);
            bottom = math.max(bottom, q.dy);
          }
          return (box: Rect.fromLTRB(left, top, right, bottom), text: l.text);
        }(),
    ];
  }

  @visibleForTesting
  static String groupIntoRows(List<({Rect box, String text})> lines) {
    if (lines.isEmpty) return '';
    final sorted = [...lines]
      ..sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));

    final rows = <List<({Rect box, String text})>>[];
    for (final line in sorted) {
      final row = rows.isEmpty ? null : rows.last;
      if (row != null) {
        final ref = row.first.box;
        // Same row when the centres are within half a line height.
        final tolerance =
            (ref.height < line.box.height ? ref.height : line.box.height) / 2;
        if ((line.box.center.dy - ref.center.dy).abs() <= tolerance) {
          row.add(line);
          continue;
        }
      }
      rows.add([line]);
    }

    return rows
        .map((row) => (row..sort((a, b) => a.box.left.compareTo(b.box.left)))
            .map((l) => l.text)
            .join(' '))
        .join('\n');
  }
}
