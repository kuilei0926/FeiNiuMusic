# Local DLNA compatibility fixes

Based on the MIT-licensed `media_cast_dlna` 0.3.1 package from
https://github.com/felnanuke2/media_cast_dlna. The original license is retained.
The Dart/Pigeon API and iOS implementation are unchanged.

Android changes:

- Infer MIME types from the URI path, excluding query parameters and fragments.
  HLS playlists use `application/vnd.apple.mpegurl`; unknown audio is not labelled MP3.
- Preserve action, UPnP fault code, HTTP status, elapsed time and error category
  in Flutter platform exception details, without including media URLs or credentials.
- Ignore callbacks after cancellation and retain structured errors in polling.

Application changes and regression tests live in `lib/app/services/cast/` and
`test/dlna_cast_*`. Native regression tests live under `android/src/test/`.
Do not edit generated Pigeon files to change error handling.

Native verification without an Android SDK (requires Java 17+, Maven, and Flutter
Android engine artifacts):

```sh
mvn -f plugins/media_cast_dlna/native-tests/pom.xml -Dflutter.sdk=/opt/flutter test
```

This compiles the full Android plugin against Android API stubs and Flutter's
embedding, then runs JVM protocol tests. It does not replace an Android APK build
or testing on a real renderer.
