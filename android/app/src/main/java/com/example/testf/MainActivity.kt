package com.example.testf

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        const val LIFECYCLE_CHANNEL   = "com.example.testf/lifecycle"
        const val PERM_CHANNEL        = "com.example.testf/permissions"
        const val PERM_REQ_CODE       = 1001
        const val UPDATE_CHANNEL      = "com.example.testf/app_update"
        const val MEDIASTORE_CHANNEL  = "com.example.testf/mediastore"
    }

    private var lifecycleChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        lifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LIFECYCLE_CHANNEL,
        )

        // ── Runtime permissions channel ───────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.POST_NOTIFICATIONS,
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                PERM_REQ_CODE,
                            )
                        }
                        result.success(null)
                    }
                    "requestStoragePermissions" -> {
                        requestStoragePermissions()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
            when (call.method) {
                "getSupportedAbis" -> {
                    result.success(Build.SUPPORTED_ABIS.toList())
                }
                "installApk" -> {
                    val apk = call.argument<String>("path")?.let(::File)
                    if (apk == null || !apk.isFile) {
                        result.error("APK_MISSING", "Downloaded APK was not found", null)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !packageManager.canRequestPackageInstalls()) {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")))
                        result.success(false)
                    } else {
                        try {
                            val uri = FileProvider.getUriForFile(this,
                                "$packageName.fileprovider", apk)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALLER_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── MediaStore channel (audio insertion for API 29+) ─────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIASTORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "insertAudioFromFile" -> {
                        val basename  = call.argument<String>("basename") ?: ""
                        val extension = call.argument<String>("extension") ?: "m4a"
                        val tempPath  = call.argument<String>("tempPath")  ?: ""
                        val tempFile  = java.io.File(tempPath)
                        val uri = MediaStoreHelper.insertFromFile(
                            applicationContext, basename, extension, tempFile
                        )
                        if (uri != null) result.success(uri)
                        else result.error("MEDIASTORE_FAILED", "Could not insert audio", null)
                    }
                    "uriExists" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        result.success(MediaStoreHelper.uriExists(applicationContext, uri))
                    }
                    "copyUriToFile" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val targetPath = call.argument<String>("targetPath") ?: ""
                        result.success(
                            MediaStoreHelper.copyUriToFile(
                                applicationContext, uri, File(targetPath)
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestStoragePermissions() {
        val permsToRequest = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+ — granular audio permission and notifications
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_AUDIO)
                    != PackageManager.PERMISSION_GRANTED) {
                permsToRequest.add(Manifest.permission.READ_MEDIA_AUDIO)
            }
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                permsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        } else {
            // Android 6–12 — legacy storage permission
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE)
                    != PackageManager.PERMISSION_GRANTED) {
                permsToRequest.add(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    != PackageManager.PERMISSION_GRANTED) {
                    permsToRequest.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                }
            }
        }

        if (permsToRequest.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, permsToRequest.toTypedArray(), PERM_REQ_CODE)
        }
    }

    override fun onDestroy() {
        if (!isChangingConfigurations && isFinishing) {
            lifecycleChannel?.invokeMethod("taskRemoved", null)
        }
        lifecycleChannel = null
        super.onDestroy()
    }
}
