package com.jacksons.local_music_player

import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.Intent
import android.content.IntentSender
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// AudioServiceActivity shares its Flutter engine with the background audio
// service, which is what Android Auto talks to.
class MainActivity : AudioServiceActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    // Deletes waiting for the user to answer the system confirmation.
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPaths: List<String> = emptyList()
    private var pendingUris: List<Uri> = emptyList()

    // Voice / Assistant requests, delivered to Dart.
    private var intentsChannel: MethodChannel? = null
    private var pendingAction: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, FILES_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "deleteFiles" -> {
                    val paths = call.argument<List<String>>("paths")
                    if (paths == null) {
                        result.error("bad_args", "paths is required", null)
                    } else {
                        deleteFiles(paths, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
        intentsChannel = MethodChannel(messenger, INTENTS_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart asks once it's ready, so a cold start isn't lost.
                    "takePendingAction" -> {
                        result.success(pendingAction)
                        pendingAction = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val action: Map<String, Any?> = when (intent?.action) {
            // "Hey Google, play <query> on Music Player"
            MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH -> mapOf(
                "type" to "search",
                "query" to (intent.getStringExtra(android.app.SearchManager.QUERY) ?: ""),
                "focus" to intent.getStringExtra(MediaStore.EXTRA_MEDIA_FOCUS),
                "artist" to intent.getStringExtra(MediaStore.EXTRA_MEDIA_ARTIST),
                "album" to intent.getStringExtra(MediaStore.EXTRA_MEDIA_ALBUM),
                "title" to intent.getStringExtra(MediaStore.EXTRA_MEDIA_TITLE),
                "playlist" to intent.getStringExtra("android.intent.extra.playlist"),
            )
            // App shortcut: long-press the icon -> "Voice command"
            ACTION_VOICE -> mapOf("type" to "voice")
            else -> return
        }
        val channel = intentsChannel
        if (channel == null) {
            pendingAction = action
        } else {
            channel.invokeMethod("onAction", action, object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) {
                    pendingAction = action
                }
                override fun notImplemented() {
                    // Dart side not listening yet (cold start): keep it.
                    pendingAction = action
                }
            })
        }
    }

    // ---------------------------------------------------------------------
    // Deleting files

    private fun deleteFiles(paths: List<String>, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Another delete is waiting for confirmation", null)
            return
        }
        val existing = paths.filter { File(it).exists() }
        if (existing.isEmpty()) {
            result.success(paths)
            return
        }
        val uris = mutableMapOf<String, Uri>()
        val missing = mutableListOf<String>()
        for (path in existing) {
            val uri = mediaStoreUri(path)
            if (uri != null) uris[path] = uri else missing.add(path)
        }
        if (missing.isEmpty()) {
            deleteViaMediaStore(paths, uris, result)
            return
        }
        // Not indexed yet: ask MediaStore to scan them so they get URIs.
        var remaining = missing.size
        MediaScannerConnection.scanFile(this, missing.toTypedArray(), null) { path, uri ->
            mainHandler.post {
                if (uri != null) uris[path] = uri
                remaining--
                if (remaining == 0) deleteViaMediaStore(paths, uris, result)
            }
        }
    }

    private fun deleteViaMediaStore(
        paths: List<String>,
        uris: Map<String, Uri>,
        result: MethodChannel.Result,
    ) {
        // Files MediaStore doesn't know about: try directly.
        for (path in paths) {
            if (!uris.containsKey(path)) deleteDirectly(path)
        }
        if (uris.isEmpty()) {
            result.success(gone(paths))
            return
        }
        // Android 11+: one system dialog for all; MediaStore deletes on approval.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val request = MediaStore.createDeleteRequest(contentResolver, uris.values.toList())
                askUser(request.intentSender, paths, uris.values.toList(), result)
            } catch (e: Exception) {
                uris.keys.forEach { deleteDirectly(it) }
                result.success(gone(paths))
            }
            return
        }
        // Android 10 and older: one by one; Android 10 may need consent for
        // files owned by other apps (asked for the first such file).
        for ((path, uri) in uris) {
            try {
                if (contentResolver.delete(uri, null, null) == 0) deleteDirectly(path)
            } catch (e: SecurityException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    e is RecoverableSecurityException
                ) {
                    askUser(e.userAction.actionIntent.intentSender, paths, uris.values.toList(), result)
                    return
                }
                deleteDirectly(path)
            }
        }
        result.success(gone(paths))
    }

    private fun askUser(
        sender: IntentSender,
        paths: List<String>,
        uris: List<Uri>,
        result: MethodChannel.Result,
    ) {
        pendingResult = result
        pendingPaths = paths
        pendingUris = uris
        try {
            startIntentSenderForResult(sender, DELETE_REQUEST, null, 0, 0, 0)
        } catch (e: IntentSender.SendIntentException) {
            finishPending()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != DELETE_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        if (resultCode == RESULT_OK && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // Android 10: consent granted, now retry.
            for (uri in pendingUris) {
                try {
                    contentResolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
            }
        }
        // Android 11+: createDeleteRequest already deleted on approval.
        finishPending()
    }

    private fun finishPending() {
        pendingResult?.success(gone(pendingPaths))
        pendingResult = null
        pendingPaths = emptyList()
        pendingUris = emptyList()
    }

    private fun gone(paths: List<String>) = paths.filter { !File(it).exists() }

    /** Android 9 and older (or app-owned files). */
    private fun deleteDirectly(path: String): Boolean {
        val file = File(path)
        val isGone = !file.exists() || file.delete()
        if (isGone) {
            // Let MediaStore forget it so other apps stop showing it.
            MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
        }
        return isGone
    }

    private fun mediaStoreUri(path: String): Uri? =
        mediaStoreUri(path, MediaStore.Audio.Media.EXTERNAL_CONTENT_URI)
            ?: mediaStoreUri(path, MediaStore.Files.getContentUri("external"))

    private fun mediaStoreUri(path: String, collection: Uri): Uri? {
        return try {
            contentResolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DATA} = ?",
                arrayOf(path),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    ContentUris.withAppendedId(collection, cursor.getLong(0))
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        private const val FILES_CHANNEL = "com.jacksons.local_music_player/files"
        private const val INTENTS_CHANNEL = "com.jacksons.local_music_player/intents"
        private const val DELETE_REQUEST = 4021
        const val ACTION_VOICE = "com.jacksons.local_music_player.VOICE"
    }
}
