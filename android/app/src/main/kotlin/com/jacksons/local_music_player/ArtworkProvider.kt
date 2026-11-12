package com.jacksons.local_music_player

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves the cover art cached by the library scanner as
 * `content://com.jacksons.local_music_player.artwork/<file name>`.
 *
 * Android Auto, the lock screen and other media controllers run in other
 * processes and can't open our private `file://` paths, so the media session
 * hands them these URIs instead. Read-only, and only files directly inside
 * the artwork folder can be opened.
 */
class ArtworkProvider : ContentProvider() {
    private lateinit var artDir: File

    override fun onCreate(): Boolean {
        // Matches getApplicationSupportDirectory()/artwork on the Dart side.
        artDir = File(context!!.filesDir, "artwork").canonicalFile
        return true
    }

    private fun fileFor(uri: Uri): File {
        val name = uri.lastPathSegment ?: throw FileNotFoundException(uri.toString())
        val file = File(artDir, name).canonicalFile
        if (file.parentFile != artDir || !file.isFile) {
            throw FileNotFoundException(uri.toString())
        }
        return file
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Artwork is read-only")
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String =
        when (uri.lastPathSegment?.substringAfterLast('.', "")?.lowercase()) {
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            else -> "image/jpeg"
        }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = fileFor(uri)
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply { addRow(arrayOf<Any>(file.name, file.length())) }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0
}
