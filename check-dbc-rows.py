"""Check whether a DBC set contains the rows the CoA DBC guard requires.

Usage: python3 check-dbc-rows.py <dbc-dir>

The id offset per table is taken from the core's DBCfmt.h, e.g. CurrencyTypes
uses "xnxi" (first field skipped) while the others start with "n".
"""
import struct
import sys
from pathlib import Path

# (file, required id, id byte offset inside the record, label)
REQUIRED = [
    ("CurrencyTypes.dbc", 375250, 4, "Rune of Ascension"),
    ("CreatureDisplayInfo.dbc", 236827, 0, "Blood Parasite"),
    ("GameObjectDisplayInfo.dbc", 87226, 0, "Worldforged pickup"),
    ("ItemLimitCategory.dbc", 2414, 0, ""),
    ("Map.dbc", 3690, 0, "Brawler\x27s Guild"),
]
HEADER = struct.Struct("<4s4I")


def ids(path, offset):
    data = path.read_bytes()
    _, rows, fields, record_size, _ = HEADER.unpack_from(data)
    found = [struct.unpack_from("<I", data, HEADER.size + i * record_size + offset)[0]
             for i in range(rows)]
    return found, rows, fields, record_size


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    missing = 0
    for name, wanted, offset, label in REQUIRED:
        path = directory / name
        if not path.is_file():
            print(f"{name:26} MISSING FILE")
            missing += 1
            continue
        found, rows, fields, record_size = ids(path, offset)
        ok = wanted in found
        missing += 0 if ok else 1
        print(f"{name:26} {("OK" if ok else "MISSING"):7} id {wanted:>8} at offset {offset}  "
              f"({rows} rows, {fields} fields, {record_size} B/record, max id {max(found)})")
    print(f"\n{len(REQUIRED) - missing}/{len(REQUIRED)} required rows present")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())