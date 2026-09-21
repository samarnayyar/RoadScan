import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Frosted-glass capture bar pinned to the bottom of the map.
///
/// Two actions, split down the middle: camera on the left, gallery on the
/// right. Both run the same on-device detection; the only difference is where
/// the image came from, and therefore whether its time and place are read from
/// EXIF or from the live device.
///
/// The blur is a real BackdropFilter over the live map rather than a flat
/// translucent panel, so the map stays legible underneath while the buttons
/// keep enough contrast to read in sunlight.
class GlassActionBar extends StatelessWidget {
  const GlassActionBar({
    super.key,
    required this.onCamera,
    required this.onGallery,
    this.busy = false,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    // The glass tints toward the surface colour of whichever theme is active.
    // Frosting a dark map with a white panel (as this did unconditionally)
    // produced a bright slab that fought the map instead of sitting over it.
    final glass = c.isDark ? const Color(0xFF16293A) : Colors.white;

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: glass.withValues(alpha: c.isDark ? 0.62 : 0.55),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: c.isDark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.75),
                width: 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 20,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                // Half the previous height. The bar should sit under the map,
                // not compete with it -- the map is the product.
                height: 46,
                child: Row(
                  children: [
                    Expanded(
                      child: _GlassAction(
                        icon: Icons.camera_alt_rounded,
                        label: 'Camera',
                        onTap: busy ? null : onCamera,
                        primary: true,
                      ),
                    ),
                    Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 11),
                      color: c.isDark
                          ? Colors.white.withValues(alpha: 0.14)
                          : Colors.black.withValues(alpha: 0.10),
                    ),
                    Expanded(
                      child: _GlassAction(
                        icon: Icons.photo_library_rounded,
                        label: 'Upload',
                        onTap: busy ? null : onGallery,
                        primary: false,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassAction extends StatelessWidget {
  const _GlassAction({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primary,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    // Camera is the primary action and gets the accent; Upload is secondary
    // and sits back a step. In dark mode both need lifting off the frosted
    // panel, so the secondary tone comes from the theme rather than a fixed
    // slate that vanished against dark glass.
    final accent = primary
        ? (c.isDark ? const Color(0xFF4FB8ED) : const Color(0xFF1B6CA8))
        : c.textSecondary;
    final disabled = onTap == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: disabled ? 0.45 : 1.0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: accent),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: accent,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
