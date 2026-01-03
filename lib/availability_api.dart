import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';

class AvailabilityApi {
  AvailabilityApi({
    required this.baseUrl,
    this.checkPath = '/api/availability/save',
    this.timeoutMs = 12000,
    this.maxRetries = 3,
    this.authToken,
  });

  final String baseUrl;
  final String checkPath;
  final int timeoutMs;
  final int maxRetries;
  final String? authToken;

  Future<AvailabilityCheckResult> checkAvailability(Map<String, dynamic> payload) async {
    final conn = await Connectivity().checkConnectivity();
    if (conn == ConnectivityResult.none) {
      return AvailabilityCheckResult.offline();
    }

    final uri = Uri.parse('$baseUrl$checkPath');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (authToken != null) 'Authorization': 'Bearer $authToken',
    };

    http.Response? lastResp;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final resp = await http
            .post(uri, headers: headers, body: jsonEncode(payload))
            .timeout(Duration(milliseconds: timeoutMs));

        // Success or client-side validation -> return immediately
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          return AvailabilityCheckResult.ok(data);
        }
        if (resp.statusCode == 400 || resp.statusCode == 422) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          return AvailabilityCheckResult.validation(data);
        }

        // For 5xx/429, retry; otherwise, stop
        lastResp = resp;
        if (!(resp.statusCode >= 500 || resp.statusCode == 429)) {
          return AvailabilityCheckResult.server(resp.statusCode, resp.body);
        }
      } on TimeoutException catch (e) {
        if (attempt == maxRetries - 1) {
          return AvailabilityCheckResult.network('Timeout: $e');
        }
      } on Exception catch (e) {
        if (attempt == maxRetries - 1) {
          return AvailabilityCheckResult.network(e.toString());
        }
      }
      // Exponential-ish backoff
      await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
    }

    if (lastResp != null) {
      return AvailabilityCheckResult.server(lastResp.statusCode, lastResp.body);
    }
    return AvailabilityCheckResult.network('Unknown network error');
  }
}

class AvailabilityCheckResult {
  AvailabilityCheckResult._(this.status, this.data, this.message, this.code);
  final AvailabilityCheckStatus status;
  final Map<String, dynamic>? data;
  final String? message;
  final int? code;

  factory AvailabilityCheckResult.ok(Map<String, dynamic> data) =>
      AvailabilityCheckResult._(AvailabilityCheckStatus.ok, data, null, 200);

  factory AvailabilityCheckResult.validation(Map<String, dynamic> data) =>
      AvailabilityCheckResult._(AvailabilityCheckStatus.validation, data, null, 400);

  factory AvailabilityCheckResult.server(int code, String body) =>
      AvailabilityCheckResult._(AvailabilityCheckStatus.server, null, body, code);

  factory AvailabilityCheckResult.network(String msg) =>
      AvailabilityCheckResult._(AvailabilityCheckStatus.network, null, msg, null);

  factory AvailabilityCheckResult.offline() =>
      AvailabilityCheckResult._(AvailabilityCheckStatus.offline, null, 'No internet', null);
}

enum AvailabilityCheckStatus { ok, validation, server, network, offline }
