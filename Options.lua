-- Options window (/hst). While it is open the bar is unlocked: it loops a demo shot cycle
-- and can be dragged, so every change is visible as you make it.
local _, ns = ...

local W, H = 890, 540
local COL = 270 -- column width
local LEFT, MID, RIGHT = 16, 310, 604
local win
local controls = {}

local function changed()
  ns.ApplyLayout()
  if ns.RefreshVendorPins then ns.RefreshVendorPins() end
end

-- First template the client knows, else a plain frame (templates differ between clients).
local function createFrom(kind, name, parent, templates)
  for _, t in ipairs(templates) do
    local ok, f = pcall(CreateFrame, kind, name, parent, t)
    if ok and f then return f, t end
  end
  return CreateFrame(kind, name, parent)
end

local function label(parent, text, x, y, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetText(text)
  return fs
end

local function heading(parent, text, x, y)
  label(parent, text, x, y, "GameFontNormal")
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.25)
  line:SetPoint("TOPLEFT", x, y - 16)
  line:SetSize(COL, 1)
end

local function tooltip(widget, title, body)
  if not body then return end
  widget:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    GameTooltip:AddLine(body, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  widget:SetScript("OnLeave", GameTooltip_Hide)
end

local function checkbox(parent, text, x, y, key, tip)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", x, y)
  local t = cb.Text or cb.text
  if t then t:SetText("") end
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  fs:SetText(text)
  cb:SetScript("OnClick", function(self)
    ns.db[key] = self:GetChecked() and true or false
    changed()
  end)
  tooltip(cb, text, tip)
  cb.Refresh = function(self) self:SetChecked(ns.db[key]) end
  controls[#controls + 1] = cb
end

local function slider(parent, text, x, y, key, min, max, step, unit)
  label(parent, text, x, y, "GameFontHighlightSmall")
  local function set(v)
    v = math.floor(v / step + 0.5) * step
    if ns.db[key] ~= v then
      ns.db[key] = v
      changed()
    end
  end
  local fmt = function(v) return tostring(math.floor(v + 0.5)) .. (unit or "") end
  local s, template = createFrom("Frame", nil, parent, { "MinimalSliderWithSteppersTemplate" })
  if template and s.Init and MinimalSliderWithSteppersMixin then
    -- The slider with arrows the game's own settings use.
    s:SetPoint("TOPLEFT", x - 4, y - 14)
    s:SetSize(COL - 40, 20)
    s:Init(ns.db[key], min, max, (max - min) / step, { [MinimalSliderWithSteppersMixin.Label.Right] = fmt })
    s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v) set(v) end, s)
    s.Refresh = function(self) self:SetValue(ns.db[key]) end
    controls[#controls + 1] = s
    return
  end
  -- Older clients: the classic options slider and a value label.
  s:Hide()
  local bar = createFrom("Slider", nil, parent, { "OptionsSliderTemplate", "UISliderTemplate" })
  bar:SetPoint("TOPLEFT", x + 2, y - 18)
  bar:SetSize(COL - 60, 16)
  bar:SetOrientation("HORIZONTAL")
  bar:SetMinMaxValues(min, max)
  bar:SetValueStep(step)
  if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end
  for _, k in ipairs({ "Low", "High", "Text" }) do
    local fs = bar[k] or (bar:GetName() and _G[bar:GetName() .. k])
    if fs then fs:SetText("") end
  end
  local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  value:SetPoint("LEFT", bar, "RIGHT", 10, 0)
  bar:SetScript("OnValueChanged", function(_, v)
    value:SetText(fmt(v))
    set(v)
  end)
  bar.Refresh = function(self) self:SetValue(ns.db[key]); value:SetText(fmt(ns.db[key])) end
  controls[#controls + 1] = bar
end

-- A choice from a short list: [<]  value  [>]
local function stepper(parent, text, x, y, key, list)
  label(parent, text, x, y, "GameFontHighlightSmall")
  local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  value:SetPoint("TOP", parent, "TOPLEFT", x + COL / 2, y - 20)
  local function step(dir)
    ns.db[key] = ns.Step(list, ns.db[key], dir)
    value:SetText(ns.Label(list, ns.db[key]))
    changed()
  end
  for _, side in ipairs({ { "<", -1, 0 }, { ">", 1, COL - 28 } }) do
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(28, 22)
    b:SetPoint("TOPLEFT", x + side[3], y - 15)
    b:SetText(side[1])
    b:SetScript("OnClick", function() step(side[2]) end)
  end
  controls[#controls + 1] = { Refresh = function() value:SetText(ns.Label(list, ns.db[key])) end }
end

-- A choice from a list as the game's own dropdown; the [<] value [>] stepper where the
-- client has no such dropdown.
local function choice(parent, text, x, y, key, list)
  local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and dd and MenuUtil and MenuUtil.CreateRadioMenu then
    label(parent, text, x, y, "GameFontHighlightSmall")
    dd:SetPoint("TOPLEFT", x, y - 16)
    dd:SetWidth(COL - 10)
    local items = {}
    for _, item in ipairs(list) do items[#items + 1] = { item[2], item[1] } end
    MenuUtil.CreateRadioMenu(dd,
      function(value) return ns.db[key] == value end,
      function(value) ns.db[key] = value; changed() end,
      unpack(items))
    controls[#controls + 1] = { Refresh = function() if dd.GenerateMenu then dd:GenerateMenu() end end }
    return
  end
  if ok and dd then dd:Hide() end
  stepper(parent, text, x, y, key, list)
end

local function openColorPicker(colour, hasAlpha, apply)
  local r, g, b, a = colour[1], colour[2], colour[3], colour[4] or 1
  local function pick(restore)
    if restore then
      colour[1], colour[2], colour[3], colour[4] = r, g, b, a
    else
      colour[1], colour[2], colour[3] = ColorPickerFrame:GetColorRGB()
      if hasAlpha then
        colour[4] = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha()
          or (OpacitySliderFrame and 1 - OpacitySliderFrame:GetValue()) or colour[4]
      end
    end
    apply()
  end
  ColorPickerFrame:Hide()
  if ColorPickerFrame.SetupColorPickerAndShow then
    ColorPickerFrame:SetupColorPickerAndShow({
      r = r, g = g, b = b, opacity = a, hasOpacity = hasAlpha,
      swatchFunc = function() pick() end,
      opacityFunc = function() pick() end,
      cancelFunc = function() pick(true) end,
    })
  else
    ColorPickerFrame.func = function() pick() end
    ColorPickerFrame.opacityFunc = function() pick() end
    ColorPickerFrame.cancelFunc = function() pick(true) end
    ColorPickerFrame.hasOpacity, ColorPickerFrame.opacity = hasAlpha, 1 - a
    ColorPickerFrame:SetColorRGB(r, g, b)
    ColorPickerFrame:Show()
  end
end

local function swatch(parent, text, x, y, key, hasAlpha)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(18, 18)
  b:SetPoint("TOPLEFT", x, y)
  local edge = b:CreateTexture(nil, "BACKGROUND")
  edge:SetAllPoints()
  edge:SetColorTexture(0.6, 0.6, 0.6, 1)
  local fill = b:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", -1, 1)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", b, "RIGHT", 6, 0)
  fs:SetText(text)
  local function refresh()
    local c = ns.db.colors[key]
    fill:SetColorTexture(c[1], c[2], c[3], 1)
  end
  b:SetScript("OnClick", function()
    openColorPicker(ns.db.colors[key], hasAlpha, function() refresh(); changed() end)
  end)
  controls[#controls + 1] = { Refresh = refresh }
end

local function button(parent, text, width, point, x, y, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetPoint(point, x, y)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function refreshAll()
  for _, c in ipairs(controls) do c:Refresh() end
end

local function build()
  local template
  win, template = createFrom("Frame", "HunterShotTimerOptions", UIParent,
    { "DefaultPanelFlatTemplate", "BasicFrameTemplateWithInset" })
  win:SetSize(W, H)
  win:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  win:SetFrameStrata("DIALOG")
  win:SetToplevel(true)
  win:SetClampedToScreen(true)
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", win.StopMovingOrSizing)
  local title = "Hunter Shot Timer"
  if win.SetTitle then
    win:SetTitle(title)
  elseif win.TitleContainer then
    win.TitleContainer.TitleText:SetText(title)
  else
    local fs = win.TitleText or win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:ClearAllPoints()
    fs:SetPoint("TOP", 0, -5)
    fs:SetText(title)
  end
  if not template or not (win.NineSlice or win.Bg or win.Inset) then
    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.94)
  end
  if not win.CloseButton then
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
  end
  table.insert(UISpecialFrames, "HunterShotTimerOptions") -- Esc closes it

  -- Left column: layout and size, timing.
  local y = -34
  heading(win, "Layout & size", LEFT, y)
  y = y - 26
  choice(win, "Layout", LEFT, y, "layout", ns.LAYOUTS)
  y = y - 48
  slider(win, "Length", LEFT, y, "width", 100, 500, 5)
  y = y - 42
  slider(win, "Thickness", LEFT, y, "barHeight", 4, 40, 1)
  y = y - 42
  slider(win, "Opacity", LEFT, y, "opacity", 20, 100, 5, "%")
  y = y - 42
  slider(win, "Stand-still window adjust", LEFT, y, "windowExtra", -200, 300, 10, " ms")
  y = y - 46
  heading(win, "Timing", LEFT, y)
  y = y - 22
  checkbox(win, "Add my ping to the window", LEFT, y, "addPing",
    "Your 'stopped moving' reaches the server one ping later, so the red window grows by your world latency. Used until the addon has measured your real stand-still time on a few shots.")
  y = y - 34
  heading(win, "Ammo vendors on the map", LEFT, y)
  y = y - 22
  checkbox(win, "World map", LEFT, y, "vendorPins",
    "Every NPC that sells arrows or bullets, coloured by faction. Hover for what they sell, click for a waypoint.")
  checkbox(win, "Minimap", LEFT + COL / 2, y, "vendorMinimap",
    "The same vendors on the minimap when they are near you. Hidden in combat. Click one for a waypoint.")
  y = y - 24
  checkbox(win, "Continent maps", LEFT, y, "vendorContinent", "Also show them, smaller, on Kalimdor and the Eastern Kingdoms.")
  checkbox(win, "|cffffd140Neutral|r", LEFT + COL / 2, y, "vendorNeutral", "Goblin towns, Argent Dawn, Cenarion Circle and the like: open to both sides.")
  y = y - 24
  checkbox(win, "Other faction", LEFT, y, "vendorOtherFaction",
    "Also show the other side's vendors. They will not sell to you. Your own side is always shown.")
  y = y - 30
  choice(win, "Vendors that sell", LEFT, y, "vendorAmmo", ns.VENDOR_AMMO)

  -- Middle column: text and colours.
  y = -34
  heading(win, "Text", MID, y)
  y = y - 26
  choice(win, "Font", MID, y, "font", ns.FONTS)
  y = y - 48
  choice(win, "Text style", MID, y, "outline", ns.OUTLINES)
  y = y - 48
  slider(win, "Font size", MID, y, "fontSize", 8, 28, 1)
  y = y - 42
  slider(win, "Small font size (info, range)", MID, y, "smallFontSize", 6, 20, 1)
  y = y - 46
  heading(win, "Colors", MID, y)
  y = y - 24
  swatch(win, "Move", MID, y, "move")
  swatch(win, "Stand still", MID + COL / 2, y, "stand")
  y = y - 24
  swatch(win, "Window", MID, y, "zone", true)
  swatch(win, "Background", MID + COL / 2, y, "track", true)
  y = y - 24
  swatch(win, "Countdown", MID, y, "text")
  swatch(win, "Melee", MID + COL / 2, y, "melee")
  y = y - 30
  choice(win, "Bar texture", MID, y, "texture", ns.TEXTURES)

  -- Right column: what to show, range check.
  y = -34
  heading(win, "Show", RIGHT, y)
  y = y - 22
  checkbox(win, "Status text", RIGHT, y, "showStatus", "MOVE / STAND STILL / STOP.")
  checkbox(win, "Countdown", RIGHT + COL / 2, y, "showCountdown", "Seconds left in the current phase.")
  y = y - 24
  checkbox(win, "Weapon speed", RIGHT, y, "showSpeed", "Your ranged speed from the last shot, haste included.")
  checkbox(win, "Shots to kill", RIGHT + COL / 2, y, "showShots",
    "Estimated Auto Shots to kill your target: its health divided by your average shot (armor and crits left out). Shown only when the game lets addons read the target's health; /hst probe tells you.")
  y = y - 24
  checkbox(win, "Spark", RIGHT, y, "showSpark")
  checkbox(win, "Flash on shot", RIGHT + COL / 2, y, "showFlash")
  y = y - 24
  checkbox(win, "Border", RIGHT, y, "showBorder")
  checkbox(win, "Gradient fill", RIGHT + COL / 2, y, "gradient")
  y = y - 24
  checkbox(win, "Melee & too close", RIGHT, y, "showMelee",
    "In melee range the bar stays up: while you swing it times your melee swings (MELEE, handy for Raptor Strike); otherwise it tells you to back off (TOO CLOSE).")
  checkbox(win, "Stand-still bar", RIGHT + COL / 2, y, "showStandBar",
    "A slim second bar under the main one. Red: stand still; it fills from the moment you must stand (or the moment you stop, if you stop late) and is full as the arrow or bullet leaves. Then it turns solid green: the shot is away, move. The time is measured on your own shots; /hst timing shows it. Colours follow Move and Stand still.")
  y = y - 30
  choice(win, "Ammo left", RIGHT, y, "ammoDisplay", ns.AMMO_MODES)

  y = y - 52
  heading(win, "Range check", RIGHT, y)
  y = y - 22
  checkbox(win, "Enabled", RIGHT, y, "rangeEnabled", "In range / Too close (dead zone) / Out of range for a hostile target.")
  checkbox(win, "Show text", RIGHT + COL / 2, y, "rangeText", "In range / Too close / Out of range. Off: only the coloured dot and the distance.")
  y = y - 24
  checkbox(win, "Only in combat", RIGHT, y, "rangeCombatOnly")
  checkbox(win, "When not shooting", RIGHT + COL / 2, y, "rangeWhenIdle", "Also show it while Auto Shot is off, so you can check before you pull.")
  y = y - 30
  choice(win, "Position (horizontal layouts)", RIGHT, y, "rangePosition", ns.RANGE_POSITIONS)
  y = y - 48
  choice(win, "Distance to target", RIGHT, y, "rangeDistance", ns.DISTANCE_MODES)

  button(win, "Reset position", 120, "BOTTOMLEFT", 16, 14, function()
    ns.db.point = nil
    ns.ApplyPosition()
  end)
  button(win, "Reset all settings", 140, "BOTTOMLEFT", 144, 14, function()
    ns.ResetDB()
    changed() -- the vendor pins follow the reset vendor settings
    refreshAll()
  end)
  button(win, "Done", 90, "BOTTOMRIGHT", -16, 14, function() win:Hide() end)
  local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOM", 0, 42)
  hint:SetText("Drag the bar to move it while this window is open.")

  win:SetScript("OnShow", function()
    refreshAll()
    ns.SetUnlocked(true)
  end)
  win:SetScript("OnHide", function() ns.SetUnlocked(false) end)
  win:Hide()
end

-- Options > AddOns > Hunter Shot Timer: a button that opens this window.
function ns.CreateOptions()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and CreateSettingsButtonInitializer) then return end
  local ok = pcall(function()
    local cat, layout = Settings.RegisterVerticalLayoutCategory("Hunter Shot Timer")
    layout:AddInitializer(CreateSettingsButtonInitializer("Hunter Shot Timer", "Open settings", function()
      if SettingsPanel then HideUIPanel(SettingsPanel) end
      ns.OpenOptions()
    end, "Size, fonts, colours and the range check. Also: /hst", true))
    Settings.RegisterAddOnCategory(cat)
  end)
  return ok
end

function ns.OpenOptions()
  if not win then build() end
  win:Show()
  win:Raise()
end

function ns.ToggleOptions()
  if win and win:IsShown() then win:Hide() else ns.OpenOptions() end
end
