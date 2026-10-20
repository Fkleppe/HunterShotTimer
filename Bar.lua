local addonName, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DEMO_SPEED = 3.0
local DEMO_SHOTS = 4
local DEMO_AMMO = { count = "|cff40d8601200|r", percent = "|cffa6d96a60%|r" }
local DEMO_AMMO_ICON = 132382 -- Rough Arrow
local RANGE_INTERVAL = 0.1
local BLEND_TIME = 0.2 -- switching between shot, melee and "too close" glides over this long
local CLOSE_HOLD = 0.2 -- "too close" must hold this long before the bar changes over (and back)
local LATENCY_INTERVAL = 5
local DAMAGE_INTERVAL = 2
local GAP = 4 -- between text and the bar

local RANGE = {
  ["in"] = { "In range", { 0.36, 0.82, 0.47 } },
  close = { "Too close", { 1.00, 0.66, 0.20 } },
  far = { "Out of range", { 0.96, 0.40, 0.29 } },
}
-- An overdue shot held up by range, not by moving: standing still will not help.
local LATE_RANGE = { close = "TOO CLOSE", far = "OUT OF RANGE" }
local MUTED = { 0.62, 0.64, 0.67 }

local function text(parent, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetJustifyH(justify)
  fs:SetWordWrap(false)
  return fs
end

-- Widgets are built once; ns.ApplyLayout sizes, places and colours them from ns.db.

-- Container: always shown so it can drive updates; its two parts fade in and out.
local frame = CreateFrame("Frame", "HunterShotTimerFrame", UIParent)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
ns.frame = frame

-- Timer part: the bar with its status, countdown and info text.
local timer = CreateFrame("Frame", nil, frame)
timer:SetAllPoints()
timer:SetAlpha(0)
timer:Hide()
ns.timer = timer

local bar = CreateFrame("StatusBar", nil, timer)
bar:SetMinMaxValues(0, 1)
ns.bar = bar

local track = bar:CreateTexture(nil, "BACKGROUND")
track:SetAllPoints()

-- The end of the swing, where you must stand still.
local zone = bar:CreateTexture(nil, "BACKGROUND", nil, 1)
local divider = bar:CreateTexture(nil, "OVERLAY")
divider:SetColorTexture(1, 1, 1, 0.55)

-- A faint highlight along one edge gives a flat bar a little depth.
local sheen = bar:CreateTexture(nil, "OVERLAY")
sheen:SetColorTexture(1, 1, 1, 0.08)

local spark = bar:CreateTexture(nil, "OVERLAY", nil, 2)
spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
spark:SetBlendMode("ADD")

-- Brief flash across the bar when a shot fires.
local flash = bar:CreateTexture(nil, "OVERLAY", nil, 3)
flash:SetAllPoints()
flash:SetColorTexture(1, 1, 1, 1)
flash:SetBlendMode("ADD")
flash:SetAlpha(0)
local flashAlpha = 0

-- 1 px border just outside the bar, drawn as textures so the spark stays on top of it.
local borderEdges = {}
for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", -1, 1, 1, 1, true }, { "BOTTOMLEFT", "BOTTOMRIGHT", -1, -1, 1, -1, true },
                     { "TOPLEFT", "BOTTOMLEFT", -1, 1, -1, -1 }, { "TOPRIGHT", "BOTTOMRIGHT", 1, 1, 1, -1 } }) do
  local t = bar:CreateTexture(nil, "BORDER")
  t:SetColorTexture(0, 0, 0, 1)
  t:SetPoint(e[1], bar, e[1], e[3], e[4])
  t:SetPoint(e[2], bar, e[2], e[5], e[6])
  if e[7] then t:SetHeight(1) else t:SetWidth(1) end
  borderEdges[#borderEdges + 1] = t
end

local status = text(timer, "LEFT")
local countdown = text(timer, "RIGHT")
local info = text(timer, "LEFT") -- weapon speed and shots to kill

-- Ammo: the equipped arrows' icon and a small value, in its own fixed slot.
local ammoIcon = timer:CreateTexture(nil, "OVERLAY")
ammoIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local ammoText = text(timer, "LEFT")

-- Range part: its own frame so it can show while the timer is hidden.
local range = CreateFrame("Frame", nil, frame)
range:SetAlpha(0)
range:Hide()
ns.range = range
local rangeText = text(range, "LEFT")
local dot = range:CreateTexture(nil, "OVERLAY")
dot:SetTexture(WHITE)

-- For tests and /hst debugging.
ns.ui = { status = status, countdown = countdown, info = info, ammoText = ammoText, ammoIcon = ammoIcon, rangeText = rangeText, dot = dot, zone = zone }

local function setFont(fs, size)
  local db = ns.db
  -- Modern clients return false for a font they cannot load; older ones return nothing.
  if fs:SetFont(db.font, size, db.outline) == false then fs:SetFont(ns.FONTS[1][1], size, db.outline) end
  local shadow = db.outline == ""
  fs:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
  fs:SetShadowColor(0, 0, 0, shadow and 0.9 or 0)
end

local vertical = false
local barLength = 0 -- along the fill direction
local infoShare = false -- info and range share the row under the bar
local rangeReserve = 0 -- room kept for the range text next to the info
local lastLabel, shownSpeed, shownWindow, shownInfo, shownAmmo
-- What each widget shows now, so a frame only touches widgets whose content changed.
local shown = {}

-- Switching between modes (Auto Shot, melee, too close) is never a hard cut: over
-- BLEND_TIME the fill glides to its new place, the colour and the stand-still window
-- follow, and the texts dip out and back in with the new words at the halfway point.
-- `blend` runs 0 -> 1 during a switch and stays 1 otherwise, so a steady bar pays nothing.
local mode, prevMode -- what the bar shows now, and before the current switch
local blend = 1
local from = { value = 0, colour = { 1, 1, 1, 1 }, zone = 0, label = nil }
local shownValue, shownZone = 0, 0
local shownColour = { 1, 1, 1, 1 }
local mix = { 1, 1, 1, 1 }
local textAlpha, infoFits = 1, true
local function smooth(t) return t * t * (3 - 2 * t) end

local function setTextAlpha(a)
  textAlpha = a
  status:SetAlpha(a)
  countdown:SetAlpha(a)
  info:SetAlpha(infoFits and a or 0)
end

-- Every text has a fixed slot, so nothing can run into anything else: a text too long
-- for its slot is cut off with "...", never drawn over its neighbour.
--
--   text above:  [STATUS..........][icon 62%][ 0.7]
--                [=========bar==========|#####]
--                [2.80s  ~4 shots....][■ In range 20-25 yd]
--   one row:     [STATUS][====bar====|##][ 0.7][icon 62%]   info / range underneath
--   vertical:    bar | STATUS, 0.7, icon 62%, range stacked at the top, info at the bottom
function ns.ApplyLayout()
  local db = ns.db
  local layout = db.layout
  vertical = layout == "vertical"
  local width, thick, font, small = db.width, db.barHeight, db.fontSize, db.smallFontSize
  local ammoOn = db.ammoDisplay ~= "off"
  local showInfo = db.showSpeed or db.showShots
  local rangeBelow = db.rangeEnabled and not vertical and (db.rangePosition == "belowRight" or db.rangePosition == "belowLeft")
  infoShare = showInfo and rangeBelow
  local statusW = math.ceil(font * 6)         -- "OUT OF RANGE"
  local countW = math.ceil(font * 2.2)        -- "10.0"
  local ammoTextW = math.ceil(small * 3.0)    -- "100%" / "1200"
  local ammoW = small + 3 + ammoTextW
  local dotSize = math.max(4, math.floor(small * 0.5))

  frame:SetAlpha(db.opacity / 100)
  bar:SetStatusBarTexture(db.texture)
  bar:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
  track:SetColorTexture(unpack(db.colors.track))
  zone:SetColorTexture(unpack(db.colors.zone))
  for _, t in ipairs(borderEdges) do t:SetShown(db.showBorder) end
  for _, fs in ipairs({ status, countdown }) do setFont(fs, font) end
  for _, fs in ipairs({ info, rangeText, ammoText }) do setFont(fs, small) end
  countdown:SetTextColor(unpack(db.colors.text))
  info:SetTextColor(unpack(MUTED))
  status:SetShown(db.showStatus)
  countdown:SetShown(db.showCountdown)
  info:SetShown(showInfo)
  ammoText:SetShown(ammoOn)
  ammoIcon:SetShown(ammoOn)
  ammoIcon:SetSize(small, small)
  ammoText:SetWidth(ammoTextW)
  rangeText:SetShown(db.rangeText or db.rangeDistance ~= "off")
  dot:SetSize(dotSize, dotSize)
  range:SetSize(1, small)

  bar:ClearAllPoints()
  zone:ClearAllPoints()
  divider:ClearAllPoints()
  sheen:ClearAllPoints()
  range:ClearAllPoints()
  dot:ClearAllPoints()
  rangeText:ClearAllPoints()
  ammoIcon:ClearAllPoints()
  for _, fs in ipairs({ status, countdown, info, ammoText }) do fs:ClearAllPoints() end

  -- The ammo slot: icon then value, starting at `x, y` from the frame's top left.
  local function placeAmmo(point, relative, relPoint, x, y)
    ammoIcon:SetPoint(point, relative, relPoint, x, y)
    ammoText:SetPoint("LEFT", ammoIcon, "RIGHT", 3, 0)
  end

  if vertical then
    -- Upright bar filling bottom to top, stand-still window at the top, text to the right.
    barLength = width
    local textW = math.max(statusW, math.ceil(small * 11))
    local x = thick + 6
    frame:SetSize(x + textW, width)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    bar:SetSize(thick, width)
    zone:SetPoint("TOPLEFT")
    zone:SetPoint("TOPRIGHT")
    divider:SetHeight(1)
    divider:SetPoint("LEFT", zone, "BOTTOMLEFT")
    divider:SetPoint("RIGHT", zone, "BOTTOMRIGHT")
    sheen:SetWidth(1)
    sheen:SetPoint("TOPLEFT")
    sheen:SetPoint("BOTTOMLEFT")
    spark:SetRotation(math.pi / 2)
    spark:SetSize(thick * 2.4, math.max(6, thick * 1.2))
    -- Stack from the top: status, countdown, ammo, range. Info sits at the bottom.
    local y = 0
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
    status:SetWidth(textW)
    if db.showStatus then y = y + font + 3 end
    countdown:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
    countdown:SetWidth(textW)
    countdown:SetJustifyH("LEFT")
    if db.showCountdown then y = y + font + 3 end
    placeAmmo("TOPLEFT", frame, "TOPLEFT", x, -y)
    if ammoOn then y = y + small + 3 end
    range:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
    dot:SetPoint("LEFT", range, "LEFT")
    rangeText:SetPoint("LEFT", dot, "RIGHT", 4, 0)
    info:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 0)
    info:SetWidth(textW)
    info:SetJustifyH("LEFT")
  else
    barLength = width
    zone:SetPoint("TOPRIGHT")
    zone:SetPoint("BOTTOMRIGHT")
    divider:SetWidth(1)
    divider:SetPoint("TOP", zone, "TOPLEFT")
    divider:SetPoint("BOTTOM", zone, "BOTTOMLEFT")
    sheen:SetHeight(1)
    sheen:SetPoint("TOPLEFT")
    sheen:SetPoint("TOPRIGHT")
    spark:SetRotation(0)
    spark:SetSize(math.max(6, thick * 1.2), thick * 2.4)
    countdown:SetWidth(countW)
    local leftExtra, rightExtra = 0, 0 -- row layout: text slots beside the bar
    local bottomH = (showInfo or rangeBelow) and (small + GAP) or 0
    if layout == "row" then
      local left = db.showStatus and (statusW + 6) or 0
      local right = (db.showCountdown and (countW + 6) or 0) + (ammoOn and (ammoW + 6) or 0)
      leftExtra, rightExtra = left, right
      local rowH = math.max(thick, font + 2)
      frame:SetSize(left + width + right, rowH + bottomH)
      bar:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -(rowH - thick) / 2)
      bar:SetSize(width, thick)
      status:SetPoint("RIGHT", bar, "LEFT", -6, 0)
      status:SetWidth(statusW)
      status:SetJustifyH("RIGHT")
      countdown:SetPoint("LEFT", bar, "RIGHT", 6, 0)
      countdown:SetJustifyH("LEFT")
      placeAmmo("LEFT", bar, "RIGHT", 6 + (db.showCountdown and (countW + 6) or 0), 0)
    else
      local topH = (db.showStatus or db.showCountdown or ammoOn) and (math.max(font, small) + GAP) or 0
      frame:SetSize(width, topH + thick + bottomH)
      bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -topH)
      bar:SetSize(width, thick)
      countdown:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, GAP)
      countdown:SetJustifyH("RIGHT")
      local countSlot = db.showCountdown and (countW + 8) or 0
      placeAmmo("BOTTOMLEFT", bar, "TOPRIGHT", -(countSlot + ammoW), GAP)
      local ammoSlot = ammoOn and (ammoW + 8) or 0
      status:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, GAP)
      status:SetWidth(math.max(1, width - countSlot - ammoSlot))
      status:SetJustifyH("LEFT")
    end
    -- Under the bar: info on one side, range on the other.
    local pos = db.rangePosition
    local infoRight = rangeBelow and pos == "belowLeft"
    info:SetPoint(infoRight and "TOPRIGHT" or "TOPLEFT", bar, infoRight and "BOTTOMRIGHT" or "BOTTOMLEFT", 0, -GAP)
    info:SetJustifyH(infoRight and "RIGHT" or "LEFT")
    info:SetWidth(width)
    local leftwards = pos == "belowRight" or pos == "left"
    if pos == "belowRight" then range:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -GAP)
    elseif pos == "belowLeft" then range:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -GAP)
    elseif pos == "left" then range:SetPoint("RIGHT", bar, "LEFT", -6 - leftExtra, 0)
    else range:SetPoint("LEFT", bar, "RIGHT", 6 + rightExtra, 0) end
    if leftwards then
      -- [dot text]|
      rangeText:SetPoint("RIGHT", range, "RIGHT")
      if rangeText:IsShown() then dot:SetPoint("RIGHT", rangeText, "LEFT", -4, 0) else dot:SetPoint("RIGHT", range, "RIGHT") end
    else
      -- |[dot text]
      dot:SetPoint("LEFT", range, "LEFT")
      rangeText:SetPoint("LEFT", dot, "RIGHT", 4, 0)
    end
  end

  -- Force colours, sizes and text to refresh on the next frame (a switch in progress just lands).
  lastLabel, shownSpeed, shownWindow, shownInfo, shownAmmo, shownZone = nil, nil, nil, nil, nil, nil
  shown = {}
  rangeReserve = 0
  blend = 1
  setTextAlpha(1)
end

-- Info shares its row with the range check: give it only the width the range text leaves.
local function fitInfo(rangeVisible)
  if not infoShare then
    infoFits = true
    info:SetAlpha(textAlpha)
    return
  end
  local used = 0
  if rangeVisible then
    used = dot:GetWidth() + 10
    if rangeText:IsShown() then used = used + (rangeText:GetStringWidth() or 0) + 4 end
  end
  -- Keep the room for the range text steady: "~23 yd" and "~28 yd" are not quite the same
  -- width, and the info must not jump each time the distance changes. It only follows when
  -- the range text grows, or gets a lot shorter.
  if used > rangeReserve or used < rangeReserve - ns.db.smallFontSize * 2 then rangeReserve = used end
  local room = barLength - rangeReserve
  -- Too narrow to say anything useful: leave the row to the range check.
  local fits = room >= (ns.db.smallFontSize * 2)
  info:SetWidth(math.max(1, room))
  infoFits = fits
  info:SetAlpha(fits and textAlpha or 0)
end

-- The stand-still window at the end of the bar; `window` 0 hides it (melee has none).
-- During a switch it slides from its old size to the new one.
local function setSpeed(speed, window)
  window = window or ns.Window()
  local size
  if blend < 1 then
    local goal = barLength * math.min(window, speed) / speed
    size = from.zone + (goal - from.zone) * smooth(blend)
  else
    if speed == shownSpeed and window == shownWindow then return end
    shownSpeed, shownWindow = speed, window
    size = barLength * math.min(window, speed) / speed
  end
  if size == shownZone then return end
  shownZone = size
  if vertical then zone:SetHeight(math.max(1, size)) else zone:SetWidth(math.max(1, size)) end
  zone:SetShown(size >= 0.5)
  divider:SetShown(size >= 0.5)
end

-- "2.80s   ~4 shots", each part only when it is switched on and known. Rebuilt only when
-- the speed or the shot count changes, not every frame.
local function setInfo(speed, shots, melee)
  local db = ns.db
  speed = db.showSpeed and speed or nil
  shots = db.showShots and shots or nil
  if speed == shown.infoSpeed and shots == shown.infoShots and melee == shown.infoMelee and shownInfo then return end
  shown.infoSpeed, shown.infoShots, shown.infoMelee = speed, shots, melee
  local s = speed and string.format(melee and "%.2fs melee" or "%.2fs", speed) or ""
  if shots then
    s = s .. (speed and "   " or "") .. string.format("~%d shot%s", shots, shots == 1 and "" or "s")
  end
  if s ~= shownInfo then
    shownInfo = s
    info:SetText(s)
  end
end

local function setAmmo(value, icon)
  if value ~= shownAmmo then
    shownAmmo = value
    ammoText:SetText(value or "")
    ammoIcon:SetAlpha(value and 1 or 0)
  end
  if icon ~= shown.ammoIcon then
    shown.ammoIcon = icon
    ammoIcon:SetTexture(icon)
  end
end

-- Two reusable colour objects for the gradient, so a switch's per-frame colour glide
-- creates no garbage.
local gradLow, gradHigh
local function gradient(tex, direction, r1, g1, b1, r2, g2, b2, a)
  if not gradLow then gradLow, gradHigh = CreateColor(0, 0, 0, 1), CreateColor(0, 0, 0, 1) end
  gradLow:SetRGBA(r1, g1, b1, a)
  gradHigh:SetRGBA(r2, g2, b2, a)
  tex:SetGradient(direction, gradLow, gradHigh)
end

local function fill(colour)
  local r, g, b, a = colour[1], colour[2], colour[3], colour[4] or 1
  shownColour[1], shownColour[2], shownColour[3], shownColour[4] = r, g, b, a
  local tex = bar:GetStatusBarTexture()
  local direction = vertical and "VERTICAL" or "HORIZONTAL"
  if ns.db.gradient and CreateColor and tex.SetGradient then
    tex:SetVertexColor(1, 1, 1, 1)
    gradient(tex, direction, r * 0.72, g * 0.72, b * 0.72, r, g, b, a)
  else
    if CreateColor and tex.SetGradient then
      -- Clear any earlier gradient so the flat colour shows as picked.
      gradient(tex, direction, 1, 1, 1, 1, 1, 1, 1)
    end
    bar:SetStatusBarColor(r, g, b, a)
    tex:SetVertexColor(r, g, b, a)
  end
end

local rangeState, rangeWait, shots, ammo = nil, 0, nil, nil

-- Draw one state of the bar: fill, spark, status text and colour, countdown (nil = none).
-- `key` tells states with the same text apart (a late "TOO CLOSE" shot vs. melee range).
local function paint(now, value, left, label, colour, key, pulse)
  -- Mid-switch: glide fill and colour from where they were; the old texts stay up
  -- (fading out) until halfway, then the new ones fade in.
  local swapped = blend >= 0.5
  if blend < 1 then
    local e = smooth(blend)
    value = from.value + (value - from.value) * e
    local c = from.colour
    for i = 1, 3 do mix[i] = c[i] + (colour[i] - c[i]) * e end
    mix[4] = colour[4] or 1
    fill(mix)
    status:SetTextColor(mix[1], mix[2], mix[3])
    -- Same words before and after (a held-up "TOO CLOSE" shot becoming melee range's
    -- "TOO CLOSE"): only the colour glides, the text does not blink.
    setTextAlpha(label == from.label and 1 or math.abs(1 - 2 * blend))
  end
  shownValue = value
  bar:SetValue(value)
  if vertical then
    spark:SetPoint("CENTER", bar, "BOTTOM", 0, barLength * value)
  else
    spark:SetPoint("CENTER", bar, "LEFT", barLength * value, 0)
  end
  if key ~= lastLabel and swapped then
    lastLabel, shown.label = key, label
    status:SetText(label)
    if blend >= 1 then
      fill(colour)
      status:SetTextColor(colour[1], colour[2], colour[3])
    end
  end
  -- Overdue shot: pulse the spark so it reads as "waiting on you".
  if ns.db.showSpark ~= shown.spark then
    shown.spark = ns.db.showSpark
    spark:SetShown(shown.spark)
  end
  if pulse then
    spark:SetAlpha(0.45 + 0.45 * math.sin(now * 9))
    shown.sparkPulse = true
  elseif shown.sparkPulse ~= false then
    shown.sparkPulse = false
    spark:SetAlpha(0.9)
  end
  -- The countdown shows tenths: new text ten times a second, not every frame.
  local tenths = left and math.floor(left * 10 + 0.5) or -1
  if tenths ~= shown.tenths and swapped then
    shown.tenths = tenths
    countdown:SetText(tenths < 0 and "" or string.format("%.1f", tenths / 10))
  end
end

-- Auto Shot: move, stand still, or late (held up by moving or range).
-- With movement known, the end of the swing follows what you actually do: moving where you
-- must stand still says STOP, and standing still counts down to the real shot, which comes
-- a full stand-still window after you stopped if you stopped late.
local function render(now, lastShot, speed, demo)
  setSpeed(speed)
  local phase, value, left = ns.Phase(now, lastShot, speed)
  local late = phase == "late"
  local label, pulse = "STAND STILL", late
  if phase == "move" then
    label = "MOVE"
  elseif late and LATE_RANGE[rangeState] then
    label, left = LATE_RANGE[rangeState], nil
  elseif ns.move.known and not demo then
    if ns.move.moving then
      label, left, pulse = "STOP", nil, true
    else
      left = ns.ShotIn(now, lastShot, speed)
      pulse = not left or left <= 0
      if pulse then left = nil end
    end
  elseif late then
    left = nil
  end
  local colour = phase == "move" and ns.db.colors.move or ns.db.colors.stand
  paint(now, value, left, label, colour, label, pulse)
  return phase
end

-- Melee: time to your next main-hand swing (Raptor Strike goes off with it).
local function renderMelee(now)
  local m = ns.melee
  setSpeed(m.speed or 1, 0)
  local value, left = ns.MeleePhase(now)
  paint(now, value, left, "MELEE", ns.db.colors.melee, "melee", false)
end

-- In melee range without swinging: Auto Shot cannot fire, so say so and keep the bar up.
local function renderClose(now)
  setSpeed(ns.state.speed or 1)
  paint(now, 0, nil, "TOO CLOSE", ns.db.colors.stand, "close", false)
end

local function showRange(state, distance)
  local r = RANGE[state]
  local label = ns.db.rangeText and r[1] or nil
  local text = label and distance and (label .. "  " .. distance) or label or distance or ""
  if text ~= shown.rangeText then
    shown.rangeText = text
    rangeText:SetText(text)
  end
  if state ~= shown.rangeState then
    shown.rangeState = state
    rangeText:SetTextColor(r[2][1], r[2][2], r[2][3])
    dot:SetVertexColor(r[2][1], r[2][2], r[2][3])
  end
end

-- Ease a part toward shown or hidden; hidden parts stop drawing. A part that has arrived
-- (fully shown or hidden) is left alone.
local alpha = {}
local function fade(part, visible, dt)
  local a = alpha[part] or 0
  local goal = visible and 1 or 0
  if a == goal and (part:IsShown() == visible) then return end
  a = a + (goal - a) * math.min(1, dt * 14)
  if visible then
    if a > 0.98 then a = 1 end
    if not part:IsShown() then part:Show() end
  elseif a < 0.02 then
    a = 0
    part:Hide()
  end
  alpha[part] = a
  part:SetAlpha(a)
end

local function inCombat()
  local v = UnitAffectingCombat and UnitAffectingCombat("player")
  return not ns.issecret(v) and v and true or false
end

-- End a switch: hand back to the cached (change-only) drawing with full texts and the
-- final colour, window and countdown.
local function landBlend()
  blend = 1
  lastLabel, shownSpeed, shown.tenths = nil, nil, nil
  setTextAlpha(1)
end

-- Start gliding to `new`. A bar that is not on screen yet just shows the new mode: its
-- own fade-in is the transition.
local function switchTo(new)
  if new == mode then return end
  if mode and timer:IsShown() and (alpha[timer] or 0) > 0.05 then
    blend = 0
    from.value, from.zone, from.label = shownValue, shownZone or 0, shown.label
    for i = 1, 4 do from.colour[i] = shownColour[i] end
  elseif blend < 1 then
    landBlend() -- a switch cut short must not leave the texts half faded
  end
  prevMode, mode = mode, new
end

local function advanceBlend(dt)
  if blend >= 1 then return end
  blend = blend + dt / BLEND_TIME
  if blend > 0.999 then landBlend() end
end

-- The range check flips between "too close" and "in range" right at the edge of melee;
-- the bar only follows once it has held for CLOSE_HOLD, so it never flickers there.
local closeHeld, closeTime = false, 0
local function holdClose(dt)
  if (rangeState == "close") == closeHeld then
    closeTime = 0
    return
  end
  closeTime = closeTime + dt
  if closeTime >= CLOSE_HOLD then closeHeld, closeTime = not closeHeld, 0 end
end

local latencyWait, damageWait = 0, 0
frame:SetScript("OnUpdate", function(_, dt)
  if not ns.db then return end
  local db = ns.db
  local now = GetTime()
  latencyWait = latencyWait - dt
  if latencyWait <= 0 then
    latencyWait = LATENCY_INTERVAL
    if GetNetStats then
      local ok, _, _, _, world = pcall(GetNetStats)
      if ok then ns.SetLatency(world) end
    end
  end
  damageWait = damageWait - dt
  if damageWait <= 0 then
    damageWait = DAMAGE_INTERVAL
    ns.UpdateShotDamage()
  end
  if flashAlpha > 0 then
    flashAlpha = math.max(0, flashAlpha - dt * 2.2)
    flash:SetAlpha(flashAlpha)
  end

  if ns.unlocked then
    rangeState = nil
    switchTo("shot")
    advanceBlend(dt)
    render(now, now - now % DEMO_SPEED, DEMO_SPEED, true)
    setInfo(DEMO_SPEED, DEMO_SHOTS)
    setAmmo(DEMO_AMMO[db.ammoDisplay], ns.ammo.icon or DEMO_AMMO_ICON)
    fitInfo(db.rangeEnabled)
    showRange("in", ns.FormatDistance(db.rangeDistance, 20, 25))
    fade(timer, true, dt)
    fade(range, db.rangeEnabled, dt)
    return
  end

  local s = ns.state
  local active = false
  local melee = ns.isHunter and db.showMelee
  if ns.isHunter then ns.PollMovement(now) end
  holdClose(dt)
  local meleeOn = melee and ns.MeleeActive(now, closeHeld and "close" or nil)
  if meleeOn then
    -- Swinging in melee: the bar times your melee swings instead of fading away.
    switchTo("melee")
    advanceBlend(dt)
    renderMelee(now)
    active = true
  elseif melee and closeHeld and inCombat() and not s.shooting then
    -- Too close to shoot and not swinging: say so instead of fading away.
    switchTo("close")
    advanceBlend(dt)
    renderClose(now)
    active = true
  elseif s.lastShot then
    -- Keep the bar while Auto Shot is on; once it is off, let the current swing finish
    -- (and keep drawing it while it fades).
    switchTo("shot")
    advanceBlend(dt)
    active = render(now, s.lastShot, s.speed) ~= "late" or s.shooting
  elseif blend < 1 then
    -- Nothing left to show mid-switch (the fight ended): land it, so the next time the
    -- bar shows it starts clean instead of finishing an old glide.
    landBlend()
  end
  fade(timer, active, dt)

  rangeWait = rangeWait - dt
  if rangeWait <= 0 then
    rangeWait = RANGE_INTERVAL
    if not db.rangeEnabled or not ns.isHunter or (db.rangeCombatOnly and not inCombat()) then
      rangeState = nil
    else
      -- A failing range API must never stop the timer; /hst range shows the error.
      local ok, result = pcall(ns.TargetRange)
      if ok then rangeState = result else rangeState, ns.rangeError = nil, result end
    end
    if rangeState then
      local distance
      if db.rangeDistance ~= "off" then
        local lo, hi = ns.Bracket(ns.RangeAnswers(), rangeState)
        distance = ns.FormatDistance(db.rangeDistance, lo, hi)
      end
      showRange(rangeState, distance)
    end
    local ok, result = pcall(ns.ShotsToKill)
    shots = db.showShots and ok and result or nil
    local okAmmo, text = pcall(ns.AmmoText, db.ammoDisplay)
    ammo = okAmmo and text or nil
    setAmmo(ammo, ns.ammo.icon)
    fitInfo(rangeState ~= nil)
  end
  -- Shots to kill counts Auto Shots, so it is left out while you fight in melee. Mid-switch
  -- the old line stays until the texts swap.
  local meleeText = (blend >= 0.5 and mode or prevMode) == "melee"
  setInfo(meleeText and ns.melee.speed or s.speed, not meleeText and shots or nil, meleeText)
  fade(range, rangeState ~= nil and (active or db.rangeWhenIdle), dt)
end)

frame:SetScript("OnDragStart", function(self) if ns.unlocked then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, relativePoint, x, y = self:GetPoint()
  ns.db.point = { point, relativePoint, x, y }
end)

function ns.ApplyPosition()
  local p = ns.db.point
  frame:ClearAllPoints()
  if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("CENTER", UIParent, "CENTER", 0, -180) end
end

function ns.Say(msg) print("|cffabd473Hunter Shot Timer|r " .. msg) end

-- Unlocked: a looping demo you can drag. The options window unlocks while it is open.
function ns.SetUnlocked(on)
  ns.unlocked = on
  frame:EnableMouse(on)
end

local function report(title, lines)
  ns.Say(title)
  for _, line in ipairs(lines) do print("  " .. line) end
end

SLASH_HUNTERSHOTTIMER1 = "/hst"
SlashCmdList.HUNTERSHOTTIMER = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "reset" then
    ns.db.point = nil
    ns.ApplyPosition()
    ns.Say("Position reset.")
  elseif msg == "range" then
    report("Range check:", ns.RangeReport())
  elseif msg == "timing" then
    report("Auto Shot timing (stand still and shoot first):", ns.TimingReport())
  elseif msg == "probe" then
    report("Shots to kill (run this mid-fight):", ns.ProbeReport())
  elseif msg == "lock" or msg == "unlock" or msg == "move" then
    if msg == "lock" then ns.SetUnlocked(false) elseif msg == "unlock" then ns.SetUnlocked(true) else ns.SetUnlocked(not ns.unlocked) end
    ns.Say(ns.unlocked and "Unlocked: drag the bar where you want it. Type /hst lock to lock." or "Locked.")
  elseif ns.ToggleOptions then
    ns.ToggleOptions()
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("START_AUTOREPEAT_SPELL")
events:RegisterEvent("STOP_AUTOREPEAT_SPELL")
pcall(events.RegisterEvent, events, "PLAYER_SWING")
for _, e in ipairs({ "PLAYER_ENTER_COMBAT", "PLAYER_LEAVE_COMBAT", "PLAYER_REGEN_ENABLED" }) do pcall(events.RegisterEvent, events, e) end
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:SetScript("OnEvent", function(_, event, a, b)
  if event == "PLAYER_SWING" then
    -- a = swing duration, b = Enum.PlayerSwingType (2 = ranged)
    if ns.isHunter and not ns.issecret(b) and b == 2 then
      ns.OnShot(GetTime(), a)
      if ns.db and ns.db.showFlash then flashAlpha = 0.35 end
    elseif ns.isHunter and not ns.issecret(b) and b == 0 then
      ns.OnMeleeSwing(GetTime(), a)
      if ns.db and ns.db.showFlash and ns.db.showMelee then flashAlpha = 0.25 end
    end
  elseif event == "PLAYER_ENTER_COMBAT" then
    ns.melee.attacking = ns.isHunter -- melee auto-attack switched on
  elseif event == "PLAYER_LEAVE_COMBAT" or event == "PLAYER_REGEN_ENABLED" then
    ns.melee.attacking = false
  elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
    ns.RefreshAmmo()
    -- A new bow or gun changes which vendors "Match my weapon" shows.
    if event == "PLAYER_EQUIPMENT_CHANGED" and a == 18 and ns.RefreshVendorPins then ns.RefreshVendorPins() end
  elseif event == "START_AUTOREPEAT_SPELL" then
    ns.state.shooting, ns.state.gapBroken = true, true
  elseif event == "STOP_AUTOREPEAT_SPELL" then
    ns.state.shooting = false
  elseif event == "PLAYER_ENTERING_WORLD" then
    local _, class = UnitClass("player")
    ns.isHunter = class == "HUNTER"
    ns.state.lastShot, ns.state.shooting = nil, false
    ns.gaps = {}
    ns.melee.lastSwing, ns.melee.speed, ns.melee.attacking = nil, nil, false
    ns.UpdateShotDamage()
    ns.RefreshAmmo()
    if ns.AttachVendorMap then ns.AttachVendorMap() end
    if ns.AttachVendorMinimap then ns.AttachVendorMinimap() end
  elseif event == "ADDON_LOADED" and a == addonName then
    local _, class = UnitClass("player")
    ns.isHunter = class == "HUNTER"
    if ns.LoadRangeItems then ns.LoadRangeItems() end
    HunterShotTimerDB = ns.InitDB(HunterShotTimerDB)
    ns.ApplyLayout()
    ns.ApplyPosition()
    if ns.CreateOptions then ns.CreateOptions() end
  end
end)
