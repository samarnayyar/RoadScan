import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Which map is drawn under the chrome.
enum MapMode {
  /// MapLibre: the corridor styling, the hazard markers, the road bands and
  /// the 3D craters. Everything RoadScan draws itself.
  roadscan,

  /// Google's map, at exactly the camera the other view was left at.
  google;

  bool get isGoogle => this == MapMode.google;

  /// What the button says: the mode it switches TO, not the one you are in.
  ///
  /// A toggle labelled with its current state is the classic ambiguity -- a
  /// button reading "3D model view" could equally mean "you are here" or
  /// "go here". Naming the destination leaves no room for that.
  String get switchLabel =>
      isGoogle ? 'Switch to 3D model view' : 'Switch to Google view';

  IconData get switchIcon =>
      isGoogle ? Icons.view_in_ar_outlined : Icons.public;

  MapMode get other => isGoogle ? MapMode.roadscan : MapMode.google;
}

/// The view toggle, directly under the area header.
///
/// Full width and in the reading path rather than tucked into the button rail
/// with the theme and compass controls: this changes what the whole screen
/// IS, which is a different class of action from nudging the tilt, and it
/// should not be something the user has to hunt for.
class MapModeSwitch extends StatelessWidget {
  const MapModeSwitch({
    super.key,
    required this.mode,
    required this.onToggle,
    this.enabled = true,
  });

  final MapMode mode;
  final VoidCallback onToggle;

  /// False while the map is still setting itself up, so a tap cannot swap the
  /// view out from under a style load that is halfway through.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;

    return Material(
      color: c.surface.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: enabled ? onToggle : null,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: c.chromeBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                mode.switchIcon,
                size: 17,
                color: enabled ? c.accent : c.textMuted,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  mode.switchLabel,
                  style: TextStyle(
                    color: enabled ? c.textPrimary : c.textMuted,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.swap_horiz, size: 16, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
