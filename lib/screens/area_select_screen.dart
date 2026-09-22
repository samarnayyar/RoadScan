import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

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

    // Loaded during the intro animation, which is exactly the startup cost
    // that animation exists to cover.
    AreaRoads.load().then((_) {
      if (mounted) setState(() {});
    });

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
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _NeonToggle(),
                            SizedBox(width: 8),
                            _ThemeToggle(),
                          ],
                        ),
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
                          // Scoped to UPES on purpose. The app only covers the
                          // corridor around campus, and saying so up front is
                          // better than letting someone open it in Dehradun
                          // city and find an empty, off-limits map.
                          'Covering the UPES Bidholi corridor. Pick the '
                          'stretch you are riding.',
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
                          // Near-square. 1.45 filled the screen but left the
                          // tiles noticeably elongated; dropping "Open map"
                          // freed the vertical space that made that necessary.
                          final cardH = math.min(cardW * 1.12, rowH);
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

/// Day/night. Deliberately only swings between dark and light -- neon has its
/// own control, so reaching for "make it lighter" never drops you into a
/// completely different look.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return ValueListenableBuilder<AppThemeKind>(
      valueListenable: ThemeController.instance.kind,
      builder: (context, kind, _) {
        // While neon is on, this button offers the way back to a plain theme.
        final target =
            kind == AppThemeKind.light ? AppThemeKind.dark : AppThemeKind.light;
        return Tooltip(
          message: 'Switch to ${target.label}',
          child: Material(
            color: c.surface.withValues(alpha: c.isDark ? 0.55 : 0.85),
            shape: CircleBorder(
              side: BorderSide(color: c.border, width: 1),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => ThemeController.instance.toggleBrightness(),
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Icon(
                    target.icon,
                    key: ValueKey(target),
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

/// Neon on/off.
///
/// Spelled out as a word rather than an icon: a sparkle is a generic
/// "something decorative happens" glyph and told the user nothing about what
/// the button does. The label also gives the control room to glow when it is
/// on, which is the most on-the-nose way to preview what it turns on.
class _NeonToggle extends StatelessWidget {
  const _NeonToggle();

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return ValueListenableBuilder<AppThemeKind>(
      valueListenable: ThemeController.instance.kind,
      builder: (context, kind, _) {
        final on = kind == AppThemeKind.neon;
        final tint = on ? c.accent : c.textSecondary;
        return Tooltip(
          message: on ? 'Neon theme on' : 'Switch to neon theme',
          child: Material(
            color: on
                ? c.accent.withValues(alpha: 0.16)
                : c.surface.withValues(alpha: c.isDark ? 0.55 : 0.85),
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => ThemeController.instance.toggleNeon(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: on ? c.accent : c.border,
                    width: on ? 1.4 : 1,
                  ),
                  boxShadow: on
                      ? [
                          BoxShadow(
                            color: c.accent.withValues(alpha: 0.45),
                            blurRadius: 14,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  'NEON',
                  style: TextStyle(
                    color: tint,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    // Wide tracking is what makes four letters read as a
                    // sign rather than as a cramped word.
                    letterSpacing: 2.4,
                    height: 1.0,
                    shadows: on
                        ? [
                            Shadow(
                                color: c.accent.withValues(alpha: 0.9),
                                blurRadius: 10),
                          ]
                        : null,
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

/// Road geometry for the area cards, loaded once from the bundle.
///
/// Held statically rather than fetched per card: all four cards build at once
/// on the launch screen, and re-reading a 127 KB asset four times on the frame
/// that screen appears is exactly the sort of startup cost the intro animation
/// is meant to be hiding, not adding to.
class AreaRoads {
  AreaRoads._();

  static Map<String, dynamic>? _data;
  static Future<void>? _loading;

  static Map<String, dynamic>? get data => _data;

  static Future<void> load() {
    if (_data != null) return Future.value();
    return _loading ??= rootBundle
        .loadString('assets/area_roads.json')
        .then((raw) => _data = json.decode(raw) as Map<String, dynamic>)
        .catchError((Object e) {
          // The cards fall back to a plain tinted panel; not worth failing the
          // launch screen over.
          debugPrint('RoadScan: area roads unavailable: $e');
          return <String, dynamic>{};
        })
        .whenComplete(() => _loading = null);
  }
}

/// Draws one area's road network as glowing lines. Neon theme only.
///
/// Colour control is the whole point of doing this as vector rather than a
/// baked image: the roads are a bright core over a wider blurred halo of the
/// same hue, which is unachievable from an OSM raster tile where carriageway
/// and background are both near-white and cannot be separated after the fact.
///
/// Dark and light themes deliberately do NOT use this -- they show the actual
/// map thumbnail, which reads as the real place rather than as an abstraction
/// of it.
class _AreaRoadPainter extends CustomPainter {
  _AreaRoadPainter({required this.roads, required this.accent});

  final List<dynamic> roads;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (roads.isEmpty) return;

    // Three tiers, drawn thin-to-thick so major roads sit on top of the lanes
    // they connect rather than being cut by them.
    for (final tier in const [0, 1, 2]) {
      final width = switch (tier) {
        2 => size.width * 0.026,
        1 => size.width * 0.017,
        _ => size.width * 0.010,
      };

      final path = Path();
      for (final road in roads) {
        if ((road['w'] as num).toInt() != tier) continue;
        final pts = road['p'] as List<dynamic>;
        if (pts.length < 2) continue;
        for (var i = 0; i < pts.length; i++) {
          final p = pts[i] as List<dynamic>;
          final o = Offset(
            (p[0] as num).toDouble() * size.width,
            (p[1] as num).toDouble() * size.height,
          );
          if (i == 0) {
            path.moveTo(o.dx, o.dy);
          } else {
            path.lineTo(o.dx, o.dy);
          }
        }
      }

      // Glow pass first, then the bright core on top.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 3.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = accent.withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 1.6),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          // Lifted toward white so the core reads as emitting light rather
          // than merely being coloured.
          ..color = Color.lerp(accent, Colors.white, 0.45)!
              .withValues(alpha: tier == 0 ? 0.80 : 1.0),
      );
    }
  }

  @override
  bool shouldRepaint(_AreaRoadPainter old) =>
      old.roads != roads || old.accent != accent;
}

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
              // Stronger in light mode: the cards are pale maps on a pale
              // background, so a faint edge left them floating without a
              // defined boundary.
              color: busy
                  ? accent
                  : accent.withValues(alpha: dark ? 0.34 : 0.62),
              width: busy ? 1.8 : (dark ? 1.1 : 1.4),
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
                // Neon draws the road network as glowing vector geometry;
                // dark and light show the real raster map thumbnail, which is
                // the more literal, recognisable view of the place.
                if (c.isNeon) ...[
                  ColoredBox(
                    color: Color.lerp(const Color(0xFF05070A), accent, 0.10)!,
                  ),
                  CustomPaint(
                    painter: _AreaRoadPainter(
                      roads: (AreaRoads.data?[area.id]
                              as Map<String, dynamic>?)?['r']
                              as List<dynamic>? ??
                          const [],
                      accent: accent,
                    ),
                  ),
                ] else
                  Image.asset(
                    'assets/area_maps/${area.id}_${dark ? 'dark' : 'light'}.jpg',
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
                //
                // Much lighter in light mode. At the dark-mode strength it
                // tinted a pale basemap outright -- the violet and indigo
                // tiles came out pink, which looked like a rendering fault
                // rather than a colour code.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent.withValues(alpha: dark ? 0.26 : 0.07),
                        accent.withValues(alpha: dark ? 0.04 : 0.01),
                      ],
                    ),
                  ),
                ),

                // Scrim so the label stays readable over whatever the map
                // happens to show underneath it.
                //
                // Confined to the lower part of the card: a scrim that starts
                // a third of the way down washes out the map itself, which is
                // the thing the card exists to show. It only needs to cover
                // the text.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        (dark ? const Color(0xFF091521) : Colors.white)
                            .withValues(alpha: dark ? 0.45 : 0.55),
                        (dark ? const Color(0xFF091521) : Colors.white)
                            .withValues(alpha: dark ? 0.94 : 0.97),
                      ],
                      stops: const [0.50, 0.70, 0.94],
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
                      // "Open map" removed -- on a tappable card the label was
                      // stating the obvious, and it crowded the tile. Only the
                      // busy spinner remains, because that does say something
                      // the card otherwise cannot.
                      if (busy) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: dark ? accent : c.accent),
                        ),
                      ],
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

/// The launch screen's backdrop: a working radar scope.
///
/// This replaces an earlier drawn skyline of blocks with lit windows. That
/// version had two problems: the buildings were invented, so they looked
/// generic rather than like anywhere in particular, and rendering them over a
/// saturated navy gradient made the whole screen read as decorative wallpaper.
///
/// A radar is the honest motif -- it is literally what the app does, watching
/// ahead and warning early -- and being an instrument rather than a landscape,
/// it does not have to resemble any real place to look right.
///
/// Drawn like an actual scope, not a suggestion of one:
///   * range rings at fixed radii, with bearing ticks
///   * a swept wedge with a trailing gradient, the way phosphor persistence
///     decays behind a real sweep
///   * contacts that light up as the beam crosses them and then fade, rather
///     than sitting there permanently
class _CampusBackdrop extends CustomPainter {
  _CampusBackdrop({required this.progress, required this.colors});

  final double progress;
  final RoadScanColors colors;

  /// Contacts, as (sweep position 0..1, radius fraction, severity tier).
  ///
  /// The first value is where in the sweep's travel the beam reaches them, so
  /// these are spread across the visible upper half rather than around a full
  /// circle -- contacts in the lower half would never be seen. Fixed rather
  /// than random so the scope does not reshuffle on every rebuild.
  ///
  /// Tier picks the colour from the app's REAL severity palette (see
  /// hazard_report.dart): 2 = critical red, 1 = high orange, 0 = medium
  /// amber. Three of each, so the scope previews the same vocabulary the map
  /// uses rather than inventing a decorative one -- and the mix conveys that
  /// severe damage is the rarer case.
  /// Radius fractions are capped at 0.58 on purpose. The scope's hub sits just
  /// below the screen, so a contact any further out rises above y = 0.75h --
  /// straight behind the Pondha and Nanda Ki Chowki cards, where it is
  /// invisible and the sweep appears to find nothing.
  ///
  /// Tiers are interleaved rather than run in order. Assigning them
  /// sequentially made the colours track position -- all the ambers on one
  /// side, the reds on the other -- which read as three separate groups
  /// instead of a mixed severity picture.
  /// Sweep positions are kept inside 0.18-0.82 as well.
  ///
  /// The hub sits just below the bottom edge, so a contact near sweep 0 or 1
  /// lies almost horizontally out from it -- which is off the bottom of the
  /// screen entirely. Only the middle of the sweep's travel is actually on
  /// screen, so that is where the contacts live.
  /// Two per severity, six in total. Nine was busy enough that the scope read
  /// as a field of dots rather than as occasional finds, which undercut the
  /// idea that severe damage is the rare case.
  ///
  /// Radii deliberately span 0.27 to 0.68 rather than sitting in a narrow
  /// band. Clustered at one distance they all landed on roughly the same
  /// range ring and read as a row rather than as contacts scattered through
  /// the scope's depth.
  ///
  /// 0.68 is the practical ceiling, not an arbitrary one: further out and a
  /// contact either rises behind the Pondha / Nanda Ki Chowki cards near the
  /// top of the sweep, or runs off the side edges at the shallow ends of it.
  static const List<List<double>> _contacts = [
    [0.20, 0.66, 2], // outer
    [0.31, 0.27, 0], // close in
    [0.42, 0.55, 1],
    [0.54, 0.35, 2],
    [0.66, 0.68, 0], // outer
    [0.78, 0.44, 1],
  ];

  /// Matches SeverityClass -> colour in hazard_report.dart.
  static const List<Color> _severityColors = [
    Color(0xFFE8B21A), // medium  amber
    Color(0xFFE2661C), // high    orange
    Color(0xFFD32F2F), // critical red
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final dark = colors.isDark;
    final accent = colors.accent;

    // Background. Neon gets a FLAT fill rather than a gradient: on an OLED
    // panel any lift off #000 turns pixels back on and loses the depth the
    // theme is built around. The other two keep a soft radial lift so the
    // screen is not a dead slab.
    if (colors.isNeon) {
      canvas.drawRect(Offset.zero & size, Paint()..color = colors.background);
    } else {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0.35, 0.34),
            radius: 1.1,
            colors: [
              Color.lerp(colors.background, accent, dark ? 0.05 : 0.06)!,
              colors.backgroundDeep,
            ],
          ).createShader(Offset.zero & size),
      );
    }

    // Per-theme intensity. One multiplier rather than branching every alpha:
    //   neon  brightest, the theme is meant to glow
    //   light was previously almost invisible against a pale ground, so it
    //         needs MORE than dark, not less
    //   dark  deliberately the most restrained of the three
    final k = switch (colors.kind) {
      AppThemeKind.neon => 1.9,
      AppThemeKind.light => 1.5,
      AppThemeKind.dark => 1.0,
    };

    // --- road + hazard motif, upper screen -------------------------------
    // Replaces a plain coordinate grid. This app is about road damage, so the
    // backdrop says "road" rather than "generic tech": a carriageway running
    // off toward a vanishing point, dashed lane line, and a few potholes on
    // it. Reads as the subject matter instead of as screen furniture.
    _paintRoad(canvas, size, k);

    // Anchored just below the bottom edge, so the scope reads as a horizon
    // sweep rising into the empty area under the card grid -- that space was
    // otherwise flat and dead. Only the upper half is on screen, which is
    // also why the sweep spends half its cycle invisible and that is fine:
    // a real scope does the same when you only see part of the scope face.
    // Radius is sized off WIDTH, not height.
    //
    // At 0.46h this was ~1457px on this phone against a 720px half-width, so
    // any contact more than a few degrees off vertical was thrown past the
    // left or right edge and clipped. Scoping it to width keeps the whole
    // scope on screen whatever the aspect ratio.
    final centre = Offset(w * 0.5, h * 0.99);
    final maxR = w * 0.80;

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = accent.withValues(alpha: (0.26 * k).clamp(0.0, 1.0));

    for (var i = 1; i <= 5; i++) {
      canvas.drawCircle(centre, maxR * (i / 5), ringPaint);
    }

    // Bearing ticks every 30 degrees, longer at the cardinals.
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      final outer = maxR;
      final inner = maxR * (i % 3 == 0 ? 0.86 : 0.93);
      canvas.drawLine(
        centre + Offset(math.cos(a) * inner, math.sin(a) * inner),
        centre + Offset(math.cos(a) * outer, math.sin(a) * outer),
        Paint()
          ..strokeWidth = i % 3 == 0 ? 2.0 : 1.3
          ..color = accent.withValues(alpha: (0.34 * k).clamp(0.0, 1.0)),
      );
    }

    // Cross-hairs.
    canvas.drawLine(centre - Offset(maxR, 0), centre + Offset(maxR, 0),
        ringPaint);
    canvas.drawLine(centre - Offset(0, maxR), centre + Offset(0, maxR),
        ringPaint);

    // The sweep: a wedge whose trailing edge fades, imitating the decay behind
    // a real beam. SweepGradient starts at 3 o'clock, hence the rotation.
    //
    // Mapped to the UPPER half only (pi..2pi) rather than a full revolution:
    // with the hub below the screen, a full turn would spend half its cycle
    // off-screen and the scope would look broken for seconds at a time.
    final beam = math.pi + progress * math.pi;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(beam);
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: maxR),
      // Narrower trail (45 deg, was 60): a wide wedge at this radius covers a
      // large fraction of the lower screen at once.
      -math.pi / 4,
      math.pi / 4,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: -math.pi / 4,
          endAngle: 0,
          // Much softer than the rings and ticks. Those are thin strokes and
          // needed the opacity; a filled wedge at the same alpha becomes a
          // solid shape with a hard edge -- it stopped reading as a sweep and
          // started reading as a stray panel across the bottom of the screen.
          colors: [
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: (0.09 * k).clamp(0.0, 1.0)),
          ],
        ).createShader(
            Rect.fromCircle(center: Offset.zero, radius: maxR)),
    );
    // Leading edge, brightest.
    canvas.drawLine(
      Offset.zero,
      Offset(maxR, 0),
      Paint()
        ..strokeWidth = 2.0
        ..color = accent.withValues(alpha: (0.45 * k).clamp(0.0, 1.0)),
    );
    canvas.restore();

    // Contacts light up as the beam passes and fade behind it.
    for (final contact in _contacts) {
      // Same pi..2pi mapping as the beam, so a contact lights exactly when the
      // sweep reaches it.
      final ang = math.pi + contact[0] * math.pi;
      final r = maxR * contact[1];
      final pos = centre + Offset(math.cos(ang) * r, math.sin(ang) * r);

      // How far the beam has travelled past this contact, 0..1.
      var since = (progress - contact[0]) % 1.0;
      if (since < 0) since += 1.0;
      // Bright immediately after the beam crosses, then decays over ~40% of a
      // pass.
      final glow = since < 0.40 ? (1.0 - since / 0.40) : 0.0;
      if (glow <= 0.01) continue;

      // Severity colour, not the accent: these are things the scope has
      // FOUND, and the app already uses this exact palette to mean damage on
      // the map. As accent-coloured blips they were indistinguishable from
      // the rings and disappeared into the scope.
      final tier = contact[2].toInt();
      final hazard = _severityColors[tier];
      // Worse damage reads bigger, the same way pins are sized on the map.
      final scale = 1.0 + tier * 0.28;

      // Expanding ring, as though the contact were pinging back.
      canvas.drawCircle(
        pos,
        (6.0 + 16.0 * (1.0 - glow)) * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = hazard.withValues(alpha: 0.45 * glow * k.clamp(0.0, 1.4)),
      );
      canvas.drawCircle(
        pos,
        (16.0 * glow + 5.0) * scale,
        Paint()
          ..color = hazard.withValues(alpha: 0.38 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
      );
      canvas.drawCircle(
        pos,
        4.5 * scale,
        Paint()..color = hazard.withValues(alpha: glow),
      );
    }

    // Corner brackets, the way an instrument frames its active area. Cheap,
    // and they make the screen read as a panel rather than as a wallpaper
    // with a circle on it.
    const bracket = 26.0;
    const inset = 14.0;
    final bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = accent.withValues(alpha: (0.26 * k).clamp(0.0, 1.0));
    for (final corner in [
      [inset, inset, 1.0, 1.0],
      [w - inset, inset, -1.0, 1.0],
      [inset, h - inset, 1.0, -1.0],
      [w - inset, h - inset, -1.0, -1.0],
    ]) {
      final cx = corner[0], cy = corner[1], sx = corner[2], sy = corner[3];
      canvas.drawLine(
          Offset(cx, cy), Offset(cx + bracket * sx, cy), bracketPaint);
      canvas.drawLine(
          Offset(cx, cy), Offset(cx, cy + bracket * sy), bracketPaint);
    }
  }

  /// A multi-lane highway receding toward a vanishing point.
  ///
  /// Deliberately literal. A radar alone says "scanning"; this says what is
  /// being scanned, which for a road-hazard app is the point. Kept to the
  /// upper screen so it sits behind the heading rather than under the cards.
  ///
  /// Five lanes rather than one carriageway: a single road with a centre line
  /// read as a thin wedge, whereas a set of converging lanes is immediately
  /// legible as a highway even at this opacity.
  void _paintRoad(Canvas canvas, Size size, double k) {
    final w = size.width;
    final h = size.height;
    final accent = colors.accent;

    // Vanishing point at top CENTRE, with the carriageway opening out to far
    // beyond both screen edges.
    //
    // It sat at 0.80w before, which cornered the whole road in the top right
    // and left the left-hand half of the screen empty. Centring it makes the
    // cone symmetrical and fills the page, and the lanes then read as a wide
    // multi-lane highway rather than a narrow slip road tucked into a corner.
    //
    // The near edge is pushed well below the screen (1.4h). Ending it inside
    // the viewport left a hard horizontal cut across the middle -- the road
    // visibly stopped in mid-air. Running it off the bottom means it simply
    // passes behind the cards, the way a road would.
    final vp = Offset(w * 0.5, h * 0.02);
    final nearL = Offset(-w * 2.6, h * 1.4);
    final nearR = Offset(w * 3.6, h * 1.4);

    // Distance bands: full-width rules that compress toward the vanishing
    // point, the way transverse road markings and field boundaries do. With
    // the cone now spanning the page these cross the whole screen rather than
    // filling a dead flank.
    for (var i = 1; i <= 8; i++) {
      final t = math.pow(i / 8, 2.1).toDouble();
      final y = ui.lerpDouble(vp.dy, h * 1.02, t)!;
      final spread = w * (0.04 + 1.25 * t);
      canvas.drawLine(
        Offset(vp.dx - spread, y),
        Offset(vp.dx + spread, y),
        Paint()
          ..strokeWidth = 1.0
          ..color = accent.withValues(
              alpha: ((0.012 + 0.042 * t) * k).clamp(0.0, 1.0)),
      );
    }

    // Surface wash between the outer edges, so the road reads as a plane
    // rather than as a set of loose lines. Fades out before the cards so the
    // wash never sits behind a tile as a visible band.
    canvas.drawPath(
      Path()
        ..moveTo(vp.dx, vp.dy)
        ..lineTo(nearL.dx, nearL.dy)
        ..lineTo(nearR.dx, nearR.dy)
        ..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: (0.055 * k).clamp(0.0, 1.0)),
            accent.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.34, 0.72],
        ).createShader(Rect.fromLTRB(0, vp.dy, w, h)),
    );

    // Outer edges. Drawn as short segments with falling alpha rather than one
    // straight line, so they dissolve as they approach the cards instead of
    // running under a tile and reappearing.
    for (final near in [nearL, nearR]) {
      for (var i = 0; i < 16; i++) {
        final t0 = i / 16, t1 = (i + 1) / 16;
        // Fade to nothing by ~55% of the way down.
        final fade = (1.0 - (t0 / 0.55)).clamp(0.0, 1.0);
        if (fade <= 0.01) break;
        canvas.drawLine(
          Offset.lerp(vp, near, t0)!,
          Offset.lerp(vp, near, t1)!,
          Paint()
            ..strokeWidth = 1.2 + 1.8 * t0
            ..strokeCap = StrokeCap.round
            ..color = accent
                .withValues(alpha: (0.16 * fade * k).clamp(0.0, 1.0)),
        );
      }
    }

    // Four dashed dividers between them -> five lanes.
    //
    // Dash length grows toward the viewer. Evenly spaced dashes read as a flat
    // ladder; scaling them with distance is what actually sells the
    // perspective.
    // 18 lanes. At this spread they converge into a dense fan near the
    // vanishing point and open out to comfortable spacing at the bottom of
    // the screen, which is what makes the perspective read.
    const lanes = 18;
    for (var lane = 1; lane < lanes; lane++) {
      final near = Offset.lerp(nearL, nearR, lane / lanes)!;
      for (var i = 0; i < 14; i++) {
        final t0 = math.pow(i / 14, 1.9).toDouble();
        final t1 = math.pow((i + 0.42) / 14, 1.9).toDouble();
        // Same dissolve as the edges, so the whole road fades together rather
        // than the dashes outliving the lines that contain them.
        final fade = (1.0 - (t0 / 0.55)).clamp(0.0, 1.0);
        if (fade <= 0.01) break;
        canvas.drawLine(
          Offset.lerp(vp, near, t0)!,
          Offset.lerp(vp, near, t1)!,
          Paint()
            ..strokeWidth = 0.8 + 2.4 * t0
            ..strokeCap = StrokeCap.round
            ..color = accent.withValues(
                alpha: ((0.05 + 0.14 * t0) * fade * k).clamp(0.0, 1.0)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CampusBackdrop old) =>
      old.progress != progress || old.colors != colors;
}
