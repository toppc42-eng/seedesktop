import 'package:flutter_custom_cursor/cursor_manager.dart'
    as custom_cursor_manager;
import 'package:flutter_custom_cursor/flutter_custom_cursor.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';

Future<void> deleteCustomCursor(String key) async {
  if (isLinux) return;
  try {
    await custom_cursor_manager.CursorManager.instance.deleteCursor(key);
  } on MissingPluginException {
    // Sub-window or headless engine without native plugin.
  }
}

void resetSystemCursor() {}

bool get _customCursorAvailable {
  if (isLinux) return false;
  return true;
}

MouseCursor buildCursorOfCache(
    CursorModel cursor, double scale, CursorData? cache) {
  if (cache == null) {
    return MouseCursor.defer;
  } else {
    final key = cache.updateGetKey(scale);
    if (!cursor.cachedKeys.contains(key)) {
      // data should be checked here, because it may be changed after `updateGetKey()`
      final data = cache.data;
      if (data == null) {
        return MouseCursor.defer;
      }
      debugPrint(
          "Register custom cursor with key $key (${cache.hotx},${cache.hoty})");
      // [Safety]
      // It's ok to call async registerCursor in current synchronous context,
      // because activating the cursor is also an async call and will always
      // be executed after this.
      if (_customCursorAvailable) {
        custom_cursor_manager.CursorManager.instance
            .registerCursor(custom_cursor_manager.CursorData()
              ..name = key
              ..buffer = data
              ..width = (cache.width * cache.scale).toInt()
              ..height = (cache.height * cache.scale).toInt()
              ..hotX = cache.hotx
              ..hotY = cache.hoty);
        cursor.addKey(key);
      }
    }
    if (!_customCursorAvailable) {
      return MouseCursor.defer;
    }
    return FlutterCustomMemoryImageCursor(key: key);
  }
}
