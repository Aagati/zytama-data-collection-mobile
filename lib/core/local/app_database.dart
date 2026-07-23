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
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
}

// ── Database ──────────────────────────────────────────────────────────────────

@DriftDatabase(tables: [CachedProducts, PendingUploads])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(pendingUploads, pendingUploads.ageGroup);
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
}

// ── Connection ────────────────────────────────────────────────────────────────

QueryExecutor _openConnection() {
  return driftDatabase(name: 'zytama_local');
}
