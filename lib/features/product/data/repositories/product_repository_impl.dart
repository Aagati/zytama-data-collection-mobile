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
  Future<Either<Failure, String>> uploadProduct({
    required String barcode,
    required File? productImage,
    required File? ingredientsImage,
    required File? nutritionImage,
    required String ageGroup,
  }) async {
    if (connectivity.isOnline) {
      try {
        final result = await remoteDataSource.uploadProduct(
          barcode: barcode,
          productImage: productImage,
          ingredientsImage: ingredientsImage,
          nutritionImage: nutritionImage,
          ageGroup: ageGroup,
        );
        return Right(result.message);
      } on NetworkException {
        return _saveUploadOffline(
          barcode: barcode,
          productImage: productImage,
          ingredientsImage: ingredientsImage,
          nutritionImage: nutritionImage,
          ageGroup: ageGroup,
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
      );
    }
  }

  Future<Either<Failure, String>> _saveUploadOffline({
    required String barcode,
    required File? productImage,
    required File? ingredientsImage,
    required File? nutritionImage,
    required String ageGroup,
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

    await db.insertPendingUpload(PendingUploadsCompanion(
      barcode: Value(barcode),
      productImagePath: Value(savedProduct),
      ingredientsImagePath: Value(savedIngredients),
      nutritionImagePath: Value(savedNutrition),
      ageGroup: Value(ageGroup),
      createdAt: Value(DateTime.now()),
    ));

    return const Right('__offline__');
  }
}
