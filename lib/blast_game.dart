import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'blast_image.dart';
import 'blast_model.dart';
import 'blast_sound.dart';
import 'storage.dart';
import 'theme.dart';

/// Sample points of a track layout, for tests that verify the shapes are
/// genuinely different curves rather than one path with a tweak.
@visibleForTesting
List<Offset> debugBlastPath(BlastShape shape, double turns) {
  final game = _Game(
    [const BlastItem(word: 'x', image: 'data:,')],
    const {},
    track: BlastTrack(turns: turns, shape: shape),
  );
  return [for (final p in game.path) Offset(p.x, p.y)];
}

/// Flutter port of the TYPE//BLAST shooter: picture balls crawl a spiral
/// toward the exit, and typing a word launches the idol's bolt at it.
/// Drawn in the app's paper palette so it sits naturally as one more page.
class BlastGame extends StatefulWidget {
  final StorageService storage;
  final BlastBundle bundle;
  final VoidCallback onExit;
  final BlastTrack track;
  final ValueChanged<BlastTrack> onTrackChanged;

  const BlastGame({
    super.key,
    required this.storage,
    required this.bundle,
    required this.onExit,
    required this.track,
    required this.onTrackChanged,
  });

  @override
  State<BlastGame> createState() => BlastGameState();
}

class BlastGameState extends State<BlastGame>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final _Game _game;
  Duration? _last;
  final FocusNode _focus = FocusNode();
  final Map<String, ui.Image> _images = {};
  final BlastSound _sound = BlastSound();
  late BlastTrack _track;
  bool _showTrackSettings = false;

  /// The canvas repaints through this notifier every frame; only real HUD
  /// changes trigger a (much more expensive) widget rebuild.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  late final _GamePainter _painter;
  String _hudKey = '';

  @override
  void initState() {
    super.initState();
    _track = widget.track;
    _game = _Game(widget.bundle.items, _images, track: widget.track)
      ..onSound = _sound.play;
    _painter = _GamePainter(_game, repaint: _frame);
    _ticker = createTicker(_onTick)..start();
    _loadImages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    _game.dispose();
    _focus.dispose();
    _sound.dispose();
    super.dispose();
  }

  Future<void> _loadImages() async {
    for (final item in widget.bundle.items) {
      final provider = blastImageProvider(widget.storage, item.image);
      if (provider == null) continue;
      final completer = Completer<ui.Image?>();
      provider.resolve(const ImageConfiguration()).addListener(
        ImageStreamListener(
          (info, _) {
            if (!completer.isCompleted) completer.complete(info.image);
          },
          onError: (error, stackTrace) {
            if (!completer.isCompleted) completer.complete(null);
          },
        ),
      );
      final image = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
      if (image != null && mounted) {
        setState(() => _images[item.word] = image);
      }
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _last == null
        ? 0.0
        : (elapsed - _last!).inMicroseconds / 1000000.0;
    _last = elapsed;
    if (_game.running && !_game.paused && !_game.over) {
      _game.update(dt.clamp(0.0, 0.05));
    }
    if (!mounted) return;

    // Canvas-only refresh for smooth motion.
    _frame.value++;

    // Widget tree only when something the eye can read actually changes.
    // Exit risk is bucketed so the bar animates without a rebuild per pixel.
    final risk = _game.danger > 0.75
        ? 2
        : (_game.danger > 0.45 ? 1 : 0);
    final key = '${_game.score}|${_game.wave}|${_game.combo}|'
        '${_game.lives}|${_game.emp}|${_game.typed}|'
        '${_game.over}|${_game.paused}|${_game.waveBanner}|'
        '${_game.hoveredBall}|$risk|${_images.length}';
    if (key != _hudKey) {
      _hudKey = key;
      setState(() {});
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final log = event.logicalKey;
    String? key;
    if (log == LogicalKeyboardKey.backspace) {
      key = 'backspace';
    } else if (log == LogicalKeyboardKey.enter ||
        log == LogicalKeyboardKey.numpadEnter) {
      key = 'enter';
    } else if (log == LogicalKeyboardKey.escape) {
      key = 'escape';
    } else if (log == LogicalKeyboardKey.space) {
      // Two-part names such as "garbage disposal" need a space.
      key = ' ';
    } else {
      final ch = event.character;
      if (ch != null &&
          ch.length == 1 &&
          RegExp(r'[a-zA-Z0-9 ]').hasMatch(ch)) {
        key = ch.toLowerCase();
      }
    }
    if (key == null) return KeyEventResult.ignored;
    _sound.unlock(); // browsers only allow audio after a user gesture
    setState(() => _game.onKey(key!));
    return KeyEventResult.handled;
  }

  void _applyTrack(BlastTrack track) {
    setState(() {
      _track = track;
      _game.setTrack(track);
    });
    widget.onTrackChanged(track);
  }

  /// Test hook: type a word without needing a physical keyboard in the
  /// widget sandbox (the real page uses [Focus.onKeyEvent]).
  @visibleForTesting
  void debugType(String text) {
    for (final ch in text.split('')) {
      if (RegExp(r'[a-zA-Z0-9 ]').hasMatch(ch)) {
        _game.onKey(ch.toLowerCase());
      }
    }
  }

  @visibleForTesting
  String get debugTyped => _game.typed;

  @visibleForTesting
  double get debugTurns => _game.turns;

  @visibleForTesting
  BlastShape get debugShape => _game.shape;

  @visibleForTesting
  List<Offset> get debugPathPoints =>
      [for (final p in _game.path) Offset(p.x, p.y)];

  @visibleForTesting
  int get debugScore => _game.score;

  @visibleForTesting
  bool get debugRunning => _game.running;

  @visibleForTesting
  int get debugChainLength => _game.chain.length;

  @visibleForTesting
  void debugHover(String word) {
    for (final ball in _game.chain) {
      if (ball.word == word) {
        _game.hoverPoint = Offset(ball.x, ball.y);
        return;
      }
    }
  }

  void _quit() {
    _ticker.stop();
    _game.stop();
    widget.onExit();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PaperTheme.paper,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _sound.unlock();
            _focus.requestFocus();
          },
          child: Center(
            child: LayoutBuilder(
              builder: (context, cons) {
                final w = cons.maxWidth < double.infinity
                    ? math.min(540.0, cons.maxWidth - 40)
                    : 420.0;
                final side = math.max(240.0, w);
                final h = side * 4 / 3;
                if ((_game.w - side).abs() > 0.5 ||
                    (_game.h - h).abs() > 0.5) {
                  _game.resize(side, h);
                }
                final gutter = (cons.maxWidth - side) / 2;
                final hovered = _game.hoveredBall;
                final showPreview = gutter >= 235 && hovered != null;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 10),
                          MouseRegion(
                            onHover: (e) => _game.hoverPoint = e.localPosition,
                            onExit: (_) => _game.hoverPoint = null,
                            child: SizedBox(
                              width: side,
                              height: h,
                              child: _buildStage(side, h),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text(
                              'hover a ball to see it bigger  ·  type the name'
                              ' to fire  ·  ENTER for EMP  ·  Esc to pause',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: PaperTheme.inkSoft, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The board stays centred; the preview lives in the
                    // empty gutter on the right when there is room.
                    if (cons.maxWidth >= 700)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 18),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            child: showPreview
                                ? _buildPreview(hovered)
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Large read-only preview of the hovered ball, shown in the free space
  /// beside the board. IgnorePointer keeps the mouse on the game itself.
  Widget _buildPreview(String word) {
    final image = _images[word];
    return IgnorePointer(
      key: ValueKey<String>(word),
      child: Container(
        width: 210,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PaperTheme.paper,
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3E3A31).withValues(alpha: 0.14),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('PREVIEW',
                style: TextStyle(
                    color: PaperTheme.inkSoft,
                    fontSize: 10,
                    letterSpacing: 1.4)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 186,
                height: 186,
                color: PaperTheme.surface,
                child: image == null
                    ? const Icon(Icons.image_outlined,
                        size: 40, color: PaperTheme.inkSoft)
                    : RawImage(image: image, fit: BoxFit.cover),
              ),
            ),
            // No name here on purpose: the player has to recognise the
            // picture from the image alone to type it.
          ],
        ),
      ),
    );
  }

  Widget _buildStage(double w, double h) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _painter,
            child: const SizedBox.expand(),
          ),
        ),
        // Top HUD.
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Row(
            children: [
              _iconButton(
                icon: Icons.pause,
                tooltip: 'Pause',
                onTap: () => setState(() => _game.togglePause()),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: PaperTheme.surface.withValues(alpha: 0.9),
                    border: Border.all(color: PaperTheme.lineThin),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _stat('SCORE', '${_game.score}'),
                      _stat('WAVE', '${_game.wave}'),
                      _stat('COMBO', '×${math.min(_game.combo, 99)}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _iconButton(
                icon: Icons.tune,
                tooltip: 'Track settings',
                onTap: () =>
                    setState(() => _showTrackSettings = true),
              ),
              const SizedBox(width: 8),
              _iconButton(
                icon: _sound.muted ? Icons.volume_off : Icons.volume_up,
                tooltip: _sound.muted ? 'Unmute' : 'Mute',
                onTap: () {
                  _sound.unlock();
                  setState(() => _sound.muted = !_sound.muted);
                  if (!_sound.muted) _sound.play('ready');
                },
              ),
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8C878),
                  border: Border.all(color: PaperTheme.line),
                  shape: BoxShape.circle,
                ),
                child: Text('${math.max(0, _game.lives)}',
                    style: const TextStyle(
                        color: PaperTheme.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
        // Exit-risk meter.
        Positioned(
          top: 54,
          left: w / 2 - 85,
          width: 170,
          child: Column(
            children: [
              const Text('EXIT RISK',
                  style: TextStyle(
                      color: PaperTheme.inkSoft,
                      fontSize: 8,
                      letterSpacing: 1.5)),
              const SizedBox(height: 3),
              Container(
                height: 5,
                decoration: BoxDecoration(
                  color: PaperTheme.surface,
                  border: Border.all(color: PaperTheme.lineThin),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: _game.danger,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _game.danger > 0.75
                            ? const Color(0xFF8F2F25)
                            : (_game.danger > 0.45
                                ? const Color(0xFFB07A2E)
                                : const Color(0xFF6F8F6A)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Typed word sits at the TOP, above the board.
        Positioned(
          left: 10,
          right: 10,
          top: 84,
          child: Column(
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 30),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: PaperTheme.surface.withValues(alpha: 0.88),
                  border: Border.all(color: PaperTheme.lineThin),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  _game.typed.isEmpty ? '…' : _game.typed.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Color(0xFF8A621E),
                      fontSize: 18,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => setState(() => _game.fireEMP()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 6),
                      decoration: BoxDecoration(
                        color: PaperTheme.surface,
                        border: Border.all(color: PaperTheme.lineThin),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('EMP ${_game.emp}',
                          style: const TextStyle(
                              color: PaperTheme.ink,
                              fontSize: 10,
                              letterSpacing: 1)),
                    ),
                  ),
                  const Spacer(),
                  const Text('type the name',
                      style: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 10)),
                ],
              ),
            ],
          ),
        ),
        if (_game.waveBanner != null)
          Center(
            child: Text('WAVE ${_game.waveBanner}',
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 30,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w800)),
          ),
        if (_showTrackSettings && !_game.over)
          _trackSettingsOverlay(),
        if (_game.paused && !_game.over)
          _overlay([
            const Text('Paused',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 26,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Take a breath. The core can wait.',
                style: TextStyle(color: PaperTheme.inkSoft, fontSize: 12)),
            const SizedBox(height: 14),
            _wideButton('Resume', () {
              _focus.requestFocus();
              setState(() => _game.togglePause(false));
            }),
            _wideButton('Restart', () {
              _focus.requestFocus();
              setState(() {
                _game.togglePause(false);
                _game.start();
              });
            }),
            _wideButton('Quit to bundles', _quit),
          ]),
        if (_game.over) _gameOverOverlay(),
      ],
    );
  }

  Widget _trackSettingChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? PaperTheme.ink : PaperTheme.surface,
            border: Border.all(color: PaperTheme.lineThin),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? PaperTheme.paper : PaperTheme.ink,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _trackSettingsOverlay() {
    return _overlay([
      Row(
        children: [
          const Expanded(
            child: Text('Track settings',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
          ),
          InkWell(
            onTap: () => setState(() => _showTrackSettings = false),
            child: const Icon(Icons.close,
                size: 18, color: PaperTheme.inkSoft),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Align(
        alignment: Alignment.centerLeft,
        child: Text('LENGTH',
            style: TextStyle(
                color: PaperTheme.inkSoft,
                fontSize: 10,
                letterSpacing: 1.2)),
      ),
      const SizedBox(height: 6),
      Wrap(
        children: [
          for (final preset in BlastTrack.lengths)
            _trackSettingChip(
              label: preset.label,
              selected: (_track.turns - preset.turns).abs() < 0.01,
              onTap: () => _applyTrack(
                  BlastTrack(turns: preset.turns, shape: _track.shape)),
            ),
        ],
      ),
      const SizedBox(height: 8),
      const Align(
        alignment: Alignment.centerLeft,
        child: Text('SHAPE',
            style: TextStyle(
                color: PaperTheme.inkSoft,
                fontSize: 10,
                letterSpacing: 1.2)),
      ),
      const SizedBox(height: 6),
      Wrap(
        children: [
          for (final shape in BlastShape.values)
            _trackSettingChip(
              label: shape.label,
              selected: _track.shape == shape,
              onTap: () => _applyTrack(
                  BlastTrack(turns: _track.turns, shape: shape)),
            ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        'length: ${_track.turns.toStringAsFixed(2)} turns · ${_track.shape.label}',
        style: const TextStyle(color: PaperTheme.inkSoft, fontSize: 10),
      ),
      const SizedBox(height: 14),
      _wideButton('Done', () {
        _focus.requestFocus();
        setState(() => _showTrackSettings = false);
      }),
    ]);
  }

  Widget _gameOverOverlay() {
    return _overlay([
      const Text('Game Over',
          style: TextStyle(
              color: PaperTheme.ink,
              fontSize: 26,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _stat('SCORE', '${_game.score}'),
          _stat('WAVE', '${_game.wave}'),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _stat('ACCURACY', '${_game.accuracy}%'),
          _stat('WPM', '${_game.wpm}'),
        ],
      ),
      const SizedBox(height: 14),
      _wideButton('Play again', () {
        _focus.requestFocus();
        setState(() => _game.start());
      }),
      _wideButton('Back to bundles', _quit),
    ]);
  }

  Widget _overlay(List<Widget> children) {
    return Positioned.fill(
      child: Container(
        color: const Color(0xCCCFC5AB),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Material(
          color: PaperTheme.paper,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              border: Border.all(color: PaperTheme.lineThin),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  Widget _wideButton(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: PaperTheme.ink,
            foregroundColor: PaperTheme.paper,
          ),
          onPressed: onTap,
          child: Text(label),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 36,
          height: 34,
          decoration: BoxDecoration(
            color: PaperTheme.surface.withValues(alpha: 0.9),
            border: Border.all(color: PaperTheme.lineThin),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 16, color: PaperTheme.ink),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(
                color: PaperTheme.inkSoft, fontSize: 8, letterSpacing: 1.2)),
        Text(value,
            style: const TextStyle(
                color: PaperTheme.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _GamePainter extends CustomPainter {
  final _Game game;

  _GamePainter(this.game, {super.repaint});

  @override
  void paint(Canvas canvas, Size size) => game.draw(canvas);

  @override
  bool shouldRepaint(covariant _GamePainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Pure game state + rendering (ported from the original JavaScript game).
// ---------------------------------------------------------------------------

class _Pt {
  final double x;
  final double y;
  double len;
  _Pt(this.x, this.y, this.len);
}

class _Ball {
  final String word;
  final String image;
  double t;
  double targetT;
  double x;
  double y;
  final double r;
  int matched = 0;
  double scale = 0;

  _Ball({
    required this.word,
    required this.image,
    required this.t,
    required this.x,
    required this.y,
    required this.r,
  }) : targetT = t;
}

class _Shot {
  double x;
  double y;
  final String target;
  double angle = 0;
  _Shot(this.x, this.y, this.target);
}

class _Particle {
  double x;
  double y;
  double vx;
  double vy;
  double life;
  final double size;
  final Color color;
  _Particle(this.x, this.y, this.vx, this.vy, this.life, this.size, this.color);
}

class _Floater {
  double x;
  double y;
  final String text;
  double life;
  final bool bad;
  _Floater(this.x, this.y, this.text, this.life, this.bad);
}

class _Corpse {
  final double x;
  final double y;
  final double r;
  double life;
  final String image;
  _Corpse(this.x, this.y, this.r, this.life, this.image);
}

class _Shock {
  double radius = 0;
  double life;
  _Shock(this.life);
}

class _Game {
  final List<BlastItem> items;
  final Map<String, ui.Image> images;
  final math.Random _rand = math.Random();

  /// Sound hook; the widget wires this to the platform sound engine.
  void Function(String effect)? onSound;

  /// Pointer position inside the stage, for the gentle hover magnifier.
  Offset? hoverPoint;
  String? hoveredBall;

  double w = 400;
  double h = 533;
  double cx = 0;
  double cy = 0;
  double r0 = 0;
  double r1 = 0;
  BlastShape shape = BlastShape.spiral;
  double turns = 2.35;
  List<_Pt> path = [];
  double pathLen = 1;
  double gap = 0.05;
  _Pt exit = _Pt(0, 0, 0);
  List<Offset> speckles = [];

  /// The paper background and the whole track never change during a game.
  /// Bake them into one picture on resize instead of re-drawing hundreds of
  /// speckles, two gradients and 480 path segments every single frame.
  ui.Picture? _staticPicture;
  Path? _trackPathCache;

  /// Reused for the short-lived effects so a frame does not allocate a
  /// dozen Paint objects that the GC then has to clean up.
  final Paint _scratchPaint = Paint();

  bool running = false;
  bool paused = false;
  bool over = false;
  List<_Ball> chain = [];
  List<_Shot> shots = [];
  List<_Particle> particles = [];
  List<_Floater> floaters = [];
  List<_Corpse> corpses = [];
  List<_Shock> shocks = [];
  List<BlastItem> queue = [];
  double spawnTimer = 0;
  double waveDelay = -1;
  int score = 0;
  int combo = 0;
  int wave = 1;
  int lives = 3;
  int emp = 1;
  int hits = 0;
  int misses = 0;
  int correctChars = 0;
  DateTime startTime = DateTime.now();
  double danger = 0;
  String typed = '';
  String? targetId;
  int? waveBanner;
  DateTime? bannerUntil;
  double flashRed = 0;
  double flashCyan = 0;
  double gunAngle = -math.pi / 2;
  double gunTarget = -math.pi / 2;
  double recoil = 0;

  _Game(this.items, this.images, {BlastTrack? track}) {
    if (track != null) setTrack(track);
    resize(w, h);
    start();
  }

  /// Rebuild the track for a new length/shape, keeping balls at their
  /// current progress (positions are recomputed from each ball's t).
  void setTrack(BlastTrack track) {
    turns = track.turns;
    shape = track.shape;
    if (w > 0) resize(w, h);
  }

  int get accuracy =>
      hits + misses == 0 ? 0 : (hits * 100 / (hits + misses)).round();
  int get wpm {
    final mins = math.max(
        DateTime.now().difference(startTime).inMilliseconds / 60000.0,
        1 / 60);
    return (correctChars / 5 / mins).round();
  }

  void resize(double width, double height) {
    w = width;
    h = height;
    cx = w / 2;
    cy = h * 0.52;
    r0 = math.min(w * 0.455, h * 0.345);
    r1 = math.max(42, math.min(w, h) * 0.085);
    const n = 480;
    final pts = <_Pt>[];
    for (var i = 0; i <= n; i++) {
      final pt = _pathPoint(i / n);
      if (pts.isNotEmpty) {
        pt.len = pts.last.len +
            math.sqrt(math.pow(pt.x - pts.last.x, 2) +
                math.pow(pt.y - pts.last.y, 2));
      }
      pts.add(pt);
    }
    path = pts;
    pathLen = pts.last.len == 0 ? 1 : pts.last.len;
    gap = (math.max(30, math.min(44, w * 0.075)) + 4) / pathLen;
    exit = ptAt(1);
    for (final b in chain) {
      final p = ptAt(b.t);
      b.x = p.x;
      b.y = p.y;
    }
    speckles = [
      for (var i = 0; i < 260; i++)
        Offset(_rand.nextDouble() * w, _rand.nextDouble() * h),
    ];
    _buildStatic();
  }

  void _buildStatic() {
    _staticPicture?.dispose();
    _staticPicture = null;
    _trackPathCache = null;
    try {
      final recorder = ui.PictureRecorder();
      _paintStatic(Canvas(recorder));
      _staticPicture = recorder.endRecording();
      _trackPathCache = _makeTrackPath();
    } catch (_) {
      // Headless/test canvas may refuse a recorder: draw directly instead.
      _staticPicture = null;
      _trackPathCache = null;
    }
  }

  void _paintStatic(Canvas c) {
    _paintBackground(c);
    _paintTrack(c);
  }

  void dispose() {
    _staticPicture?.dispose();
    _staticPicture = null;
  }

  /// Point on the chosen track at progress [u] (0 = entry, 1 = exit).
  _Pt _pathPoint(double u) {
    final a = -math.pi / 2 + u * turns * math.pi * 2;
    switch (shape) {
      case BlastShape.spiral:
        final rad = r0 - (r0 - r1) * u;
        return _Pt(cx + rad * math.cos(a), cy + rad * math.sin(a) * 0.82, 0);

      case BlastShape.ring:
      case BlastShape.oval:
      case BlastShape.square:
        // Radius eases in across the loops, so each revolution sits just
        // inside the previous one (concentric rings, no ball overlap).
        final rad = r0 - (r0 - r1) * u;
        if (shape == BlastShape.square) {
          final ca = math.cos(a);
          final sa = math.sin(a);
          final den = math.pow(
              math.pow(ca.abs(), 4) + math.pow(sa.abs(), 4), 0.25);
          return _Pt(cx + rad * ca / den, cy + rad * sa / den, 0);
        }
        final ys = shape == BlastShape.oval ? 0.52 : 1.0;
        return _Pt(cx + rad * math.cos(a), cy + rad * math.sin(a) * ys, 0);

      case BlastShape.figure8:
        // Lemniscate; [turns] sets how many lobes it draws.
        final q = u * turns * math.pi;
        final den = 1 + math.pow(math.sin(q), 2);
        final rx = r0 * 0.92 * math.cos(q) / den;
        final ry = r0 * 1.1 * math.sin(q) * math.cos(q) / den;
        return _Pt(cx + rx, cy + ry, 0);

      case BlastShape.wave:
        // Serpentine: enter at the left, leave at the right, with
        // [turns] controlling the number of bends.
        final x = cx - r0 + 2 * r0 * u;
        final amp = r0 - (r0 - r1) * u * 0.8;
        final y = cy + amp * math.sin(u * turns * math.pi * 2);
        return _Pt(x, y, 0);
    }
  }

  _Pt ptAt(double t) {
    if (path.isEmpty) return _Pt(cx, cy, 0);
    final target = t.clamp(0.0, 1.0) * pathLen;
    var lo = 0;
    var hi = path.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (path[mid].len < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final i = math.max(1, lo);
    final a = path[i - 1];
    final b = path[i];
    final span = (b.len - a.len) == 0 ? 1 : b.len - a.len;
    final f = (target - a.len) / span;
    return _Pt(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, 0);
  }

  void start() {
    running = items.isNotEmpty;
    paused = false;
    over = false;
    score = 0;
    combo = 0;
    wave = 1;
    lives = 3;
    emp = 1;
    hits = 0;
    misses = 0;
    correctChars = 0;
    startTime = DateTime.now();
    chain = [];
    shots = [];
    particles = [];
    floaters = [];
    corpses = [];
    shocks = [];
    typed = '';
    targetId = null;
    danger = 0;
    flashRed = 0;
    flashCyan = 0;
    gunAngle = -math.pi / 2;
    gunTarget = -math.pi / 2;
    recoil = 0;
    if (!running) return;
    onSound?.call('ready');
    startWave(1);
  }

  void stop() {
    running = false;
  }

  void startWave(int n) {
    wave = n;
    queue = List<BlastItem>.of(items)..shuffle(_rand);
    spawnTimer = 0.4;
    waveDelay = -1;
    if (n > 1 && n % 3 == 0 && emp < 3) emp++;
    if (n > 1) onSound?.call('wave');
    waveBanner = n;
    bannerUntil = DateTime.now().add(const Duration(milliseconds: 1500));
  }

  void togglePause([bool? force]) {
    if (!running || over) return;
    paused = force ?? !paused;
  }

  _Ball? _ball(String id) {
    for (final b in chain) {
      if (b.word == id) return b;
    }
    return null;
  }

  void _clearTarget() {
    targetId = null;
    for (final b in chain) {
      b.matched = 0;
    }
  }

  void onKey(String key) {
    if (!running) return;
    if (key == 'escape') {
      if (!over) togglePause();
      return;
    }
    if (paused || over) return;
    if (key == 'enter') {
      fireEMP();
      return;
    }
    if (key == 'backspace') {
      if (typed.isEmpty) return;
      typed = typed.substring(0, typed.length - 1);
      if (typed.isEmpty) {
        _clearTarget();
      } else {
        final cur = targetId == null ? null : _ball(targetId!);
        if (cur == null || !cur.word.startsWith(typed)) {
          _clearTarget();
        } else {
          for (final b in chain) {
            b.matched = b.word == targetId ? typed.length : 0;
          }
        }
      }
      return;
    }
    _typeChar(key);
  }

  /// Try the next letter WITHOUT destroying progress. A wrong key is
  /// simply ignored (small flash + miss sound): the player keeps what they
  /// already typed and only needs to enter the correct next letter.
  void _typeChar(String ch) {
    final candidate = typed + ch;
    _Ball? target;
    if (targetId != null) {
      final cur = _ball(targetId!);
      if (cur != null && cur.word.startsWith(candidate)) target = cur;
    }
    if (target == null) {
      for (final b in chain) {
        if (!b.word.startsWith(candidate)) continue;
        if (target == null || b.t > target.t) target = b;
      }
    }
    if (target == null) {
      // Wrong letter: keep [typed] intact so it can be corrected by
      // simply typing the right letter (or Backspace).
      misses++;
      combo = 0;
      flashRed = 0.2;
      onSound?.call('miss');
      return;
    }
    typed = candidate;
    targetId = target.word;
    for (final b in chain) {
      b.matched = b.word == target.word ? typed.length : 0;
    }
    if (typed.length == 1) onSound?.call('lock');
    if (typed == target.word) _launchShot(target);
  }

  _Ball _makeBall(BlastItem item, double t) {
    final p = ptAt(t.clamp(0.0, 1.0));
    return _Ball(
      word: item.word,
      image: item.image,
      t: t,
      x: p.x,
      y: p.y,
      r: math.max(16, math.min(22, w * 0.038)),
    );
  }

  void _repack() {
    for (var i = 1; i < chain.length; i++) {
      chain[i].targetT = math.max(0, chain[i - 1].targetT - gap);
    }
  }

  void _launchShot(_Ball b) {
    shots.add(_Shot(cx, cy, b.word));
    recoil = 9;
    gunTarget = math.atan2(b.y - cy, b.x - cx) + math.pi / 2;
    _clearTarget();
    typed = '';
    onSound?.call('shoot');
  }

  void _destroyBall(_Ball b) {
    final idx = chain.indexOf(b);
    if (idx < 0) return;
    chain.removeAt(idx);
    if (targetId == b.word) _clearTarget();
    _repack();
    hits++;
    correctChars += b.word.length;
    combo++;
    score += b.word.length * 10 * math.min(combo, 10);
    corpses.add(_Corpse(b.x, b.y, b.r, 0.28, b.image));
    _burst(b.x, b.y, 18);
    floaters.add(_Floater(
        b.x, b.y - 10, '+${b.word.length * 10 * math.min(combo, 10)}', 1, false));
    onSound?.call('explode');
  }

  void fireEMP() {
    if (!running || emp <= 0 || over || paused) return;
    emp--;
    flashCyan = 0.9;
    shocks.add(_Shock(0.7));
    for (final b in chain) {
      score += 25;
      hits++;
      corpses.add(_Corpse(b.x, b.y, b.r, 0.28, b.image));
      _burst(b.x, b.y, 12);
    }
    chain = [];
    _clearTarget();
    typed = '';
    combo = 0;
    onSound?.call('emp');
  }

  void _burst(double x, double y, int count) {
    for (var i = 0; i < count; i++) {
      final a = _rand.nextDouble() * math.pi * 2;
      final sp = 30 + _rand.nextDouble() * 170;
      particles.add(_Particle(
        x,
        y,
        math.cos(a) * sp,
        math.sin(a) * sp,
        0.4 + _rand.nextDouble() * 0.5,
        1.5 + _rand.nextDouble() * 3,
        PaperTheme.ink,
      ));
    }
  }

  void _breach() {
    if (chain.isEmpty) return;
    final leader = chain.removeAt(0);
    _repack();
    lives--;
    combo = 0;
    flashRed = 1;
    _burst(exit.x, exit.y, 26);
    floaters.add(_Floater(exit.x, exit.y - 16, 'BREACH', 1, true));
    onSound?.call('damage');
    if (targetId == leader.word) _clearTarget();
    if (lives <= 0) {
      over = true;
      running = false;
    }
  }

  void update(double dt) {
    if (queue.isNotEmpty) {
      spawnTimer -= dt;
      if (spawnTimer <= 0) {
        final tail = chain.isEmpty ? null : chain.last;
        chain.add(_makeBall(
            queue.removeAt(0), tail == null ? 0 : tail.targetT - gap));
        spawnTimer = math.max(0.5, 1.65 - wave * 0.12);
      }
    }
    final speed = 34 + wave * 5;
    for (final b in chain) {
      b.targetT += (speed * dt) / pathLen;
    }
    _repack();
    for (final b in chain) {
      b.t += (b.targetT - b.t) * math.min(1, dt * 9);
      final p = ptAt(b.t);
      b.x = p.x;
      b.y = p.y;
      b.scale = math.min(1, b.scale + dt * 5);
    }
    if (chain.isNotEmpty && chain.first.t >= 1) {
      _breach();
      if (over) return;
    }
    danger = chain.isEmpty ? 0 : math.max(0, math.min(1, chain.first.t));

    for (var i = shots.length - 1; i >= 0; i--) {
      final sh = shots[i];
      final target = _ball(sh.target);
      if (target == null) {
        shots.removeAt(i);
        continue;
      }
      final dx = target.x - sh.x;
      final dy = target.y - sh.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      final step = 900 * dt;
      if (dist <= step + 4) {
        _destroyBall(target);
        shots.removeAt(i);
      } else {
        sh.x += dx / dist * step;
        sh.y += dy / dist * step;
        sh.angle = math.atan2(dy, dx);
      }
    }

    if (queue.isEmpty && chain.isEmpty && shots.isEmpty && waveDelay < 0) {
      waveDelay = 1.4;
    }
    if (waveDelay > 0) {
      waveDelay -= dt;
      if (waveDelay <= 0) {
        waveDelay = -1;
        startWave(wave + 1);
      }
    }

    for (var i = corpses.length - 1; i >= 0; i--) {
      corpses[i].life -= dt;
      if (corpses[i].life <= 0) corpses.removeAt(i);
    }
    for (var i = particles.length - 1; i >= 0; i--) {
      final p = particles[i];
      p.life -= dt;
      if (p.life <= 0) {
        particles.removeAt(i);
        continue;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vy += 160 * dt;
      p.vx *= 0.98;
    }
    for (var i = floaters.length - 1; i >= 0; i--) {
      floaters[i].life -= dt;
      floaters[i].y -= 26 * dt;
      if (floaters[i].life <= 0) floaters.removeAt(i);
    }
    for (var i = shocks.length - 1; i >= 0; i--) {
      shocks[i].life -= dt;
      shocks[i].radius = math.sqrt(w * w + h * h) * (1 - shocks[i].life / 0.7);
      if (shocks[i].life <= 0) shocks.removeAt(i);
    }
    if (bannerUntil != null && DateTime.now().isAfter(bannerUntil!)) {
      waveBanner = null;
      bannerUntil = null;
    }

    _Ball? aim = targetId == null ? null : _ball(targetId!);
    if (aim == null && shots.isNotEmpty) {
      aim = _ball(shots.last.target);
    }
    gunTarget = aim == null
        ? -math.pi / 2
        : math.atan2(aim.y - cy, aim.x - cx) + math.pi / 2;
    var d = gunTarget - gunAngle;
    while (d > math.pi) {
      d -= math.pi * 2;
    }
    while (d < -math.pi) {
      d += math.pi * 2;
    }
    gunAngle += d * math.min(1, dt * 7);
    recoil *= math.max(0, 1 - dt * 9);
    flashRed = math.max(0, flashRed - dt * 2.5);
    flashCyan = math.max(0, flashCyan - dt * 1.6);
  }

  // ---- Drawing ----

  void _updateHover() {
    final p = hoverPoint;
    hoveredBall = null;
    if (p == null) return;
    var best = double.infinity;
    for (final b in chain) {
      final dx = b.x - p.dx;
      final dy = b.y - p.dy;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d <= b.r * b.scale + 6 && d < best) {
        best = d;
        hoveredBall = b.word;
      }
    }
  }

  void draw(Canvas c) {
    _updateHover();
    final staticPicture = _staticPicture;
    if (staticPicture != null) {
      c.drawPicture(staticPicture);
    } else {
      _paintBackground(c);
      _paintTrack(c);
    }
    _drawExit(c);
    // Hovered ball goes last, so its enlarged picture is never hidden by
    // the rest of the chain.
    for (final b in chain) {
      if (b.word != hoveredBall) _drawBall(c, b);
    }
    for (final b in chain) {
      if (b.word == hoveredBall) _drawBall(c, b, zoom: 1.45);
    }
    for (final corpse in corpses) {
      final a = (corpse.life / 0.28).clamp(0.0, 1.0);
      c.drawCircle(
        Offset(corpse.x, corpse.y),
        corpse.r * (0.4 + 0.6 * a),
        _scratchPaint
          ..color = PaperTheme.ink.withValues(alpha: a * 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (final sh in shots) {
      c.save();
      c.translate(sh.x, sh.y);
      c.rotate(sh.angle);
      c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(-12, -2.5, 20, 5),
            const Radius.circular(2)),
        _scratchPaint
          ..color = PaperTheme.ink
          ..style = PaintingStyle.fill,
      );
      c.restore();
    }
    for (final p in particles) {
      c.drawCircle(
        Offset(p.x, p.y),
        p.size,
        _scratchPaint
          ..color = p.color.withValues(alpha: (p.life / 0.9).clamp(0.0, 1.0))
          ..style = PaintingStyle.fill,
      );
    }
    for (final s in shocks) {
      c.drawCircle(
        Offset(cx, cy),
        s.radius,
        _scratchPaint
          ..color = const Color(0xFF6F8F6A)
              .withValues(alpha: (s.life / 0.7).clamp(0.0, 1.0) * 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + 6 * (s.life / 0.7),
      );
    }
    _drawIdol(c);
    for (final f in floaters) {
      final paint = Paint()
        ..color = (f.bad ? const Color(0xFF8F2F25) : const Color(0xFF8A621E))
            .withValues(alpha: (f.life / 1.0).clamp(0.0, 1.0));
      final tp = TextPainter(
        text: TextSpan(
            text: f.text,
            style: TextStyle(
                color: paint.color,
                fontSize: 16,
                fontWeight: FontWeight.w800)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(f.x - tp.width / 2, f.y));
    }
    if (flashRed > 0) {
      c.drawRect(
        Offset.zero & Size(w, h),
        _scratchPaint
          ..color = const Color(0xFF8F2F25).withValues(alpha: flashRed * 0.16)
          ..style = PaintingStyle.fill,
      );
    }
    if (flashCyan > 0) {
      c.drawRect(
        Offset.zero & Size(w, h),
        _scratchPaint
          ..color = const Color(0xFF6F8F6A).withValues(alpha: flashCyan * 0.2)
          ..style = PaintingStyle.fill,
      );
    }
  }

  void _paintBackground(Canvas c) {
    c.drawRect(Offset.zero & Size(w, h), Paint()..color = PaperTheme.paper);
    final shader = RadialGradient(
      center: Alignment.center,
      radius: 0.75,
      colors: [
        const Color(0xFFF3EDDE),
        PaperTheme.paperDark,
      ],
    ).createShader(Offset.zero & Size(w, h));
    c.drawRect(Offset.zero & Size(w, h), Paint()..shader = shader);
    final dot = Paint()..color = PaperTheme.line.withValues(alpha: 0.25);
    for (final p in speckles) {
      c.drawCircle(p, 0.7, dot);
    }
    final ring = Paint()
      ..color = PaperTheme.line.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var r = 46.0; r < 150; r += 18) {
      c.drawOval(
          Rect.fromCenter(
              center: Offset(cx, cy), width: r * 2, height: r * 2 * 0.82),
          ring);
    }
    final vignette = RadialGradient(
      center: Alignment.center,
      radius: 0.9,
      colors: [Colors.transparent, const Color(0x33403B31)],
    ).createShader(Offset.zero & Size(w, h));
    c.drawRect(Offset.zero & Size(w, h), Paint()..shader = vignette);
  }

  Path _makeTrackPath() {
    final p = Path();
    if (path.isEmpty) return p;
    p.moveTo(path.first.x, path.first.y);
    for (var i = 1; i < path.length; i++) {
      p.lineTo(path[i].x, path[i].y);
    }
    return p;
  }

  void _paintTrack(Canvas c) {
    final p = _trackPathCache ?? _makeTrackPath();
    const layers = <({double width, Color color})>[
      (width: 64, color: Color(0x55403B31)),
      (width: 56, color: Color(0xFF9A917D)),
      (width: 50, color: Color(0xFFC9BFA9)),
      (width: 44, color: Color(0xFFE9E2D3)),
      (width: 38, color: Color(0xFFD9D0BA)),
    ];
    for (final layer in layers) {
      c.drawPath(
        p,
        Paint()
          ..strokeWidth = layer.width
          ..color = layer.color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _drawExit(Canvas c) {
    c.save();
    c.translate(exit.x, exit.y);
    c.drawCircle(
      Offset.zero,
      r1 * 0.9,
      Paint()..color = const Color(0xFF8F2F25).withValues(alpha: 0.22),
    );
    c.drawCircle(
      Offset.zero,
      r1 * 0.72,
      Paint()..color = const Color(0xFF3A2A22),
    );
    c.drawCircle(
      Offset.zero,
      r1 * 0.68,
      Paint()..color = const Color(0xFF2C201A),
    );
    c.drawCircle(
      Offset.zero,
      r1 * 0.72,
      Paint()
        ..color = const Color(0xFF8F2F25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    for (var i = 0; i < 12; i++) {
      final a = i / 12 * math.pi * 2;
      final rA = r1 * 0.68;
      final rB = rA - 8;
      final teeth = Path()
        ..moveTo(math.cos(a) * rA, math.sin(a) * rA)
        ..lineTo(math.cos(a + 0.18) * rA, math.sin(a + 0.18) * rA)
        ..lineTo(math.cos(a + 0.09) * rB, math.sin(a + 0.09) * rB)
        ..close();
      c.drawPath(teeth, Paint()..color = const Color(0xFF5A4032));
    }
    final tp = TextPainter(
      text: const TextSpan(
          text: 'EXIT',
          style: TextStyle(
              color: Color(0xFFE8C0A0), fontSize: 8, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
    c.restore();
  }

  void _drawBall(Canvas c, _Ball b, {double zoom = 1}) {
    final targeted = b.word == targetId;
    final s = b.scale * zoom;
    final r = b.r * s;
    c.save();
    c.translate(b.x, b.y);

    c.drawOval(
      Rect.fromCenter(
          center: const Offset(2, 0), width: r * 1.9, height: r * 0.9),
      Paint()..color = const Color(0x55403B31),
    );

    final body = RadialGradient(
      center: const Alignment(-0.3, -0.4),
      radius: 1.0,
      colors: [const Color(0xFFF6F0E2), const Color(0xFFC9BFA9)],
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: r));
    if (targeted) {
      c.drawCircle(
        Offset.zero,
        r + 6,
        Paint()..color = const Color(0xFFB07A2E).withValues(alpha: 0.25),
      );
    }
    c.drawCircle(Offset.zero, r, Paint()..shader = body);

    c.save();
    c.scale(s, s);
    c.clipPath(Path()
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: math.max(0.5, b.r - 1))));
    final image = images[b.word];
    if (image != null) {
      final s = math.max(2 * b.r / image.width, 2 * b.r / image.height);
      final dw = image.width * s;
      final dh = image.height * s;
      c.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(-dw / 2, -dh / 2, dw, dh),
        Paint(),
      );
    } else {
      final tp = TextPainter(
        text: TextSpan(
            text: b.word.isEmpty ? '?' : b.word[0].toUpperCase(),
            style: TextStyle(
                color: PaperTheme.inkSoft,
                fontSize: b.r,
                fontWeight: FontWeight.w800)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
    }
    c.restore();

    c.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..color = targeted ? const Color(0xFFB07A2E) : PaperTheme.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = targeted ? 3 : 2,
    );
    if (targeted && b.matched > 0) {
      final pct = (b.matched / b.word.length).clamp(0.0, 1.0);
      c.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: r + 6),
        -math.pi / 2,
        math.pi * 2 * pct,
        false,
        Paint()
          ..color = const Color(0xFFB07A2E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    c.restore();
  }

  void _roundRect(Canvas c, Rect rect, double r, Paint paint) {
    c.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)), paint);
  }

  void _drawIdol(Canvas c) {
    c.save();
    c.translate(cx, cy);
    c.drawOval(
      Rect.fromCenter(center: const Offset(0, 8), width: 84, height: 68),
      Paint()..color = const Color(0x55403B31),
    );
    c.drawCircle(Offset.zero, 36, Paint()..color = const Color(0xFF9A917D));
    c.drawCircle(
        Offset.zero,
        36,
        Paint()
          ..color = PaperTheme.inkSoft
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    c.drawCircle(
        Offset.zero,
        29,
        Paint()
          ..color = PaperTheme.line
          ..style = PaintingStyle.stroke);

    c.rotate(gunAngle);
    final rec = recoil;
    final stone = Paint()..color = const Color(0xFF7A7B69);
    _roundRect(
        c, Rect.fromLTWH(-8, -38 - rec, 16, 34), 6, stone);
    _roundRect(
        c,
        Rect.fromLTWH(-5, -40 - rec, 10, 12),
        4,
        Paint()..color = const Color(0xFF4A5147));
    c.drawCircle(
        Offset(0, -40 - rec),
        3.2,
        Paint()..color = const Color(0xFFB9E4D9));

    final body = RadialGradient(
      center: const Alignment(-0.3, -0.3),
      radius: 1.0,
      colors: [const Color(0xFFB3B49E), const Color(0xFF777C69)],
    ).createShader(Rect.fromCircle(center: const Offset(0, 4), radius: 28));
    c.drawOval(
      Rect.fromCenter(center: const Offset(0, 4), width: 50, height: 46),
      Paint()..shader = body,
    );
    for (final ex in [-12.0, 12.0]) {
      c.drawCircle(Offset(ex, -14), 9, Paint()..color = const Color(0xFF9A9D87));
      c.drawCircle(Offset(ex, -15), 5, Paint()..color = const Color(0xFF2E372F));
      c.drawCircle(
          Offset(ex + 1, -16),
          2.2,
          Paint()..color = const Color(0xFFE8C878));
    }
    c.drawArc(
      Rect.fromCenter(center: const Offset(0, 8), width: 24, height: 24),
      0.15 * math.pi,
      0.7 * math.pi,
      false,
      Paint()
        ..color = PaperTheme.inkSoft
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    c.restore();
  }
}
