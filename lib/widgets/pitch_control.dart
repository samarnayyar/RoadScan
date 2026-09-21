import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';

/// Tilt slider plus a compass that doubles as "reset north".
///
/// Pitch is gesture-controllable on the map itself, but a two-finger drag is
/// not discoverable and is awkward to perform on camera during a demo. An
/// explicit slider makes the 3D nature of the map obvious and controllable.
class PitchControl extends StatelessWidget {
  const PitchControl({
    super.key,
    required this.pitch,
    required this.bearing,
    required this.onPitchChanged,
    required this.onResetBearing,
  });

  final double pitch;
  final double bearing;
  final ValueChanged<double> onPitchChanged;
  final VoidCallback onResetBearing;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.border.withValues(alpha: 0.6)),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${pitch.round()}°',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: c.textPrimary),
          ),
          SizedBox(
            height: 130,
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: pitch.clamp(0.0, AppConfig.maxPitch),
                  min: 0,
                  max: AppConfig.maxPitch,
                  onChanged: onPitchChanged,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Tooltip(
            message: 'Face north',
            child: InkWell(
              onTap: onResetBearing,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Transform.rotate(
                  // Counter-rotate so the needle keeps pointing at true north
                  // as the map turns underneath it.
                  angle: -bearing * math.pi / 180.0,
                  child: Icon(Icons.navigation, size: 20, color: c.textPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
