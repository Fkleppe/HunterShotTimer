"""Reads the shot log Hunter Shot Timer saves (SavedVariables) and checks the timing.

For each shot: gap to the last one, the swing it ended, how long after the swing end it
came, and how long you had stood still. Then what that says: does the stand-still need sit
inside the swing or on top of it, and how long you really have to stand still.

Usage: python -I tools/analyze_log.py "<WoW>/_classic_beta_/WTF/Account/<account>/SavedVariables/HunterShotTimer.lua"
(needs lupa; run /reload in game first so the file is written)
"""
import statistics
import sys

import lupa.lua51 as lupa


def load(path):
    lua = lupa.LuaRuntime()
    with open(path, encoding="utf-8") as f:
        lua.execute(f.read())
    db = lua.globals().HunterShotTimerDB
    if db is None:
        sys.exit("No HunterShotTimerDB in that file.")
    rows = []
    log = db.shotLog
    if log is not None:
        for i in range(1, len(log) + 1):
            rows.append({k: v for k, v in log[i].items()})
    calib = {k: [db.calib[k][i] for i in range(1, len(db.calib[k]) + 1)]
             for k in ("stand", "early", "missed") if db.calib and db.calib[k] is not None}
    return rows, calib


def main(path):
    rows, calib = load(path)
    print(f"{len(rows)} shots in the log")
    if not rows:
        print("Nothing logged yet: shoot, then /reload so the game writes the file.")
        return
    known = sum(1 for r in rows if r.get("known") in (1, 2))
    events = sum(1 for r in rows if r.get("known") == 2)
    print(f"movement known on {known} of {len(rows)} shots ({events} from the movement events)"
          + ("" if known else "  <- the client hides movement: the bar cannot see you stand still"))
    print(f"ping: {min(r['ping'] for r in rows)}-{max(r['ping'] for r in rows)} ms")
    print()
    print("  #    gap   swing  after-swing  stood-still  notes")
    still_all, stopped_late, missed = [], [], []
    for i, r in enumerate(rows, 1):
        notes = []
        if r.get("broken"):
            notes.append("melee/restart")
        if r.get("moved"):
            notes.append("moved")
        still = r.get("still")
        if still is not None and still < 0:
            notes.append("MOVING at the shot?")
        gap = r.get("gap")
        print(f"{i:3d}  {gap if gap is not None else '-':>6}  {r.get('prev', '-'):>5}  {r.get('afterSwing', '-'):>11}"
              f"  {still if still is not None else '-':>11}  {', '.join(notes)}")
        if gap is None or r.get("broken"):
            continue
        after = r["afterSwing"]
        if still is not None and still >= 0:
            before = still - after  # how long before the swing end you stopped
            if before >= 0.8:  # stood still through the whole window
                still_all.append(after)
            elif before <= 0 and 0.15 <= still <= 1.2:  # stopped after the swing ended
                stopped_late.append(still)
            elif 0.1 <= before < 0.8:  # stopped inside the window
                missed.append((before, after))
    print()
    if still_all:
        print(f"standing still all along ({len(still_all)} shots): the shot came "
              f"{statistics.median(still_all):+.3f} s after the swing ended (median; "
              f"min {min(still_all):+.3f}, max {max(still_all):+.3f})")
        m = statistics.median(still_all)
        print("  -> the half second sits INSIDE the swing" if m < 0.15 else
              "  -> the half second comes ON TOP of the swing" if 0.35 < m < 0.75 else "  -> unclear")
    if missed:
        afters = [a for _, a in missed]
        print(f"stopped inside the window ({len(missed)} shots, {min(b for b, _ in missed):.2f}-"
              f"{max(b for b, _ in missed):.2f} s before the end): the shot came "
              f"{statistics.median(afters):+.3f} s after the swing ended (median; min {min(afters):+.3f}, "
              f"max {max(afters):+.3f})")
    if stopped_late:
        print(f"stopped after the swing ended ({len(stopped_late)} shots): the shot came "
              f"{statistics.median(stopped_late):.3f} s after you stopped (median; "
              f"min {min(stopped_late):.3f}, max {max(stopped_late):.3f})")
    # Haste changes inside a swing (Deadly Aspects, Rapid Fire): does the game speed up the
    # swing already under way? Compare the gap with both answers.
    hasted = [r for r in rows if r.get("haste") and r.get("gap") and not r.get("broken")]
    if hasted:
        print(f"\nattack speed changed inside {len(hasted)} swings:")
        print("  events (R ranged, A attack speed; seconds into the swing): see each row")
        print("  at (s into swing)  old speed  new speed  gap    if only the next swing  if this swing too")
        votes = {"next": 0, "this": 0}
        for r in hasted:
            first = str(r["haste"]).split(",")[0]
            t = float(first.lstrip("RA"))
            old, new, gap = r["prev"], r["speed"], r["gap"]
            plain = old
            rescaled = t + (old - t) * new / old
            stand = max(0.0, (r.get("afterSwing") or 0))
            near = "next" if abs(gap - plain) <= abs(gap - rescaled) else "this"
            if abs(new - old) / old > 0.05 and stand < 0.3:
                votes[near] += 1
            print(f"  {t:17.3f}  {old:9.3f}  {new:9.3f}  {gap:5.3f}  {plain:22.3f}  {rescaled:17.3f}  -> {near}"
                  f"   [{r['haste']}]")
        print(f"  verdict (clear cases): only the next swing {votes['next']}, this swing too {votes['this']}")
    if calib:
        for k, v in calib.items():
            if v:
                print(f"learned {k}: median {statistics.median(v):+.3f} from {len(v)} shots")


if __name__ == "__main__":
    main(sys.argv[1])
