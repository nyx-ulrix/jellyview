import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:async/async.dart';
import 'package:audio_session/audio_session.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/audio_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/screens/video_player/video_player.dart' as video_screen;
import 'package:fladder/util/subtitle_position_calculator.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class LibMPV extends BasePlayer {
  mpv.Player? _player;
  VideoController? _controller;
  Duration _subtitleOffset = Duration.zero;

  /// True when the current subtitle is plain text drawn by the Flutter overlay (so it can move above
  /// the controls and use the user's styling) instead of being burned in by libass.
  final ValueNotifier<bool> _overlayText = ValueNotifier(false);
  bool _displaySync = false;
  AppLifecycleListener? _lifecycle;

  /// Bitmap subs (DVD/PGS/DVB) jump to the top of the frame under sub-pos, so they are never lifted.
  final ValueNotifier<bool> _bitmapSub = ValueNotifier(false);
  static const _bitmapCodecs = {'dvdsub', 'dvd_subtitle', 'pgssub', 'hdmv_pgs_subtitle', 'dvbsub', 'dvb_subtitle'};
  static const _plainTextCodecs = {'srt', 'subrip', 'vtt', 'webvtt', 'mov_text', 'tx3g', 'text'};

  final StreamController<PlayerState> _stateController = StreamController.broadcast();
  @override
  Stream<PlayerState> get stateStream => _stateController.stream;

  StreamSubscription<bool>? _onCompleted;

  bool _replayGainFallbackLogged = false;
  VideoPlayerSettingsModel _settings = VideoPlayerSettingsModel();
  bool _lowResourceMode = false;

  RestartableTimer? _retryTimer;
  DateTime _firstLoadAttempt = DateTime.now();
  final Duration _maxRetryDuration = const Duration(minutes: 1);
  final Duration _currentRetryDuration = const Duration(seconds: 5);
  Completer<void>? _loadCompleter;
  final List<StreamSubscription> _playerStreamSubs = [];
  double _preferredVolume = 100;
  int _crossfadeGeneration = 0;
  Timer? _fadeTimer;
  Duration get playPauseFadeDuration => const Duration(milliseconds: 175);
  AudioSession? _audioSession;

  bool _musicPaused = false;
  bool _musicPlaybackMode = false;

  void setMusicPlaybackMode(bool enabled) {
    _musicPlaybackMode = enabled;
    if (!enabled) _musicPaused = false;
    setState(lastState);
  }

  Future<void> setupAudioSession() async {
    _audioSession = await AudioSession.instance;
    await _audioSession?.configure(const AudioSessionConfiguration.music());
  }

  Future<void> updateSettings(VideoPlayerSettingsModel settings) async {
    _settings = settings;
  }

  @override
  Future<void> init(VideoPlayerSettingsModel settings, {bool lowResourceMode = false}) async {
    _settings = settings;
    _lowResourceMode = lowResourceMode;
    dispose();

    mpv.MediaKit.ensureInitialized();

    _player = mpv.Player(
      configuration: mpv.PlayerConfiguration(
        title: "nl.jknaapen.fladder",
        libassAndroidFont: libassFallbackFont,
        libassAndroidFontName: libassFallbackFontName,
        libass: !kIsWeb && settings.useLibass,
        bufferSize: settings.bufferSize * 1024 * 1024, // MPV uses buffer size in bytes
      ),
    );

    if (_player != null) {
      _controller = VideoController(
        _player!,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: settings.hardwareAccel,
        ),
      );
      _setupPlayerStreams(_player!);
    }

    if (_player?.platform is mpv.NativePlayer) {
      final nativePlayer = _player!.platform as dynamic;
      await nativePlayer.setProperty('force-seekable', 'yes');
      await nativePlayer.setProperty('gapless-audio', 'yes');
      await nativePlayer.setProperty('cache', 'yes');
      await nativePlayer.setProperty('demuxer-max-bytes', _lowResourceMode ? '64M' : '150M');
      await nativePlayer.setProperty('network-timeout', '60');
      await nativePlayer.setProperty('stream-buffer-size', '4M');
      await nativePlayer.setProperty('prefetch-playlist', 'yes');
      await nativePlayer.setProperty('volume-max', '300');

      if (defaultTargetPlatform == TargetPlatform.android) {
        await nativePlayer.setProperty('ao', 'audiotrack');
        // mpv's "fast" profile: desktop-grade scalers (lanczos, dithering, linear downscaling) can't keep
        // up on a mobile GPU at tablet resolution after mediacodec-copy, which dropped ~1 in 5 frames.
        for (final entry in const {
          'scale': 'bilinear',
          'dscale': 'bilinear',
          'cscale': 'bilinear',
          'dither': 'no',
          'correct-downscaling': 'no',
          'linear-downscaling': 'no',
          'sigmoid-upscaling': 'no',
          'hdr-compute-peak': 'no',
          'deband': 'no',
          'interpolation': 'no',
        }.entries) {
          await nativePlayer.setProperty(entry.key, entry.value);
        }
      }

      setupAudioSession();
    }

    await _applyReplayGainSettings();
  }

  @override
  Future<void> dispose() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_audioSession?.setActive(false));
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _crossfadeGeneration++;
    _cancelPlayerStreams();
    _onCompleted?.cancel();
    _onCompleted = null;
    _player?.stop();
    _player?.dispose();
    _player = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void setState(PlayerState state) {
    final newState = state.update(
      playing: _musicPlaybackMode ? !_musicPaused : state.playing,
    );
    lastState = newState;
    _stateController.add(newState);
  }

  void _cancelPlayerStreams() {
    for (final sub in _playerStreamSubs) {
      sub.cancel();
    }
    _playerStreamSubs.clear();
  }

  void _setupPlayerStreams(mpv.Player player) {
    _playerStreamSubs.addAll([
      player.stream.playing.listen((value) {
        setState(lastState.update(playing: value));
      }),
      player.stream.buffering.listen((value) => setState(lastState.update(buffering: value))),
      player.stream.position.listen((value) => setState(lastState.update(position: value))),
      player.stream.duration.listen((value) => setState(lastState.update(duration: value))),
      player.stream.volume.listen((value) {
        setState(lastState.update(volume: value));
      }),
      player.stream.rate.listen((value) => setState(lastState.update(rate: value))),
      player.stream.buffer.listen((value) => setState(lastState.update(buffer: value))),
      player.stream.completed.listen((value) => setState(lastState.update(completed: value))),
    ]);
  }

  Future<void> crossfadeToUrl(String url, Duration startPosition, {double? replayGainDb}) async {
    if (!_settings.enableCrossfade || !VideoPlayerSettingsModel.crossfadeSupportedOnCurrentPlatform) {
      await _applyReplayGainSettings(trackGainDb: replayGainDb);
      await loadVideo(url, true, startPosition: startPosition);
      return;
    }

    final oldPlayer = _player;
    if (oldPlayer == null) {
      await loadVideo(url, true, startPosition: startPosition);
      return;
    }

    const stepMs = 16;
    final steps = math.max(1, _settings.crossfadeDurationMs ~/ stepMs);

    final incomingPlayer = mpv.Player(
      configuration: mpv.PlayerConfiguration(
        title: "nl.jknaapen.fladder",
        libassAndroidFont: libassFallbackFont,
        libassAndroidFontName: libassFallbackFontName,
        libass: !kIsWeb && _settings.useLibass,
        bufferSize: _settings.bufferSize * 1024 * 1024,
      ),
    );

    if (incomingPlayer.platform is mpv.NativePlayer) {
      final native = incomingPlayer.platform as dynamic;
      await native.setProperty('force-seekable', 'yes');
      await native.setProperty('gapless-audio', 'weak');
      await native.setProperty('volume-max', '300');
      if (defaultTargetPlatform == TargetPlatform.android) {
        await native.setProperty('ao', 'audiotrack');
      }
      await native.setProperty('start', '${startPosition.inMilliseconds / 1000}');
    }

    await _applyReplayGainSettings(trackGainDb: replayGainDb, targetPlayer: incomingPlayer);
    _fadeTimer?.cancel();
    _fadeTimer = null;
    await incomingPlayer.setVolume(0.0);
    await incomingPlayer.open(mpv.Media(url), play: true);

    final generation = ++_crossfadeGeneration;
    final fromVolume = oldPlayer.state.volume.clamp(0.0, 300.0);

    bool aborted = false;
    for (var i = 1; i <= steps; i++) {
      if (generation != _crossfadeGeneration) {
        aborted = true;
        break;
      }
      final progress = i / steps;
      await oldPlayer.setVolume(fromVolume * (1.0 - progress));
      await incomingPlayer.setVolume(_preferredVolume * progress);
      if (i < steps) await Future.delayed(const Duration(milliseconds: stepMs));
    }

    if (aborted || generation != _crossfadeGeneration) {
      incomingPlayer.stop();
      incomingPlayer.dispose();
      return;
    }

    _cancelPlayerStreams();
    _player = incomingPlayer;
    _controller = null;
    _setupPlayerStreams(incomingPlayer);

    _retryTimer?.cancel();
    _retryTimer = null;
    _loadCompleter = null;

    oldPlayer.stop();
    oldPlayer.dispose();

    setState(lastState.update(
      playing: incomingPlayer.state.playing,
      buffering: incomingPlayer.state.buffering,
      position: incomingPlayer.state.position,
      duration: incomingPlayer.state.duration,
      volume: _preferredVolume,
      buffer: incomingPlayer.state.buffer,
      completed: false,
    ));
  }

  /// Streams over Tailscale: when the buffer runs dry, pause and wait until a few seconds are buffered,
  /// then resume by itself (instead of stuttering frame by frame). Downloads play from disk, so never pause.
  Future<void> _applyStallPolicy(String url) async {
    if (_player?.platform is! mpv.NativePlayer) return;
    final native = _player!.platform as dynamic;
    final streaming = url.startsWith('http://') || url.startsWith('https://');
    await native.setProperty('cache-pause', streaming ? 'yes' : 'no');
    await native.setProperty('cache-pause-initial', streaming ? 'yes' : 'no');
    await native.setProperty('cache-pause-wait', streaming ? '4' : '0');

    // Per-episode reset: sub-delay is a player property but the UI offset resets per video.
    _subtitleOffset = Duration.zero;
    await native.setProperty('sub-delay', '0');

    if (defaultTargetPlatform == TargetPlatform.android) {
      // mpv can't see the vsync behind Flutter's texture, so it timed frames off the audio clock and they
      // landed on uneven vsyncs (judder). Sync to the display, re-read per video since the panel can change
      // rate; fall back to audio timing when the rate is unknown.
      final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      final refresh = view?.display.refreshRate ?? 0;
      _displaySync = refresh >= 30;
      _lifecycle ??= AppLifecycleListener(onStateChange: (state) {
        // Display sync blocks on a surface nobody presents (screen off/background): use audio timing there.
        final p = _player?.platform;
        if (p is! mpv.NativePlayer) return;
        (p as dynamic).setProperty(
            'video-sync', state == AppLifecycleState.resumed && _displaySync ? 'display-resample' : 'audio');
      });
      if (_displaySync) {
        await native.setProperty('override-display-fps', refresh.toStringAsFixed(2));
        await native.setProperty('video-sync', 'display-resample');
      } else {
        await native.setProperty('video-sync', 'audio');
      }
    }
  }

  @override
  Future<void> loadVideo(String url, bool play, {Duration startPosition = Duration.zero}) async {
    _loadCompleter = Completer<void>();
    _firstLoadAttempt = DateTime.now();

    await setStartPosition(startPosition);
    await _applyStallPolicy(url);

    await _player?.open(mpv.Media(url), play: play);

    _retryTimer?.cancel();
    _retryTimer = null;
    if (_player == null) return;

    _retryTimer = RestartableTimer(
      _currentRetryDuration,
      () async {
        await Future.delayed(const Duration(milliseconds: 150));
        if (DateTime.now().isAfter(_firstLoadAttempt.add(_maxRetryDuration))) {
          log("Max retry duration reached, stopping retries.");
          _retryTimer?.cancel();
          _retryTimer = null;
        } else {
          log("Retrying to load video $url");
          await setStartPosition(startPosition);
          await _player?.open(mpv.Media(url), play: play);
          _retryTimer?.reset();
        }
      },
    );

    // Wait for the player to be ready
    if (_loadCompleter?.isCompleted == false) {
      StreamSubscription? subBuffering;
      StreamSubscription? subDuration;

      void onReady() {
        if (_loadCompleter?.isCompleted == true) return;
        _finishedLoading();
        subBuffering?.cancel();
        subDuration?.cancel();
      }

      subBuffering = _player?.stream.buffering.listen((event) {
        if (event == false && (_player?.state.duration ?? Duration.zero) > Duration.zero) {
          onReady();
        }
      });
      subDuration = _player?.stream.duration.listen((event) {
        if (event > Duration.zero) onReady();
      });
    }

    _loadCompleter?.future.then(
      (value) async {
        // Backup seek in case property didn't work
        if (startPosition != Duration.zero && (_player?.state.position.inSeconds ?? 0) < startPosition.inSeconds - 5) {
          await _player?.seek(startPosition);
        }
      },
    );
    return setState(lastState.update(buffering: true));
  }

  /// Apply ReplayGain normalization for the given [item] before loading it.
  /// Call this before [loadVideo] when starting an audio queue item.
  Future<void> applyReplayGainForItem(ItemBaseModel? item) async {
    double? gainDb;
    if (item is AudioModel) {
      final gain = item.normalizationGain;
      if (gain != null && !gain.isNaN && !gain.isInfinite) {
        gainDb = gain.clamp(-60.0, 0).toDouble();
      }
    }
    await _applyReplayGainSettings(trackGainDb: gainDb);
  }

  double get _replayGainVolumeOffsetDb {
    return _settings.replayGainVolumeLevel.replayGainOffsetDb;
  }

  Future<void> _applyReplayGainSettings({double? trackGainDb, mpv.Player? targetPlayer}) async {
    final player = targetPlayer ?? _player;
    if (player?.platform is! mpv.NativePlayer) {
      return;
    }

    final nativePlayer = player!.platform as dynamic;

    if (!_settings.enableReplayGain) {
      try {
        await nativePlayer.setProperty('af', '');
      } catch (_) {
        // Best effort clear.
      }
      return;
    }

    final replayGainOffsetDb = clampReplayGainDb(_replayGainVolumeOffsetDb);
    final replayGainFallbackDb = _settings.replayGainVolumeLevel.adjustedReplayGainDb(trackGainDb);

    try {
      await nativePlayer.setProperty('replaygain', 'track');
      await nativePlayer.setProperty('replaygain-clip', 'yes');
      await nativePlayer.setProperty('replaygain-fallback', '$replayGainFallbackDb');
      await nativePlayer.setProperty('replaygain-preamp', '$replayGainOffsetDb');
      await nativePlayer.setProperty('af', '');
      _replayGainFallbackLogged = false;
    } catch (error, stackTrace) {
      if (!_replayGainFallbackLogged) {
        log('ReplayGain unsupported by current mpv backend, falling back to loudnorm. $error\n$stackTrace');
      }
      _replayGainFallbackLogged = true;

      try {
        final gainFilter = ',volume=${replayGainFallbackDb}dB';
        await nativePlayer.setProperty('af', 'format=stereo,loudnorm$gainFilter');
      } catch (fallbackError, fallbackStackTrace) {
        log('Unable to set loudnorm fallback filter. $fallbackError\n$fallbackStackTrace');
      }
    }
  }

  Future<void> setStartPosition(Duration position) async {
    if (_player?.platform is mpv.NativePlayer) {
      await (_player?.platform as dynamic).setProperty(
        'start',
        '${position.inMilliseconds / 1000}',
      );
    }
  }

  void _finishedLoading() {
    _loadCompleter?.complete();
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  Future<void> open(BuildContext context) async => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (context) => const video_screen.VideoPlayer(),
        ),
      );

  List<mpv.SubtitleTrack> get subTracks => _player?.state.tracks.subtitle ?? [];
  mpv.SubtitleTrack get subtitleTrack => _player?.state.track.subtitle ?? mpv.SubtitleTrack.no();

  List<mpv.AudioTrack> get audioTracks => _player?.state.tracks.audio ?? [];
  mpv.AudioTrack get audioTrack => _player?.state.track.audio ?? mpv.AudioTrack.no();

  void _startPlaybackFade(bool fadingIn) {
    final player = _player;
    if (player == null) return;

    _fadeTimer?.cancel();

    if (!_settings.enablePlayPauseFade) {
      if (fadingIn) {
        player.play();
      } else {
        player.pause();
      }
      return;
    }

    const stepMs = 16;
    final steps = playPauseFadeDuration.inMilliseconds ~/ stepMs;
    final stepSize = _preferredVolume / steps;

    if (fadingIn) player.play();

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      final p = _player;
      if (p == null) {
        timer.cancel();
        return;
      }
      if (fadingIn) {
        final next = (p.state.volume + stepSize).clamp(0.0, _preferredVolume);
        p.setVolume(next);
        if (next >= _preferredVolume) timer.cancel();
      } else {
        final next = (p.state.volume - stepSize).clamp(0.0, _preferredVolume);
        p.setVolume(next);
        if (next <= 0.0) {
          timer.cancel();
          p.pause();
        }
      }
    });
  }

  @override
  Future<void> pause() async {
    _musicPaused = true;
    setState(lastState.update(playing: false));
    unawaited(_audioSession?.setActive(false));
    _startPlaybackFade(false);
  }

  @override
  Future<void> play() async {
    _musicPaused = false;
    setState(lastState.update(playing: true));
    unawaited(_audioSession?.setActive(true));
    _startPlaybackFade(true);
  }

  @override
  Future<void> playOrPause() async {
    if ((_player?.state.playing ?? lastState.playing) == true) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  // mpv parses tracks asynchronously after open(); at playback start the list is still empty, so a
  // positional lookup would miss and leave mpv on its own default pick. Wait (capped) for [index].
  Future<void> _awaitTrack(int index, int Function(mpv.Tracks) count) async {
    final player = _player;
    if (player == null || index < 0 || count(player.state.tracks) > index + 2) return;
    await player.stream.tracks
        .firstWhere((tracks) => count(tracks) > index + 2)
        .timeout(const Duration(seconds: 5), onTimeout: () => player.state.tracks);
  }

  @override
  Future<int> setAudioTrack(AudioStreamModel? model, PlaybackModel playbackModel) async {
    final wantedAudioStream = model ?? playbackModel.defaultAudioStream;
    if (wantedAudioStream == null) return -1;
    if (wantedAudioStream.index == AudioStreamModel.no().index) {
      await _player?.setAudioTrack(mpv.AudioTrack.no());
    } else {
      final index = (playbackModel.audioStreams?.indexOf(wantedAudioStream) ?? -1) - 1;
      await _awaitTrack(index, (tracks) => tracks.audio.length);
      final internalTracks = audioTracks.getRange(2, audioTracks.length).toList();
      final audioTrack = internalTracks.elementAtOrNull(index);
      if (audioTrack != null) {
        await _player?.setAudioTrack(audioTrack);
      }
    }
    return wantedAudioStream.index;
  }

  @override
  Future<void> setSpeed(double speed) async => _player?.setRate(speed);

  @override
  Future<int> setSubtitleTrack(SubStreamModel? model, PlaybackModel playbackModel) async {
    if (_player == null) return -1;
    final wantedSubtitle = model ?? playbackModel.defaultSubStream;
    if (wantedSubtitle == null || wantedSubtitle.index == SubStreamModel.no().index) {
      await _player?.setSubtitleTrack(mpv.SubtitleTrack.no());
      return -1;
    }
    final index = playbackModel.subStreams?.sublist(1).indexWhere((element) => element.id == wantedSubtitle.id) ?? -1;
    // A delivery URL means the server serves this track separately (external file, or External delivery
    // when transcoding to HLS, where the stream carries no subtitle track) - load it by URL, don't wait.
    final byUrl = wantedSubtitle.isExternal || wantedSubtitle.url != null;
    if (!byUrl) await _awaitTrack(index, (tracks) => tracks.subtitle.length);
    final internalTrack = subTracks.getRange(2, subTracks.length).toList();
    final subTrack = internalTrack.elementAtOrNull(index);
    if (byUrl && wantedSubtitle.url != null && (wantedSubtitle.isExternal || subTrack == null)) {
      await _player?.setSubtitleTrack(mpv.SubtitleTrack.uri(wantedSubtitle.url!));
    } else if (subTrack != null) {
      await _player?.setSubtitleTrack(subTrack);
    }
    // Exactly one renderer per track: plain text goes to the overlay on mobile, styled/bitmap subs stay
    // with libass. Showing both is what doubled every line.
    final isDesktop = defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
    _overlayText.value = !isDesktop && _plainTextCodecs.contains(wantedSubtitle.codec.toLowerCase());
    _bitmapSub.value = _bitmapCodecs.contains(wantedSubtitle.codec.toLowerCase());
    if (_player?.platform?.configuration.libass ?? false) {
      await (_player!.platform as dynamic).setProperty('sub-visibility', _overlayText.value ? 'no' : 'yes');
    } else if (_player?.platform is mpv.NativePlayer) {
      // Without libass the overlay draws text, but bitmap subs (now direct-played, not burned in) need mpv.
      await (_player!.platform as dynamic).setProperty('sub-visibility', _bitmapSub.value ? 'yes' : 'no');
    }
    return wantedSubtitle.index;
  }

  @override
  Future<void> addToPlaylist(String url) async => _player?.add(mpv.Media(url));

  @override
  Future<void> removeFromPlaylist(int index) async => _player?.remove(index);

  @override
  Future<void> playerNext() async => _player?.next();

  @override
  Future<void> playerPrevious() async => _player?.previous();

  @override
  Stream<int> get playlistIndexStream => _player?.stream.playlist.map((p) => p.index) ?? const Stream<int>.empty();

  @override
  Future<void> stop() async {
    unawaited(_audioSession?.setActive(false));
    return _player?.stop();
  }

  @override
  Future<Uint8List?> takeScreenshot() async {
    return _player?.screenshot(format: "image/png", includeLibassSubtitles: true);
  }

  @override
  Widget? videoWidget(
    Key key,
    BoxFit fit,
  ) =>
      _controller == null
          ? null
          : Video(
              key: key,
              controller: _controller!,
              wakelock: false,
              fill: Colors.transparent,
              fit: fit,
              subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
              controls: NoVideoControls,
            );

  @override
  Widget? subtitles(
    bool showOverlay, {
    GlobalKey? controlsKey,
  }) =>
      _controller != null
          ? _VideoSubtitles(
              controller: _controller!,
              overlayText: _overlayText,
              bitmapSub: _bitmapSub,
              showOverlay: showOverlay,
              controlsKey: controlsKey,
            )
          : null;

  @override
  Future<void> shiftSubtitleOffset(Duration offset) async {
    if (_player?.platform is! mpv.NativePlayer) return;

    _subtitleOffset += offset;
    final nativePlayer = _player!.platform as dynamic;
    await nativePlayer.setProperty('sub-delay', (_subtitleOffset.inMilliseconds / 1000).toStringAsFixed(3));
  }

  @override
  Future<void> setVolume(double volume) async {
    _fadeTimer?.cancel();
    _preferredVolume = volume.clamp(0.0, 300.0);
    await _player?.setVolume(_preferredVolume);
  }

  @override
  Future<void> loop(bool loop) async {
    if (loop && _onCompleted == null) {
      _onCompleted = _player?.stream.completed.listen((completed) {
        if (completed) {
          _player?.play();
        }
      });
    } else {
      _onCompleted?.cancel();
    }
  }
}

class _VideoSubtitles extends ConsumerStatefulWidget {
  final VideoController controller;
  final ValueListenable<bool> overlayText;
  final ValueListenable<bool> bitmapSub;
  final bool showOverlay;
  final GlobalKey? controlsKey;

  const _VideoSubtitles({
    required this.controller,
    required this.overlayText,
    required this.bitmapSub,
    this.showOverlay = false,
    this.controlsKey,
  });

  @override
  _VideoSubtitlesState createState() => _VideoSubtitlesState();
}

class _VideoSubtitlesState extends ConsumerState<_VideoSubtitles> {
  late List<String> subtitle;
  String _cachedSubtitleText = '';
  List<String>? _lastSubtitleList;
  StreamSubscription<List<String>>? subscription;

  double? _cachedMenuHeight;

  @override
  void initState() {
    super.initState();
    subtitle = widget.controller.player.state.subtitle;
    subscription = widget.controller.player.stream.subtitle.listen((value) {
      if (mounted) {
        setState(() {
          subtitle = value;
          _lastSubtitleList = null;
        });
      }
    });
    widget.overlayText.addListener(_onTrackKind);
    widget.bitmapSub.addListener(_onTrackKind);
    _liftBurnedInSubs();
  }

  /// Track switched between overlay/libass/bitmap: redraw now and re-apply the lift.
  void _onTrackKind() {
    if (!mounted) return;
    setState(() {});
    _liftBurnedInSubs();
  }

  double? _subPos;

  /// Subs burned in by mpv (ASS/bitmap) can't use the overlay's positioning, so lift them with
  /// mpv's sub-pos while the controls are on screen, Netflix-style.
  void _liftBurnedInSubs() {
    final platform = widget.controller.player.platform;
    if (!(platform?.configuration.libass ?? false)) return;
    final lift = widget.showOverlay && !widget.overlayText.value && !widget.bitmapSub.value;
    final pos = lift ? 85.0 : 100.0;
    if (pos == _subPos) return;
    _subPos = pos;
    (platform as dynamic).setProperty('sub-pos', pos.toStringAsFixed(0));
  }

  @override
  void didUpdateWidget(covariant _VideoSubtitles oldWidget) {
    super.didUpdateWidget(oldWidget);
    _liftBurnedInSubs();
  }

  @override
  void dispose() {
    widget.overlayText.removeListener(_onTrackKind);
    widget.bitmapSub.removeListener(_onTrackKind);
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _measureMenuHeight();

    final settings = ref.watch(subtitleSettingsProvider);
    final padding = MediaQuery.paddingOf(context);

    if (!const ListEquality().equals(subtitle, _lastSubtitleList)) {
      _lastSubtitleList = List<String>.from(subtitle);
      _cachedSubtitleText = subtitle.where((line) => line.trim().isNotEmpty).map((line) => line.trim()).join('\n');
    }

    final text = _cachedSubtitleText;

    final bool isLibassEnabled = widget.controller.player.platform?.configuration.libass ?? false;

    // libass draws styled/bitmap subs itself (sub-visibility=yes); only plain text uses this overlay.
    if ((isLibassEnabled && !widget.overlayText.value) || text.isEmpty) return const SizedBox.shrink();

    final offset = SubtitlePositionCalculator.calculateOffset(
      settings: settings,
      showOverlay: widget.showOverlay,
      screenHeight: MediaQuery.sizeOf(context).height,
      menuHeight: _cachedMenuHeight,
    );

    return SubtitleText(
      subModel: settings,
      padding: padding,
      offset: offset,
      text: text,
    );
  }

  void _measureMenuHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.controlsKey == null) return;

      final RenderBox? renderBox = widget.controlsKey?.currentContext?.findRenderObject() as RenderBox?;
      final newHeight = renderBox?.size.height;

      if (newHeight != _cachedMenuHeight && newHeight != null) {
        setState(() {
          _cachedMenuHeight = newHeight;
        });
      }
    });
  }
}
