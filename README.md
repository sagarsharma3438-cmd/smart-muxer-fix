# Smart Muxer Fix

A Dart (Flutter) helper that lets a video player open videos downloaded with
VidMate's "Smart Muxer" option. Without this, other players only show a
10-second dummy clip saying "Player doesn't support this video format. Install PLAYit".

## What it does
Smart Muxer files contain a short dummy MP4 at the start, and the real video
and audio are stored inside the same file. This helper finds the real parts,
rebuilds a normal video file and a normal audio file in the app cache, and
gives you their paths so a player (such as media_kit) can play them.

- Detects the layout and the scrambling key automatically (nothing is hard-coded to one file).
- Copies in 4 MB chunks, so large files do not fill the phone's memory.
- Normal videos are not touched (`prepareSmartMuxer` returns `null`).

## Usage (media_kit)
```dart
final sm = await prepareSmartMuxer(path); // null = normal video
if (sm == null) {
  await player.open(Media(path));
} else {
  if (sm.audio != null) {
    await (player.platform as dynamic).setProperty('audio-files', sm.audio!);
  }
  await player.open(Media(sm.video));
}
// when the player closes:
if (sm != null) deleteSmartMuxerFiles(sm);
```
Needs the `path_provider` package.

## Limits
- Local files only (not streaming).
- Tested on Android with one sample file. Other VidMate versions may differ.
- Preparing a big file takes a few seconds and needs temporary storage space.

## License
Free for personal use. You may NOT include this code in any app or software
that is published or distributed to others (Google Play, other app stores,
APK sites, etc.) without my written permission. See the LICENSE.txt file.

For permission, contact: sagarsharma3438@gmail.com

## About
I could not find another public implementation of this, so I wrote one. This project is not affiliated with VidMate or
PLAYit. Use it only with videos you have the right to watch.
