-- MMT Statistics: earnings and expenses. Every change of this character's
-- gold (PLAYER_MONEY) is put into a category by what is open or just happened:
--   earned: Looted, Quests, Vendor sales, Auction house, Mail, Trade, Guild bank, Other
--   spent:  Vendor purchases, Repairs, Flights, Training, Auction house, Mail,
--           Trade, Guild bank, Other
-- Kept per character and day (the chart's 60 days) and since tracking began:
--   c.flow[date] = { e = { [cat] = copper }, s = { [cat] = copper } }
--   c.flowTotal  = { e = {...}, s = {...} },  c.flowSince = time()
-- The game's own lifetime counters (gold acquired, looted, from quests, vendor
-- and auction sales, spent on travel, most gold owned) come from the statistics
-- API, for this character (statistic ids as listed by ForeverIRS, checked by its
-- authors for this client).

local _, mod = ...
local MMT = MMT
local M = mod.M

mod.EARN_CATS = { "Looted", "Quests", "Vendor sales", "Auction house", "Mail", "Trade", "Guild bank", "Other" }
mod.SPEND_CATS = { "Vendor purchases", "Repairs", "Flights", "Training", "Auction house", "Mail", "Trade", "Guild bank", "Other" }

local last              -- this character's gold at the last change
local open = {}         -- [context] = true while its window is open
local closedAt = {}     -- [context] = GetTime() it closed (late money still counts)
local hint, hintAt      -- a one-shot reason for the next change ("Looted", "Quests", "Repairs", "Auction house")
local LATE = 3          -- seconds after a window closed / a hint that a change still belongs to it

local function Recent(ctx)
    return open[ctx] or (closedAt[ctx] and GetTime() - closedAt[ctx] < LATE)
end

local function Hint(what) hint, hintAt = what, GetTime() end

-- the category of a change of `delta` copper
local function Category(delta)
    local earned = delta > 0
    if hint and GetTime() - hintAt < LATE then
        local h = hint
        if (h == "Looted" or h == "Quests") and earned then hint = nil return h end
        if h == "Repairs" and not earned then hint = nil return h end
        if h == "Auction house" or h == "Mail" then hint = nil return h end
    end
    if Recent("trade") then return "Trade" end
    if Recent("auction") then return "Auction house" end
    if Recent("guildbank") then return "Guild bank" end
    if Recent("mail") then return "Mail" end
    if Recent("merchant") then return earned and "Vendor sales" or "Vendor purchases" end
    if Recent("taxi") and not earned then return "Flights" end
    if Recent("trainer") and not earned then return "Training" end
    if Recent("loot") and earned then return "Looted" end
    if Recent("quest") and earned then return "Quests" end
    return "Other"
end

local function Add(map, cat, n) map[cat] = (map[cat] or 0) + n end

function mod.RecordFlow(delta, cat)
    if not (M.enabled and M.db.trackGold and M.db.trackFlow ~= false) then return end
    local c = mod.Char()
    if not c then return end
    local side = delta > 0 and "e" or "s"
    local n = math.abs(delta)
    c.flow = c.flow or {}
    c.flowTotal = c.flowTotal or { e = {}, s = {} }
    c.flowSince = c.flowSince or time()
    local day = mod.Today()
    local d = c.flow[day] or { e = {}, s = {} }
    c.flow[day] = d
    Add(d[side], cat, n)
    Add(c.flowTotal[side], cat, n)
    local first = mod.Days()[1]
    for k in pairs(c.flow) do if k < first then c.flow[k] = nil end end
    M:Debug("money %s%s: %s", delta > 0 and "+" or "-", mod.Money(n), cat)
end

local function Money()
    local m = GetMoney and GetMoney()
    if m == nil or MMT.IsSecret(m) then return nil end
    return m
end

local redrawSoon = MMT.Coalesce(function() if mod.Redraw then mod.Redraw() end end, 0.2)   -- (at a vendor: once selling pauses)
M:On("PLAYER_MONEY", function()
    local now = Money()
    if not now then return end
    if last and now ~= last then
        local delta = now - last
        local cat = Category(delta)
        mod.RecordFlow(delta, cat)
        if cat == "Looted" and delta > 0 and mod.SessionLootMoney then mod.SessionLootMoney(delta) end   -- Session Kill-Details
    end
    last = now
    redrawSoon()
end)
-- the starting point: login and every loading screen (no change is lost or invented)
M:On("PLAYER_ENTERING_WORLD", function() C_Timer.After(1, function() last = Money() or last end) end)

-- windows: open / closed
local function Track(ctx, showEvent, hideEvent)
    M:On(showEvent, function() open[ctx] = true end)
    M:On(hideEvent, function() open[ctx] = nil; closedAt[ctx] = GetTime() end)
end
Track("merchant", "MERCHANT_SHOW", "MERCHANT_CLOSED")
Track("taxi", "TAXIMAP_OPENED", "TAXIMAP_CLOSED")
Track("mail", "MAIL_SHOW", "MAIL_CLOSED")
Track("auction", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED")
Track("trade", "TRADE_SHOW", "TRADE_CLOSED")
Track("trainer", "TRAINER_SHOW", "TRAINER_CLOSED")
Track("guildbank", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED")
Track("loot", "LOOT_OPENED", "LOOT_CLOSED")
Track("quest", "QUEST_COMPLETE", "QUEST_FINISHED")
-- newer clients open some of these through the interaction manager
local INTERACTION = {}
if Enum and Enum.PlayerInteractionType then
    local E = Enum.PlayerInteractionType
    for name, ctx in pairs({ Merchant = "merchant", TaxiNode = "taxi", MailInfo = "mail", Auctioneer = "auction",
        TradePartner = "trade", Trainer = "trainer", GuildBanker = "guildbank" }) do
        if E[name] then INTERACTION[E[name]] = ctx end
    end
end
M:On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind) local ctx = INTERACTION[kind] if ctx then open[ctx] = true end end)
M:On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
    local ctx = INTERACTION[kind]
    if ctx then open[ctx] = nil; closedAt[ctx] = GetTime() end
end)

-- one-shot reasons
M:On("CHAT_MSG_MONEY", function() Hint("Looted") end)              -- "You loot 12 Silver", "Your share of the loot is ..."
M:On("QUEST_TURNED_IN", function() Hint("Quests") end)
if type(RepairAllItems) == "function" then hooksecurefunc("RepairAllItems", function() Hint("Repairs") end) end
-- money taken from a mail: an auction house mail counts for the auction house
if type(TakeInboxMoney) == "function" then
    hooksecurefunc("TakeInboxMoney", function(index)
        local ok, _, _, sender = pcall(GetInboxHeaderInfo, index)
        local s = ok and type(sender) == "string" and not MMT.IsSecret(sender) and sender:lower() or ""
        Hint(s:find("auction") and "Auction house" or "Mail")
    end)
end

---------------------------------------------------------------------------
-- Sums
---------------------------------------------------------------------------
-- this account per chart day: { [date] = { e = copper, s = copper } } and the
-- categories over the 60 days and since tracking: { e = {cat=copper}, s = {...} }
function mod.OwnFlow()
    local days, cats60, life, since = {}, { e = {}, s = {} }, { e = {}, s = {} }, nil
    for _, c in pairs(mod.Store().chars) do
        for day, d in pairs(c.flow or {}) do
            local t = days[day] or { e = 0, s = 0 }
            days[day] = t
            for side in pairs(cats60) do
                for cat, n in pairs(d[side] or {}) do
                    t[side] = t[side] + n
                    Add(cats60[side], cat, n)
                end
            end
        end
        for side in pairs(life) do
            for cat, n in pairs((c.flowTotal or {})[side] or {}) do Add(life[side], cat, n) end
        end
        if c.flowSince and (not since or c.flowSince < since) then since = c.flowSince end
    end
    return { days = days, cats = cats60, life = life, since = since }
end

-- the scope's earnings and spendings: per chart day, by category (60 days, and
-- since tracking), and today / last 7 days by category
function mod.FlowSummary(scope)
    local list = mod.Days()
    local out = { days = {}, cats = { e = {}, s = {} }, life = { e = {}, s = {} }, week = { e = {}, s = {} },
        today = { e = {}, s = {} }, total = { e = 0, s = 0 }, since = nil }
    local index = {}
    for i, d in ipairs(list) do index[d] = i; out.days[i] = { e = 0, s = 0 } end
    local weekStart, today = list[#list - 6], list[#list]
    for _, id in ipairs(mod.ScopeAccounts(scope)) do
        local a = mod.Account(id)
        local f = a and a.flow
        if f then
            for day, t in pairs(f.days or {}) do
                local i = index[day]
                if i then
                    out.days[i].e = out.days[i].e + (t.e or 0)
                    out.days[i].s = out.days[i].s + (t.s or 0)
                    out.total.e = out.total.e + (t.e or 0)
                    out.total.s = out.total.s + (t.s or 0)
                end
            end
            for side in pairs(out.cats) do
                for cat, n in pairs((f.cats or {})[side] or {}) do Add(out.cats[side], cat, n) end
                for cat, n in pairs((f.life or {})[side] or {}) do Add(out.life[side], cat, n) end
                for cat, n in pairs((f.week or {})[side] or {}) do Add(out.week[side], cat, n) end
                for cat, n in pairs((f.today or {})[side] or {}) do Add(out.today[side], cat, n) end
            end
            if f.since and (not out.since or f.since < out.since) then out.since = f.since end
        end
    end
    return out
end

-- this account's today / last 7 days by category (part of what is sent to the team)
function mod.OwnFlowRecent()
    local list = mod.Days()
    local weekStart, today = list[#list - 6], list[#list]
    local week, now = { e = {}, s = {} }, { e = {}, s = {} }
    for _, c in pairs(mod.Store().chars) do
        for day, d in pairs(c.flow or {}) do
            if day >= weekStart then
                for side in pairs(week) do
                    for cat, n in pairs(d[side] or {}) do
                        Add(week[side], cat, n)
                        if day == today then Add(now[side], cat, n) end
                    end
                end
            end
        end
    end
    return week, now
end

-- the flow part of this account's record (Module.lua's OwnAccount / summary)
function mod.OwnFlowRecord()
    local f = mod.OwnFlow()
    f.week, f.today = mod.OwnFlowRecent()
    return f
end

---------------------------------------------------------------------------
-- The game's own lifetime counters (this character)
---------------------------------------------------------------------------
mod.GAME_WEALTH = {
    { id = 328, label = "Gold acquired", side = "e" },
    { id = 333, label = "Gold looted", side = "e" },
    { id = 326, label = "Quest rewards", side = "e" },
    { id = 921, label = "Vendor sales", side = "e" },
    { id = 919, label = "Auction sales", side = "e" },
    { id = 1146, label = "Spent on travel", side = "s" },
    { id = 334, label = "Most gold owned", side = "o" },
}

-- money text of a statistic ("12|TInterface\MoneyFrame\UI-GoldIcon...|t 3|T...") -> copper
local function ParseMoney(raw)
    if raw == nil or MMT.IsSecret(raw) then return nil end
    local n = tonumber(raw)
    if n then return n end
    if type(raw) ~= "string" or #raw > 400 then return nil end
    local text = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local total, found = 0, false
    for amount, icon in text:gmatch("([%d%.,]+)%s*|[TA]([^|]+)|[ta]") do
        local metal = icon:lower():match("ui%-(%a+)icon") or icon:lower():match("coin%-(%a+)")
        local mult = metal == "gold" and 10000 or metal == "silver" and 100 or metal == "copper" and 1 or nil
        local v = tonumber((amount:gsub("[^%d]", "")))
        if mult and v then total = total + v * mult; found = true end
    end
    if found then return total end
    return nil
end
mod.ParseStatMoney = ParseMoney   -- (tests)

-- { {label, side, copper|nil}, ... } for this character
function mod.GameWealth()
    local out = {}
    for _, s in ipairs(mod.GAME_WEALTH) do
        local value
        if type(GetStatistic) == "function" then
            local ok, raw = pcall(GetStatistic, s.id)
            if ok then value = ParseMoney(raw) end
        end
        out[#out + 1] = { s.label, s.side, value }
    end
    return out
end
