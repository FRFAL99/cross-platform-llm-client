package com.write4me.llama_flutter_android

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** JNI helpers for the loaded model: speed benchmark and token counting. */
object LlamaTools {
    init {
        System.loadLibrary("llama_jni")
    }

    /** [prompt tok/s, generation tok/s], or null if stopped. Clears the cache. */
    external fun nativeBenchmark(nPrompt: Int, nGen: Int, reps: Int): DoubleArray?

    /** Tokens in [text] for the loaded model, or -1 without a model. */
    external fun nativeCountTokens(text: String): Int
}

/** Method channel "llama_flutter_android/tools" for [LlamaTools]. */
class ToolsChannel(messenger: BinaryMessenger, private val scope: CoroutineScope) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "llama_flutter_android/tools")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "benchmark" -> scope.launch(Dispatchers.IO) {
                val out = try {
                    LlamaTools.nativeBenchmark(
                        call.argument<Int>("prompt") ?: 512,
                        call.argument<Int>("gen") ?: 128,
                        call.argument<Int>("reps") ?: 1
                    )
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) { result.error("BENCHMARK_FAILED", e.message, null) }
                    return@launch
                }
                withContext(Dispatchers.Main) { result.success(out?.toList()) }
            }
            "countTokens" -> scope.launch(Dispatchers.IO) {
                val texts = call.argument<List<String>>("texts") ?: emptyList()
                val counts = texts.map { LlamaTools.nativeCountTokens(it) }
                withContext(Dispatchers.Main) { result.success(counts) }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
