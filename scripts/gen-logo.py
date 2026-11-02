#!/usr/bin/env python3
"""Regenerate the empty-session mark in TUIWidgetsChatPanel.pas from
docs/design/logo.txt.

The art lives in a plain ASCII PIXEL GRID so it can be EDITED AS A PICTURE:

    .   blank
    #   ink, muted   (the circle around the h - the frame)
    W   ink, bright  (the word "hildi")

Everything is monospace ASCII, so the picture lines up in any editor. An earlier
version stored braille glyphs beside a mask of ASCII dots; those render at
different widths in a text editor, so the two pictures could never be visually
compared - which is why the alignment kept drifting and the editor could not be
used at all.

Each terminal braille cell is a 2x4 block of pixels, so this script DOWNSAMPLES:
one 2x4 block becomes one braille character, and a cell counts as part of the
word when any of its pixels is 'W'.

    make logo          # or: python3 scripts/gen-logo.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_FILE = ROOT / 'docs/design/logo.txt'
PAS = ROOT / 'src/tui/widgets/TUIWidgetsChatPanel.pas'

# Braille dot bit -> (dx, dy) inside the 2x4 cell.
DOT_BIT = {(0, 0): 0x01, (0, 1): 0x02, (0, 2): 0x04, (0, 3): 0x40,
           (1, 0): 0x08, (1, 1): 0x10, (1, 2): 0x20, (1, 3): 0x80}


def read_grid(path):
    lines = path.read_text(encoding='utf-8').split('\n')
    rows, seen_marker = [], False
    for raw in lines:
        s = raw.rstrip()
        if not seen_marker:
            if s == '---':
                seen_marker = True
            continue
        if s == '':
            continue
        rows.append(s)
    if not rows:
        sys.exit('logo.txt: no picture found below the --- line')
    return rows


def main():
    rows = read_grid(SRC_FILE)

    widths = {len(r) for r in rows}
    if len(widths) != 1:
        bad = [(i, len(r)) for i, r in enumerate(rows)]
        sys.exit('logo.txt: rows are not all the same width: ' + str(bad))
    W = widths.pop()
    if W % 2:
        sys.exit(f'logo.txt: picture is {W} characters wide; a braille cell is '
                 '2 pixels, so the width must be even.')
    if len(rows) % 4:
        sys.exit(f'logo.txt: picture is {len(rows)} rows tall; a braille cell is '
                 '4 pixels, so the height must be a multiple of 4.')

    for i, r in enumerate(rows):
        bad = set(r) - {'.', '#', 'W'}
        if bad:
            sys.exit(f'logo.txt: row {i} has unexpected characters {sorted(bad)}; '
                     "only '.', '#' and 'W' are allowed.")

    art, mask = [], []
    for cr in range(len(rows) // 4):
        line, mline = [], []
        for cc in range(W // 2):
            bits = 0
            word = False
            for dy in range(4):
                for dx in range(2):
                    px = rows[cr * 4 + dy][cc * 2 + dx]
                    if px in ('#', 'W'):
                        bits |= DOT_BIT[(dx, dy)]
                    if px == 'W':
                        word = True
            line.append(chr(0x2800 + bits))
            # '.' for a cell with no ink at all, so the Pascal source stays
            # readable and a diff between art edits stays minimal.
            mline.append('.' if bits == 0 else ('1' if word else '0'))
        art.append(''.join(line))
        mask.append(''.join(mline))

    src = PAS.read_text(encoding='utf-8')

    def splice(text, anchor, values):
        i = text.index(anchor)
        j = text.index(');', i) + 2
        n = len(values) - 1
        head = anchor[:anchor.index('array[0..')] + \
            f'array[0..{n}] of UnicodeString = (\n'
        body = ',\n'.join("    '%s'" % v for v in values)
        return text[:i] + head + body + ');' + text[j:]

    src = splice(src, '  EmptyLogo: array[0..', art)
    src = splice(src, '  EmptyLogoWordMask: array[0..', mask)
    PAS.write_text(src, encoding='utf-8')
    print(f'logo: {W}x{len(rows)} px -> {len(art)} cells x {len(art[0])} '
          f'from docs/design/logo.txt')


if __name__ == '__main__':
    main()
