import 'dart:io';
import 'package:dio/dio.dart';
import '../../../../core/constants/api_constants.dart';
import '../../../../core/errors/exceptions.dart';
import '../../../../core/network/api_client.dart';
import '../models/product_model.dart';

abstract class ProductRemoteDataSource {
  Future<ProductCheckModel> checkBarcode(String barcode);
  Future<List<String>> getCategories();
  Future<UploadResponseModel> uploadProduct({
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
  });
}

class ProductRemoteDataSourceImpl implements ProductRemoteDataSource {
  final ApiClient apiClient;
  ProductRemoteDataSourceImpl(this.apiClient);

  @override
  Future<ProductCheckModel> checkBarcode(String barcode) async {
    try {
      final response = await apiClient.get(
        ApiConstants.checkBarcodeEndpoint(barcode),
      );
      final body = response.data as Map<String, dynamic>;
      return ProductCheckModel.fromJson(body);
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = (body is Map ? body['message'] : null) ??
          e.message ??
          'Barcode check failed';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        throw NetworkException(msg);
      }
      throw ServerException(msg, statusCode: e.response?.statusCode);
    }
  }

  @override
  Future<List<String>> getCategories() async {
    try {
      final response =
          await apiClient.get(ApiConstants.productCategoriesEndpoint);
      final body = response.data as Map<String, dynamic>;
      return ProductCategoriesModel.fromJson(body).categories;
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = (body is Map ? body['message'] : null) ??
          e.message ??
          'Failed to load categories';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        throw NetworkException(msg);
      }
      throw ServerException(msg, statusCode: e.response?.statusCode);
    }
  }

  @override
  Future<UploadResponseModel> uploadProduct({
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
    try {
      // A skipped photo (e.g. no nutrition label) is sent as an empty
      // string, per the backend contract for a missing image field.
      final formData = FormData.fromMap({
        'gtin': barcode,
        'age_group': ageGroup,
        'category': category,
        'front_image': productImage != null
            ? await MultipartFile.fromFile(
                productImage.path,
                filename: 'front_image.jpg',
              )
            : '',
        'ingredients_image': ingredientsImage != null
            ? await MultipartFile.fromFile(
                ingredientsImage.path,
                filename: 'ingredients_image.jpg',
              )
            : '',
        'nutrition_image': nutritionImage != null
            ? await MultipartFile.fromFile(
                nutritionImage.path,
                filename: 'nutrition_image.jpg',
              )
            : '',
        // Extras: sent only when present, so an upload without them is
        // byte-for-byte what the backend received before. `front_image`
        // stays the untouched original.
        if (studioImage != null)
          'studio_image': await MultipartFile.fromFile(
            studioImage.path,
            filename: 'studio_image.jpg',
          ),
        if (studioIngredientsImage != null)
          'studio_ingredients_image': await MultipartFile.fromFile(
            studioIngredientsImage.path,
            filename: 'studio_ingredients_image.jpg',
          ),
        if (studioNutritionImage != null)
          'studio_nutrition_image': await MultipartFile.fromFile(
            studioNutritionImage.path,
            filename: 'studio_nutrition_image.jpg',
          ),
        if (productDetailsJson.isNotEmpty)
          'product_details': productDetailsJson,
      });

      final response = await apiClient.postMultipart(
        ApiConstants.uploadProductEndpoint,
        formData,
      );
      final body = response.data as Map<String, dynamic>;
      if (body['success'] != true) {
        throw ServerException(body['message'] ?? 'Upload failed');
      }
      return UploadResponseModel.fromJson(body);
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = (body is Map ? body['message'] : null) ??
          e.message ??
          'Upload failed';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        throw NetworkException(msg);
      }
      throw ServerException(msg, statusCode: e.response?.statusCode);
    }
  }
}
