import json, re, sys
from pathlib import Path

d = Path(sys.argv[1])
ids = d.joinpath("ammo_ids.txt").read_text().split()
sold = {}
for i in ids:
    if not d.joinpath(f"{i}.html").exists():
        print(i, "- no Wowhead page")
        continue
    s = d.joinpath(f"{i}.html").read_text(encoding="utf-8")
    name = re.search(r"<title>([^<]*)", s).group(1).split(" - ")[0]
    k = s.find("id: 'sold-by'")
    if k < 0:
        print(i, name, "- not sold")
        continue
    k = s.find("data:", k)
    blk = s[k: s.find("});", k)]
    rows = re.findall(r'\{"[^{}]*?"id":(\d+)[^{}]*?"name":"((?:[^"\\]|\\.)*)"', blk)
    if not rows:
        rows = [(n, "?") for n in re.findall(r'"id":(\d+)', blk)]
    sold[i] = {"name": name, "npcs": {int(n): nm for n, nm in rows}}
    print(i, name, len(sold[i]["npcs"]))
d.joinpath("wowhead_sold.json").write_text(json.dumps(sold, indent=1))
