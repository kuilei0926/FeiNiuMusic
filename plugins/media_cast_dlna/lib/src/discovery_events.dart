import 'dart:async';

import 'package:flutter/services.dart';

import 'media_cast_dlna_pigeon.dart';

/// Receives native discovery callbacks and exposes them as Dart streams.
class MediaCastDlnaDiscoveryEvents {
  MediaCastDlnaDiscoveryEvents({BinaryMessenger? binaryMessenger}) {
    _handler = _DiscoveryEventsHandler(
      onDeviceFound: _handleDeviceFound,
      onDeviceLost: _handleDeviceLost,
      onRendererOffline: _handleRendererOffline,
    );
    DiscoveryEventsFlutterApi.setUp(_handler, binaryMessenger: binaryMessenger);
  }

  late final _DiscoveryEventsHandler _handler;

  final StreamController<DlnaDevice> _onDeviceFoundController =
      StreamController<DlnaDevice>.broadcast();
  final StreamController<DeviceUdn> _onDeviceLostController =
      StreamController<DeviceUdn>.broadcast();
  final StreamController<DeviceUdn> _onRendererOfflineController =
      StreamController<DeviceUdn>.broadcast();

  final List<DlnaDevice> _knownDevices = <DlnaDevice>[];

  Stream<DlnaDevice> get onDeviceFound => _onDeviceFoundController.stream;
  Stream<DeviceUdn> get onDeviceLost => _onDeviceLostController.stream;
  Stream<DeviceUdn> get onRendererOffline =>
      _onRendererOfflineController.stream;

  List<DlnaDevice> get knownDevices =>
      List<DlnaDevice>.unmodifiable(_knownDevices);

  void _handleDeviceFound(DlnaDevice device) {
    final existingIndex = _knownDevices.indexWhere(
      (item) => item.udn.value == device.udn.value,
    );

    if (existingIndex >= 0) {
      _knownDevices[existingIndex] = device;
    } else {
      _knownDevices.add(device);
    }

    _onDeviceFoundController.add(device);
  }

  void _handleDeviceLost(DeviceUdn deviceUdn) {
    _knownDevices.removeWhere((item) => item.udn.value == deviceUdn.value);
    _onDeviceLostController.add(deviceUdn);
  }

  void _handleRendererOffline(DeviceUdn deviceUdn) {
    _onRendererOfflineController.add(deviceUdn);
  }

  Future<void> dispose() async {
    DiscoveryEventsFlutterApi.setUp(null);
    await Future.wait<void>([
      _onDeviceFoundController.close(),
      _onDeviceLostController.close(),
      _onRendererOfflineController.close(),
    ]);
  }
}

class _DiscoveryEventsHandler implements DiscoveryEventsFlutterApi {
  _DiscoveryEventsHandler({
    required void Function(DlnaDevice) onDeviceFound,
    required void Function(DeviceUdn) onDeviceLost,
    required void Function(DeviceUdn) onRendererOffline,
  }) : _onDeviceFound = onDeviceFound,
       _onDeviceLost = onDeviceLost,
       _onRendererOffline = onRendererOffline;

  final void Function(DlnaDevice) _onDeviceFound;
  final void Function(DeviceUdn) _onDeviceLost;
  final void Function(DeviceUdn) _onRendererOffline;

  @override
  void onDeviceFound(DlnaDevice device) {
    _onDeviceFound(device);
  }

  @override
  void onDeviceLost(DeviceUdn deviceUdn) {
    _onDeviceLost(deviceUdn);
  }

  @override
  void onRendererOffline(DeviceUdn deviceUdn) {
    _onRendererOffline(deviceUdn);
  }
}
