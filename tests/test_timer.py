"""Runs the addon in Lua 5.1 against a minimal WoW mock and plays out shot cycles."""
import pathlib
import sys

import lupa.lua51 as lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = [line.strip() for line in (ROOT / "HunterShotTimer.toc").read_text(encoding="utf-8").splitlines()
         if line.strip().endswith(".lua")]

MOCK = r"""
local clock = 0
function GetTime() return clock end
function setClock(t) clock = t end
issecretvalue = function(v) return v == "SECRET" end
printed = {}
function print(msg) printed[#printed + 1] = msg end
SlashCmdList = {}
UISpecialFrames = {}
UIParent = {}
frames = {}
function CreateColor(r, g, b, a) return { r, g, b, a } end
netWorld = 0
function GetNetStats() return 0, 0, 40, netWorld end
combat = false
function UnitAffectingCombat() return combat end

-- Target world: set per test.
target = { exists = false, dead = false, hostile = true, autoShot = nil, close = false, byId = true }
function UnitExists() return target.exists end
function UnitIsDeadOrGhost() return target.dead end
function UnitCanAttack() return target.hostile end
C_Spell = { IsSpellInRange = function(id, unit)
  if target.broken then error("range API blew up") end
  if id == 75 then return target.byId and target.autoShot or nil end
  if id == "Auto Shot" then return target.autoShot end
end }
function CheckInteractDistance(unit, i) assert(i == 3); return target.close end
playerClass = "HUNTER"
function UnitClass() return "Hunter", playerClass end
playerFaction = "Alliance"
function UnitFactionGroup() return playerFaction end
-- Range items answer from target.yards once their range is known (filled after load).
itemRange = {}
function fillItems(ns)
  for _, entry in ipairs(ns.RANGE_ITEMS) do
    for _, id in ipairs(entry[2]) do itemRange[id] = entry[1] end
  end
end
target.yards = 22
target.health, target.maxHealth = 1000, 1000
function UnitHealth() return target.health end
function UnitHealthMax() return target.maxHealth end
-- Bow: 40-60 damage, +10 bonus, 100% -> 60 per shot.
ranged = { 2.8, 40, 60, 10, 0, 1 }
function UnitRangedDamage() return unpack(ranged) end
-- Ammo: 1200 arrows (item 2512) and a 6-slot quiver (item 2101) in bag 1.
ammoCount = 1200
function GetInventoryItemCount(unit, slot) assert(slot == 0); return ammoCount end
rangedWeapon = 2504 -- Worn Shortbow; 2508 = Old Blunderbuss
function GetInventoryItemID(unit, slot)
  if slot == 0 then return 2512 end
  if slot == 18 then return rangedWeapon end
  if slot == 31 then return 2101 end
end
C_Container = {
  ContainerIDToInventoryID = function(bag) return 30 + bag end,
  GetContainerNumSlots = function(bag) return bag == 1 and 6 or 16 end,
}
C_Item = {
  GetItemInfoInstant = function(id)
    if id == 2512 then return id, "Projectile", "Arrow", "", 0, 6, 2 end
    if id == 2101 then return id, "Quiver", "Quiver", "", 0, 11, 2 end
    if id == 2504 then return id, "Weapon", "Bows", "", 0, 2, 2 end
    if id == 2508 then return id, "Weapon", "Guns", "", 0, 2, 3 end
  end,
  GetItemMaxStackSizeByID = function(id) return 200 end,
  RequestLoadItemDataByID = function() end,
  IsItemInRange = function(id, unit)
    if not target.exists or itemRange[id] == nil then return nil end
    return target.yards <= itemRange[id]
  end,
}

-- World map: Elwynn (with Stormwind inside it) on the Eastern Kingdoms, Durotar on Kalimdor.
-- Teldrassil is named differently on this "client" and lives at map 2000.
function CreateFromMixins(...)
  local t = {}
  for _, m in ipairs({ ... }) do for k, v in pairs(m) do t[k] = v end end
  return t
end
MapCanvasPinMixin = {}
MapCanvasDataProviderMixin = { GetMap = function(self) return self.owningMap end }
Enum = { UIMapType = { Continent = 2, Zone = 3 } }
mapInfos = {
  [1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
  [1414] = { mapID = 1414, name = "Kalimdor", mapType = 2, parentMapID = 947 },
  [1429] = { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
  [1453] = { mapID = 1453, name = "Stormwind City", mapType = 3, parentMapID = 1429 },
  [1411] = { mapID = 1411, name = "Durotar", mapType = 3, parentMapID = 1414 },
  [1438] = { mapID = 1438, name = "Somewhere Else", mapType = 3, parentMapID = 1414 },
  [2000] = { mapID = 2000, name = "Teldrassil", mapType = 3, parentMapID = 1414 },
}
waypoint = nil
C_Map = {
  GetMapInfo = function(id) return mapInfos[id] end,
  GetMapChildrenInfo = function(id, kind, all)
    local out = {}
    for _, m in pairs(mapInfos) do out[#out + 1] = m end
    return out
  end,
  GetMapRectOnMap = function(from, to)
    if from == 1429 and to == 1415 then return 0.4, 0.5, 0.7, 0.8 end
    if from == 1453 and to == 1429 then return 0.2, 0.4, 0.3, 0.5 end
    if from == 1411 and to == 1414 then return 0.5, 0.6, 0.5, 0.6 end
    error("not on that map")
  end,
  CanSetUserWaypointOnMap = function() return true end,
  SetUserWaypoint = function(point) waypoint = point end,
}
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
tooltip = {}
GameTooltip = {
  SetOwner = function() tooltip = {} end,
  AddLine = function(_, t) tooltip[#tooltip + 1] = t end,
  AddDoubleLine = function(_, a, b) tooltip[#tooltip + 1] = a .. " " .. b end,
  Show = function() end, Hide = function() end,
}
mapPins = {}
WorldMapFrame = {
  mapID = 1429,
  GetMapID = function(self) return self.mapID end,
  AddDataProvider = function(self, p) self.provider = p; p.owningMap = self end,
  SetPinTemplateType = function() end,
  SetMapID = function(self, id) self.opened = id end,
  RemoveAllPinsByTemplate = function(self, t) mapPins = {} end,
  AcquirePin = function(self, t, ...)
    assert(t == "HunterShotTimerVendorPinTemplate")
    local pin = CreateFromMixins(HunterShotTimerVendorPinMixin)
    pin.Ring, pin.Icon, pin.Hover, pin.Count = CreateFrame("Frame"), CreateFrame("Frame"), CreateFrame("Frame"), CreateFrame("Frame")
    pin.GetMap = function() return WorldMapFrame end
    for _, k in ipairs({ "Ring", "Icon", "Hover" }) do
      local r = pin[k]
      r.SetTexture = function(r, tex) r.texture = tex end
      r.SetVertexColor = function(r, cr, cg, cb) r.colour = { cr, cg, cb } end
    end
    pin.SetSize = function(p, w) p.size = w end
    pin.SetPosition = function(p, x, y) p.x, p.y = x, y end
    pin.RegisterForClicks = function() end
    pin:OnLoad()
    pin:OnAcquired(...)
    mapPins[#mapPins + 1] = pin
  end,
}
-- Minimap world: Elwynn spans 4500 x 3000 yd on continent 0 (Stormwind inside it), Durotar
-- is on continent 1. World x runs north, world y runs west.
player = { map = 1429, x = 0.44, y = 0.66 }
viewRadius, rotate, facing, lockdown = 200, "0", 0, false
function CreateVector2D(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
C_Map.GetBestMapForUnit = function() return player.map end
C_Map.GetPlayerMapPosition = function(m) return CreateVector2D(player.x, player.y) end
C_Map.GetWorldPosFromMapPos = function(m, v)
  local x, y = v.x, v.y
  if m == 1453 then x, y = 0.2 + x * 0.2, 0.3 + y * 0.2; m = 1429 end
  if m == 1429 then return 0, CreateVector2D(1000 - y * 3000, 1000 - x * 4500) end
  if m == 1411 then return 1, CreateVector2D(500 - y * 3000, 500 - x * 3000) end
end
C_Minimap = { GetViewRadius = function() return viewRadius end }
C_CVar = { GetCVar = function(name) if name == "rotateMinimap" then return rotate end end }
function GetPlayerFacing() return facing end
function GetMinimapShape() return "ROUND" end
function InCombatLockdown() return lockdown end
function miniPins()
  local out = {}
  for _, f in ipairs(frames) do
    if f.kind == "Button" and rawget(f, "vendor") and f.shown then out[#out + 1] = f end
  end
  return out
end

function showMap(id)
  WorldMapFrame.mapID = id
  WorldMapFrame.provider:RefreshAllData()
  return mapPins
end

-- Any unknown method or field is a do-nothing callable, so UI code runs end to end.
local any = setmetatable({}, { __call = function() end })
getmetatable(any).__index = function() return any end
local Region = {}
Region.__index = function(_, k) local v = rawget(Region, k); if v ~= nil then return v end return any end
function Region:SetSize(w, h) self.width, self.height = w, h end
function Region:GetWidth() return self.width or 0 end
function Region:SetFont(path, size) self.fontSize = size end
-- Narrow-font estimate: half the font size per character.
function Region:GetStringWidth()
  local t = (self.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return #t * (self.fontSize or 10) * 0.5
end
function Region:SetWidth(w) self.width = w end
function Region:GetHeight() return self.height or 0 end
function Region:SetPoint(...) self.point = { ... } end
function Region:SetText(t) self.text = t end
function Region:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function Region:Hide()
  local was = self.shown
  self.shown = false
  if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Region:IsShown() return self.shown end
function Region:SetShown(on) if on then self:Show() else self:Hide() end end
function Region:SetAlpha(a) self.alpha = a end
function Region:EnableMouse(on) self.mouse = on end
function Region:SetValue(v) self.value = v end
function Region:SetChecked(v) self.checked = v end
function Region:GetChecked() return self.checked end
function Region:GetStatusBarTexture() return self.fill end
function Region:GetPoint() return "CENTER", UIParent, "CENTER", 10, 20 end
function Region:SetScript(name, fn) self.scripts[name] = fn end
function Region:RegisterEvent(e) self.events[e] = true end
texts = {}
local function region() return setmetatable({ scripts = {}, events = {}, shown = true }, Region) end
function Region:CreateTexture() return region() end
function Region:CreateFontString() local r = region(); texts[#texts + 1] = r; return r end

function CreateFrame(kind, name, parent, template)
  local f = region()
  f.kind, f.template = kind, template
  f.fill = region()
  frames[#frames + 1] = f
  if name then _G[name] = f end
  return f
end

Minimap = CreateFrame("Frame", "Minimap")
Minimap:SetSize(140, 140)

function fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
-- Advance to time t in small frames so fades settle.
function tick(t)
  local f = HunterShotTimerFrame
  local from = GetTime()
  local steps = math.max(1, math.ceil((t - from) / 0.05))
  for i = 1, steps do
    setClock(from + (t - from) * i / steps)
    f.scripts.OnUpdate(f, (t - from) / steps)
  end
end
function shownText()
  local out = {}
  for _, r in ipairs(texts) do local t = rawget(r, "text"); if t and r.shown then out[#out + 1] = t end end
  return table.concat(out, " | ")
end
function checkboxes()
  local out = {}
  for _, f in ipairs(frames) do if f.template == "UICheckButtonTemplate" then out[#out + 1] = f end end
  return out
end
"""


def main():
    lua = lupa.LuaRuntime()
    lua.execute(MOCK)
    ns = lua.eval("{}")
    for name in FILES:
        chunk = lua.eval("function(src, name) return assert(loadstring(src, name)) end")(
            (ROOT / name).read_text(encoding="utf-8"), name)
        chunk("HunterShotTimer", ns)
    g = lua.globals()
    g.fillItems(ns)
    frame, timer, rng, target, bar = g.HunterShotTimerFrame, ns.timer, ns.range, g.target, ns.bar
    checks = []

    def check(name, cond):
        if not cond:
            print(f"FAIL {name} | shown texts: {g.shownText()}")
            sys.exit(1)
        checks.append(name)

    # --- Settings storage -------------------------------------------------------
    g.HunterShotTimerDB = lua.eval('{ point = { "TOP", "TOP", 1, 2 }, width = "bad", colors = { move = { 1, 0, 0, 1 } } }')
    g.fire("ADDON_LOADED", "HunterShotTimer")
    db = ns.db
    check("old saved position kept", db.point[1] == "TOP")
    check("mistyped value replaced", db.width == 220)
    check("saved colour kept, missing colours filled", db.colors.move[1] == 1 and db.colors.stand[1] == 0.96)
    check("saved table is the live db", lua.eval("function(a, b) return rawequal(a, b) end")(g.HunterShotTimerDB, db))
    n = len(ns.FONTS)
    check("choice steps wrap", ns.Step(ns.FONTS, ns.FONTS[n][1], 1) == ns.FONTS[1][1]
          and ns.Step(ns.FONTS, ns.FONTS[1][1], -1) == ns.FONTS[n][1])
    check("2002 Bold is the default font", db.font == r"Fonts\2002B.ttf")
    old = ns.InitDB(lua.eval(r'{ font = "Fonts\\ARIALN.TTF" }'))
    check("old default font moves to 2002 Bold", old.font == r"Fonts\2002B.ttf")
    kept = ns.InitDB(lua.eval(r'{ font = "Fonts\\MORPHEUS.TTF" }'))
    check("a font you picked is kept", kept.font == r"Fonts\MORPHEUS.TTF")
    picked = ns.InitDB(lua.eval(r'{ font = "Fonts\\ARIALN.TTF", configVersion = 2 }'))
    check("Arial picked after the change is kept", picked.font == r"Fonts\ARIALN.TTF")
    ns.InitDB(db)
    fonts = [ns.FONTS[i + 1][1] for i in range(len(ns.FONTS))]
    bundled = [f.split("\\")[-1] for f in fonts if f.startswith("Interface")]
    check("16 fonts to pick from", len(fonts) == 16)
    check("bundled fonts are in Media/Fonts", all((ROOT / "Media" / "Fonts" / b).is_file() for b in bundled) and len(bundled) == 9)
    db.width = 333
    ns.ResetDB()
    check("reset all keeps position", db.width == 220 and db.point[1] == "TOP")
    db.point = None
    ns.ApplyLayout()

    # --- Phase math and window --------------------------------------------------
    phase = lambda now, speed=3.0: tuple(ns.Phase(now, 0, speed))  # noqa: E731
    check("move phase", phase(1.0)[0] == "move" and abs(phase(1.0)[2] - 1.5) < 1e-9)
    check("stand phase", phase(2.6)[0] == "stand" and abs(phase(2.6)[2] - 0.4) < 1e-9)
    check("late phase", phase(3.2) == ("late", 1, 0))
    check("zone never longer than swing", phase(0.1, 0.4)[0] == "stand")
    ns.SetLatency(80)
    check("ping widens window", abs(ns.Window() - 0.58) < 1e-9 and ns.Phase(2.45, 0, 3.0)[0] == "stand")
    db.addPing = False
    check("ping can be turned off", abs(ns.Window() - 0.5) < 1e-9)
    db.addPing = True
    ns.SetLatency(900)
    check("ping capped", abs(ns.Window() - 0.75) < 1e-9)
    ns.SetLatency("SECRET")
    check("secret ping ignored", abs(ns.Window() - 0.75) < 1e-9)
    ns.SetLatency(0)
    db.windowExtra = 100
    check("window adjust", abs(ns.Window() - 0.6) < 1e-9)
    db.windowExtra = -900
    check("window never below 0.1s", abs(ns.Window() - 0.1) < 1e-9)
    db.windowExtra = 0

    # --- Range mapping ----------------------------------------------------------
    check("range in", ns.Range(True, False) == "in")
    check("range dead zone", ns.Range(False, True) == "close")
    check("range too far", ns.Range(False, False) == "far")
    check("range unknown", ns.Range(None, True) is None and ns.Range("SECRET", False) is None)

    g.fire("PLAYER_ENTERING_WORLD")
    g.tick(1)
    check("timer hidden before first shot", not timer.shown)
    check("range hidden without target", not rng.shown)

    # Hostile target: the range check shows on its own, before any shot.
    target.exists, target.autoShot = True, True
    g.tick(2)
    check("in range shown with yards", rng.shown and rng.alpha > 0.9 and "In range  20-25 yd" in g.shownText())
    db.rangeDistance = "estimate"
    g.tick(2.2)
    check("distance as one number", "In range  ~23 yd" in g.shownText())
    db.rangeText = False
    g.tick(2.4)
    check("distance without label", "~23 yd" in g.shownText() and "In range" not in g.shownText())
    db.rangeText, db.rangeDistance = True, "off"
    ns.ApplyLayout()
    g.tick(2.45)
    check("distance off", "In range" in g.shownText() and "yd" not in g.shownText())
    db.rangeDistance = "bracket"
    ns.ApplyLayout()
    target.yards = 6
    target.autoShot, target.close = False, True
    g.tick(2.6)
    check("dead zone shown", "Too close" in g.shownText())
    check("dead zone yards", "Too close  5-8 yd" in g.shownText())
    target.close, target.yards = False, 60
    g.tick(3)
    check("too far shown", "Out of range  45+ yd" in g.shownText())
    target.yards = 22
    target.hostile = False
    check("friendly target ignored", ns.TargetRange() is None)
    target.hostile, target.dead = True, True
    check("dead target ignored", ns.TargetRange() is None)
    target.dead, target.autoShot = False, True
    db.rangeCombatOnly = True
    g.tick(3.5)
    check("combat-only range hidden out of combat", not rng.shown)
    g.combat = True
    g.tick(4)
    check("combat-only range shown in combat", rng.shown)
    g.combat, db.rangeCombatOnly = False, False
    db.rangeWhenIdle = False
    g.tick(4.5)
    check("range can wait for Auto Shot", not rng.shown)
    db.rangeWhenIdle = True
    db.rangeEnabled = False
    g.tick(5)
    check("range can be turned off", not rng.shown)
    db.rangeEnabled = True
    target.exists = False
    g.tick(6)
    check("range fades out without target", not rng.shown)

    # --- Shot cycle ---------------------------------------------------------------
    g.fire("START_AUTOREPEAT_SPELL")
    g.tick(10)
    g.fire("PLAYER_SWING", 2.8, 2)
    g.tick(10.5)
    check("timer shown after shot", timer.shown and timer.alpha > 0.9)
    check("move state", "MOVE" in g.shownText() and "2.80s" in g.shownText())
    g.tick(12.5)
    check("stand still near end", "STAND STILL" in g.shownText())
    g.tick(13.5)
    check("late holds while shooting", timer.shown and "STAND STILL" in g.shownText())
    # Overdue because of range: say so instead of "stand still".
    target.exists, target.autoShot, target.close = True, False, False
    g.tick(13.7)
    check("late out of range label", "OUT OF RANGE" in g.shownText())
    target.close = True
    g.tick(13.9)
    check("late too close label", "TOO CLOSE" in g.shownText())
    target.exists, target.close = False, False
    g.tick(14.1)
    check("late label back to stand still", "STAND STILL" in g.shownText())
    g.fire("PLAYER_SWING", 3.6, 0)
    check("melee swing ignored", ns.state.speed == 2.8 and ns.state.lastShot == 10)
    g.tick(14.2)
    g.fire("PLAYER_SWING", 2.0, 2)
    g.fire("PLAYER_SWING", 9.9, "SECRET")
    check("re-anchored on delayed shot, haste speed", abs(ns.state.lastShot - 14.2) < 1e-9 and ns.state.speed == 2.0)
    g.fire("PLAYER_SWING", "SECRET", 2)
    g.fire("PLAYER_SWING", 0, 2)
    check("bad payload ignored", ns.state.speed == 2.0)
    g.fire("STOP_AUTOREPEAT_SPELL")
    g.tick(14.8)
    check("finishes swing after stop", timer.shown)
    g.tick(17.0)
    check("hidden after stop", not timer.shown)

    # Live ping from GetNetStats feeds the window within a few seconds.
    g.netWorld = 120
    g.tick(24)
    check("live ping polled", abs(ns.Window() - 0.62) < 1e-9)
    g.netWorld = 0
    g.tick(30)

    # --- Layout follows the settings -----------------------------------------------
    db.width, db.barHeight, db.fontSize, db.smallFontSize = 300, 20, 16, 11
    ns.ApplyLayout()
    check("width and bar height applied", frame.width == 300 and bar.width == 300 and bar.height == 20)
    check("frame height = text + bar + info row", frame.height == (16 + 4) + 20 + (11 + 4))
    db.showStatus, db.showCountdown, db.showSpeed, db.rangeEnabled = False, False, False, False
    db.showShots, db.ammoDisplay = False, "off"
    ns.ApplyLayout()
    check("hidden rows take no space", frame.height == 20)
    db.showStatus, db.showCountdown, db.showSpeed, db.rangeEnabled = True, True, True, True
    db.showShots, db.ammoDisplay = True, "percent"
    db.opacity = 50
    ns.ApplyLayout()
    check("opacity applied", abs(frame.alpha - 0.5) < 1e-9)
    ns.ResetDB()
    ns.ApplyLayout()

    # Layouts: one row puts text beside the bar; vertical stands the bar up.
    db.layout = "row"
    ns.ApplyLayout()
    check("row layout: text beside the bar", frame.width == (72 + 6) + 220 + (27 + 6) + (39 + 6) and bar.width == 220)
    db.layout = "vertical"
    ns.ApplyLayout()
    check("vertical layout: bar stands up", bar.width == 10 and bar.height == 220 and frame.height == 220)
    db.layout = "standard"
    ns.ApplyLayout()
    check("standard layout back", bar.width == 220 and bar.height == 10)

    # --- Nothing overlaps -----------------------------------------------------------
    # Standard layout: status + ammo slot + countdown slot add up to the bar width exactly,
    # and the info text never reaches the range text, for every size combination.
    ui = ns.ui
    worst = []
    for width in (100, 160, 220, 350, 500):
        for font in (8, 12, 20, 28):
            for small in (6, 10, 14, 20):
                for ammo in ("off", "percent"):
                    for countdown_on in (True, False):
                        db.width, db.fontSize, db.smallFontSize = width, font, small
                        db.ammoDisplay, db.showCountdown = ammo, countdown_on
                        ns.ApplyLayout()
                        countSlot = (-(-font * 2.2 // 1) + 8) if countdown_on else 0
                        ammoSlot = (small + 3 + -(-small * 2.6 // 1) + 8) if ammo != "off" else 0
                        if abs(ui.status.width - max(1, width - countSlot - ammoSlot)) > 1e-6:
                            worst.append((width, font, small, ammo, countdown_on, ui.status.width))
    check("top row slots never overlap", not worst)
    db.width, db.fontSize, db.smallFontSize, db.showCountdown = 220, 12, 10, True
    ns.ApplyLayout()
    # Info and range on one row: info stops where the range text begins.
    ui.rangeText.text = "Out of range  45+ yd"
    fit_ok = True
    for width in (100, 220, 500):
        db.width = width
        ns.ApplyLayout()
        ui.rangeText.text = "Out of range  45+ yd"
        g.fire("START_AUTOREPEAT_SPELL")
        target.exists, target.autoShot, target.close, target.yards = True, False, False, 60
        g.tick(g.GetTime() + 0.3)
        used = ui.rangeText.GetStringWidth(ui.rangeText) + 4 + ui.dot.width + 10
        hidden = ui.info.alpha == 0
        if not hidden and ui.info.width + used > width + 1e-6:
            fit_ok = False
        if width >= 220 and hidden:
            fit_ok = False  # room enough: info must stay visible
    check("info row stops before the range text", fit_ok)
    target.exists, target.yards = False, 22
    g.fire("STOP_AUTOREPEAT_SPELL")
    db.width = 220
    ns.ApplyLayout()
    g.setClock(30)  # back to where the following steps expect the clock

    # --- Shots to kill -------------------------------------------------------------
    check("average shot like the character sheet", ns.AverageShot(40, 60, 10, 0, 1) == 60)
    check("secret damage ignored", ns.AverageShot("SECRET", 60, 0, 0, 1) is None)
    ns.UpdateShotDamage()
    check("shot damage cached", ns.shotDamage == 60)
    check("shots from plain health", ns.ShotsFrom(1000, 1000, 60) == 17)
    check("secret health shows nothing", ns.ShotsFrom("SECRET", 1000, 60) is None)
    check("percent-only health shows nothing", ns.ShotsFrom(80, 100, 60) is None)
    g.ranged = lua.eval('{ "SECRET", "SECRET", "SECRET", 0, 0, 1 }')
    ns.UpdateShotDamage()
    check("cached damage survives secret combat reads", ns.shotDamage == 60)

    # --- Ammo ----------------------------------------------------------------------
    ns.RefreshAmmo()
    check("quiver capacity from bag slots", ns.ammo.capacity == 1200 and ns.ammo.kind == "Arrows")
    check("full quiver is green", ns.AmmoText("count") == "|cff40d860Arrows 1200|r")
    # The five bands at their edges (quiver holds 1200: 12 arrows = 1%).
    bands = {100: "ff40d860", 70: "ff40d860", 69: "ffa6d96a", 50: "ffa6d96a", 49: "ffffc04d",
             30: "ffffc04d", 29: "ffff8c2e", 15: "ffff8c2e", 14: "fff23a3a", 1: "fff23a3a", 0: "fff23a3a"}
    for pct, colour in bands.items():
        g.ammoCount = pct * 12
        ns.ammo.last = None
        check(f"{pct}% is {colour}", ns.AmmoText("percent") == f"|c{colour}Arrows {pct}%|r")
    g.ammoCount = 240
    check("count mode uses the same colours", ns.AmmoText("count") == "|cffff8c2eArrows 240|r")
    check("ammo off", ns.AmmoText("off") is None)
    ns.ammo.capacity = None
    ns.ammo.last = None
    g.ammoCount = 800
    ns.AmmoShare(800)
    g.ammoCount = 400
    check("no quiver: percent of last restock", ns.AmmoText("percent") == "|cffa6d96aArrows 50%|r")
    g.ammoCount = 1200
    ns.RefreshAmmo()

    # Info row while shooting: speed, shots to kill and ammo together.
    g.ranged = lua.eval("{ 2.8, 40, 60, 10, 0, 1 }")
    ns.UpdateShotDamage()
    target.exists, target.autoShot, target.health = True, True, 600
    g.fire("START_AUTOREPEAT_SPELL")
    g.tick(30.5)
    g.fire("PLAYER_SWING", 2.8, 2)
    g.tick(31)
    check("info row shows speed and shots", "2.80s   ~10 shots" in g.shownText())
    check("ammo in its own slot, percent by default", ns.ui.ammoText.text == "|cff40d860Arrows 100%|r")
    target.health = "SECRET"
    g.tick(31.2)
    check("secret health hides shots only", ns.ui.info.text == "2.80s")
    target.exists, target.health = False, 1000
    g.fire("STOP_AUTOREPEAT_SPELL")
    g.tick(36)

    # --- Options window and slash commands -------------------------------------------
    g.SlashCmdList.HUNTERSHOTTIMER("")
    check("/hst opens options and unlocks", g.HunterShotTimerOptions.shown and ns.unlocked and frame.mouse)
    g.tick(37)
    check("demo shows while options open", timer.shown and rng.shown)
    boxes = list(g.checkboxes().values())
    check("options has the checkboxes", len(boxes) == 18)
    first = boxes[6]  # "Status text" (left column first: ping, then the 5 vendor options)
    first.checked = False
    first.scripts.OnClick(first)
    check("checkbox writes setting", db.showStatus is False)
    first.checked = True
    first.scripts.OnClick(first)
    frame.scripts.OnDragStop(frame)
    check("position saved on drag", db.point is not None)
    g.SlashCmdList.HUNTERSHOTTIMER("")
    g.tick(38)
    check("closing options locks and hides demo", not g.HunterShotTimerOptions.shown and not ns.unlocked
          and not timer.shown and not frame.mouse)
    g.SlashCmdList.HUNTERSHOTTIMER("unlock")
    g.SlashCmdList.HUNTERSHOTTIMER("unlock")
    check("/hst unlock unlocks (and stays unlocked)", ns.unlocked)
    g.SlashCmdList.HUNTERSHOTTIMER("lock")
    g.SlashCmdList.HUNTERSHOTTIMER("lock")
    check("/hst lock locks (and stays locked)", not ns.unlocked)
    g.SlashCmdList.HUNTERSHOTTIMER(" RESET ")
    check("/hst reset clears position", db.point is None)

    # Client only answers by spell name: the fallback still finds the range.
    target.exists, target.autoShot, target.byId = True, True, False
    check("name fallback", ns.TargetRange() == "in")
    # A throwing range API must not stop the timer, and /hst range reports it.
    target.broken = True
    g.fire("START_AUTOREPEAT_SPELL")
    g.tick(40)
    g.fire("PLAYER_SWING", 2.8, 2)
    g.tick(41)
    check("range error keeps timer running", timer.shown and not rng.shown)
    g.SlashCmdList.HUNTERSHOTTIMER("range")
    report = " ".join(str(v) for v in g.printed.values())
    g.SlashCmdList.HUNTERSHOTTIMER("probe")
    report = " ".join(str(v) for v in g.printed.values())
    check("probe report", "target health = 1000" in report and "average shot (cached) = 60.0" in report)
    check("range report", "C_Spell id 75 = error" in report and "within ~10 yd = false" in report)
    # --- Ammo vendors on the world map ----------------------------------------------
    vendors = [ns.AMMO_VENDORS[i + 1] for i in range(len(ns.AMMO_VENDORS))]
    check("vendor data: 100+ spots", len(vendors) > 100)
    check("vendor data: every spot complete", all(
        v[1] in ns.AMMO_MAPS and 0 <= v[2] <= 100 and 0 <= v[3] <= 100 and v[6] in ("A", "H", "N")
        and len(v[7]) > 0 and all(ns.AMMO_ITEMS[i] is not None for i in v[7].values()) for v in vendors))
    names = {f: set() for f in "AHN"}
    for v in vendors:
        names[v[6]].add(v[5])
    check("vendor data: all three factions", all(len(names[f]) > 5 for f in "AHN"))
    check("vendor data: goblin towns are neutral", {"Haren Kanmae", "Blizrik Buckshot", "Wixxrak", "Jazzik"} <= names["N"])
    check("vendor data: no vendors the live game lacks", not ({"Mazk Snipeshot", "Burkrum", "Netali Proudwind", "Fizzlefuse"} & (names["A"] | names["H"] | names["N"])))
    check("vendor data: matches Wowhead (117 Classic vendors)", len({v[4] for v in vendors}) == 117)
    spots = {}
    for v in vendors:
        spots.setdefault(v[4], set()).add(v[1])
    check("vendor data: city vendors not repeated on the zone around the city",
          not any({1453, 1429} <= m or {1454, 1411} <= m or {1455, 1426} <= m or {1456, 1412} <= m
                  or {1457, 1438} <= m or {1458, 1420} <= m for m in spots.values()))
    check("vendor data: arrows and bullets", {ns.AMMO_ITEMS[2512][2], ns.AMMO_ITEMS[2516][2]} == {"arrow", "bullet"})

    g.playerClass = "HUNTER"
    g.fire("PLAYER_ENTERING_WORLD")
    wm = g.WorldMapFrame
    check("vendor map provider attached", wm.provider is not None)

    def pins(map_id):
        got = g.showMap(map_id)
        return [got[i + 1] for i in range(len(got))]

    def sells(pin, kind):
        return any(ns.AMMO_ITEMS[i][2] == kind for i in pin.vendor["items"].values())

    elwynn = pins(1429)
    check("bow: Elwynn shows arrow vendors only",
          elwynn and all(sells(p, "arrow") and p.Icon.texture.endswith("Arrow_02") for p in elwynn))
    check("Stormwind vendors drawn small on Elwynn", any(p.vendor.map == 1453 and p.size == 13 for p in elwynn)
          and any(p.vendor.map == 1429 and p.size == 18 for p in elwynn))
    inner = [p for p in elwynn if p.vendor.map == 1453]
    check("Stormwind spots land inside its rect on Elwynn", all(0.2 <= p.x <= 0.4 and 0.3 <= p.y <= 0.5 for p in inner))
    check("Alliance pins are blue", all(p.Ring.colour[3] == 1 for p in elwynn if p.vendor.faction == "A"))
    def sides():
        return {v.faction for v in ns.VendorList(db, ns.VendorKinds("both")).values()}
    check("default for Alliance: own side and neutral, no Horde", sides() == {"A", "N"} and pins(1411) == [])
    db.vendorNeutral = False
    check("neutral switch", sides() == {"A"})
    db.vendorNeutral = True
    g.playerFaction = "Horde"
    check("default for Horde: own side and neutral", sides() == {"H", "N"} and pins(1429) == [])
    durotar = pins(1411)
    check("Durotar shows Horde vendors", durotar and all(p.vendor.faction == "H" for p in durotar))
    g.playerFaction = "Alliance"
    db.vendorOtherFaction = True
    check("other faction switch shows the other side", sides() == {"A", "H", "N"} and pins(1411) != [])
    g.playerFaction = None
    db.vendorOtherFaction = False
    check("no side yet: both sides shown", sides() == {"A", "H", "N"})
    g.playerFaction = "Alliance"
    db.vendorOtherFaction = True
    old = ns.InitDB(lua.eval('{ vendorAlliance = true, vendorHorde = true, configVersion = 3 }'))
    check("old per-faction switches replaced by the new default",
          old.vendorAlliance is None and old.vendorHorde is None and old.vendorOtherFaction is False)
    ns.InitDB(db)
    g.rangedWeapon = 2508
    g.fire("PLAYER_EQUIPMENT_CHANGED", 18)
    check("gun: map redraws with bullet vendors", g.mapPins[1] is not None
          and all(sells(p, "bullet") and p.Icon.texture.endswith("Bullet_02") for p in pins(1411)))
    db.vendorAmmo = "both"
    both = pins(1411)
    check("both kinds shows more", len(both) >= len(durotar))
    db.vendorAmmo = "weapon"
    g.rangedWeapon = 2504
    continent = pins(1415)
    check("continent: Elwynn vendors, small, inside Elwynn's rect", continent and all(
        p.size == 13 and 0.4 <= p.x <= 0.5 and 0.7 <= p.y <= 0.8 for p in continent))
    db.vendorContinent = False
    check("continent switch", pins(1415) == [])
    db.vendorContinent = True
    teldrassil = pins(2000)
    check("renamed map ID found by zone name", teldrassil and all(p.vendor.map == 1438 for p in teldrassil))
    check("unknown map: no pins, no error", pins(9999) == [] and ns.vendorError is None)
    # Close vendors share a pin, and no two pins of a side overlap.
    for m in (1429, 1411, 1415, 1453):
        drawn = pins(m)
        close = [(a, b) for i, a in enumerate(drawn) for b in drawn[i + 1:]
                 if a.vendor.faction == b.vendor.faction and a.small == b.small
                 and ((a.x - b.x) * 1.5) ** 2 + (a.y - b.y) ** 2 < 0.012 ** 2]
        check(f"map {m}: no overlapping pins", not close)
    db.vendorAmmo = "both"
    # Neighbours in the Trade District share pins; the Dwarven District gunsmith keeps his own.
    city = [p for p in pins(1429) if p.vendor.map == 1453]
    city.sort(key=lambda p: -len(p.pin.vendors))
    check("Stormwind's 5 vendors merge into fewer, numbered pins on Elwynn",
          sum(len(p.pin.vendors) for p in city) == 5 and len(city) < 5
          and all(p.Count.text == (len(p.pin.vendors) if len(p.pin.vendors) > 1 else "") for p in city))
    city[0].OnMouseEnter(city[0])
    tip = " | ".join(str(t) for t in g.tooltip.values())
    check("merged tooltip lists every vendor", f"{len(city[0].pin.vendors)} ammo vendors" in tip
          and all(v.name in tip for v in city[0].pin.vendors.values()) and "Click: open Stormwind City" in tip)
    city[0].OnMouseClickAction(city[0], "LeftButton")
    check("clicking a city pin opens the city map", wm.opened == 1453)
    db.vendorAmmo = "weapon"
    pin = [p for p in pins(1429) if p.pin.open is None and len(p.pin.vendors) == 1][0]
    pin.OnMouseEnter(pin)
    tip = " | ".join(str(t) for t in g.tooltip.values())
    check("tooltip: name, faction, ammo with level",
          pin.vendor.name in tip and "Alliance" in tip and "level " in tip and "Click: set a waypoint" in tip)
    pin.OnMouseClickAction(pin, "LeftButton")
    check("click sets a waypoint on the vendor's map",
          g.waypoint.m == pin.vendor.map and abs(g.waypoint.x - pin.vendor.x) < 1e-9)
    check("waypoint message", "Waypoint set: " + pin.vendor.name in str(g.printed[len(g.printed)]))
    g.SlashCmdList.HUNTERSHOTTIMER("")
    show = list(g.checkboxes().values())[1]
    show.checked = False
    show.scripts.OnClick(show)
    check("options switch removes the pins at once", not db.vendorPins and len(g.mapPins) == 0)
    show.checked = True
    show.scripts.OnClick(show)
    check("and brings them back", len(g.mapPins) > 0)
    g.SlashCmdList.HUNTERSHOTTIMER("")

    # --- Ammo vendors on the minimap ---------------------------------------------------
    db.vendorOtherFaction = False
    check("minimap updater attached", ns.minimapUpdater is not None)

    def mini():
        ns.UpdateMinimapPins()
        got = g.miniPins()
        return [got[i + 1] for i in range(len(got))]

    goldshire = mini()  # standing 3 yd south of Brog Hamfist (44, 65.9)
    brog = [m for m in goldshire if m.vendor.name == "Brog Hamfist"]
    check("minimap: Goldshire vendor shown", len(brog) == 1)
    px, py = brog[0].point[4], brog[0].point[5]
    check("minimap: 3 yd north is just above the centre", abs(px) < 0.01 and 0.5 < py < 1.5)
    check("minimap: only vendors within the view radius", all(
        ((m.vendor.x - 0.44) * 4500) ** 2 + ((m.vendor.y - 0.66) * 3000) ** 2 <= 200 ** 2 for m in goldshire))
    g.rotate, g.facing = "1", 3.14159265 / 2  # facing west: north is to the right
    brog = [m for m in mini() if m.vendor.name == "Brog Hamfist"][0]
    check("minimap: rotating minimap turns the pins", brog.point[4] > 0.5 and abs(brog.point[5]) < 0.01)
    g.rotate, g.facing = "0", 0
    g.player.x, g.player.y = 0.05, 0.05
    check("minimap: nothing nearby, no pins", mini() == [])
    # Standing in Elwynn at the Trade District: Stormwind's vendors show from outside the city map.
    g.player.x, g.player.y = 0.2 + 0.55 * 0.2, 0.3 + 0.59 * 0.2
    trade = mini()
    names_here = {v.name for m in trade for v in m.pin.vendors.values()}
    check("minimap: city vendors show from the zone map", {"Thurman Mullby", "Marda Weller"} <= names_here)
    check("minimap: close vendors share a numbered pin", any(len(m.pin.vendors) > 1 and m.Count.text == len(m.pin.vendors) for m in trade))
    m = trade[0]
    m.scripts.OnEnter(m)
    tip = " | ".join(str(t) for t in g.tooltip.values())
    check("minimap: tooltip", m.vendor.name in tip and "Click: set a waypoint" in tip)
    m.scripts.OnClick(m, "LeftButton")
    check("minimap: click sets a waypoint", g.waypoint.m == m.vendor.map)
    g.lockdown = True
    check("minimap: hidden in combat", mini() == [])
    g.lockdown = False
    db.vendorMinimap = False
    check("minimap: switch hides the pins", mini() == [])
    db.vendorMinimap, db.vendorPins = True, False
    check("minimap works with the world map pins off", mini() != [])
    db.vendorPins = True
    g.player.map = None
    check("minimap: unknown position, no pins, no error", mini() == [])
    g.player.map = 1429

    # Other classes with a wand fire the same events: no hunter bar for them.
    target.broken = False
    g.playerClass = "PRIEST"
    g.fire("PLAYER_ENTERING_WORLD")
    g.fire("START_AUTOREPEAT_SPELL")
    g.tick(50)
    g.fire("PLAYER_SWING", 1.8, 2)
    g.tick(51)
    check("no bar or range for other classes", not timer.shown and not rng.shown)
    check("no vendor pins for other classes", pins(1429) == [] and mini() == [])
    check("messages in English", "Unlocked" in report and "Position reset" in report)

    print({"result": "PASS", "checks": len(checks)})


if __name__ == "__main__":
    main()
