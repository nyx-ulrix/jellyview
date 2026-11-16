import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:background_downloader/background_downloader.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/models/syncing/download_stream.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/util/localization_helper.dart';

part 'background_download_provider.g.dart';

final itemDownloadGroup = "ITEM_DOWNLOAD_GROUP";

@Riverpod(keepAlive: true)
class BackgroundDownloader extends _$BackgroundDownloader {
  late StreamSubscription<TaskUpdate> updateListener;

  @override
  FileDownloader build() {
    ref.onDispose(
      () => updateListener.cancel(),
    );

    final maxDownloads = ref.read(clientSettingsProvider.select((value) => value.maxConcurrentDownloads));
    final downloader = FileDownloader()
      ..configure(
        globalConfig: globalConfig(maxDownloads),
        androidConfig: (Config.runInForeground, Config.always),
      )
      ..trackTasks();
    updateListener = downloader.updates.listen(updateTask);
    return downloader;
  }

  void updateTask(TaskUpdate update) {
    switch (update) {
      case TaskStatusUpdate():
        final status = update.status;
        ref.read(downloadTasksProvider(update.task.taskId).notifier).update(
              (state) => state.copyWith(status: status),
            );

        // Any finished state (done, cancelled, failed, gone) leaves the active list, so the badge can't get stuck.
        // Only the exact task that finished: a re-download reuses the taskId, and the old task's late
        // "canceled" must not clear the new one or delete its temp file.
        if (status.isFinalState) {
          final active = ref.read(activeDownloadTasksProvider);
          bool sameTask(DownloadTask t) => t.taskId == update.task.taskId && t.creationTime == update.task.creationTime;
          if (active.any(sameTask)) {
            ref.read(activeDownloadTasksProvider.notifier).state = active.where((t) => !sameTask(t)).toList();
            ref.read(downloadTasksProvider(update.task.taskId).notifier).update((state) => DownloadStream.empty());
            ref.read(syncProvider.notifier).cleanupTemporaryFiles();
          }
        }
      case TaskProgressUpdate():
        final progress = update.progress;
        ref.read(downloadTasksProvider(update.task.taskId).notifier).update(
              (state) => state.copyWith(
                progress: progress > 0 && progress < 1 ? progress : null,
                downloadSpeed: update.networkSpeedAsString,
              ),
            );
    }
  }

  void setMaxConcurrent(int value) {
    state.configure(
      globalConfig: globalConfig(value),
      androidConfig: (Config.runInForeground, Config.always),
    );
  }

  void updateTranslations(BuildContext context) async {
    if (kIsWeb) return;
    state.configureNotification(
      running: TaskNotification(context.localized.notificationDownloadingDownloading, '{filename}\n{networkSpeed}'),
      complete: TaskNotification(context.localized.notificationDownloadingFinished, '{filename}'),
      paused: TaskNotification(context.localized.notificationDownloadingPaused, '{filename}'),
      error: TaskNotification(context.localized.notificationDownloadingError, '{filename}'),
      progressBar: true,
    );
  }

  /// Phones and tablets: no holding queue. That queue lives inside the app, so downloads waiting their turn
  /// only started while the app was open; without it every download is handed to Android at once and its
  /// scheduler runs them a few at a time in the background, app open or not.
  dynamic globalConfig(int value) => !kIsWeb && (Platform.isAndroid || Platform.isIOS)
      ? (Config.holdingQueue, (null, null, null))
      : _desktopQueue(value);

  (String, dynamic) _desktopQueue(int value) => value == 0
      ? (
          Config.holdingQueue,
          (
            null,
            null,
            null,
          )
        )
      : (
          Config.holdingQueue,
          (
            //maxConcurrent
            value,
            //maxConcurrentByHost
            value,
            //maxConcurrentByGroup
            value,
          ),
        );
}
