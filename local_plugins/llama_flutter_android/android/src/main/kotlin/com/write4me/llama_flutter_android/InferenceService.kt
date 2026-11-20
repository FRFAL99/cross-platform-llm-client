package com.write4me.llama_flutter_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the app process alive while a model is
 * loaded or the API server runs. While the server runs, the app keeps its
 * Flutter engine when its window is closed (swiped away from recent apps),
 * so the server goes on answering; the notification says so and has a
 * Stop button.
 */
class InferenceService : Service() {
    private val binder = InferenceBinder()

    inner class InferenceBinder : Binder() {
        fun getService(): InferenceService = this@InferenceService
    }

    companion object {
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "InferenceServiceChannel"
        const val ACTION_REFRESH = "com.write4me.llama_flutter_android.REFRESH"
        const val ACTION_STOP_SERVER = "com.write4me.llama_flutter_android.STOP_SERVER"

        /** True while the API server runs (set from Dart). */
        @Volatile
        var serverRunning = false
            private set

        /** Called on the main thread when the notification's Stop is tapped. */
        @Volatile
        var onStopServerRequested: (() -> Unit)? = null

        /**
         * Called on the main thread when the server stops while the app has
         * no window, so the app can let its engine go (see MainActivity).
         */
        @Volatile
        var onServerStoppedWithoutUi: (() -> Unit)? = null

        private val main = Handler(Looper.getMainLooper())

        fun setServerRunning(context: Context, running: Boolean, hasUi: Boolean) {
            val changed = serverRunning != running
            serverRunning = running
            if (running) {
                // Started even before a model is loaded: the server must
                // outlive the window either way.
                start(context)
            } else if (changed) {
                refresh(context)
                if (!hasUi) main.post { onServerStoppedWithoutUi?.invoke() }
            }
        }

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context, Intent(context, InferenceService::class.java)
            )
        }

        /** Updates the notification if the service is running. */
        private fun refresh(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.activeNotifications.any { it.id == NOTIFICATION_ID }) {
                manager.notify(NOTIFICATION_ID, build(context))
            }
        }

        private fun build(context: Context): android.app.Notification {
            createChannel(context)
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setSilent(true)
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                builder.setContentIntent(PendingIntent.getActivity(
                    context, 0, it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            if (serverRunning) {
                val stop = Intent(context, InferenceService::class.java).setAction(ACTION_STOP_SERVER)
                builder
                    .setContentTitle("API server running")
                    .setContentText("Keeps answering when you close the app. Tap to open.")
                    .addAction(0, "Stop server", PendingIntent.getService(
                        context, 1, stop,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                builder
                    .setContentTitle("Model loaded")
                    .setContentText("Ready to answer on this device")
            }
            return builder.build()
        }

        private fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID, "AI Inference Service", NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shown while a model is loaded or the API server runs"
                    setSound(null, null)
                }
                context.getSystemService(NotificationManager::class.java)
                    .createNotificationChannel(channel)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every start must call startForeground, also for a Stop tap.
        startForeground(NOTIFICATION_ID, build(this))
        if (intent?.action == ACTION_STOP_SERVER) {
            val stop = onStopServerRequested
            if (stop != null) {
                main.post { stop() }
            } else {
                // No app engine left to stop the server: nothing to keep alive.
                serverRunning = false
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
