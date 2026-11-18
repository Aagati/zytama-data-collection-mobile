import 'dart:io';
import 'package:dartz/dartz.dart';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../../../core/errors/exceptions.dart';
import '../../../../core/errors/failures.dart';
import '../../domain/repositories/product_repository.dart';
import '../datasources/product_remote_datasource.dart';
import '../../../../core/local/app_database.dart';
import '../../../../core/network/connectivity_service.dart';

class ProductRepositoryImpl implements ProductRepository {
  final ProductRemoteDataSource remoteDataSource;
  final AppDatabase db;
  final ConnectivityService connectivity;

  ProductRepositoryImpl(this.remoteDataSource, this.db, this.connectivity);

  @override
  Future<Either<Failure, ({bool found, String? message, String? productImageUrl})>>
      checkBarcodeExists(String barcode) async {
    if (connectivity.isOnline) {
      try {
        final result = await remoteDataSource.checkBarcode(barcode);
        return Right((
          found: result.found,
          message: result.message,
          productImageUrl: result.productImageUrl,
        ));
      } on NetworkException {
        return _checkBarcodeOffline(barcode);
      } on ServerException catch (e) {
        return Left(ServerFailure(e.message));
      }
    } else {
      return _checkBarcodeOffline(barcode);
    }
  }

  Future<Either<Failure, ({bool found, String? message, String? productImageUrl})>>
      _checkBarcodeOffline(String barcode) async {
    final cached = await db.getCachedProduct(barcode);
    if (cached != null) {
      return Right((
        found: cached.found,
        message: cached.found ? 'Product found in local cache.' : null,
        productImageUrl: cached.productImageUrl,
      ));
    }
    return const Right((found: false, message: null, productImageUrl: null));
  }

  @override
  Future<Either<Failure, List<String>>> getCategories() async {
    if (connectivity.isOnline) {
      try {
        final categories = await remoteDataSource.getCategories();
        if (categories.isNotEmpty) {
          await db.replaceCachedCategories(categories);
        }
        return Right(categories);
      } on NetworkException catch (e) {
        return _categoriesFromCache(e.message);
      } on ServerException catch (e) {
        return _categoriesFromCache(e.message);
      }
    }
    return _categoriesFromCache('No internet connection');
  }

  /// Falls back to the last synced category list so the review screen stays
  /// usable offline; only reports a failure when nothing was ever cached.
  Future<Either<Failure, List<String>>> _categoriesFromCache(
    String failureMessage,
  ) async {
    final cached = await db.getCachedCategories();
    if (cached.isNotEmpty) return Right(cached);
    return Left(NetworkFailure(failureMessage));
  }

  @override
  Future<Either<Failure, String>> uploadProduct({
    required String barcode,
    required File? productImage,
    required File? ingredientsImage,
    required File? nutritionImage,
    required String ageGroup,
    required String category,
    File? studioImage,
    File? studioIngredientsImage,
    File? studioNutritionImage,
    String productDetailsJson = '',
  }) async {
    if (connectivity.isOnline) {
      try {
        final result = await remoteDataSource.uploadProduct(
          barcode: barcode,
          productImage: productImage,
          ingredientsImage: ingredientsImage,
          nutritionImage: nutritionImage,
          ageGroup: ageGroup,
          category: category,
          studioImage: studioImage,
          studioIngredientsImage: studioIngredientsImage,
          studioNutritionImage: studioNutritionImage,
          productDetailsJson: productDetailsJson,
        );
        return Right(result.message);
      } on NetworkException {
        return _saveUploadOffline(
          barcode: barcode,
          productImage: productImage,
          ingredientsImage: ingredientsImage,
          nutritionImage: nutritionImage,
          ageGroup: ageGroup,
          category: category,
          studioImage: studioImage,
          studioIngredientsImage: studioIngredientsImage,
          studioNutritionImage: studioNutritionImage,
          productDetailsJson: productDetailsJson,
        );
      } on ServerException catch (e) {
        return Left(ServerFailure(e.message));
      }
    } else {
      return _saveUploadOffline(
        barcode: barcode,
        productImage: productImage,
        ingredientsImage: ingredientsImage,
        nutritionImage: nutritionImage,
        ageGroup: ageGroup,
        category: category,
        studioImage: studioImage,
        studioIngredientsImage: studioIngredientsImage,
        studioNutritionImage: studioNutritionImage,
        productDetailsJson: productDetailsJson,
      );
    }
  }

  Future<Either<Failure, String>> _saveUploadOffline({
    required String barcode,
    required File? productImage,
    required File? ingredientsImage,
    required File? nutritionImage,
    required String ageGroup,
    required String category,
    File? studioImage,
    File? studioIngredientsImage,
    File? studioNutritionImage,
    String productDetailsJson = '',
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final offlineDir =
        Directory(p.join(dir.path, 'offline_uploads', barcode));
    await offlineDir.create(recursive: true);

    // A skipped photo (e.g. no nutrition label) is stored as an empty path,
    // matching the backend convention of an empty string for a missing image.
    final savedProduct = productImage != null
        ? (await productImage.copy(p.join(offlineDir.path, 'product.jpg'))).path
        : '';
    final savedIngredients = ingredientsImage != null
        ? (await ingredientsImage.copy(p.join(offlineDir.path, 'ingredients.jpg'))).path
        : '';
    final savedNutrition = nutritionImage != null
        ? (await nutritionImage.copy(p.join(offlineDir.path, 'nutrition.jpg'))).path
        : '';
    Future<String> keep(File? f, String name) async =>
        f == null ? '' : (await f.copy(p.join(offlineDir.path, name))).path;
    final savedStudio = await keep(studioImage, 'studio.jpg');
    final savedStudioIngredients =
        await keep(studioIngredientsImage, 'studio_ingredients.jpg');
    final savedStudioNutrition =
        await keep(studioNutritionImage, 'studio_nutrition.jpg');

    await db.insertPendingUpload(PendingUploadsCompanion(
      barcode: Value(barcode),
      productImagePath: Value(savedProduct),
      ingredientsImagePath: Value(savedIngredients),
      nutritionImagePath: Value(savedNutrition),
      ageGroup: Value(ageGroup),
      category: Value(category),
      studioImagePath: Value(savedStudio),
      studioIngredientsImagePath: Value(savedStudioIngredients),
      studioNutritionImagePath: Value(savedStudioNutrition),
      productDetailsJson: Value(productDetailsJson),
      createdAt: Value(DateTime.now()),
    ));

    return const Right('__offline__');
  }
}
