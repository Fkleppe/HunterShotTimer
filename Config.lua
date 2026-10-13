local addonName, ns = ...

-- Everything the options window can change. Missing or wrongly typed saved values fall
-- back to these, so new settings appear on upgrade without touching old ones.
ns.DEFAULTS = {
  width = 220,
  barHeight = 10,
  fontSize = 12,
  smallFontSize = 10,
  font = "Fonts\\2002B.ttf",
  outline = "",
  layout = "standard", -- "standard" / "row" / "vertical"
  texture = "Interface\\Buttons\\WHITE8X8",
  gradient = true,
  opacity = 100,
  windowExtra = 0, -- ms added to (or taken from) the stand-still window
  addPing = true,

  showStatus = true,
  showCountdown = true,
  showSpeed = true,
  showSpark = true,
  showFlash = true,
  showBorder = true,
  showShots = true, -- estimated Auto Shots to kill the target
  showMelee = true, -- in melee range the bar stays: melee swing timer, or "too close"
  ammoDisplay = "percent", -- "off" / "percent" / "count"

  rangeEnabled = true,
  rangeText = true,
  rangeCombatOnly = false,
  rangeWhenIdle = true, -- also while Auto Shot is off
  rangePosition = "belowRight",
  rangeDistance = "bracket", -- "off" / "bracket" (20-25 yd) / "estimate" (~23 yd)

  vendorPins = true, -- ammo vendors on the world map
  vendorMinimap = true, -- and on the minimap
  vendorContinent = true, -- also on Kalimdor / Eastern Kingdoms
  vendorNeutral = true,
  vendorOtherFaction = false, -- vendors of the other side, who will not trade with you
  vendorAmmo = "weapon", -- "weapon" / "both" / "arrow" / "bullet"

  colors = {
    move = { 0.36, 0.82, 0.47, 1 },
    stand = { 0.96, 0.40, 0.29, 1 },
    zone = { 0.42, 0.11, 0.08, 0.9 },
    track = { 0.07, 0.07, 0.08, 0.88 },
    text = { 0.95, 0.95, 0.95, 1 },
    melee = { 1.00, 0.78, 0.30, 1 },
  },
}

-- The game's own fonts, then fonts shipped in Media\Fonts (SIL Open Font License,
-- see Media\Fonts\LICENSES.txt).
local MEDIA = "Interface\\AddOns\\" .. (addonName or "HunterShotTimer") .. "\\Media\\Fonts\\"
ns.FONTS = {
  { "Fonts\\2002B.ttf", "2002 Bold" },
  { "Fonts\\2002.TTF", "2002" },
  { "Fonts\\ARIALN.TTF", "Arial Narrow" },
  { "Fonts\\FRIZQT__.TTF", "Friz Quadrata" },
  { "Fonts\\skurri.ttf", "Skurri" },
  { "Fonts\\NIM_____.ttf", "Nimrod" },
  { "Fonts\\MORPHEUS.TTF", "Morpheus" },
  { MEDIA .. "BarlowCondensed-SemiBold.ttf", "Barlow Condensed" },
  { MEDIA .. "BarlowCondensed-Bold.ttf", "Barlow Condensed Bold" },
  { MEDIA .. "BebasNeue-Regular.ttf", "Bebas Neue" },
  { MEDIA .. "ChakraPetch-Bold.ttf", "Chakra Petch" },
  { MEDIA .. "Rajdhani-Bold.ttf", "Rajdhani" },
  { MEDIA .. "RussoOne-Regular.ttf", "Russo One" },
  { MEDIA .. "SairaCondensed-Bold.ttf", "Saira Condensed" },
  { MEDIA .. "ShareTechMono-Regular.ttf", "Share Tech Mono" },
  { MEDIA .. "TitilliumWeb-Bold.ttf", "Titillium Web" },
}
ns.LAYOUTS = {
  { "standard", "Horizontal, text above" },
  { "row", "Horizontal, one row" },
  { "vertical", "Vertical" },
}
ns.OUTLINES = {
  { "", "Shadow" },
  { "OUTLINE", "Outline" },
  { "THICKOUTLINE", "Thick outline" },
}
ns.TEXTURES = {
  { "Interface\\Buttons\\WHITE8X8", "Flat" },
  { "Interface\\TargetingFrame\\UI-StatusBar", "Blizzard" },
  { "Interface\\RaidFrame\\Raid-Bar-Hp-Fill", "Raid" },
}
ns.RANGE_POSITIONS = {
  { "belowRight", "Below, right" },
  { "belowLeft", "Below, left" },
  { "right", "Right of bar" },
  { "left", "Left of bar" },
}

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

-- Fill `into` from `defaults`: keep valid saved values, replace missing or mistyped ones.
local function merge(into, defaults)
  for k, d in pairs(defaults) do
    if type(into[k]) ~= type(d) then
      into[k] = copy(d)
    elseif type(d) == "table" then
      merge(into[k], d)
    end
  end
end

function ns.InitDB(saved)
  local db = type(saved) == "table" and saved or {}
  -- v2: 2002 Bold became the default font; move anyone still on the old default.
  if (db.configVersion or 1) < 2 and db.font == "Fonts\\ARIALN.TTF" then db.font = ns.DEFAULTS.font end
  -- v3: ammo shows as a percentage by default; move anyone still on the old default.
  if (db.configVersion or 1) < 3 and db.ammoDisplay == "count" then db.ammoDisplay = "percent" end
  -- v4: per-faction vendor switches became "your side + neutral", other side optional.
  db.vendorAlliance, db.vendorHorde = nil, nil
  db.configVersion = 4
  merge(db, ns.DEFAULTS)
  ns.db = db
  return db
end

-- Back to defaults, keeping where the bar sits on screen.
function ns.ResetDB()
  local point = ns.db.point
  for k in pairs(ns.db) do ns.db[k] = nil end
  merge(ns.db, ns.DEFAULTS)
  ns.db.point = point
  ns.db.configVersion = 4
end

function ns.Label(list, value)
  for _, item in ipairs(list) do
    if item[1] == value then return item[2] end
  end
  return list[1][2]
end

-- The next entry in a choice list, wrapping around.
function ns.Step(list, value, dir)
  local at = 1
  for i, item in ipairs(list) do
    if item[1] == value then at = i end
  end
  return list[(at - 1 + dir) % #list + 1][1]
end
