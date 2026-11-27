-- MMT: warnings for full bags, a full quest log and drowning (Alerts page;
-- the room warnings as in MBAssist).
--
-- Every client watches its own character and tells the leader (FTL leader,
-- or the group leader without one) when it gets low on room or on breath:
--   NOTE:WARN:BAGS:<free slots>
--   NOTE:WARN:QLOG:<quests>:<maximum>
--   NOTE:WARN:BREATH:<seconds of breath left>   (0 = drowning: losing health)
-- Each warns once when it crosses the limit, and once more when it is
-- completely full (out of breath); it warns again only after there was room
-- (breath) again. Breath is the game's breath bar (mirror timer "BREATH"),
-- watched twice a second while it runs down.
-- On the leader's client: a chat line, optionally a raid warning and sound;
-- warnings arriving within 2 seconds share one line.

local _, ns = ...

local function Cfg() return ns.db and ns.db.warn end

---------------------------------------------------------------------------
-- Leader: show the warning
---------------------------------------------------------------------------
local RAID_WARNING_SOUND = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959

-- warnings arriving within 2 seconds become one line (and one raid warning / sound):
--   Bags: John full, Monika 2 free.  Quest log: Apple full (25/25).
local function Show(list)
    local cfg = Cfg()
    local bags, quests, breath = {}, {}, {}
    for _, w in ipairs(list) do
        if w.kind == "BAGS" then
            bags[#bags + 1] = w.who .. " " .. (w.a == 0 and "full" or (w.a .. " free"))
        elseif w.kind == "BREATH" then
            breath[#breath + 1] = w.who .. " " .. (w.a == 0 and "out of breath" or (w.a .. " s left"))
        else
            quests[#quests + 1] = ("%s %s (%d/%d)"):format(w.who, w.a >= w.b and "full" or "almost full", w.a, w.b)
        end
    end
    local lines = {}
    if #breath > 0 then lines[#lines + 1] = "Drowning: " .. ns.AndList(breath) .. "." end
    if #bags > 0 then lines[#lines + 1] = "Bags: " .. ns.AndList(bags) .. "." end
    if #quests > 0 then lines[#lines + 1] = "Quest log: " .. ns.AndList(quests) .. "." end
    if #lines == 0 then return end
    local text = table.concat(lines, "  ")
    ns.Print("|cffffa020%s|r", text)
    if cfg.raidWarning and RaidNotice_AddMessage and RaidWarningFrame then
        pcall(RaidNotice_AddMessage, RaidWarningFrame, text, { r = 1, g = 0.63, b = 0.13 })
    end
    if cfg.sound then pcall(PlaySound, RAID_WARNING_SOUND, "Master") end
end
local warnings = ns.ChatBatch(2, Show)

local function Add(key, kind, a, b)
    -- the same warning about the same character at most once every few seconds
    if not ns.AlertAllowed("warn", ("%s:%s:%s:%s"):format(key, kind, a, tostring(b))) then return end
    warnings.Add({ who = ns.ShownName(key), kind = kind, a = a, b = b or 0 })
end

ns.Listen("TEAM_MESSAGE", function(key, sender, text, _, channel)
    local kind, a, b = text:match("^NOTE:WARN:(%u+):(%d+):?(%d*)$")
    if not kind or not ns.AcceptNotice(channel) then return end
    Add(key, kind, tonumber(a), tonumber(b))
end)

local function Report(kind, a, b)
    local msg = ("NOTE:WARN:%s:%d%s"):format(kind, a, b and (":" .. b) or "")
    -- drowning can't wait behind the team's other messages: the alert lane
    local result = ns.TellLeader and ns.TellLeader(msg, kind == "BREATH" and "ALERT" or nil)
    if result == "self" then Add(ns.PlayerFull(), kind, a, b) end
end

---------------------------------------------------------------------------
-- Own character
---------------------------------------------------------------------------
-- level: 0 room, 1 low, 2 full; a warning when the level goes up
local bagLevel, questLevel

local function QuestCounts()
    local quests
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
        local _, n = C_QuestLog.GetNumQuestLogEntries()
        quests = n
    elseif GetNumQuestLogEntries then
        local _, n = GetNumQuestLogEntries()
        quests = n
    end
    local max = (C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept())
        or MAX_QUESTS or 25
    return quests, max
end

local function Check()
    local cfg = Cfg()
    if not (cfg and ns.ready) then return end

    if cfg.bags then
        local s = ns.UpdateOwnStatus()
        local free = s and s.free
        if free then
            local level = free == 0 and 2 or (free <= (cfg.bagsAt or 2) and 1 or 0)
            if bagLevel ~= nil and level > bagLevel then Report("BAGS", free) end
            bagLevel = level
        end
    end

    if cfg.quests then
        local n, max = QuestCounts()
        if n and max and max > 0 then
            local left = max - n
            local level = left <= 0 and 2 or (left <= (cfg.questsAt or 3) and 1 or 0)
            if questLevel ~= nil and level > questLevel then Report("QLOG", n, max) end
            questLevel = level
        end
    end
end
ns.CheckRoomWarnings = Check

local CheckSoon = ns.Coalesce(function() Check() end, 0.5)   -- (at a vendor: once selling pauses)

---------------------------------------------------------------------------
-- Breath: the game's breath bar while it runs down
---------------------------------------------------------------------------
-- level: 0 enough breath, 1 low, 2 out of breath (drowning)
local breathLevel, breathTicker = 0, nil
-- the breath bar as MIRROR_TIMER_START told it: seconds left then, the rate (-1 runs down,
-- positive fills up), when, and paused. Counted on from there: the GetMirrorTimer* calls
-- don't always say the same on every client.
local bar

local function FromApi()
    if not GetMirrorTimerInfo then return nil end
    for i = 1, (MIRRORTIMER_NUMTIMERS or 3) do
        local timer, value, _, scale, paused = GetMirrorTimerInfo(i)
        if timer == "BREATH" then
            local left = GetMirrorTimerProgress and GetMirrorTimerProgress("BREATH") or value
            return { left = (tonumber(left) or 0) / 1000, scale = tonumber(scale) or -1, at = GetTime(),
                paused = paused == true or (tonumber(paused) or 0) ~= 0 }
        end
    end
    return nil
end

-- seconds of breath left and whether the bar runs down; nil when there is no breath bar
local function Breath()
    local b = bar or FromApi()
    if not b then return nil end
    local left = b.left
    if not b.paused then left = left + (GetTime() - b.at) * b.scale end
    return math.max(0, left), b.scale < 0 and not b.paused
end
ns.BreathLeft = Breath

local function CheckBreath()
    local cfg = Cfg()
    local left, falling = Breath()
    if not (cfg and cfg.drown and ns.ready) or not left then
        breathLevel = 0
        if not left and breathTicker then breathTicker:Cancel(); breathTicker = nil end
        return
    end
    local level = (left <= 0 and 2) or (left <= (cfg.drownAt or 15) and 1) or 0
    if level > breathLevel and falling then
        ns.Debug("BREATH warn: %.1f s left (limit %s)", left, tostring(cfg.drownAt))
        Report("BREATH", math.floor(left + 0.5))
    end
    -- breath coming back: warn again next time it runs low
    if level < breathLevel or not falling then breathLevel = falling and level or 0 else breathLevel = math.max(breathLevel, level) end
end
ns.CheckBreath = CheckBreath

local function WatchBreath()
    if not breathTicker then breathTicker = C_Timer.NewTicker(0.5, CheckBreath) end
    CheckBreath()
end
ns.On("MIRROR_TIMER_START", function(timer, value, maxValue, scale, paused)
    if timer ~= "BREATH" then return end
    bar = { left = (tonumber(value) or 0) / 1000, scale = tonumber(scale) or -1, at = GetTime(),
        paused = paused == true or (tonumber(paused) or 0) ~= 0 }
    ns.Debug("BREATH start value=%s max=%s scale=%s paused=%s", tostring(value), tostring(maxValue), tostring(scale), tostring(paused))
    WatchBreath()
end)
ns.On("MIRROR_TIMER_PAUSE", function(timer, paused)
    if timer ~= "BREATH" or not bar then return end
    local left = Breath()
    bar.left, bar.at, bar.paused = left or bar.left, GetTime(), paused == true or (tonumber(paused) or 0) ~= 0
    CheckBreath()
end)
ns.On("MIRROR_TIMER_STOP", function(timer)
    if timer ~= "BREATH" then return end
    ns.Debug("BREATH stop")
    bar, breathLevel = nil, 0
    if breathTicker then breathTicker:Cancel(); breathTicker = nil end
end)
-- already under water at login / after a reload
ns.OnLogin(function() C_Timer.After(3, function() if FromApi() then WatchBreath() end end) end)

ns.On("BAG_UPDATE_DELAYED", CheckSoon)
ns.On("QUEST_ACCEPTED", CheckSoon)
ns.On("QUEST_REMOVED", CheckSoon)
ns.On("QUEST_LOG_UPDATE", CheckSoon)
-- the state at login is only remembered: no warning for what was full before
ns.OnLogin(function() C_Timer.After(3, Check) end)
