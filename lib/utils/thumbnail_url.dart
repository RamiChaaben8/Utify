/// Normalize YouTube/Google CDN thumbnail URLs and fallback when missing.
class ThumbnailUrl {
  ThumbnailUrl._();

  /// Normalizes any raw thumbnail URL:
  /// - Empty or null check
  /// - Prepends 'https:' to protocol-relative URLs ('//...')
  /// - Upgrades 'http://' to 'https://'
  /// - Adjusts Google CDN (lh3.googleusercontent.com, yt3.ggpht.com, yt3.googleusercontent.com)
  ///   sizing parameters to a proper high-res square dimension (e.g. '=w544-h544-l90-rj')
  /// - If the URL is empty or invalid, falls back to videoId-based thumbnail if [videoId] is provided.
  static String normalize(String? rawUrl, {String? videoId, int targetSize = 544}) {
    var url = rawUrl?.trim() ?? '';

    if (url.startsWith('//')) {
      url = 'https:$url';
    } else if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }

    // Google CDN sizing rewrite
    if (url.isNotEmpty) {
      final isGoogleCdn = url.contains('googleusercontent.com') || url.contains('ggpht.com');
      if (isGoogleCdn) {
        // Rewrite existing size/crop suffix
        if (url.contains('=')) {
          final base = url.substring(0, url.indexOf('='));
          url = '$base=w$targetSize-h$targetSize-l90-rj';
        } else {
          url = '$url=w$targetSize-h$targetSize-l90-rj';
        }
      }
    }

    // If still empty or invalid and we have a videoId, fall back to hqdefault.jpg
    if ((url.isEmpty || !url.startsWith('https://')) && videoId != null && videoId.trim().isNotEmpty) {
      final vId = videoId.trim();
      return 'https://i.ytimg.com/vi/$vId/hqdefault.jpg';
    }

    return url;
  }

  /// Returns fallback candidate URLs for a YouTube video in order of preference.
  static List<String> videoFallbacks(String videoId) {
    final vId = videoId.trim();
    if (vId.isEmpty) return const [];
    return [
      'https://i.ytimg.com/vi/$vId/hqdefault.jpg',
      'https://i.ytimg.com/vi/$vId/mqdefault.jpg',
      'https://i.ytimg.com/vi/$vId/default.jpg',
    ];
  }
}
