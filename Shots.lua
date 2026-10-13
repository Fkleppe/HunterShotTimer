local _, ns = ...

-- Estimated Auto Shots to kill the target: target health divided by your average shot.
-- The shot comes from your character sheet numbers (weapon, ammo and ranged attack
-- power); armor and crits are left out, so it is an estimate. Forever hides enemy health
-- from addons when it is secret, and then nothing is shown (/hst probe tells you).

ns.shotDamage = nil

-- Average ranged hit the way the character sheet works it out.
function ns.AverageShot(minDamage, maxDamage, posBuff, negBuff, percent)
  for _, v in ipairs({ minDamage, maxDamage, posBuff, negBuff, percent }) do
    if ns.issecret(v) or type(v) ~= "number" or v ~= v then return nil end
  end
  local avg = ((minDamage + maxDamage) / 2 + posBuff + negBuff) * percent
  return avg > 0 and avg or nil
end

-- Read while the numbers are plain (out of combat); the cached value carries into fights.
function ns.UpdateShotDamage()
  if not UnitRangedDamage then return end
  local ok, _, minDamage, maxDamage, posBuff, negBuff, percent = pcall(UnitRangedDamage, "player")
  if not ok then return end
  local avg = ns.AverageShot(minDamage, maxDamage, posBuff or 0, negBuff or 0, percent or 1)
  if avg then ns.shotDamage = avg end
end

-- Shots from plain health numbers; nil when anything is secret or only a percentage.
function ns.ShotsFrom(health, maxHealth, shot)
  if ns.issecret(health) or ns.issecret(maxHealth) then return nil end
  if type(health) ~= "number" or type(maxHealth) ~= "number" or not shot or shot <= 0 then return nil end
  if health <= 0 then return nil end
  -- Classic-style clients report enemy health as 0-100 percent, which says nothing about
  -- how many hits it takes.
  if maxHealth == 100 then return nil end
  return math.ceil(health / shot)
end

function ns.ShotsToKill()
  if not ns.shotDamage then return nil end
  local okH, health = pcall(UnitHealth, "target")
  local okM, maxHealth = pcall(UnitHealthMax, "target")
  if not (okH and okM) then return nil end
  return ns.ShotsFrom(health, maxHealth, ns.shotDamage)
end

-- /hst probe: what the client lets us read for the estimate. Best run mid-fight.
function ns.ProbeReport()
  local function show(ok, v)
    if not ok then return "error: " .. tostring(v) end
    if ns.issecret(v) then return "secret" end
    return tostring(v)
  end
  local lines = {}
  local function add(label, fn) lines[#lines + 1] = label .. " = " .. show(pcall(fn)) end
  add("in combat", function() return UnitAffectingCombat("player") end)
  add("target health", function() return UnitHealth("target") end)
  add("target max health", function() return UnitHealthMax("target") end)
  add("UnitHealthPercent exists", function() return UnitHealthPercent ~= nil end)
  add("C_CurveUtil exists", function() return C_CurveUtil ~= nil end)
  add("ranged min damage", function() return select(2, UnitRangedDamage("player")) end)
  add("average shot (cached)", function() return ns.shotDamage and string.format("%.1f", ns.shotDamage) or "none yet" end)
  add("shots to kill", ns.ShotsToKill)
  return lines
end
