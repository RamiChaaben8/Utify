// ============================================================
// desktop/shell/desktop_navigation.dart
//
// Lets surfaces that are not the sidebar ask the shell to open
// something in the centre view.
//
// The sidebar gets playlists as a direct callback
// (onPlaylistSelected). Anything deeper in the tree — the friend
// activity panel's playlist grid, or its "Open profile" menu entry —
// has no such handle, and pushing a route would land it on the
// mobile PlaylistScreen / FriendProfileScreen. Writing the request
// here instead lets the shell run it through its normal
// _navigateTo, so the view history and the back/forward buttons keep
// working.
//
// Set a value to open it; set null (or leave it alone) for nothing.
// The shell clears each after consuming.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import '../../services/firestore_service.dart';

/// The playlist the shell should show in the centre view, or null.
final desktopPlaylistRequestProvider =
    StateProvider<Playlist?>((ref) => null);

/// The friend profile the shell should show in the centre view, or null.
final desktopFriendProfileRequestProvider =
    StateProvider<PublicProfile?>((ref) => null);

/// A YouTube Music browse ID (album / playlist) to open in the centre view.
/// Set a non-empty string to navigate; the shell clears it after consuming.
final desktopYtBrowseRequestProvider =
    StateProvider<String?>((ref) => null);

/// A YouTube Music artist browse ID to open in the centre view.
/// Set a non-empty string to navigate; the shell clears it after consuming.
final desktopYtArtistRequestProvider =
    StateProvider<String?>((ref) => null);