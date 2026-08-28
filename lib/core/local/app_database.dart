import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

// ── Tables ────────────────────────────────────────────────────────────────────

class CachedProducts extends Table {
  TextColumn get barcode => text()();
  BoolColumn get found => boolean()();
  TextColumn get productImageUrl => text().nullable()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {barcode};
}

class PendingUploads extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get barcode => text()();
  TextColumn get productImagePath => text()();
  TextColumn get ingredientsImagePath => text()();
  TextColumn get nutritionImagePath => text()();
  // Age group the product is suitable for (e.g. '1-3 years'); empty if unset.
  TextColumn get ageGroup => text().withDefault(const Constant(''))();
  // Product category as chosen from the backend list; empty if unset.
  TextColumn get category => text().withDefault(const Constant(''))();
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
}

/// Last known product-category list from the backend, kept so the review
/// screen can still offer categories while the agent is offline.
class CachedCategories extends Table {
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {name};
}

// ── Database ──────────────────────────────────────────────────────────────────

@DriftDatabase(tables: [CachedProducts, PendingUploads, CachedCategories])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(pendingUploads, pendingUploads.ageGroup);
          }
          if (from < 3) {
            await m.addColumn(pendingUploads, pendingUploads.category);
            await m.createTable(cachedCategories);
          }
        },
      );

  // ── CachedProducts ops ────────────────────────────────────────────────────

  Future<CachedProduct?> getCachedProduct(String barcode) =>
      (select(cachedProducts)..where((t) => t.barcode.equals(barcode)))
          .getSingleOrNull();

  Future<void> upsertCachedProduct(CachedProductsCompanion entry) =>
      into(cachedProducts).insertOnConflictUpdate(entry);

  // ── PendingUploads ops ────────────────────────────────────────────────────

  Future<List<PendingUpload>> getPendingUploads() =>
      (select(pendingUploads)..where((t) => t.isSynced.equals(false))).get();

  Stream<int> watchPendingCount() => (selectOnly(pendingUploads)
        ..addColumns([pendingUploads.id.count()])
        ..where(pendingUploads.isSynced.equals(false)))
      .map((row) => row.read(pendingUploads.id.count()) ?? 0)
      .watchSingle();

  Future<int> insertPendingUpload(PendingUploadsCompanion entry) =>
      into(pendingUploads).insert(entry);

  Future<void> markAsSynced(int id) =>
      (update(pendingUploads)..where((t) => t.id.equals(id)))
          .write(const PendingUploadsCompanion(isSynced: Value(true)));

  Future<void> deletePendingUpload(int id) =>
      (delete(pendingUploads)..where((t) => t.id.equals(id))).go();

  Future<void> deleteAllSyncedUploads() =>
      (delete(pendingUploads)..where((t) => t.isSynced.equals(true))).go();

  // ── CachedCategories ops ──────────────────────────────────────────────────

  /// Cached categories in the order the backend returned them.
  Future<List<String>> getCachedCategories() async {
    final rows = await (select(cachedCategories)
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
    return rows.map((r) => r.name).toList(growable: false);
  }

  /// Replaces the cached list wholesale so categories removed upstream do
  /// not linger on the device.
  Future<void> replaceCachedCategories(List<String> names) =>
      transaction(() async {
        await delete(cachedCategories).go();
        final now = DateTime.now();
        await batch((b) => b.insertAll(
              cachedCategories,
              [
                for (final (index, name) in names.indexed)
                  CachedCategoriesCompanion.insert(
                    name: name,
                    sortOrder: index,
                    cachedAt: now,
                  ),
              ],
            ));
      });
}

// ── Connection ────────────────────────────────────────────────────────────────

QueryExecutor _openConnection() {
  return driftDatabase(name: 'zytama_local');
}
