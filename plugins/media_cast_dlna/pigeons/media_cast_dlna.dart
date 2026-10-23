import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/media_cast_dlna_pigeon.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/br/com/felnanuke2/media_cast_dlna/MediaCastDlnaPigeon.kt',
    kotlinOptions: KotlinOptions(),
    swiftOut:
        'ios/media_cast_dlna/Sources/media_cast_dlna/MediaCastDlnaPigeon.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'media_cast_dlna',
  ),
)
/// Represents a Unique Device Name (UDN) following object calisthenics
class DeviceUdn {
  DeviceUdn({required this.value});
  final String value;
}

/// Volume level representation following object calisthenics
class VolumeLevel {
  VolumeLevel({required this.percentage});
  final int percentage;
}

/// Mute state representation
class MuteState {
  MuteState({required this.isMuted});
  final bool isMuted;
}

/// Volume information combining level and mute state
class VolumeInfo {
  VolumeInfo({required this.level, required this.muteState});
  final VolumeLevel level;
  final MuteState muteState;
}

/// Represents a mute operation
class MuteOperation {
  MuteOperation({required this.shouldMute});
  final bool shouldMute;
}

/// Represents a position in time (seconds)
class TimePosition {
  TimePosition({required this.seconds});
  final int seconds;
}

/// Represents a duration in time (seconds)
class TimeDuration {
  TimeDuration({required this.seconds});
  final int seconds;
}

/// Represents a URL following object calisthenics
class Url {
  Url({required this.value});
  final String value;
}

/// Represents an IP address following object calisthenics
class IpAddress {
  IpAddress({required this.value});
  final String value;
}

/// Represents a network port following object calisthenics
class NetworkPort {
  NetworkPort({required this.value});
  final int value;
}

/// Represents a discovery timeout following object calisthenics
class DiscoveryTimeout {
  DiscoveryTimeout({required this.seconds});
  final int seconds;
}

/// Represents a search target for discovery
class SearchTarget {
  SearchTarget({required this.target});
  final String target;
}

/// Discovery options with descriptive classes
class DiscoveryOptions {
  DiscoveryOptions({this.searchTarget, required this.timeout});
  final SearchTarget? searchTarget;
  final DiscoveryTimeout timeout;
}

/// Represents a device icon with its properties
class DeviceIcon {
  DeviceIcon({
    required this.mimeType,
    required this.width,
    required this.height,
    required this.uri,
  });

  final String mimeType;
  final int width;
  final int height;
  final Url uri;
}

/// Represents detailed manufacturer information for a device
class ManufacturerDetails {
  ManufacturerDetails({required this.manufacturer, this.manufacturerUri});

  final String manufacturer;
  final Url? manufacturerUri;
}

/// Represents detailed model information for a device
class ModelDetails {
  ModelDetails({
    required this.modelName,
    this.modelDescription,
    this.modelNumber,
    this.modelUri,
  });

  final String modelName;
  final String? modelDescription;
  final String? modelNumber;
  final Url? modelUri;
}

/// Represents a UPnP/DLNA device discovered on the network
class DlnaDevice {
  DlnaDevice({
    required this.udn,
    required this.friendlyName,
    required this.deviceType,
    required this.manufacturerDetails,
    required this.modelDetails,
    required this.ipAddress,
    required this.port,
    this.presentationUrl,
    this.icons,
  });

  final DeviceUdn udn;
  final String friendlyName;
  final String deviceType;
  final ManufacturerDetails manufacturerDetails;
  final ModelDetails modelDetails;
  final IpAddress ipAddress;
  final NetworkPort port;
  final Url? presentationUrl;
  final List<DeviceIcon>? icons;
}

/// Represents a UPnP service available on a device
class DlnaService {
  DlnaService({
    required this.serviceType,
    required this.serviceId,
    required this.scpdUrl,
    required this.controlUrl,
    required this.eventSubUrl,
  });

  final String serviceType;
  final String serviceId;
  final Url scpdUrl;
  final Url controlUrl;
  final Url eventSubUrl;
}

/// Represents a subtitle track
class SubtitleTrack {
  SubtitleTrack({
    required this.id,
    required this.uri,
    required this.mimeType,
    required this.language,
    this.title,
    this.isDefault,
  });

  final String id;
  final Url uri;
  final String mimeType;
  final String language;
  final String? title;
  final bool? isDefault;
}

/// Abstract class for media metadata
sealed class MediaMetadata {}

/// Audio-specific metadata
class AudioMetadata extends MediaMetadata {
  AudioMetadata({
    this.artist,
    this.album,
    this.genre,
    this.duration,
    this.albumArtUri,
    this.description,
    this.originalTrackNumber,
    this.upnpClass = 'object.item.audioItem.musicTrack',
    this.title,
  });

  final String? artist;
  final String? album;
  final String? genre;
  final TimeDuration? duration;
  final Url? albumArtUri;
  final String? description;
  final int? originalTrackNumber;
  final String? upnpClass;
  final String? title;
}

/// Video-specific metadata
class VideoMetadata extends MediaMetadata {
  VideoMetadata({
    this.resolution,
    this.duration,
    this.description,
    this.thumbnailUri,
    this.genre,
    this.upnpClass = 'object.item.videoItem.movie',
    this.bitrate,
    this.title,
  });

  final String? resolution;
  final TimeDuration? duration;
  final String? description;
  final Url? thumbnailUri;
  final String? genre;
  final String? upnpClass;
  final int? bitrate;
  final String? title;
}

/// Image-specific metadata
class ImageMetadata extends MediaMetadata {
  ImageMetadata({
    this.resolution,
    this.description,
    this.thumbnailUri,
    this.date,
    this.upnpClass = 'object.item.imageItem.photo',
    this.title,
  });

  final String? resolution;
  final String? description;
  final Url? thumbnailUri;
  final String? date;
  final String? upnpClass;
  final String? title;
}

/// Represents media content that can be played
class MediaItem {
  MediaItem({
    required this.id,
    required this.title,
    required this.uri,
    required this.mimeType,
    this.metadata,
    this.size,
    this.subtitleTracks,
  });

  final String id;
  final String title;
  final Url uri;
  final String mimeType;
  final MediaMetadata? metadata;
  final int? size;
  final List<SubtitleTrack>? subtitleTracks;
}

/// Represents the current transport state
enum TransportState { stopped, playing, paused, transitioning, noMediaPresent }

/// Represents playback information with descriptive time classes
class PlaybackInfo {
  PlaybackInfo({
    required this.state,
    required this.position,
    required this.duration,
    this.currentTrackUri,
    this.currentTrackMetadata,
  });

  final TransportState state;
  final TimePosition position;
  final TimeDuration duration;
  final String? currentTrackUri;
  final MediaMetadata? currentTrackMetadata;
}

/// Host API for device discovery and control
@HostApi()
abstract class MediaCastDlnaApi {
  // ==== Initialization ====

  @async
  void initializeUpnpService();

  @async
  bool isUpnpServiceInitialized();

  @async
  void shutdownUpnpService();

  // ==== Discovery Methods ====

  @async
  void startDiscovery(DiscoveryOptions options);

  @async
  void stopDiscovery();

  @async
  List<DlnaDevice> getDiscoveredDevices();

  @async
  DlnaDevice? refreshDevice(DeviceUdn deviceUdn);

  // ==== Device Services ====

  @async
  List<DlnaService> getDeviceServices(DeviceUdn deviceUdn);

  @async
  bool hasService(DeviceUdn deviceUdn, String serviceType);

  @async
  bool isDeviceOnline(DeviceUdn deviceUdn);

  // ==== Media Renderer Control ====

  @async
  void setMediaUri(DeviceUdn deviceUdn, Url uri, MediaMetadata metadata);

  @async
  void setMediaUriWithSubtitles(
    DeviceUdn deviceUdn,
    Url uri,
    MediaMetadata metadata,
    List<SubtitleTrack> subtitleTracks,
  );

  @async
  bool supportsSubtitleControl(DeviceUdn deviceUdn);

  @async
  void setSubtitleTrack(DeviceUdn deviceUdn, String? subtitleTrackId);

  @async
  List<SubtitleTrack> getAvailableSubtitleTracks(DeviceUdn deviceUdn);

  @async
  SubtitleTrack? getCurrentSubtitleTrack(DeviceUdn deviceUdn);

  @async
  void play(DeviceUdn deviceUdn);

  @async
  void pause(DeviceUdn deviceUdn);

  @async
  void stop(DeviceUdn deviceUdn);

  @async
  void seek(DeviceUdn deviceUdn, TimePosition position);

  // ==== Volume Control ====

  @async
  void setVolume(DeviceUdn deviceUdn, VolumeLevel volumeLevel);

  @async
  VolumeInfo getVolumeInfo(DeviceUdn deviceUdn);

  @async
  void setMute(DeviceUdn deviceUdn, MuteOperation muteOperation);

  // ==== Playback Status ====

  @async
  PlaybackInfo getPlaybackInfo(DeviceUdn deviceUdn);

  @async
  TimePosition getCurrentPosition(DeviceUdn deviceUdn);

  @async
  TransportState getTransportState(DeviceUdn deviceUdn);

  @async
  SupportedPlaybackSpeeds getSupportedPlaybackSpeeds(DeviceUdn deviceUdn);

  @async
  void setPlaybackSpeed(DeviceUdn deviceUdn, PlaybackSpeed speed);

  /// This method is designed mainly for iOS platform and
  /// the use is for once Multicast DNS is restricted on
  /// iOS you can specify a local IP and port to let the plugin return a device for that IP and port
  /// this will throw an exception if you try to use it on Android
  /// this will return null if the device is not found
  @async
  DlnaDevice? getDeviceManually(Url uri);
}

class PlaybackSpeed {
  PlaybackSpeed({required this.value});
  final double value;
}

class PlaybackSpeedToken {
  PlaybackSpeedToken({required this.value});
  final String value;
}

class SupportedPlaybackSpeeds {
  SupportedPlaybackSpeeds({required this.values});
  final List<PlaybackSpeedToken> values;
}

/// Flutter API for discovery events to avoid polling getDiscoveredDevices.
@FlutterApi()
abstract class DiscoveryEventsFlutterApi {
  void onDeviceFound(DlnaDevice device);

  void onDeviceLost(DeviceUdn deviceUdn);

  /// Emitted when a MediaRenderer becomes unavailable on the network.
  void onRendererOffline(DeviceUdn deviceUdn);
}
