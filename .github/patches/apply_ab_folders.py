#!/usr/bin/env python3
"""
Everty patch: folder/group tree view for address book.
Targets RustDesk 1.4.6 (flutter/lib/common/widgets/address_book.dart).

Tags named "Folder/Leaf" are rendered as expandable folder nodes.
Flat tags ("Linux", "Windows") stay as chips at root level.
Clicking the folder filter icon selects/deselects all tags in that folder.

Usage: python3 apply_ab_folders.py
"""
import sys

PATH = './flutter/lib/common/widgets/address_book.dart'

try:
    with open(PATH, 'r', encoding='utf-8') as f:
        src = f.read()
except FileNotFoundError:
    print(f'ERROR: {PATH} not found — wrong directory?', file=sys.stderr)
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# 1. Replace _buildTags() with folder-aware tree renderer
# ─────────────────────────────────────────────────────────────────────────────
OLD_BUILD_TAGS = '''  Widget _buildTags() {
    return Obx(() {
      List tags;
      if (gFFI.abModel.sortTags.value) {
        tags = gFFI.abModel.currentAbTags.toList();
        tags.sort();
      } else {
        tags = gFFI.abModel.currentAbTags.toList();
      }
      tags = [kUntagged, ...tags].toList();
      final editPermission = gFFI.abModel.current.canWrite();
      tagBuilder(String e) {
        return AddressBookTag(
            name: e,
            tags: gFFI.abModel.selectedTags,
            onTap: () {
              if (gFFI.abModel.selectedTags.contains(e)) {
                gFFI.abModel.selectedTags.remove(e);
              } else {
                gFFI.abModel.selectedTags.add(e);
              }
            },
            showActionMenu: editPermission);
      }

      gridView(bool isPortrait) => DynamicGridView.builder(
          shrinkWrap: isPortrait,
          gridDelegate: SliverGridDelegateWithWrapping(),
          itemCount: tags.length,
          itemBuilder: (BuildContext context, int index) {
            final e = tags[index];
            return tagBuilder(e);
          });
      final maxHeight = max(MediaQuery.of(context).size.height / 6, 100.0);
      return Obx(() => stateGlobal.isPortrait.isFalse
          ? gridView(false)
          : LimitedBox(maxHeight: maxHeight, child: gridView(true)));
    });
  }'''

NEW_BUILD_TAGS = '''  // Everty: folder-aware tag tree. Tags named "Folder/Leaf" are grouped
  // under a collapsible folder header. Flat tags stay as root-level chips.
  Widget _buildTags() {
    return Obx(() {
      final rawTags = gFFI.abModel.sortTags.value
          ? (gFFI.abModel.currentAbTags.toList()..sort())
          : gFFI.abModel.currentAbTags.toList();
      final editPermission = gFFI.abModel.current.canWrite();
      final selected = gFFI.abModel.selectedTags;

      // Separate flat tags and folder-grouped tags by first '/' separator.
      final flatTags = <String>[];
      final folderMap = <String, List<String>>{};
      for (final t in rawTags) {
        final slash = t.indexOf('/');
        if (slash <= 0) {
          flatTags.add(t);
        } else {
          folderMap.putIfAbsent(t.substring(0, slash), () => []).add(t);
        }
      }

      // Leaf chip: shows only the last path component as label,
      // but the full tag name is used for selection/filtering.
      Widget leafChip(String fullTag) {
        final display = fullTag.contains('/')
            ? fullTag.substring(fullTag.lastIndexOf('/') + 1)
            : fullTag;
        return AddressBookTag(
          name: fullTag,
          displayName: display,
          tags: selected,
          onTap: () {
            if (selected.contains(fullTag)) {
              selected.remove(fullTag);
            } else {
              selected.add(fullTag);
            }
          },
          showActionMenu: editPermission,
        );
      }

      final widgets = <Widget>[
        leafChip(kUntagged),
        ...flatTags.map(leafChip),
        ...folderMap.entries.map((e) => _AbFolderTile(
              folder: e.key,
              children: e.value,
              selected: selected,
              leafBuilder: leafChip,
            )),
      ];

      final listView = ListView(
        shrinkWrap: true,
        physics: const ClampingScrollPhysics(),
        children: widgets,
      );
      final maxHeight = max(MediaQuery.of(context).size.height / 6, 100.0);
      return Obx(() => stateGlobal.isPortrait.isFalse
          ? listView
          : LimitedBox(maxHeight: maxHeight, child: listView));
    });
  }'''

if OLD_BUILD_TAGS not in src:
    print('ERROR: _buildTags() not found — source may have changed from 1.4.6', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_BUILD_TAGS, NEW_BUILD_TAGS, 1)
print('  ✓ _buildTags() replaced with folder-aware version')

# ─────────────────────────────────────────────────────────────────────────────
# 2. Add optional displayName field + ctor param to AddressBookTag
# ─────────────────────────────────────────────────────────────────────────────
OLD_TAG_CLASS_HEAD = '''class AddressBookTag extends StatelessWidget {
  final String name;
  final RxList<dynamic> tags;
  final Function()? onTap;
  final bool showActionMenu;

  const AddressBookTag(
      {Key? key,
      required this.name,
      required this.tags,
      this.onTap,
      this.showActionMenu = true})
      : super(key: key);'''

NEW_TAG_CLASS_HEAD = '''class AddressBookTag extends StatelessWidget {
  final String name;
  // Everty: optional short label shown in UI (leaf part of "Folder/Leaf" tags).
  // Falls back to [name] when null.
  final String? displayName;
  final RxList<dynamic> tags;
  final Function()? onTap;
  final bool showActionMenu;

  const AddressBookTag(
      {Key? key,
      required this.name,
      this.displayName,
      required this.tags,
      this.onTap,
      this.showActionMenu = true})
      : super(key: key);'''

if OLD_TAG_CLASS_HEAD not in src:
    print('ERROR: AddressBookTag class header not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_TAG_CLASS_HEAD, NEW_TAG_CLASS_HEAD, 1)
print('  ✓ AddressBookTag.displayName field added')

# ─────────────────────────────────────────────────────────────────────────────
# 3. Use displayName in the Text widget inside AddressBookTag.build()
# ─────────────────────────────────────────────────────────────────────────────
OLD_TAG_TEXT = '''                  Expanded(
                    child: Text(isUnTagged ? translate(name) : name,
                        style: TextStyle(
                            overflow: TextOverflow.ellipsis,
                            color: tags.contains(name) ? Colors.white : null)),
                  ),'''

NEW_TAG_TEXT = '''                  Expanded(
                    child: Text(isUnTagged ? translate(name) : (displayName ?? name),
                        style: TextStyle(
                            overflow: TextOverflow.ellipsis,
                            color: tags.contains(name) ? Colors.white : null)),
                  ),'''

if OLD_TAG_TEXT not in src:
    print('ERROR: AddressBookTag Text widget not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_TAG_TEXT, NEW_TAG_TEXT, 1)
print('  ✓ AddressBookTag Text uses displayName')

# ─────────────────────────────────────────────────────────────────────────────
# 4. Insert _AbFolderTile class just before AddressBookTag
# ─────────────────────────────────────────────────────────────────────────────
FOLDER_TILE = r'''
// ─── Everty: Expandable folder tile ──────────────────────────────────────────
// Renders a collapsible folder header + its leaf tag chips.
// The folder header shows:
//   • folder icon (open/closed)
//   • folder name (bold when any child is selected)
//   • filter icon to select/deselect all children at once
class _AbFolderTile extends StatefulWidget {
  final String folder;
  final List<String> children;
  final RxList<dynamic> selected;
  final Widget Function(String) leafBuilder;

  const _AbFolderTile({
    Key? key,
    required this.folder,
    required this.children,
    required this.selected,
    required this.leafBuilder,
  }) : super(key: key);

  @override
  State<_AbFolderTile> createState() => _AbFolderTileState();
}

class _AbFolderTileState extends State<_AbFolderTile> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    // Folder header — reactive to selection state via Obx,
    // expand/collapse managed by local setState.
    final header = InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Obx(() {
        final anySelected =
            widget.children.any((t) => widget.selected.contains(t));
        final allSelected =
            widget.children.every((t) => widget.selected.contains(t));
        final activeColor = Theme.of(context).colorScheme.primary;
        final dimColor = Theme.of(context).disabledColor;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 3.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _expanded ? Icons.folder_open : Icons.folder,
                size: 14,
                color: anySelected ? activeColor : dimColor,
              ),
              const SizedBox(width: 4),
              Text(
                widget.folder,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      anySelected ? FontWeight.w600 : FontWeight.normal,
                  color: anySelected ? activeColor : null,
                ),
              ),
              const SizedBox(width: 4),
              // Filter button: toggles selection of all children at once.
              GestureDetector(
                onTap: () {
                  if (allSelected) {
                    for (final t in widget.children) {
                      widget.selected.remove(t);
                    }
                  } else {
                    for (final t in widget.children) {
                      if (!widget.selected.contains(t)) {
                        widget.selected.add(t);
                      }
                    }
                  }
                },
                child: Tooltip(
                  message: allSelected
                      ? 'Снять выбор папки'
                      : 'Выбрать всю папку',
                  waitDuration: Duration.zero,
                  child: Icon(
                    anySelected ? Icons.filter_alt : Icons.filter_alt_outlined,
                    size: 13,
                    color: anySelected ? activeColor : dimColor,
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12.0),
            child: Wrap(
              children: widget.children.map(widget.leafBuilder).toList(),
            ),
          ),
      ],
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────

'''

INSERT_BEFORE = 'class AddressBookTag extends StatelessWidget {'
if INSERT_BEFORE not in src:
    print('ERROR: class AddressBookTag not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(INSERT_BEFORE, FOLDER_TILE + INSERT_BEFORE, 1)
print('  ✓ _AbFolderTile class inserted')

# ─────────────────────────────────────────────────────────────────────────────
# 5. Fix: show "Sort tags" menu item in non-legacy mode too
#
# Original code hides sortMenuItem() behind `if (gFFI.abModel.legacyMode.value)`.
# EvertyDesk uses non-legacy mode (multiple address books), so the option was
# never visible — the tag list never sorted even if the user expected it to.
# Fix: show it always.
# ─────────────────────────────────────────────────────────────────────────────
OLD_SORT_GUARD = '      getEntry(translate("Unselect all tags"), gFFI.abModel.unsetSelectedTags),\n      if (gFFI.abModel.legacyMode.value)\n        sortMenuItem(), // It\'s already sorted after pulling down\n      if (canWrite) syncMenuItem(),'

NEW_SORT_GUARD = '      getEntry(translate("Unselect all tags"), gFFI.abModel.unsetSelectedTags),\n      sortMenuItem(), // Everty: always show (was hidden in non-legacy mode)\n      if (canWrite) syncMenuItem(),'

if OLD_SORT_GUARD not in src:
    print('WARNING: sortMenuItem guard not found — may already be fixed or source changed', file=sys.stderr)
else:
    src = src.replace(OLD_SORT_GUARD, NEW_SORT_GUARD, 1)
    print('  ✓ Sort tags menu item always visible (legacyMode guard removed)')

# ─────────────────────────────────────────────────────────────────────────────
# 6. Add live search bar above peers list
#
# peerSearchText / peerSearchTextController are globals from peers_view.dart
# (already imported). The existing matchPeer() filtering already reacts to
# peerSearchText.value — we just need the TextField in the UI.
# ─────────────────────────────────────────────────────────────────────────────
OLD_PEERS_VIEW = '''  Widget _buildPeersViews() {
    return Expanded(
      child: Align(
          alignment: Alignment.topLeft,
          child: AddressBookPeersView(
            menuPadding: widget.menuPadding,
          )),
    );
  }'''

NEW_PEERS_VIEW = '''  // Everty: live search bar + address book peers view
  Widget _buildPeersViews() {
    return Expanded(
      child: Column(
        children: [
          Obx(() => TextField(
                controller: peerSearchTextController,
                onChanged: (v) => peerSearchText.value = v,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: peerSearchText.value.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 14),
                          padding: EdgeInsets.zero,
                          splashRadius: 14,
                          onPressed: () {
                            peerSearchTextController.clear();
                            peerSearchText.value = \'\';
                          },
                        )
                      : null,
                  hintText: translate(\'Search\'),
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 8, horizontal: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              )).marginOnly(bottom: 6.0),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: AddressBookPeersView(
                menuPadding: widget.menuPadding,
              ),
            ),
          ),
        ],
      ),
    );
  }'''

if OLD_PEERS_VIEW not in src:
    print('WARNING: _buildPeersViews() not found — may have changed', file=sys.stderr)
else:
    src = src.replace(OLD_PEERS_VIEW, NEW_PEERS_VIEW, 1)
    print('  ✓ Search bar added above peers list')

# ─────────────────────────────────────────────────────────────────────────────
# Write result
# ─────────────────────────────────────────────────────────────────────────────
with open(PATH, 'w', encoding='utf-8') as f:
    f.write(src)

print(f'\n✓ AB folders patch applied to {PATH}')
print('  Usage: create tags like "Серверы/Prod", "Серверы/Dev" → grouped under "Серверы" folder.')
print('  Sort tags: right-click "..." in tag header → "Sort tags" (now always visible).')
