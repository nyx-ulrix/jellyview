import 'package:flutter/material.dart';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';

class BannerPlayButton extends ConsumerWidget {
  final ItemBaseModel item;
  const BannerPlayButton({
    super.key,
    required this.item,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Opacity(
        opacity: 0.9,
        child: Padding(
          // Room for the progress ring drawn around the button's edge, so it's never clipped.
          padding: const EdgeInsets.all(16.0),
          child: SizedBox.square(
            dimension: 64,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Round button with the watched progress as a ring around it.
                Material(
                  shape: const CircleBorder(),
                  color: Theme.of(context).colorScheme.surface,
                  child: IconButton(
                    onPressed: () => item.play(context, ref),
                    icon: const Icon(IconsaxPlusBold.play, size: 30),
                  ),
                ),
                IgnorePointer(
                  child: CircularProgressIndicator(
                    value: item.userData.progress / 100,
                    strokeWidth: 4,
                    color: Theme.of(context).colorScheme.primary,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
