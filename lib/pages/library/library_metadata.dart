import '../../app/services/feiniu/api_models.dart';

class LibraryEntityMetadata {
  final String name;
  final String? coverId;

  const LibraryEntityMetadata({required this.name, this.coverId});
}

List<FeiNiuAlbum> replaceAlbumMetadata(
  List<FeiNiuAlbum> source,
  String guid,
  LibraryEntityMetadata metadata,
) {
  return source.map((album) {
    if (album.guid != guid) return album;
    return FeiNiuAlbum(
      guid: album.guid,
      name: metadata.name,
      coverId: metadata.coverId ?? album.coverId,
      releaseDate: album.releaseDate,
      trackCount: album.trackCount,
      createdAt: album.createdAt,
    );
  }).toList();
}

List<FeiNiuArtist> replaceArtistMetadata(
  List<FeiNiuArtist> source,
  String guid,
  LibraryEntityMetadata metadata,
) {
  return source.map((artist) {
    if (artist.guid != guid) return artist;
    return FeiNiuArtist(
      guid: artist.guid,
      name: metadata.name,
      coverId: metadata.coverId ?? artist.coverId,
      trackCount: artist.trackCount,
      albumCount: artist.albumCount,
    );
  }).toList();
}
