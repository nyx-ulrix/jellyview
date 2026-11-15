import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/shared_provider.dart';

/// Power-user settings (codecs, buffers, colour schemes, layout modes...) stay out of sight unless this
/// is switched on at the bottom of Settings, so the app stays simple for everyone else.
final showAdvancedSettingsProvider =
    StateProvider<bool>((ref) => ref.read(sharedPreferencesProvider).getBool('showAdvancedSettings') ?? false);

void setShowAdvancedSettings(WidgetRef ref, bool value) {
  ref.read(sharedPreferencesProvider).setBool('showAdvancedSettings', value);
  ref.read(showAdvancedSettingsProvider.notifier).state = value;
}
