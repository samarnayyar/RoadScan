import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// What the map is drawn on.
///
/// Both modes are the SAME MapLibre map -- only the basemap underneath
/// changes. That is the point: the hazard markers and the road bands stay on
/// screen either way, so the switch adds real photography to what the app
/// knows rather than replacing one with the other.
enum MapMode {
  /// The styled vector basemap with the 3D building extrusions.
  roadscan,

  /// Aerial imagery. The extruded buildings step aside, because the imagery
  /// already has the real ones in it and drawing grey blocks on top of
  /// photographed rooftops doubles them.
  satellite;

  bool get isSatellite => this == MapMode.satellite;

  /// What the button says: the mode it switches TO, not the one you are in.
  ///
  /// A toggle labelled with its current state is the classic ambiguity -- a
  /// button reading "3D model view" could equally mean "you are here" or
  /// "go here". Naming the destination leaves no room for that.
  String get switchLabel =>
      isSatellite ? 'Switch to 3D model view' : 'Switch to satellite view';

  IconData get switchIcon =>
      isSatellite ? Icons.map_outlined : Icons.satellite_alt;

  MapMode get other => isSatellite ? MapMode.roadscan : MapMode.satellite;
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
            // Fills the width it is given so its edges line up with the
            // header card above, rather than shrinking to its text.
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
