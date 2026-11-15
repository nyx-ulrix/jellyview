import 'package:flutter/material.dart';

import 'package:flutter_blurhash/flutter_blurhash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/providers/dashboard_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/screens/settings/client_sections/client_settings_theme.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/screens/video_player/components/video_subtitle_controls.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/widgets/shared/fladder_slider.dart';

/// One place for how the app looks. Every control applies instantly, and the preview pinned at the
/// top shows the result (posters, accent colour and a subtitle line) while you change it.
class CustomizePage extends ConsumerWidget {
  const CustomizePage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CustomizePage()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clientSettings = ref.watch(clientSettingsProvider);
    final showBanner = ref.watch(homeSettingsProvider.select((value) => value.homeBanner)) != HomeBanner.hide;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Customize')),
      body: Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
            child: const SingleChildScrollView(child: _Preview()),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                ...buildClientSettingsTheme(context, ref),
                _Heading('Home', theme),
                SettingsListTile(
                  label: const Text('Show slideshow'),
                  subLabel: const Text('The big rotating banner at the top of Home'),
                  onTap: () => ref
                      .read(homeSettingsProvider.notifier)
                      .update((s) => s.copyWith(homeBanner: showBanner ? HomeBanner.hide : HomeBanner.banner)),
                  trailing: Switch(
                    value: showBanner,
                    onChanged: (on) => ref
                        .read(homeSettingsProvider.notifier)
                        .update((s) => s.copyWith(homeBanner: on ? HomeBanner.banner : HomeBanner.hide)),
                  ),
                ),
                SettingsListTile(
                  label: const Text('Poster size'),
                  trailing: Text('${(clientSettings.posterSize * 100).round()}%', style: theme.textTheme.bodyLarge),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: FladderSlider(
                    min: 0.5,
                    max: 1.5,
                    divisions: 20,
                    value: clientSettings.posterSize,
                    onChanged: (value) =>
                        ref.read(clientSettingsProvider.notifier).update((c) => c.copyWith(posterSize: value)),
                  ),
                ),
                _Heading('Subtitles', theme),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: VideoSubtitleControls(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final ThemeData theme;
  const _Heading(this.text, this.theme);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(text, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
      );
}

class _Preview extends ConsumerWidget {
  const _Preview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final posterSize = ref.watch(clientSettingsProvider.select((value) => value.posterSize));
    final subtitles = ref.watch(subtitleSettingsProvider);
    final home = ref.watch(dashboardProvider);
    // Real artwork from Home when it's loaded; plain tiles otherwise.
    final List<ItemBaseModel?> posters = [...home.nextUp, ...home.resumeVideo].take(4).toList();
    while (posters.length < 4) {
      posters.add(null);
    }
    final posterWidth = 84 * posterSize;

    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text('Preview', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          SizedBox(
            height: posterWidth * 1.5,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: posters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: posterWidth,
                  child: posters[i]?.getPosters?.primary != null
                      ? FladderImage(image: posters[i]!.getPosters!.primary, fit: BoxFit.cover)
                      : ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                ),
              ),
            ),
          ),
          Row(
            spacing: 8,
            children: [
              FilledButton.icon(
                  onPressed: () {}, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play')),
              OutlinedButton(onPressed: () {}, child: const Text('My List')),
            ],
          ),
          // A frame of "video" with a subtitle line drawn exactly as the player will draw it.
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 21 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const Image(image: BlurHashImage('LEF}}|0000~p8w~W%N4n~pIU4o%g'), fit: BoxFit.cover),
                  SubtitleText(
                    subModel: subtitles,
                    padding: EdgeInsets.zero,
                    offset: subtitles.verticalOffset,
                    text: 'This is how subtitles will look.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
