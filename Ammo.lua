local _, ns = ...

-- Ammo left: the equipped arrows or bullets, as a count or as a percentage of what your
-- quiver or ammo pouch holds. Without one, the percentage is of the most you have had
-- since you last restocked.

ns.AMMO_MODES = {
  { "off", "Off" },
  { "percent", "Percent (62%)" },
  { "count", "Count (1234)" },
}

local AMMO_SLOT = 0
local QUIVER_CLASS = 11 -- Enum.ItemClass.Quiver
local PROJECTILE_CLASS, ARROW, BULLET = 6, 2, 3
-- Colour by how full you are: { lowest percent, colour }, checked top down.
ns.AMMO_BANDS = {
  { 70, "ff40d860" }, -- green
  { 50, "ffa6d96a" }, -- softer green
  { 30, "ffffc04d" }, -- light orange
  { 15, "ffff8c2e" }, -- orange
  { 0, "fff23a3a" }, -- red
}
local NO_SHARE = "ff9ea3aa" -- grey, while there is nothing to compare with yet

function ns.AmmoColour(percent)
  if not percent then return NO_SHARE end
  for _, band in ipairs(ns.AMMO_BANDS) do
    if percent >= band[1] then return band[2] end
  end
  return ns.AMMO_BANDS[#ns.AMMO_BANDS][2]
end

ns.ammo = { capacity = nil, peak = 0, last = nil, kind = "Ammo", icon = nil }

local function plainNumber(v)
  return not ns.issecret(v) and type(v) == "number" and v or nil
end

function ns.AmmoCount()
  if not GetInventoryItemCount then return nil end
  local ok, n = pcall(GetInventoryItemCount, "player", AMMO_SLOT)
  return ok and plainNumber(n) or nil
end

local function itemInfo(id)
  if not (id and C_Item and C_Item.GetItemInfoInstant) then return nil end
  local ok, _, _, _, _, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, id)
  if ok then return classID, subclassID end
end

-- Arrows or Bullets, from the equipped ammo.
local function ammoKind()
  local ok, id = pcall(GetInventoryItemID, "player", AMMO_SLOT)
  local classID, subclassID = itemInfo(ok and id)
  if classID == PROJECTILE_CLASS then
    if subclassID == ARROW then return "Arrows" end
    if subclassID == BULLET then return "Bullets" end
  end
  return "Ammo"
end

-- Slots in equipped quivers / ammo pouches times the ammo's stack size.
local function quiverCapacity()
  if not (C_Container and C_Container.GetContainerNumSlots and C_Container.ContainerIDToInventoryID) then return nil end
  local okAmmo, ammoID = pcall(GetInventoryItemID, "player", AMMO_SLOT)
  local stack = 200
  if okAmmo and ammoID and C_Item.GetItemMaxStackSizeByID then
    local ok, s = pcall(C_Item.GetItemMaxStackSizeByID, ammoID)
    stack = ok and plainNumber(s) or stack
  end
  local slots = 0
  for bag = 1, 4 do
    local okInv, invSlot = pcall(C_Container.ContainerIDToInventoryID, bag)
    local okId, bagID = pcall(GetInventoryItemID, "player", okInv and invSlot or -1)
    if okId and bagID and itemInfo(bagID) == QUIVER_CLASS then
      local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
      slots = slots + (okN and plainNumber(n) or 0)
    end
  end
  return slots > 0 and slots * stack or nil
end

-- Bags or ammo changed: look again at the quiver and what kind of ammo is equipped.
function ns.RefreshAmmo()
  ns.ammo.capacity = quiverCapacity()
  ns.ammo.kind = ammoKind()
  local ok, icon = pcall(GetInventoryItemTexture, "player", AMMO_SLOT)
  ns.ammo.icon = ok and not ns.issecret(icon) and icon or nil
end

-- Share of a full load: of the quiver when there is one, else of the restock peak.
function ns.AmmoShare(count)
  local a = ns.ammo
  -- More than last time means you restocked: that is the new full load.
  if not a.last or count > a.last then a.peak = count end
  a.last = count
  local full = a.capacity or a.peak
  if not full or full <= 0 then return nil end
  return math.min(1, count / full)
end

-- Asked ten times a second; the text is rebuilt only when something in it changed.
local cache = {}
function ns.AmmoText(mode)
  if mode == "off" then return nil end
  local count = ns.AmmoCount()
  if not count then return nil end
  local a = ns.ammo
  if cache.text and cache.count == count and cache.mode == mode and cache.capacity == a.capacity
    and cache.peak == a.peak and cache.icon == a.icon and cache.kind == a.kind then
    return cache.text
  end
  local share = ns.AmmoShare(count)
  -- The colour follows the percentage you would see, also when showing the count.
  local percent = share and math.floor(share * 100 + 0.5)
  if count == 0 then percent = 0 end
  local colour = ns.AmmoColour(percent)
  local value = (mode == "percent" and percent) and string.format("%d%%", percent) or tostring(count)
  -- The ammo icon says arrows or bullets; without one, say it in words.
  if not ns.ammo.icon then value = ns.ammo.kind .. " " .. value end
  cache.text = string.format("|c%s%s|r", colour, value)
  cache.count, cache.mode, cache.capacity, cache.peak, cache.icon, cache.kind = count, mode, a.capacity, a.peak, a.icon, a.kind
  return cache.text
end
