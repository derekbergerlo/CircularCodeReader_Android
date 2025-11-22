import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class ApiClient {
  ApiClient({required this.baseUrl});
  String baseUrl;

  /// Sends image bytes to backend for decoding.
  /// Expected backend response JSON:
  /// {
  ///   "product_bits": "101010101",
  ///   "date_bits": "010101010",
  ///   "meta": {...}
  /// }
  Future<Map<String, dynamic>> decodeCircularCode(Uint8List imageBytes) async {
    final uri = Uri.parse('$baseUrl/decode');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: 'capture.png'));

    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return json.decode(resp.body) as Map<String, dynamic>;
    } else {
      throw Exception('Backend error ${resp.statusCode}: ${resp.body}');
    }
  }
}
