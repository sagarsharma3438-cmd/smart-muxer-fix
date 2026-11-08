// Smart Muxer Fix
// Copyright (c) 2026 Sagar. All rights reserved.
// Developed with AI assistance.
// Licensed under the Smart Muxer Fix Personal-Use License. See the LICENSE file.
// Personal use is free. Including this code (or any part of it) in an app or software
// that is published or distributed to others (Google Play, any app store, APK sites,
// websites, etc.) requires prior written permission: sagarsharma3438@gmail.com
//
// VidMate "Smart Muxer" fix.
// Smart Muxer videos are a 10-second dummy MP4 with the real video + audio hidden
// inside the same file. This file rebuilds the real video (and audio) into the
// app cache so media_kit can play them. Normal videos are NOT touched
// (prepareSmartMuxer returns null for them).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

typedef SmartMuxerResult = ({String video, String? audio});

// SWITCH: true = also attach the audio track (sound), false = video only (no sound).
const bool kSmartMuxerAttachAudio = true;

const int _kChunk = 4 * 1024 * 1024; // copy in 4 MB pieces, never the whole file
const int _kMaxHead = 16 * 1024 * 1024; // safety limit for the scrambled head block
// Smart Muxer signatures seen in the ftyp brands (any one of them = Smart Muxer). Add new ones here.
const List<String> _kSigs = ['56d3', 'fbd2', 'a209'];

class _Box {
  final int size;
  final String type;
  const _Box(this.size, this.type);
}

/// Reads one MP4 box header at [p]. Returns null if it is not a valid box.
Future<_Box?> _box(RandomAccessFile f, int p, int len) async {
  if (p < 0 || p + 8 > len) return null;
  await f.setPosition(p);
  final h = await f.read(8);
  if (h.length < 8) return null;
  final size = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
  for (var i = 4; i < 8; i++) {
    if (h[i] < 32 || h[i] >= 127) return null;
  }
  if (size < 8 || p + size > len) return null;
  return _Box(size, String.fromCharCodes(h.sublist(4, 8)));
}

/// Generic box walk: returns the offset where valid boxes stop.
Future<int> _walk(RandomAccessFile f, int p, int len) async {
  while (true) {
    final b = await _box(f, p, len);
    if (b == null) return p;
    p += b.size;
  }
}

/// Walks moof + mdat pairs: returns the offset where they stop.
Future<int> _walkFrags(RandomAccessFile f, int p, int len) async {
  while (true) {
    final b = await _box(f, p, len);
    if (b == null || b.type != 'moof') return p;
    final m = await _box(f, p + b.size, len);
    if (m == null || m.type != 'mdat') return p;
    p += b.size + m.size;
  }
}

/// Finds the first real "moof" box (followed by a valid "mdat") at or after [from].
Future<int> _findFirstFrag(RandomAccessFile f, int from, int len) async {
  final limit = math.min(len, from + 64 * 1024 * 1024);
  var pos = from;
  while (pos < limit) {
    await f.setPosition(pos);
    final buf = await f.read(math.min(_kChunk, limit - pos));
    if (buf.length < 4) break;
    for (var i = 0; i + 4 <= buf.length; i++) {
      if (buf[i] == 0x6d && buf[i + 1] == 0x6f && buf[i + 2] == 0x6f && buf[i + 3] == 0x66) {
        final s = pos + i - 4;
        if (s < from) continue;
        final b = await _box(f, s, len);
        if (b != null && b.type == 'moof') {
          final m = await _box(f, s + b.size, len);
          if (m != null && m.type == 'mdat') return s;
        }
      }
    }
    pos += buf.length - 3; // small overlap so a "moof" on a chunk edge is not missed
  }
  return -1;
}

bool _containsAscii(Uint8List d, String s) {
  final n = s.length;
  for (var i = 0; i + n <= d.length; i++) {
    var ok = true;
    for (var j = 0; j < n; j++) {
      if (d[i + j] != s.codeUnitAt(j)) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

Future<void> _copy(RandomAccessFile src, int start, int count, RandomAccessFile out) async {
  await src.setPosition(start);
  var left = count;
  while (left > 0) {
    final b = await src.read(left < _kChunk ? left : _kChunk);
    if (b.isEmpty) throw 'Unexpected end of file';
    await out.writeFrom(b);
    left -= b.length;
  }
}

String _fnv(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return h.toRadixString(16);
}

Future<Directory> _cacheDir() async {
  final t = await getTemporaryDirectory();
  final d = Directory('${t.path}/smart_muxer');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

/// Returns null if [path] is NOT a Smart Muxer file (play it normally).
/// Returns the rebuilt video (+ optional audio) paths if it is.
/// THROWS a String message if it IS a Smart Muxer file but recovery failed.
Future<SmartMuxerResult?> prepareSmartMuxer(String path) async {
  final src = File(path);
  RandomAccessFile? f;
  var detected = false;
  try {
    if (!await src.exists()) return null;
    final st = await src.stat();
    final len = st.size;
    if (len < 4096) return null;
    f = await src.open();

    // 1) Is it Smart Muxer? ftyp must contain the brand "56d3".
    final first = await _box(f, 0, len);
    if (first == null || first.type != 'ftyp' || first.size > 4096) return null;
    await f.setPosition(0);
    final ftyp = await f.read(first.size);
    if (!_kSigs.any((x) => _containsAscii(ftyp, x))) return null;
    detected = true;

    // 2) Already prepared before? Reuse it.
    final dir = await _cacheDir();
    final name = 'sm2_${_fnv(path)}_${len}_${st.modified.millisecondsSinceEpoch}';
    final vFinal = '${dir.path}/${name}_v.mp4';
    final aFinal = '${dir.path}/${name}_a.m4a';
    if (await File(vFinal).exists()) {
      return (video: vFinal, audio: await File(aFinal).exists() ? aFinal : null);
    }

    // 3) Find D (end of dummy), then the video fragments, then A (end of video part).
    final d = await _walk(f, 0, len);
    if (d < 8 || d > _kMaxHead) throw 'Smart Muxer: dummy part not understood (D=$d)';
    final s = await _findFirstFrag(f, d, len);
    if (s < 0) throw 'Smart Muxer: video data not found (D=$d)';
    final a = await _walkFrags(f, s, len);
    if (a + d > len || a + 8 > len) throw 'Smart Muxer: saved head block missing (D=$d A=$a)';

    // 4) Detect the XOR key (do not hardcode).
    await f.setPosition(a);
    final k = await f.read(8);
    final key = k[4] ^ 0x66; // 'f' of "ftyp"
    if ((k[5] ^ key) != 0x74 || (k[6] ^ key) != 0x79 || (k[7] ^ key) != 0x70) {
      throw 'Smart Muxer: unknown scrambling (D=$d A=$a bytes=${k.map((e) => e.toRadixString(16)).join(" ")})';
    }

    // 5) Audio: normally a plain mp4 right after the saved head block.
    //    If it looks scrambled with the same key, try to unscramble its first D bytes (best effort).
    final aStart = a + d;
    var aEnd = aStart;
    var audioScrambled = false;
    if (aStart + 8 <= len) {
      final ab = await _box(f, aStart, len);
      if (ab != null && ab.type == 'ftyp') {
        aEnd = await _walk(f, aStart, len);
      } else {
        await f.setPosition(aStart);
        final q = await f.read(8);
        if (q.length == 8 &&
            (q[4] ^ key) == 0x66 &&
            (q[5] ^ key) == 0x74 &&
            (q[6] ^ key) == 0x79 &&
            (q[7] ^ key) == 0x70) {
          audioScrambled = true;
          aEnd = len;
        }
      }
    }

    // 6) Write files (temp name first, rename when complete).
    String? audioOut;
    if (aEnd - aStart > 16) {
      final tmp = '$aFinal.part';
      final o = await File(tmp).open(mode: FileMode.write);
      try {
        final total = aEnd - aStart;
        var copied = 0;
        if (audioScrambled) {
          final hl = total < d ? total : d;
          await f.setPosition(aStart);
          final hb = await f.read(hl);
          for (var i = 0; i < hb.length; i++) {
            hb[i] = hb[i] ^ key;
          }
          await o.writeFrom(hb);
          copied = hb.length;
        }
        await _copy(f, aStart + copied, total - copied, o);
      } finally {
        await o.close();
      }
      // Check the written audio really is a valid mp4 and cut any junk (footer) at the end.
      var ok = true;
      final g = await File(tmp).open(mode: FileMode.append);
      try {
        final n = await g.length();
        final e2 = await _walk(g, 0, n);
        if (e2 < 16) {
          ok = false;
        } else if (e2 < n) {
          await g.truncate(e2);
        }
      } finally {
        await g.close();
      }
      if (ok) {
        await File(tmp).rename(aFinal);
        audioOut = aFinal;
      } else {
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    }

    final vTmp = '$vFinal.part';
    final vo = await File(vTmp).open(mode: FileMode.write);
    try {
      await f.setPosition(a);
      final head = await f.read(d);
      if (head.length != d) throw 'Unexpected end of file';
      for (var i = 0; i < head.length; i++) {
        head[i] = head[i] ^ key;
      }
      await vo.writeFrom(head);
      await _copy(f, d, a - d, vo);
    } finally {
      await vo.close();
    }
    await File(vTmp).rename(vFinal); // video renamed LAST = marks "ready"

    return (video: vFinal, audio: audioOut);
  } catch (e) {
    if (!detected) return null; // could not even check -> just play normally
    throw e is String ? e : 'Smart Muxer: $e';
  } finally {
    try {
      await f?.close();
    } catch (_) {}
  }
}

/// Deletes the temp files of one prepared video (call when the player screen closes).
Future<void> deleteSmartMuxerFiles(SmartMuxerResult r) async {
  for (final p in [r.video, r.audio]) {
    if (p == null) continue;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Deletes ALL leftover temp files (call once at app start).
Future<void> cleanupSmartMuxerCache() async {
  try {
    final t = await getTemporaryDirectory();
    final d = Directory('${t.path}/smart_muxer');
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}
