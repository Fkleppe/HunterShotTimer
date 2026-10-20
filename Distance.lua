local _, ns = ...

-- WoW gives addons no exact distance to an enemy. What it does answer, also in combat, is
-- "is this item usable on the target from here" for items with a known range. Asking that
-- for 5, 10, 15 ... 45 yd items narrows the distance to a 5 yd bracket.
-- Item IDs from LibRangeCheck-3.0 (MIT), its Classic Era hostile list, which Forever uses.
ns.RANGE_ITEMS = {
  { 5, { 8149, 15826, 16308, 17117 } },
  { 10, { 9606, 9618, 9619, 9620 } },
  { 15, { 4559 } },
  { 20, { 1191, 2012, 4388, 10645 } },
  { 25, { 13289 } },
  { 30, { 835, 1404, 1434, 1444 } },
  { 35, { 1258, 1399, 1402, 8688 } },
  { 40, { 4945, 8348 } },
  { 45, { 221316 } },
  { 100, { 5418, 17162, 23715, 23718 } },
}

ns.DISTANCE_MODES = {
  { "off", "Off" },
  { "bracket", "Range (20-25 yd)" },
  { "estimate", "Number (~23 yd)" },
}

-- Range checks answer nil until the client has the item cached; ask for all at login.
function ns.LoadRangeItems()
  if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
  for _, entry in ipairs(ns.RANGE_ITEMS) do
    for _, id in ipairs(entry[2]) do pcall(C_Item.RequestLoadItemDataByID, id) end
  end
end

local function itemInRange(id)
  local check = C_Item and C_Item.IsItemInRange or IsItemInRange
  if not check then return nil end
  local ok, v = pcall(check, id, "target")
  if not ok or ns.issecret(v) or v == nil then return nil end
  return v == true or v == 1
end

-- One answer per range step: the first of its items the client can answer for.
-- The same table is refilled on every call (ten times a second).
local answers = {}
function ns.RangeAnswers()
  for k in pairs(answers) do answers[k] = nil end
  for _, entry in ipairs(ns.RANGE_ITEMS) do
    for _, id in ipairs(entry[2]) do
      local v = itemInRange(id)
      if v ~= nil then answers[entry[1]] = v; break end
    end
  end
  return answers
end

-- From {yards = in range?} to the bracket [lo, hi]; hi is nil when it is further than 45 yd.
-- The Auto Shot state sharpens the 5-10 step at the 8 yd dead-zone edge.
function ns.Bracket(answers, autoShot)
  if not next(answers) then return nil end
  local lo, hi = 0, nil
  for _, entry in ipairs(ns.RANGE_ITEMS) do
    local yards, v = entry[1], answers[entry[1]]
    if v == true and not hi then hi = yards end
    if v == false and (not hi or yards < hi) and yards > lo then lo = yards end
  end
  if hi == 100 then hi = nil end -- "45-100" says less than "45+"
  if autoShot == "close" then hi, lo = 8, math.min(lo, 5) end
  if autoShot == "in" then
    -- Auto Shot reaches it, so it is 8 yd or more, whatever a stale item answer says.
    if lo < 8 then lo = 8 end
    if hi and hi <= 8 then hi = 10 end
  end
  if lo == 0 and not hi then return nil end -- only the 100 yd step answered: says nothing
  if hi and lo >= hi then lo = hi - 5 end -- answers that disagree mid-crossing
  return lo, hi
end

function ns.FormatDistance(mode, lo, hi)
  if mode == "off" or lo == nil then return nil end
  if not hi then return string.format("%d+ yd", lo) end
  if mode == "estimate" then return string.format("~%d yd", math.floor((lo + hi) / 2 + 0.5)) end
  return string.format("%d-%d yd", lo, hi)
end
