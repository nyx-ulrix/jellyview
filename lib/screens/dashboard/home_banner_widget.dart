import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/shared/media/media_banner.dart';

/// The home slideshow (the only banner style); hidden when turned off in settings.
class HomeBannerWidget extends ConsumerWidget {
  final List<ItemBaseModel> posters;
  final Function(ItemBaseModel selected) onSelect;

  const HomeBannerWidget({
    required this.posters,
    required this.onSelect,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(homeSettingsProvider.select((value) => value.homeBanner)) == HomeBanner.hide) {
      return const SizedBox.shrink();
    }
    // Full width from the very top of the screen: tall on phones, 16:9-ish on wider screens.
    final size = MediaQuery.sizeOf(context);
    final height = size.width < size.height
        ? size.height * 0.62
        // Landscape / wide: 16:9 but never taller than most of the screen (phones sideways are short).
        : (size.width * 9 / 16).clamp(0.0, size.height * 0.8);
    return MediaBanner(items: posters, maxHeight: height, onSelect: onSelect);
  }
}
