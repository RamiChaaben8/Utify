"""
Patch downloads_screen.dart and downloads_view.dart:
- Wrap both ListTile widgets with Material(color: transparent)
- Add tileColor: Colors.transparent to each ListTile
"""
import sys

# ---- mobile downloads_screen.dart ----
mobile_path = r'C:\Users\ramic\StudioProjects\testf\lib\screens\downloads_screen.dart'
with open(mobile_path, 'r', encoding='utf-8') as f:
    src = f.read()

# Find _DownloadedSongTile class, then find the 'return ListTile(' block and wrap it
marker = '_DownloadedSongTile extends StatelessWidget'
cls_start = src.find(marker)
if cls_start < 0:
    print('ERROR: _DownloadedSongTile not found', file=sys.stderr)
    sys.exit(1)

# Find 'return ListTile(' within this class
lt_marker = '    return ListTile(\n'
lt_pos = src.find(lt_marker, cls_start)
if lt_pos < 0:
    print('ERROR: return ListTile( not found in _DownloadedSongTile', file=sys.stderr)
    sys.exit(1)

# We need to find the end of this ListTile. Count braces from lt_pos.
# The ListTile ends at '    );' which is 4-space indent followed by );
# More reliable: find '    );\n  }\n}' after the ListTile start
end_seq = '    );\n  }\n}'
end_pos = src.find(end_seq, lt_pos)
if end_pos < 0:
    print('ERROR: end of _DownloadedSongTile build method not found', file=sys.stderr)
    sys.exit(1)
end_pos_full = end_pos + len(end_seq)

old_block = src[lt_pos:end_pos_full]

# Build the wrapped version by re-indenting the ListTile content
# Take everything between 'return ListTile(\n' and the matching ');'
# The content is already at 6-space indent; ListTile props are at 6 spaces.
# We keep the existing ListTile body unchanged and just wrap it.
# Extract the ListTile content (everything inside the outer ListTile parens)
# Actually simplest: add Material wrapper around the whole return statement

new_block = (
    '    // Material + tileColor:transparent ensures the InkWell ripple is\n'
    '    // visible regardless of any opaque ancestor widget above this tile.\n'
    '    return Material(\n'
    '      color: Colors.transparent,\n'
    '      child: ListTile(\n'
    '        tileColor: Colors.transparent,\n'
)

# Now take everything between 'return ListTile(\n' and end_pos (which is '    );')
# and re-indent it by 2 more spaces
inner = src[lt_pos + len(lt_marker):end_pos]
# inner currently has 6-space indent for props; add 2 more spaces
reindented = '\n'.join('  ' + line if line.strip() else line
                       for line in inner.split('\n'))

new_block += reindented
new_block += '      ),\n    );\n  }\n}'

new_src = src[:lt_pos] + new_block + src[end_pos_full:]

with open(mobile_path, 'w', encoding='utf-8') as f:
    f.write(new_src)
print('mobile downloads_screen.dart: _DownloadedSongTile wrapped with Material')

# ---- desktop downloads_view.dart ----
desktop_path = r'C:\Users\ramic\StudioProjects\testf\lib\desktop\views\downloads_view.dart'
with open(desktop_path, 'r', encoding='utf-8') as f:
    dsrc = f.read()

def wrap_tile_class(src, class_name):
    """Wrap the 'return ListTile(' in a class with Material + tileColor."""
    marker = f'{class_name} extends StatelessWidget'
    cls_start = src.find(marker)
    if cls_start < 0:
        print(f'ERROR: {class_name} not found', file=sys.stderr)
        return src, False

    lt_marker = '    return ListTile(\n'
    lt_pos = src.find(lt_marker, cls_start)
    if lt_pos < 0:
        print(f'ERROR: return ListTile( not found in {class_name}', file=sys.stderr)
        return src, False

    end_seq = '    );\n  }\n}'
    end_pos = src.find(end_seq, lt_pos)
    if end_pos < 0:
        print(f'ERROR: end of {class_name} build not found', file=sys.stderr)
        return src, False
    end_pos_full = end_pos + len(end_seq)

    inner = src[lt_pos + len(lt_marker):end_pos]
    reindented = '\n'.join('  ' + line if line.strip() else line
                           for line in inner.split('\n'))

    new_block = (
        '    // Material + tileColor:transparent ensures ink splash is visible.\n'
        '    return Material(\n'
        '      color: Colors.transparent,\n'
        '      child: ListTile(\n'
        '        tileColor: Colors.transparent,\n'
        + reindented +
        '      ),\n    );\n  }\n}'
    )

    new_src = src[:lt_pos] + new_block + src[end_pos_full:]
    return new_src, True

dsrc, ok1 = wrap_tile_class(dsrc, '_DesktopActiveTile')
if ok1:
    print('desktop downloads_view.dart: _DesktopActiveTile wrapped')
dsrc, ok2 = wrap_tile_class(dsrc, '_DesktopDoneTile')
if ok2:
    print('desktop downloads_view.dart: _DesktopDoneTile wrapped')

with open(desktop_path, 'w', encoding='utf-8') as f:
    f.write(dsrc)
print('desktop downloads_view.dart written')
