package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log

class PermissionRequestTransparentActivity: Activity() {
    private val logTag = "permissionRequest"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(logTag, "onCreate PermissionRequestTransparentActivity: intent.action: ${intent.action}")

        when (intent.action) {
            ACT_REQUEST_MEDIA_PROJECTION -> {
                val mediaProjectionManager =
                    getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    // Force full-device capture flow instead of per-app chooser.
                    mediaProjectionManager.createScreenCaptureIntent(
                        MediaProjectionConfig.createConfigForDefaultDisplay()
                    )
                } else {
                    mediaProjectionManager.createScreenCaptureIntent()
                }
                startActivityForResult(intent, REQ_REQUEST_MEDIA_PROJECTION)
            }
            else -> finish()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_REQUEST_MEDIA_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                Log.d(logTag, "MediaProjection permission granted")
                launchService(data)
            } else {
                Log.w(logTag, "MediaProjection permission denied or missing data")
                setResult(RES_FAILED)
            }
        }

        finish()
    }

    private fun launchService(mediaProjectionResultIntent: Intent) {
        Log.d(logTag, "Launch MainService")
        val serviceIntent = Intent(this, MainService::class.java)
        serviceIntent.action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
        serviceIntent.putExtra(EXT_MEDIA_PROJECTION_RES_INTENT, mediaProjectionResultIntent)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

}