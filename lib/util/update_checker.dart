import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:background_downloader/background_downloader.dart';
import 'package:path_provider/path_provider.dart';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class ReleaseInfo {
  final String version;
  final String changelog;
  final String url;
  final bool isNewerThanCurrent;
  final Map<String, String> downloads;

  ReleaseInfo({
    required this.version,
    required this.changelog,
    required this.url,
    required this.isNewerThanCurrent,
    required this.downloads,
  });

  String? downloadUrlFor(String platform) => downloads[platform];

  Map<String, String> get preferredDownloads {
    final group = _platformGroup();
    final entries = downloads.entries.where((e) => e.key.contains(group));
    return Map.fromEntries(entries);
  }

  Map<String, String> get otherDownloads {
    final group = _platformGroup();
    final entries = downloads.entries.where((e) => !e.key.contains(group));
    return Map.fromEntries(entries);
  }

  String _platformGroup() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return '';
    }
  }
}

extension DownloadLabelFormatter on String {
  String prettifyKey() {
    final parts = split('_');
    if (parts.isEmpty) return this;

    final base = parts.first.capitalize();
    if (parts.length == 1) return base;

    final variant = parts.sublist(1).join(' ').capitalize();
    return '$base ($variant)';
  }

  String capitalize() => isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}

class UpdateChecker {
  // JellyView's own public release repo (upstream Fladder builds can't install over it: different id/signature).
  final String owner = 'nyx-ulrix';
  final String repo = 'jellyview';

  Future<List<ReleaseInfo>> fetchRecentReleases({int count = 5}) async {
    final info = await PackageInfo.fromPlatform();
    final currentVersion = info.version;

    final url = Uri.parse('https://api.github.com/repos/$owner/$repo/releases?per_page=$count');
    final response = await http.get(url);

    if (response.statusCode != 200) {
      print('Failed to fetch releases: ${response.statusCode}');
      return [];
    }

    final List<dynamic> releases = jsonDecode(response.body);
    return releases.where((json) => json['draft'] != true).map((json) {
      final tag = (json['tag_name'] as String?)?.replaceFirst(RegExp(r'^v'), '');
      final changelog = json['body'] as String? ?? '';
      final htmlUrl = json['html_url'] as String? ?? '';
      final assets = json['assets'] as List<dynamic>? ?? [];

      final Map<String, String> downloads = {};
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        final downloadUrl = asset['browser_download_url'] as String? ?? '';

        if (name.endsWith('.apk')) {
          downloads['android'] = downloadUrl;
        } else if (name.contains('iOS') && name.endsWith('.ipa')) {
          downloads['ios'] = downloadUrl;
        } else if (name.contains('Windows') && name.endsWith('Setup.exe')) {
          downloads['windows_installer'] = downloadUrl;
        } else if (name.contains('Windows') && name.endsWith('.zip')) {
          downloads['windows_portable'] = downloadUrl;
        } else if (name.contains('macOS') && name.endsWith('.dmg')) {
          downloads['macos'] = downloadUrl;
        } else if (name.contains('Linux') && name.endsWith('.AppImage')) {
          downloads['linux_appimage'] = downloadUrl;
        } else if (name.contains('Linux') && name.endsWith('.flatpak')) {
          downloads['linux_flatpak'] = downloadUrl;
        } else if (name.contains('Linux') && name.endsWith('.zip')) {
          downloads['linux_zip'] = downloadUrl;
        } else if (name.contains('Linux') && name.endsWith('.zsync')) {
          downloads['linux_zsync'] = downloadUrl;
        } else if (name.contains('Web') && name.endsWith('.zip')) {
          downloads['web'] = downloadUrl;
        }
      }

      bool isNewer = tag != null && _compareVersions(tag, currentVersion) > 0;

      return ReleaseInfo(
        version: tag ?? 'unknown',
        changelog: changelog.trim(),
        url: htmlUrl,
        isNewerThanCurrent: isNewer,
        downloads: downloads,
      );
    }).toList();
  }

  Future<bool> isUpToDate() async {
    final releases = await fetchRecentReleases(count: 1);
    if (releases.isEmpty) return true;
    return !releases.first.isNewerThanCurrent;
  }

  /// Numeric compare of "1.2.3"; pre-release/build suffixes ("-beta", "+4") are ignored.
  static int _compareVersions(String a, String b) {
    a = a.split(RegExp(r'[-+]')).first;
    b = b.split(RegExp(r'[-+]')).first;
    final aParts = a.split('.').map(int.tryParse).toList();
    final bParts = b.split('.').map(int.tryParse).toList();

    for (var i = 0; i < aParts.length || i < bParts.length; i++) {
      final aVal = i < aParts.length ? (aParts[i] ?? 0) : 0;
      final bVal = i < bParts.length ? (bParts[i] ?? 0) : 0;
      if (aVal != bVal) return aVal.compareTo(bVal);
    }
    return 0;
  }
}

/// Downloads a release APK from GitHub, reporting bytes received (total may be null).
Future<File> downloadAndroidUpdate(String apkUrl, void Function(int received, int? total) onProgress) async {
  final uri = Uri.parse(apkUrl);
  if (uri.scheme != 'https' || uri.host != 'github.com') throw const FormatException('Unexpected update source');
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('Download failed (${res.statusCode})');
    final file = File('${(await getTemporaryDirectory()).path}/jellyview-update.apk');
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, res.contentLength);
      }
    } finally {
      await sink.close();
    }
    return file;
  } finally {
    client.close();
  }
}

/// Hands a downloaded APK to Android's installer. Android asks once to allow installs from JellyView;
/// updating keeps all app data.
Future<void> openAndroidInstaller(File apk) async {
  final opened =
      await FileDownloader().openFile(filePath: apk.path, mimeType: 'application/vnd.android.package-archive');
  if (!opened) throw Exception('Could not open the installer');
}
