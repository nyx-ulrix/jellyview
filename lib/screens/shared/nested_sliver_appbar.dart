import 'package:flutter/material.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/routes/auto_router.gr.dart';

class NestedSliverAppBar extends ConsumerWidget {
  final BuildContext parent;
  final PageRouteInfo? route;
  const NestedSliverAppBar({required this.parent, this.route, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaceColor = Theme.of(context).colorScheme.surface;
    return SliverAppBar(
      automaticallyImplyLeading: false,
      elevation: 0,
      forceElevated: false,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      backgroundColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: BoxDecoration(
            gradient: LinearGradient(
          colors: [
            surfaceColor.withValues(alpha: 0.7),
            surfaceColor.withValues(alpha: 0),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        )),
        child: Padding(
          padding: MediaQuery.paddingOf(context).copyWith(bottom: 0),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              height: 50,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  Expanded(child: SearchPill(route: route)),
                ],
              ),
            ),
          ),
        ),
      ),
      toolbarHeight: 80,
      floating: true,
    );
  }
}

/// The same menu + profile buttons as [NestedSliverAppBar], but floating over the page instead of taking
/// space, so the Home slideshow can run edge to edge under it. Its background fades in as you scroll.
class HomeTopBar extends StatelessWidget {
  final BuildContext parent;
  final ScrollController controller;
  const HomeTopBar({required this.parent, required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    final surfaceColor = Theme.of(context).colorScheme.surface;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final offset = controller.hasClients ? controller.offset : 0.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: surfaceColor.withValues(alpha: (offset / 300).clamp(0.0, 0.92)),
          ),
          child: child,
        );
      },
      child: Padding(
        padding: MediaQuery.paddingOf(context).copyWith(bottom: 0).add(const EdgeInsets.all(14)),
        child: SizedBox(
          height: 50,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              const Expanded(child: SearchPill()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pill-shaped search bar at the top of the main pages; tapping it opens search.
class SearchPill extends StatelessWidget {
  final PageRouteInfo? route;
  const SearchPill({this.route, super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.75),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.router.push(route ?? LibrarySearchRoute()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            spacing: 10,
            children: [
              Icon(IconsaxPlusLinear.search_normal_1, size: 20, color: scheme.onSurfaceVariant),
              Text('Search', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
