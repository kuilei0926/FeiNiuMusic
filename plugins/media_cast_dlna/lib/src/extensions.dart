import '../src/media_cast_dlna_pigeon.dart';

/// Extensions and utilities for the media cast DLNA classes to add object calisthenics behavior
/// while keeping the core classes Pigeon-compatible.

/// Static factory methods for VolumeLevel
class VolumeLevelFactory {
  /// Create volume from percentage with validation
  static VolumeLevel fromPercentage(int percentage) {
    if (percentage < 0 || percentage > 100) {
      throw ArgumentError('Volume percentage must be between 0 and 100');
    }
    return VolumeLevel(percentage: percentage);
  }

  /// Create minimum volume (0%)
  static VolumeLevel minimum() => VolumeLevel(percentage: 0);

  /// Create maximum volume (100%)
  static VolumeLevel maximum() => VolumeLevel(percentage: 100);

  /// Create muted volume (0%)
  static VolumeLevel muted() => VolumeLevel(percentage: 0);

  /// Create medium volume (50%)
  static VolumeLevel medium() => VolumeLevel(percentage: 50);
}

/// Extension methods for VolumeLevel to add object calisthenics behavior
extension VolumeLevelExtensions on VolumeLevel {
  bool get isMuted => percentage == 0;
  bool get isMaximum => percentage == 100;
  bool get isMinimum => percentage == 0;
  bool get isLow => percentage < 30;
  bool get isMedium => percentage >= 30 && percentage <= 70;
  bool get isHigh => percentage > 70;

  VolumeLevel increaseBy(int amount) {
    final newLevel = (percentage + amount).clamp(0, 100);
    return VolumeLevel(percentage: newLevel);
  }

  VolumeLevel decreaseBy(int amount) {
    final newLevel = (percentage - amount).clamp(0, 100);
    return VolumeLevel(percentage: newLevel);
  }

  String get displayString => 'Volume: $percentage%';
}

/// Static factory methods for MuteState
class MuteStateFactory {
  /// Create muted state
  static MuteState muted() => MuteState(isMuted: true);

  /// Create unmuted state
  static MuteState unmuted() => MuteState(isMuted: false);

  /// Create from boolean value
  static MuteState fromBoolean(bool isMuted) => MuteState(isMuted: isMuted);
}

/// Extension methods for MuteState to add object calisthenics behavior
extension MuteStateExtensions on MuteState {
  bool get isUnmuted => !isMuted;

  MuteState toggle() => MuteState(isMuted: !isMuted);
}

/// Extension methods for VolumeInfo to add object calisthenics behavior
extension VolumeInfoExtensions on VolumeInfo {
  /// Get effective volume considering mute state
  VolumeLevel get effectiveLevel {
    return muteState.isMuted ? VolumeLevel(percentage: 0) : level;
  }

  /// Check if volume is effectively audible
  bool get isAudible => !muteState.isMuted && !level.isMuted;

  VolumeInfo withLevel(VolumeLevel newLevel) {
    return VolumeInfo(level: newLevel, muteState: muteState);
  }

  VolumeInfo withMuteState(MuteState newMuteState) {
    return VolumeInfo(level: level, muteState: newMuteState);
  }

  VolumeInfo mute() {
    return VolumeInfo(level: level, muteState: MuteState(isMuted: true));
  }

  VolumeInfo unmute() {
    return VolumeInfo(level: level, muteState: MuteState(isMuted: false));
  }
}

/// Static factory methods for MuteOperation
class MuteOperationFactory {
  /// Create mute operation
  static MuteOperation mute() => MuteOperation(shouldMute: true);

  /// Create unmute operation
  static MuteOperation unmute() => MuteOperation(shouldMute: false);

  /// Create from boolean
  static MuteOperation fromBoolean(bool shouldMute) =>
      MuteOperation(shouldMute: shouldMute);
}

/// Extension methods for MuteOperation to add object calisthenics behavior
extension MuteOperationExtensions on MuteOperation {
  bool get shouldUnmute => !shouldMute;
}

/// Static factory methods for TimePosition
class TimePositionFactory {
  /// Create position from seconds with validation
  static TimePosition fromSeconds(int seconds) {
    if (seconds < 0) {
      throw ArgumentError('Time position cannot be negative');
    }
    return TimePosition(seconds: seconds);
  }

  /// Create position at start (0 seconds)
  static TimePosition start() => TimePosition(seconds: 0);

  /// Create position from minutes and seconds
  static TimePosition fromMinutesAndSeconds(int minutes, int seconds) {
    if (minutes < 0 || seconds < 0) {
      throw ArgumentError('Time components cannot be negative');
    }
    return TimePosition(seconds: minutes * 60 + seconds);
  }
}

/// Extension methods for TimePosition to add object calisthenics behavior
extension TimePositionExtensions on TimePosition {
  int get totalMinutes => seconds ~/ 60;
  int get remainingSeconds => seconds % 60;
  bool get isAtStart => seconds == 0;

  TimePosition add(Duration duration) {
    return TimePosition(seconds: seconds + duration.inSeconds);
  }

  TimePosition subtract(Duration duration) {
    final newSeconds = (seconds - duration.inSeconds)
        .clamp(0, double.infinity)
        .toInt();
    return TimePosition(seconds: newSeconds);
  }

  bool isAfter(TimePosition other) => seconds > other.seconds;
  bool isBefore(TimePosition other) => seconds < other.seconds;

  String get displayString =>
      'TimePosition(${totalMinutes}m ${remainingSeconds}s)';
}

/// Static factory methods for TimeDuration
class TimeDurationFactory {
  /// Create duration from seconds with validation
  static TimeDuration fromSeconds(int seconds) {
    if (seconds < 0) {
      throw ArgumentError('Duration cannot be negative');
    }
    return TimeDuration(seconds: seconds);
  }

  /// Create zero duration
  static TimeDuration zero() => TimeDuration(seconds: 0);

  /// Create duration from minutes and seconds
  static TimeDuration fromMinutesAndSeconds(int minutes, int seconds) {
    if (minutes < 0 || seconds < 0) {
      throw ArgumentError('Duration components cannot be negative');
    }
    return TimeDuration(seconds: minutes * 60 + seconds);
  }
}

/// Extension methods for TimeDuration to add object calisthenics behavior
extension TimeDurationExtensions on TimeDuration {
  int get totalMinutes => seconds ~/ 60;
  int get remainingSeconds => seconds % 60;
  bool get isZero => seconds == 0;
  bool get isShort => seconds < 60; // Less than 1 minute
  bool get isLong => seconds > 3600; // More than 1 hour

  TimeDuration add(TimeDuration other) {
    return TimeDuration(seconds: seconds + other.seconds);
  }

  TimeDuration subtract(TimeDuration other) {
    final newSeconds = (seconds - other.seconds)
        .clamp(0, double.infinity)
        .toInt();
    return TimeDuration(seconds: newSeconds);
  }

  bool isLongerThan(TimeDuration other) => seconds > other.seconds;
  bool isShorterThan(TimeDuration other) => seconds < other.seconds;

  String get displayString =>
      'TimeDuration(${totalMinutes}m ${remainingSeconds}s)';
}

/// Extension methods for PlaybackInfo to add object calisthenics behavior
extension PlaybackInfoExtensions on PlaybackInfo {
  /// Calculate remaining time
  TimeDuration get remainingTime {
    final remainingSeconds = duration.seconds - position.seconds;
    return TimeDuration(
      seconds: remainingSeconds.clamp(0, double.infinity).toInt(),
    );
  }

  /// Calculate progress percentage (0-100)
  int get progressPercentage {
    if (duration.isZero) return 0;
    return ((position.seconds / duration.seconds) * 100).round().clamp(0, 100);
  }

  /// Check if playback is near end (within 10 seconds)
  bool get isNearEnd {
    return remainingTime.seconds <= 10;
  }

  /// Check if playback is at start
  bool get isAtStart => position.isAtStart;
}

/// Static factory methods for DeviceUdn
class DeviceUdnFactory {
  /// Create UDN from string value with validation
  static DeviceUdn fromString(String value) {
    if (value.isEmpty) {
      throw ArgumentError('UDN cannot be empty');
    }
    return DeviceUdn(value: value);
  }

  /// Create UDN with uuid prefix
  static DeviceUdn withUuid(String uuid) {
    if (uuid.isEmpty) {
      throw ArgumentError('UUID cannot be empty');
    }
    return DeviceUdn(value: 'uuid:$uuid');
  }
}

/// Extension methods for DeviceUdn to add object calisthenics behavior
extension DeviceUdnExtensions on DeviceUdn {
  /// Check if UDN is valid UUID format
  bool get isUuidFormat => value.startsWith('uuid:');

  /// Get the UUID part if this is a UUID format UDN
  String? get uuid => isUuidFormat ? value.substring(5) : null;
}

/// Static factory methods for Url
class UrlFactory {
  /// Create URL from string with validation
  static Url fromString(String url) {
    if (url.isEmpty) {
      throw ArgumentError('URL cannot be empty');
    }
    // Basic URL validation
    if (!url.startsWith('http://') &&
        !url.startsWith('https://') &&
        !url.startsWith('ftp://')) {
      throw ArgumentError('URL must start with a valid protocol');
    }
    return Url(value: url);
  }

  /// Create HTTP URL
  static Url http(String host, {int port = 80, String path = ''}) {
    final portPart = port == 80 ? '' : ':$port';
    return Url(value: 'http://$host$portPart$path');
  }

  /// Create HTTPS URL
  static Url https(String host, {int port = 443, String path = ''}) {
    final portPart = port == 443 ? '' : ':$port';
    return Url(value: 'https://$host$portPart$path');
  }
}

/// Extension methods for Url to add object calisthenics behavior
extension UrlExtensions on Url {
  bool get isHttp => value.startsWith('http://');
  bool get isHttps => value.startsWith('https://');
  bool get isSecure => isHttps;
}

/// Static factory methods for IpAddress
class IpAddressFactory {
  /// Create IP address from string with validation
  static IpAddress fromString(String ipAddress) {
    if (ipAddress.isEmpty) {
      throw ArgumentError('IP address cannot be empty');
    }
    // Basic IPv4 validation
    final parts = ipAddress.split('.');
    if (parts.length != 4) {
      throw ArgumentError('Invalid IPv4 address format');
    }
    for (final part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) {
        throw ArgumentError('Invalid IPv4 address: each octet must be 0-255');
      }
    }
    return IpAddress(value: ipAddress);
  }

  /// Create localhost IP address
  static IpAddress localhost() => IpAddress(value: '127.0.0.1');

  /// Create any IP address (0.0.0.0)
  static IpAddress any() => IpAddress(value: '0.0.0.0');
}

/// Extension methods for IpAddress to add object calisthenics behavior
extension IpAddressExtensions on IpAddress {
  bool get isLocalhost => value == '127.0.0.1';
  bool get isPrivate =>
      value.startsWith('192.168.') ||
      value.startsWith('10.') ||
      value.startsWith('172.');
  bool get isAny => value == '0.0.0.0';
}

/// Static factory methods for NetworkPort
class NetworkPortFactory {
  /// Create port from integer with validation
  static NetworkPort fromInt(int port) {
    if (port < 1 || port > 65535) {
      throw ArgumentError('Port must be between 1 and 65535');
    }
    return NetworkPort(value: port);
  }

  /// Create HTTP port (80)
  static NetworkPort http() => NetworkPort(value: 80);

  /// Create HTTPS port (443)
  static NetworkPort https() => NetworkPort(value: 443);

  /// Create FTP port (21)
  static NetworkPort ftp() => NetworkPort(value: 21);

  /// Create DLNA port (1900)
  static NetworkPort dlna() => NetworkPort(value: 1900);
}

/// Extension methods for NetworkPort to add object calisthenics behavior
extension NetworkPortExtensions on NetworkPort {
  bool get isWellKnown => value < 1024;
  bool get isEphemeral => value >= 32768;
  bool get isHttp => value == 80;
  bool get isHttps => value == 443;
}

/// Static factory methods for DiscoveryTimeout
class DiscoveryTimeoutFactory {
  /// Create timeout from seconds with validation
  static DiscoveryTimeout fromSeconds(int seconds) {
    if (seconds <= 0) {
      throw ArgumentError('Discovery timeout must be positive');
    }
    return DiscoveryTimeout(seconds: seconds);
  }

  /// Create short timeout (3 seconds)
  static DiscoveryTimeout short() => DiscoveryTimeout(seconds: 3);

  /// Create standard timeout (5 seconds)
  static DiscoveryTimeout standard() => DiscoveryTimeout(seconds: 5);

  /// Create long timeout (10 seconds)
  static DiscoveryTimeout long() => DiscoveryTimeout(seconds: 10);

  /// Create extended timeout (30 seconds)
  static DiscoveryTimeout extended() => DiscoveryTimeout(seconds: 30);
}

/// Extension methods for DiscoveryTimeout to add object calisthenics behavior
extension DiscoveryTimeoutExtensions on DiscoveryTimeout {
  bool get isShort => seconds <= 3;
  bool get isStandard => seconds == 5;
  bool get isLong => seconds >= 10;
}

/// Static factory methods for SearchTarget
class SearchTargetFactory {
  /// Create search target from string with validation
  static SearchTarget fromString(String target) {
    if (target.isEmpty) {
      throw ArgumentError('Search target cannot be empty');
    }
    return SearchTarget(target: target);
  }

  /// Search for all root devices
  static SearchTarget rootDevice() => SearchTarget(target: 'upnp:rootdevice');

  /// Search for all SSDP devices
  static SearchTarget all() => SearchTarget(target: 'ssdp:all');

  /// Search for media renderers
  static SearchTarget mediaRenderer() =>
      SearchTarget(target: 'urn:schemas-upnp-org:device:MediaRenderer:1');

  /// Search for media servers
  static SearchTarget mediaServer() =>
      SearchTarget(target: 'urn:schemas-upnp-org:device:MediaServer:1');
}

/// Extension methods for SearchTarget to add object calisthenics behavior
extension SearchTargetExtensions on SearchTarget {
  bool get isRootDevice => target == 'upnp:rootdevice';
  bool get isAll => target == 'ssdp:all';
  bool get isMediaRenderer => target.contains('MediaRenderer');
  bool get isMediaServer => target.contains('MediaServer');
}

/// Static factory methods for DiscoveryOptions
class DiscoveryOptionsFactory {
  /// Create options for media renderers with standard timeout
  static DiscoveryOptions mediaRenderers() => DiscoveryOptions(
    searchTarget: SearchTarget(
      target: 'urn:schemas-upnp-org:device:MediaRenderer:1',
    ),
    timeout: DiscoveryTimeout(seconds: 5),
  );

  /// Create options for media servers with standard timeout
  static DiscoveryOptions mediaServers() => DiscoveryOptions(
    searchTarget: SearchTarget(
      target: 'urn:schemas-upnp-org:device:MediaServer:1',
    ),
    timeout: DiscoveryTimeout(seconds: 5),
  );

  /// Create options for all devices with extended timeout
  static DiscoveryOptions allDevices() => DiscoveryOptions(
    searchTarget: SearchTarget(target: 'ssdp:all'),
    timeout: DiscoveryTimeout(seconds: 30),
  );

  /// Create quick discovery options
  static DiscoveryOptions quick() => DiscoveryOptions(
    searchTarget: SearchTarget(target: 'upnp:rootdevice'),
    timeout: DiscoveryTimeout(seconds: 3),
  );
}

/// Extension methods for DiscoveryOptions to add object calisthenics behavior
extension DiscoveryOptionsExtensions on DiscoveryOptions {}

/// Utility class for creating common volume levels
class VolumePresets {
  static VolumeLevel get silent => VolumeLevel(percentage: 0);
  static VolumeLevel get whisper => VolumeLevel(percentage: 10);
  static VolumeLevel get low => VolumeLevel(percentage: 25);
  static VolumeLevel get medium => VolumeLevel(percentage: 50);
  static VolumeLevel get high => VolumeLevel(percentage: 75);
  static VolumeLevel get maximum => VolumeLevel(percentage: 100);
}

/// Utility class for creating common time positions
class TimePresets {
  static TimePosition get start => TimePosition(seconds: 0);
  static TimePosition get tenSeconds => TimePosition(seconds: 10);
  static TimePosition get thirtySeconds => TimePosition(seconds: 30);
  static TimePosition get oneMinute => TimePosition(seconds: 60);
  static TimePosition get fiveMinutes => TimePosition(seconds: 300);
}

/// Utility class for creating common durations
class DurationPresets {
  static TimeDuration get zero => TimeDuration(seconds: 0);
  static TimeDuration get short => TimeDuration(seconds: 30); // 30 seconds
  static TimeDuration get medium => TimeDuration(seconds: 180); // 3 minutes
  static TimeDuration get long => TimeDuration(seconds: 600); // 10 minutes
  static TimeDuration get movie => TimeDuration(seconds: 7200); // 2 hours
}
