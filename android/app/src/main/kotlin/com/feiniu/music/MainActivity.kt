package com.feiniu.music

import android.content.ContentValues
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Environment
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.proify.lyricon.lyric.model.LyricWord
import io.github.proify.lyricon.lyric.model.RichLyricLine
import io.github.proify.lyricon.lyric.model.Song
import io.github.proify.lyricon.provider.LyriconFactory
import io.github.proify.lyricon.provider.LyriconProvider
import com.feiniu.music.R

class MainActivity : AudioServiceActivity() {
    private val channelName = "com.feiniu.music/meizu_lyrics"
    private val lyriconChannelName = "com.feiniu.music/lyricon"
    private val downloadsChannelName = "com.feiniu.music/downloads"
    private val artworkChannelName = "com.feiniu.music/native_artwork"
    private val tvChannelName = "com.feiniu.music/tv"
    private val notificationId = 10010
    private val notificationChannelId = "meizu_lyric_channel"
    private var flagShowTicker: Int? = null
    private var flagUpdateTicker: Int? = null
    private var lyriconProvider: LyriconProvider? = null
    private var lyriconEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkSupport" -> {
                    result.success(checkSupport())
                }
                "updateLyric" -> {
                    val text = call.argument<String>("text") ?: ""
                    updateLyric(text)
                    result.success(null)
                }
                "stopLyric" -> {
                    stopLyric()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            lyriconChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setServiceEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setLyriconEnabled(enabled)
                    result.success(null)
                }
                "setPlaybackState" -> {
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    setLyriconPlaybackState(isPlaying)
                    result.success(null)
                }
                "setSong" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        setLyriconSong(args)
                    }
                    result.success(null)
                }
                "updatePosition" -> {
                    val position = call.argument<Int>("position") ?: 0
                    updateLyriconPosition(position.toLong())
                    result.success(null)
                }
                "setDisplayTranslation" -> {
                    val display = call.argument<Boolean>("display") ?: false
                    setLyriconDisplayTranslation(display)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadsChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidSdkInt" -> {
                    result.success(Build.VERSION.SDK_INT)
                }
                "saveToDownloads" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val fileName = call.argument<String>("fileName")
                    val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"
                    val subdirectory = call.argument<String>("subdirectory") ?: "FeiNiuMusic"
                    val overwrite = call.argument<Boolean>("overwrite") ?: false
                    if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                        result.error("invalid_args", "缺少文件信息", null)
                    } else {
                        try {
                            val savedPath = saveToDownloads(
                                sourcePath = sourcePath,
                                fileName = fileName,
                                mimeType = mimeType,
                                subdirectory = subdirectory,
                                overwrite = overwrite
                            )
                            result.success(savedPath)
                        } catch (t: Throwable) {
                            result.error("save_failed", t.message ?: "保存失败", null)
                        }
                    }
                }
                "existsInDownloads" -> {
                    val fileName = call.argument<String>("fileName")
                    val subdirectory = call.argument<String>("subdirectory") ?: "FeiNiuMusic"
                    if (fileName.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        try {
                            result.success(downloadFileExists(fileName, subdirectory))
                        } catch (t: Throwable) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            artworkChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "loadAudioThumbnail" -> {
                    val path = call.argument<String>("path")
                    val size = call.argument<Int>("size") ?: 320
                    if (path.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        try {
                            result.success(loadAudioThumbnail(path, size))
                        } catch (t: Throwable) {
                            result.error("thumbnail_failed", t.message ?: "读取缩略图失败", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            tvChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTvDevice" -> result.success(isTvDevice())
                else -> result.notImplemented()
            }
        }
    }

    /** 是否为 Android TV 设备：uiMode 类型为 TELEVISION，或设备声明 LEANBACK 特性。 */
    private fun isTvDevice(): Boolean {
        val uiMode = resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_TYPE_MASK
        return uiMode == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK)
    }

    private fun loadAudioThumbnail(path: String, size: Int): ByteArray? {
        val uri = findAudioUri(path) ?: return null
        val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            applicationContext.contentResolver.loadThumbnail(uri, android.util.Size(size, size), null)
        } else {
            MediaStore.Images.Thumbnails.getThumbnail(
                applicationContext.contentResolver,
                uri.lastPathSegment?.toLongOrNull() ?: return null,
                MediaStore.Images.Thumbnails.MINI_KIND,
                null
            )
        } ?: return null
        return java.io.ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 86, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }

    private fun findAudioUri(path: String): Uri? {
        val normalizedPath = java.io.File(path).absolutePath
        val projection = arrayOf(MediaStore.Audio.Media._ID)
        val selection = "${MediaStore.Audio.Media.DATA}=?"
        val selectionArgs = arrayOf(normalizedPath)
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        applicationContext.contentResolver.query(
            collection,
            projection,
            selection,
            selectionArgs,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                return Uri.withAppendedPath(collection, id.toString())
            }
        }
        return null
    }

    private fun saveToDownloads(
        sourcePath: String,
        fileName: String,
        mimeType: String,
        subdirectory: String,
        overwrite: Boolean
    ): String {
        val sourceFile = java.io.File(sourcePath)
        require(sourceFile.exists()) { "源文件不存在" }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveToDownloadsWithMediaStore(sourceFile, fileName, mimeType, subdirectory, overwrite)
        } else {
            saveToDownloadsLegacy(sourceFile, fileName, subdirectory, overwrite)
        }
    }

    private fun downloadFileExists(fileName: String, subdirectory: String): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val relativePath = Environment.DIRECTORY_DOWNLOADS + "/" + subdirectory
            resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.RELATIVE_PATH}=? AND ${MediaStore.Downloads.DISPLAY_NAME}=?",
                arrayOf("$relativePath/", fileName),
                null
            )?.use { it.moveToFirst() } == true
        } else {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            java.io.File(java.io.File(downloadsDir, subdirectory), fileName).exists()
        }
    }

    private fun deleteExistingDownload(fileName: String, relativePath: String) {
        try {
            applicationContext.contentResolver.delete(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                "${MediaStore.Downloads.RELATIVE_PATH}=? AND ${MediaStore.Downloads.DISPLAY_NAME}=?",
                arrayOf("$relativePath/", fileName)
            )
        } catch (_: Throwable) {
        }
    }

    private fun saveToDownloadsWithMediaStore(
        sourceFile: java.io.File,
        fileName: String,
        mimeType: String,
        subdirectory: String,
        overwrite: Boolean
    ): String {
        val resolver = applicationContext.contentResolver
        val relativePath = Environment.DIRECTORY_DOWNLOADS + "/" + subdirectory
        val actualName: String
        if (overwrite) {
            deleteExistingDownload(fileName, relativePath)
            actualName = fileName
        } else {
            actualName = nextAvailableDisplayName(fileName, relativePath)
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, actualName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("无法创建下载文件")

        resolver.openOutputStream(uri)?.use { output ->
            sourceFile.inputStream().use { input ->
                input.copyTo(output)
            }
        } ?: error("无法写入下载文件")

        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri.toString()
    }

    private fun saveToDownloadsLegacy(
        sourceFile: java.io.File,
        fileName: String,
        subdirectory: String,
        overwrite: Boolean
    ): String {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        val targetDir = java.io.File(downloadsDir, subdirectory)
        if (!targetDir.exists()) {
            targetDir.mkdirs()
        }
        val targetFile = if (overwrite) {
            java.io.File(targetDir, fileName)
        } else {
            nextAvailableFile(targetDir, fileName)
        }
        sourceFile.copyTo(targetFile, overwrite = overwrite)
        return targetFile.absolutePath
    }

    private fun nextAvailableDisplayName(fileName: String, relativePath: String): String {
        val resolver = applicationContext.contentResolver
        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var candidate = fileName
        var index = 1
        while (true) {
            val cursor = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.RELATIVE_PATH}=? AND ${MediaStore.Downloads.DISPLAY_NAME}=?",
                arrayOf("$relativePath/", candidate),
                null
            )
            val exists = cursor?.use { it.moveToFirst() } == true
            if (!exists) return candidate
            candidate = "$base ($index)$ext"
            index += 1
        }
    }

    private fun nextAvailableFile(dir: java.io.File, fileName: String): java.io.File {
        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var candidate = java.io.File(dir, fileName)
        var index = 1
        while (candidate.exists()) {
            candidate = java.io.File(dir, "$base ($index)$ext")
            index += 1
        }
        return candidate
    }

    private fun setLyriconEnabled(enabled: Boolean) {
        lyriconEnabled = enabled
        val provider = ensureLyriconProvider() ?: return
        if (enabled) {
            provider.register()
        } else {
            provider.unregister()
        }
    }

    private fun setLyriconPlaybackState(isPlaying: Boolean) {
        if (!lyriconEnabled) return
        lyriconProvider?.player?.setPlaybackState(isPlaying)
    }

    private fun setLyriconDisplayTranslation(display: Boolean) {
        if (!lyriconEnabled) return
        lyriconProvider?.player?.setDisplayTranslation(display)
    }

    private fun updateLyriconPosition(position: Long) {
        if (!lyriconEnabled) return
        lyriconProvider?.player?.setPosition(position)
    }

    private fun setLyriconSong(args: Map<*, *>) {
        if (!lyriconEnabled) return
        val lyrics = (args["lyrics"] as? List<*>)?.mapNotNull { item ->
            val lineMap = item as? Map<*, *> ?: return@mapNotNull null
            val begin = toLong(lineMap["begin"])
            val end = toLong(lineMap["end"])
            val words = (lineMap["words"] as? List<*>)?.mapNotNull { wordItem ->
                val wordMap = wordItem as? Map<*, *> ?: return@mapNotNull null
                LyricWord(
                    begin = toLong(wordMap["begin"]),
                    end = toLong(wordMap["end"]),
                    text = wordMap["text"] as? String
                )
            }
            RichLyricLine(
                begin = begin,
                end = end,
                text = lineMap["text"] as? String,
                translation = lineMap["translation"] as? String,
                words = words
            )
        } ?: emptyList()
        val song = Song(
            id = args["id"]?.toString(),
            name = args["name"] as? String,
            artist = args["artist"] as? String,
            duration = toLong(args["duration"]),
            lyrics = lyrics
        )
        lyriconProvider?.player?.setSong(song)
    }

    private fun ensureLyriconProvider(): LyriconProvider? {
        if (lyriconProvider == null) {
            lyriconProvider = LyriconFactory.createProvider(this)
        }
        return lyriconProvider
    }

    private fun toLong(value: Any?): Long {
        return when (value) {
            is Long -> value
            is Int -> value.toLong()
            is Double -> value.toLong()
            is Float -> value.toLong()
            is String -> value.toLongOrNull() ?: 0L
            else -> 0L
        }
    }

    private fun checkSupport(): Boolean {
        val show = ensureTickerFlags()
        val update = flagUpdateTicker ?: 0
        return show > 0 && update > 0
    }

    private fun ensureTickerFlags(): Int {
        if (flagShowTicker != null && flagUpdateTicker != null) {
            return flagShowTicker ?: 0
        }
        return try {
            val cls = Class.forName("android.app.Notification")
            val showField = cls.getDeclaredField("FLAG_ALWAYS_SHOW_TICKER")
            val updateField = cls.getDeclaredField("FLAG_ONLY_UPDATE_TICKER")
            flagShowTicker = showField.getInt(null)
            flagUpdateTicker = updateField.getInt(null)
            flagShowTicker ?: 0
        } catch (_: Throwable) {
            flagShowTicker = 0
            flagUpdateTicker = 0
            0
        }
    }

    private fun updateLyric(text: String) {
        if (text.isBlank()) return
        if (!checkSupport()) return
        ensureNotificationChannel()
        val builder = NotificationCompat.Builder(this, notificationChannelId)
            .setPriority(Notification.PRIORITY_MAX)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("歌词")
            .setContentText(text)

        builder.setTicker(text)
        val notification = builder.build()
        notification.flags = notification.flags or Notification.FLAG_NO_CLEAR
        val showFlag = flagShowTicker ?: 0
        val updateFlag = flagUpdateTicker ?: 0
        if (showFlag > 0) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                notification.extras.putBoolean("ticker_icon_switch", false)
                notification.extras.putInt("ticker_icon", R.mipmap.ic_launcher)
            }
            notification.flags = notification.flags or showFlag
            notification.flags = notification.flags or updateFlag
        }
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(notificationId, notification)
    }

    private fun stopLyric() {
        if (!checkSupport()) return
        ensureNotificationChannel()
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(notificationId)
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(notificationChannelId) != null) return
        val channel = NotificationChannel(
            notificationChannelId,
            "Lyric",
            NotificationManager.IMPORTANCE_HIGH
        )
        manager.createNotificationChannel(channel)
    }
}
