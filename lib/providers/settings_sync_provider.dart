import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';

/// Keeps JellyView's settings the same on every device signed in to the same Jellyfin account.
///
/// The settings are stored on the server under the user's display preferences ("jellyviewsettings").
/// On sign-in the newer copy wins: the server's is applied here, or this device's is uploaded.
/// After that, any change is uploaded a few seconds later. Device-only values (download folder,
/// window position, volume, player hardware options...) never travel and never count as a change.
final settingsSyncProvider = Provider<SettingsSync>((ref) {
  final sync = SettingsSync(ref);
  ref.listen(clientSettingsProvider.select((s) => _shared(s.toJson(), _deviceOnly['clientSettings']!)),
      (previous, next) => sync.scheduleUpload());
  ref.listen(videoPlayerSettingsProvider.select((s) => _shared(s.toJson(), _deviceOnly['videoPlayerSettings']!)),
      (previous, next) => sync.scheduleUpload());
  ref.listen(homeSettingsProvider, (previous, next) => sync.scheduleUpload());
  ref.listen(subtitleSettingsProvider, (previous, next) => sync.scheduleUpload());
  ref.listen(downloadSubtitlesProvider, (previous, next) => sync.scheduleUpload());
  ref.onDispose(sync.dispose);
  return sync;
});

const _prefsId = 'jellyviewsettings';
const _client = 'jellyview';

/// Saved-settings keys that follow the account. Everything else stays on the device.
const _syncedKeys = [
  SharedKeys.clientSettingsKey,
  'homeSettings',
  'videoPlayerSettings',
  'subtitleSettings',
  'hiddenNextUp',
  'downloadSubtitles',
];

/// Fields inside a synced JSON setting that only make sense on the device they were set on.
const _deviceOnly = {
  'clientSettings': [
    'syncPath',
    'x',
    'y',
    'size',
    'position',
    'forceLeanBackMode',
    'lowResourceMode',
    'useTVExpandedLayout',
    'lastViewedUpdate',
    'maxConcurrentDownloads',
  ],
  'videoPlayerSettings': [
    'internalVolume',
    'screenBrightness',
    'hardwareAccel',
    'useLibass',
    'enableTunneling',
    'bufferSize',
    'refreshRateSwitching',
    'allowedOrientations',
    'playerOptions',
  ],
};

/// The part of a setting that is shared between devices, as a comparable string.
String _shared(Map<String, dynamic> json, List<String> deviceOnly) =>
    jsonEncode({...json}..removeWhere((key, _) => deviceOnly.contains(key)));

class SettingsSync {
  SettingsSync(this.ref);

  final Ref ref;
  Timer? _debounce;
  bool _applying = false;

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  String? get _userId => ref.read(userProvider)?.id;

  /// Per account, so two people sharing a device never overwrite each other's settings.
  String get _stampKey => 'settingsSyncedAt_$_userId';

  /// Run after sign-in: take the server's settings if they're newer, otherwise upload ours.
  Future<void> pull() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final api = ref.read(jellyApiProvider).api;
      final response = await api.displayPreferencesDisplayPreferencesIdGet(
          displayPreferencesId: _prefsId, userId: userId, $client: _client);
      final remote = response.body?.customPrefs ?? const {};
      final remoteStamp = int.tryParse('${remote['updated'] ?? ''}') ?? 0;
      final localStamp = _prefs.getInt(_stampKey) ?? 0;

      if (remoteStamp > localStamp) {
        _apply(remote, remoteStamp);
      } else if (localStamp > remoteStamp || remote.isEmpty) {
        await _upload();
      }
    } catch (e) {
      log('Settings sync: could not fetch settings: $e');
    }
  }

  /// Called whenever a shared setting changes; uploads once things settle.
  void scheduleUpload() {
    if (_applying || _userId == null) return;
    _prefs.setInt(_stampKey, DateTime.now().millisecondsSinceEpoch);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), _upload);
  }

  void _apply(Map<String, dynamic> remote, int stamp) {
    _applying = true;
    try {
      for (final key in _syncedKeys) {
        final value = remote[key];
        if (value is! String) continue;
        if (key == 'downloadSubtitles') {
          _prefs.setBool(key, value == 'true');
          ref.read(downloadSubtitlesProvider.notifier).state = value == 'true';
        } else if (_deviceOnly.containsKey(key)) {
          _prefs.setString(key, _keepDeviceOnly(key, value));
        } else {
          _prefs.setString(key, value);
        }
      }
      _prefs.setInt(_stampKey, stamp);
      ref.read(sharedUtilityProvider).loadSettings();
    } finally {
      _applying = false;
    }
  }

  /// The server's copy of a setting, with this device's device-only fields put back.
  String _keepDeviceOnly(String key, String remoteJson) {
    final local = _prefs.getString(key);
    final localMap = local != null ? jsonDecode(local) as Map : const {};
    final merged = Map<String, dynamic>.from(jsonDecode(remoteJson) as Map);
    for (final field in _deviceOnly[key]!) {
      if (localMap.containsKey(field)) {
        merged[field] = localMap[field];
      } else {
        merged.remove(field);
      }
    }
    return jsonEncode(merged);
  }

  Future<void> _upload() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final stamp = _prefs.getInt(_stampKey) ?? DateTime.now().millisecondsSinceEpoch;
      _prefs.setInt(_stampKey, stamp);
      final values = <String, dynamic>{'updated': '$stamp'};
      for (final key in _syncedKeys) {
        final value = key == 'downloadSubtitles' ? _prefs.getBool(key)?.toString() : _prefs.getString(key);
        if (value != null) values[key] = value;
      }
      final api = ref.read(jellyApiProvider).api;
      final current = await api.displayPreferencesDisplayPreferencesIdGet(
          displayPreferencesId: _prefsId, userId: userId, $client: _client);
      final body = current.body;
      if (body == null) return;
      await api.displayPreferencesDisplayPreferencesIdPost(
        displayPreferencesId: _prefsId,
        userId: userId,
        $client: _client,
        body: body.copyWith(customPrefs: values),
      );
    } catch (e) {
      log('Settings sync: could not upload settings: $e');
    }
  }

  void dispose() => _debounce?.cancel();
}
