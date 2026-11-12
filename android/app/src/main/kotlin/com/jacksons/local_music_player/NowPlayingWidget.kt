package com.jacksons.local_music_player

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.KeyEvent
import android.widget.RemoteViews
import com.ryanheise.audioservice.MediaButtonReceiver
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File

/**
 * Home-screen widget: cover, title, artist, previous / play-pause / next.
 *
 * The Dart side writes the current song into home_widget's shared
 * preferences and asks for an update. The buttons send ordinary media-button
 * events to audio_service's receiver, so they work like headset buttons, even
 * when the app's UI isn't running.
 */
class NowPlayingWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val data = HomeWidgetPlugin.getData(context)
        val title = data.getString("title", null)
        val artist = data.getString("artist", null)
        val artPath = data.getString("artPath", null)
        val playing = data.getBoolean("playing", false)
        val art = artPath?.let { loadArt(it) }

        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_now_playing)
            views.setTextViewText(R.id.widget_title, title ?: "Nothing playing")
            views.setTextViewText(R.id.widget_artist, artist ?: "Tap to open Music Player")
            if (art != null) {
                views.setImageViewBitmap(R.id.widget_art, art)
            } else {
                views.setImageViewResource(R.id.widget_art, R.drawable.ic_music_note)
            }
            views.setImageViewResource(
                R.id.widget_play,
                if (playing) R.drawable.ic_pause else R.drawable.ic_play,
            )
            views.setOnClickPendingIntent(R.id.widget_root, openApp(context))
            views.setOnClickPendingIntent(
                R.id.widget_play,
                mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE),
            )
            views.setOnClickPendingIntent(
                R.id.widget_next,
                mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT),
            )
            views.setOnClickPendingIntent(
                R.id.widget_prev,
                mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS),
            )
            manager.updateAppWidget(id, views)
        }
    }

    private fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
            .setComponent(ComponentName(context, MediaButtonReceiver::class.java))
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        return PendingIntent.getBroadcast(
            context, keyCode, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** Decodes the cover at about 256 px, small enough for RemoteViews. */
    private fun loadArt(path: String): Bitmap? {
        if (!File(path).exists()) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 256 && bounds.outHeight / (sample * 2) >= 256) {
                sample *= 2
            }
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (_: Exception) {
            null
        }
    }
}
