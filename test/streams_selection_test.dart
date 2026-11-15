import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/util/streams_selection.dart';

AudioAndSubStreamModel sub(int index, String language, String title) => AudioAndSubStreamModel(
      displayTitle: title,
      name: title,
      codec: 'srt',
      isDefault: false,
      isExternal: false,
      index: index,
      language: language,
    );

void main() {
  test('eng / ENG / English / en all match an "eng" preference', () {
    for (final s in [sub(3, 'eng', 'Track'), sub(3, 'ENG', 'Track'), sub(3, 'und', 'English'), sub(3, 'en', 'x')]) {
      expect(subtitleIndexByKeyword([sub(1, 'jpn', 'Japanese'), s], 'eng'), 3);
    }
  });

  test('prefers full subtitles over forced, and English preference phrased as a word', () {
    final subs = [sub(1, 'eng', 'English (Forced)'), sub(2, 'eng', 'English SDH'), sub(4, 'spa', 'Spanish')];
    expect(subtitleIndexByKeyword(subs, 'English'), 2);
  });

  test('no match / no preference returns null', () {
    expect(subtitleIndexByKeyword([sub(1, 'jpn', 'Japanese')], 'eng'), isNull);
    expect(subtitleIndexByKeyword([sub(1, 'eng', 'English')], ''), isNull);
    // "english" must not match a word that merely contains "en" (e.g. "Kitchen").
    expect(subtitleIndexByKeyword([sub(1, 'und', 'Kitchen commentary')], 'eng'), isNull);
    // Two-letter codes only match the language tag: "English (HI)" is not Hindi.
    expect(subtitleIndexByKeyword([sub(1, 'eng', 'English (HI)')], 'hin'), isNull);
  });
}
