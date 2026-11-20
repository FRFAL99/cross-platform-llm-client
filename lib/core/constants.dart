class AppConstants {
  AppConstants._();

  // Hive Box Names
  static const String chatSessionsBox = 'chat_sessions';
  static const String chatMessagesBox = 'chat_messages';
  static const String chatMessageIndexBox = 'chat_message_index';

  /// Legacy box of the removed task feature, deleted on startup.
  static const String tasksBox = 'tasks';
  static const String settingsBox = 'settings';

  // Settings Keys
  static const String keyGlobalSystemPrompt = 'global_system_prompt';
  static const String keyLocalModelPath = 'local_model_path';
  static const String keyLocalModelName = 'local_model_name';
  static const String keyLocalModelRuntime = 'local_model_runtime';
  static const String keyLocalModelBackend = 'local_model_backend';

  /// Performance mode for local models: 'auto_fast', 'gpu_fast' or
  /// 'cpu_safe'. The stored key keeps its old LiteRT-era name so existing
  /// settings survive.
  static const String keyPerformanceMode = 'litert_performance_mode';

  /// Set while a GGUF model runs on the GPU until its first reply succeeds;
  /// still set on the next load means the GPU crashed the app.
  static const String keyGgufGpuPending = 'gguf_gpu_pending';
  static const String keyStopSequences = 'stop_sequences';
  static const String keyTemperature = 'temperature';
  static const String keyMaxTokens = 'max_tokens';
  static const String keyContextSize = 'context_size';
  static const String keyHapticsEnabled = 'haptics_enabled';

  /// Summarize chat messages that no longer fit in the context window.
  static const String keySummarizeHistory = 'summarize_history';
  static const String keyAutoUpdateCheck = 'auto_update_check';
  static const String keyLastUpdateCheck = 'last_update_check';
  static const String keyLastUpdatePrompt = 'last_update_prompt';
  static const String keySkippedUpdateVersion = 'skipped_update_version';

  /// GitHub repository whose releases ship the Android APKs.
  static const String githubRepo = 'FRFAL99/cross-platform-llm-client';
  static const String keyServerApiKey = 'server_api_key';
  static const String keyServerUseApiKey = 'server_use_api_key';
  static const String keyServerAllowNetwork = 'server_allow_network';
  static const String keyClusterEnabled = 'cluster_enabled';
  static const String keyClusterWorkers = 'cluster_workers';

  /// Speed test history: list of BenchmarkResult maps, newest first.
  static const String keyBenchmarkResults = 'benchmark_results';

  /// This phone's pairing code as a worker (secure storage).
  static const String keyClusterWorkerCode = 'cluster_worker_code';

  /// Master: pairing code of each worker, JSON {worker id or endpoint: code}
  /// (secure storage).
  static const String keyClusterPairingCodes = 'cluster_pairing_codes';

  /// Prefix of the native generation error when a cluster worker drops.
  static const String clusterWorkerLostError = 'CLUSTER_WORKER_LOST:';
  static const String keyFontScale = 'font_scale';
  static const String keyMessageStorageVersion = 'message_storage_version';

  // Default Model Config
  static const double defaultTemperature = 0.7;
  static const int defaultMaxTokens = 1024;
  static const int defaultContextSize = 2048;
  static const String defaultPerformanceMode = 'auto_fast';
  static const double defaultFontScale =
      0.95; // 4th slider stop, "Small" default

  // System Prompt (compact for small context models)
  static const String systemPrompt =
      '''You are PrivateLM, a helpful and friendly assistant. Be concise, accurate, and conversational. Answer questions directly without unnecessary preamble.''';

  // System Prompt for Uncensored Models
  static const String uncensoredSystemPrompt =
      '''You are PrivateLM running with an uncensored local model. Be direct, mature, and conversational. Avoid moralizing or unnecessary disclaimers, but keep answers accurate and do not help with real-world harm, abuse, or illegal activity.''';

  /// Default system prompts of older versions, still stored in some
  /// settings: treated as the default, not as a custom prompt.
  static const legacySystemPrompts = {
    '''You are AI Chat, a helpful and friendly assistant. Be concise, accurate, and conversational. Answer questions directly without unnecessary preamble.''',
  };

  /// [prompt] is the default system prompt (now or in an older version).
  static bool isDefaultSystemPrompt(String prompt) {
    final p = prompt.trim();
    return p.isEmpty || p == systemPrompt || legacySystemPrompts.contains(p);
  }

  static bool isUncensoredModelName(String value) {
    final lower = value.toLowerCase();
    return lower.contains('uncensored') ||
        lower.contains('abliterated') ||
        lower.contains('unrestricted') ||
        lower.contains('dolphin');
  }

  // Available Models for Download
  static const List<Map<String, String>> availableModels = [
    {
      'name': 'Kimi Moonlight 16B-A3B (Q3_K_S)',
      'filename': 'moonlight-16b-a3b-instruct-q3_k_s.gguf',
      'url':
          'https://huggingface.co/mmnga/Moonlight-16B-A3B-Instruct-gguf/resolve/main/Moonlight-16B-A3B-Instruct-Q3_K_S.gguf',
      'sha256':
          'c632f6e9f15f781f1d1cd061d6533e20ee3263162a9b9cc312417d27023fda7b',
      'size': '7.1 GB',
      'description': 'Moonshot AI (Kimi) — 3B active MoE, high quality',
      'template': 'chatml',
    },
    {
      'name': 'Gemma 4 26B-A4B Instruct (UD-IQ2_M)',
      'filename': 'gemma-4-26b-a4b-it-ud-iq2_m.gguf',
      'url':
          'https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-IQ2_M.gguf',
      'sha256':
          '3fe245f4436ab44c103291222e81c514e53ca382871b555df24fea11e36b3c3a',
      'size': '10.0 GB',
      'description':
          'Google Gemma 4 MoE, 4B active — too big for one phone: run it as a Phone cluster master with workers (~11 GB free across devices)',
      'template': 'gemma',
    },
    {
      'name': 'Qwen2.5-3B Instruct (Q4_K_M)',
      'filename': 'qwen2.5-3b-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf',
      'sha256':
          '9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94',
      'size': '2.1 GB',
      'description': 'Best balance of speed and quality for mobile',
      'template': 'chatml',
    },
    {
      'name': 'LFM2.5 1.2B Instruct (Q4_K_M)',
      'filename': 'lfm2.5-1.2b-instruct-q4_k_m.gguf',
      'recommended': 'general',
      'url':
          'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
      'sha256':
          'b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5',
      'size': '731 MB',
      'description':
          'Liquid AI\'s fast on-device model — quick replies on mid-range phones',
      'template': 'chatml',
    },
    {
      'name': 'LFM2.5-VL 1.6B (Q4_K_M)',
      'filename': 'lfm2.5-vl-1.6b-q4_k_m.gguf',
      'url':
          'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-Q4_K_M.gguf',
      'sha256':
          'aefc3c97c9eb30d9c0dd6af4c38250f5f5106b57c8cf92de7914c7d0a9c94da2',
      'size': '731 MB + 583 MB vision',
      'description':
          'Liquid AI\'s small vision model — fast, light enough for the GPU on most phones',
      'template': 'chatml',
      'vision': 'true',
      'mmproj_filename': 'lfm2.5-vl-1.6b-mmproj-q8_0.gguf',
      'mmproj_url':
          'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/mmproj-LFM2.5-VL-1.6b-Q8_0.gguf',
      'mmproj_sha256':
          '2ce89e610c56f3198ece2b86cf61743a08b9307279c89125eb2412ebb908689d',
    },
    {
      'name': 'Qwen2-VL-2B Instruct (Q4_K_M)',
      'filename': 'qwen2-vl-2b-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/ggml-org/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf',
      'sha256':
          '5745685d2e607a82a0696c1118e56a2a1ae0901da450fd9cd4f161c6b62867d7',
      'size': '986 MB + 710 MB vision',
      'description':
          'Small vision model — describe photos, read text in images',
      'template': 'chatml',
      'vision': 'true',
      'mmproj_filename': 'qwen2-vl-2b-instruct-mmproj-q8_0.gguf',
      'mmproj_url':
          'https://huggingface.co/ggml-org/Qwen2-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-2B-Instruct-Q8_0.gguf',
      'mmproj_sha256':
          'a0ad91f00a7a80dcf84d719a61b00ee2e07b71794f4ee2dfa81a254621a8c418',
    },
    {
      'name': 'Gemma 4 E2B Uncensored Vision (Q2_K_P)',
      'filename': 'gemma-4-e2b-uncensored-hauhaucs-aggressive-q2_k_p.gguf',
      'url':
          'https://huggingface.co/HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive/resolve/main/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive-Q2_K_P.gguf',
      'sha256':
          'c9213a33b16d513482790bb7092243f783a450e35f7deca584a41e0470afdb97',
      'size': '3.0 GB + 986 MB vision',
      'description':
          'Uncensored Gemma 4 with image understanding — smallest quant, needs ~4 GB free RAM',
      'template': 'gemma',
      'vision': 'true',
      'mmproj_filename': 'gemma-4-e2b-uncensored-hauhaucs-mmproj-f16.gguf',
      'mmproj_url':
          'https://huggingface.co/HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive/resolve/main/mmproj-Gemma-4-E2B-Uncensored-HauhauCS-Aggressive-f16.gguf',
      'mmproj_sha256':
          '628b7e999f89beef70b32396ae84f59c096e867747d7901f0134064ff672e290',
    },
    {
      'name': 'Gemma 3 4B Instruct Vision (Q4_K_M)',
      'filename': 'gemma-3-4b-it-q4_k_m.gguf',
      'url':
          'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf',
      'sha256':
          '882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863',
      'size': '2.5 GB + 851 MB vision',
      'description':
          'Google\'s multimodal Gemma — stronger image understanding, needs ~4 GB free RAM',
      'template': 'gemma',
      'vision': 'true',
      'mmproj_filename': 'gemma-3-4b-it-mmproj-f16.gguf',
      'mmproj_url':
          'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf',
      'mmproj_sha256':
          '8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb',
    },
    {
      'name': 'Phi-3.5 Mini Instruct (Q4_K_M)',
      'filename': 'phi-3.5-mini-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
      'sha256':
          'e4165e3a71af97f1b4820da61079826d8752a2088e313af0c7d346796c38eff5',
      'size': '2.2 GB',
      'description': 'Microsoft\'s compact reasoning model',
      'template': 'phi',
    },
    {
      'name': 'Gemma 3 1B Instruct (Q4_0)',
      'filename': 'gemma-3-1b-it-q4_0.gguf',
      'url':
          'https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_0.gguf',
      'sha256':
          '27ee88e03be02e9ba73def9a819d570d8ad73716e50769e87f374ae394b0276e',
      'size': '722 MB',
      'description':
          'Google\'s newer compact chat model — fast, small, and capable',
      'template': 'gemma',
    },
    {
      'name': 'Qwen3 4B Abliterated (Q4_K_M)',
      'filename': 'mlabonne_qwen3-4b-abliterated-q4_k_m.gguf',
      'recommended': 'uncensored',
      'url':
          'https://huggingface.co/bartowski/mlabonne_Qwen3-4B-abliterated-GGUF/resolve/main/mlabonne_Qwen3-4B-abliterated-Q4_K_M.gguf',
      'size': '2.5 GB',
      'description':
          'Qwen3 4B with refusals removed (abliterated) — the best uncensored pick for 6 GB+ phones; thinks before answering',
      'template': 'chatml',
    },
    {
      'name': 'Gemma 3 4B Abliterated (Q4_K_M)',
      'filename': 'mlabonne_gemma-3-4b-it-abliterated-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/mlabonne_gemma-3-4b-it-abliterated-GGUF/resolve/main/mlabonne_gemma-3-4b-it-abliterated-Q4_K_M.gguf',
      'size': '2.5 GB',
      'description':
          'Gemma 3 4B with refusals removed (abliterated) — answers directly, good at writing',
      'template': 'gemma',
    },
    {
      'name': 'Qwen3 1.7B Abliterated (Q4_K_M)',
      'filename': 'mlabonne_qwen3-1.7b-abliterated-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/mlabonne_Qwen3-1.7B-abliterated-GGUF/resolve/main/mlabonne_Qwen3-1.7B-abliterated-Q4_K_M.gguf',
      'size': '1.3 GB',
      'description':
          'Small uncensored Qwen3 for phones with 4 GB of RAM; thinks before answering',
      'template': 'chatml',
    },
    {
      'name': 'Llama-3.2-1B Instruct (Q4_K_M)',
      'filename': 'llama-3.2-1b-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      'sha256':
          '6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83',
      'size': '0.8 GB',
      'description': 'Ultra-lightweight text model',
      'template': 'llama3',
    },
  ];
}
