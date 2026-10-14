package com.example.frontend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import java.io.File

object LockScreenRadarNotification {

    const val CHANNEL_ID = "kyiv_alert_radar_lockscreen"
    const val CHANNEL_NAME = "Kyiv Alert Radar"
    const val NOTIFICATION_ID = 2024

    fun buildNotification(context: Context): Notification? {
        val prefs = context.getSharedPreferences("kyiv_alert_widget", Context.MODE_PRIVATE)
        val isAlert = prefs.getBoolean("isAlert", false)
        if (!isAlert) return null

        val statusTitle = prefs.getString("statusTitle", "ПОВІТРЯНА ТРИВОГА") ?: "ПОВІТРЯНА ТРИВОГА"
        val activeCount = prefs.getInt("activeCount", 0)
        val nearestInfo = prefs.getString("nearestInfo", "Загроза в повітряному просторі") ?: "Загроза в повітряному просторі"
        val lastMsgText = prefs.getString("lastMsgText", "") ?: ""
        val updatedTime = prefs.getString("updatedTime", "--:--") ?: "--:--"

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createChannelIfNeeded(notificationManager)

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = if (activeCount > 0) {
            "🚨 $statusTitle • $activeCount цілей ($updatedTime)"
        } else {
            "🚨 $statusTitle ($updatedTime)"
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(nearestInfo)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_STATUS)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        // Load native canvas radar snapshot
        val imageFile = File(context.filesDir, "radar_snapshot.png")
        if (imageFile.exists() && imageFile.length() > 0) {
            try {
                val bitmap = BitmapFactory.decodeFile(imageFile.absolutePath)
                if (bitmap != null) {
                    val summary = if (lastMsgText.isNotBlank()) "$nearestInfo\n$lastMsgText" else nearestInfo
                    val style = Notification.BigPictureStyle()
                        .bigPicture(bitmap)
                        .setSummaryText(summary)
                    builder.setStyle(style)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        return builder.build()
    }

    fun update(context: Context) {
        val prefs = context.getSharedPreferences("kyiv_alert_widget", Context.MODE_PRIVATE)
        val isAlert = prefs.getBoolean("isAlert", false)

        if (isAlert) {
            // Запускаємо або оновлюємо Foreground Service для захисту від вивантаження на One UI / HyperOS
            RadarForegroundService.start(context)
            val notification = buildNotification(context)
            if (notification != null) {
                val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                createChannelIfNeeded(notificationManager)
                notificationManager.notify(NOTIFICATION_ID, notification)
            }
        } else {
            // Зупиняємо Foreground Service та знімаємо сповіщення
            RadarForegroundService.stop(context)
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NOTIFICATION_ID)
        }
    }

    fun createChannelIfNeeded(notificationManager: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = notificationManager.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Живий тактичний радар для екрана блокування під час тривоги"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    enableLights(true)
                    enableVibration(false)
                }
                notificationManager.createNotificationChannel(channel)
            }
        }
    }
}
