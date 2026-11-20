#!/usr/bin/env python3
"""Generate synthetic content without opening a device or personal data."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
parser.add_argument('--mib', type=int, default=4, choices=range(1, 129))
args = parser.parse_args()
root = args.destination
# No replacement of an existing fixture or user folder.
root.mkdir(parents=True, exist_ok=False)
(root / '.database').mkdir()
with sqlite3.connect(root / '.database/HvNote.db') as db:
    db.execute('CREATE TABLE NoteList(name TEXT,nameUser TEXT,noteType INTEGER,hasPsd INTEGER)')
    db.execute('INSERT INTO NoteList VALUES(?,?,?,?)', ('synthetic-note-001', '合成测试笔记', 1, 0))
note = root / 'synthetic-note-001'
(note / 'empty').mkdir(parents=True)
(note / 'page.psl').write_bytes(b'NPSL0001\nSynthetic fixture only; not a valid native page.\n')
with (note / 'resource.bin').open('xb') as out:
    for number in range(args.mib): out.write(bytes([number % 251]) * 1024 * 1024)
manifest = {}
for file in sorted(root.rglob('*')):
    if file.is_file(): manifest[file.relative_to(root).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
(root / 'synthetic-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('Synthetic fixture generated. No device was accessed.')
