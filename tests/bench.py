"""Per-frame cost of the bar in the WoW mock: memory allocated and widget calls per frame,
over 10 seconds of shooting at 120 fps with the range check and distance on.
Usage: python -I tests/bench.py"""
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import test_timer as t  # noqa: E402  (reuses its WoW mock and file list)

FPS, SECONDS = 120, 10

lua = t.lupa.LuaRuntime()
lua.execute(t.MOCK)
lua.execute("""
calls = 0
-- The test mock records SetPoint arguments in a new table; that cost is the mock's, not the addon's.
rawset(getmetatable(CreateFrame("Frame")), "SetPoint", nil)
local mt = getmetatable(CreateFrame("Frame"))
for _, name in ipairs({ "SetText", "SetAlpha", "SetShown", "Show", "Hide", "SetWidth", "SetPoint", "SetTextColor", "SetVertexColor", "SetTexture" }) do
  local f = rawget(mt, name)
  rawset(mt, name, function(...) calls = calls + 1; if f then return f(...) end end)
end
""")
ns = lua.eval("{}")
for name in t.FILES:
    lua.eval("function(src, name) return assert(loadstring(src, name)) end")(
        (t.ROOT / name).read_text(encoding="utf-8"), name)("HunterShotTimer", ns)
g = lua.globals()
g.fillItems(ns)
g.fire("ADDON_LOADED", "HunterShotTimer")
g.fire("PLAYER_ENTERING_WORLD")
g.target.exists, g.target.autoShot = True, True
g.fire("START_AUTOREPEAT_SPELL")
g.setClock(100)
g.fire("PLAYER_SWING", 2.8, 2)

run = lua.eval("""function(fps, seconds)
  local f = HunterShotTimerFrame
  local dt = 1 / fps
  collectgarbage("collect")
  collectgarbage("stop")
  local mem, n = collectgarbage("count"), calls
  local nextShot = GetTime() + 2.8
  for i = 1, fps * seconds do
    setClock(GetTime() + dt)
    if GetTime() >= nextShot then fire("PLAYER_SWING", 2.8, 2); nextShot = nextShot + 2.8 end
    f.scripts.OnUpdate(f, dt)
  end
  local kb, c = collectgarbage("count") - mem, calls - n
  collectgarbage("restart")
  return kb, c
end""")
start = time.perf_counter()
kb, c = run(FPS, SECONDS)
ms = (time.perf_counter() - start) * 1000
frames = FPS * SECONDS
print(f"{frames} frames: {kb * 1024 / frames:.0f} bytes allocated/frame, "
      f"{c / frames:.1f} widget calls/frame, {ms / frames * 1000:.1f} us/frame (mock)")
