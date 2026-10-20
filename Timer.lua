local _, ns = ...

-- Forever fires Auto Shot after you have stood still for about half a second at the
-- end of the weapon swing. Before that you can move freely.
ns.STAND = 0.5
ns.AUTO_SHOT = 75
-- Your "stopped moving" reaches the server one ping later, so the window grows by it.
ns.latency = 0
ns.MAX_LATENCY = 0.25

-- Every value from the client is checked with this before it is compared or tested:
-- on Forever, comparing a secret value throws.
local issecret = issecretvalue or function() return false end
ns.issecret = issecret

-- Stand-still window: the engine's half second, plus your ping and your own fine-tuning.
function ns.Window()
  local db = ns.db or ns.DEFAULTS
  local w = ns.STAND + (db.addPing and ns.latency or 0) + db.windowExtra / 1000
  return math.max(0.1, w)
end

-- World latency in ms from GetNetStats; ignored when secret or nonsense.
function ns.SetLatency(ms)
  if issecret(ms) or type(ms) ~= "number" or ms ~= ms or ms < 0 then return end
  ns.latency = math.min(ns.MAX_LATENCY, ms / 1000)
end

-- Where the shot cycle is at time `now`.
-- Returns phase ("move" / "stand" / "late"), bar fill 0-1, and seconds left in the phase.
-- "late" means the swing is over but no shot has fired yet (you moved, or are out of range;
-- since the 16 October build Auto Shot keeps firing while you cast Aimed Shot):
-- keep standing still until it does.
function ns.Phase(now, lastShot, speed)
  local elapsed = now - lastShot
  local stand = math.min(ns.Window(), speed)
  local moveUntil = speed - stand
  if elapsed < moveUntil then return "move", elapsed / speed, moveUntil - elapsed end
  if elapsed < speed then return "stand", elapsed / speed, speed - elapsed end
  return "late", 1, 0
end

-- gapBroken: something besides the swing came between this shot and the last one (a
-- melee swing, which puts Auto Shot on cooldown, or Auto Shot switched off and on), so
-- /hst timing leaves that gap out.
ns.state = { lastShot = nil, speed = nil, shooting = false, gapBroken = false }

-- Are you moving, and since when have you stood still? Read from the client every frame
-- (GetUnitSpeed, IsFalling), so the bar knows instead of guessing. `known` stays false on a
-- client that hides these: the bar then works from the swing time alone, as before.
ns.move = { known = false, moving = false, stillSince = nil }

function ns.OnMovement(now, moving)
  local m = ns.move
  m.known = true
  if moving then
    m.moving, m.stillSince = true, nil
    -- /hst timing only trusts gaps where you stood still the whole time.
    if ns.state.lastShot then ns.state.moved = true end
  else
    if m.moving or not m.stillSince then m.stillSince = now end
    m.moving = false
  end
end

local function plainNumber(v) return not issecret(v) and type(v) == "number" and v == v and v end

-- Polled from the bar's OnUpdate; a secret or missing answer means "unknown".
function ns.PollMovement(now)
  local speed = GetUnitSpeed and plainNumber(GetUnitSpeed("player"))
  if not speed then ns.move.known = false return end
  local falling = IsFalling and IsFalling()
  ns.OnMovement(now, speed > 0 or (not issecret(falling) and falling == true))
end

-- Seconds until the shot fires if you stay still: when the swing ends, but never sooner
-- than a full stand-still window after you stopped. nil while you move, or when
-- movement is not known.
function ns.ShotIn(now, lastShot, speed)
  local m = ns.move
  if not m.known or m.moving or not m.stillSince then return nil end
  return math.max(0, math.max(lastShot + speed, m.stillSince + ns.Window()) - now)
end

-- The last few gaps between Auto Shots, next to the speed the game reported, for
-- /hst timing: since the 16 October beta build Auto Shot needs 0.5 s of standing still,
-- and these show whether that half second sits inside the swing (gap = speed) or comes
-- on top of it (gap = speed + 0.5).
ns.gaps = {}
local MAX_GAPS = 10

-- PLAYER_SWING carries the real ranged speed of every shot, haste included.
function ns.OnShot(now, duration)
  if issecret(duration) or type(duration) ~= "number" or duration ~= duration or duration <= 0 or duration > 10 then return end
  local s = ns.state
  if s.lastShot and s.speed and not s.gapBroken then
    table.insert(ns.gaps, { gap = now - s.lastShot, speed = s.speed, moved = s.moved })
    if #ns.gaps > MAX_GAPS then table.remove(ns.gaps, 1) end
  end
  s.lastShot, s.speed, s.gapBroken, s.moved = now, duration, false, false
end

-- Gaps longer than this past the speed were held up (moving, out of range): left out.
ns.HELD_UP = 1.2

-- /hst timing: the measured gaps and what they say about the bar.
function ns.TimingReport()
  local lines, extra, n = {}, 0, 0
  for i, g in ipairs(ns.gaps) do
    local over = g.gap - g.speed
    local held = over > ns.HELD_UP
    local note = g.moved and " - you moved, left out" or held and " - held up, left out" or ""
    lines[#lines + 1] = string.format("%d. %.2f s apart, speed %.2f s (%+.2f s)%s", i, g.gap, g.speed, over, note)
    if not held and not g.moved then extra, n = extra + over, n + 1 end
  end
  if n < 3 then
    lines[#lines + 1] = "Not enough shots yet: stand still and let Auto Shot fire 6 times, then type /hst timing."
    return lines
  end
  extra = extra / n
  if extra < 0.15 then
    lines[#lines + 1] = string.format("Shots come %.2f s after the speed on average: the half second is inside the swing. The bar is right.", extra)
  elseif extra > 0.35 and extra < 0.75 then
    lines[#lines + 1] = string.format("Shots come %.2f s after the speed on average: the half second is added on top of the swing. The bar needs a change.", extra)
  else
    lines[#lines + 1] = string.format("Shots come %.2f s after the speed on average: unclear. Stand still and try again.", extra)
  end
  return lines
end

-- Melee: main-hand swings (PLAYER_SWING type 0) while you auto-attack up close.
ns.melee = { lastSwing = nil, speed = nil, attacking = false }

function ns.OnMeleeSwing(now, duration)
  if issecret(duration) or type(duration) ~= "number" or duration ~= duration or duration <= 0 or duration > 10 then return end
  ns.melee.lastSwing, ns.melee.speed = now, duration
  ns.state.gapBroken = true
end

-- In melee? A melee swing within the last swing time (+ a little, in case the "attack
-- stopped" event never comes) that is newer than your last Auto Shot: whatever happened
-- last wins, so stepping back and shooting brings the shot bar back at once. Before the
-- first swing, melee auto-attack being on counts too, but only with Auto Shot off and the
-- target too close to shoot (`range` == "close"): right-clicking a target far away also
-- switches melee attack on, and that must not turn the bar into MELEE. Auto Shot back on
-- with melee attack off (you stepped out, or the game's auto-switch swapped back) ends
-- melee at once, without waiting for the first shot.
function ns.MeleeActive(now, range)
  local m, s = ns.melee, ns.state
  if s.shooting and not m.attacking then return false end
  if m.lastSwing and now - m.lastSwing < m.speed + 0.5 and not (s.lastShot and s.lastShot > m.lastSwing) then
    return true
  end
  return m.attacking and not s.shooting and range == "close"
end

-- Bar fill 0-1 and seconds to the next melee swing; nil before the first swing.
function ns.MeleePhase(now)
  local m = ns.melee
  if not m.lastSwing then return 0, nil end
  local elapsed = now - m.lastSwing
  return math.min(1, elapsed / m.speed), math.max(0, m.speed - elapsed)
end

-- Range to the target from two plain answers: is Auto Shot in range, and is the target
-- within ~10 yd (interact distance). Auto Shot fails both inside the 8 yd dead zone and
-- past 35 yd, so "close" tells the two apart. nil = nothing to show.
function ns.Range(inRange, close)
  if issecret(inRange) or inRange == nil then return nil end
  if inRange == true or inRange == 1 then return "in" end
  if not issecret(close) and close then return "close" end
  return "far"
end

local function plain(v) return not issecret(v) and v end

-- Each way the client may answer "is Auto Shot in range": by spell ID, by name, or the
-- legacy global. The first non-nil answer wins.
ns.rangeSources = {
  { "C_Spell id 75", function() return C_Spell.IsSpellInRange(ns.AUTO_SHOT, "target") end },
  { "C_Spell 'Auto Shot'", function() return C_Spell.IsSpellInRange("Auto Shot", "target") end },
  { "IsSpellInRange 'Auto Shot'", function() return IsSpellInRange("Auto Shot", "target") end },
}

local function autoShotInRange()
  for _, source in ipairs(ns.rangeSources) do
    local ok, v = pcall(source[2])
    if ok and (issecret(v) or v ~= nil) then return v end
  end
end

function ns.TargetRange()
  if not plain(UnitExists("target")) or plain(UnitIsDeadOrGhost("target")) then return nil end
  -- A secret answer in combat counts as hostile, so the check stays up in fights.
  local hostile = UnitCanAttack("player", "target")
  if not issecret(hostile) and not hostile then return nil end
  local inRange = autoShotInRange()
  if issecret(inRange) or inRange == nil or inRange == true or inRange == 1 then return ns.Range(inRange) end
  local ok, close = pcall(CheckInteractDistance, "target", 3)
  return ns.Range(inRange, ok and close)
end

-- /hst range: every raw answer the range check depends on, for a target in front of you.
function ns.RangeReport()
  local function show(ok, v)
    if not ok then return "error: " .. tostring(v) end
    if issecret(v) then return "secret" end
    return tostring(v)
  end
  local lines = {}
  local function add(label, fn) lines[#lines + 1] = label .. " = " .. show(pcall(fn)) end
  add("target exists", function() return UnitExists("target") end)
  add("target dead", function() return UnitIsDeadOrGhost("target") end)
  add("can attack", function() return UnitCanAttack("player", "target") end)
  for _, source in ipairs(ns.rangeSources) do add(source[1], source[2]) end
  add("within ~10 yd", function() return CheckInteractDistance("target", 3) end)
  add("result", ns.TargetRange)
  if ns.rangeError then lines[#lines + 1] = "last error = " .. tostring(ns.rangeError) end
  return lines
end
