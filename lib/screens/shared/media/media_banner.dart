import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:async/async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/screens/shared/media/banner_play_button.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';
import 'package:fladder/util/list_padding.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/widgets/shared/item_actions.dart';
import 'package:fladder/widgets/shared/modal_bottom_sheet.dart';

class MediaBanner extends ConsumerStatefulWidget {
  final PageController? controller;
  final List<ItemBaseModel> items;
  final double maxHeight;

  /// Called with the item now showing, e.g. so Home's background follows the slideshow.
  final ValueChanged<ItemBaseModel>? onSelect;

  const MediaBanner({
    this.controller,
    this.onSelect,
    required this.items,
    this.maxHeight = 250,
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MediaBannerState();
}

class _MediaBannerState extends ConsumerState<MediaBanner> {
  bool interacting = false;
  int currentPage = 0;
  double slidePosition = 1;

  late final RestartableTimer timer = RestartableTimer(const Duration(seconds: 8), () => nextSlide());

  @override
  void initState() {
    super.initState();
    timer.reset();
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  // Modulo, so a list that shrank on refresh can't leave the page past the end and stall the slideshow.
  void nextSlide() => _goTo(currentPage + 1);

  void previousSlide() => _goTo(currentPage - 1);

  void _goTo(int page) {
    if (!interacting && widget.items.isNotEmpty) {
      setState(() => currentPage = page % widget.items.length);
      widget.onSelect?.call(widget.items[currentPage]);
    }
    timer.reset();
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items[currentPage.clamp(0, widget.items.length - 1)];

    final surface = Theme.of(context).colorScheme.surface;
    final scroll = Scrollable.maybeOf(context)?.position;

    // Full-bleed artwork: a soft blur that strengthens toward the top (under the status bar and buttons)
    // and a fade into the page at the bottom. Crossfades between slides.
    Widget art(ItemBaseModel item) => LayoutBuilder(builder: (context, box) {
          final image = item.bannerArt(landscape: box.maxWidth >= box.maxHeight);
          return Stack(
            fit: StackFit.expand,
            children: [
              FladderImage(fit: BoxFit.cover, image: image, alignment: Alignment.topCenter),
              ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.4],
                  colors: [Colors.white, Colors.transparent],
                ).createShader(rect),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18, tileMode: TileMode.clamp),
                  child:
                      FladderImage(fit: BoxFit.cover, image: image, alignment: Alignment.topCenter, disableBlur: true),
                ),
              ),
            ],
          );
        });

    final banner = SizedBox(
      height: widget.maxHeight,
      child: MouseRegion(
        onHover: (event) => timer.reset(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // A swipe changes slide with the same crossfade as the slideshow; the artwork never slides.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity > 150) {
                  previousSlide();
                } else if (velocity < -150) {
                  nextSlide();
                }
              },
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 700),
                child: RepaintBoundary(
                  key: Key(currentItem.id),
                  child: FocusButton(
                    onTap: () => currentItem.navigateTo(context),
                    onLongPress: AdaptiveLayout.inputDeviceOf(context) == InputDevice.touch
                        ? () async {
                            interacting = true;
                            final poster = currentItem;
                            showBottomSheetPill(
                              context: context,
                              item: poster,
                              content: (scrollContext, scrollController) => ListView(
                                shrinkWrap: true,
                                controller: scrollController,
                                children:
                                    poster.generateActions(context, ref).listTileItems(scrollContext, useIcons: true),
                              ),
                            );
                            interacting = false;
                            timer.reset();
                          }
                        : null,
                    onSecondaryTapDown: AdaptiveLayout.inputDeviceOf(context) == InputDevice.touch
                        ? null
                        : (details) async {
                            Offset localPosition = details.globalPosition;
                            RelativeRect position = RelativeRect.fromLTRB(
                                localPosition.dx - 320, localPosition.dy, localPosition.dx, localPosition.dy);
                            final poster = currentItem;

                            await showMenu(
                              context: context,
                              position: position,
                              items: poster.generateActions(context, ref).popupMenuItems(useIcons: true),
                            );
                          },
                    child: art(currentItem),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.25, 0.55, 1],
                    colors: [
                      surface.withValues(alpha: 0.55),
                      Colors.transparent,
                      surface.withValues(alpha: 0.15),
                      surface,
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: IgnorePointer(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    currentItem.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                          color: Colors.white,
                                        ),
                                  ),
                                ),
                                if (currentItem.label(context.localized) != null || currentItem.subText != null)
                                  Flexible(
                                    child: Text(
                                      currentItem.label(context.localized) ?? currentItem.subText ?? "",
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            color: Colors.white.withValues(alpha: 0.75),
                                          ),
                                    ),
                                  ),
                              ].addInBetween(const SizedBox(height: 6)),
                            ),
                          ),
                        ),
                      ].addInBetween(const SizedBox(height: 16)),
                    ),
                  ),
                ),
              ],
            ),
            BannerPlayButton(item: currentItem),
          ],
        ),
      ),
    );

    if (scroll == null) return banner;
    // As the page scrolls, the banner fades away. No clipping or drifting, so there's never a hard edge
    // and the play button is never cut off.
    return AnimatedBuilder(
      animation: scroll,
      builder: (context, child) {
        final offset = scroll.hasPixels ? scroll.pixels.clamp(0.0, widget.maxHeight) : 0.0;
        return Opacity(opacity: (1 - offset / widget.maxHeight * 1.3).clamp(0.0, 1.0), child: child);
      },
      child: banner,
    );
  }

  void animateToTarget(int nextIndex) {
    int step = currentPage < nextIndex ? 1 : -1;
    void updateItem(int item) {
      Future.delayed(Duration(milliseconds: 64 ~/ ((currentPage - nextIndex).abs() / 3)), () {
        setState(() {
          currentPage = item;
        });

        if (currentPage != nextIndex) {
          updateItem(item + step);
        }
      });
      timer.reset();
    }

    updateItem(currentPage + step);
  }
}

class RoundedTrackShape extends RoundedRectSliderTrackShape {
  @override
  void paint(PaintingContext context, Offset offset,
      {required RenderBox parentBox,
      required SliderThemeData sliderTheme,
      required Animation<double> enableAnimation,
      required TextDirection textDirection,
      required Offset thumbCenter,
      Offset? secondaryOffset,
      bool isDiscrete = false,
      bool isEnabled = false,
      double additionalActiveTrackHeight = 0}) {
    super.paint(context, offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isDiscrete: isDiscrete,
        isEnabled: isEnabled,
        additionalActiveTrackHeight: additionalActiveTrackHeight);
  }
}
