import 'dart:developer';

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';

/// Auto-delete watched episodes + keep the next N episodes of in-progress shows downloaded.
final autoSyncProvider = Provider<AutoSync>((ref) {
  final autoSync = AutoSync(ref);
  ref.listen(connectivityStatusProvider, (previous, next) {
    if (previous == ConnectionState.offline && next != ConnectionState.offline) autoSync.downloadNextEpisodes();
  });
  // Top up at start-up too (covers episodes watched on another device).
  Future(autoSync.downloadNextEpisodes);
  return autoSync;
});

class AutoSync {
  AutoSync(this.ref);

  final Ref ref;
  bool _running = false;

  Future<void> onPlaybackStopped(ItemBaseModel item, Duration position, Duration? total) async {
    if (item is! EpisodeModel || ref.read(incognitoModeProvider)) return;
    // A zero length (stopped while loading) must not count as "watched": fall back to the runtime.
    final length = (total != null && total > Duration.zero) ? total : (item.overview.runTime ?? Duration.zero);
    if (length <= Duration.zero) return;
    final played = UserData.isPlayed(position, length) ?? false;
    if (!played) return;

    if (ref.read(clientSettingsProvider).autoDeleteWatched) {
      final sync = ref.read(syncProvider.notifier);
      final synced = await sync.getSyncedItem(item.id);
      try {
        if (synced != null && await synced.videoFile.exists()) {
          await sync.deleteFullSyncFiles(synced, null);
        }
      } catch (e) {
        log('Auto delete failed: $e');
      }
    }
    await downloadNextEpisodes(alsoSeriesId: item.parentBaseModel.id);
  }

  /// Tops up only shows that already have downloads (plus [alsoSeriesId], the show just watched), so
  /// switching this on never pulls every show in Next Up.
  Future<void> downloadNextEpisodes({String? alsoSeriesId}) async {
    final settings = ref.read(clientSettingsProvider);
    if (kIsWeb || _running || !settings.autoDownloadNextEpisodes) return;
    if (!(ref.read(userProvider)?.canDownload ?? false)) return;
    if (ref.read(connectivityStatusProvider) == ConnectionState.offline) return;

    _running = true;
    try {
      final api = ref.read(jellyApiProvider);
      final sync = ref.read(syncProvider.notifier);
      // Push offline watch state first so Next Up doesn't hand back episodes we just finished.
      await sync.updateSyncStates();
      final nextUp = (await api.showsNextUpGet(
            limit: 20,
            enableUserData: true,
            nextUpDateCutoff: DateTime.now().subtract(const Duration(days: 28)),
          ))
              .body
              ?.items ??
          [];

      for (final next in nextUp) {
        if (next.seriesId == null) continue;
        if (next.seriesId != alsoSeriesId && await sync.getSyncedItem(next.seriesId) == null) continue;
        final episodes =
            (await api.showsSeriesIdEpisodesGet(seriesId: next.seriesId, isMissing: false, enableUserData: true))
                    .body
                    ?.items ??
                [];
        final start = episodes.indexWhere((e) => e.id == next.id);
        if (start < 0) continue;

        final missing = <String>{};
        for (final ep in episodes.skip(start).take(settings.autoDownloadEpisodeCount)) {
          // Watched (possibly offline, not yet synced to the server): never re-download what was just deleted.
          if (ep.userData?.played == true) continue;
          final synced = await sync.getSyncedItem(ep.id);
          if (synced?.userData?.played == true) continue;
          final downloading = ref.read(downloadTasksProvider(ep.id)).task != null;
          if (!downloading && (synced == null || !await synced.videoFile.exists())) missing.add(ep.id!);
        }
        if (missing.isEmpty) continue;

        final episode = ItemBaseModel.fromBaseDto(next, ref);
        if (episode is! EpisodeModel) continue;
        await sync.syncSeries(episode.parentBaseModel, episodeIds: missing);
      }
    } catch (e) {
      log('Auto download failed: $e');
    } finally {
      _running = false;
    }
  }
}
