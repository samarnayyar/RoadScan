import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../services/theme_controller.dart';
import 'map_home_screen.dart';

/// Animated launch screen: brand reveal, then "Select your area".
///
/// This doubles as cover for real startup cost. Supabase init, the first pin
/// fetch and the YOLO interpreter warm-up all happen while the animation plays,
/// so the work is hidden behind motion instead of behind a frozen splash.
class AreaSelectScreen extends StatefulWidget {
  const AreaSelectScreen({super.key});

  @override
  State<AreaSelectScreen> createState() => _AreaSelectScreenState();
}

class _AreaSelectScreenState extends State<AreaSelectScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _pulse;

  /// Drives the staggered entrance of the area cards.
  late final Animation<double> _logoFade;
  late final Animation<double> _logoScale;
  late final Animation<double> _titleFade;
  late final Animation<double> _listFade;

  String? _selecting;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    // The scan sweep runs forever, independent of the intro, so the screen
    // never looks frozen while the user decides.
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    // Intervals rather than chained controllers: one timeline is far easier to
    // retime than four controllers waiting on each other's completion.
    _logoScale = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOutBack),
    );
    _logoFade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.0, 0.30, curve: Curves.easeOut),
    );
    _titleFade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.35, 0.60, curve: Curves.easeOut),
    );
    _listFade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.50, 1.0, curve: Curves.easeOut),
    );

    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _open(CampusArea area) async {
    if (_selecting != null) return;
    setState(() => _selecting = area.id);

    // Brief beat so the tap feedback is visible before the route pushes;
    // without it the transition reads as an unexplained jump.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;

    await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        reverseTransitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => MapHomeScreen(area: area),
        transitionsBuilder: (_, animation, __, child) {
          // Zoom-and-fade reads as "diving into" the area, which matches what
          // the camera does on the other side.
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 1.18, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );

    if (mounted) setState(() => _selecting = null);
  }

  /// One grid cell, with its own entrance delay so the four cards fill in
  /// left-to-right, top-to-bottom rather than all popping in at once.
  Widget _buildCard(int i, bool dark) {
    final area = AppConfig.areas[i];
    final start = (0.5 + i * 0.08).clamp(0.0, 0.9).toDouble();
    final anim = CurvedAnimation(
      parent: _intro,
      curve: Interval(start, 1.0, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, 22 * (1 - anim.value)),
        child: Opacity(opacity: anim.value.clamp(0.0, 1.0), child: child),
      ),
      child: _AreaCard(
        area: area,
        index: i,
        dark: dark,
        busy: _selecting == area.id,
        onTap: () => _open(area),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final dark = c.isDark;

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          // Campus skyline + scanning motif behind everything.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => CustomPaint(
                painter: _CampusBackdrop(progress: _pulse.value, colors: c),
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FadeTransition(
                          opacity: _logoFade,
                          child: ScaleTransition(
                            scale: _logoScale,
                            alignment: Alignment.centerLeft,
                            child: const _Wordmark(),
                          ),
                        ),
                      ),
                      FadeTransition(
                        opacity: _logoFade,
                        child: const _ThemeToggle(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FadeTransition(
                    opacity: _titleFade,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select your area',
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Road hazards are mapped per stretch. Pick where you '
                          'are riding.',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Fixed 2x2 grid, not a ListView -- every area is on screen
                  // at once by construction, not by hoping the content is short
                  // enough. Sized by LayoutBuilder rather than Expanded so the
                  // cards keep a sane proportion instead of stretching into
                  // tall slabs on a 20:9 phone.
                  //
                  // This assumes exactly four areas (matching the corridor's
                  // four named places); a fifth would need this revisited.
                  Expanded(
                    child: FadeTransition(
                      opacity: _listFade,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          const gap = 14.0;
                          final cardW = (constraints.maxWidth - gap) / 2;
                          final rowH = (constraints.maxHeight - gap) / 2;
                          final cardH = math.min(cardW * 1.18, rowH);
                          return Align(
                            // Top, not centre: centring split the leftover
                            // space above and below, opening a dead gap
                            // between the subtitle and the first row.
                            alignment: Alignment.topCenter,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                        width: cardW,
                                        height: cardH,
                                        child: _buildCard(0, dark)),
                                    const SizedBox(width: gap),
                                    SizedBox(
                                        width: cardW,
                                        height: cardH,
                                        child: _buildCard(1, dark)),
                                  ],
                                ),
                                const SizedBox(height: gap),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                        width: cardW,
                                        height: cardH,
                                        child: _buildCard(2, dark)),
                                    const SizedBox(width: gap),
                                    SizedBox(
                                        width: cardW,
                                        height: cardH,
                                        child: _buildCard(3, dark)),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FadeTransition(
                    opacity: _listFade,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'You can switch areas at any time from the map.',
                          style:
                              TextStyle(color: c.textMuted, fontSize: 11.5),
                        ),
                        const SizedBox(height: 3),
                        // Licence obligation for the bundled card thumbnails:
                        // they are OSM-derived raster tiles baked by
                        // tool/fetch_area_maps.py. ODbL requires the credit.
                        Text(
                          'Area maps (c) OpenStreetMap contributors',
                          style: TextStyle(
                            color: c.textMuted.withValues(alpha: 0.7),
                            fontSize: 9.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cycles system -> light -> dark. One control rather than a settings screen:
/// there is exactly one preference, and burying it would be worse than the
/// small ambiguity of a three-state button (which the tooltip and the icon
/// both disambiguate).
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) {
        return Tooltip(
          message: 'Theme: ${ThemeController.label(mode)}',
          child: Material(
            color: c.surface.withValues(alpha: c.isDark ? 0.55 : 0.85),
            shape: CircleBorder(
              side: BorderSide(color: c.border, width: 1),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => ThemeController.instance.cycle(),
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Icon(
                    ThemeController.icon(mode),
                    key: ValueKey(mode),
                    size: 19,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF2E9CD6), Color(0xFF1B6CA8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2E9CD6).withValues(alpha: 0.35),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: const Icon(Icons.radar, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 12),
        Text(
          'RoadScan',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

/// Accent per area tile.
///
/// Strictly COOL hues. The map's severity palette owns green/amber/orange/red
/// (hazard_report.dart's `color` getter), so an area tile tinted amber would
/// be teaching a colour vocabulary that means something entirely different one
/// screen later. Blues and violets are unambiguous here.
const List<Color> _areaAccents = [
  Color(0xFF3FA9F5), // azure
  Color(0xFF21C5D6), // cyan
  Color(0xFF7C7CF0), // indigo
  Color(0xFFA96FE0), // violet
];

/// One tile in the 2x2 area grid.
///
/// The background is the REAL map at that area's coordinates -- a raster
/// thumbnail baked from OpenStreetMap by tool/fetch_area_maps.py and shipped
/// as an asset. An earlier version drew a procedural fake road sketch, which
/// looked fine but told the user nothing; this previews the actual place they
/// are about to open. Bundled rather than fetched so there is no tile-server
/// traffic, no API key, and no loading state.
class _AreaCard extends StatelessWidget {
  const _AreaCard({
    required this.area,
    required this.busy,
    required this.onTap,
    required this.index,
    required this.dark,
  });

  final CampusArea area;
  final bool busy;
  final VoidCallback onTap;
  final int index;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final accent = _areaAccents[index % _areaAccents.length];
    final asset =
        'assets/area_maps/${area.id}_${dark ? 'dark' : 'light'}.jpg';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: busy ? accent : accent.withValues(alpha: 0.34),
              width: busy ? 1.8 : 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.38 : 0.12),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
              // A faint colour bloom under the card, so the tile feels lit
              // rather than pasted onto the background.
              BoxShadow(
                color: accent.withValues(alpha: busy ? 0.26 : 0.10),
                blurRadius: 22,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  asset,
                  fit: BoxFit.cover,
                  // If the bake was never run, fall back to a plain tinted
                  // panel rather than Flutter's grey broken-image box.
                  errorBuilder: (_, __, ___) => ColoredBox(
                    color: Color.lerp(c.surfaceAlt, accent, 0.18)!,
                  ),
                ),

                // Accent wash, so each tile is identifiable at a glance and
                // the raster map reads as part of the app rather than a
                // screenshot pasted in.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent.withValues(alpha: dark ? 0.26 : 0.20),
                        accent.withValues(alpha: 0.04),
                      ],
                    ),
                  ),
                ),

                // Scrim so the label stays readable over whatever the map
                // happens to show underneath it.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        (dark ? const Color(0xFF091521) : Colors.white)
                            .withValues(alpha: 0.35),
                        (dark ? const Color(0xFF091521) : Colors.white)
                            .withValues(alpha: dark ? 0.92 : 0.95),
                      ],
                      stops: const [0.32, 0.56, 1.0],
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Spacer(),
                      Text(
                        area.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        area.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 11,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            busy ? 'Opening' : 'Open map',
                            style: TextStyle(
                              color: dark ? accent : c.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const Spacer(),
                          if (busy)
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: dark ? accent : c.accent),
                            )
                          else
                            Icon(Icons.arrow_outward_rounded,
                                color: (dark ? accent : c.accent)
                                    .withValues(alpha: 0.75),
                                size: 15),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The launch screen's backdrop: a campus skyline under a scanning sweep.
///
/// Two ideas, deliberately kept abstract:
///
///   * The campus. Blocks of varying height with lit windows, a domed hall and
///     a flagged tower -- the silhouette of a university at night, without
///     copying any real building or using any UPES mark. Drawing it avoids
///     shipping (and licensing) a campus photograph.
///   * The scan. Concentric arcs sweeping out from a point on the skyline,
///     plus a horizon sweep line. That is the app's actual job -- watching the
///     road ahead and warning early -- rendered as a motif rather than a
///     stock shield icon.
///
/// The previous version drew rings at 0.75x the screen height, which put their
/// arcs diagonally across the middle of the content where they read as stray
/// strokes rather than a radar. These are anchored low and kept small enough
/// to stay a background.
class _CampusBackdrop extends CustomPainter {
  _CampusBackdrop({required this.progress, required this.colors});

  final double progress;
  final RoadScanColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final dark = colors.isDark;

    // Vertical wash: lighter toward the horizon, so the skyline has something
    // to sit against.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colors.backgroundDeep,
            colors.background,
            Color.lerp(colors.background, colors.accent,
                dark ? 0.10 : 0.07)!,
          ],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(Offset.zero & size),
    );

    final horizon = h * 0.845;
    final origin = Offset(w * 0.5, horizon);

    // --- the scan -------------------------------------------------------
    // Arcs rise from the middle of the skyline and fade as they expand.
    final maxR = h * 0.34;
    for (var i = 0; i < 4; i++) {
      final t = (progress + i / 4.0) % 1.0;
      final r = maxR * t;
      if (r <= 1) continue;
      final a = (1.0 - t) * (dark ? 0.30 : 0.22);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: r),
        math.pi,            // upper half only -- below the horizon is ground
        math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = colors.accent.withValues(alpha: a),
      );
    }

    // A slow sweep line, the "currently scanning" cue.
    final sweep = math.pi + (progress * math.pi);
    final sweepEnd = Offset(
      origin.dx + math.cos(sweep) * maxR,
      origin.dy + math.sin(sweep) * maxR,
    );
    canvas.drawLine(
      origin,
      sweepEnd,
      Paint()
        ..shader = LinearGradient(
          colors: [
            colors.accent.withValues(alpha: dark ? 0.26 : 0.18),
            colors.accent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromPoints(origin, sweepEnd))
        ..strokeWidth = 2.0,
    );

    // --- the campus -----------------------------------------------------
    _paintSkyline(canvas, size, horizon);

    // Ground below the skyline, so the buildings sit on something.
    canvas.drawRect(
      Rect.fromLTRB(0, horizon, w, h),
      Paint()
        ..color = (dark ? colors.backgroundDeep : colors.backgroundDeep)
            .withValues(alpha: dark ? 0.85 : 0.5),
    );
  }

  void _paintSkyline(Canvas canvas, Size size, double horizon) {
    final w = size.width;
    final dark = colors.isDark;
    final rnd = math.Random(20260921); // fixed: the skyline must not reshuffle

    final body = Paint()
      ..color = dark
          ? colors.backgroundDeep.withValues(alpha: 0.92)
          : colors.textPrimary.withValues(alpha: 0.10);
    final windowPaint = Paint()
      ..color = colors.accent.withValues(alpha: dark ? 0.50 : 0.28);

    var x = -w * 0.05;
    var i = 0;
    while (x < w * 1.05) {
      final bw = w * (0.10 + rnd.nextDouble() * 0.09);
      final bh = size.height * (0.035 + rnd.nextDouble() * 0.075);
      final top = horizon - bh;
      final rect = Rect.fromLTWH(x, top, bw * 0.92, bh);

      // Every third block gets a domed roof; one gets a tower and flag. Gives
      // the skyline a campus profile rather than a generic city one.
      final domed = i % 3 == 1;
      final towered = i == 3;

      canvas.drawRect(rect, body);
      if (domed) {
        canvas.drawArc(
          Rect.fromLTWH(rect.left, top - bw * 0.30, rect.width, bw * 0.60),
          math.pi,
          math.pi,
          false,
          body..style = PaintingStyle.fill,
        );
      }
      if (towered) {
        final tw = rect.width * 0.20;
        final tx = rect.center.dx - tw / 2;
        final th = bh * 0.55;
        canvas.drawRect(Rect.fromLTWH(tx, top - th, tw, th), body);
        // Flagpole.
        canvas.drawLine(
          Offset(tx + tw / 2, top - th),
          Offset(tx + tw / 2, top - th - size.height * 0.022),
          Paint()
            ..strokeWidth = 1.4
            ..color = colors.accent.withValues(alpha: dark ? 0.5 : 0.35),
        );
      }

      // Lit windows. Sparse and irregular -- a full grid reads as a
      // spreadsheet, not a building.
      final cols = (rect.width / (w * 0.028)).floor();
      final rows = (bh / (size.height * 0.018)).floor();
      for (var cx = 0; cx < cols; cx++) {
        for (var cy = 0; cy < rows; cy++) {
          if (rnd.nextDouble() > 0.34) continue;
          canvas.drawRect(
            Rect.fromLTWH(
              rect.left + 6 + cx * (w * 0.028),
              top + 7 + cy * (size.height * 0.018),
              w * 0.010,
              size.height * 0.006,
            ),
            windowPaint,
          );
        }
      }

      x += bw;
      i++;
    }
  }

  @override
  bool shouldRepaint(_CampusBackdrop old) =>
      old.progress != progress || old.colors != colors;
}
