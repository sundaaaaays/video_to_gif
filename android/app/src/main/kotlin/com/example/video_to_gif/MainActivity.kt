package com.example.video_to_gif

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "com.example.video_to_gif/saver"
    private val pickChannelName = "com.example.video_to_gif/picker"
    private val pickVideoRequestCode = 1001
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ========== 通道1：保存 GIF 到相册 ==========
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveGifToGallery" -> {
                        val srcPath = call.argument<String>("srcPath") ?: ""
                        val displayName = call.argument<String>("displayName")
                            ?: "video_to_gif_${System.currentTimeMillis()}.gif"
                        try {
                            result.success(saveGifToGallery(srcPath, displayName))
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ========== 通道2：选视频（系统 Intent，不依赖任何第三方插件）==========
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pickChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickVideo" -> {
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                            type = "video/*"
                            addCategory(Intent.CATEGORY_OPENABLE)
                        }
                        startActivityForResult(intent, pickVideoRequestCode)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickVideoRequestCode) {
            val result = pendingPickResult
            pendingPickResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                result?.success(copyToCache(data.data!!))
            } else {
                result?.success(null) // 用户取消
            }
        }
    }

    /** 把选中的视频拷贝到应用缓存目录，返回可被 ffmpeg 直接读取的绝对路径 */
    private fun copyToCache(uri: Uri): String? {
        return try {
            val name = queryDisplayName(uri)
                ?: "picked_video_${System.currentTimeMillis()}"
            val outFile = File(cacheDir, name)
            contentResolver.openInputStream(uri)?.use { input ->
                outFile.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            outFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun saveGifToGallery(srcPath: String, displayName: String): String {
        val src = File(srcPath)
        if (!src.exists()) throw IllegalStateException("源文件不存在: $srcPath")
        val mimeType = "image/gif"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/GIFTools"
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val collection =
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = contentResolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore 插入失败")
            contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { it.copyTo(out) }
            } ?: throw IllegalStateException("无法打开输出流")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } else {
            if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED
            ) {
                throw IllegalStateException("缺少写存储权限，请授权后再试")
            }
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                "GIFTools"
            )
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, displayName)
            src.copyTo(dest, overwrite = true)
            MediaScannerConnection.scanFile(
                this, arrayOf(dest.absolutePath), arrayOf(mimeType), null
            )
            return dest.absolutePath
        }
    }
}