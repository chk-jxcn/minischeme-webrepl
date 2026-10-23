#!/usr/bin/env python3
"""Generates MFNT dot-matrix fonts and installs them on the board.

The same engine serves the WebREPL font generator (minischeme-webrepl server.py,
/api/font/*), so a font made here and one made in the browser are identical.

    # list installed faces / character presets
    python tools/make_font.py --list-faces
    python tools/make_font.py --list-presets

    # write a file
    python tools/make_font.py --face simsun --size 16 --preset gb2312 -o simsun-16.mfnt
    python tools/make_font.py --face simhei --size 24 --preset ascii,digits,datetime --chars "温度湿度" -o x.mfnt
    python tools/make_font.py --face kaiti --size 20 --from app.scm --preview kaiti.png --sample "你好，世界"

    # generate and install: system font ROM (default) or /spiffs/fonts/
    python tools/make_font.py --face simsun --size 16 --preset gb2312 --device 192.168.1.100
    python tools/make_font.py --face simhei --size 24 --from app.scm --device COM42 --to spiffs

--face is an alias (simsun, msyh, simhei, kaiti, fangsong, dengxian), a font
file name in the system font folder, a family name from --list-faces, or a
path. ASCII 32..126 is always included. Characters the face does not contain
are left out (the device draws them with its built-in font) and reported.
The font is named <face>-<size> unless --name is given; apps use it with
(use-font id "<face>" <size>).

--bpp 2 or 4 stores coverage (anti-aliased edges) instead of one bit per
pixel.

MFNT version 2 layout (little-endian):
    0  "MFNT", u16 version 2, u8 height, u8 max bytes per row,
    8  u32 glyph count, u32 bitmap offset, char name[16]
    32 u8 bits per pixel, u8 ascent (baseline row), u8 descent, u8 flags,
       u32 identity hash, 8 reserved bytes
    48 index sorted by code point: u16 cp, u8 advance, u8 bytes per row
       (0: no such glyph), u32 bitmap offset (relative); then rows, MSB =
       leftmost pixel
"""
import argparse
import functools
import json
import os
import re
import struct
import sys
import zlib

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHARSETS_PATH = os.path.join(ROOT, 'data', 'font_charsets.json')
if not os.path.exists(CHARSETS_PATH):
    CHARSETS_PATH = os.path.join(ROOT, 'font_charsets.json')
if not os.path.exists(CHARSETS_PATH):
    CHARSETS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'font_charsets.json')
ASCII = ''.join(chr(i) for i in range(32, 127))
FACES = {
    'simsun': 'simsun.ttc', 'msyh': 'msyh.ttc', 'yahei': 'msyh.ttc', 'simhei': 'simhei.ttf',
    'kaiti': 'simkai.ttf', 'fangsong': 'simfang.ttf', 'dengxian': 'Deng.ttf',
}
FONT_DIRS = [
    os.path.join(os.environ.get('WINDIR', 'C:/Windows'), 'Fonts'),
    os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Microsoft', 'Windows', 'Fonts'),
    '/usr/share/fonts', '/usr/local/share/fonts', os.path.expanduser('~/.fonts'),
    '/Library/Fonts', '/System/Library/Fonts', os.path.expanduser('~/Library/Fonts'),
]
FONT_EXTS = ('.ttf', '.ttc', '.otf', '.otc')
STRING_RE = re.compile(r'"((?:\\.|[^"\\])*)"')
MAX_BPR = 16
MIN_SIZE, MAX_SIZE = 6, 128


class FontError(Exception):
    pass


# ---------------------------------------------------------------------------
# Character sets
# ---------------------------------------------------------------------------

def load_charsets():
    """Presets from font_charsets.json: [{id, label, chars}] with
    composite presets ("parts") resolved."""
    with open(CHARSETS_PATH, encoding='utf-8') as f:
        data = json.load(f)
    by_id = {p['id']: p for p in data['presets']}
    out = []
    for p in data['presets']:
        chars = p.get('chars', '')
        if 'parts' in p:
            chars = ''.join(by_id[q]['chars'] for q in p['parts'])
        out.append({'id': p['id'], 'label': p['label'], 'chars': chars})
    return out


def preset_chars(ids):
    presets = {p['id']: p for p in load_charsets()}
    chars = set()
    for pid in ids:
        if pid not in presets:
            raise FontError(f'unknown preset {pid!r} (see --list-presets)')
        chars.update(presets[pid]['chars'])
    return chars


def string_chars(paths):
    """Characters of the string literals in source files."""
    chars = set()
    for p in paths:
        with open(p, encoding='utf-8') as f:
            for m in STRING_RE.finditer(f.read()):
                chars.update(m.group(1))
    return chars


def gb2312_chars():
    return preset_chars(['gb2312'])


def _gb2312_rows(first, last):
    out = []
    for hi in range(first, last + 1):
        for lo in range(0xA1, 0xFF):
            try:
                out.append(bytes([hi, lo]).decode('gb2312'))
            except UnicodeDecodeError:
                pass
    return ''.join(out)


def write_charsets():
    """Regenerates font_charsets.json (developer use)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from compile_font_to_fasl import COMMON_CHARS
    uniq = lambda s: ''.join(sorted(set(s), key=ord))  # noqa: E731
    presets = [
        {'id': 'ascii', 'label': 'ASCII 可打印字符', 'chars': ASCII},
        {'id': 'digits', 'label': '数字与常用符号', 'chars': uniq('0123456789+-×÷=.,:;%‰°℃℉/()[]#*~ ')},
        {'id': 'datetime', 'label': '日期时间', 'chars': uniq(
            '0123456789:-/ 年月日时分秒点刻星期周一二三四五六七八九十日天今明昨前后上下午早晚凌晨中'
            '农历正冬腊闰初廿卅春夏秋冬立雨水惊蛰清明谷小满芒种暑处白露寒霜降雪大至')},
        {'id': 'punct', 'label': '中文标点', 'chars': uniq('，。、；：？！…—～·“”‘’（）《》〈〉【】「」『』〔〕［］｛｝￥％＋－＝')},
        {'id': 'system', 'label': '内置 16px 字体的字符集', 'chars': uniq(COMMON_CHARS)},
        {'id': 'gb2312-symbols', 'label': 'GB2312 符号', 'chars': _gb2312_rows(0xA1, 0xA9)},
        {'id': 'gb2312-1', 'label': 'GB2312 一级汉字 (常用)', 'chars': _gb2312_rows(0xB0, 0xD7)},
        {'id': 'gb2312-2', 'label': 'GB2312 二级汉字', 'chars': _gb2312_rows(0xD8, 0xF7)},
        {'id': 'gb2312', 'label': 'GB2312 全部 (符号 + 一级 + 二级)', 'parts': ['gb2312-symbols', 'gb2312-1', 'gb2312-2']},
    ]
    with open(CHARSETS_PATH, 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'version': 1, 'presets': presets}, f, ensure_ascii=False, indent=1)
        f.write('\n')
    return CHARSETS_PATH


# ---------------------------------------------------------------------------
# Faces
# ---------------------------------------------------------------------------

def _font_files():
    seen = set()
    for d in FONT_DIRS:
        if not d or not os.path.isdir(d):
            continue
        for dirpath, _, files in os.walk(d):
            for fn in files:
                if fn.lower().endswith(FONT_EXTS) and fn.lower() not in seen:
                    seen.add(fn.lower())
                    yield os.path.join(dirpath, fn)


def _open_tt(path):
    from fontTools.ttLib import TTFont
    return TTFont(path, fontNumber=0, lazy=True)


def face_cmap(path):
    """Code points the face maps to glyphs; None when they cannot be read."""
    try:
        tt = _open_tt(path)
        cmap = tt['cmap'].getBestCmap() or {}
        tt.close()
        return set(cmap)
    except Exception:
        return None


def _family_names(tt):
    en = zh = None
    for rec in tt['name'].names:
        if rec.nameID not in (1, 16):
            continue
        try:
            text = rec.toUnicode()
        except Exception:
            continue
        if rec.platformID == 3 and rec.langID == 0x804:
            zh = zh or text
        elif rec.platformID == 3 and rec.langID == 0x409:
            en = en or text
        elif rec.platformID == 1 and not en:
            en = text
    return en, zh


_faces_cache = None


def list_faces():
    """Installed faces: [{id, family, family_zh, file, path, cjk}], CJK first.
    Scanned once per process (a few seconds on a full Windows font folder)."""
    global _faces_cache
    if _faces_cache is None:
        _faces_cache = _scan_faces()
    return _faces_cache


def _scan_faces():
    out = []
    for path in _font_files():
        try:
            tt = _open_tt(path)
            en, zh = _family_names(tt)
            cmap = tt['cmap'].getBestCmap() or {}
            tt.close()
        except Exception:
            continue
        stem = os.path.splitext(os.path.basename(path))[0]
        alias = next((a for a, fn in FACES.items() if fn.lower() == os.path.basename(path).lower()), None)
        out.append({
            'id': alias or stem.lower(),
            'family': en or stem,
            'family_zh': zh or '',
            'file': os.path.basename(path),
            'path': path,
            'cjk': 0x4E2D in cmap,
            'glyphs': len(cmap),
        })
    out.sort(key=lambda f: (not f['cjk'], f['family'].lower()))
    return out


def face_path(face):
    """A path, an alias, a file name in a font folder, or a family name."""
    if os.path.isfile(face):
        return face
    name = FACES.get(face.lower(), face)
    for d in FONT_DIRS:
        if d and os.path.isfile(os.path.join(d, name)):
            return os.path.join(d, name)
    for f in list_faces():
        if face.lower() in (f['id'], f['family'].lower(), f['family_zh'].lower(), f['file'].lower()):
            return f['path']
    raise FontError(f'font face not found: {face} (see --list-faces)')


def face_id(face):
    """Short name used in font names: the alias or the file name stem."""
    path = face_path(face)
    for alias, fn in FACES.items():
        if os.path.basename(path).lower() == fn.lower() and alias != 'yahei':
            return alias
    return os.path.splitext(os.path.basename(path))[0].lower()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def auto_offset(font, height, chars=()):
    """Vertical offset that puts the glyphs' ink in the cell: the ink of all
    of chars, centered, when it fits; else that of 98 % of them (the 1 % that
    reach highest and lowest may lose a row), the tops kept first.
    Centering the face's ascent + descent instead cut the top row off most
    16 px SimSun / SimHei characters (ascent 14 + descent 3 > 16 although
    their ink fills rows 0..15); it is only the fallback without ink."""
    tops, bottoms = [], []
    for ch in chars:
        bb = font.getbbox(ch)
        if bb and bb[3] > bb[1]:
            tops.append(bb[1])
            bottoms.append(bb[3])
    if not tops:
        ascent, descent = font.getmetrics()
        return (height - (ascent + descent)) // 2
    tops.sort()
    bottoms.sort()
    top, bottom = tops[0], bottoms[-1]
    if bottom - top > height:
        k = len(tops) // 100
        top, bottom = tops[k], bottoms[-1 - k]
    if bottom - top > height:
        return -top
    return -top + (height - (bottom - top)) // 2


SPACINGS = ('font', 'cell')


def _pack_rows(img, width, height, bpp):
    """Rows of an L (coverage) or 1 image, bpp bits per pixel, MSB first."""
    bpr = (width * bpp + 7) // 8
    px = img.load()
    levels = (1 << bpp) - 1
    rows = bytearray(bpr * height)
    for y in range(height):
        for x in range(width):
            v = px[x, y]
            if bpp == 1:
                v = 1 if v else 0
            else:
                v = (v * levels + 127) // 255
            if v:
                bit = x * bpp
                rows[y * bpr + bit // 8] |= v << (8 - bpp - bit % 8)
    return bpr, bytes(rows)


def render_glyph(font, ch, height, y_offset, spacing='font', bpp=1):
    """(advance, bytes per row, rows) of one character; rows hold bpp bits
    per pixel (1: on/off, 2 or 4: coverage).
    spacing font: the face's own advance widths (proportional faces such as
    Microsoft YaHei keep their spacing; SimSun, SimHei and KaiTi give 8 / 16 px
    at 16 px either way); cell: at least half a cell for ASCII and a full cell
    otherwise, like the built-in fonts."""
    bbox = font.getbbox(ch)
    cell = height // 2 if ord(ch) < 128 else height
    own = max(1, int(font.getlength(ch) + 0.5))
    if not bbox or bbox[2] <= bbox[0]:
        advance = own if spacing == 'font' else cell
        advance = min(advance, MAX_BPR * 8)
        bpr = (advance * bpp + 7) // 8
        return advance, bpr, bytes(bpr * height)
    advance = own if spacing == 'font' else max(bbox[2] - bbox[0], cell)
    advance = min(advance, MAX_BPR * 8)
    width = min(max(advance, bbox[2]), MAX_BPR * 8)
    if bpp == 1:
        img = Image.new('1', ((width + 7) // 8 * 8, height), 0)
        ImageDraw.Draw(img).text((0, y_offset), ch, font=font, fill=1)
    else:
        img = Image.new('L', (width, height), 0)
        ImageDraw.Draw(img).text((0, y_offset), ch, font=font, fill=255)
    bpr, rows = _pack_rows(img, width if bpp > 1 else (width + 7) // 8 * 8, height, bpp)
    return advance, bpr, rows


@functools.lru_cache(maxsize=32)
def _pil_font(path, size):
    return ImageFont.truetype(path, size)


def font_hash(path, *parts):
    """Identity of a generated font: the face file and the settings."""
    try:
        st = os.stat(path)
        ident = f'{os.path.basename(path).lower()}:{st.st_size}'
    except OSError:
        ident = os.path.basename(path).lower()
    return zlib.crc32(':'.join([ident] + [str(p) for p in parts]).encode('utf-8')) & 0xFFFFFFFF


def _mfnt(name, size, bpp, ascent, descent, fhash, entries):
    """MFNT version 2 bytes; entries: [(cp, advance, bpr, rows or None)]."""
    index, bitmaps, seen, max_bpr = [], bytearray(), {}, 1
    for cp, advance, bpr, rows in sorted(entries):
        if rows is None:  # the face has no such glyph: marked absent
            index.append(struct.pack('<HBBI', cp, 0, 0, 0))
            continue
        off = seen.get(rows)
        if off is None:  # identical bitmaps (blank glyphs) are stored once
            off = seen[rows] = len(bitmaps)
            bitmaps += rows
        index.append(struct.pack('<HBBI', cp, advance, bpr, off))
        max_bpr = max(max_bpr, bpr)
    head = b'MFNT' + struct.pack('<HBBII', 2, size, max_bpr, len(index), 48 + 8 * len(index))
    head += name.encode('utf-8')[:16].ljust(16, b'\0')
    head += struct.pack('<BBBBI', bpp, max(0, min(255, ascent)), max(0, min(255, descent)), 0, fhash) + bytes(8)
    return head + b''.join(index) + bytes(bitmaps)


def build_font(face, size, chars, name=None, y_offset=None, spacing='font', bpp=1):
    """MFNT bytes plus {name, height, glyphs, bytes, missing} for chars
    (ASCII added) of face at size pixels."""
    if spacing not in SPACINGS:
        raise FontError('spacing must be font or cell')
    if bpp not in (1, 2, 4):
        raise FontError('bpp must be 1, 2 or 4')
    if not MIN_SIZE <= int(size) <= MAX_SIZE:
        raise FontError(f'size must be {MIN_SIZE}..{MAX_SIZE}')
    size = int(size)
    path = face_path(face)
    font = _pil_font(path, size)
    wanted = {ord(c) for c in set(chars) | set(ASCII) if 32 <= ord(c) <= 0xFFFF and c not in '\r\n\t'}
    cmap = face_cmap(path)
    missing = sorted(cp for cp in wanted if cmap is not None and cp not in cmap and cp != 32)
    cps = sorted(wanted - set(missing))
    if y_offset is None:
        y_offset = auto_offset(font, size, [chr(cp) for cp in cps])
    entries = [(cp, *render_glyph(font, chr(cp), size, y_offset, spacing, bpp)) for cp in cps]
    if not name:
        name = f'{face_id(face)}-{size}'
    ascent, descent = font.getmetrics()
    data = _mfnt(name, size, bpp, y_offset + ascent, descent, font_hash(path, size, bpp, spacing), entries)
    info = {'name': name, 'height': size, 'glyphs': len(entries), 'bytes': len(data),
            'missing': ''.join(chr(cp) for cp in missing), 'y_offset': y_offset, 'face': path, 'bpp': bpp}
    return data, info


def build_mfnt(face, size, chars, name=None, y_offset=None, spacing='font', bpp=1):
    """MFNT bytes for chars (ASCII is added) of face at size pixels."""
    return build_font(face, size, chars, name, y_offset, spacing, bpp)[0]


def mfnt_bpp(data):
    return data[32] if struct.unpack_from('<H', data, 4)[0] == 2 else 1


def decode_mfnt(data):
    """(height, {cp: (advance, bpr, rows)}) of an MFNT font (absent glyphs left out)."""
    if data[:4] != b'MFNT':
        raise FontError('not an MFNT font')
    version = struct.unpack_from('<H', data, 4)[0]
    index_off = 48 if version == 2 else 32
    height, count, boff = data[6], struct.unpack_from('<I', data, 8)[0], struct.unpack_from('<I', data, 12)[0]
    glyphs = {}
    for i in range(count):
        cp, adv, bpr, off = struct.unpack_from('<HBBI', data, index_off + 8 * i)
        if bpr:
            glyphs[cp] = (adv, bpr, data[boff + off:boff + off + bpr * height])
    return height, glyphs


def render_preview(data, text, scale=2, fg=(255, 255, 255), bg=(0, 0, 0), width=320):
    """Image of text drawn with the font as the device would (missing: red box)."""
    height, glyphs = decode_mfnt(data)
    bpp = mfnt_bpp(data)
    lines, line, x = [], [], 0
    for ch in text:
        g = glyphs.get(ord(ch))
        adv = g[0] if g else height
        if ch == '\n' or x + adv > width:
            lines.append(line)
            line, x = [], 0
            if ch == '\n':
                continue
        line.append((x, ch, g))
        x += adv
    lines.append(line)
    img = Image.new('RGB', (width, max(1, len(lines)) * (height + 2)), bg)
    px = img.load()
    for ln, items in enumerate(lines):
        top = ln * (height + 2)
        for x0, ch, g in items:
            if not g:
                for k in range(1, height - 1):
                    for (xx, yy) in ((x0 + 1, top + k), (x0 + height - 2, top + k), (x0 + k, top + 1), (x0 + k, top + height - 2)):
                        if xx < width:
                            px[xx, yy] = (200, 60, 60)
                continue
            adv, bpr, rows = g
            levels = (1 << bpp) - 1
            for y in range(height):
                for xb in range(bpr * 8 // bpp):
                    bit = xb * bpp
                    v = (rows[y * bpr + bit // 8] >> (8 - bpp - bit % 8)) & levels
                    if v and x0 + xb < width:
                        px[x0 + xb, top + y] = tuple((f * v + b * (levels - v)) // levels for f, b in zip(fg, bg))
    return img.resize((img.width * scale, img.height * scale), Image.NEAREST)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def collect_chars(presets=(), chars='', sources=()):
    out = set(chars or '')
    if presets:
        out |= preset_chars(presets)
    if sources:
        out |= string_chars(sources)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog='\n'.join(__doc__.split('\n')[3:21]))
    ap.add_argument('--face', help='alias, font file, family name or path')
    ap.add_argument('--size', type=int, help=f'cell height in pixels ({MIN_SIZE}..{MAX_SIZE})')
    ap.add_argument('--preset', action='append', default=[], help='character presets, comma separated (see --list-presets)')
    ap.add_argument('--chars', default='', help='characters to include')
    ap.add_argument('--chars-file', help='include every character of this text file')
    ap.add_argument('--from', dest='sources', nargs='*', default=[], help='include the string literals of these files')
    ap.add_argument('--gb2312', action='store_true', help='same as --preset gb2312')
    ap.add_argument('--y-offset', type=int, default=None, help='vertical offset (default: centered)')
    ap.add_argument('--bpp', type=int, choices=(1, 2, 4), default=1,
                    help='bits per pixel: 1 (default), 2 or 4 (anti-aliased)')
    ap.add_argument('--spacing', choices=SPACINGS, default='font',
                    help="font: the face's advance widths (default); cell: ASCII at least half a cell, like the built-in fonts")
    ap.add_argument('--name', default=None, help='font name (default <face>-<size>)')
    ap.add_argument('-o', '--output', help='write the .mfnt file')
    ap.add_argument('--preview', help='write a PNG preview')
    ap.add_argument('--sample', default=None, help='preview text (default: the characters)')
    ap.add_argument('--device', help='install on the board: IP/host for HTTP, or a serial port (COM42, /dev/ttyUSB0)')
    ap.add_argument('--to', choices=['fontrom', 'spiffs'], default='fontrom',
                    help='fontrom: system font ROM (default); spiffs: /spiffs/fonts/<name>.mfnt')
    ap.add_argument('--list-faces', action='store_true')
    ap.add_argument('--list-presets', action='store_true')
    ap.add_argument('--write-charsets', action='store_true', help=argparse.SUPPRESS)
    a = ap.parse_args()
    for stream in (sys.stdout, sys.stderr):  # Chinese on non-UTF-8 consoles
        try:
            stream.reconfigure(errors='replace')
        except AttributeError:
            pass

    try:
        if a.write_charsets:
            print(write_charsets())
            return
        if a.list_presets:
            for p in load_charsets():
                print(f'  {p["id"]:<16} {len(set(p["chars"])):>5}  {p["label"]}')
            return
        if a.list_faces:
            for f in list_faces():
                zh = f' / {f["family_zh"]}' if f['family_zh'] else ''
                print(f'  {f["id"]:<20} {"CJK" if f["cjk"] else "   "} {f["glyphs"]:>6}  {f["family"]}{zh}  ({f["file"]})')
            return
        if not a.face or not a.size:
            ap.error('--face and --size are required')
        if not (a.output or a.device or a.preview):
            ap.error('nothing to do: give -o, --preview and/or --device')
        presets = [p.strip() for spec in a.preset for p in spec.split(',') if p.strip()]
        if a.gb2312:
            presets.append('gb2312')
        chars = a.chars
        if a.chars_file:
            with open(a.chars_file, encoding='utf-8') as f:
                chars += f.read()
        data, info = build_font(a.face, a.size, collect_chars(presets, chars, a.sources), a.name, a.y_offset,
                                a.spacing, a.bpp)
    except (FontError, OSError) as e:
        sys.exit(f'make_font: {e}')

    print(f'{info["name"]}: {info["glyphs"]} glyphs, {info["bytes"]} bytes, {info["height"]} px '
          f'({os.path.basename(info["face"])})')
    if info['missing']:
        shown = info['missing'][:60] + ('…' if len(info['missing']) > 60 else '')
        print(f'  {len(info["missing"])} characters are not in this face (drawn with the built-in font): {shown}')
    if a.output:
        os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
        with open(a.output, 'wb') as f:
            f.write(data)
        print(f'  wrote {a.output}')
    if a.preview:
        sample = a.sample if a.sample is not None else ''.join(sorted(collect_chars(presets, chars, a.sources), key=ord))[:400]
        render_preview(data, sample).save(a.preview)
        print(f'  preview {a.preview}')
    if a.device:
        import device_client
        try:
            dev = device_client.open_device(a.device)
            where = device_client.install_font(dev, data, info['name'], a.to, progress=_progress)
            print(f'\n  installed on {a.device}: {where}')
            print(f'  use it with {usage(info["name"])}')
        except device_client.DeviceError as e:
            sys.exit(f'\nmake_font: {e}')


def usage(name, font_id=2):
    m = re.match(r'^(.+)-(\d+)$', name)
    return f'(use-font {font_id} "{m.group(1)}" {m.group(2)})' if m else f'(use-font {font_id} "{name}")'


def _progress(done, total, what):
    print(f'\r  {what} {done * 100 // max(total, 1):3d}%', end='', flush=True)


if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
