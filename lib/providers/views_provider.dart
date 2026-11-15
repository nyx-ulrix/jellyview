import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/view_model.dart';
import 'package:fladder/models/views_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/jellyfin_websocket_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/user_provider.dart';

//Known supported collection types
const enableCollectionTypes = {
  CollectionType.movies,
  CollectionType.books,
  CollectionType.tvshows,
  CollectionType.homevideos,
  CollectionType.boxsets,
  CollectionType.playlists,
  CollectionType.photos,
  CollectionType.livetv,
  CollectionType.folders,
  CollectionType.music,
  CollectionType.musicvideos,
};

final viewsProvider = StateNotifierProvider<ViewsNotifier, ViewsModel>((ref) {
  return ViewsNotifier(ref);
});

class ViewsNotifier extends StateNotifier<ViewsModel> {
  ViewsNotifier(this.ref) : super(ViewsModel());

  final Ref ref;

  late final JellyService api = ref.read(jellyApiProvider);

  final _requests = LatestRequests();

  Future<ViewsModel?> fetchViews() async {
    if (state.loading) return null;
    try {
      final showAllCollections = ref.read(clientSettingsProvider.select((value) => value.showAllCollectionTypes));
      final response = await api.usersUserIdViewsGet();
      final previousViews = {for (final view in state.views) view.id: view};
      final newList = response.body?.items
              ?.map((e) => ViewModel.fromBodyDto(e, ref))
              .where((element) => showAllCollections ? true : enableCollectionTypes.contains(element.collectionType))
              .map((e) => e.copyWith(recentlyAdded: previousViews[e.id]?.recentlyAdded))
              .toList() ??
          [];

      state = state.copyWith(
          views: _applyLibraryOrdering(newList), dashboardViews: _dashboardViews(newList), loading: false);
      return state;
    } catch (e) {
      return state.copyWith(loading: false);
    }
  }

  Future<void> fetchRecentlyAdded({Set<String> libraryIds = const {}}) async {
    final showAllCollections = ref.read(clientSettingsProvider.select((value) => value.showAllCollectionTypes));
    final views = state.dashboardViews.where((view) => libraryIds.isEmpty || libraryIds.contains(view.id));
    if (views.isEmpty) return;
    final revision = _requests.startAll(views.map((view) => view.id));
    try {
      final recentlyAdded = Map.fromEntries(await Future.wait(views.map((e) async {
        final recents = await api.usersUserIdItemsLatestGet(
          parentId: e.id,
          imageTypeLimit: 1,
          limit: 16,
          includeItemTypes:
              (e.collectionType == CollectionType.books && !showAllCollections) ? [BaseItemKind.book] : null,
          enableImageTypes: [
            ImageType.primary,
            ImageType.backdrop,
            ImageType.thumb,
          ],
          fields: [
            ItemFields.parentid,
            ItemFields.mediastreams,
            ItemFields.mediasources,
            ItemFields.candelete,
            ItemFields.candownload,
            ItemFields.primaryimageaspectratio,
            ItemFields.overview,
          ],
        );
        // A show with a single new episode comes back as that episode (e.g. S06E41), which then opens/plays
        // mid-show. Show the series instead; its page starts at the earliest unwatched episode.
        final dtos = recents.body ?? [];
        final seriesIds = {
          for (final d in dtos)
            if (d.type == BaseItemKind.episode && d.seriesId != null) d.seriesId!
        };
        final series = <String, ItemBaseModel>{};
        if (seriesIds.isNotEmpty) {
          final found = await api.itemsGet(
            ids: seriesIds.toList(),
            enableImageTypes: [ImageType.primary, ImageType.backdrop, ImageType.thumb],
            fields: [ItemFields.parentid, ItemFields.primaryimageaspectratio, ItemFields.overview],
          );
          for (final item in found.body?.items ?? <ItemBaseModel>[]) {
            series[item.id] = item;
          }
        }
        final seen = <String>{};
        final items = <ItemBaseModel>[];
        for (final d in dtos) {
          final item =
              (d.type == BaseItemKind.episode ? series[d.seriesId] : null) ?? ItemBaseModel.fromBaseDto(d, ref);
          if (seen.add(item.id)) items.add(item);
        }
        return MapEntry(e.id, items);
      })))
        ..removeWhere((id, _) => !_requests.isLatest(id, revision));

      ViewModel withRecents(ViewModel view) =>
          recentlyAdded.containsKey(view.id) ? view.copyWith(recentlyAdded: recentlyAdded[view.id]) : view;

      state = state.copyWith(
        views: state.views.map(withRecents).toList(),
        dashboardViews: state.dashboardViews.map(withRecents).toList(),
      );
    } catch (_) {}
  }

  void updateRecentlyAddedItems(ItemBaseModel Function(ItemBaseModel) update) {
    ViewModel updateView(ViewModel view) => view.copyWith(recentlyAdded: view.recentlyAdded.map(update).toList());

    state = state.copyWith(
      views: state.views.map(updateView).toList(),
      dashboardViews: state.dashboardViews.map(updateView).toList(),
    );
  }

  void removeRecentlyAddedItems(Set<String> ids) {
    if (ids.isEmpty) return;
    ViewModel removeFromView(ViewModel view) =>
        view.copyWith(recentlyAdded: view.recentlyAdded.where((item) => !ids.contains(item.id)).toList());

    state = state.copyWith(
      views: state.views.map(removeFromView).toList(),
      dashboardViews: state.dashboardViews.map(removeFromView).toList(),
    );
  }

  List<ViewModel> _dashboardViews(List<ViewModel> views) => _applyLibraryOrdering(
      views.where((element) => !(ref.read(userProvider)?.latestItemsExcludes.contains(element.id) ?? true)).toList());

  List<ViewModel> _applyLibraryOrdering(List<ViewModel> views) {
    final orderedViews = ref.read(userProvider)?.userConfiguration?.orderedViews ?? [];
    if (orderedViews.isEmpty) return views;

    final viewMap = {for (var v in views) v.id: v};
    final ordered = <ViewModel>[];

    for (final id in orderedViews) {
      final view = viewMap.remove(id);
      if (view != null) ordered.add(view);
    }
    ordered.addAll(viewMap.values);
    return ordered;
  }

  void clear() {
    _requests.clear();
    state = ViewsModel();
  }
}
