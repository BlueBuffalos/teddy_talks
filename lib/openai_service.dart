import 'dart:convert';
import 'package:http/http.dart' as http;

class OpenAIService {
  final String apiKey;
  final String model;
  OpenAIService({required this.apiKey, required this.model});

  Future<String> chat({
    required String systemPrompt,
    required String stylePrefix,
    required String userText,
  }) async {
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final headers = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final body = jsonEncode({
      "model": model,
      "temperature": 0.6,
      "max_tokens": 120,
      "messages": [
        {"role": "system", "content": systemPrompt},
        {"role": "user", "content": "$stylePrefix\nUser: $userText\nReply as Teddy in one to two sentences."}
      ]
    });

    final resp = await http.post(uri, headers: headers, body: body);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body);
      final text = data["choices"][0]["message"]["content"];
      return (text as String).trim();
    }
    throw Exception("OpenAI error ${resp.statusCode}: ${resp.body}");
  }
}
