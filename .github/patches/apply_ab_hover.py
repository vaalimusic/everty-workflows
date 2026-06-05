#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
# Force UTF-8 stdout/stderr on Windows runners (default cp1252 breaks Unicode).
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
"""
Everty patch: hover popup for peer cards in address book.
Targets RustDesk 1.4.6 (flutter/lib/common/widgets/peer_card.dart).

On mouse hover over a peer card a popup appears after 600ms showing:
  - Full note text (if set)
  - All tags with colors (if any)

Usage: python3 apply_ab_hover.py
"""

PATH = './flutter/lib/common/widgets/peer_card.dart'

try:
    with open(PATH, 'r', encoding='utf-8') as f:
        src = f.read()
except FileNotFoundError:
    print(f'ERROR: {PATH} not found', file=sys.stderr)
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# 1. Add dart:async import (needed for Timer)
# ─────────────────────────────────────────────────────────────────────────────
OLD_FIRST_IMPORT = "import 'package:bot_toast/bot_toast.dart';"
NEW_FIRST_IMPORT = "import 'dart:async';\nimport 'package:bot_toast/bot_toast.dart';"

if OLD_FIRST_IMPORT not in src:
    print('ERROR: bot_toast import not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_FIRST_IMPORT, NEW_FIRST_IMPORT, 1)
print('  [OK] dart:async import added')

# ─────────────────────────────────────────────────────────────────────────────
# 2. Insert _EvertyHoverCard widget before BasePeerCard
# ─────────────────────────────────────────────────────────────────────────────
HOVER_CARD_CLASS = r'''
// ─── Everty: hover popup for peer cards ──────────────────────────────────────
// Shows a floating popup with the peer's full note and all tags after the
// cursor rests on the card for 600 ms. Removed immediately on mouse-out.
// Only rendered on desktop; no-op on mobile/portrait.
class _EvertyHoverCard extends StatefulWidget {
  final Peer peer;
  final Widget child;

  const _EvertyHoverCard({Key? key, required this.peer, required this.child})
      : super(key: key);

  @override
  State<_EvertyHoverCard> createState() => _EvertyHoverCardState();
}

class _EvertyHoverCardState extends State<_EvertyHoverCard> {
  OverlayEntry? _overlay;
  Timer? _showTimer;
  final _boxKey = GlobalKey();

  bool get _hasContent =>
      widget.peer.note.isNotEmpty || widget.peer.tags.isNotEmpty;

  void _scheduleShow() {
    if (!_hasContent) return;
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 600), _doShow);
  }

  void _doShow() {
    if (!mounted) return;
    _removeOverlay();

    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenSize = MediaQuery.of(context).size;
    final popupW = (screenSize.width - 32).clamp(0.0, 260.0);

    // Position below the card, or above when near the bottom of the screen.
    final spaceBelow = screenSize.height - (pos.dy + size.height);
    final top = spaceBelow > 220
        ? pos.dy + size.height + 4
        : pos.dy - 220;

    // Clamp left so the popup never overflows the right edge.
    final left = (pos.dx).clamp(8.0, screenSize.width - popupW - 8);

    // Capture theme colors before entering the overlay builder — the builder
    // receives its own BuildContext and Theme.of() works there, but we
    // capture them here as a safety net.
    final surface = Theme.of(context).colorScheme.surface;
    final divider = Theme.of(context).dividerColor.withOpacity(0.25);
    final disabled = Theme.of(context).disabledColor;
    final textStyle = Theme.of(context).textTheme.bodyMedium;

    _overlay = OverlayEntry(builder: (_) => Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: popupW,
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: divider),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1A000000),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Note ────────────────────────────────────────────────────
                if (widget.peer.note.isNotEmpty) ...[
                  Row(children: [
                    Icon(Icons.notes_outlined, size: 13, color: disabled),
                    const SizedBox(width: 4),
                    Text('Note',
                        style: TextStyle(fontSize: 11, color: disabled)),
                  ]),
                  const SizedBox(height: 4),
                  Text(widget.peer.note,
                      style: textStyle?.copyWith(fontSize: 13)),
                  if (widget.peer.tags.isNotEmpty)
                    const SizedBox(height: 10),
                ],
                // ── Tags ────────────────────────────────────────────────────
                if (widget.peer.tags.isNotEmpty) ...[
                  Row(children: [
                    Icon(Icons.label_outline, size: 13, color: disabled),
                    const SizedBox(width: 4),
                    Text('Tags',
                        style: TextStyle(fontSize: 11, color: disabled)),
                  ]),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: widget.peer.tags.map((t) {
                      final tagColor =
                          gFFI.abModel.getCurrentAbTagColor(t);
                      final label =
                          t.contains('/') ? t.split('/').last : t;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: tagColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: tagColor.withOpacity(0.4),
                              width: 0.5),
                        ),
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 11, color: tagColor)),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ));
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _showTimer?.cancel();
    _showTimer = null;
    _overlay?.remove();
    _overlay = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only wrap with hover on desktop; on portrait/mobile pass through.
    if (!(isDesktop || isWebDesktop)) return widget.child;
    return MouseRegion(
      key: _boxKey,
      onEnter: (_) => _scheduleShow(),
      onExit: (_) => _removeOverlay(),
      child: widget.child,
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────

'''

INSERT_BEFORE = 'abstract class BasePeerCard extends StatelessWidget {'
if INSERT_BEFORE not in src:
    print('ERROR: BasePeerCard class not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(INSERT_BEFORE, HOVER_CARD_CLASS + INSERT_BEFORE, 1)
print('  [OK] _EvertyHoverCard class inserted')

# ─────────────────────────────────────────────────────────────────────────────
# 3a. In _buildLandscape: change "return MouseRegion(" to a local variable
#     so we can wrap it with _EvertyHoverCard.
# ─────────────────────────────────────────────────────────────────────────────
OLD_RETURN_MOUSE = '''    return MouseRegion(
      onEnter: (evt) {
        deco.value = BoxDecoration(
          border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: _borderWidth),'''

NEW_RETURN_MOUSE = '''    // Everty: assign to variable so _EvertyHoverCard can wrap it
    final _evertyHoverInner = MouseRegion(
      onEnter: (evt) {
        deco.value = BoxDecoration(
          border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: _borderWidth),'''

if OLD_RETURN_MOUSE not in src:
    print('ERROR: _buildLandscape MouseRegion not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_RETURN_MOUSE, NEW_RETURN_MOUSE, 1)
print('  [OK] _buildLandscape: MouseRegion assigned to variable')

# ─────────────────────────────────────────────────────────────────────────────
# 3b. Replace the closing of _buildLandscape to return _EvertyHoverCard
# ─────────────────────────────────────────────────────────────────────────────
OLD_LANDSCAPE_END = '''      child: gestureDetector(
          child: Obx(() => peerCardUiType.value == PeerUiType.grid
              ? _buildPeerCard(context, peer, deco)
              : _buildPeerTile(context, peer, deco))),
    );
  }'''

NEW_LANDSCAPE_END = '''      child: gestureDetector(
          child: Obx(() => peerCardUiType.value == PeerUiType.grid
              ? _buildPeerCard(context, peer, deco)
              : _buildPeerTile(context, peer, deco))),
    );
    // Everty: wrap with hover popup (note + tags shown on 600ms hover)
    return _EvertyHoverCard(peer: peer, child: _evertyHoverInner);
  }'''

if OLD_LANDSCAPE_END not in src:
    print('ERROR: _buildLandscape closing not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_LANDSCAPE_END, NEW_LANDSCAPE_END, 1)
print('  [OK] _buildLandscape: wrapped with _EvertyHoverCard')

# ─────────────────────────────────────────────────────────────────────────────
# Write result
# ─────────────────────────────────────────────────────────────────────────────
with open(PATH, 'w', encoding='utf-8') as f:
    f.write(src)

print(f'\n[OK] Hover popup patch applied to {PATH}')
print('  - Hover over any peer card for 600ms -> popup with note and tags')
print('  - Popup disappears when mouse leaves the card')
print('  - Desktop only, no effect on mobile/portrait')
