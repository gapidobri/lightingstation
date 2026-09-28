import 'dart:typed_data';

import 'packet.dart';

/// One cell of a MagicQ Execute page.
class ExecuteItem {
  const ExecuteItem({
    required this.index,
    this.flags = 0,
    this.borders = 0,
    this.extra = 0,
    this.state = 0,
    this.iconId = 0,
    this.level = 0,
    this.text = '',
    this.name = '',
    this.tag = '',
  });

  const ExecuteItem.empty(this.index)
    : flags = 0,
      borders = 0,
      extra = 0,
      state = 0,
      iconId = 0,
      level = 0,
      text = '',
      name = '',
      tag = '';

  final int index;
  final int flags;

  /// Region edges (bits 0..3) and fader-span bits.
  final int borders;

  /// Bit 7: active (colour mode). Bits 24..27: height - 1, bits 28..31:
  /// width - 1 (the item's size in grid cells; MagicQ copies the top byte
  /// of its own item flags here, `FUN_100368630`).
  final int extra;

  /// 1 = active, 2 = inactive; in colour mode, `0x80000000 | rgb`.
  final int state;
  final int iconId;

  /// Fader level 0..255 (for fader items and some value items).
  final int level;
  final String text;
  final String name;

  /// Item type tag in colour mode ("PB", "FL", "CS", "G", ...), or a
  /// bitmap file name when [iconId] is `0xfd000000`.
  final String tag;

  bool get exists => flags & 0x0001 != 0;
  bool get isFader => flags & 0x0010 != 0;
  bool get isFlash => flags & 0x0008 != 0;

  /// Fader occupies the cell below as well. MagicQ only sets this for a
  /// fader without an explicit size, when the cell below is empty.
  bool get isTallFader => borders & 0x0080 != 0;

  /// Size in grid cells, as set with the Execute window's width and height
  /// soft buttons (`FUN_10036b920`). 1x1 for most items.
  int get width => (extra >> 28 & 0xf) + 1;
  int get height => isTallFader && extra >> 24 & 0xf == 0 ? 2 : (extra >> 24 & 0xf) + 1;

  /// Empty cell that is the lower half of the fader above it.
  bool get isFaderContinuation => borders & 0x0200 != 0;

  /// Region (item group) outline: the item is in a region and the cell on
  /// that side is not in the same one (`FUN_100368630`, from the binary
  /// only). MagicQ checks the item's own cell's neighbours, so a sized
  /// item's edges follow its top-left cell.
  bool get regionTop => borders & 0x0001 != 0;
  bool get regionBottom => borders & 0x0002 != 0;
  bool get regionLeft => borders & 0x0004 != 0;
  bool get regionRight => borders & 0x0008 != 0;
  bool get hasRegionEdge => borders & 0x000f != 0;

  bool get hasColour => state & 0x80000000 != 0;

  /// 0xRRGGBB, or null when MagicQ did not report a colour.
  int? get rgb => hasColour ? state & 0xffffff : null;

  bool get active => hasColour ? extra & 0x80 != 0 : state == 1;

  ExecuteItem copyWith({int? level, int? extra, int? state}) => ExecuteItem(
    index: index,
    flags: flags,
    borders: borders,
    extra: extra ?? this.extra,
    state: state ?? this.state,
    iconId: iconId,
    level: level ?? this.level,
    text: text,
    name: name,
    tag: tag,
  );
}

/// A full Execute page, assembled from one or more reply datagrams.
class ExecutePage {
  ExecutePage({
    required this.page,
    required this.name,
    required this.columns,
    required this.rows,
    required this.flags,
    required this.items,
  });

  final int page;
  final String name;
  final int columns;
  final int rows;
  final int flags;
  final List<ExecuteItem> items;

  ExecuteItem itemAt(int row, int column) => items[row * columns + column];

  /// The items to draw, each with the cells it covers, in index order.
  ///
  /// A sized item (or a tall fader) covers the cells to its right and below,
  /// clipped to the grid; items in cells it covers are left out, as are
  /// the lower halves of tall faders. How MagicQ reports the covered cells
  /// is not confirmed live, so any item there is dropped.
  List<ExecuteCell> get layout {
    final covered = List.filled(columns * rows, false);
    final cells = <ExecuteCell>[];
    for (final item in items) {
      if (item.index >= covered.length || covered[item.index] || item.isFaderContinuation) continue;
      final row = item.index ~/ columns;
      final column = item.index % columns;
      final width = item.width.clamp(1, columns - column);
      final height = item.height.clamp(1, rows - row);
      for (var r = row; r < row + height; r++) {
        for (var c = column; c < column + width; c++) {
          covered[r * columns + c] = true;
        }
      }
      cells.add(ExecuteCell(item, row: row, column: column, width: width, height: height));
    }
    return cells;
  }
}

/// Where an [ExecuteItem] sits in its page's grid, in cells.
class ExecuteCell {
  const ExecuteCell(this.item, {required this.row, required this.column, this.width = 1, this.height = 1});

  final ExecuteItem item;
  final int row;
  final int column;
  final int width;
  final int height;
}

/// Header fields present in every `0x8003` datagram.
class ExecutePageChunk {
  ExecutePageChunk({
    required this.flags,
    required this.page,
    required this.columns,
    required this.rows,
    required this.name,
    required this.startIndex,
    required this.items,
  });

  final int flags;
  final int page;
  final int columns;
  final int rows;
  final String name;
  final int startIndex;
  final List<ExecuteItem> items;

  int get itemCount => columns * rows;

  /// Parses an extended-format (protocol v2.12+) Execute page reply.
  ///
  /// ```
  /// 0x00 u32 page flags      0x04 u16 page      0x06 u16 columns
  /// 0x08 u16 rows            0x0a char[16] name 0x1a u16 first item index
  /// 0x1c items...
  /// item: u16 flags, u16 borders, u32 extra, u32 state, u32 icon,
  ///       u16 level, cstring text, cstring name, cstring tag
  /// ```
  /// MagicQ pads short replies with stale buffer bytes, so parsing stops
  /// at the page's item count rather than at the end of the payload.
  static ExecutePageChunk parse(Uint8List payload) {
    final r = PayloadReader(payload);
    final flags = r.u32();
    final page = r.u16();
    final columns = r.u16();
    final rows = r.u16();
    final name = r.fixedString(16);
    final start = r.remaining >= 2 ? r.u16() : 0;
    final total = columns * rows;
    final items = <ExecuteItem>[];
    var index = start;
    while (index < total && r.remaining >= 0x15) {
      items.add(
        ExecuteItem(
          index: index,
          flags: r.u16(),
          borders: r.u16(),
          extra: r.u32(),
          state: r.u32(),
          iconId: r.u32(),
          level: r.u16(),
          text: r.cString(),
          name: r.cString(),
          tag: r.cString(),
        ),
      );
      index++;
    }
    return ExecutePageChunk(
      flags: flags,
      page: page,
      columns: columns,
      rows: rows,
      name: name,
      startIndex: start,
      items: items,
    );
  }
}

/// Merges [ExecutePageChunk]s into complete [ExecutePage]s.
class ExecutePageAssembler {
  int? _page;
  List<ExecuteItem>? _items;
  ExecutePageChunk? _header;

  /// Returns a page once all of its items have arrived.
  ExecutePage? add(ExecutePageChunk chunk) {
    final total = chunk.itemCount;
    if (_page != chunk.page || _items?.length != total || _header?.columns != chunk.columns) {
      _page = chunk.page;
      _items = List.generate(total, ExecuteItem.empty);
      _received.clear();
    }
    _header = chunk;
    for (final item in chunk.items) {
      _items![item.index] = item;
      _received.add(item.index);
    }
    if (_received.length < total) return null;
    _received.clear();
    return ExecutePage(
      page: chunk.page,
      name: chunk.name,
      columns: chunk.columns,
      rows: chunk.rows,
      flags: chunk.flags,
      items: List.unmodifiable(_items!.map((item) => _withGroupColour(chunk.page, item))),
    );
  }

  final Set<int> _received = {};

  /// Inactive colour last seen per (page, item).
  final Map<(int, int), int> _dimColours = {};

  /// MagicQ drops the colour of a group item that shares an item group
  /// with others (flags bit 15 clear): active, it sends plain state 1;
  /// inactive, its dimmed colour (`FUN_100365930`, confirmed live). Give
  /// an active one its full colour back, from the dimmed colour seen
  /// before or MagicQ's default group colour.
  ExecuteItem _withGroupColour(int page, ExecuteItem item) {
    if (!item.exists || item.flags & 0x8000 != 0) return item;
    final key = (page, item.index);
    if (item.hasColour) {
      _dimColours[key] = item.rgb!;
      return item;
    }
    if (item.state != 1) return item;
    final dim = _dimColours[key];
    return item.copyWith(
      extra: item.extra | 0x80,
      state: 0x80000000 | (dim == null ? _defaultGroupColour : _undim(dim)),
    );
  }

  /// MagicQ's default Execute colour for a group item.
  static const _defaultGroupColour = 0xbb0030;

  /// Inverts MagicQ's inactive dimming (each channel times 0.51).
  static int _undim(int rgb) {
    var out = 0;
    for (final shift in const [16, 8, 0]) {
      out |= ((rgb >> shift & 0xff) / 0.51).round().clamp(0, 255) << shift;
    }
    return out;
  }
}
