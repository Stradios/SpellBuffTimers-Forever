-- Spell Buff Timers 2.1
-- Shows the remaining time of buffs on you as a cooldown sweep + custom timer text on the action
-- bar button whose icon matches the buff icon. Works for any class. Supports Blizzard bars and ElvUI.
-- In combat the game blocks aura reading, so timers are started from your own casts, using
-- durations learned earlier from real buff data (saved between sessions).

local legacy = (GetPlayerBuff ~= nil)
local overlays = {}
local active = {}            -- overlays that currently show a timer
local castTimers = {}        -- icon -> { start, duration, name }
local scanTip
local lastError
local usedFallback = false
local DB

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
if ElvUI and ElvUI[1] and ElvUI[1].media and ElvUI[1].media.normFont then
    FONT = ElvUI[1].media.normFont
end

local function Say(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00SpellBuffTimers:|r " .. tostring(msg)) end
end

local function GetDB()
    if not DB then
        DB = SpellBuffTimersDB or {}
        SpellBuffTimersDB = DB
        DB.learned = DB.learned or {}
        DB.min = DB.min or 0      -- ignore buffs shorter than this many seconds (0 = off)
        DB.max = DB.max or 0      -- ignore buffs longer than this many seconds (0 = off)
        DB.size = DB.size or 0    -- number font size (0 = automatic, based on button size)
    end
    return DB
end

local function Allowed(dur)
    local d = GetDB()
    if d.min > 0 and dur < d.min then return false end
    if d.max > 0 and dur > d.max then return false end
    return true
end

local function G(name)
    if _G then return _G[name] end
    return getglobal(name)
end

local function Norm(t)
    if type(t) == "string" then return string.lower(t) end
    return t
end

local function Learn(icon, dur)
    if icon and dur and dur > 0 then GetDB().learned[tostring(icon)] = dur end
end

-- Build the list of button names to check
local buttonNames = {}
local function AddButtons(prefix, count)
    for i = 1, count do table.insert(buttonNames, prefix .. i) end
end
AddButtons("ActionButton", 12)
AddButtons("BonusActionButton", 12)
AddButtons("MultiBarBottomLeftButton", 12)
AddButtons("MultiBarBottomRightButton", 12)
AddButtons("MultiBarRightButton", 12)
AddButtons("MultiBarLeftButton", 12)
for bar = 1, 15 do AddButtons("ElvUI_Bar" .. bar .. "Button", 12) end

local function LegacyBuffName(index)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "SpellBuffTimersScanTip", nil, "GameTooltipTemplate")
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    scanTip:ClearLines()
    scanTip:SetPlayerBuff(index)
    local fs = G("SpellBuffTimersScanTipTextLeft1")
    return fs and fs:GetText()
end

-- Reads real aura data. May throw an error when the game restricts aura access (combat).
local function ReadAuras()
    local found, all = {}, {}
    local now = GetTime()
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not a then break end
            table.insert(all, tostring(a.name) .. " icon=" .. tostring(a.icon) .. " dur=" .. tostring(a.duration))
            local dur, expires = a.duration, a.expirationTime
            if dur and dur > 0 and expires and expires > 0 then
                local icon = Norm(a.icon)
                Learn(icon, dur)
                if Allowed(dur) then found[icon] = { expires - dur, dur, a.name } end
            end
        end
    elseif UnitBuff and not legacy then
        for i = 1, 40 do
            local name, icon, _, _, dur, expires = UnitBuff("player", i)
            if not name then break end
            table.insert(all, tostring(name) .. " icon=" .. tostring(icon) .. " dur=" .. tostring(dur))
            if dur and dur > 0 and expires and expires > 0 then
                icon = Norm(icon)
                Learn(icon, dur)
                if Allowed(dur) then found[icon] = { expires - dur, dur, name } end
            end
        end
    elseif legacy then
        for i = 0, 31 do
            local idx = GetPlayerBuff(i, "HELPFUL")
            if idx and idx >= 0 then
                local timeLeft = GetPlayerBuffTimeLeft(idx)
                local name = LegacyBuffName(idx)
                local icon = Norm(GetPlayerBuffTexture(idx))
                table.insert(all, tostring(name) .. " icon=" .. tostring(icon) .. " left=" .. tostring(timeLeft))
                if timeLeft and timeLeft > 0 then
                    local known = GetDB().learned[tostring(icon)] or 0
                    local dur = math.max(known, timeLeft)
                    Learn(icon, dur)
                    if Allowed(dur) then found[icon] = { now + timeLeft - dur, dur, name } end
                end
            end
        end
    end
    return found, all
end

-- Returns table: normalized icon -> { start, duration, name }, plus a list of all buffs (for debugging)
local function ScanBuffs()
    local ok, found, all = pcall(ReadAuras)
    if ok then
        usedFallback = false
        -- A cast made in the last 2 seconds may not show up in the aura list yet: keep it
        local now = GetTime()
        for icon, info in pairs(castTimers) do
            if not found[icon] and (now - info[1]) < 2 then
                found[icon] = info
            end
        end
        castTimers = found
        return found, all
    end
    -- Aura data restricted (combat): use timers started from your own casts
    usedFallback = true
    local now = GetTime()
    local result = {}
    for icon, info in pairs(castTimers) do
        if info[1] + info[2] > now then
            result[icon] = info
        else
            castTimers[icon] = nil
        end
    end
    return result, { "(aura data restricted right now, using cast tracking)" }
end

local function GetButtonTexture(btn)
    local tex
    if btn.icon and btn.icon.GetTexture then tex = btn.icon:GetTexture() end
    if not tex and btn.Icon and btn.Icon.GetTexture then tex = btn.Icon:GetTexture() end
    if not tex and btn.GetName and btn:GetName() then
        local ic = G(btn:GetName() .. "Icon")
        if ic and ic.GetTexture then tex = ic:GetTexture() end
    end
    if not tex then
        local slot = btn.action
        if not slot and btn.GetAction then
            local t, a = btn:GetAction()
            if t == "action" then slot = a end
        end
        if not slot and ActionButton_GetPagedID then slot = ActionButton_GetPagedID(btn) end
        if slot and GetActionTexture then tex = GetActionTexture(slot) end
    end
    return Norm(tex)
end

------------------------------------------------------------------------
-- Timer text
------------------------------------------------------------------------

-- Returns number text, unit text for a remaining time in seconds
local function FormatTime(rem)
    if rem >= 3600 then
        return tostring(math.ceil(rem / 3600)), "h"
    elseif rem >= 60 then
        return tostring(math.ceil(rem / 60)), "m"
    elseif rem >= 2 then
        return tostring(math.floor(rem)), ""
    else
        if rem < 0 then rem = 0 end
        return string.format("%.2f", rem), ""
    end
end

-- Sizes and positions the number (full size) and unit letter (half size, bottom right of the number)
-- so everything stays inside the button.
local function Layout(cd, numStr, unitStr)
    local btn = cd.btn
    local h = btn:GetHeight() or 36
    local w = btn:GetWidth() or 36
    local size = GetDB().size
    if not size or size <= 0 then size = math.floor(h * 0.5 + 0.5) end
    if size < 8 then size = 8 end
    for tries = 1, 3 do
        local usize = math.floor(size / 2)
        if usize < 6 then usize = 6 end
        cd.num:SetFont(FONT, size, "OUTLINE")
        cd.unit:SetFont(FONT, usize, "OUTLINE")
        cd.num:SetText(numStr)
        cd.unit:SetText(unitStr)
        local tw = cd.num:GetStringWidth() + cd.unit:GetStringWidth()
        if tw <= (w - 2) or size <= 8 then break end
        size = math.floor(size * (w - 2) / tw)
        if size < 8 then size = 8 end
    end
    cd.num:ClearAllPoints()
    cd.num:SetPoint("CENTER", btn, "CENTER", -(cd.unit:GetStringWidth() / 2), 0)
    cd.unit:ClearAllPoints()
    cd.unit:SetPoint("BOTTOMLEFT", cd.num, "BOTTOMRIGHT", 0, 1)
end

local function UpdateText(cd, now)
    local rem = cd.sealEnd - now
    if rem <= 0 then
        active[cd] = nil
        cd.tf:Hide()
        return
    end
    cd.tf:Show()
    local numStr, unitStr = FormatTime(rem)
    local layoutKey = string.len(numStr) .. unitStr
    if cd.layoutKey ~= layoutKey then
        cd.layoutKey = layoutKey
        Layout(cd, numStr, unitStr)
        cd.lastNum = numStr
    elseif cd.lastNum ~= numStr then
        cd.lastNum = numStr
        cd.num:SetText(numStr)
    end
    -- White until 2 seconds are left, then yellow fading to red at 0
    local r, g, b = 1, 1, 1
    if rem <= 2 then g = rem / 2; b = 0 end
    local ckey = math.floor(g * 50) .. (b == 0 and "y" or "w")
    if cd.ckey ~= ckey then
        cd.ckey = ckey
        cd.num:SetTextColor(r, g, b)
        cd.unit:SetTextColor(r, g, b)
    end
end

------------------------------------------------------------------------
-- Overlays
------------------------------------------------------------------------

local function GetOverlay(btn)
    local cd = overlays[btn]
    if not cd then
        local ok
        ok, cd = pcall(CreateFrame, "Cooldown", nil, btn, "CooldownFrameTemplate")
        if not ok or not cd then cd = CreateFrame("Model", nil, btn, "CooldownFrameTemplate") end
        cd:SetAllPoints(btn)
        cd:SetFrameLevel(btn:GetFrameLevel() + 5)
        if cd.SetDrawEdge then cd:SetDrawEdge(false) end
        -- Turn off every built-in / ElvUI / OmniCC timer text; we draw our own
        if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
        cd.noCooldownCount = true
        cd.noOCC = true
        cd.forceDisabled = true
        cd.btn = btn
        local tf = CreateFrame("Frame", nil, btn)
        tf:SetAllPoints(btn)
        tf:SetFrameLevel(btn:GetFrameLevel() + 8)
        cd.tf = tf
        cd.num = tf:CreateFontString(nil, "OVERLAY")
        cd.unit = tf:CreateFontString(nil, "OVERLAY")
        cd.num:SetFont(FONT, 14, "OUTLINE")
        cd.unit:SetFont(FONT, 7, "OUTLINE")
        overlays[btn] = cd
    end
    return cd
end

local function ClearOverlay(btn)
    local cd = overlays[btn]
    if cd and (cd.sealKey or cd:IsShown()) then
        cd.sealKey = nil
        cd.layoutKey = nil
        active[cd] = nil
        cd.tf:Hide()
        if cd.Clear then cd:Clear() end
        cd:Hide()
    end
end

local function Update(debug)
    local buffs, all = ScanBuffs()
    local buttons, matched = 0, 0
    local sample = {}
    for _, bname in ipairs(buttonNames) do
        local btn = G(bname)
        if btn and btn.IsVisible and btn:IsVisible() then
            buttons = buttons + 1
            local tex = GetButtonTexture(btn)
            if debug and buttons <= 3 then
                table.insert(sample, bname .. " icon=" .. tostring(tex))
            end
            local info = tex and buffs[tex]
            if info then
                matched = matched + 1
                local cd = GetOverlay(btn)
                local key = math.floor(info[1] * 10) .. ":" .. math.floor(info[2] * 10)
                if cd.sealKey ~= key or not cd:IsShown() then
                    cd.sealKey = key
                    cd:Show()
                    if CooldownFrame_Set then
                        CooldownFrame_Set(cd, info[1], info[2], true)
                    elseif CooldownFrame_SetTimer then
                        CooldownFrame_SetTimer(cd, info[1], info[2], 1)
                    else
                        cd:SetCooldown(info[1], info[2])
                    end
                end
                cd.sealEnd = info[1] + info[2]
                active[cd] = true
                -- Hide any timer text another addon (e.g. ElvUI) attached to this cooldown
                if cd.timer and cd.timer.Hide then cd.timer:Hide() end
            else
                ClearOverlay(btn)
            end
        end
    end
    if debug then
        local d = GetDB()
        Say("Mode: " .. (usedFallback and "cast tracking (aura data restricted)" or "real aura data"))
        Say("Filters: min=" .. d.min .. "s, max=" .. d.max .. "s, font size=" .. d.size .. " (0 = off/auto)")
        Say("Buffs on you:")
        for _, line in ipairs(all) do Say("  " .. line) end
        Say("Visible buttons checked: " .. buttons .. ", matched: " .. matched)
        for _, line in ipairs(sample) do Say("  sample " .. line) end
        if lastError then Say("Last error: " .. lastError) end
    end
end

local function SafeUpdate(debug)
    local ok, err = pcall(Update, debug)
    if not ok and err ~= lastError then
        lastError = tostring(err)
        Say("ERROR: " .. lastError)
    end
end

-- Start a timer from your own cast, using a duration learned earlier from real buff data
local function OnCast(unit, spellID)
    if unit ~= "player" or not spellID then return end
    local name, icon
    if C_Spell and C_Spell.GetSpellInfo then
        local i = C_Spell.GetSpellInfo(spellID)
        if i then name, icon = i.name, i.iconID end
    elseif GetSpellInfo then
        local n, _, ic = GetSpellInfo(spellID)
        name, icon = n, ic
    end
    if not name or not icon then return end
    icon = Norm(icon)
    local dur = GetDB().learned[tostring(icon)]
    if dur and Allowed(dur) then
        castTimers[icon] = { GetTime(), dur, name }
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
if legacy then f:RegisterEvent("PLAYER_AURAS_CHANGED") end
pcall(f.RegisterEvent, f, "UNIT_SPELLCAST_SUCCEEDED")

f:SetScript("OnEvent", function(self, ev, unit, castGUID, spellID)
    ev = ev or event
    unit = unit or arg1
    if ev == "PLAYER_ENTERING_WORLD" then
        Say("loaded. Type /sbt for diagnostics.")
    elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
        pcall(OnCast, unit, spellID)
    end
    if ev == "UNIT_AURA" and unit and unit ~= "player" then return end
    SafeUpdate()
end)

-- Buff/button refresh twice a second
local acc = 0
f:SetScript("OnUpdate", function(self, elapsed)
    elapsed = elapsed or arg1 or 0
    acc = acc + elapsed
    if acc > 0.5 then acc = 0; SafeUpdate() end
end)

-- Timer text refresh every frame (needed for the smooth 1.99, 1.98, ... countdown)
local tick = CreateFrame("Frame")
tick:SetScript("OnUpdate", function()
    local now = GetTime()
    for cd in pairs(active) do
        local ok, err = pcall(UpdateText, cd, now)
        if not ok and err ~= lastError then
            lastError = tostring(err)
            Say("ERROR: " .. lastError)
        end
    end
end)

SLASH_SPELLBUFFTIMERS1 = "/sbt"
SLASH_SPELLBUFFTIMERS2 = "/spellbufftimers"
SlashCmdList["SPELLBUFFTIMERS"] = function(msg)
    msg = string.lower(msg or "")
    local _, _, cmd, val = string.find(msg, "^(%S+)%s*(%S*)")
    local d = GetDB()
    if cmd == "max" then
        d.max = tonumber(val) or 0
        Say("Ignoring buffs longer than " .. d.max .. " seconds (0 = off).")
    elseif cmd == "min" then
        d.min = tonumber(val) or 0
        Say("Ignoring buffs shorter than " .. d.min .. " seconds (0 = off).")
    elseif cmd == "size" then
        d.size = tonumber(val) or 0
        for _, cd in pairs(overlays) do cd.layoutKey = nil end
        Say("Timer number font size: " .. (d.size > 0 and d.size or "automatic") .. ".")
    elseif cmd == "reset" then
        d.learned = {}
        Say("Cleared learned buff durations.")
    else
        if cmd == "help" then
            Say("/sbt - diagnostics   /sbt max N   /sbt min N   /sbt size N (0 = auto)   /sbt reset")
        end
        SafeUpdate(true)
        return
    end
    SafeUpdate()
end
