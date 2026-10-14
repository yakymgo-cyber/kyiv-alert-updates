package com.example.frontend

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ua.kyiv.alert.monitor/widget"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensurePermissions()
    }

    private fun ensurePermissions() {
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    try {
                        val statusTitle = call.argument<String>("statusTitle") ?: "БЕЗПЕЧНО"
                        val activeCount = call.argument<Int>("activeCount") ?: 0
                        val nearestInfo = call.argument<String>("nearestInfo") ?: ""
                        val lastMsgText = call.argument<String>("lastMsgText") ?: ""
                        val updatedTime = call.argument<String>("updatedTime") ?: ""
                        val isAlert = call.argument<Boolean>("isAlert") ?: false
                        val radarPng = call.argument<ByteArray>("radarPng")

                        @Suppress("UNCHECKED_CAST")
                        val threats = call.argument<List<Map<String, Any?>>>("threats") ?: emptyList()
                        @Suppress("UNCHECKED_CAST")
                        val watchedLocations = call.argument<List<Map<String, Any?>>>("watchedLocations") ?: emptyList()

                        val prefs = getSharedPreferences("kyiv_alert_widget", Context.MODE_PRIVATE)
                        prefs.edit()
                            .putString("statusTitle", statusTitle)
                            .putInt("activeCount", activeCount)
                            .putString("nearestInfo", nearestInfo)
                            .putString("lastMsgText", lastMsgText)
                            .putString("updatedTime", updatedTime)
                            .putBoolean("isAlert", isAlert)
                            .apply()

                        // Якщо екран активний і Flutter надіслав готовий скріншот карти — зберігаємо його.
                        // Якщо ж екран вимкнений / спить — рендеримо нативний Canvas через RadarBitmapRenderer.
                        if (radarPng != null && radarPng.isNotEmpty()) {
                            try {
                                val file = File(filesDir, "radar_snapshot.png")
                                val rawBitmap = BitmapFactory.decodeByteArray(radarPng, 0, radarPng.size)
                                if (rawBitmap != null) {
                                    val scaledBitmap = if (rawBitmap.width > 440 || rawBitmap.height > 300) {
                                        Bitmap.createScaledBitmap(rawBitmap, 440, 300, true)
                                    } else {
                                        rawBitmap
                                    }
                                    FileOutputStream(file).use { fos ->
                                        scaledBitmap.compress(Bitmap.CompressFormat.PNG, 90, fos)
                                        fos.flush()
                                    }
                                } else {
                                    FileOutputStream(file).use { fos ->
                                        fos.write(radarPng)
                                        fos.flush()
                                    }
                                }
                            } catch (e: Throwable) {
                                e.printStackTrace()
                            }
                        } else {
                            try {
                                RadarBitmapRenderer.render(
                                    applicationContext,
                                    threats,
                                    watchedLocations,
                                    isAlert,
                                    statusTitle,
                                    updatedTime
                                )
                            } catch (e: Throwable) {
                                e.printStackTrace()
                            }
                        }

                        // Оновлення віджетів на робочому столі
                        KyivAlertWidgetProvider.updateAllWidgets(applicationContext)

                        // Оновлення або запуск Foreground Service зі сповіщенням на Lock Screen
                        LockScreenRadarNotification.update(applicationContext)

                        result.success(true)
                    } catch (e: Exception) {
                        e.printStackTrace()
                        result.error("UPDATE_ERROR", e.message, null)
                    }
                }
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                            try {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(intent)
                                result.success(true)
                                return@setMethodCallHandler
                            } catch (e: Exception) {
                                e.printStackTrace()
                            }
                        }
                    }
                    result.success(false)
                }
                "isIgnoringBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    } else {
                        result.success(true)
                    }
                }
                "installApk" -> {
                    try {
                        val filePath = call.argument<String>("filePath")
                        if (filePath != null) {
                            val file = File(filePath)
                            if (file.exists()) {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    if (!packageManager.canRequestPackageInstalls()) {
                                        try {
                                            val manageIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                                data = Uri.parse("package:$packageName")
                                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                            }
                                            startActivity(manageIntent)
                                        } catch (se: Exception) {
                                            se.printStackTrace()
                                        }
                                        result.error("PERMISSION_REQUIRED", "Потрібно дозволити 'Встановлювати невідомі додатки'", null)
                                        return@setMethodCallHandler
                                    }
                                }
                                val apkUri = androidx.core.content.FileProvider.getUriForFile(
                                    applicationContext,
                                    "${applicationContext.packageName}.fileprovider",
                                    file
                                )
                                val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(apkUri, "application/vnd.android.package-archive")
                                    flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(installIntent)
                                result.success(true)
                            } else {
                                result.error("FILE_NOT_FOUND", "APK file not found at $filePath", null)
                            }
                        } else {
                            result.error("INVALID_ARGUMENT", "File path is null", null)
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                "canRequestPackageInstalls" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        result.success(packageManager.canRequestPackageInstalls())
                    } else {
                        result.success(true)
                    }
                }
                "openUnknownAppSourcesSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "getCacheDir" -> {
                    result.success(cacheDir.absolutePath)
                }
                "getFilesDir" -> {
                    result.success(filesDir.absolutePath)
                }
                "ensureAndroidPermissions" -> {
                    ensurePermissions()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
