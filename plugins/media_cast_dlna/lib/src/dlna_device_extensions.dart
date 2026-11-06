import 'media_cast_dlna_pigeon.dart';

/// Extensions for DlnaDevice to provide enhanced functionality
extension DlnaDeviceExtensions on DlnaDevice {
  /// Compares two DlnaDevice instances by their UDN (Unique Device Name)
  ///
  /// UDN is the standard unique identifier for UPnP/DLNA devices.
  /// This method ensures proper device comparison for deduplication
  /// and device management operations.
  ///
  /// Returns true if both devices have the same UDN, false otherwise.
  bool hasSameUdn(DlnaDevice other) {
    return udn.value == other.udn.value;
  }

  /// Checks if this device matches the given UDN string
  ///
  /// This is useful for finding devices in collections by their UDN
  /// without needing to create a DlnaDevice instance for comparison.
  ///
  /// Returns true if the device's UDN matches the provided UDN string.
  bool matchesUdn(String deviceUdn) {
    return udn.value == deviceUdn;
  }

  /// Returns true if this device is a media renderer
  ///
  /// Media renderers are devices that can play media content
  /// (e.g., smart TVs, media players, speakers)
  bool get isRenderer {
    return deviceType.toLowerCase().contains('renderer');
  }

  /// Returns true if this device is a media server
  ///
  /// Media servers are devices that provide media content
  /// (e.g., NAS devices, media libraries)
  bool get isServer {
    return deviceType.toLowerCase().contains('server');
  }

  /// Returns a human-readable string representation of the device
  String get displayInfo {
    return '$friendlyName (${manufacturerDetails.manufacturer} - ${modelDetails.modelName}) at ${ipAddress.value}:${port.value}';
  }
}

/// Extension on `List<DlnaDevice>` to provide collection-specific operations
extension DlnaDeviceListExtensions on List<DlnaDevice> {
  /// Finds a device by UDN in the list
  ///
  /// Returns the device if found, null otherwise.
  DlnaDevice? findByUdn(String udn) {
    try {
      return firstWhere((device) => device.matchesUdn(udn));
    } catch (e) {
      return null;
    }
  }

  /// Gets the index of a device with the specified UDN
  ///
  /// Returns the index if found, -1 otherwise.
  int indexOfUdn(String udn) {
    return indexWhere((device) => device.matchesUdn(udn));
  }

  /// Adds or updates a device in the list based on UDN
  ///
  /// If a device with the same UDN exists, it updates the existing entry.
  /// If no device with the UDN exists, it adds the new device.
  /// This prevents duplicates while allowing device updates.
  void addOrUpdate(DlnaDevice device) {
    final existingIndex = indexOfUdn(device.udn.value);
    if (existingIndex != -1) {
      // Update existing device
      this[existingIndex] = device;
    } else {
      // Add new device
      add(device);
    }
  }

  /// Removes a device by UDN from the list
  ///
  /// Returns true if a device was removed, false if no device with the UDN was found.
  bool removeByUdn(String udn) {
    final initialLength = length;
    removeWhere((device) => device.matchesUdn(udn));
    return length < initialLength;
  }

  /// Gets all renderer devices from the list
  List<DlnaDevice> get renderers {
    return where((device) => device.isRenderer).toList();
  }

  /// Gets all server devices from the list
  List<DlnaDevice> get servers {
    return where((device) => device.isServer).toList();
  }
}
