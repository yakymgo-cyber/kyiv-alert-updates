package com.example.frontend

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class KyivAlertWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            try {
                updateAppWidget(context, appWidgetManager, appWidgetId)
            } catch (e: Throwable) {
                Log.e(TAG, "Error in onUpdate for widget $appWidgetId", e)
                try {
                    renderFallbackWidget(context, appWidgetManager, appWidgetId)
                } catch (t: Throwable) {
                    Log.e(TAG, "Error rendering fallback widget in onUpdate", t)
                }
            }
        }
    }

    companion object {
        private const val TAG = "KyivAlertWidget"
        private const val PREFS_NAME = "kyiv_alert_widget"
        private const val MAX_BITMAP_WIDTH = 440
        private const val MAX_BITMAP_HEIGHT = 300

        fun updateAllWidgets(context: Context) {
            try {
                val appWidgetManager = AppWidgetManager.getInstance(context) ?: return
                val thisWidget = ComponentName(context, KyivAlertWidgetProvider::class.java)
                val appWidgetIds = appWidgetManager.getAppWidgetIds(thisWidget) ?: return
                for (appWidgetId in appWidgetIds) {
                    try {
                        updateAppWidget(context, appWidgetManager, appWidgetId)
                    } catch (e: Throwable) {
                        Log.e(TAG, "Error updating widget $appWidgetId", e)
                        try {
                            renderFallbackWidget(context, appWidgetManager, appWidgetId)
                        } catch (t: Throwable) {
                            Log.e(TAG, "Error rendering fallback widget in updateAllWidgets", t)
                        }
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error in updateAllWidgets", e)
            }
        }

        fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            try {
                val prefs = try {
                    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                } catch (e: Throwable) {
                    null
                }

                val statusTitle = prefs?.getString("statusTitle", "БЕЗПЕЧНО") ?: "БЕЗПЕЧНО"
                val activeCount = prefs?.getInt("activeCount", 0) ?: 0
                val nearestInfo = prefs?.getString("nearestInfo", "Немає загроз поблизу") ?: "Немає загроз поблизу"
                val lastMsgText = prefs?.getString("lastMsgText", "") ?: ""
                val updatedTime = prefs?.getString("updatedTime", "")?.takeIf { it.isNotBlank() }
                    ?: SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
                val isAlert = prefs?.getBoolean("isAlert", false) ?: false

                val views = RemoteViews(context.packageName, R.layout.kyiv_alert_widget)

                // Setup click intent to launch MainActivity
                val intent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                // Background & Border styling
                if (isAlert) {
                    views.setInt(R.id.widget_root, "setBackgroundResource", R.drawable.widget_bg_alert)
                    views.setTextColor(R.id.widget_status_title, Color.parseColor("#FF5252"))
                } else {
                    views.setInt(R.id.widget_root, "setBackgroundResource", R.drawable.widget_bg_normal)
                    views.setTextColor(R.id.widget_status_title, Color.parseColor("#4CAF50"))
                }

                views.setTextViewText(R.id.widget_status_title, statusTitle)

                // Target Count
                if (activeCount > 0) {
                    views.setTextViewText(R.id.widget_threat_count, "• $activeCount цілей")
                    views.setViewVisibility(R.id.widget_threat_count, View.VISIBLE)
                } else {
                    views.setViewVisibility(R.id.widget_threat_count, View.GONE)
                }

                // Nearest Info & ETA
                views.setTextViewText(R.id.widget_nearest_info, nearestInfo)

                // Last message snippet
                if (lastMsgText.isNotBlank()) {
                    views.setTextViewText(R.id.widget_last_msg, lastMsgText)
                    views.setViewVisibility(R.id.widget_last_msg, View.VISIBLE)
                } else {
                    views.setViewVisibility(R.id.widget_last_msg, View.GONE)
                }

                // Updated timestamp
                views.setTextViewText(R.id.widget_updated_time, updatedTime)

                // Load Radar Snapshot with strict safety & size bounds
                loadRadarBitmap(context, views)

                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (e: Throwable) {
                Log.e(TAG, "Failed updateAppWidget $appWidgetId, falling back", e)
                renderFallbackWidget(context, appWidgetManager, appWidgetId)
            }
        }

        private fun loadRadarBitmap(context: Context, views: RemoteViews) {
            try {
                val imageFile = File(context.filesDir, "radar_snapshot.png")
                if (imageFile.exists() && imageFile.length() > 0) {
                    val options = BitmapFactory.Options().apply {
                        inPreferredConfig = Bitmap.Config.RGB_565
                    }
                    val rawBitmap = BitmapFactory.decodeFile(imageFile.absolutePath, options)
                    if (rawBitmap != null) {
                        // Enforce max dimensions 440x300 px
                        val scaledBitmap = if (rawBitmap.width > MAX_BITMAP_WIDTH || rawBitmap.height > MAX_BITMAP_HEIGHT) {
                            Bitmap.createScaledBitmap(rawBitmap, MAX_BITMAP_WIDTH, MAX_BITMAP_HEIGHT, true)
                        } else {
                            rawBitmap
                        }

                        // Ensure RGB_565 format (< 550 KB) to avoid TransactionTooLargeException
                        val finalBitmap = if (scaledBitmap.config != Bitmap.Config.RGB_565) {
                            try {
                                val rgb565 = Bitmap.createBitmap(scaledBitmap.width, scaledBitmap.height, Bitmap.Config.RGB_565)
                                val canvas = Canvas(rgb565)
                                canvas.drawBitmap(scaledBitmap, 0f, 0f, null)
                                rgb565
                            } catch (t: Throwable) {
                                scaledBitmap
                            }
                        } else {
                            scaledBitmap
                        }

                        views.setImageViewBitmap(R.id.widget_radar_image, finalBitmap)
                        return
                    }
                }

                // Fallback: якщо radar_snapshot.png відсутній або пошкоджений — генеруємо нативний радарний Bitmap 440x300 px
                try {
                    val fallbackBitmap = RadarBitmapRenderer.render(
                        context,
                        emptyList(),
                        emptyList(),
                        false,
                        "БЕЗПЕЧНО",
                        SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
                    )
                    val scaledFallback = if (fallbackBitmap.width > MAX_BITMAP_WIDTH || fallbackBitmap.height > MAX_BITMAP_HEIGHT) {
                        Bitmap.createScaledBitmap(fallbackBitmap, MAX_BITMAP_WIDTH, MAX_BITMAP_HEIGHT, true)
                    } else {
                        fallbackBitmap
                    }
                    val finalFallback = if (scaledFallback.config != Bitmap.Config.RGB_565) {
                        try {
                            val rgb565 = Bitmap.createBitmap(scaledFallback.width, scaledFallback.height, Bitmap.Config.RGB_565)
                            val c = Canvas(rgb565)
                            c.drawBitmap(scaledFallback, 0f, 0f, null)
                            rgb565
                        } catch (t: Throwable) {
                            scaledFallback
                        }
                    } else {
                        scaledFallback
                    }
                    views.setImageViewBitmap(R.id.widget_radar_image, finalFallback)
                    return
                } catch (t: Throwable) {
                    Log.w(TAG, "Fallback RadarBitmapRenderer failed", t)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Error decoding radar snapshot bitmap", t)
            }
            views.setImageViewResource(R.id.widget_radar_image, R.drawable.widget_radar_placeholder)
        }

        fun renderFallbackWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            try {
                val views = RemoteViews(context.packageName, R.layout.kyiv_alert_widget)

                val intent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                // Чистий базовий темний стан віджета (#12101B з фіолетовою рамкою та статусом "🟢 Моніторинг активний")
                views.setInt(R.id.widget_root, "setBackgroundResource", R.drawable.widget_bg_normal)
                views.setTextColor(R.id.widget_status_title, Color.parseColor("#4CAF50"))
                views.setTextViewText(R.id.widget_status_title, "🟢 Моніторинг активний")

                views.setViewVisibility(R.id.widget_threat_count, View.GONE)
                views.setTextViewText(R.id.widget_nearest_info, "Немає загроз поблизу")
                views.setViewVisibility(R.id.widget_last_msg, View.GONE)

                val currentTime = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
                views.setTextViewText(R.id.widget_updated_time, currentTime)

                views.setImageViewResource(R.id.widget_radar_image, R.drawable.widget_radar_placeholder)

                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (t: Throwable) {
                Log.e(TAG, "Critical failure in renderFallbackWidget", t)
            }
        }
    }
}
