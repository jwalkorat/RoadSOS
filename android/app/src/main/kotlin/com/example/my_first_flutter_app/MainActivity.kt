package com.example.my_first_flutter_app

import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.roadsos/sms"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "sendSms") {
                val num = call.argument<String>("phone")
                val msg = call.argument<String>("msg")
                try {
                    val smsManager: SmsManager = SmsManager.getDefault()
                    smsManager.sendTextMessage(num, null, msg, null, null)
                    result.success("SMS Sent")
                } catch (ex: Exception) {
                    result.error("ERR", ex.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
