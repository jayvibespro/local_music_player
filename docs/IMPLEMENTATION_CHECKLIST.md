# Implementation checklist

## 1. Delete audio files from the device
- [x] Native `deleteFile` method channel in `MainActivity.kt`
  - [x] Android 11+: `MediaStore.createDeleteRequest` (system confirmation dialog)
  - [x] Android 10: catch `RecoverableSecurityException`, ask the user, retry
  - [x] Android 9 and below: `contentResolver.delete` / `File.delete` (WRITE_EXTERNAL_STORAGE, maxSdk 28)
  - [x] Files missing from MediaStore: scan them first so they get a content URI
- [x] `MusicLibrary.deleteTrack`: remove from library, favourites, playlists, hidden list; save
- [x] `MusicHandler.removeTrack`: drop the song from the play queue (skip ahead if it is playing)
- [x] "Delete from device…" in the song menu and the Now Playing menu, with a confirmation dialog

## 2. Swipeable cover carousel on Now Playing
- [x] Expose the queue in play order (respects shuffle) from `MusicHandler`
- [x] Current cover centred at the top; previous/next covers tilted (3D `rotateY`), scaled down and tucked behind on the left and right
- [x] Centre cover painted on top (custom paint order), driven by a `PageController` for native fling physics
- [x] Swipe left → next song, swipe right → previous song (acts on scroll end, not mid-drag)
- [x] Track changes from buttons / auto-advance / notification animate the carousel
- [x] Smoothness: `RepaintBoundary` per cover, decoded at display size, only ±2 neighbours built, no rebuilds of the rest of the screen while scrolling
- [x] Tap a side cover to jump to it; keep the Hero animation from the mini player

## 3. Album art in Android Auto
- [x] `ArtworkProvider` (read-only `ContentProvider`) serving the app's cached artwork as `content://` URIs
- [x] `MediaItem.artUri` uses the `content://` URI on Android (Auto cannot read `file://`); the in-app UI keeps reading the file path from `extras`
- [x] Works for the now-playing screen and the browse lists in Auto

## 4. Phone calls & audio interruptions
- [x] Handle audio-session interruptions in `MusicHandler` (instead of just_audio's default)
- [x] Call starts → pause; call ends → resume, even with the app in the background
- [x] Keep the media service in the foreground while paused by a call so Android allows resuming (avoids `ForegroundServiceStartNotAllowedException` on Android 12+ and the process being killed)
- [x] Short interruptions (navigation prompts, notifications) → duck volume, then restore
- [x] Manual play/pause during the call cancels the auto-resume
- [x] Headphones unplugged / Bluetooth disconnected → pause

## 5. Extras
- [x] Sleep timer (15/30/45/60 min or end of current song), shown in the Now Playing app bar, with a fade-out
- [x] Double-tap the cover to favourite it, with a heart burst animation
- [x] Haptic tick when a swipe changes song

## 6. Verify
- [x] `flutter analyze` clean
- [x] `flutter build apk --debug` succeeds
- [ ] On-device check (no Android device was connected): swipe feel, delete prompt on Android 10/11+, art in Android Auto (Desktop Head Unit), call → resume in background

---

# Round 2: Android Auto, fades, equalizer

## 7. Android Auto
- [x] Four tabs: Home, Albums, Artists, Playlists (Auto shows at most four)
- [x] Albums and Artists as cover grids; playlists use the first song's cover
- [x] Home: "Start driving" (Driving mix, Shuffle all) and "Your music" (Recently played, Most played, Recently added, Favourites, All songs) groups
- [x] Play history (`PlayHistory`): a play counts after 30 s (or half of a short song); deleted songs are forgotten
- [x] Smarter voice: collections ("my favourites", "driving mix", "new music"), shuffle phrases, "the album/playlist …", Assistant focus/extras, fuzzy and mis-heard names; a song request plays on into more by that artist
- [x] Auto-play when Android Auto connects (setting, on by default); optional resume on Bluetooth connect (off by default); never overrides a pause from the last 10 min
- [x] Queue title "Playing from …"
- [x] Search results grouped: Artists, Albums, Playlists, Songs

## 8. Fade between songs
- [x] Setting with 1–12 s length; fades the end out and the next song in (fade through silence; just_audio can't overlap two songs)
- [x] Combines with ducking and the sleep-timer fade

## 9. Equalizer (Android)
- [x] `AndroidEqualizer` in the player's audio pipeline; on/off; gains saved per band
- [x] Equalizer screen: band sliders, animated response curve, 11 presets (incl. "Driving") mapped onto the device's bands
- [x] Reachable from Settings → Playback and the Now Playing ⋮ menu

## 10. Verify
- [x] Unit tests for voice parsing/matching, EQ presets and play history (32 tests pass)
- [x] `flutter analyze` clean, debug APK builds
- [ ] On-device: Auto tabs/grids/groups in the Desktop Head Unit, voice commands, auto-play on connect, fade sound, EQ effect

---

# Round 3: phone app features

## 11. For you tab (replaces the Favourites tab; Favourites is a shelf on it)
- [x] Greeting, quick starts (Your mix, Shuffle all, Your stats)
- [x] Shelves: Recently played, Your top artists, Most played, Recently added, Favourites, each with "See all"

## 12. Swipe actions
- [x] Song rows: swipe right = Play next, swipe left = Add to queue, with Undo
- [x] Mini player: swipe left/right to skip (card slides out/in), swipe up to open Now Playing

## 13. Multi-select
- [x] Long-press (or ⋮ → Select) any song; action bar: Play next, Add to playlist, Play these, Add to queue, Favourite, Hide, Delete, Select all
- [x] Batch delete: one confirmation, one Android 11+ system prompt
- [x] Works on Songs, album/artist/collection pages and playlists; Back clears the selection

## 14. Lyrics
- [x] `.lrc` file next to the song (same name), else lyrics embedded in the tags
- [x] Synced: current line highlighted, auto-scroll (pauses when you scroll), tap a line to seek
- [x] Lyrics button appears when a song has lyrics; swipe up on Now Playing; ⋮ → Lyrics

## 15. Listening stats
- [x] Play log with timestamps + listening time per day (recorded from now on)
- [x] Week / Month / Year / All: total time, plays, songs, peak hour, bar chart (tap a bar), top artists, songs, albums

## 16. Even out volume
- [x] ReplayGain tags read during scanning (MP3 TXXX, FLAC/OGG comments); one-time full rescan
- [x] Songs without tags: loudness estimated from the waveform, measured ahead for the next songs
- [x] Android 9+: applied in the native gain stage (can boost, with a limiter); older: volume can only turn loud songs down

## 17. Album & artist pages
- [x] Big cover that collapses into the app bar, blurred backdrop, colours from the cover
- [x] Album: track numbers, artist, length; Artist: songs grouped by album; artist photos in the Artists tab

## 18. Search
- [x] Typo-tolerant ranked results; Artists/Albums cards, Playlists, Songs
- [x] Recent searches; mic button

## 19. Home-screen widget (Android)
- [x] Cover, title, artist, previous / play-pause / next; tap opens the app
- [x] Buttons send media-button events, like headset buttons

## 20. Visualizer (Android)
- [x] Mirrored spectrum bars on Now Playing (⋮ → Visualizer or Settings); eased at display refresh rate
- [x] Microphone permission requested only when turned on (Android requirement; nothing recorded); captures only while playing

## 21. Voice
- [x] In-app voice sheet (mic on Home/Search): "play …", "shuffle …", "next", "pause", "like this song", "stop in 20 minutes", "what's playing"
- [x] "Hey Google, play … on Music Player" (play-from-search intent) uses the same matching
- [x] Long-press the app icon → "Voice command" shortcut

## 22. Equalizer: more bands
- [x] 10 bands (31 Hz–16 kHz) + preamp on Android 9+ via `DynamicsProcessing` (local `packages/audio_fx` plugin), with limiter
- [x] Older phones fall back to the built-in equalizer (usually 5 bands)
- [x] Presets re-mapped to the band layout

## 23. Verify
- [x] 49 unit tests pass; `flutter analyze` clean; debug APK builds
- [ ] On-device: everything above, especially the EQ/visualizer on a real phone, the widget, the Assistant intent, batch delete prompts
