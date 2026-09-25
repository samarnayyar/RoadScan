import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// One transient message, themed and cheap to draw.
///
/// Replaces the bare `ScaffoldMessenger.showSnackBar(SnackBar(...))` calls,
/// which had three problems on this app specifically:
///
///   * they used Material's default dark-grey slab, which looks pasted on in
///     light mode and wrong in neon;
///   * they could only be flicked DOWN to dismiss, which is Flutter's default
///     for a floating snack bar and is not what anyone reaches for;
///   * the default elevation of 6 puts a blurred drop shadow under the bar,
///     and every frame of the entry animation composites that blur over the
///     MapLibre platform view underneath. That is the expensive part, and it
///     is why the bar stuttered on the map screen rather than on any ordinary
///     Flutter page.
///
/// Elevation 1 keeps the bar readable against the map without the blur pass.
/// This reduces the stutter; it does not abolish it. A Flutter overlay
/// animating over a native texture costs more to composite than the same
/// overlay on a pure-Flutter screen, and no amount of styling changes that.
void showAppSnack(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
  bool isError = false,
}) {
  final c = context.rs;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: c.textPrimary, fontSize: 13, height: 1.3),
        ),
        backgroundColor: c.surface,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        // Flick either way to get rid of it.
        dismissDirection: DismissDirection.horizontal,
        elevation: 1,
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            // Error keeps a fixed red: it has to read as "wrong" identically
            // in all three themes, and none of the palettes carries a red.
            color: isError
                ? const Color(0xFFD32F2F).withValues(alpha: 0.7)
                : c.border,
          ),
        ),
      ),
    );
}
