# Hunter Shot Timer

An Auto Shot bar for hunters on WoW Forever (Interface 16001, Classic rules): it shows when you
can move and when to stand still so the next Auto Shot fires on time.

- **Shot bar**: driven by the game's own swing event (`PLAYER_SWING`), so the speed includes
  quiver haste, Rapid Fire and other haste. The red window is the ~0.5 s stand-still the engine
  needs, plus your ping.
- **Range check**: in range / too close (dead zone) / out of range, with the distance to your
  target as a 5 yd bracket or an estimate.
- **Shots to kill** (when the game lets addons read the target's health) and **ammo left**
  (percent or count, coloured by how full your quiver is).
- **Ammo vendors** on the world map and minimap: every NPC that sells arrows or bullets, for your
  side and neutral towns by default. Hover for what they sell, click for a waypoint.
- Everything is set in a settings window: `/hst`.

## Commands

| Command | |
|---|---|
| `/hst` | Open or close the settings (the bar can be dragged while it is open) |
| `/hst lock`, `/hst unlock` | Lock or unlock the bar |
| `/hst reset` | Put the bar back in its default place |
| `/hst range` | Show what the range check reads (for troubleshooting) |
| `/hst probe` | Show what the shots-to-kill estimate can read (run it mid-fight) |

## Install

Copy this folder to `World of Warcraft\_classic_beta_\Interface\AddOns\HunterShotTimer`
(only the `.toc`, `.lua`, `.xml` files and `Media` are needed). Restart the game after adding
or removing files; `/reload` is enough for changes to existing files.

## Development

- Tests run the addon in Lua 5.1 against a WoW mock: `python -I tests/test_timer.py`
  (needs `pip install lupa`).
- `python -I tests/bench.py` measures the bar's per-frame cost.
- `tools/build_vendors.py` rebuilds `VendorData.lua`; see `Media/VENDOR-DATA.txt` for the data
  sources and their licences. Bundled fonts are under the SIL Open Font License
  (`Media/Fonts/LICENSES.txt`).
