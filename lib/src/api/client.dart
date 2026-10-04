import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openai_autoreset/src/core/limits.dart';
import 'package:openai_autoreset/src/core/refusal.dart';

abstract interface class Api {
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  });
}

abstract interface class GuardedApi implements Api {
  Future<Map<String, dynamic>> consume(
    Map<String, dynamic> body, {
    required bool Function() permit,
  });
}

/// Raised only when transport proves no POST bytes were entered.
class ConsumeNotSent extends Refusal {
  const ConsumeNotSent()
    : super(
        'Preflight became stale or monitor is stopping. No request sent; unsent intent cancelled.',
      );
}

void validateResponseHeaders(int status, List<String>? ages) {
  if (status >= 300 && status < 400)
    throw const Refusal('HTTP redirect refused. No credentials forwarded.');
  if (status != 200)
    throw Refusal('HTTP $status. No retry. Check account manually.');
  if (ages != null && (ages.length != 1 || ages.single != '0'))
    throw const Refusal('Cached API response refused.');
}

/// A fresh direct client for each request eliminates reused-socket POST retries.
class HttpApi implements GuardedApi {
  final String token;
  final String account;
  HttpApi(this.token, this.account);
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  }) => _request(path, body: body);
  @override
  Future<Map<String, dynamic>> consume(
    Map<String, dynamic> body, {
    required bool Function() permit,
  }) => _request('$creditsEndpoint/consume', body: body, permit: permit);
  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
    bool Function()? permit,
  }) async {
    const allowed = ['usage', creditsEndpoint, '$creditsEndpoint/consume'];
    if (!allowed.contains(path)) {
      throw const Refusal('Endpoint not allowlisted.');
    }
    final consume = '$creditsEndpoint/consume';
    if ((body != null) != (path == consume)) {
      throw const Refusal('Invalid endpoint/method pairing.');
    }
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionTimeout = httpTimeout;
    var cancelled = false;
    final deadline = Stopwatch()..start();

    Future<Map<String, dynamic>> send() async {
      final request = await client.openUrl(
        body == null ? 'GET' : 'POST',
        Uri.parse('$base$path'),
      );
      request.followRedirects = false;
      request.persistentConnection = false;
      if (body != null) {
        await Future<void>.delayed(Duration.zero);
        final blocked =
            cancelled ||
            deadline.elapsed >= httpTimeout ||
            (permit != null && !permit());
        if (blocked) {
          request.abort();
          throw const ConsumeNotSent();
        }
      }
      final headers = {
        'Authorization': 'Bearer $token',
        'ChatGPT-Account-ID': account,
        'Accept': 'application/json',
        'OpenAI-Beta': 'codex-1',
        'originator': 'Codex Desktop',
        'User-Agent': 'openai-autoreset/1.0',
        'Cache-Control': 'no-cache, no-store',
      };
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.set('Content-Type', 'application/json');
        final payload = utf8.encode(jsonEncode(body));
        request.contentLength = payload.length;
        request.add(payload);
      }
      final response = await request.close();
      validateResponseHeaders(response.statusCode, response.headers['age']);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxApiBytes) {
          throw const Refusal('Oversized API response.');
        }
        bytes.add(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (data is! Map<String, dynamic>) {
        throw const Refusal('Expected a JSON object.');
      }
      return data;
    }

    try {
      return await send().timeout(httpTimeout);
    } on Refusal {
      rethrow;
    } catch (_) {
      throw const Refusal(
        'Network or JSON error. No retry. Check account manually.',
      );
    } finally {
      cancelled = true;
      client.close(force: true);
    }
  }
}
