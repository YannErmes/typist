import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Tiny Mistral client: one question in, one answer out. No chat history
/// is ever stored — each ask is a single stateless request.
class MistralClient {
  static const String endpoint =
      'https://api.mistral.ai/v1/chat/completions';
  static const String model = 'mistral-small-latest';

  final http.Client _http;

  MistralClient({http.Client? client})
      : _http = client ?? http.Client();

  void dispose() => _http.close();

  Future<String> ask(String apiKey, String question) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw MistralException(
          'Paste your Mistral API key first.');
    }
    final q = question.trim();
    if (q.isEmpty) {
      throw MistralException('Type a question first.');
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
      throw MistralException(
          'Mistral took too long. Check your connection and retry.');
    } catch (e) {
      throw MistralException('Could not reach Mistral ($e).');
    }
    if (res.statusCode != 200) {
      throw MistralException.friendly(res.statusCode, res.body);
    }
    return parseChatAnswer(res.body);
  }
}

/// Pure request builder (unit-tested, no network).
Map<String, Object> buildChatRequest(String question) {
  return {
    'model': MistralClient.model,
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
      throw MistralException('Mistral answered empty-handed.');
    }
    return content;
  } catch (e) {
    if (e is MistralException) rethrow;
    throw MistralException('Could not read the answer.');
  }
}

class MistralException implements Exception {
  final String message;
  MistralException(this.message);

  factory MistralException.friendly(int code, String body) {
    if (code == 401) {
      return MistralException(
          'Wrong or missing key (401). Paste a valid Mistral API key.');
    }
    if (code == 429) {
      return MistralException(
          'Rate limited (429). Wait a moment and retry.');
    }
    String detail = '';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      detail =
          (json['message'] ?? json['error'] ?? '').toString();
    } catch (_) {}
    final suffix = detail.isEmpty ? '' : ' $detail';
    return MistralException('Mistral error $code.$suffix'.trim());
  }

  @override
  String toString() => message;
}
