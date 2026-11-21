/// Ready-to-paste client code for the local API server, shown in the
/// Server tab: one example per (topic, language) pair.
library;

enum ApiExampleTopic {
  chat('Chat'),
  streaming('Streaming'),
  tools('Tools'),
  decisions('Decisions'),
  models('Models');

  final String label;
  const ApiExampleTopic(this.label);
}

enum ApiExampleLanguage {
  python('Python'),
  curl('curl'),
  javascript('JavaScript');

  final String label;
  const ApiExampleLanguage(this.label);
}

/// Code for [topic] in [language]. [baseUrl] has no `/v1`; [apiKey] is null
/// when the server needs none (SDKs still get a placeholder, since they
/// refuse an empty key).
String apiExample(
  ApiExampleTopic topic,
  ApiExampleLanguage language, {
  required String baseUrl,
  String? apiKey,
}) {
  final key = apiKey == null || apiKey.trim().isEmpty ? null : apiKey.trim();
  final sdkKey = key ?? 'not-needed';
  final v1 = '$baseUrl/v1';
  return switch (language) {
    ApiExampleLanguage.python => _python(topic, v1, key, sdkKey),
    ApiExampleLanguage.curl => _curl(topic, v1, key),
    ApiExampleLanguage.javascript => _javascript(topic, v1, key, sdkKey),
  };
}

// ── Python ────────────────────────────────────────────────────────────────

String _python(ApiExampleTopic topic, String v1, String? key, String sdkKey) {
  final client = 'from openai import OpenAI\n\n'
      'client = OpenAI(\n'
      '    base_url="$v1",\n'
      '    api_key="$sdkKey",\n'
      ')\n';
  switch (topic) {
    case ApiExampleTopic.chat:
      return '$client\n'
          'response = client.chat.completions.create(\n'
          '    model="local",\n'
          '    messages=[{"role": "user", "content": "Hello"}],\n'
          ')\n'
          'print(response.choices[0].message.content)';
    case ApiExampleTopic.streaming:
      return '$client\n'
          'stream = client.chat.completions.create(\n'
          '    model="local",\n'
          '    messages=[{"role": "user", "content": "Write a haiku"}],\n'
          '    stream=True,\n'
          ')\n'
          'for chunk in stream:\n'
          '    print(chunk.choices[0].delta.content or "", end="", flush=True)';
    case ApiExampleTopic.tools:
      return '$client\n'
          'tools = [{\n'
          '    "type": "function",\n'
          '    "function": {\n'
          '        "name": "get_weather",\n'
          '        "description": "Current weather for a city",\n'
          '        "parameters": {\n'
          '            "type": "object",\n'
          '            "properties": {"city": {"type": "string"}},\n'
          '            "required": ["city"],\n'
          '        },\n'
          '    },\n'
          '}]\n\n'
          'response = client.chat.completions.create(\n'
          '    model="local",\n'
          '    messages=[{"role": "user", "content": "Weather in Rome?"}],\n'
          '    tools=tools,\n'
          ')\n'
          'print(response.choices[0].message.tool_calls)\n'
          '# Works best with models trained for tools (Qwen 2.5/3, Hermes, Llama 3.1+).';
    case ApiExampleTopic.decisions:
      final headers =
          key == null ? '' : '    headers={"Authorization": "Bearer $key"},\n';
      return 'import requests\n\n'
          'answers = requests.post(\n'
          '    "$v1/decisions",\n'
          '$headers'
          '    json={\n'
          '        "state": "Help! My payouts have been failing for 3 days.",\n'
          '        "questions": {\n'
          '            "urgent": {"type": "boolean",\n'
          '                       "instructions": "Does this convey urgency?"},\n'
          '            "topic": {"type": "choice",\n'
          '                      "instructions": "What is it about?",\n'
          '                      "options": [\n'
          '                          {"id": "billing", "description": "Payments or invoices"},\n'
          '                          {"id": "bug", "description": "Something broken in the app"},\n'
          '                          {"id": "other", "description": "Anything else"}]},\n'
          '        },\n'
          '    },\n'
          ').json()["answers"]\n'
          'print(answers["urgent"]["probabilities"]["true"])\n'
          'print(answers["topic"]["choice"])';
    case ApiExampleTopic.models:
      return '$client\n'
          'for model in client.models.list():\n'
          '    print(model.id)';
  }
}

// ── curl ──────────────────────────────────────────────────────────────────

String _curl(ApiExampleTopic topic, String v1, String? key) {
  final auth = key == null ? '' : ' \\\n  -H "Authorization: Bearer $key"';
  String post(String path, String body) =>
      'curl $v1/$path \\\n  -H "Content-Type: application/json"$auth \\\n'
      "  -d '$body'";
  switch (topic) {
    case ApiExampleTopic.chat:
      return post('chat/completions',
          '{"model":"local","messages":[{"role":"user","content":"Hello"}]}');
    case ApiExampleTopic.streaming:
      return 'curl -N $v1/chat/completions \\\n'
          '  -H "Content-Type: application/json"$auth \\\n'
          "  -d '{\"model\":\"local\",\"stream\":true,"
          "\"messages\":[{\"role\":\"user\",\"content\":\"Write a haiku\"}]}'";
    case ApiExampleTopic.tools:
      return post(
          'chat/completions',
          '{"model":"local",'
              '"messages":[{"role":"user","content":"Weather in Rome?"}],'
              '"tools":[{"type":"function","function":{"name":"get_weather",'
              '"description":"Current weather for a city",'
              '"parameters":{"type":"object","properties":{"city":{"type":"string"}},'
              '"required":["city"]}}}]}');
    case ApiExampleTopic.decisions:
      return post(
          'decisions',
          '{"state":"Help! My payouts have been failing for 3 days.",'
              '"questions":{"urgent":{"type":"boolean",'
              '"instructions":"Does this convey urgency?"}}}');
    case ApiExampleTopic.models:
      return 'curl $v1/models$auth';
  }
}

// ── JavaScript ────────────────────────────────────────────────────────────

String _javascript(
    ApiExampleTopic topic, String v1, String? key, String sdkKey) {
  final client = 'import OpenAI from "openai";\n\n'
      'const client = new OpenAI({\n'
      '  baseURL: "$v1",\n'
      '  apiKey: "$sdkKey",\n'
      '});\n';
  switch (topic) {
    case ApiExampleTopic.chat:
      return '$client\n'
          'const response = await client.chat.completions.create({\n'
          '  model: "local",\n'
          '  messages: [{ role: "user", content: "Hello" }],\n'
          '});\n'
          'console.log(response.choices[0].message.content);';
    case ApiExampleTopic.streaming:
      return '$client\n'
          'const stream = await client.chat.completions.create({\n'
          '  model: "local",\n'
          '  messages: [{ role: "user", content: "Write a haiku" }],\n'
          '  stream: true,\n'
          '});\n'
          'for await (const chunk of stream) {\n'
          '  process.stdout.write(chunk.choices[0]?.delta?.content ?? "");\n'
          '}';
    case ApiExampleTopic.tools:
      return '$client\n'
          'const response = await client.chat.completions.create({\n'
          '  model: "local",\n'
          '  messages: [{ role: "user", content: "Weather in Rome?" }],\n'
          '  tools: [{\n'
          '    type: "function",\n'
          '    function: {\n'
          '      name: "get_weather",\n'
          '      description: "Current weather for a city",\n'
          '      parameters: {\n'
          '        type: "object",\n'
          '        properties: { city: { type: "string" } },\n'
          '        required: ["city"],\n'
          '      },\n'
          '    },\n'
          '  }],\n'
          '});\n'
          'console.log(response.choices[0].message.tool_calls);';
    case ApiExampleTopic.decisions:
      final auth = key == null ? '' : ',\n    Authorization: "Bearer $key"';
      return 'const res = await fetch("$v1/decisions", {\n'
          '  method: "POST",\n'
          '  headers: {\n'
          '    "Content-Type": "application/json"$auth,\n'
          '  },\n'
          '  body: JSON.stringify({\n'
          '    state: "Help! My payouts have been failing for 3 days.",\n'
          '    questions: {\n'
          '      urgent: { type: "boolean", instructions: "Does this convey urgency?" },\n'
          '    },\n'
          '  }),\n'
          '});\n'
          'const { answers } = await res.json();\n'
          'console.log(answers.urgent.probabilities.true);';
    case ApiExampleTopic.models:
      return '$client\n'
          'for await (const model of client.models.list()) {\n'
          '  console.log(model.id);\n'
          '}';
  }
}
