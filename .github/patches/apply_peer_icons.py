#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
"""
Everty patch: OS platform icon improvements.
Targets RustDesk 1.4.6 (flutter/lib/common.dart).

Fix: when peer.platform is empty (manually added peer that hasn't
connected yet), show a generic computer icon instead of an invisible
empty Container.
"""

PATH = './flutter/lib/common.dart'

try:
    with open(PATH, 'r', encoding='utf-8') as f:
        src = f.read()
except FileNotFoundError:
    print(f'ERROR: {PATH} not found', file=sys.stderr)
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# Replace empty Container fallback with a visible generic icon
# ─────────────────────────────────────────────────────────────────────────────
OLD_GET_PLATFORM = '''Widget getPlatformImage(String platform, {double size = 50}) {
  if (platform.isEmpty) {
    return Container(width: size, height: size);
  }'''

NEW_GET_PLATFORM = '''Widget getPlatformImage(String platform, {double size = 50}) {
  if (platform.isEmpty) {
    // Everty: generic computer icon for peers with unknown platform
    // (e.g. manually added to address book, never connected yet).
    return SizedBox(
      width: size,
      height: size,
      child: Icon(
        Icons.computer_outlined,
        size: size * 0.75,
        color: Colors.grey.shade400,
      ),
    );
  }'''

if OLD_GET_PLATFORM not in src:
    print('ERROR: getPlatformImage not found in common.dart', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_GET_PLATFORM, NEW_GET_PLATFORM, 1)
print('  [OK] getPlatformImage: empty platform now shows generic computer icon')

with open(PATH, 'w', encoding='utf-8') as f:
    f.write(src)

print(f'\n[OK] Peer icons patch applied to {PATH}')
print('  - Peers without platform info show a grey computer icon')
print('  - Windows/Linux/macOS/Android peers unchanged')
