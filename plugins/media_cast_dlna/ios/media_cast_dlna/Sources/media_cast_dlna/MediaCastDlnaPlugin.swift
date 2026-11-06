import Flutter
import Foundation
import Network

public class MediaCastDlnaPlugin: NSObject, FlutterPlugin {
    private static let plugin = MediaCastDlnaPluginImpl()
    public static func register(with registrar: FlutterPluginRegistrar) {
        MediaCastDlnaApiSetup.setUp(binaryMessenger: registrar.messenger(), api: plugin)
    }
}


