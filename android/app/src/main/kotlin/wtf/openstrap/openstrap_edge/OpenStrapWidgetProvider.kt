package wtf.openstrap.openstrap_edge

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home-screen metrics widget — the Android sibling of OpenStrapWidget.swift
 * (Readiness headline + the Strain · Sleep · HRV rings, Ember on Paper).
 *
 * Renders the snapshot WidgetService.push() writes through home_widget; the app
 * broadcasts an update after every sync (this provider name is already wired in
 * widget_service.dart). Unlike iOS there is no self-refresh fetch of /today —
 * updatePeriodMillis just re-renders the cached snapshot so the theme/staleness
 * stay honest when the app hasn't run for a while.
 *
 * Two layouts, like the iOS families: a 2×2 ring grid (small) and a readiness
 * row over the triple rings (medium). On Android 12+ the launcher picks by live
 * size (RemoteViews size map); below that we choose from the widget's min width.
 */
class OpenStrapWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) render(context, appWidgetManager, id, widgetData)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, appWidgetManager, appWidgetId, HomeWidgetPlugin.getData(context))
    }

    private fun render(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        prefs: SharedPreferences,
    ) {
        val views: RemoteViews = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            RemoteViews(
                mapOf(
                    SizeF(110f, 110f) to build(context, prefs, small = true),
                    SizeF(250f, 110f) to build(context, prefs, small = false),
                ),
            )
        } else {
            val minW = manager.getAppWidgetOptions(id)
                .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            build(context, prefs, small = minW in 1..249)
        }
        manager.updateAppWidget(id, views)
    }

    private fun build(context: Context, prefs: SharedPreferences, small: Boolean): RemoteViews {
        val w = StrapWidgets
        val pal = w.pal(prefs)

        // Snapshot (sentinels: -1 = no data — mirrors OpenStrapEntry).
        val readiness = w.readInt(prefs, "readiness", -1)
        val strain = w.readDouble(prefs, "strain", -1.0)
        val sleepMin = w.readInt(prefs, "sleep_min", -1)
        val needMin = w.readInt(prefs, "sleep_need_min", 480)
        val hrv = w.readInt(prefs, "hrv", -1)
        val hrvBaseline = w.readInt(prefs, "hrv_baseline", -1)

        // Ring fractions + colours — same rules as OpenStrapEntry in Swift.
        val readinessT = if (readiness >= 0) readiness / 100.0 else 0.0
        val readinessColor = when {
            readiness < 0 -> pal.inkMuted
            readiness >= 66 -> w.GOOD
            readiness >= 40 -> w.CORAL
            else -> w.CORAL_DEEP
        }
        val strainT = if (strain >= 0) (strain / 21.0).coerceAtMost(1.0) else 0.0
        val sleepT = if (sleepMin >= 0 && needMin > 0) {
            (sleepMin.toDouble() / needMin).coerceAtMost(1.0)
        } else {
            0.0
        }
        val hrvT = when {
            hrv < 0 -> 0.0
            hrvBaseline > 0 -> (hrv / (1.5 * hrvBaseline)).coerceAtMost(1.0)
            else -> (hrv / 100.0).coerceAtMost(1.0)
        }
        // HRV reads green at/above your baseline, warmer as it drops below it.
        val hrvColor = when {
            hrv < 0 || hrvBaseline <= 0 -> w.GOOD
            hrv >= hrvBaseline -> w.GOOD
            hrv >= (0.8 * hrvBaseline).toInt() -> w.CORAL
            else -> w.CORAL_DEEP
        }

        val strainText = if (strain >= 0) String.format("%.1f", strain) else "—"
        val readinessText = if (readiness >= 0) "$readiness" else "—"
        val hrvText = if (hrv >= 0) "$hrv" else "—"

        val layout = if (small) R.layout.widget_openstrap_small else R.layout.widget_openstrap
        val ringDp = if (small) 40 else 56
        val strokeDp = if (small) 5f else 7f

        val views = RemoteViews(context.packageName, layout)
        views.setInt(R.id.widget_root, "setBackgroundResource", pal.bgRes)
        views.setOnClickPendingIntent(R.id.widget_root, w.openAppIntent(context))

        // Readiness leads the row; its VALUE carries the readiness colour (the
        // iOS headline treatment, compressed into a cell).
        views.setImageViewBitmap(
            R.id.ring_readiness,
            w.ringBitmap(context, ringDp, strokeDp, pal.track, readinessColor, readinessT),
        )
        views.setTextViewText(R.id.val_readiness, readinessText)
        views.setTextColor(R.id.val_readiness, readinessColor)
        views.setTextColor(R.id.cap_readiness, pal.inkMuted)

        fun metric(ring: Int, value: Int, cap: Int, bmpColor: Int, t: Double, text: String) {
            views.setImageViewBitmap(
                ring,
                w.ringBitmap(context, ringDp, strokeDp, pal.track, bmpColor, t),
            )
            views.setTextViewText(value, text)
            views.setTextColor(value, pal.ink)
            views.setTextColor(cap, pal.inkMuted)
        }
        metric(R.id.ring_strain, R.id.val_strain, R.id.cap_strain, w.CORAL, strainT, strainText)
        metric(R.id.ring_sleep, R.id.val_sleep, R.id.cap_sleep, w.SLEEP_BLUE, sleepT, w.hm(sleepMin))
        metric(R.id.ring_hrv, R.id.val_hrv, R.id.cap_hrv, hrvColor, hrvT, hrvText)
        return views
    }
}
