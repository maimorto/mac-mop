#!/usr/bin/env python3
"""Package a staging folder as a designed, compressed Mac Mop disk image.

Usage: python3 scripts/make-dmg.py <staging-dir> <volume-name> <out.dmg>
           [--background assets/dmg/background.tiff] [--volume-icon Resources/AppIcon.icns]
           [--app "Mac Mop.app"]

The staging dir must already hold the app and the Applications symlink
(scripts/prepare-dmg-staging.sh). This script

  1. adds the hidden background picture and the volume icon,
  2. makes a read-write HFS+ image and mounts it hidden (-nobrowse: Finder
     never shows it, nothing is driven by AppleScript, so there are no
     Automation prompts),
  3. writes the Finder window layout straight into the volume's .DS_Store
     (window size, hidden toolbar/sidebar, icon view at 128 pt, icon
     positions, background picture referenced by an alias + bookmark),
  4. marks the volume as having a custom icon, detaches it and converts it
     to a zlib-compressed read-only UDZO image.

Standard library only. The .DS_Store (Buddy allocator + B-tree) and the
Alias Manager v2 record are written from the publicly documented formats
(Mark Mentovai's and Wim Lewis' notes on the .DS_Store format); no third
party code is included. Exits non-zero on any failure so build-dmg.sh can
fall back to the plain image.
"""
import argparse
import ctypes
import ctypes.util
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time

# Window/icon layout (points). Keep in sync with render-dmg-background.py.
WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (660, 420)
TITLEBAR = 28                       # WindowBounds includes the title bar
ICON_SIZE = 128
TEXT_SIZE = 13
APP_POS = (170, 200)
APPS_POS = (490, 200)
HIDDEN_POS = (1200, 1200)           # hidden files, if the user shows them

HFS_EPOCH = 2082844800              # seconds from 1904-01-01 to 1970-01-01


# ---------------------------------------------------------------- .DS_Store

def _ustr(name):
    data = name.encode("utf-16-be")
    return struct.pack(">I", len(data) // 2) + data


def _record(name, code, kind, value):
    out = _ustr(name) + code.encode("ascii") + kind.encode("ascii")
    if kind == "blob":
        out += struct.pack(">I", len(value)) + value
    elif kind == "long" or kind == "shor":
        out += struct.pack(">I", value)
    elif kind == "bool":
        out += struct.pack(">B", 1 if value else 0)
    elif kind == "type":
        out += value.encode("ascii")
    elif kind == "ustr":
        out += _ustr(value)
    else:
        raise ValueError(kind)
    return out


def ds_store_bytes(records):
    """Serialise [(filename, code, type, value)] as a .DS_Store file.

    One B-tree leaf holds every record (a DMG window needs only a handful).
    Arena (offsets relative to file byte 4, as the format specifies):
        0     header (32)          32    DSDB block (32)
        64..2047 free buddies      2048  allocator info block (2048)
        4096  leaf node (4096)
    """
    # Finder sorts records by case-insensitive filename, then by code.
    records = sorted(records, key=lambda r: (r[0].lower(), r[0], r[1]))
    leaf = struct.pack(">II", 0, len(records)) + b"".join(_record(*r) for r in records)
    if len(leaf) > 4096:
        raise ValueError("DS_Store records do not fit in one 4 KiB node")
    dsdb = struct.pack(">IIIII", 2, 0, len(records), 1, 0x1000)

    def addr(offset, log2):
        return offset | log2

    blocks = [addr(2048, 11), addr(32, 5), addr(4096, 12)]   # 0 info, 1 DSDB, 2 leaf
    info = struct.pack(">II", len(blocks), 0)
    info += b"".join(struct.pack(">I", b) for b in blocks)
    info += b"\0" * 4 * (256 - len(blocks))                  # table padded to 256
    info += struct.pack(">I", 1) + struct.pack(">B", 4) + b"DSDB" + struct.pack(">I", 1)
    free = {6: [64], 7: [128], 8: [256], 9: [512], 10: [1024]}
    for n in range(13, 31):                                   # rest of the 2 GiB arena
        free[n] = [1 << n]
    for n in range(32):
        lst = free.get(n, [])
        info += struct.pack(">I", len(lst)) + b"".join(struct.pack(">I", o) for o in lst)
    assert len(info) <= 2048

    arena = bytearray(8192)
    arena[0:32] = b"Bud1" + struct.pack(">III", 2048, 2048, 2048) + \
        bytes.fromhex("0000100c000000870000200b00000000")
    arena[32:32 + len(dsdb)] = dsdb
    arena[2048:2048 + len(info)] = info
    arena[4096:4096 + len(leaf)] = leaf
    return struct.pack(">I", 1) + bytes(arena)


def ds_store_read(data):
    """Minimal reader used to self-check what we wrote: {(name, code): (type, raw)}."""
    base = 4
    assert data[4:8] == b"Bud1"
    root_off, root_size, _ = struct.unpack(">III", data[8:20])
    p = base + root_off
    count, _ = struct.unpack(">II", data[p:p + 8])
    table = struct.unpack(">%dI" % count, data[p + 8:p + 8 + 4 * count])
    p += 8 + 4 * (((count + 255) // 256) * 256)
    ndirs = struct.unpack(">I", data[p:p + 4])[0]
    p += 4
    dirs = {}
    for _ in range(ndirs):
        n = data[p]
        name = data[p + 1:p + 1 + n].decode()
        dirs[name] = struct.unpack(">I", data[p + 1 + n:p + 5 + n])[0]
        p += 5 + n

    def block(i):
        a = table[i]
        off, size = a & ~0x1F, 1 << (a & 0x1F)
        return data[base + off:base + off + size]

    root, levels, nrec, nnodes, page = struct.unpack(">IIIII", block(dirs["DSDB"])[:20])
    node = block(root)
    p_, cnt = struct.unpack(">II", node[:8])
    assert p_ == 0 and levels == 0 and cnt == nrec
    q = 8
    out = {}
    for _ in range(cnt):
        ln = struct.unpack(">I", node[q:q + 4])[0]
        name = node[q + 4:q + 4 + 2 * ln].decode("utf-16-be")
        q += 4 + 2 * ln
        code = node[q:q + 4].decode()
        kind = node[q + 4:q + 8].decode()
        q += 8
        if kind == "blob":
            ln = struct.unpack(">I", node[q:q + 4])[0]
            val = node[q + 4:q + 4 + ln]
            q += 4 + ln
        elif kind in ("long", "shor", "type"):
            val = node[q:q + 4]
            q += 4
        elif kind == "bool":
            val = node[q:q + 1]
            q += 1
        else:
            raise ValueError(kind)
        out[(name, code)] = (kind, val)
    return out


# ---------------------------------------------------------- Alias (v2) record

def _pascal(s, size):
    b = s.encode("mac_roman", "replace")[:size - 1]
    return bytes([len(b)]) + b + b"\0" * (size - 1 - len(b))


def _tag(tag, data):
    out = struct.pack(">HH", tag, len(data)) + data
    return out + (b"\0" if len(data) % 2 else b"")


def _uni(s):
    data = s.encode("utf-16-be")
    return struct.pack(">H", len(data) // 2) + data


def alias_record(mount, rel_path, volume_name):
    """Alias Manager version 2 record for <mount>/<rel_path> on an HFS+ volume."""
    target = os.path.join(mount, rel_path)
    parent = os.path.dirname(target)
    st, pst, vst = os.stat(target), os.stat(parent), os.stat(mount)
    vol_date = int(vst.st_birthtime) + HFS_EPOCH
    cr_date = int(st.st_birthtime) + HFS_EPOCH
    name = os.path.basename(target)
    parts = rel_path.split("/")
    cnids = []
    walk = mount
    for comp in parts[:-1]:
        walk = os.path.join(walk, comp)
        cnids.append(os.stat(walk).st_ino)
    body = struct.pack(">h28sI2shI64sII4s4shhI2s10s",
                       0,                                   # kind: file
                       _pascal(volume_name, 28), vol_date,
                       b"H+", 5,                            # HFS+, ejectable disk
                       pst.st_ino,                          # parent CNID
                       _pascal(name, 64), st.st_ino, cr_date,
                       b"\0\0\0\0", b"\0\0\0\0",            # creator, type
                       -1, -1,                              # levels from/to
                       0, b"\0\0", b"\0" * 10)
    tags = b""
    tags += _tag(0, os.path.basename(parent).encode("mac_roman", "replace"))
    tags += _tag(1, b"".join(struct.pack(">I", c) for c in reversed(cnids)))
    tags += _tag(2, (volume_name + ":" + ":".join(parts)).encode("mac_roman", "replace"))
    tags += _tag(14, _uni(name))
    tags += _tag(15, _uni(volume_name))
    tags += _tag(16, struct.pack(">Q", vol_date * 65536))
    tags += _tag(17, struct.pack(">Q", cr_date * 65536))
    tags += _tag(18, ("/" + rel_path).encode("utf-8"))
    tags += _tag(19, ("/Volumes/" + volume_name).encode("utf-8"))
    tags += struct.pack(">hH", -1, 0)
    size = 8 + len(body) + len(tags)
    return b"\0\0\0\0" + struct.pack(">HH", size, 2) + body + tags


# ------------------------------------------------- CoreFoundation (bookmarks)

def _cf():
    cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
    vp, sz = ctypes.c_void_p, ctypes.c_long
    cf.CFURLCreateFromFileSystemRepresentation.restype = vp
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [vp, ctypes.c_char_p, sz, ctypes.c_bool]
    cf.CFURLCreateBookmarkData.restype = vp
    cf.CFURLCreateBookmarkData.argtypes = [vp, vp, ctypes.c_ulong, vp, vp, vp]
    cf.CFURLCreateBookmarkDataFromAliasRecord.restype = vp
    cf.CFURLCreateBookmarkDataFromAliasRecord.argtypes = [vp, vp]
    cf.CFURLCreateByResolvingBookmarkData.restype = vp
    cf.CFURLCreateByResolvingBookmarkData.argtypes = [vp, vp, ctypes.c_ulong, vp, vp, vp, vp]
    cf.CFURLGetFileSystemRepresentation.restype = ctypes.c_bool
    cf.CFURLGetFileSystemRepresentation.argtypes = [vp, ctypes.c_bool, ctypes.c_char_p, sz]
    cf.CFDataCreate.restype = vp
    cf.CFDataCreate.argtypes = [vp, ctypes.c_char_p, sz]
    cf.CFDataGetLength.restype = sz
    cf.CFDataGetLength.argtypes = [vp]
    cf.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_char)
    cf.CFDataGetBytePtr.argtypes = [vp]
    cf.CFRelease.argtypes = [vp]
    return cf


def bookmark_for(path):
    cf = _cf()
    raw = path.encode()
    url = cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), False)
    data = cf.CFURLCreateBookmarkData(None, url, 1 << 29, None, None, None)  # no implicit sandbox scope
    cf.CFRelease(url)
    if not data:
        return None
    out = ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data))
    cf.CFRelease(data)
    return out


def resolve_alias(alias):
    """Resolve an alias record through the system (self-check); returns a path."""
    cf = _cf()
    data = cf.CFDataCreate(None, alias, len(alias))
    bmk = cf.CFURLCreateBookmarkDataFromAliasRecord(None, data)
    cf.CFRelease(data)
    if not bmk:
        return None
    stale = ctypes.c_bool(False)
    url = cf.CFURLCreateByResolvingBookmarkData(None, bmk, 1 << 8, None, None, ctypes.byref(stale), None)
    cf.CFRelease(bmk)
    if not url:
        return None
    buf = ctypes.create_string_buffer(4096)
    ok = cf.CFURLGetFileSystemRepresentation(url, True, buf, 4096)
    cf.CFRelease(url)
    return buf.value.decode() if ok else None


# ------------------------------------------------------------------ packaging

def run(*cmd, **kw):
    return subprocess.run(list(cmd), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kw).stdout


def layout_records(app_name, alias, bookmark):
    x, y = WINDOW_ORIGIN
    w, h = WINDOW_SIZE
    bwsp = {
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (x, y, w, h + TITLEBAR),
        "ShowSidebar": False, "ContainerShowSidebar": False, "SidebarWidth": 0,
        "ShowToolbar": False, "ShowTabView": False, "ShowPathbar": False,
        "ShowStatusBar": False, "PreviewPaneVisibility": False,
    }
    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,                        # picture
        "backgroundImageAlias": alias,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "iconSize": float(ICON_SIZE), "textSize": float(TEXT_SIZE),
        "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "arrangeBy": "none", "labelOnBottom": True,
        "showIconPreview": True, "showItemInfo": False,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }

    def iloc(pos):
        return struct.pack(">IIII", pos[0], pos[1], 0xFFFFFFFF, 0xFFFF0000)

    recs = [
        (".", "bwsp", "blob", plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)),
        (".", "icvp", "blob", plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)),
        (".", "vSrn", "long", 1),
        (".", "vstl", "type", "icnv"),
        (app_name, "Iloc", "blob", iloc(APP_POS)),
        ("Applications", "Iloc", "blob", iloc(APPS_POS)),
        (".background", "Iloc", "blob", iloc(HIDDEN_POS)),
        (".VolumeIcon.icns", "Iloc", "blob", iloc((HIDDEN_POS[0] + 140, HIDDEN_POS[1]))),
    ]
    if bookmark:
        recs.append((".", "pBBk", "blob", bookmark))
    return recs


def set_custom_icon_flag(path):
    if shutil.which("SetFile"):
        try:
            run("SetFile", "-a", "C", path)
            return
        except subprocess.CalledProcessError:
            pass
    # FinderInfo: 32 bytes, Finder flags (big endian) at offset 8; kHasCustomIcon = 0x0400.
    info = bytearray(32)
    try:
        cur = run("xattr", "-px", "com.apple.FinderInfo", path).split()
        info[:len(cur)] = bytes(int(b, 16) for b in cur)[:32]
    except subprocess.CalledProcessError:
        pass
    info[8] |= 0x04
    run("xattr", "-wx", "com.apple.FinderInfo", info.hex(), path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("staging")
    ap.add_argument("volname")
    ap.add_argument("out")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--background", default=os.path.join(here, "..", "assets", "dmg", "background.tiff"))
    ap.add_argument("--volume-icon", default=os.path.join(here, "..", "Resources", "AppIcon.icns"))
    ap.add_argument("--app", default=None)
    args = ap.parse_args()

    staging = os.path.abspath(args.staging)
    app_name = args.app or next((n for n in os.listdir(staging) if n.endswith(".app")), None)
    if not app_name or not os.path.isdir(os.path.join(staging, app_name)):
        sys.exit("make-dmg: no .app in staging dir")
    if not os.path.isfile(args.background):
        sys.exit("make-dmg: background missing: %s" % args.background)

    bg_dir = os.path.join(staging, ".background")
    os.makedirs(bg_dir, exist_ok=True)
    shutil.copyfile(args.background, os.path.join(bg_dir, "background.tiff"))
    if os.path.isfile(args.volume_icon):
        shutil.copyfile(args.volume_icon, os.path.join(staging, ".VolumeIcon.icns"))

    work = tempfile.mkdtemp(prefix="macmop-dmg.")
    rw = os.path.join(work, "rw.dmg")
    mount = None
    try:
        kb = int(run("du", "-sk", staging).split()[0])
        size_mb = kb // 1024 + 24                             # payload + room for metadata
        run("hdiutil", "create", "-quiet", "-volname", args.volname, "-fs", "HFS+",
            "-srcfolder", staging,
            "-format", "UDRW", "-size", "%dm" % size_mb, "-ov", rw)
        plist = run("hdiutil", "attach", "-plist", "-readwrite", "-noverify", "-noautoopen",
                    "-nobrowse", "-owners", "off", rw)
        for ent in plistlib.loads(plist.encode())["system-entities"]:
            if ent.get("mount-point"):
                mount = ent["mount-point"]
        if not mount:
            raise RuntimeError("no mount point")

        rel = ".background/background.tiff"
        alias = alias_record(mount, rel, args.volname)
        resolved = resolve_alias(alias)
        if resolved is None or os.path.realpath(resolved) != os.path.realpath(os.path.join(mount, rel)):
            print("make-dmg: warning: alias self-check resolved to %r" % resolved, file=sys.stderr)
        bookmark = bookmark_for(os.path.join(mount, rel))
        recs = layout_records(app_name, alias, bookmark)
        try:
            data = ds_store_bytes(recs)
        except ValueError:
            data = ds_store_bytes([r for r in recs if r[1] != "pBBk"])
        check = ds_store_read(data)
        assert (app_name, "Iloc") in check and (".", "icvp") in check
        ds_path = os.path.join(mount, ".DS_Store")
        if os.path.exists(ds_path):
            os.remove(ds_path)
        with open(ds_path, "wb") as f:
            f.write(data)

        if os.path.isfile(os.path.join(mount, ".VolumeIcon.icns")):
            set_custom_icon_flag(mount)
        # Nothing else on the volume should be visible besides the app and the link.
        for junk in (".fseventsd", ".Trashes"):
            shutil.rmtree(os.path.join(mount, junk), ignore_errors=True)
        run("sync")
        for attempt in range(5):
            try:
                run("hdiutil", "detach", "-quiet", mount)
                mount = None
                break
            except subprocess.CalledProcessError:
                time.sleep(1 + attempt)
        if mount:
            run("hdiutil", "detach", "-quiet", "-force", mount)
            mount = None
        out = os.path.abspath(args.out)
        if os.path.exists(out):
            os.remove(out)
        run("hdiutil", "convert", "-quiet", rw, "-format", "UDZO", "-imagekey", "zlib-level=9", "-o", out)
    finally:
        if mount:
            subprocess.run(["hdiutil", "detach", "-quiet", "-force", mount])
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(bg_dir, ignore_errors=True)
        try:
            os.remove(os.path.join(staging, ".VolumeIcon.icns"))
        except OSError:
            pass
    print(args.out)


if __name__ == "__main__":
    main()
