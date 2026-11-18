import 'dart:io';
import 'package:dartz/dartz.dart';
import '../../../../core/errors/failures.dart';
import '../entities/product_details.dart';
import '../repositories/product_repository.dart';

class UploadProductUseCase {
  final ProductRepository repository;
  UploadProductUseCase(this.repository);

  Future<Either<Failure, String>> call({
    required String barcode,
    required File? productImage,
    required File? ingredientsImage,
    required File? nutritionImage,
    required String ageGroup,
    required String category,
    File? studioImage,
    File? studioIngredientsImage,
    File? studioNutritionImage,
    ProductDetails productDetails = ProductDetails.empty,
  }) =>
      repository.uploadProduct(
        barcode: barcode,
        productImage: productImage,
        ingredientsImage: ingredientsImage,
        nutritionImage: nutritionImage,
        ageGroup: ageGroup,
        category: category,
        studioImage: studioImage,
        studioIngredientsImage: studioIngredientsImage,
        studioNutritionImage: studioNutritionImage,
        productDetailsJson:
            productDetails.isEmpty ? '' : productDetails.encode(),
      );
}
