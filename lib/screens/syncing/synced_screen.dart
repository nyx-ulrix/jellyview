import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/screens/shared/nested_scaffold.dart';
import 'package:fladder/screens/shared/nested_sliver_appbar.dart';
import 'package:fladder/screens/syncing/sync_item_details.dart';
import 'package:fladder/screens/syncing/sync_list_item.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/sliver_list_padding.dart';
import 'package:fladder/widgets/navigation_scaffold/components/background_image.dart';
import 'package:fladder/widgets/shared/pull_to_refresh.dart';

@RoutePage()
class SyncedScreen extends ConsumerStatefulWidget {
  const SyncedScreen({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SyncedScreenState();
}

class _SyncedScreenState extends ConsumerState<SyncedScreen> {
  /// Downloads picked via long-press; while non-empty, taps toggle selection.
  final Set<String> picked = {};

  void togglePick(String id) => setState(() => picked.contains(id) ? picked.remove(id) : picked.add(id));

  Future<void> deletePicked(List items) async {
    final chosen = items.where((e) => picked.contains(e.id)).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${chosen.length} downloads?'),
        content: Text(context.localized.syncDeletePopupPermanent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.localized.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.localized.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final item in chosen) {
      if (!mounted) return;
      await ref.read(syncProvider.notifier).removeSync(context, item);
    }
    if (mounted) setState(picked.clear);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(syncProvider.select((value) => value.items));
    final padding = AdaptiveLayout.adaptivePadding(context);

    return PullToRefresh(
      refreshOnStart: true,
      onRefresh: () => ref.read(syncProvider.notifier).refresh(),
      child: (context) => NestedScaffold(
        background: BackgroundImage(images: items.map((value) => value.images).nonNulls.toList()),
        body: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          controller: AdaptiveLayout.scrollOf(context, HomeTabs.sync),
          slivers: [
            if (AdaptiveLayout.viewSizeOf(context) == ViewSize.phone)
              NestedSliverAppBar(
                parent: context,
                route: LibrarySearchRoute(),
              )
            else
              const DefaultSliverTopBadding(),
            if (kDebugMode)
              SliverToBoxAdapter(
                child: Padding(
                  padding: padding,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runAlignment: WrapAlignment.center,
                    spacing: 12,
                    children: [
                      ElevatedButton(
                        onPressed: () => ref.read(syncProvider.notifier).viewDatabase(context),
                        child: const Text("View Database"),
                      ),
                      ElevatedButton(
                        onPressed: () => ref.read(syncProvider.notifier).removeAllSyncedData(),
                        child: const Text("Clear drift database"),
                      ),
                    ],
                  ),
                ),
              ),
            if (items.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: padding,
                  child: picked.isEmpty
                      ? Text(
                          context.localized.syncedItems,
                          style: Theme.of(context).textTheme.titleLarge,
                        )
                      : Row(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: context.localized.cancel,
                              onPressed: () => setState(picked.clear),
                              icon: const Icon(IconsaxPlusLinear.close_circle),
                            ),
                            Text('${picked.length} selected', style: Theme.of(context).textTheme.titleLarge),
                            const Spacer(),
                            if (picked.length == 1)
                              IconButton(
                                tooltip: 'Details',
                                onPressed: () => showSyncItemDetails(
                                    context, items.firstWhere((e) => e.id == picked.first), ref),
                                icon: const Icon(IconsaxPlusLinear.info_circle),
                              ),
                            IconButton(
                              tooltip: 'Select all',
                              onPressed: () => setState(() => picked.addAll(items.map((e) => e.id))),
                              icon: const Icon(IconsaxPlusLinear.tick_square),
                            ),
                            IconButton(
                              tooltip: context.localized.delete,
                              onPressed: () => deletePicked(items),
                              icon: Icon(IconsaxPlusLinear.trash, color: Theme.of(context).colorScheme.error),
                            ),
                          ],
                        ),
                ),
              ),
              SliverPadding(
                padding: padding,
                sliver: SliverList.builder(
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return FocusProvider(
                      autoFocus: index == 0,
                      child: SyncListItem(
                        syncedItem: item,
                        selected: picked.contains(item.id),
                        onTap: picked.isEmpty ? null : () => togglePick(item.id),
                        onLongPress: AdaptiveLayout.inputDeviceOf(context) == InputDevice.touch
                            ? () => togglePick(item.id)
                            : null,
                      ),
                    );
                  },
                  itemCount: items.length,
                ),
              ),
            ] else ...[
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      Icon(IconsaxPlusLinear.arrow_down_2, size: 56, color: Theme.of(context).colorScheme.primary),
                      Text('No downloads yet', style: Theme.of(context).textTheme.titleLarge),
                      Text(
                        'Shows and movies you download play here, even when Tailscale is off.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      FilledButton.icon(
                        onPressed: () => context.router.navigate(const LibraryRoute()),
                        icon: const Icon(IconsaxPlusLinear.search_normal_1),
                        label: const Text('Find something to download'),
                      ),
                    ],
                  ),
                ),
              )
            ],
            const DefaultSliverBottomPadding(),
          ],
        ),
      ),
    );
  }
}
