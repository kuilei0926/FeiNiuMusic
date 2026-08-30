import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/feiniu/api_models.dart';
import 'package:feiniu_music/pages/library/library_metadata.dart';

void main() {
  test('album metadata replacement preserves loaded pages and item order', () {
    final source = List.generate(
      205,
      (index) => FeiNiuAlbum(
        guid: 'album-$index',
        name: 'Album $index',
        coverId: 'cover-$index',
        trackCount: index,
      ),
    );

    final updated = replaceAlbumMetadata(
      source,
      'album-150',
      const LibraryEntityMetadata(name: 'Renamed album', coverId: 'new-cover'),
    );

    expect(updated, hasLength(205));
    expect(
      updated.map((album) => album.guid),
      source.map((album) => album.guid),
    );
    expect(updated[150].name, 'Renamed album');
    expect(updated[150].coverId, 'new-cover');
    expect(updated[150].trackCount, 150);
    expect(source[150].name, 'Album 150');
  });

  test('artist metadata replacement preserves loaded pages and item order', () {
    final source = List.generate(
      205,
      (index) => FeiNiuArtist(
        guid: 'artist-$index',
        name: 'Artist $index',
        coverId: 'cover-$index',
        trackCount: index,
        albumCount: index ~/ 2,
      ),
    );

    final updated = replaceArtistMetadata(
      source,
      'artist-150',
      const LibraryEntityMetadata(name: 'Renamed artist', coverId: 'new-cover'),
    );

    expect(updated, hasLength(205));
    expect(
      updated.map((artist) => artist.guid),
      source.map((artist) => artist.guid),
    );
    expect(updated[150].name, 'Renamed artist');
    expect(updated[150].coverId, 'new-cover');
    expect(updated[150].trackCount, 150);
    expect(updated[150].albumCount, 75);
    expect(source[150].name, 'Artist 150');
  });
}
