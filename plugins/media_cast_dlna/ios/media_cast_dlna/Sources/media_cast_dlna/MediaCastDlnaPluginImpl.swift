//
//  MediaCastDlnaPluginImpl.swift
//  media_cast_dlna
//
//  Created by LUIZ FELIPE ALVES LIMA on 17/07/25.
//

import Flutter
import Foundation
import Network

public class MediaCastDlnaPluginImpl: MediaCastDlnaApi {

    func initializeUpnpService(completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func isUpnpServiceInitialized(completion: @escaping (Result<Bool, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func shutdownUpnpService(completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func startDiscovery(
        options: DiscoveryOptions, completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func stopDiscovery(completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getDiscoveredDevices(completion: @escaping (Result<[DlnaDevice], any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func refreshDevice(
        deviceUdn: DeviceUdn, completion: @escaping (Result<DlnaDevice?, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getDeviceServices(
        deviceUdn: DeviceUdn, completion: @escaping (Result<[DlnaService], any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func hasService(
        deviceUdn: DeviceUdn, serviceType: String,
        completion: @escaping (Result<Bool, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func isDeviceOnline(
        deviceUdn: DeviceUdn, completion: @escaping (Result<Bool, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func setMediaUri(
        deviceUdn: DeviceUdn, uri: Url, metadata: any MediaMetadata,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func setMediaUriWithSubtitles(
        deviceUdn: DeviceUdn, uri: Url, metadata: any MediaMetadata,
        subtitleTracks: [SubtitleTrack], completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func supportsSubtitleControl(
        deviceUdn: DeviceUdn, completion: @escaping (Result<Bool, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func setSubtitleTrack(
        deviceUdn: DeviceUdn, subtitleTrackId: String?,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getAvailableSubtitleTracks(
        deviceUdn: DeviceUdn, completion: @escaping (Result<[SubtitleTrack], any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getCurrentSubtitleTrack(
        deviceUdn: DeviceUdn, completion: @escaping (Result<SubtitleTrack?, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func play(deviceUdn: DeviceUdn, completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func pause(deviceUdn: DeviceUdn, completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func stop(deviceUdn: DeviceUdn, completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func seek(
        deviceUdn: DeviceUdn, position: TimePosition,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func setVolume(
        deviceUdn: DeviceUdn, volumeLevel: VolumeLevel,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getVolumeInfo(
        deviceUdn: DeviceUdn, completion: @escaping (Result<VolumeInfo, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func setMute(
        deviceUdn: DeviceUdn, muteOperation: MuteOperation,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getPlaybackInfo(
        deviceUdn: DeviceUdn, completion: @escaping (Result<PlaybackInfo, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getCurrentPosition(
        deviceUdn: DeviceUdn, completion: @escaping (Result<TimePosition, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getTransportState(
        deviceUdn: DeviceUdn, completion: @escaping (Result<TransportState, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getSupportedPlaybackSpeeds(
        deviceUdn: DeviceUdn, completion: @escaping (Result<SupportedPlaybackSpeeds, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func setPlaybackSpeed(
        deviceUdn: DeviceUdn, speed: PlaybackSpeed,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

    func getDeviceManually(uri: Url, completion: @escaping (Result<DlnaDevice?, any Error>) -> Void)
    {
        completion(
            .failure(
                NSError(
                    domain: "MediaCastDlnaPluginImpl", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not implemented"])))
    }

}
