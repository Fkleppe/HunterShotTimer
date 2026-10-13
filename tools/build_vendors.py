"""Build VendorData.lua: every NPC that sells arrows or bullets, with faction and map spots.

Sources (not shipped with the addon, only the generated table is):
  - pfQuest db (MIT, Shagu): items "V" (vendor NPC ids), units (coords, faction), enUS names
  - cMaNGOS classic-db: item_template (arrows 6/2, bullets 6/3), npc_vendor and
    npc_vendor_template (who sells them, cross-check only)
  - Wowhead Classic "Sold by" lists (tools/wowhead_sold.json): who sells them
Usage: python -I tools/build_vendors.py <pfquest dir> <chestatlas tools/sources dir>
"""
import gzip, json, re, sys
from pathlib import Path
from lupa.lua51 import LuaRuntime

pfq, src = Path(sys.argv[1]), Path(sys.argv[2])
out = Path(__file__).resolve().parents[1] / "VendorData.lua"

# --- From the cMaNGOS MySQL dump: ammo items, and which NPCs sell them (directly or
# through a vendor template).
WANT = {"item_template", "npc_vendor", "npc_vendor_template", "creature_template"}

def tuples(s):
    i, n = 0, len(s)
    while i < n:
        if s[i] != "(": i += 1; continue
        i += 1; vals, cur, q = [], "", False
        while i < n:
            c = s[i]
            if q:
                if c == "\\": cur += s[i + 1]; i += 2; continue
                if c == "'": q = False
                else: cur += c
            elif c == "'": q = True
            elif c == ",": vals.append(cur); cur = ""
            elif c == ")": vals.append(cur); i += 1; break
            else: cur += c
            i += 1
        yield vals

cols, tables, current = {}, {t: [] for t in WANT}, None
with gzip.open(src / "cmangos-classic.sql.gz", "rt", encoding="utf-8", errors="replace") as f:
    for line in f:
        m = re.match(r"CREATE TABLE `(\w+)`", line)
        if m:
            current = m.group(1) if m.group(1) in WANT else None
            if current: cols[current] = []
            continue
        if current and line.startswith("  `"):
            cols[current].append(re.match(r"\s+`(\w+)`", line).group(1)); continue
        m = re.match(r"INSERT INTO `(\w+)`", line)
        if m and m.group(1) in WANT:
            body = line[line.index("VALUES") + 6:].strip().rstrip(";")
            for v in tuples(body): tables[m.group(1)].append(dict(zip(cols[m.group(1)], v)))

items = {}
for r in tables["item_template"]:
    if r["class"] == "6" and r["subclass"] in ("2", "3"):
        items[int(r["entry"])] = dict(name=r["name"], kind="arrow" if r["subclass"] == "2" else "bullet",
                                      req=int(r["RequiredLevel"]), ilvl=int(r["ItemLevel"]))
templates, cmVendors = {}, {}
for r in tables["npc_vendor_template"]:
    if int(r["item"]) in items: templates.setdefault(int(r["entry"]), set()).add(int(r["item"]))
for r in tables["npc_vendor"]:
    if int(r["item"]) in items: cmVendors.setdefault(int(r["entry"]), set()).add(int(r["item"]))
for r in tables["creature_template"]:
    t = int(r["VendorTemplateId"] or 0)
    if t in templates: cmVendors.setdefault(int(r["Entry"]), set()).update(templates[t])

L = LuaRuntime()
env = L.eval("function(s,e) local f=assert(loadstring(s)); setfenv(f,e); f() end")
E = L.eval("{pfDB={items={},units={},zones={}}}")
env((src / "db_items.lua").read_text(encoding="utf-8"), E)
env((pfq / "db_units.lua").read_text(encoding="utf-8"), E)
env((pfq / "db_enUS_units.lua").read_text(encoding="utf-8"), E)
env((src / "db_enUS_zones.lua").read_text(encoding="utf-8"), E)
zoneNames = E.pfDB["zones"]["enUS"]
data, units, names = E.pfDB["items"]["data"], E.pfDB["units"]["data"], E.pfDB["units"]["enUS"]

# Who sells what, three ways: pfQuest, cMaNGOS, and Wowhead's "Sold by" lists (what players
# have seen in the live Classic client, tools/wowhead_sold.json from tools/wowhead_sold.py).
# Wowhead is the answer; the emulator databases each add a few vendors or items that the
# live game does not have (Mazk Snipeshot and Burkrum sell no ammo at all).
pfVendors = {}
for item in items:
    d = data[item]
    if not d or not d["V"]: continue
    for npc in d["V"].keys():
        pfVendors.setdefault(int(npc), set()).add(item)
wowhead = json.loads((Path(__file__).parent / "wowhead_sold.json").read_text(encoding="utf-8"))
vendors = {}
for item, d in wowhead.items():
    for npc in d["npcs"]:
        vendors.setdefault(int(npc), set()).add(int(item))
# Season of Discovery additions on Wowhead's Classic pages; not in Classic itself.
SEASONAL = {207743: "Netali Proudwind", 240654: "Fizzlefuse"}
for npc in SEASONAL: vendors.pop(npc, None)
for label, other in (("pfQuest", pfVendors), ("cMaNGOS", cmVendors)):
    extra = {n: sorted(other[n] - vendors.get(n, set())) for n in other if other[n] - vendors.get(n, set())}
    missing = sorted(set(vendors) - set(other))
    print(f"{label}: not on Wowhead {extra}  |  missing {missing}")

# Zone (AreaTable) -> Classic uiMapID
UIMAP = {14: 1411, 215: 1412, 17: 1413, 36: 1416, 45: 1417, 3: 1418, 4: 1419, 85: 1420, 130: 1421,
         28: 1422, 139: 1423, 267: 1424, 47: 1425, 1: 1426, 51: 1427, 46: 1428, 12: 1429, 41: 1430,
         10: 1431, 38: 1432, 44: 1433, 33: 1434, 8: 1435, 40: 1436, 11: 1437, 141: 1438, 148: 1439,
         331: 1440, 400: 1441, 406: 1442, 405: 1443, 357: 1444, 15: 1445, 440: 1446, 16: 1447,
         361: 1448, 490: 1449, 493: 1450, 1377: 1451, 618: 1452, 1519: 1453, 1637: 1454, 1537: 1455,
         1638: 1456, 1657: 1457, 1497: 1458, 2597: 1459}
# No faction in pfQuest = friendly through reputation only (goblin towns, Argent Dawn,
# Cenarion Circle...): neutral for both sides.
FAC = {"A": "A", "H": "H", "AH": "N", None: "N"}
# Vendors that only trade once you have reputation with them.
NOTES = {11555: "Needs Timbermaw Hold reputation"}
spots, skipped = [], {"nofac": 0, "nomap": 0, "nocoord": 0}
for npc, sold in sorted(vendors.items()):
    u = units[npc]
    name = names[npc]
    if not u or not name or str(name).startswith("["): continue
    fac = FAC.get(u["fac"], "?")
    if fac == "?": skipped["nofac"] += 1; continue
    coords = [tuple(c.values()) for c in u["coords"].values()] if u["coords"] else []
    if not coords: skipped["nocoord"] += 1; print("no spot:", npc, name); continue
    for c in coords:
        x, y, zone = float(c[0]), float(c[1]), int(c[2])
        if zone not in UIMAP: skipped["nomap"] += 1; print("no map:", npc, name, zone); continue
        spots.append((UIMAP[zone], x, y, npc, name, fac, sorted(sold)))

# pfQuest lists some city vendors on both the city map and the zone around it. The zone map
# already shows city vendors (as small pins inside the city), so keep only the city spot.
CITY_PARENT = {1453: 1429, 1454: 1411, 1455: 1426, 1456: 1412, 1457: 1438, 1458: 1420}
inCity = {(s[3], CITY_PARENT[s[0]]) for s in spots if s[0] in CITY_PARENT}
dropped = [s for s in spots if (s[3], s[0]) in inCity]
spots = [s for s in spots if (s[3], s[0]) not in inCity]
print("city vendors also listed on the zone, dropped there:", sorted({s[4] for s in dropped}))

used = sorted({i for s in spots for i in s[6]})
def lua_str(s): return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'
lines = ["-- Generated by tools/build_vendors.py. Do not edit by hand.",
         "-- Data: pfQuest database (MIT, (c) Shagu) and cMaNGOS classic-db (GPL); see Media/VENDOR-DATA.txt.",
         "local _, ns = ...", "", "-- [itemID] = { name, kind, required level }", "ns.AMMO_ITEMS = {"]
for i in used:
    it = items[i]
    lines.append(f"  [{i}] = {{ {lua_str(it['name'])}, \"{it['kind']}\", {it['req']} }},")
maps = sorted({s[0] for s in spots})
areaOf = {m: a for a, m in UIMAP.items()}
lines += ["}", "", "-- [uiMapID] = English zone name, to find the map again if an ID differs on this client.", "ns.AMMO_MAPS = {"]
lines += [f"  [{m}] = {lua_str(zoneNames[areaOf[m]])}," for m in maps]
lines += ["}", "", "-- Vendors that need reputation before they trade.", "ns.AMMO_VENDOR_NOTES = {"]
lines += [f"  [{k}] = {lua_str(v)}," for k, v in sorted(NOTES.items())]
lines += ["}", "", "-- { uiMapID, x, y, npcID, name, faction (A/H/N), { itemIDs } }", "ns.AMMO_VENDORS = {"]
seen = set()
for m, x, y, npc, name, fac, sold in sorted(spots, key=lambda s: (s[0], s[3], s[1], s[2])):
    key = (m, npc, round(x, 1), round(y, 1))
    if key in seen: continue
    seen.add(key)
    lines.append(f"  {{ {m}, {x:g}, {y:g}, {npc}, {lua_str(name)}, \"{fac}\", {{ {', '.join(map(str, sold))} }} }},")
lines.append("}")
out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
print(f"items {len(used)}/{len(items)}  vendors {len(vendors)}  spots {len(seen)}  skipped {skipped}")
from collections import Counter
print(Counter(s[5] for s in spots))
