import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Tiny Groq client (OpenAI-compatible chat API): one question in, one
/// answer out. No chat history is ever stored — each ask is a single
/// stateless request. Get a key at https://console.groq.com/keys.
class GroqClient {
  static const String endpoint =
      'https://api.groq.com/openai/v1/chat/completions';

  /// Fast + generous free-tier limits; ideal for quick writing questions.
  static const String model = 'openai/gpt-oss-20b';

  final http.Client _http;

  GroqClient({http.Client? client}) : _http = client ?? http.Client();

  void dispose() => _http.close();

  Future<String> ask(String apiKey, String question) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw GroqException('Paste your Groq API key first.');
    }
    final q = question.trim();
    if (q.isEmpty) {
      throw GroqException('Type a question first.');
    }
    late final http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(buildChatRequest(q)),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw GroqException(
          'Groq took too long. Check your connection and retry.');
    } catch (e) {
      throw GroqException('Could not reach Groq ($e).');
    }
    if (res.statusCode != 200) {
      throw GroqException.friendly(res.statusCode, res.body);
    }
    return parseChatAnswer(res.body);
  }
}

/// Pure request builder (unit-tested, no network).
Map<String, Object> buildChatRequest(String question) {
  return {
    'model': GroqClient.model,
    'messages': [
      {
        'role': 'system',
        'content': 'You are a concise writing assistant inside a '
            'note-taking app. Answer briefly and plainly. When asked '
            'for a better word, lead with the word itself.',
      },
      {'role': 'user', 'content': question.trim()},
    ],
    'temperature': 0.7,
    'max_tokens': 400,
  };
}

/// Pure response parser (unit-tested, no network).
String parseChatAnswer(String body) {
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final choices = json['choices'] as List;
    final message =
        (choices.first as Map<String, dynamic>)['message']
            as Map<String, dynamic>;
    final content = (message['content'] ?? '').toString().trim();
    if (content.isEmpty) {
      throw GroqException('Groq answered empty-handed.');
    }
    return content;
  } catch (e) {
    if (e is GroqException) rethrow;
    throw GroqException('Could not read the answer.');
  }
}

class GroqException implements Exception {
  final String message;
  GroqException(this.message);

  factory GroqException.friendly(int code, String body) {
    if (code == 401) {
      return GroqException(
          'Wrong or missing key (401). Paste a valid Groq API key from console.groq.com/keys.');
    }
    if (code == 429) {
      return GroqException(
          'Rate limited (429). Free-tier quota is tight — wait a bit and retry.');
    }
    String detail = '';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final err = json['error'];
      if (err is Map) {
        detail = (err['message'] ?? '').toString();
      } else {
        detail = (json['message'] ?? '').toString();
      }
    } catch (_) {}
    final suffix = detail.isEmpty ? '' : ' $detail';
    return GroqException('Groq error $code.$suffix'.trim());
  }

  @override
  String toString() => message;
}
