import 'dart:convert';
import 'package:http/http.dart' as http;

class OpenAIService {
  final String apiKey;
  final String model;
  final String baseUrl; // e.g. https://api.openai.com/v1 or Azure-equivalent
  final String? orgId; // optional OpenAI-Organization header
  final String? projectId; // optional OpenAI-Project header

  OpenAIService({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://api.openai.com/v1',
    this.orgId,
    this.projectId,
  });

  Future<String> chat({
    required String systemPrompt,
    required String stylePrefix,
    required String userText,
  }) async {
    final uri = Uri.parse('$baseUrl/chat/completions');
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    if (orgId != null && orgId!.isNotEmpty) headers['OpenAI-Organization'] = orgId!;
    if (projectId != null && projectId!.isNotEmpty) headers['OpenAI-Project'] = projectId!;

  final body = jsonEncode({
      "model": model,
      "temperature": 0.4,
      "max_tokens": 400,
      "messages": [
  {"role": "system", "content": "$systemPrompt\n$stylePrefix\nStay strictly in character as K-2 S-O."},
    {"role": "user", "content": userText}
      ]
    });

    final resp = await http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 45));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body);
      final text = data["choices"][0]["message"]["content"];
      return (text as String).trim();
    }
    // Bubble up concise error info
    final snippet = resp.body.length > 500 ? resp.body.substring(0, 500) : resp.body;
    throw Exception("OpenAI error ${resp.statusCode}: $snippet");
  }
}
