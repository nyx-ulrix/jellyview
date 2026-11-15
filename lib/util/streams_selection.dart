import 'package:fladder/models/items/media_streams_model.dart';

int? selectAudioStream(
  bool rememberAudioSelection,
  AudioAndSubStreamModel? previousStream,
  List<AudioAndSubStreamModel>? currentStream,
  int? defaultStream,
) {
  if (!rememberAudioSelection) {
    return defaultStream;
  }
  return _selectStream(previousStream, currentStream, defaultStream);
}

int? selectSubStream(
  bool rememberSubSelection,
  AudioAndSubStreamModel? previousStream,
  List<AudioAndSubStreamModel>? currentStream,
  int? defaultStream,
) {
  if (!rememberSubSelection) {
    return defaultStream;
  }
  return _selectStream(previousStream, currentStream, defaultStream);
}

int? _selectStream(
  AudioAndSubStreamModel? previousStream,
  List<AudioAndSubStreamModel>? currentStream,
  int? defaultStream,
) {
  if (currentStream == null || previousStream == null) {
    return defaultStream;
  }

  int? bestStreamIndex;
  int bestStreamScore = 0;

  // Find the relative index of the previous stream
  int prevRelIndex = 0;
  for (var stream in currentStream) {
    if (stream.index == previousStream.index) break;
    prevRelIndex += 1;
  }

  int newRelIndex = 0;
  for (var stream in currentStream) {
    int score = 0;

    if (previousStream.codec == stream.codec) score += 1;
    if (prevRelIndex == newRelIndex) score += 1;
    if (previousStream.displayTitle == stream.displayTitle) {
      score += 2;
    }
    if (previousStream.language != 'und' && previousStream.language == stream.language) {
      score += 2;
    }

    if (score > bestStreamScore && score >= 3) {
      bestStreamScore = score;
      bestStreamIndex = stream.index;
    }

    newRelIndex += 1;
  }
  return bestStreamIndex ?? defaultStream;
}

/// Aliases so a preference of "eng" matches tracks tagged en / ENG / English / "English (SDH)" etc.
const _languageAliases = <List<String>>[
  ['en', 'eng', 'english'],
  ['ja', 'jpn', 'japanese'],
  ['zh', 'chi', 'zho', 'chinese', 'mandarin', 'cantonese'],
  ['ko', 'kor', 'korean'],
  ['ms', 'may', 'msa', 'malay', 'melayu'],
  ['id', 'ind', 'indonesian'],
  ['ta', 'tam', 'tamil'],
  ['hi', 'hin', 'hindi'],
  ['th', 'tha', 'thai'],
  ['vi', 'vie', 'vietnamese'],
  ['es', 'spa', 'spanish', 'espanol'],
  ['fr', 'fre', 'fra', 'french', 'francais'],
  ['de', 'ger', 'deu', 'german', 'deutsch'],
  ['it', 'ita', 'italian'],
  ['pt', 'por', 'portuguese'],
  ['ru', 'rus', 'russian'],
  ['ar', 'ara', 'arabic'],
];

Set<String> languageKeywords(String preference) {
  final p = preference.trim().toLowerCase();
  return _languageAliases.firstWhere((a) => a.contains(p), orElse: () => [p]).toSet();
}

/// Picks the best subtitle whose language / title contains a keyword for [preference].
/// Prefers full subtitles over "forced"/"signs" tracks. Returns null if none match.
int? subtitleIndexByKeyword(List<AudioAndSubStreamModel> subs, String? preference) {
  if (preference == null || preference.trim().isEmpty) return null;
  final keys = languageKeywords(preference);
  int? best;
  var bestScore = 0;
  for (final s in subs) {
    if (s.index == -1) continue;
    final tokens = '${s.language} ${s.name} ${s.displayTitle}'.toLowerCase().split(RegExp(r'[^a-z]+')).toSet();
    // Two-letter codes only count in the language tag ("hi" in "English (HI)" is not Hindi).
    final language = s.language.toLowerCase().trim();
    final matches = keys.any((k) => k.length > 2 ? tokens.contains(k) : k == language);
    if (!matches) continue;
    final partial = tokens.contains('forced') || tokens.contains('signs') || tokens.contains('songs');
    final score = partial ? 1 : 2;
    if (score > bestScore) {
      best = s.index;
      bestScore = score;
    }
  }
  return best;
}
