package com.example.my_first_flutter_app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.roadsos/sms"
    private val SENT_ACTION = "SMS_SENT_ACTION"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "sendSms") {
                val num = call.argument<String>("phone")
                val msg = call.argument<String>("msg")
                
                if (num == null || msg == null) {
                    result.error("BAD_ARGS", "Missing phone or message arguments", null)
                    return@setMethodCallHandler
                }

                try {
                    val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        context.getSystemService(SmsManager::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        SmsManager.getDefault()
                    }

                    val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
                    } else {
                        PendingIntent.FLAG_ONE_SHOT
                    }
                    val sentIntent = PendingIntent.getBroadcast(
                        context, 
                        0, 
                        Intent(SENT_ACTION), 
                        flag
                    )

                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(ctx: Context?, intent: Intent?) {
                            context.unregisterReceiver(this)
                            when (resultCode) {
                                Activity.RESULT_OK -> {
                                    result.success("SMS Sent")
                                }
                                SmsManager.RESULT_ERROR_GENERIC_FAILURE -> {
                                    result.error("CARRIER_FAILURE", "Generic carrier failure (e.g. no balance)", null)
                                }
                                SmsManager.RESULT_ERROR_NO_SERVICE -> {
                                    result.error("NO_SERVICE", "No service / network signal", null)
                                }
                                SmsManager.RESULT_ERROR_RADIO_OFF -> {
                                    result.error("RADIO_OFF", "Radio is turned off (Airplane mode)", null)
                                }
                                else -> {
                                    result.error("ERROR_CODE_$resultCode", "Carrier error: $resultCode", null)
                                }
                            }
                        }
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        context.registerReceiver(receiver, IntentFilter(SENT_ACTION), Context.RECEIVER_EXPORTED)
                    } else {
                        @Suppress("UnspecifiedRegisterReceiverFlag")
                        context.registerReceiver(receiver, IntentFilter(SENT_ACTION))
                    }

                    smsManager.sendTextMessage(num, null, msg, sentIntent, null)
                } catch (ex: Exception) {
                    result.error("ERR", ex.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
