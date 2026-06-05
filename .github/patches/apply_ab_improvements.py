#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
# Force UTF-8 stdout/stderr — Windows runners default to cp1252.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
"""
Everty patch: address book peer card improvements.
Targets RustDesk 1.4.6 (flutter/lib/common/widgets/peer_card.dart).

Changes:
  1. Always show peer note on card when note is non-empty
     (original: hidden in non-legacy/AB mode via peerTabShowNote gate)
  2. Add "Copy ID" item to AddressBookPeerCard context menu

Usage: python3 apply_ab_improvements.py
"""
import sys

PATH = './flutter/lib/common/widgets/peer_card.dart'

try:
    with open(PATH, 'r', encoding='utf-8') as f:
        src = f.read()
except FileNotFoundError:
    print(f'ERROR: {PATH} not found — wrong directory?', file=sys.stderr)
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# 1. Fix _showNote: always show when peer has a note
#
# Original code gates note visibility on peerTabShowNote(widget.tab).
# In RustDesk 1.4.6 that function returns false for the address book tab
# in certain configurations, so notes are never shown even when set.
# Fix: remove the gate — show the note if peer.note is non-empty, always.
# ─────────────────────────────────────────────────────────────────────────────
OLD_SHOW_NOTE = '''  bool _showNote(Peer peer) {
    return peerTabShowNote(widget.tab) && peer.note.isNotEmpty;
  }'''

NEW_SHOW_NOTE = '''  bool _showNote(Peer peer) {
    // Everty: show note for every tab when the peer has one.
    // Original peerTabShowNote() gate hid notes in non-legacy AB mode.
    return peer.note.isNotEmpty;
  }'''

if OLD_SHOW_NOTE not in src:
    print('WARNING: _showNote() not found — source may have changed', file=sys.stderr)
else:
    src = src.replace(OLD_SHOW_NOTE, NEW_SHOW_NOTE, 1)
    print('  [OK] _showNote() always returns true when note is non-empty')

# ─────────────────────────────────────────────────────────────────────────────
# 2. Add "Copy ID" to AddressBookPeerCard context menu
#
# Inserted as the second item (after Connect, before Transfer File).
# Uses Clipboard (flutter/services.dart) + BotToast — both already imported.
# ─────────────────────────────────────────────────────────────────────────────
OLD_AB_MENU_START = '''class AddressBookPeerCard extends BasePeerCard {
  AddressBookPeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.ab,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      _transferFileAction(context),'''

NEW_AB_MENU_START = '''class AddressBookPeerCard extends BasePeerCard {
  AddressBookPeerCard({required Peer peer, EdgeInsets? menuPadding, Key? key})
      : super(
            peer: peer,
            tab: PeerTabIndex.ab,
            menuPadding: menuPadding,
            key: key);

  @override
  Future<List<MenuEntryBase<String>>> _buildMenuItems(
      BuildContext context) async {
    final List<MenuEntryBase<String>> menuItems = [
      _connectAction(context),
      // Everty: copy peer ID to clipboard
      MenuEntryButton<String>(
        childBuilder: (TextStyle? style) =>
            Text(translate('Copy ID'), style: style),
        proc: () {
          Clipboard.setData(ClipboardData(text: peer.id));
          BotToast.showText(
            text: '${translate("Copied")}: ${peer.id}',
            contentColor: Colors.green.shade700,
            duration: const Duration(seconds: 2),
          );
        },
        dismissOnClicked: true,
      ),
      _transferFileAction(context),'''

if OLD_AB_MENU_START not in src:
    print('WARNING: AddressBookPeerCard._buildMenuItems not found — source may have changed',
          file=sys.stderr)
else:
    src = src.replace(OLD_AB_MENU_START, NEW_AB_MENU_START, 1)
    print('  [OK] "Copy ID" added to AddressBookPeerCard context menu')

# ─────────────────────────────────────────────────────────────────────────────
# Write result
# ─────────────────────────────────────────────────────────────────────────────
with open(PATH, 'w', encoding='utf-8') as f:
    f.write(src)

print(f'\n[OK] AB improvements patch applied to {PATH}')
print('  - Peer notes now always visible on card when non-empty')
print('  - Right-click any AB peer -> "Copy ID" copies ID to clipboard')
