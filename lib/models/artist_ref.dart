// ============================================================
// models/artist_ref.dart
//
// A single credited artist on a song: the display name plus, when YouTube
// Music gave us one, the artist's browse id.
//
// Collaborations ("Drake, Future") arrive from the source as one run per
// artist, each carrying its own browse id — so we keep them as a list and
// never have to guess where the name boundaries are by parsing the string.
// ============================================================

class ArtistRef {
  /// Display name, e.g. "Drake" or "Simon & Garfunkel".
  final String name;

  /// YouTube Music artist browse id ("UC…") when known; null when the source
  /// only gave us a name and it has to be resolved on tap.
  final String? browseId;

  const ArtistRef({required this.name, this.browseId});

  bool get hasBrowseId => browseId != null && browseId!.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ArtistRef && other.name == name && other.browseId == browseId;

  @override
  int get hashCode => Object.hash(name, browseId);

  @override
  String toString() => 'ArtistRef(name: $name, browseId: $browseId)';
}
