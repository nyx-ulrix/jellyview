import 'dart:async';

import 'package:flutter/material.dart';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/collection_types.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/library_filters_model.dart';
import 'package:fladder/models/library_search/library_search_options.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/dashboard_mode_provider.dart';
import 'package:fladder/providers/dashboard_provider.dart';
import 'package:fladder/providers/favourites_provider.dart';
import 'package:fladder/providers/jellyfin_websocket_provider.dart';
import 'package:fladder/providers/library_filters_provider.dart';
import 'package:fladder/providers/music_dashboard_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/dashboard/home_banner_widget.dart';
import 'package:fladder/screens/dashboard/music_dashboard_screen.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/screens/shared/media/poster_row.dart';
import 'package:fladder/screens/shared/nested_scaffold.dart';
import 'package:fladder/screens/shared/nested_sliver_appbar.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/list_padding.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/sliver_list_padding.dart';
import 'package:fladder/widgets/navigation_scaffold/components/background_image.dart';
import 'package:fladder/widgets/shared/pinch_poster_zoom.dart';
import 'package:fladder/widgets/shared/poster_size_slider.dart';
import 'package:fladder/widgets/shared/pull_to_refresh.dart';

/// Next Up / Continue Watching cards: 3:2 landscape, ~260pt wide image, plus room for the title lines.
const double _wideCardRatio = 3 / 2;
const double _wideCardRowHeight = 260 / _wideCardRatio + 66;

@RoutePage()
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final Timer _refreshTimer;
  bool _visible = true;
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  final textController = TextEditingController();

  final selectedPoster = ValueNotifier<ItemBaseModel?>(null);

  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(minutes: 2), (timer) {
      if (!_canRefresh) return;
      final musicMode = ref.read(musicDashboardModeProvider);
      if (!ref.read(jellyfinWebSocketConnectedProvider)) {
        musicMode
            ? ref.read(musicDashboardProvider.notifier).fetchMusicHome(silent: true)
            : ref.read(dashboardProvider.notifier).refreshLoadedSections();
      } else if (!musicMode) {
        ref.read(dashboardProvider.notifier).refreshLiveTV();
      }
    });
  }

  bool get _canRefresh {
    final appInForeground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final videoFullScreen = ref.read(mediaPlaybackProvider).state == VideoPlayerState.fullScreen;
    return _visible && appInForeground && !videoFullScreen;
  }

  void _refreshLiveTV() {
    if (_canRefresh && !ref.read(musicDashboardModeProvider)) ref.read(dashboardProvider.notifier).refreshLiveTV();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = context.watchRouter.topRoute.name == DashboardRoute.name;
    final entered = visible && !_visible;
    _visible = visible;
    if (entered) Future.microtask(_refreshLiveTV);
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    super.dispose();
  }

  bool _favouritesRequested = false;

  Future<void> _refreshHome() async {
    if (!mounted) return;
    _refreshing = true;
    try {
      await ref.read(userProvider.notifier).updateInformation();
      await ref.read(dashboardProvider.notifier).refreshDashboard();
      if (ref.read(homeSettingsProvider).carouselSettings == HomeCarouselSettings.favourites) {
        await ref.read(favouritesProvider.notifier).fetchFavourites();
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(musicDashboardModeProvider)) {
      return const MusicDashboardScreen();
    }

    ref.listen(libraryFiltersByKeyProvider(FilterSortKey.dashboard), (previous, next) {
      if (_refreshing || const ListEquality<LibraryFiltersModel>().equals(previous, next)) return;
      ref.read(dashboardProvider.notifier).fetchDashboardFilters();
    });

    final padding = AdaptiveLayout.adaptivePadding(context);
    final dashboardData = ref.watch(dashboardProvider);
    final views = ref.watch(viewsProvider);
    final homeSettings = ref.watch(homeSettingsProvider);
    final homeBanner = ref.watch(homeSettingsProvider.select((value) => value.homeBanner)) != HomeBanner.hide;
    final resumeVideo = dashboardData.resumeVideo;
    final resumeAudio = dashboardData.resumeAudio;
    final resumeBooks = dashboardData.resumeBooks;
    final tvChannels = dashboardData.activePrograms;

    final dashboardSorting = ref.watch(userProvider.select((value) => value?.userSettings?.dashboardSorting)) ??
        DashboardSorting.defaultSorting;

    final allResume = [...resumeVideo, ...resumeAudio, ...resumeBooks].toList();

    final favourites = ref.watch(favouritesProvider.select((value) => value.favourites));
    if (homeSettings.carouselSettings == HomeCarouselSettings.favourites &&
        favourites.isEmpty &&
        !_favouritesRequested) {
      _favouritesRequested = true;
      // Liked titles load lazily (normally on the Favourites tab); fetch once for the hero.
      Future.microtask(() => ref.read(favouritesProvider.notifier).fetchFavourites());
    }
    final homeCarouselItems = switch (homeSettings.carouselSettings) {
      HomeCarouselSettings.nextUp => dashboardData.nextUp,
      HomeCarouselSettings.combined => [...allResume, ...dashboardData.nextUp],
      HomeCarouselSettings.cont => allResume,
      HomeCarouselSettings.favourites => [
          ...?favourites[FladderItemType.movie],
          ...?favourites[FladderItemType.series],
        ],
    };

    final showsBanner = homeBanner && homeCarouselItems.isNotEmpty;

    final loadedSections = dashboardData.loadedSections;
    final visibleSections = homeBanner && !loadedSections.contains(DashboardSorting.nextUp)
        ? <DashboardSorting>[]
        : dashboardSorting.entries
            .where((entry) => entry.value)
            .map((entry) => entry.key)
            .takeWhile(loadedSections.contains)
            .toList();

    final viewSize = AdaptiveLayout.viewSizeOf(context);
    final floatingTopBar = viewSize == ViewSize.phone && showsBanner;

    final useTVExpandedLayout = ref.watch(clientSettingsProvider.select((value) => value.useTVExpandedLayout));

    return NestedScaffold(
      background: ValueListenableBuilder<ItemBaseModel?>(
        valueListenable: selectedPoster,
        builder: (_, value, __) {
          return BackgroundImage(
            images: (value != null
                    ? [value]
                    : [
                        ...homeCarouselItems,
                        ...dashboardData.nextUp,
                        ...allResume,
                      ])
                .map((e) => e.images)
                .nonNulls
                .toList(),
          );
        },
      ),
      body: PullToRefresh(
        refreshKey: _refreshIndicatorKey,
        contextRefresh: false,
        displacement: 80 + MediaQuery.of(context).viewPadding.top,
        onRefresh: () async => await _refreshHome(),
        child: (context) => Stack(children: [
          PinchPosterZoom(
            scaleDifference: (difference) => ref.read(clientSettingsProvider.notifier).addPosterSize(difference),
            child: CustomScrollView(
              controller: AdaptiveLayout.scrollOf(context, HomeTabs.dashboard),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // The slideshow starts at the very top (it fades into the status bar itself).
                if (!showsBanner) const DefaultSliverTopBadding(),
                if (viewSize == ViewSize.phone && !floatingTopBar)
                  NestedSliverAppBar(
                    route: LibrarySearchRoute(),
                    parent: context,
                  ),
                if (showsBanner) ...{
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: AdaptiveLayout.adaptivePadding(
                        context,
                        horizontalPadding: 0,
                      ),
                      child: HomeBannerWidget(
                        posters: homeCarouselItems,
                        onSelect: (poster) => selectedPoster.value = poster,
                      ),
                    ),
                  ),
                },
                if (AdaptiveLayout.of(context).isDesktop)
                  const SliverToBoxAdapter(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        PosterSizeWidget(),
                      ],
                    ),
                  ),
                ...[
                  for (final section in visibleSections)
                    ...switch (section) {
                      DashboardSorting.liveTV => [
                          if (tvChannels.isNotEmpty)
                            PosterRow(
                              contentPadding: padding,
                              tvMode: useTVExpandedLayout,
                              label: context.localized.activeTvChannels,
                              collectionAspectRatio: 0.55,
                              onLabelClick: () {
                                return LiveTvRoute().navigate(context);
                              },
                              posters: tvChannels,
                            ),
                        ],
                      DashboardSorting.nextUp => [
                          if (resumeVideo.isNotEmpty &&
                              (homeSettings.nextUp == HomeNextUp.cont || homeSettings.nextUp == HomeNextUp.separate))
                            PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              label: context.localized.dashboardContinueWatching,
                              // Netflix-style wide thumbnails for anything you're partway through.
                              collectionAspectRatio: _wideCardRatio,
                              height: _wideCardRowHeight, // fixed 3:2 (6:4), not user-resizable
                              imagePriority: const [ImageType.thumb, ImageType.backdrop, ImageType.primary],
                              posters: resumeVideo,
                            ),
                          if (resumeAudio.isNotEmpty &&
                              (homeSettings.nextUp == HomeNextUp.cont || homeSettings.nextUp == HomeNextUp.separate))
                            PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              label: context.localized.dashboardContinueListening,
                              posters: resumeAudio,
                            ),
                          if (resumeBooks.isNotEmpty &&
                              (homeSettings.nextUp == HomeNextUp.cont || homeSettings.nextUp == HomeNextUp.separate))
                            PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              label: context.localized.dashboardContinueReading,
                              posters: resumeBooks,
                            ),
                          if (dashboardData.nextUp.isNotEmpty &&
                              (homeSettings.nextUp == HomeNextUp.nextUp || homeSettings.nextUp == HomeNextUp.separate))
                            PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              label: context.localized.nextUp,
                              // Netflix-style wide thumbnails for anything you're partway through.
                              collectionAspectRatio: _wideCardRatio,
                              height: _wideCardRowHeight, // fixed 3:2 (6:4), not user-resizable
                              imagePriority: const [ImageType.thumb, ImageType.backdrop, ImageType.primary],
                              posters: dashboardData.nextUp,
                            ),
                          if ([...allResume, ...dashboardData.nextUp].isNotEmpty &&
                              homeSettings.nextUp == HomeNextUp.combined)
                            PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              label: context.localized.dashboardContinue,
                              // Netflix-style wide thumbnails for anything you're partway through.
                              collectionAspectRatio: _wideCardRatio,
                              height: _wideCardRowHeight, // fixed 3:2 (6:4), not user-resizable
                              imagePriority: const [ImageType.thumb, ImageType.backdrop, ImageType.primary],
                              posters: [...allResume, ...dashboardData.nextUp],
                            ),
                        ],
                      DashboardSorting.recentlyAdded => [
                          ...views.dashboardViews
                              .where(
                                (element) =>
                                    element.recentlyAdded.isNotEmpty && element.collectionType != CollectionType.livetv,
                              )
                              .map(
                                (view) => PosterRow(
                                  tvMode: useTVExpandedLayout,
                                  contentPadding: padding,
                                  label: context.localized.dashboardRecentlyAdded(view.name),
                                  collectionAspectRatio: view.collectionType.aspectRatio,
                                  onLabelClick: () {
                                    if (view.collectionType == CollectionType.livetv) {
                                      return LiveTvRoute().navigate(context);
                                    }
                                    return context.router.push(
                                      LibrarySearchRoute(
                                        parentId: [view.id],
                                        types: switch (view.collectionType) {
                                          CollectionType.tvshows => {
                                              FladderItemType.episode: true,
                                            },
                                          _ => {},
                                        },
                                        sortingOptions: switch (view.collectionType) {
                                          CollectionType.books ||
                                          CollectionType.boxsets ||
                                          CollectionType.folders ||
                                          CollectionType.music =>
                                            SortingOptions.dateLastContentAdded,
                                          _ => SortingOptions.dateAdded,
                                        },
                                        sortOrder: SortingOrder.descending,
                                        recursive: true,
                                      ),
                                    );
                                  },
                                  posters: view.recentlyAdded,
                                ),
                              ),
                        ],
                      DashboardSorting.filters => [
                          ...dashboardData.dashboardFilters.map(
                            (dashboardFilter) => PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              label: dashboardFilter.filter.name,
                              onLabelClick: () => dashboardFilter.filter.navigateTo(context),
                              posters: dashboardFilter.items,
                            ),
                          ),
                        ],
                    },
                ]
                    .nonNulls
                    .toList()
                    .mapIndexed(
                      (index, child) => SliverToBoxAdapter(
                        child: FocusProvider(
                          autoFocus: !showsBanner && index == 0,
                          child: child,
                        ),
                      ),
                    )
                    .toList()
                    .addInBetween(
                      const SliverToBoxAdapter(
                        child: SizedBox(height: 16),
                      ),
                    ),
                const DefaultSliverBottomPadding(),
              ],
            ),
          ),
          // Phone with the slideshow: the buttons float over it so the artwork reaches the top edge.
          if (floatingTopBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: HomeTopBar(parent: context, controller: AdaptiveLayout.scrollOf(context, HomeTabs.dashboard)),
            ),
        ]),
      ),
    );
  }
}
