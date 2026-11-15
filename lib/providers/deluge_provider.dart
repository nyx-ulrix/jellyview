import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';

/// Client for the "We have Deluge at home" dashboard (nyx-ulrix/media-stack, app/server.py).
/// The server only answers the home network / Tailscale and has no login, so no credentials are sent.
const _urlKey = 'delugeUrl';

/// Dashboard address. Defaults to the same tailnet as the Jellyfin server
/// (`jellyfin.<tailnet>.ts.net` -> `wehavedelugeathome.<tailnet>.ts.net`); can be overridden in the Get tab.
final delugeUrlProvider = StateProvider<String>((ref) {
  final saved = ref.read(sharedPreferencesProvider).getString(_urlKey);
  if (saved != null && saved.isNotEmpty) return saved;
  final server = Uri.tryParse(ref.read(userProvider)?.credentials.url ?? '');
  final host = server?.host ?? '';
  if (host.endsWith('.ts.net')) return 'https://wehavedelugeathome.${host.split('.').skip(1).join('.')}';
  return '';
});

void saveDelugeUrl(WidgetRef ref, String url) {
  final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
  ref.read(sharedPreferencesProvider).setString(_urlKey, clean);
  ref.read(delugeUrlProvider.notifier).state = clean;
}

final delugeApiProvider = Provider<DelugeApi>((ref) => DelugeApi(ref.watch(delugeUrlProvider)));

class DelugeApi {
  DelugeApi(this.base);
  final String base;

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse(base);
    if (uri.scheme != 'https' && uri.scheme != 'http')
      throw const FormatException('Set the media server address first.');
    return uri.replace(path: path, queryParameters: query);
  }

  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    final res = await http.get(_uri(path, query)).timeout(const Duration(seconds: 20));
    return _decode(res);
  }

  /// POSTs need this header plus JSON; the server rejects anything else (its CSRF guard).
  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final res = await http
        .post(_uri(path),
            headers: {'X-Requested-With': 'get', 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  dynamic _decode(http.Response res) {
    final data = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode != 200) {
      throw Exception(data is Map && data['error'] != null ? data['error'] : 'Server error ${res.statusCode}');
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> search(String q) async =>
      List<Map<String, dynamic>>.from(await get('/api/search', {'q': q}) as List);

  Future<List<Map<String, dynamic>>> queue() async => List<Map<String, dynamic>>.from(await get('/api/queue') as List);

  Future<List<Map<String, dynamic>>> upcoming() async =>
      List<Map<String, dynamic>>.from(await get('/api/upcoming') as List);

  Future<List<Map<String, dynamic>>> recent([int n = 8]) async =>
      List<Map<String, dynamic>>.from(await get('/api/recent', {'n': '$n'}) as List);

  Future<Map<String, dynamic>> pauseState() async => Map<String, dynamic>.from(await get('/api/paused') as Map);

  Future<Map<String, dynamic>> estimate(String kind, int id, String scope, bool uhd) async => Map<String, dynamic>.from(
      await get('/api/estimate', {'kind': kind, 'id': '$id', 'scope': scope, 'uhd': uhd ? '1' : '0'}) as Map);

  Future<Map<String, dynamic>> request(String kind, int id,
          {required bool anime, String? scope, bool uhd = false}) async =>
      Map<String, dynamic>.from(
          await post('/api/get', {'kind': kind, 'id': id, 'anime': anime, 'scope': scope, 'uhd': uhd}) as Map);

  /// Search now for a movie, or a show's aired episodes that aren't downloaded (optionally one season).
  Future<Map<String, dynamic>> missing(String kind, int id, {int? season}) async => Map<String, dynamic>.from(
      await post('/api/missing', {'kind': kind, 'id': id, if (season != null) 'season': season}) as Map);

  Future<void> itemAction(String hash, String action) => post('/api/item', {'hash': hash, 'action': action});

  Future<void> cancel({String? hash, String? group}) =>
      post('/api/cancel', {if (hash != null) 'hash': hash, if (group != null) 'group': group});

  Future<Map<String, dynamic>> setPaused(bool on) async =>
      Map<String, dynamic>.from(await post('/api/pause', {'on': on}) as Map);
}

/// "2.03:04:05" (qBittorrent) or "03:04:05" (Sonarr/Radarr) -> "2d 3h" / "3h 4m" / "4m".
String? formatEta(String? eta) {
  if (eta == null || eta.isEmpty) return null;
  final m = RegExp(r'^(?:(\d+)\.)?(\d+):(\d+):(\d+)').firstMatch(eta);
  if (m == null) return null;
  final d = int.parse(m.group(1) ?? '0'), h = int.parse(m.group(2)!), min = int.parse(m.group(3)!);
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${min}m';
  return min > 0 ? '${min}m' : '<1m';
}

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
}
