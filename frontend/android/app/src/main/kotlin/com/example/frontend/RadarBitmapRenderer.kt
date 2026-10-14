package com.example.frontend

import android.content.Context
import android.graphics.*
import java.io.File
import java.io.FileOutputStream
import kotlin.math.*

object RadarBitmapRenderer {

    private const val WIDTH = 800
    private const val HEIGHT = 420
    private const val CENTER_LAT = 50.4501
    private const val CENTER_LON = 30.5234

    // 1 deg lat ~ 111,139 meters. Aspect scale for 50.45 deg latitude
    private const val SCALE_Y = HEIGHT / 1.75f
    private val COS_LAT = cos(Math.toRadians(CENTER_LAT)).toFloat()
    private val SCALE_X = SCALE_Y / COS_LAT

    private fun project(lat: Double, lon: Double): Pair<Float, Float> {
        val px = (WIDTH / 2f) + ((lon - CENTER_LON) * SCALE_X).toFloat()
        val py = (HEIGHT / 2f) - ((lat - CENTER_LAT) * SCALE_Y).toFloat()
        return Pair(px, py)
    }

    private fun metersToPx(meters: Double): Float {
        return (meters / 111139.0 * SCALE_Y).toFloat()
    }

    fun render(
        context: Context,
        threats: List<Map<String, Any?>>,
        watchedLocations: List<Map<String, Any?>>,
        isAlert: Boolean,
        statusTitle: String,
        updatedTime: String
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // 1. Dark tactical radar background
        canvas.drawColor(Color.parseColor("#0C0E14"))

        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        // Subtle background grid lines (every 60 px)
        paint.color = Color.parseColor("#141724")
        paint.strokeWidth = 1f
        paint.style = Paint.Style.STROKE
        for (x in 0..WIDTH step 60) {
            canvas.drawLine(x.toFloat(), 0f, x.toFloat(), HEIGHT.toFloat(), paint)
        }
        for (y in 0..HEIGHT step 60) {
            canvas.drawLine(0f, y.toFloat(), WIDTH.toFloat(), y.toFloat(), paint)
        }

        // Center crosshairs through Kyiv
        val (kX, kY) = project(CENTER_LAT, CENTER_LON)
        paint.color = Color.parseColor("#1F2538")
        paint.strokeWidth = 1.5f
        canvas.drawLine(kX, 0f, kX, HEIGHT.toFloat(), paint)
        canvas.drawLine(0f, kY, WIDTH.toFloat(), kY, paint)

        // 2. Concentric radar distance rings
        val ringsMeters = listOf(15000.0, 35000.0, 65000.0, 95000.0)
        val ringLabels = listOf("15 км", "35 км", "65 км", "95 км")
        paint.color = Color.parseColor("#262E45")
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.5f
        paint.pathEffect = DashPathEffect(floatArrayOf(6f, 6f), 0f)

        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#485375")
            textSize = 12f
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
        }

        for (i in ringsMeters.indices) {
            val rPx = metersToPx(ringsMeters[i])
            canvas.drawCircle(kX, kY, rPx, paint)
            canvas.drawText(ringLabels[i], kX + rPx + 4f, kY - 4f, textPaint)
        }
        paint.pathEffect = null // reset dash

        // 3. Reference cities & towns in Kyiv Oblast
        val keyTowns = listOf(
            Triple(50.5113, 30.7903, "Бровари"),
            Triple(50.3522, 30.9547, "Бориспіль"),
            Triple(50.1778, 30.3178, "Васильків"),
            Triple(49.7989, 30.1153, "Біла Церква"),
            Triple(50.5186, 30.2394, "Ірпінь"),
            Triple(50.5847, 30.4903, "Вишгород"),
            Triple(50.0656, 29.9194, "Фастів"),
            Triple(50.1283, 30.6558, "Обухів")
        )

        paint.style = Paint.Style.FILL
        for (town in keyTowns) {
            val (tx, ty) = project(town.first, town.second)
            if (tx in 0f..WIDTH.toFloat() && ty in 0f..HEIGHT.toFloat()) {
                paint.color = Color.parseColor("#384260")
                canvas.drawCircle(tx, ty, 3.5f, paint)

                textPaint.color = Color.parseColor("#5A688C")
                textPaint.textSize = 12f
                textPaint.typeface = Typeface.DEFAULT
                canvas.drawText(town.third, tx + 6f, ty + 4f, textPaint)
            }
        }

        // Kyiv center marker
        paint.color = Color.parseColor("#4CAF50")
        canvas.drawCircle(kX, kY, 6f, paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 2f
        paint.color = Color.parseColor("#81C784")
        canvas.drawCircle(kX, kY, 11f, paint)

        val kyivTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 16f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            setShadowLayer(4f, 0f, 0f, Color.BLACK)
        }
        canvas.drawText("КИЇВ", kX + 14f, kY + 5f, kyivTextPaint)

        // 4. Watched Locations (User Safety Zones)
        for (loc in watchedLocations) {
            val enabled = loc["enabled"] as? Boolean ?: true
            if (!enabled) continue

            val lat = (loc["lat"] as? Number)?.toDouble() ?: continue
            val lon = (loc["lon"] as? Number)?.toDouble() ?: continue
            val radiusMeters = (loc["radiusMeters"] as? Number)?.toDouble() ?: 4000.0
            val name = (loc["name"] as? String) ?: "Дім"

            val (lx, ly) = project(lat, lon)
            val rPx = metersToPx(radiusMeters)

            // Zone Fill
            paint.style = Paint.Style.FILL
            paint.color = Color.argb(45, 124, 77, 255)
            canvas.drawCircle(lx, ly, rPx, paint)

            // Zone Stroke
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2f
            paint.color = Color.argb(180, 156, 39, 176)
            canvas.drawCircle(lx, ly, rPx, paint)

            // Center Pin
            paint.style = Paint.Style.FILL
            paint.color = Color.parseColor("#E040FB")
            canvas.drawCircle(lx, ly, 4f, paint)

            val locTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.parseColor("#CE93D8")
                textSize = 13f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                setShadowLayer(3f, 0f, 0f, Color.BLACK)
            }
            canvas.drawText("🏠 $name", lx + 8f, ly + 4f, locTextPaint)
        }

        // 5. Active Threats (Trajectories, Velocity Arrows, Markers)
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 3.5f
            pathEffect = DashPathEffect(floatArrayOf(10f, 6f), 0f)
        }

        val threatTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 14f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            setShadowLayer(5f, 0f, 0f, Color.BLACK)
        }

        for (threat in threats) {
            val type = (threat["type"] as? String) ?: "shahed"
            val label = (threat["label"] as? String) ?: "Ціль"
            val route = (threat["route"] as? String) ?: ""
            val isDescending = threat["isDescending"] as? Boolean ?: false

            val isMissile = type.contains("missile") || type == "kab"
            val threatColor = when {
                type == "missile_hypersonic" -> Color.parseColor("#D500F9")
                type == "missile_ballistic" -> Color.parseColor("#FF1744")
                type.contains("missile") -> Color.parseColor("#FF5252")
                type == "kab" -> Color.parseColor("#FFD600")
                type == "shahed_jet" -> Color.parseColor("#FF4081")
                else -> Color.parseColor("#FF9100") // shahed
            }

            linePaint.color = Color.argb(180, Color.red(threatColor), Color.green(threatColor), Color.blue(threatColor))

            @Suppress("UNCHECKED_CAST")
            val pathList = threat["path"] as? List<Map<String, Any?>> ?: emptyList()
            if (pathList.isEmpty()) continue

            val projectedPoints = pathList.mapNotNull { p ->
                val pLat = (p["lat"] as? Number)?.toDouble()
                val pLon = (p["lon"] as? Number)?.toDouble()
                if (pLat != null && pLon != null) project(pLat, pLon) else null
            }

            if (projectedPoints.size >= 2) {
                val trajectoryPath = Path().apply {
                    moveTo(projectedPoints.first().first, projectedPoints.first().second)
                    for (i in 1 until projectedPoints.size) {
                        lineTo(projectedPoints[i].first, projectedPoints[i].second)
                    }
                }
                canvas.drawPath(trajectoryPath, linePaint)
            }

            // Current target marker (last point)
            val currentPt = projectedPoints.lastOrNull() ?: continue
            val (cx, cy) = currentPt

            // Outer pulse circle
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2.5f
            paint.color = threatColor
            canvas.drawCircle(cx, cy, 12f, paint)

            // Inner solid core
            paint.style = Paint.Style.FILL
            paint.color = Color.WHITE
            canvas.drawCircle(cx, cy, 5f, paint)

            // Velocity Vector leader line
            if (projectedPoints.size >= 2) {
                val prevPt = projectedPoints[projectedPoints.size - 2]
                val dx = cx - prevPt.first
                val dy = cy - prevPt.second
                val dist = sqrt(dx * dx + dy * dy)
                if (dist > 1f) {
                    val nx = dx / dist
                    val ny = dy / dist
                    val arrowLen = 30f
                    val ax = cx + nx * arrowLen
                    val ay = cy + ny * arrowLen

                    paint.style = Paint.Style.STROKE
                    paint.strokeWidth = 2.5f
                    paint.color = threatColor
                    canvas.drawLine(cx, cy, ax, ay, paint)
                    canvas.drawCircle(ax, ay, 3f, paint)
                }
            }

            // Threat Label Text
            threatTextPaint.color = threatColor
            val fullLabel = if (route.isNotBlank()) "$label → $route" else label
            val finalLabel = if (isDescending) "$fullLabel ↓" else fullLabel
            canvas.drawText(finalLabel, cx + 15f, cy - 6f, threatTextPaint)
        }

        // 6. Top HUD Header: Status Badge & Live Clock
        val hudPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val badgeBgColor = if (isAlert) Color.parseColor("#B71C1C") else Color.parseColor("#1B5E20")
        val badgeBorderColor = if (isAlert) Color.parseColor("#FF1744") else Color.parseColor("#4CAF50")

        // Badge pill rect
        val badgeRect = RectF(16f, 16f, 240f, 48f)
        hudPaint.style = Paint.Style.FILL
        hudPaint.color = badgeBgColor
        canvas.drawRoundRect(badgeRect, 16f, 16f, hudPaint)

        hudPaint.style = Paint.Style.STROKE
        hudPaint.strokeWidth = 1.5f
        hudPaint.color = badgeBorderColor
        canvas.drawRoundRect(badgeRect, 16f, 16f, hudPaint)

        val badgeTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 14f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val badgeIcon = if (isAlert) "🚨 " else "🟢 "
        canvas.drawText("$badgeIcon$statusTitle", 28f, 37f, badgeTextPaint)

        // Top-Right Clock & Sector
        val clockTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#A0AEC0")
            textSize = 13f
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            textAlign = Paint.Align.RIGHT
        }
        canvas.drawText("КИЇВСЬКИЙ СЕКТОР • $updatedTime", (WIDTH - 16).toFloat(), 36f, clockTextPaint)

        // Bottom HUD Branding
        val footerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#3D4866")
            textSize = 11f
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
        }
        canvas.drawText("KYIV AIR DEFENSE TACTICAL RADAR", 16f, (HEIGHT - 16).toFloat(), footerPaint)
        canvas.drawText("МАСШТАБ 1:65 KM", (WIDTH - 130).toFloat(), (HEIGHT - 16).toFloat(), footerPaint)

        // Save Bitmap to filesDir/radar_snapshot.png (scaled to max 480x340 px for widget Binder IPC safety)
        try {
            val file = File(context.filesDir, "radar_snapshot.png")
            val scaledBitmap = if (bitmap.width > 480 || bitmap.height > 340) {
                Bitmap.createScaledBitmap(bitmap, 480, 340, true)
            } else {
                bitmap
            }
            FileOutputStream(file).use { fos ->
                scaledBitmap.compress(Bitmap.CompressFormat.PNG, 90, fos)
                fos.flush()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        return bitmap
    }
}
