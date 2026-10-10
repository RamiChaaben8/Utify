package com.example.testf

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Handles MediaStore audio insertions for Android API 29+.
 *
 * On API 28 and below the Flutter side falls back to direct file I/O,
 * so this helper is only called on API 29+.
 */
object MediaStoreHelper {

    /** Mime types for the two supported audio containers. */
    private fun mimeFor(extension: String): String = when (extension.lowercase()) {
        "m4a"  -> "audio/mp4"
        "webm" -> "audio/webm"
        "mp4"  -> "audio/mp4"
        else   -> "audio/mpeg"
    }

    /**
     * Inserts an audio file from [tempFile] into MediaStore under Music/Utify.
     *
     * Returns the content:// URI string on success, null on failure.
     * The [tempFile] is deleted after a successful insertion.
     */
    fun insertFromFile(
        context: Context,
        basename: String,
        extension: String,
        tempFile: File,
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        if (!tempFile.exists()) return null

        val resolver = context.contentResolver
        val mime = mimeFor(extension)

        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, "$basename.$extension")
            put(MediaStore.Audio.Media.MIME_TYPE, mime)
            put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/Utify")
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val uri: Uri = try {
            resolver.insert(collection, values) ?: return null
        } catch (e: Exception) {
            return null
        }

        return try {
            val output = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("MediaStore returned no output stream")
            output.use { out ->
                FileInputStream(tempFile).use { input ->
                    input.copyTo(out)
                }
            }
            // Mark as complete.
            values.clear()
            values.put(MediaStore.Audio.Media.IS_PENDING, 0)
            val updated = resolver.update(uri, values, null, null)
            if (updated != 1) {
                throw IllegalStateException("MediaStore entry could not be finalized")
            }
            // Clean up the temp file.
            tempFile.delete()
            uri.toString()
        } catch (e: Exception) {
            // Roll back the pending entry so it does not remain orphaned.
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            null
        }
    }

    /**
     * Checks whether [uriString] (a content:// URI) still points to a
     * file that exists in MediaStore.
     */
    fun uriExists(context: Context, uriString: String): Boolean {
        return try {
            val uri = Uri.parse(uriString)
            context.contentResolver.query(
                uri,
                arrayOf(MediaStore.Audio.Media._ID),
                null,
                null,
                null,
            )?.use { cursor -> cursor.count > 0 } ?: false
        } catch (_: Exception) {
            false
        }
    }

    fun copyUriToFile(context: Context, uriString: String, target: File): Boolean {
        return try {
            val source = context.contentResolver.openInputStream(Uri.parse(uriString))
                ?: return false
            target.parentFile?.mkdirs()
            source.use { input ->
                FileOutputStream(target).use { output -> input.copyTo(output) }
            }
            target.isFile && target.length() > 0L
        } catch (_: Exception) {
            if (target.exists()) target.delete()
            false
        }
    }
}
