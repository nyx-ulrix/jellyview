import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/season_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/sync/sync_provider_helpers.dart';
import 'package:fladder/screens/shared/media/episode_download_button.dart';
import 'package:fladder/screens/syncing/sync_button.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';
import 'package:fladder/util/list_padding.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/refresh_state.dart';
import 'package:fladder/widgets/shared/focus_row.dart';
import 'package:fladder/widgets/shared/horizontal_list.dart';
import 'package:fladder/widgets/shared/item_actions.dart';
import 'package:fladder/widgets/shared/modal_bottom_sheet.dart';
import 'package:fladder/widgets/shared/status_card.dart';

class EpisodePosters extends ConsumerStatefulWidget {
  final List<EpisodeModel> episodes;
  final List<SeasonModel> seasons;
  final String? label;
  final VerticalDirection? titleActionsPosition;
  final ValueChanged<EpisodeModel> playEpisode;
  final EdgeInsets contentPadding;
  final EpisodeModel? selectedEpisode;
  final Function(VoidCallback action, EpisodeModel episodeModel)? onEpisodeTap;
  final Function(EpisodeModel selected)? onFocused;
  final double revealAlignment;

  /// Touch/pointer: Netflix-style vertical list (thumbnail + title + synopsis) where a tap plays the episode.
  final bool vertical;
  const EpisodePosters({
    this.vertical = false,
    this.label,
    this.titleActionsPosition = VerticalDirection.up,
    required this.contentPadding,
    required this.playEpisode,
    required this.episodes,
    this.seasons = const [],
    this.onEpisodeTap,
    this.selectedEpisode,
    this.onFocused,
    this.revealAlignment = 0.5,
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _EpisodePosterState();
}

class _EpisodePosterState extends ConsumerState<EpisodePosters> with EpisodePicker<EpisodePosters> {
  late int? selectedSeason = widget.episodes.nextUp?.season ?? widget.episodes.firstOrNull?.season;

  final FocusNode seasonFocusNode = FocusNode();

  /// Row of the next episode to watch; the page opens scrolled to it.
  final nextUpKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.vertical) {
      // Let the page settle for a moment, then glide (not jump) down to the next episode, so it's clear
      // where you've landed and that earlier episodes are a scroll up away.
      Future.delayed(const Duration(milliseconds: 120), () {
        final row = nextUpKey.currentContext;
        // Only on a fresh page: never yank the view while the user is already scrolling.
        if (row != null && row.mounted && (Scrollable.maybeOf(row)?.position.pixels ?? 0) == 0) {
          // Lands just under the top buttons.
          Scrollable.ensureVisible(
            row,
            alignment: 0.12,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  List<EpisodeModel> get episodes {
    if (selectedSeason == null) {
      return widget.episodes;
    } else {
      return widget.episodes.where((element) => element.season == selectedSeason).toList();
    }
  }

  @override
  void dispose() {
    seasonFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexOfCurrent = (episodes.nextUp != null ? episodes.indexOf(episodes.nextUp!) : 0).clamp(0, episodes.length);
    final episodesBySeason = widget.episodes.episodesBySeason;
    final allPlayed = episodes.allPlayed;

    final isDPad = AdaptiveLayout.inputDeviceOf(context) == InputDevice.dPad;

    final constructSeasonNames = <int, String>{
      for (final entry in episodesBySeason.entries)
        entry.key: () {
          if (widget.seasons.isNotEmpty) {
            final season = widget.seasons.firstWhereOrNull((element) => element.season == entry.key);
            if (season != null) {
              return season.name;
            }
          }
          return "${context.localized.season(1)} ${entry.key}";
        }()
    };

    final hasSeasons = episodesBySeason.isNotEmpty && episodesBySeason.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        if (picked.isNotEmpty) selectionBar(widget.contentPadding, episodes),
        // Touch/pointer: one row of season chips above the episodes, Netflix-style, instead of a dropdown under them.
        if (!isDPad && hasSeasons)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: widget.contentPadding,
            child: Row(
              spacing: 8,
              children: [
                for (final e in episodesBySeason.entries)
                  ChoiceChip(
                    label: Text(constructSeasonNames[e.key] ?? "${context.localized.season(1)} ${e.key}"),
                    selected: selectedSeason == e.key,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => selectedSeason = e.key),
                  ),
              ],
            ),
          ),
        if (widget.vertical && !isDPad && (ref.watch(userProvider.select((u) => u?.canDownload)) ?? false))
          Builder(builder: (context) {
            final unwatched =
                episodes.where((e) => !e.userData.played && e.playAble && e.syncAble).map((e) => e.id).toSet();
            if (unwatched.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: widget.contentPadding,
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(IconsaxPlusLinear.import_3, size: 18),
                  label: Text('Download unwatched (${unwatched.length})'),
                  onPressed: () => queueEpisodeDownloads(ref, episodes.first.parentBaseModel, unwatched,
                      messenger: ScaffoldMessenger.maybeOf(context)),
                ),
              ),
            );
          }),
        if (widget.vertical && !isDPad)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!hasSeasons && widget.label != null)
                Padding(
                  padding: widget.contentPadding,
                  child: Text(widget.label!, style: Theme.of(context).textTheme.titleLarge),
                ),
              for (final episode in episodes)
                _EpisodeRow(
                  key: episode == episodes.nextUp ? nextUpKey : null,
                  episode: episode,
                  padding: widget.contentPadding,
                  isCurrent: widget.selectedEpisode == episode,
                  selected: picked.contains(episode),
                  onTap: picked.isNotEmpty
                      ? () => togglePick(episode)
                      : episode.playAble
                          ? () => widget.playEpisode(episode)
                          : () => episode.navigateTo(context),
                  onLongPress: () => togglePick(episode),
                  actions: episode.generateActions(context, ref),
                ),
            ],
          )
        else
          HorizontalList(
            label: !isDPad && hasSeasons ? null : widget.label,
            titleActionsPosition: widget.titleActionsPosition,
            revealAlignment: widget.revealAlignment,
            onFocused: (index) {
              widget.onFocused?.call(episodes[index]);
            },
            contentPadding: widget.contentPadding,
            startIndex: indexOfCurrent,
            items: episodes,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              final tag = UniqueKey();
              return EpisodePoster(
                episode: episode,
                heroTag: tag,
                blur: allPlayed ? false : indexOfCurrent < index,
                onTap: picked.isNotEmpty
                    ? () => togglePick(episode)
                    : widget.onEpisodeTap != null
                        ? () {
                            widget.onEpisodeTap?.call(
                              () {
                                episode.navigateTo(context, tag: tag);
                              },
                              episode,
                            );
                          }
                        : () {
                            episode.navigateTo(context, tag: tag);
                          },
                onLongPress: () async {
                  if (AdaptiveLayout.inputDeviceOf(context) == InputDevice.touch) return togglePick(episode);
                  await showBottomSheetPill(
                    context: context,
                    item: episode,
                    content: (context, scrollController) {
                      return ListView(
                        shrinkWrap: true,
                        controller: scrollController,
                        children: episode.generateActions(context, ref).listTileItems(context, useIcons: true).toList(),
                      );
                    },
                  );
                  context.refreshData();
                },
                actions: episode.generateActions(context, ref),
                isCurrentEpisode: widget.selectedEpisode == episode || picked.contains(episode),
              );
            },
          ),
        if (isDPad && hasSeasons)
          FocusRow(
            focusNode: seasonFocusNode,
            child: Container(
              padding: widget.contentPadding,
              height: 40,
              child: Row(
                spacing: 8,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Builder(builder: (context) {
                        return Row(
                          children: [
                            ItemActionButton(
                              selected: selectedSeason == null,
                              label: Text(context.localized.all),
                              action: () => setState(() => selectedSeason = null),
                            ),
                            ...episodesBySeason.entries.map(
                              (e) => ItemActionButton(
                                selected: selectedSeason == e.key,
                                label: Text(constructSeasonNames[e.key] ?? "${context.localized.season(1)} ${e.key}"),
                                action: () {
                                  setState(() => selectedSeason = e.key);
                                },
                              ),
                            ),
                          ]
                              .groupButtons(
                                context,
                                useIcons: true,
                                shouldPop: false,
                              )
                              .addInBetween(
                                const SizedBox(width: 12),
                              ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _EpisodeRow extends ConsumerWidget {
  final EpisodeModel episode;
  final EdgeInsets padding;
  final bool isCurrent;

  /// Picked in multi-select: the whole row is highlighted.
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final List<ItemAction> actions;

  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.padding,
    required this.isCurrent,
    this.selected = false,
    required this.onTap,
    required this.onLongPress,
    required this.actions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final runTime = episode.overview.runTime;
    // Phones: synopsis full width under the thumbnail row (Netflix mobile); wider screens: beside it.
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final Widget synopsis = episode.overview.summary.isEmpty
        ? const SizedBox.shrink()
        : Text(
            episode.overview.summary,
            maxLines: wide ? 4 : 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.35),
          );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.22) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // Watched episodes are greyed out but stay tappable (a picked one shows at full strength).
        child: Opacity(
          opacity: episode.userData.played && !selected ? 0.45 : 1,
          child: Padding(
            padding: padding.copyWith(top: 12, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Row(
                  crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                  spacing: 12,
                  children: [
                    SizedBox(
                      width: (MediaQuery.sizeOf(context).width * 0.4).clamp(120.0, 260.0),
                      child: EpisodePoster(
                        episode: episode,
                        showLabel: false,
                        onTap: onTap,
                        onLongPress: onLongPress,
                        actions: actions,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          Text(
                            '${episode.episode}. ${episode.name}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isCurrent ? theme.colorScheme.primary : null,
                            ),
                          ),
                          if (runTime != null && runTime.inMinutes > 0)
                            Text('${runTime.inMinutes}m', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                          if (wide) synopsis,
                        ],
                      ),
                    ),
                    // Downloaded / downloading episodes show their status on the thumbnail instead.
                    EpisodeDownloadButton(episode: episode),
                  ],
                ),
                if (!wide) synopsis,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EpisodePoster extends ConsumerWidget {
  final EpisodeModel episode;
  final bool showLabel;
  final Function()? onTap;
  final Function()? onLongPress;
  final bool blur;
  final List<ItemAction> actions;
  final Function(bool value)? onFocusChanged;
  final bool isCurrentEpisode;
  final Object? heroTag;

  const EpisodePoster({
    super.key,
    required this.episode,
    this.showLabel = true,
    this.onTap,
    this.onLongPress,
    this.blur = false,
    required this.actions,
    this.onFocusChanged,
    this.isCurrentEpisode = false,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget placeHolder = Container(
      height: double.infinity,
      child: const Icon(Icons.local_movies_outlined),
    );
    bool episodeAvailable = episode.status == EpisodeStatus.available;
    final syncedDetails = ref.watch(syncedItemProvider(episode));
    return AspectRatio(
      aspectRatio: 1.76,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: FocusButton(
              onTap: onTap,
              onLongPress: onLongPress,
              onFocusChanged: onFocusChanged,
              onSecondaryTapDown: (details) async {
                Offset localPosition = details.globalPosition;
                RelativeRect position =
                    RelativeRect.fromLTRB(localPosition.dx, localPosition.dy, localPosition.dx, localPosition.dy);
                await showMenu(context: context, position: position, items: actions.popupMenuItems(useIcons: true));
              },
              child: Hero(
                tag: heroTag ?? UniqueKey(),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: FladderTheme.smallShape.borderRadius,
                    color: Theme.of(context).colorScheme.surfaceContainer,
                  ),
                  child: FladderImage(
                    image: !episodeAvailable ? episode.parentImages?.primary : episode.images?.primary,
                    placeHolder: placeHolder,
                    blurOnly: !episodeAvailable
                        ? true
                        : ref.watch(clientSettingsProvider.select((value) => value.blurUpcomingEpisodes))
                            ? blur
                            : false,
                  ),
                ),
              ),
              overlays: [
                if (!episodeAvailable)
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Card(
                        color: episode.status.color,
                        elevation: 3,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(
                            episode.status.label(context.localized, episode.dateAired),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.topRight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      switch (syncedDetails) {
                        AsyncValue<SyncedItem?>(:final value) => Builder(
                            builder: (context) {
                              if (value == null) {
                                return const SizedBox.shrink();
                              }
                              return StatusCard(
                                child: SyncButton(item: episode, syncedItem: value),
                              );
                            },
                          ),
                      },
                      if (episode.userData.isFavourite)
                        const StatusCard(
                          color: Colors.red,
                          child: Icon(
                            Icons.favorite_rounded,
                          ),
                        ),
                      if (episode.userData.played)
                        StatusCard(
                          color: Theme.of(context).colorScheme.primary,
                          child: const Icon(
                            Icons.check_rounded,
                          ),
                        ),
                    ],
                  ),
                ),
                if ((episode.userData.progress) > 0)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      backgroundColor: Colors.black.withValues(alpha: 0.75),
                      value: episode.userData.progress / 100,
                    ),
                  ),
              ],
              focusedOverlays: [
                if (AdaptiveLayout.inputDeviceOf(context) == InputDevice.pointer && actions.isNotEmpty)
                  ExcludeFocus(
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: PopupMenuButton(
                        tooltip: context.localized.options,
                        icon: const Icon(
                          Icons.more_vert,
                          color: Colors.white,
                        ),
                        itemBuilder: (context) => actions.popupMenuItems(useIcons: true),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (showLabel) ...{
            const SizedBox(height: 4),
            Row(
              children: [
                if (isCurrentEpisode)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(
                      height: 12,
                      width: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                Flexible(
                  child: Text(
                    episode.episodeLabel(context.localized),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          }
        ],
      ),
    );
  }
}

/// Long-press multi-select for episode lists: pick episodes, then download or mark them in one go.
mixin EpisodePicker<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Episodes picked via long-press; while non-empty, taps toggle instead of opening.
  final Set<EpisodeModel> picked = {};

  void togglePick(EpisodeModel episode) =>
      setState(() => picked.contains(episode) ? picked.remove(episode) : picked.add(episode));

  Future<void> markPicked(bool played) async {
    final user = ref.read(userProvider.notifier);
    final chosen = picked.toList(); // taps during the awaits must not mutate what we iterate
    setState(picked.clear);
    for (final episode in chosen) {
      await user.markAsPlayed(played, episode.id);
    }
    if (mounted) context.refreshData();
  }

  Future<void> downloadPicked() async {
    final ids = picked.map((e) => e.id).toSet();
    final series = picked.first.parentBaseModel;
    setState(picked.clear);
    try {
      await ref.read(syncProvider.notifier).syncSeries(series, episodeIds: ids);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  /// [all] is every episode currently listed, for the one select-all / deselect-all toggle.
  Widget selectionBar(EdgeInsets padding, List<EpisodeModel> all) => Padding(
        padding: padding.copyWith(top: 0, bottom: 0),
        child: Row(
          spacing: 4,
          children: [
            IconButton(
              tooltip: context.localized.cancel,
              onPressed: () => setState(picked.clear),
              icon: const Icon(IconsaxPlusLinear.close_circle),
            ),
            Text('${picked.length} selected', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            Builder(builder: (context) {
              final allPicked = all.every(picked.contains);
              return IconButton(
                tooltip: allPicked ? 'Deselect all' : 'Select all',
                onPressed: () => setState(() => allPicked ? picked.removeAll(all) : picked.addAll(all)),
                icon: Icon(allPicked ? IconsaxPlusBold.tick_circle : IconsaxPlusLinear.tick_circle),
              );
            }),
            IconButton(tooltip: 'Download', onPressed: downloadPicked, icon: const Icon(IconsaxPlusLinear.import_3)),
            IconButton(
                tooltip: 'Mark watched',
                onPressed: () => markPicked(true),
                icon: const Icon(IconsaxPlusBold.tick_circle)),
            IconButton(
                tooltip: 'Mark unwatched',
                onPressed: () => markPicked(false),
                icon: const Icon(IconsaxPlusLinear.tick_circle)),
          ],
        ),
      );
}
