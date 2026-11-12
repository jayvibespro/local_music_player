import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Permanently deletes audio files from the device.
///
/// Android doesn't let apps delete other apps' media directly (Android 10+),
/// so `MainActivity` goes through MediaStore, which shows the system's own
/// "Allow Music Player to delete this audio file?" prompt where required.
abstract final class FileDeleter {
  static const _channel = MethodChannel(
    'com.jacksons.local_music_player/files',
  );

  /// Returns true if the file is gone, false if the user declined or the
  /// delete failed.
  static Future<bool> delete(String path) async =>
      (await deleteAll([path])).contains(path);

  /// Deletes [paths]; returns the ones that are gone afterwards. On Android
  /// 11+ this is a single system confirmation for all of them.
  static Future<List<String>> deleteAll(List<String> paths) async {
    if (paths.isEmpty) return const [];
    try {
      if (Platform.isAndroid) {
        final gone = await _channel.invokeListMethod<String>('deleteFiles', {
          'paths': paths,
        });
        return gone ?? const [];
      }
      final gone = <String>[];
      for (final path in paths) {
        final file = File(path);
        if (await file.exists()) await file.delete();
        gone.add(path);
      }
      return gone;
    } catch (e) {
      debugPrint('Delete failed: $e');
      return const [];
    }
  }
}
