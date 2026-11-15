import 'package:flutter/material.dart';

import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/util/bitrate_helper.dart';

part 'transcode_download_model.freezed.dart';
part 'transcode_download_model.g.dart';

@Freezed(copyWith: true)
abstract class TranscodeDownloadModel with _$TranscodeDownloadModel {
  const TranscodeDownloadModel._();

  factory TranscodeDownloadModel({
    @Default(false) bool enabled,
    required VideoCodec videoCodec,
    required AudioCodec audioCodec,
    required MaxHeight maxHeight,
    required VideoContainer container,
    required Bitrate maxBitrate,
  }) = _TranscodeDownloadModel;

  static TranscodeDownloadModel fromDefaults() {
    return TranscodeDownloadModel(
      enabled: false,
      videoCodec: VideoCodec.h264,
      audioCodec: AudioCodec.aac,
      maxHeight: MaxHeight.p480,
      container: VideoContainer.mp4,
      maxBitrate: Bitrate.b4Mbps,
    );
  }

  factory TranscodeDownloadModel.fromJson(Map<String, dynamic> json) => _$TranscodeDownloadModelFromJson(json);

  Map<String, String> curlHeaders(Duration duration, {ItemBaseModel? item}) => {
        'User-Agent': 'curl/8.0.1',
        'Accept': '*/*',
        'Connection': 'keep-alive',
        "Known-Content-Length": calculatedContentLength(duration, item: item).toString(),
      };

  /// Estimates download file size based on bitrate and duration.
  /// Adds 10% overhead for container and metadata.
  int calculatedContentLength(Duration duration, {ItemBaseModel? item}) {
    final seconds = duration.inSeconds;
    if (seconds <= 0) return 0;
    final bitrateValue = maxBitrate.bitRate ?? item?.streamModel?.videoStreams.firstOrNull?.bitRate ?? 4000000;
    return ((bitrateValue * seconds) / 8 * 1.1).floor();
  }

  /// Device profile for download transcoding.
  /// Uses HTTP protocol instead of HLS so the server returns a complete file URL.
  DeviceProfile get deviceProfile => DeviceProfile(
        maxStreamingBitrate: maxBitrate.bitRate,
        maxStaticBitrate: maxBitrate.bitRate,
        directPlayProfiles: const [
          DirectPlayProfile(type: DlnaProfileType.video),
          DirectPlayProfile(type: DlnaProfileType.audio),
        ],
        transcodingProfiles: [
          TranscodingProfile(
            audioCodec: audioCodec.name.toLowerCase(),
            container: container.name.toLowerCase(),
            maxAudioChannels: '2',
            protocol: MediaStreamProtocol.http,
            type: DlnaProfileType.video,
            videoCodec: videoCodec.name.toLowerCase(),
          ),
        ],
        containerProfiles: const [],
        subtitleProfiles: const [
          SubtitleProfile(format: 'vtt', method: SubtitleDeliveryMethod.$external),
          SubtitleProfile(format: 'ass', method: SubtitleDeliveryMethod.$external),
          SubtitleProfile(format: 'ssa', method: SubtitleDeliveryMethod.$external),
          SubtitleProfile(format: 'pgssub', method: SubtitleDeliveryMethod.$external),
        ],
      );

  DownloadQuality get quality => !enabled
      ? DownloadQuality.original
      : switch (maxHeight) {
          MaxHeight.p480 => DownloadQuality.p480,
          MaxHeight.p720 => DownloadQuality.p720,
          _ => DownloadQuality.p1080,
        };

  String label(BuildContext context) => quality.label;
}

/// The only download choice shown to users: keep the server's file, or shrink it to a resolution.
/// Shrunk downloads are always H.264/AAC in MP4, which plays everywhere.
enum DownloadQuality {
  original('Original (same as on the server)', null, null),
  p1080('1080p', MaxHeight.p1080, Bitrate.b10Mbps),
  p720('720p (smaller)', MaxHeight.p720, Bitrate.b4Mbps),
  p480('480p (smallest)', MaxHeight.p480, Bitrate.b1_5Mbps);

  final String label;
  final MaxHeight? height;
  final Bitrate? bitrate;
  const DownloadQuality(this.label, this.height, this.bitrate);

  TranscodeDownloadModel get model => this == original
      ? TranscodeDownloadModel.fromDefaults()
      : TranscodeDownloadModel(
          enabled: true,
          videoCodec: VideoCodec.h264,
          audioCodec: AudioCodec.aac,
          maxHeight: height!,
          container: VideoContainer.mp4,
          maxBitrate: bitrate!,
        );
}

enum VideoCodec {
  h264,
  h265,
  vp9,
  av1;

  const VideoCodec();
  String get name => switch (this) {
        VideoCodec.h264 => "H264",
        VideoCodec.h265 => "H265",
        VideoCodec.vp9 => "VP9",
        VideoCodec.av1 => "AV1"
      };
}

enum AudioCodec {
  aac,
  mp3,
  opus,
  vorbis;

  const AudioCodec();

  String get name => switch (this) {
        AudioCodec.aac => "AAC",
        AudioCodec.mp3 => "MP3",
        AudioCodec.opus => "Opus",
        AudioCodec.vorbis => "Vorbis"
      };
}

enum MaxHeight {
  p480,
  p720,
  p1080,
  p1440,
  p2160;

  const MaxHeight();

  String get label => switch (this) {
        MaxHeight.p480 => "480",
        MaxHeight.p720 => "720",
        MaxHeight.p1080 => "1080",
        MaxHeight.p1440 => "1440",
        MaxHeight.p2160 => "2160"
      };

  int get value => switch (this) {
        MaxHeight.p480 => 480,
        MaxHeight.p720 => 720,
        MaxHeight.p1080 => 1080,
        MaxHeight.p1440 => 1440,
        MaxHeight.p2160 => 2160
      };
}

enum VideoContainer {
  mp4,
  mkv,
  webm;

  const VideoContainer();

  String get name => switch (this) {
        VideoContainer.mp4 => "mp4",
        VideoContainer.mkv => "mkv",
        VideoContainer.webm => "webm",
      };

  String get extension => switch (this) {
        VideoContainer.mp4 => ".mp4",
        VideoContainer.mkv => ".mkv",
        VideoContainer.webm => ".webm",
      };
}
