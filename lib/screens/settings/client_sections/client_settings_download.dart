import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync/auto_sync_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/screens/settings/widgets/settings_label_divider.dart';
import 'package:fladder/screens/settings/widgets/settings_list_group.dart';
import 'package:fladder/screens/shared/default_alert_dialog.dart';
import 'package:fladder/models/syncing/transcode_download_model.dart';
import 'package:fladder/widgets/shared/item_actions.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/size_formatting.dart';

List<Widget> buildClientSettingsDownload(BuildContext context, WidgetRef ref, Function setState) {
  final clientSettings = ref.watch(clientSettingsProvider);
  final currentFolder = ref.watch(syncProvider.notifier).savePath;
  final canSync = ref.watch(userProvider.select((value) => value?.canDownload ?? false));

  return [
    if (canSync && !kIsWeb) ...[
      ...settingsListGroup(
        context,
        SettingsLabelDivider(label: context.localized.downloadsTitle),
        [
          if (AdaptiveLayout.of(context).isDesktop) ...[
            SettingsListTile(
              label: Text(context.localized.downloadsPath),
              subLabel: Text(currentFolder ?? "-"),
              onTap: currentFolder != null
                  ? () async => await showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(context.localized.pathEditTitle),
                          content: Text(context.localized.pathEditDesc),
                          actions: [
                            ElevatedButton(
                              onPressed: () async {
                                String? selectedDirectory = await FilePicker.getDirectoryPath(
                                    dialogTitle: context.localized.pathEditSelect, initialDirectory: currentFolder);
                                if (selectedDirectory != null) {
                                  await ref.read(clientSettingsProvider.notifier).setSyncPath(selectedDirectory);
                                }
                                Navigator.of(context).pop();
                              },
                              child: Text(context.localized.change),
                            )
                          ],
                        ),
                      )
                  : () async {
                      String? selectedDirectory = await FilePicker.getDirectoryPath(
                          dialogTitle: context.localized.pathEditSelect, initialDirectory: currentFolder);
                      if (selectedDirectory != null) {
                        ref.read(clientSettingsProvider.notifier).setSyncPath(selectedDirectory);
                      }
                    },
              trailing: currentFolder?.isNotEmpty == true
                  ? IconButton(
                      color: Theme.of(context).colorScheme.error,
                      onPressed: () async => await showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(context.localized.pathClearTitle),
                          content: Text(context.localized.pathEditDesc),
                          actions: [
                            ElevatedButton(
                              onPressed: () {
                                ref.read(clientSettingsProvider.notifier).setSyncPath(null);
                                Navigator.of(context).pop();
                              },
                              child: Text(context.localized.clear),
                            )
                          ],
                        ),
                      ),
                      icon: const Icon(IconsaxPlusLinear.folder_minus),
                    )
                  : null,
            ),
          ],
          FutureBuilder(
            future: ref.watch(syncProvider.notifier).directorySize,
            builder: (context, snapshot) {
              final data = snapshot.data ?? 0;
              return SettingsListTile(
                label: Text(context.localized.downloadsSyncedData),
                subLabel: Text(data.byteFormat ?? ""),
                onTap: () {
                  showDefaultAlertDialog(
                    context,
                    context.localized.downloadsClearTitle,
                    context.localized.downloadsClearDesc,
                    (context) async {
                      await ref.read(syncProvider.notifier).removeAllSyncedData();
                      setState(() {});
                      Navigator.of(context).pop();
                    },
                    context.localized.clear,
                    (context) => Navigator.of(context).pop(),
                    context.localized.cancel,
                  );
                },
                trailing: FilledButton(
                  onPressed: () {
                    showDefaultAlertDialog(
                      context,
                      context.localized.downloadsClearTitle,
                      context.localized.downloadsClearDesc,
                      (context) async {
                        await ref.read(syncProvider.notifier).removeAllSyncedData();
                        setState(() {});
                        Navigator.of(context).pop();
                      },
                      context.localized.clear,
                      (context) => Navigator.of(context).pop(),
                      context.localized.cancel,
                    );
                  },
                  child: Text(context.localized.clear),
                ),
              );
            },
          ),
          SettingsListTile(
            label: Text(context.localized.clientSettingsRequireWifiTitle),
            subLabel: Text(context.localized.clientSettingsRequireWifiDesc),
            onTap: () => ref.read(clientSettingsProvider.notifier).setRequireWifi(!clientSettings.requireWifi),
            trailing: Switch(
              value: clientSettings.requireWifi,
              onChanged: (value) => ref.read(clientSettingsProvider.notifier).setRequireWifi(value),
            ),
          ),
          SettingsListTileEnum(
            leading: const Icon(IconsaxPlusLinear.video_octagon),
            label: const Text('Download quality'),
            subLabel: const Text('Original keeps the full file. Lower takes less space.'),
            current: clientSettings.transcodeDownloadModel.quality.label,
            itemBuilder: (context) => DownloadQuality.values
                .map((quality) => ItemActionButton(
                      selected: clientSettings.transcodeDownloadModel.quality == quality,
                      label: Text(quality.label),
                      action: () => ref
                          .read(clientSettingsProvider.notifier)
                          .update((current) => current.copyWith(transcodeDownloadModel: quality.model)),
                    ))
                .toList(),
          ),
          SettingsListTile(
            leading: const Icon(IconsaxPlusLinear.subtitle),
            label: const Text('Include subtitles'),
            subLabel: const Text('Save subtitles with each download'),
            onTap: () => setDownloadSubtitles(ref, !ref.read(downloadSubtitlesProvider)),
            trailing: Switch(
              value: ref.watch(downloadSubtitlesProvider),
              onChanged: (value) => setDownloadSubtitles(ref, value),
            ),
          ),
          SettingsListTile(
            leading: const Icon(IconsaxPlusLinear.trash),
            label: const Text("Auto-delete watched episodes"),
            subLabel: const Text("Remove the download once you finish an episode"),
            onTap: () => ref
                .read(clientSettingsProvider.notifier)
                .update((c) => c.copyWith(autoDeleteWatched: !clientSettings.autoDeleteWatched)),
            trailing: Switch(
              value: clientSettings.autoDeleteWatched,
              onChanged: (value) =>
                  ref.read(clientSettingsProvider.notifier).update((c) => c.copyWith(autoDeleteWatched: value)),
            ),
          ),
          SettingsListTile(
            leading: const Icon(IconsaxPlusLinear.import_1),
            label: const Text("Auto-download next episodes"),
            subLabel: const Text("Keep upcoming episodes of shows you're watching downloaded"),
            onTap: () => ref
                .read(clientSettingsProvider.notifier)
                .update((c) => c.copyWith(autoDownloadNextEpisodes: !clientSettings.autoDownloadNextEpisodes)),
            trailing: Switch(
              value: clientSettings.autoDownloadNextEpisodes,
              onChanged: (value) {
                ref.read(clientSettingsProvider.notifier).update((c) => c.copyWith(autoDownloadNextEpisodes: value));
                if (value) ref.read(autoSyncProvider).downloadNextEpisodes();
              },
            ),
          ),
          if (clientSettings.autoDownloadNextEpisodes)
            SettingsListTile(
              leading: const Icon(IconsaxPlusLinear.layer),
              label: const Text("Episodes to keep ready"),
              subLabel: const Text("Per show, starting from your next episode"),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(IconsaxPlusLinear.minus_cirlce),
                    onPressed: clientSettings.autoDownloadEpisodeCount <= 1
                        ? null
                        : () => ref
                            .read(clientSettingsProvider.notifier)
                            .update((c) => c.copyWith(autoDownloadEpisodeCount: c.autoDownloadEpisodeCount - 1)),
                  ),
                  Text("${clientSettings.autoDownloadEpisodeCount}", style: Theme.of(context).textTheme.titleMedium),
                  IconButton(
                    icon: const Icon(IconsaxPlusLinear.add_circle),
                    onPressed: clientSettings.autoDownloadEpisodeCount >= 10
                        ? null
                        : () => ref
                            .read(clientSettingsProvider.notifier)
                            .update((c) => c.copyWith(autoDownloadEpisodeCount: c.autoDownloadEpisodeCount + 1)),
                  ),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
    ],
  ];
}
