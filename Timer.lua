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
-- `need` and `early` override the measured numbers (the options demo uses the plain ones).
function ns.Phase(now, lastShot, speed, need, early)
  local elapsed = now - lastShot
  local cycle = speed + (early or ns.EarlyDelay())
  local stand = math.min(need or ns.StandNeed(), cycle)
  local moveUntil = cycle - stand
  if elapsed < moveUntil then return "move", elapsed / cycle, moveUntil - elapsed end
  if elapsed < cycle then return "stand", elapsed / cycle, cycle - elapsed end
  return "late", 1, 0
end

-- Measured on your own shots, so the stand-still time fits your ping and the server
-- instead of a guess:
--   stand: from the moment you stopped to the shot, when you stopped after the swing was
--          over (how long you must stand still);
--   early: from the end of the swing to the shot, when you stood still all along (0 when
--          the half second sits inside the swing, about 0.5 when it comes on top);
--   missed: from the end of the swing to the shot, when you stopped inside the stand-still
--          window but too late for it. Measured in game on 20 Oct 2026: always about half
--          a second after the swing, however close to the end you stopped.
-- The median of the last few is used once there are three. Kept in the saved settings.
ns.calib = { stand = {}, early = {}, missed = {} }
ns.MISSED = 0.5 -- the half second after the swing, until it is measured
local MAX_SAMPLES, MIN_SAMPLES = 9, 3

-- Asked several times a frame, so the answer is kept until the list changes (a new
-- sample, or a fresh list from the saved settings).
local sorted, cached = {}, setmetatable({}, { __mode = "k" })
local function median(list)
  local n = #list
  local c = cached[list]
  if c and c.n == n and c.last == list[n] then return c.value end
  local value
  if n >= MIN_SAMPLES then
    for i = 1, n do sorted[i] = list[i] end
    for i = n + 1, #sorted do sorted[i] = nil end
    table.sort(sorted)
    value = n % 2 == 1 and sorted[(n + 1) / 2] or (sorted[n / 2] + sorted[n / 2 + 1]) / 2
  end
  cached[list] = { n = n, last = list[n], value = value }
  return value
end

local function addSample(list, v)
  cached[list] = nil
  list[#list + 1] = v
  if #list > MAX_SAMPLES then table.remove(list, 1) end
end

-- How long you must stand still before a shot goes: measured, plus your own fine-tuning;
-- until there are enough shots, the half second plus ping.
function ns.StandNeed()
  local m = median(ns.calib.stand)
  if not m then return ns.Window() end
  local db = ns.db or ns.DEFAULTS
  return math.max(0.1, m + db.windowExtra / 1000)
end

function ns.EarlyDelay()
  local m = median(ns.calib.early)
  return m and math.max(0, m) or 0
end

function ns.MissedDelay()
  return median(ns.calib.missed) or ns.MISSED
end

-- The last shots as plain numbers, saved with the settings, so the timing can be checked
-- after a /reload without copying chat. One small row per shot, at most SHOT_LOG rows.
ns.shotLog = {}
local SHOT_LOG = 40
local function r3(v) return v and math.floor(v * 1000 + 0.5) / 1000 end

-- The attack speed changed inside the current swing (a haste proc such as Deadly Aspects,
-- Rapid Fire starting or running out): when, counted from the start of the swing. Logged with
-- the next shot, so the shot log shows whether the game speeds up a swing already under way
-- (then the bar must too) or only the next one (then the game's reported speed is enough).
function ns.OnSpeedChange(now)
  local s = ns.state
  if not s.lastShot then return end
  s.speedChanges = s.speedChanges or {}
  if #s.speedChanges < 4 then s.speedChanges[#s.speedChanges + 1] = r3(now - s.lastShot) end
end

local function logShot(now, s, duration)
  local m = ns.move
  local row = {
    t = r3(now),
    speed = r3(duration),
    ping = math.floor(ns.latency * 1000 + 0.5),
    known = m.known and (m.source == "events" and 2 or 1) or 0, -- 2: from the movement events
  }
  if s.lastShot and s.speed then
    row.gap = r3(now - s.lastShot)
    row.prev = r3(s.speed)
    row.afterSwing = r3(now - (s.lastShot + s.speed))
    row.broken = s.gapBroken and 1 or 0
    row.moved = s.moved and 1 or 0
    if s.speedChanges then row.haste = table.concat(s.speedChanges, ",") end
  end
  if m.known then
    row.still = m.moving and -1 or (m.stillSince and r3(now - m.stillSince)) or nil
  end
  local log = ns.shotLog
  log[#log + 1] = row
  while #log > SHOT_LOG do table.remove(log, 1) end
end

-- A shot just fired: if you were standing still for it, learn from it.
local function learn(now, s)
  local m = ns.move
  -- Held up by range during the swing: the delay is the target's, not the game's rule.
  -- Speed changed mid-swing: the swing's end is not where its reported speed says.
  if not (s.lastShot and s.speed) or s.gapBroken or s.held or s.speedChanges or ns.unlocked then return end
  if not m.known or m.moving or not m.stillSince then return end
  local swingEnd = s.lastShot + s.speed
  local stopBefore = swingEnd - m.stillSince -- how long before the swing end you stopped
  if stopBefore <= 0 then
    local v = now - m.stillSince
    if v >= 0.15 and v <= 1.2 then addSample(ns.calib.stand, v) end
  elseif stopBefore >= 0.8 then -- stood still through the whole window
    local v = now - swingEnd
    if v >= -0.1 and v <= ns.STAND + ns.MAX_LATENCY then addSample(ns.calib.early, v) end
  elseif stopBefore >= 0.1 and stopBefore <= ns.StandNeed() - 0.05 then -- stopped inside it, too late
    local v = now - swingEnd
    if v >= 0.2 and v <= 0.9 then addSample(ns.calib.missed, v) end
  end
end

-- gapBroken: something besides the swing came between this shot and the last one (a
-- melee swing, which puts Auto Shot on cooldown, or Auto Shot switched off and on), so
-- /hst timing leaves that gap out.
ns.state = { lastShot = nil, speed = nil, shooting = false, gapBroken = false }

-- Are you moving, and since when have you stood still? Two sources:
--   the game's PLAYER_STARTED_MOVING / PLAYER_STOPPED_MOVING events: plain signals, so
--     they work in combat too (Forever turns GetUnitSpeed secret in combat);
--   GetUnitSpeed / IsFalling every frame while they are plain (out of combat, and jumps).
-- `known` is false until one of them works: the bar then uses the swing time alone.
-- `source`: "events", "speed" or nil, for /hst moving and the shot log.
ns.move = { known = false, moving = false, stillSince = nil, events = false, source = nil, eventCount = 0 }

-- From the movement events. Once they have been seen, they are trusted in combat.
function ns.OnMoveEvent(now, moving)
  local m = ns.move
  m.events, m.eventCount, m.lastEvent = true, m.eventCount + 1, now
  m.source = "events"
  ns.OnMovement(now, moving)
  -- A stop event is a real stop, even if a missed start left us thinking you stood still.
  if not moving then m.stillSince = now end
end

-- A shot fired although we think you are moving, and no movement event came since the
-- shot before: you cannot have moved through a whole swing and still shot, so a stop
-- event was missed. (One shot while "moving" is normal: you set off just before the
-- shot's news reached you.)
local function healMovement(now, s)
  local m = ns.move
  if m.events and m.moving and s.lastShot and (m.lastEvent or 0) < s.lastShot then
    m.moving, m.stillSince = false, now
  end
end

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
  local m = ns.move
  local speed = GetUnitSpeed and plainNumber(GetUnitSpeed("player"))
  if not speed then
    -- Secret (in combat) or missing: the events carry on if they work, else unknown.
    m.known = m.events
    if not m.events then m.source = nil end
    return
  end
  local falling = IsFalling and IsFalling()
  if not m.events then m.source = "speed" end
  ns.OnMovement(now, speed > 0 or (not issecret(falling) and falling == true))
end

-- /hst moving: what each movement source answers right now.
function ns.MovementReport()
  local m = ns.move
  local function show(fn)
    if not fn then return "missing" end
    local ok, v = pcall(fn, "player")
    if not ok then return "error" end
    if issecret(v) then return "secret" end
    return tostring(v)
  end
  return {
    "GetUnitSpeed = " .. show(GetUnitSpeed),
    "IsFalling = " .. show(IsFalling),
    "movement events seen = " .. m.eventCount,
    "using = " .. (m.source or "nothing (the bar goes by the swing time alone)"),
    "you are " .. (not m.known and "unknown" or m.moving and "moving" or "standing still"),
  }
end

-- When the shot fires if you stay still, and when your standing for it began (the start of
-- the stand-still bar). nil while you move, or when movement is not known. Three cases, as
-- measured in game:
--   still before the stand-still window starts: on time, at the end of the swing;
--   stopped inside the window: about half a second after the end of the swing, however
--     late in the window you stopped;
--   stopped after the swing ended: the full stand-still time after you stopped.
function ns.ShotAt(lastShot, speed)
  local m = ns.move
  if not m.known or m.moving or not m.stillSince then return nil end
  local swingEnd, need = lastShot + speed, ns.StandNeed()
  local onTime = swingEnd + ns.EarlyDelay()
  if m.stillSince <= onTime - need then return onTime, onTime - need end
  local missed = swingEnd + ns.MissedDelay()
  if m.stillSince < swingEnd then return missed, m.stillSince end
  return math.max(missed, m.stillSince + need), m.stillSince
end

function ns.ShotIn(now, lastShot, speed)
  local at = ns.ShotAt(lastShot, speed)
  return at and math.max(0, at - now)
end

-- The stand-still bar: 0 -> 1 over exactly the time you must stand still, ending as the
-- shot goes. It starts when you stop, or when the stand-still part of the swing begins if
-- you were already standing. 0 while you move.
function ns.StandProgress(now, lastShot, speed)
  local at, start = ns.ShotAt(lastShot, speed)
  if not at then return 0 end
  local span = at - start
  if span <= 0 then return 1 end
  return math.max(0, math.min(1, (now - start) / span))
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
  healMovement(now, s)
  logShot(now, s, duration)
  learn(now, s)
  if s.lastShot and s.speed and not s.gapBroken and not s.speedChanges then
    table.insert(ns.gaps, { gap = now - s.lastShot, speed = s.speed, moved = s.moved })
    if #ns.gaps > MAX_GAPS then table.remove(ns.gaps, 1) end
  end
  s.lastShot, s.speed, s.gapBroken, s.moved, s.held, s.speedChanges = now, duration, false, false, false, nil
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
  local stand, early = median(ns.calib.stand), median(ns.calib.early)
  lines[#lines + 1] = stand
    and string.format("Measured stand-still time: %.2f s (from %d shots where you stopped late).", stand, #ns.calib.stand)
    or string.format("Stand-still time not measured yet (%d of 3 shots): stop after a swing ends and let the shot go. Using %.2f s.", #ns.calib.stand, ns.Window())
  if early then
    lines[#lines + 1] = string.format("Shot after the swing ends, standing still: %+.2f s (%d shots).", early, #ns.calib.early)
  end
  local missed = median(ns.calib.missed)
  if missed then
    lines[#lines + 1] = string.format("Stopped inside the window, too late: shot %+.2f s after the swing (%d shots).", missed, #ns.calib.missed)
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
