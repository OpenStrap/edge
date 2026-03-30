package com.whoopconnect.whoop_connect

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class WhoopForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "whoop_foreground"
        const val NOTIF_ID = 1001
        const val ACTION_UPDATE_HR = "com.whoopconnect.UPDATE_HR"
        const val EXTRA_HR = "heart_rate"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val hr = intent?.getIntExtra(EXTRA_HR, 0) ?: 0
        startForeground(NOTIF_ID, buildNotification(hr))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(hr: Int): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val hrText = if (hr > 0) "$hr bpm" else "Connecting..."
        val contentText = "Heart rate: $hrText"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WHOOP Connect")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "WHOOP Live Data",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps WHOOP BLE connection active"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }
}
