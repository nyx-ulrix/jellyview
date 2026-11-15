import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/widget/markdown.dart';

import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/screens/shared/media/external_urls.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/update_checker.dart';

enum _Phase { idle, checking, downloading, ready }

/// One card, three steps: Check for updates -> Download (with progress) -> Install.
class SettingsUpdateInformation extends ConsumerStatefulWidget {
  const SettingsUpdateInformation({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SettingsUpdateInformationState();
}

class _SettingsUpdateInformationState extends ConsumerState<SettingsUpdateInformation> {
  _Phase phase = _Phase.idle;
  int received = 0;
  int? total;
  File? apk;
  String? note;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _markSeen());
  }

  void _markSeen() {
    final latest = ref.read(updateProvider).latestRelease;
    if (latest == null) return;
    if (ref.read(clientSettingsProvider).lastViewedUpdate != latest.version) {
      ref.read(clientSettingsProvider.notifier).update((value) => value.copyWith(lastViewedUpdate: latest.version));
    }
  }

  Future<void> _check() async {
    setState(() {
      phase = _Phase.checking;
      note = null;
    });
    final releases = await ref.read(updateProvider.notifier).checkNow();
    if (!mounted) return;
    final latest = ref.read(updateProvider).latestRelease;
    setState(() {
      phase = _Phase.idle;
      note = releases.isEmpty
          ? "Couldn't reach GitHub. Check your connection and try again."
          : latest == null
              ? "You're on the latest version."
              : null;
    });
    _markSeen();
  }

  Future<void> _download(ReleaseInfo release) async {
    final url = release.downloadUrlFor('android');
    if (kIsWeb || !Platform.isAndroid || url == null) return launchUrl(context, release.url);
    setState(() {
      phase = _Phase.downloading;
      received = 0;
      total = null;
      note = null;
    });
    try {
      final file = await downloadAndroidUpdate(url, (got, size) {
        if (mounted)
          setState(() {
            received = got;
            total = size;
          });
      });
      if (!mounted) return;
      setState(() {
        phase = _Phase.ready;
        apk = file;
      });
      await _install();
    } catch (e) {
      if (mounted)
        setState(() {
          phase = _Phase.idle;
          note = 'Download failed: $e';
        });
    }
  }

  Future<void> _install() async {
    try {
      await openAndroidInstaller(apk!);
    } catch (e) {
      if (mounted) setState(() => note = 'Could not start the installer: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final latest = ref.watch(updateProvider.select((value) => value.latestRelease));
    final autoCheck = ref.watch(clientSettingsProvider.select((value) => value.checkForUpdates));
    final current = ref.watch(applicationInfoProvider).version;

    final (title, subtitle) = switch (phase) {
      _Phase.downloading => ('Downloading ${latest?.version ?? 'update'}', _progressText()),
      _Phase.ready => ('Ready to install ${latest?.version ?? ''}', 'Your settings and downloads are kept.'),
      _ when latest != null => ('Update available: ${latest.version}', 'You have $current'),
      _ => ('JellyView $current', 'Check GitHub for a newer beta.'),
    };

    final Widget button = switch (phase) {
      _Phase.checking => const FilledButton(onPressed: null, child: Text('Checking…')),
      _Phase.downloading => const FilledButton(onPressed: null, child: Text('Downloading…')),
      _Phase.ready => FilledButton.icon(
          onPressed: _install, icon: const Icon(Icons.install_mobile_rounded), label: const Text('Install')),
      _ when latest != null => FilledButton.icon(
          onPressed: () => _download(latest),
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download and install'),
        ),
      _ => FilledButton.tonalIcon(
          onPressed: _check, icon: const Icon(Icons.refresh_rounded), label: const Text('Check for updates')),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    Text(subtitle, style: muted),
                  ],
                ),
                if (phase == _Phase.downloading)
                  LinearProgressIndicator(
                    value: total != null && total! > 0 ? received / total! : null,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                button,
                if (note != null)
                  Text(note!,
                      style: note!.startsWith('Download failed') ||
                              note!.startsWith('Could not') ||
                              note!.startsWith("Couldn't")
                          ? muted?.copyWith(color: theme.colorScheme.error)
                          : muted),
              ],
            ),
          ),
        ),
        if (latest != null && latest.changelog.isNotEmpty)
          ExpansionTile(
            title: const Text("What's new"),
            shape: const Border(),
            collapsedShape: const Border(),
            childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [MarkdownWidget(data: latest.changelog, shrinkWrap: true)],
          ),
        SettingsListTile(
          label: const Text('Check automatically'),
          subLabel: Text(context.localized.autoCheckForUpdates),
          onTap: () =>
              ref.read(clientSettingsProvider.notifier).update((value) => value.copyWith(checkForUpdates: !autoCheck)),
          trailing: Switch(
            value: autoCheck,
            onChanged: (value) =>
                ref.read(clientSettingsProvider.notifier).update((v) => v.copyWith(checkForUpdates: value)),
          ),
        ),
      ],
    );
  }

  String _progressText() {
    String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
    if (total == null || total! <= 0) return '${mb(received)} MB';
    return '${(received / total! * 100).round()}%  ·  ${mb(received)} of ${mb(total!)} MB';
  }
}
