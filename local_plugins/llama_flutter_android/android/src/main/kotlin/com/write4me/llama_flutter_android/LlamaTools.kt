package com.write4me.llama_flutter_android

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** JNI helpers for the loaded model: speed benchmark, token counting, decisions. */
object LlamaTools {
    init {
        System.loadLibrary("llama_jni")
    }

    /** [prompt tok/s, generation tok/s], or null if stopped. Clears the cache. */
    external fun nativeBenchmark(nPrompt: Int, nGen: Int, reps: Int): DoubleArray?

    /** Tokens in [text] for the loaded model, or -1 without a model. */
    external fun nativeCountTokens(text: String): Int

    /**
     * Answer-letter logits of multiple-choice [prompts] (already formatted),
     * [counts] letters each, without generating:
     * [shared prefix tokens, then per prompt its token count and logits].
     * Null if stopped.
     */
    external fun nativeScoreOptions(prompts: Array<String>, counts: IntArray): DoubleArray?

    /**
     * Formats a decision prompt with the model's chat template, the same way
     * generateChat does, with thinking switched off so the first token
     * written is the answer.
     */
    fun formatDecisionPrompt(system: String, user: String, modelPath: String?): String {
        val prompt = ChatTemplateManager.formatMessages(
            listOf(TemplateChatMessage("system", system), TemplateChatMessage("user", user)),
            null,
            modelPath
        )
        return prompt + noThinkingPrefix(modelPath, prompt)
    }

    /** Qwen3's template with enable_thinking=false: an empty think block. */
    internal fun noThinkingPrefix(modelPath: String?, prompt: String): String {
        val name = (modelPath ?: "").substringAfterLast('/').lowercase()
        val qwen3 = name.contains("qwen3") && !name.contains("2507")
        return if (qwen3 && prompt.endsWith("<|im_start|>assistant\n")) "<think>\n\n</think>\n\n" else ""
    }
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
            "scoreOptions" -> scope.launch(Dispatchers.IO) {
                val out = try {
                    val system = call.argument<String>("system") ?: ""
                    val users = call.argument<List<String>>("users") ?: emptyList()
                    val counts = call.argument<List<Int>>("counts") ?: emptyList()
                    val modelPath = call.argument<String>("modelPath")
                    val prompts = users.map { LlamaTools.formatDecisionPrompt(system, it, modelPath) }
                    LlamaTools.nativeScoreOptions(prompts.toTypedArray(), counts.toIntArray())
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) { result.error("DECISION_FAILED", e.message, null) }
                    return@launch
                }
                withContext(Dispatchers.Main) { result.success(out?.toList()) }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
