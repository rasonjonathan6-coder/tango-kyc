package com.tango.kyc.tango_kyc_verification

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet6Address
import java.net.InetAddress

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DNS_TEST_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != LOOKUP_METHOD) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val host = call.argument<String>("host")
                if (host.isNullOrBlank()) {
                    result.error("INVALID_HOST", "host argument is missing or blank", null)
                    return@setMethodCallHandler
                }

                // Resolution is blocking, so it never runs on the platform thread.
                Thread {
                    try {
                        val addresses = InetAddress.getAllByName(host)
                        val payload = addresses.map { address ->
                            mapOf(
                                "address" to address.hostAddress,
                                "type" to if (address is Inet6Address) "IPv6" else "IPv4",
                            )
                        }
                        runOnUiThread { result.success(payload) }
                    } catch (error: Throwable) {
                        val details = buildString {
                            append("runtimeType=").append(error.javaClass.name)
                            append('\n')
                            append("message=").append(error.message)
                            error.cause?.let { append('\n').append("cause=").append(it) }
                        }
                        runOnUiThread {
                            result.error("DNS_LOOKUP_FAILED", error.toString(), details)
                        }
                    }
                }.start()
            }
    }

    private companion object {
        const val DNS_TEST_CHANNEL = "com.tango.kyc/dns_test"
        const val LOOKUP_METHOD = "lookup"
    }
}
