import 'package:flutter/services.dart';

/// 把 GIF 保存到系统相册。
/// - Android 10+ (API29+)：走 MediaStore，无需权限
/// - Android 9 及以下：需要 WRITE_EXTERNAL_STORAGE 权限（由 Dart 侧申请）
class GifSaver {
  static const MethodChannel _channel =
      MethodChannel('com.example.video_to_gif/saver');

  static Future<String> saveToGallery({
    required String srcPath,
    required String displayName,
  }) async {
    final result = await _channel.invokeMethod<String>('saveGifToGallery', {
      'srcPath': srcPath,
      'displayName': displayName,
    });
    if (result == null) {
      throw Exception('平台未返回保存结果');
    }
    return result;
  }
}