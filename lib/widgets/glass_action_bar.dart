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

    // Sized and styled after iOS's floating glass controls: a tight pill that
    // hugs its content, heavy blur, a very low-alpha fill, and a fine
    // light-catching hairline along the top edge. The previous bar stretched
    // nearly edge to edge at 46px with a flat 55% white fill, which read as a
    // solid toolbar bolted to the bottom rather than glass floating over the
    // map.
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 44, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 34, sigmaY: 34),
          child: Container(
            decoration: BoxDecoration(
              color: glass.withValues(alpha: c.isDark ? 0.42 : 0.50),
              borderRadius: BorderRadius.circular(21),
              border: Border.all(
                color: c.isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.white.withValues(alpha: 0.65),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: c.isDark ? 0.34 : 0.14),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                // 38px. The bar should sit under the map, not compete with it
                // -- the map is the product.
                height: 38,
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
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      color: c.isDark
                          ? Colors.white.withValues(alpha: 0.12)
                          : Colors.black.withValues(alpha: 0.08),
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
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: accent,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
