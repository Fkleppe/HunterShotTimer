local _, ns = ...

-- Ammo vendors on the world map and the minimap: every NPC that sells arrows or bullets
-- (VendorData.lua), as a small icon in the vendor's faction colour. Hover for what they
-- sell, click for a waypoint.

ns.VENDOR_AMMO = {
  { "weapon", "Match my weapon" },
  { "both", "Arrows and bullets" },
  { "arrow", "Arrows only" },
  { "bullet", "Bullets only" },
}

local TEMPLATE = "HunterShotTimerVendorPinTemplate"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ICONS = { arrow = "Interface\\Icons\\INV_Ammo_Arrow_02", bullet = "Interface\\Icons\\INV_Ammo_Bullet_02" }
local FACTIONS = {
  A = { "Alliance", { 0.27, 0.55, 1 } },
  H = { "Horde", { 0.92, 0.22, 0.2 } },
  N = { "Neutral", { 1, 0.82, 0.25 } },
}
local PLAYER_FACTION = { Alliance = "A", Horde = "H" }
local PIN_SIZE, CONTINENT_SIZE = 18, 13
local RANGED_SLOT = 18
local WEAPON_CLASS = 2
local WEAPON_AMMO = { [2] = "arrow", [18] = "arrow", [3] = "bullet" } -- bow, crossbow, gun

local function normalize(s)
  return (s or ""):lower():gsub("^the ", ""):gsub("[%s%-']", "")
end

local function mapInfo(id)
  if not (C_Map and C_Map.GetMapInfo) then return nil end
  local ok, info = pcall(C_Map.GetMapInfo, id)
  return ok and info or nil
end

-- The data's map IDs are Classic's. If this client lacks one or names it differently, look
-- the zone up by its English name; a client in another language keeps the ID as it is.
local remap
local function mapFor(id)
  if not remap then
    remap = {}
    local byName = {}
    local ok, children = pcall(C_Map.GetMapChildrenInfo, 947, nil, true)
    for _, child in ipairs(ok and children or {}) do byName[normalize(child.name)] = child.mapID end
    for m, name in pairs(ns.AMMO_MAPS) do
      local info = mapInfo(m)
      local found = byName[normalize(name)]
      remap[m] = ((not info or normalize(info.name) ~= normalize(name)) and found) or m
    end
  end
  return remap[id] or id
end

-- Arrows or bullets for the equipped bow, crossbow or gun; nil for anything else.
function ns.WeaponAmmo()
  local ok, id = pcall(GetInventoryItemID, "player", RANGED_SLOT)
  if not (ok and id and C_Item and C_Item.GetItemInfoInstant) then return nil end
  local okInfo, _, _, _, _, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, id)
  if okInfo and classID == WEAPON_CLASS then return WEAPON_AMMO[subclassID] end
end

-- Which kinds to show: { arrow = true, bullet = true }.
function ns.VendorKinds(mode, weapon)
  if mode == "arrow" or mode == "bullet" then return { [mode] = true } end
  if mode == "weapon" and weapon then return { [weapon] = true } end
  return { arrow = true, bullet = true }
end

-- Your own side's vendors always; neutral ones and the other side's when switched on.
-- A character without a side yet sees both.
local function wanted(db, faction, own)
  if faction == "N" then return db.vendorNeutral end
  return not own or faction == own or db.vendorOtherFaction
end

-- The vendors to draw: ones you can buy from (see wanted), selling at least one wanted kind.
function ns.VendorList(db, kinds)
  local list = {}
  local ok, side = pcall(UnitFactionGroup, "player")
  local own = ok and PLAYER_FACTION[side] or nil
  for _, v in ipairs(ns.AMMO_VENDORS) do
    if FACTIONS[v[6]] and wanted(db, v[6], own) then
      local kind
      for _, item in ipairs(v[7]) do
        local info = ns.AMMO_ITEMS[item]
        if info and kinds[info[2]] then kind = kind or info[2] end
      end
      if kind then list[#list + 1] = { map = v[1], x = v[2] / 100, y = v[3] / 100, npc = v[4], name = v[5], faction = v[6], items = v[7], kind = kind } end
    end
  end
  return list
end

-- Where a spot on `from` lies on the map being shown, if `from` is that map or inside it.
local rects = {}
local function project(from, to, x, y)
  if from == to then return x, y, false end
  local key = from .. ":" .. to
  if rects[key] == nil then
    rects[key] = false
    -- Only maps that sit inside the shown one (a zone inside its continent, a city in its zone).
    local parent, inside = mapInfo(from), false
    for _ = 1, 4 do
      parent = parent and parent.parentMapID and mapInfo(parent.parentMapID)
      if parent and parent.mapID == to then inside = true break end
    end
    if inside and C_Map.GetMapRectOnMap then
      local ok, left, right, top, bottom = pcall(C_Map.GetMapRectOnMap, from, to)
      if ok and not ns.issecret(left) and type(left) == "number" and right > left and bottom > top then
        rects[key] = { left, right, top, bottom }
      end
    end
  end
  local r = rects[key]
  if not r then return nil end
  return r[1] + x * (r[2] - r[1]), r[3] + y * (r[4] - r[3]), true
end

-- Vendors closer than this (share of the map) share one pin, so pins never cover each other.
local MERGE, MERGE_SMALL = 0.012, 0.022

-- Pins for the map being shown: { vendors, x, y, small, open }. `small` pins sit on a map
-- that holds the vendor's own map (a city on its zone, a zone on its continent); clicking
-- one opens that map (`open`).
function ns.VendorPins(mapID, db, kinds)
  local pins = {}
  local info = mapInfo(mapID)
  local continent = info and Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Continent
  if continent and not db.vendorContinent then return pins end
  for _, v in ipairs(ns.VendorList(db, kinds)) do
    local home = mapFor(v.map)
    local x, y, outside = project(home, mapID, v.x, v.y)
    if x then
      local small = continent or outside
      local reach = small and MERGE_SMALL or MERGE
      local joined
      for _, pin in ipairs(pins) do
        -- Maps are about 1.5 times wider than tall.
        if pin.small == small and pin.vendors[1].faction == v.faction
          and ((pin.x - x) * 1.5) ^ 2 + (pin.y - y) ^ 2 <= reach ^ 2 then
          local n = #pin.vendors
          pin.x, pin.y = (pin.x * n + x) / (n + 1), (pin.y * n + y) / (n + 1)
          pin.vendors[n + 1] = v
          if pin.open ~= (outside and home or nil) then pin.open = nil end
          joined = true
          break
        end
      end
      if not joined then
        pins[#pins + 1] = { vendors = { v }, x = x, y = y, small = small, open = outside and home or nil }
      end
    end
  end
  return pins
end

local function setWaypoint(v)
  local mapID = mapFor(v.map)
  local ok = pcall(function()
    assert(C_Map.CanSetUserWaypointOnMap == nil or C_Map.CanSetUserWaypointOnMap(mapID))
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, v.x, v.y))
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
  end)
  if ok then
    ns.Say(string.format("Waypoint set: %s (%.1f, %.1f).", v.name, v.x * 100, v.y * 100))
  else
    ns.Say(string.format("%s is at %.1f, %.1f in %s.", v.name, v.x * 100, v.y * 100, ns.AMMO_MAPS[v.map] or "this zone"))
  end
end

local function itemNames(v)
  local out = {}
  for _, item in ipairs(v.items) do
    local info = ns.AMMO_ITEMS[item]
    if info then out[#out + 1] = info[1] end
  end
  return table.concat(out, ", ")
end

HunterShotTimerVendorPinMixin = CreateFromMixins and MapCanvasPinMixin and CreateFromMixins(MapCanvasPinMixin) or {}

function HunterShotTimerVendorPinMixin:OnLoad()
  if self.UseFrameLevelType then self:UseFrameLevelType("PIN_FRAME_LEVEL_HST_VENDOR") end
  self:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  self.Ring:SetTexture(WHITE)
  self.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  self.Hover:SetTexture(WHITE)
  self.Hover:SetVertexColor(1, 1, 1, 0.25)
end

function HunterShotTimerVendorPinMixin:OnAcquired(pin)
  self.pin = pin
  self.vendor = pin.vendors[1]
  local size = pin.small and CONTINENT_SIZE or PIN_SIZE
  self:SetSize(size, size)
  local c = FACTIONS[self.vendor.faction][2]
  self.Ring:SetVertexColor(c[1], c[2], c[3], 1)
  self.Icon:SetTexture(ICONS[self.vendor.kind])
  self.Count:SetText(#pin.vendors > 1 and #pin.vendors or "")
  self:SetPosition(pin.x, pin.y)
end

function HunterShotTimerVendorPinMixin:OnMouseEnter()
  local pin, v = self.pin, self.vendor
  local faction = FACTIONS[v.faction]
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if #pin.vendors == 1 then
    GameTooltip:AddLine(v.name, 1, 1, 1)
    GameTooltip:AddLine(faction[1], faction[2][1], faction[2][2], faction[2][3])
    for _, item in ipairs(v.items) do
      local info = ns.AMMO_ITEMS[item]
      if info then GameTooltip:AddDoubleLine(info[1], "level " .. info[3], 0.9, 0.9, 0.9, 0.6, 0.6, 0.6) end
    end
    local note = ns.AMMO_VENDOR_NOTES[v.npc]
    if note then GameTooltip:AddLine(note, 1, 0.5, 0.3, true) end
    GameTooltip:AddLine(string.format("%s  %.1f, %.1f", ns.AMMO_MAPS[v.map] or "", v.x * 100, v.y * 100), 0.6, 0.6, 0.6)
  else
    GameTooltip:AddLine(#pin.vendors .. " ammo vendors", 1, 1, 1)
    GameTooltip:AddLine(faction[1], faction[2][1], faction[2][2], faction[2][3])
    for _, each in ipairs(pin.vendors) do
      GameTooltip:AddLine(each.name, 0.9, 0.9, 0.9)
      GameTooltip:AddLine(itemNames(each), 0.6, 0.6, 0.6, true)
      local note = ns.AMMO_VENDOR_NOTES[each.npc]
      if note then GameTooltip:AddLine(note, 1, 0.5, 0.3, true) end
    end
  end
  if pin.open then
    GameTooltip:AddLine("Click: open " .. (ns.AMMO_MAPS[v.map] or "map"), 0.5, 0.8, 1)
  else
    GameTooltip:AddLine("Click: set a waypoint" .. (#pin.vendors > 1 and (" to " .. v.name) or ""), 0.5, 0.8, 1)
  end
  GameTooltip:Show()
end

function HunterShotTimerVendorPinMixin:OnMouseLeave()
  GameTooltip:Hide()
end

function HunterShotTimerVendorPinMixin:OnMouseClickAction()
  local map = self.pin.open and self.GetMap and self:GetMap()
  if map and map.SetMapID then
    map:SetMapID(self.pin.open)
  else
    setWaypoint(self.vendor)
  end
end

-- Minimap: the same vendors as small pins around you. Positions are compared in world
-- yards, so a vendor in Stormwind shows while you stand just outside it (and the other way
-- round). Hidden in combat: the game may lock your position then, and nobody shops mid-fight.

local MINI_SIZE = 14
local MINI_INTERVAL = 0.1
local miniPins, miniGroups = {}, {}
local miniList, miniDirty = nil, true

local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if not ok or ns.issecret(a) or ns.issecret(b) or ns.issecret(c) then return nil end
  return a, b, c
end

-- Map position -> continent and world yards (north, west).
local function worldPos(mapID, x, y)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
  local continent, pos = safe(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
  if not (continent and pos) then return nil end
  local north, west = safe(pos.GetXY, pos)
  if type(north) ~= "number" or type(west) ~= "number" then return nil end
  return continent, north, west
end

-- The vendors to show with their world positions, rebuilt when settings or the weapon change.
local function minimapList()
  if miniList and not miniDirty then return miniList end
  miniDirty = false
  miniList = {}
  for _, v in ipairs(ns.VendorList(ns.db, ns.VendorKinds(ns.db.vendorAmmo, ns.WeaponAmmo()))) do
    local continent, north, west = worldPos(mapFor(v.map), v.x, v.y)
    if continent then
      v.continent, v.north, v.west = continent, north, west
      miniList[#miniList + 1] = v
    end
  end
  return miniList
end

-- Yards east/south of you -> pixels from the minimap centre; nil when off the minimap.
function ns.MinimapPoint(east, south, radius, width, height, facing, shape, size)
  if not radius or radius <= 0 then return nil end
  local c, s = math.cos(facing or 0), math.sin(facing or 0)
  local x = (east * c - south * s) / radius * width / 2
  local y = (-east * s - south * c) / radius * height / 2
  local limitX, limitY = width / 2 - size / 2 - 2, height / 2 - size / 2 - 2
  if limitX <= 0 or limitY <= 0 then return nil end
  if shape == "SQUARE" then
    if math.abs(x) > limitX or math.abs(y) > limitY then return nil end
  elseif (x / limitX) ^ 2 + (y / limitY) ^ 2 > 1 then
    return nil
  end
  return x, y
end

local function miniPin(i)
  local pin = miniPins[i]
  if pin then return pin end
  pin = CreateFrame("Button", nil, Minimap)
  pin:SetSize(MINI_SIZE, MINI_SIZE)
  pin:SetFrameStrata("HIGH")
  pin:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 20)
  pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  pin.Ring = pin:CreateTexture(nil, "BACKGROUND")
  pin.Ring:SetAllPoints()
  pin.Icon = pin:CreateTexture(nil, "ARTWORK")
  pin.Icon:SetPoint("TOPLEFT", 2, -2)
  pin.Icon:SetPoint("BOTTOMRIGHT", -2, 2)
  pin.Count = pin:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  pin.Count:SetPoint("BOTTOMRIGHT", 5, -3)
  pin.Hover = pin:CreateTexture(nil, "HIGHLIGHT")
  pin.Hover:SetAllPoints()
  HunterShotTimerVendorPinMixin.OnLoad(pin)
  pin:SetScript("OnEnter", HunterShotTimerVendorPinMixin.OnMouseEnter)
  pin:SetScript("OnLeave", HunterShotTimerVendorPinMixin.OnMouseLeave)
  pin:SetScript("OnClick", function(self) setWaypoint(self.vendor) end)
  miniPins[i] = pin
  return pin
end

local function hideMinimapPins(from)
  for i = from, #miniPins do miniPins[i]:Hide() end
end

local function inCombat()
  local v = InCombatLockdown and InCombatLockdown()
  return ns.issecret(v) or v
end

function ns.UpdateMinimapPins()
  local db = ns.db
  if not (db and ns.isHunter and db.vendorMinimap and Minimap and Minimap:IsShown()) or inCombat() then
    return hideMinimapPins(1)
  end
  local map = C_Map and safe(C_Map.GetBestMapForUnit, "player")
  local pos = map and safe(C_Map.GetPlayerMapPosition, map, "player")
  local px, py
  if pos then px, py = safe(pos.GetXY, pos) end
  local continent, north, west
  if px and py then continent, north, west = worldPos(map, px, py) end
  local radius = C_Minimap and safe(C_Minimap.GetViewRadius)
  if not continent or type(radius) ~= "number" then return hideMinimapPins(1) end
  local facing = 0
  local rotate = safe((C_CVar and C_CVar.GetCVar) or GetCVar, "rotateMinimap") == "1"
  if rotate then
    facing = safe(GetPlayerFacing)
    if type(facing) ~= "number" then return hideMinimapPins(1) end
  end
  local width, height = Minimap:GetWidth(), Minimap:GetHeight()
  local shape = safe(GetMinimapShape) or "ROUND"

  -- Vendors on the minimap, close ones (same side) sharing a pin.
  local count = 0
  for _, v in ipairs(minimapList()) do
    if v.continent == continent then
      local x, y = ns.MinimapPoint(west - v.west, north - v.north, radius, width, height, facing, shape, MINI_SIZE)
      if x then
        local joined
        for i = 1, count do
          local g = miniGroups[i]
          if g.vendors[1].faction == v.faction and (g.x - x) ^ 2 + (g.y - y) ^ 2 <= (MINI_SIZE * 0.9) ^ 2 then
            g.vendors[#g.vendors + 1] = v
            joined = true
            break
          end
        end
        if not joined then
          count = count + 1
          local g = miniGroups[count] or { vendors = {} }
          miniGroups[count] = g
          for k in pairs(g.vendors) do g.vendors[k] = nil end
          g.vendors[1], g.x, g.y, g.small = v, x, y, false
        end
      end
    end
  end
  for i = 1, count do
    local g, pin = miniGroups[i], miniPin(i)
    pin.pin, pin.vendor = g, g.vendors[1]
    local c = FACTIONS[pin.vendor.faction][2]
    pin.Ring:SetVertexColor(c[1], c[2], c[3], 1)
    pin.Icon:SetTexture(ICONS[pin.vendor.kind])
    pin.Count:SetText(#g.vendors > 1 and #g.vendors or "")
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", Minimap, "CENTER", g.x, g.y)
    pin:Show()
  end
  hideMinimapPins(count + 1)
  ns.minimapPinCount = count
end

function ns.AttachVendorMinimap()
  if ns.minimapUpdater or not Minimap then return end
  local updater = CreateFrame("Frame", nil, UIParent)
  local wait = 0
  updater:SetScript("OnUpdate", function(_, dt)
    wait = wait - dt
    if wait > 0 then return end
    wait = MINI_INTERVAL
    local ok, err = pcall(ns.UpdateMinimapPins)
    if not ok then
      hideMinimapPins(1)
      if ns.minimapError ~= tostring(err) then
        ns.minimapError = tostring(err)
        ns.Say("Ammo vendor minimap pins failed: " .. ns.minimapError)
      end
    end
  end)
  ns.minimapUpdater = updater
end

local provider
function ns.RefreshVendorPins()
  miniDirty = true
  if provider and provider:GetMap() then provider:RefreshAllData() end
end

function ns.AttachVendorMap()
  if provider or not (WorldMapFrame and WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin) then return end
  local levels = WorldMapFrame.GetPinFrameLevelsManager and WorldMapFrame:GetPinFrameLevelsManager()
  if levels and not (levels.InsertFrameLevelAbove and levels:InsertFrameLevelAbove("PIN_FRAME_LEVEL_HST_VENDOR", "PIN_FRAME_LEVEL_VIGNETTE")) then
    levels:AddFrameLevel("PIN_FRAME_LEVEL_HST_VENDOR")
  end
  provider = CreateFromMixins(MapCanvasDataProviderMixin)
  function provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
  end
  function provider:RefreshAllData()
    self:RemoveAllData()
    local db = ns.db
    if not (db and ns.isHunter and db.vendorPins) then return end
    local map = self:GetMap()
    local ok, err = pcall(function()
      for _, pin in ipairs(ns.VendorPins(map:GetMapID(), db, ns.VendorKinds(db.vendorAmmo, ns.WeaponAmmo()))) do
        map:AcquirePin(TEMPLATE, pin)
      end
    end)
    if not ok and ns.vendorError ~= tostring(err) then
      ns.vendorError = tostring(err)
      ns.Say("Ammo vendor map pins failed: " .. ns.vendorError)
    end
  end
  if WorldMapFrame.SetPinTemplateType then WorldMapFrame:SetPinTemplateType(TEMPLATE, "BUTTON") end
  WorldMapFrame:AddDataProvider(provider)
end
