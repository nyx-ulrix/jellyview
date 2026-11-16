import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/providers/sync/sync_provider_helpers.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';

/// Episodes the user asked to download that haven't started downloading yet (still being prepared or
/// waiting in line). Lets the button react the instant it's tapped while the work happens in the background.
final pendingDownloadsProvider = StateProvider<Set<String>>((ref) => {});

/// Queue episodes of [series] for download without blocking: they show as "preparing" straight away.
void queueEpisodeDownloads(WidgetRef ref, SeriesModel series, Set<String> ids, {ScaffoldMessengerState? messenger}) {
  if (ids.isEmpty) return;
  final pending = ref.read(pendingDownloadsProvider.notifier);
  pending.update((state) => {...state, ...ids});
  void release() => pending.update((state) => state.difference(ids));
  unawaited(ref.read(syncProvider.notifier).syncSeries(series, episodeIds: ids).then((started) {
    if (started == null) {
      release();
      messenger
          ?.showSnackBar(const SnackBar(content: Text("Couldn't start the download. Check Settings > Downloads.")));
    }
  }).catchError((Object e) {
    release();
    messenger?.showSnackBar(SnackBar(content: Text('Download failed: $e')));
  }));
  // Safety net: if a download never actually starts, don't leave the button spinning forever.
  Timer(const Duration(minutes: 3), release);
}

/// Download button for one episode, with four states:
/// ready (download icon), preparing (spinning ring), downloading (a ring drawn around the button as it
/// progresses) and done (tick).
class EpisodeDownloadButton extends ConsumerWidget {
  final EpisodeModel episode;
  const EpisodeDownloadButton({required this.episode, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canDownload = episode.syncAble && (ref.watch(userProvider.select((u) => u?.canDownload)) ?? false);
    if (!canDownload) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final synced = ref.watch(syncedItemProvider(episode)).value;
    final stream = ref.watch(downloadTasksProvider(episode.id));
    final pending = ref.watch(pendingDownloadsProvider.select((ids) => ids.contains(episode.id)));

    Widget ring({double? value}) => SizedBox.square(
          dimension: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: value,
                strokeWidth: 2.5,
                color: scheme.primary,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
              ),
              Icon(IconsaxPlusLinear.import_3, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        );

    // The file must really be on the device: older builds recorded every episode of a show without downloading it.
    if (synced != null && synced.hasVideoFile && synced.videoFile.existsSync()) {
      return IconButton(
        tooltip: 'Downloaded',
        onPressed: () {}, // catches the tap so the row doesn't open the episode
        icon: Icon(IconsaxPlusBold.tick_circle, color: scheme.primary),
      );
    }
    if (stream.task != null) {
      // Downloading: the ring is drawn round the button as the file arrives (spins while still queued).
      return IconButton(
          tooltip: 'Downloading', padding: EdgeInsets.zero, onPressed: () {}, icon: ring(value: stream.progress));
    }
    if (pending) {
      return IconButton(tooltip: 'Getting ready', padding: EdgeInsets.zero, onPressed: () {}, icon: ring());
    }
    return IconButton(
      tooltip: 'Download',
      icon: const Icon(IconsaxPlusLinear.import_3),
      onPressed: () => queueEpisodeDownloads(ref, episode.parentBaseModel, {episode.id},
          messenger: ScaffoldMessenger.maybeOf(context)),
    );
  }
}
