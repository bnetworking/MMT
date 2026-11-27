-- MMT Loot Distribution: Dejunk - destroying items.
--
-- The game only lets an addon destroy an item during a real key press or
-- mouse click (a "hardware event"), one item per press. So destroying works
-- like this:
--   * "Destroy the cheapest item" (button / key binding): at once, the press is
--     the hardware event.
--   * Everything else is queued and destroyed during your next key press or
--     click anywhere (moving, clicking in the world, ...), one item per press:
--     the bags are at the free-slot limit ("Keep free bag slots"), an item of an
--     "Always destroy" role was looted, or a team member asked to destroy an
--     item you have too. With ISBoxer broadcasting keys, every window gets key
--     presses as you move, so the team's items go within a few steps.
-- The game's confirmation popup never appears: the item is destroyed directly.
-- Never: in combat, quest items, items of a "Never destroy" role, and (unless
-- an "Always destroy" role lists it) items above the quality limit or without
-- a sell price.
--
-- Same item on the team: when you destroy an item yourself (dragging it out of
-- the bags), MMT asks whether the team should destroy it too (DJX:<itemID>);
-- each member then queues all its stacks of it.

local _, mod = ...
local MMT = MMT
local M = mod.M

local queue = {}        -- { { itemID, why, count = stacks still to go } } in order
local stats = { destroyed = 0, queued = 0, asked = 0, skippedCombat = 0, last = nil }
local ours = false      -- a DeleteCursorItem of ours (not the player's)
local cursorItem        -- the item last picked up on the cursor (itemID, link)
local lastScan = 0

local function Cfg() return M.db end

local function Quality(id) return select(3, MMT.ItemInfo(id)) end
local function Price(id) return select(11, MMT.ItemInfo(id)) or 0 end

local function InRoles(set, link)
    for role, on in pairs(set or {}) do
        if on and MMT.db.roles[role] and MMT.RoleWantsItem(role, link) then return role end
    end
end

local function IsQuestItem(info, link)
    if info and (info.isQuestItem or info.questID) then return true end
    local classID = select(12, MMT.ItemInfo(link))
    return classID == 12   -- Enum.ItemClass.Questitem
end

-- every bag item with what we know about it
local function BagItems()
    local list = {}
    for bag = 0, MMT.BAGS do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local q = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
                list[#list + 1] = { bag = bag, slot = slot, id = info.itemID, link = info.hyperlink or info.itemID,
                    count = info.stackCount or 1, locked = info.isLocked, quality = info.quality,
                    quest = IsQuestItem(q, info.hyperlink or info.itemID) }
            end
        end
    end
    return list
end

-- may this item be destroyed? (forced: asked by a team member / always list)
local function Allowed(item, forced)
    if item.locked or item.quest then return false, "quest or locked" end
    local never = InRoles(Cfg().dejunkNever, item.link)
    if never then return false, "Never destroy: " .. never end
    -- the core's Never Sell List (Trade / Mail / Vendor) keeps it too
    if MMT.ExcludedItem and MMT.ExcludedItem(item.link, "sell") then return false, "Never Sell List" end
    if InRoles(Cfg().dejunkAlways, item.link) then return true, "always" end
    if forced then return true, "asked" end
    local q = item.quality or Quality(item.id) or 0
    if q > (Cfg().dejunkMaxQuality or 1) then return false, "quality" end
    if Price(item.id) <= 0 then return false, "no sell price" end
    return true
end

-- the cheapest item that may go (an "Always destroy" one first)
function mod.DejunkCandidate()
    local best, bestValue, bestAlways
    for _, item in ipairs(BagItems()) do
        local ok, why = Allowed(item, false)
        if ok then
            local always = why == "always"
            local value = Price(item.id) * item.count
            if (always and not bestAlways) or (always == (bestAlways or false) and (not bestValue or value < bestValue)) then
                best, bestValue, bestAlways = item, value, always
            end
        end
    end
    return best, bestValue
end

local function Say(fmt, ...)
    if Cfg().dejunkChat ~= false then MMT.Print("Dejunk: " .. fmt, ...) end
end

-- automatic destroys are told to the FTL / notice leader (NOTE:DJ:<itemID>:<count>:<why>);
-- the leader prints them together, a few seconds after the first, like loot lines
local WHY_CODE = { ["free bag slot limit"] = "f", looted = "l", ["asked by the team"] = "t" }
local WHY_TEXT = { f = "bags full", l = "always destroy", t = "asked by the team" }
local function TellLeader(id, count, why)
    local code = WHY_CODE[why]
    if not code then return end   -- the button / key: you did it yourself
    MMT.TellLeader(("NOTE:DJ:%d:%d:%s"):format(id, count or 1, code))
end

local leaderBatch = MMT.ChatBatch(3, function(list)
    local order, byKey = {}, {}
    for _, e in ipairs(list) do
        if not byKey[e.key] then byKey[e.key] = {} order[#order + 1] = e.key end
        table.insert(byKey[e.key], e)
    end
    local parts = {}
    for _, key in ipairs(order) do
        local items, whys = {}, {}
        for _, e in ipairs(byKey[key]) do
            local _, link = MMT.ItemInfo(e.id)
            items[#items + 1] = tostring(link or ("item " .. e.id)) .. (e.count > 1 and ("x" .. e.count) or "")
            whys[WHY_TEXT[e.why] or "?"] = true
        end
        local w = {}
        for k in pairs(whys) do w[#w + 1] = k end
        table.sort(w)
        parts[#parts + 1] = ("%s: %s (%s)"):format(MMT.ShownName(key), table.concat(items, ", "), table.concat(w, ", "))
    end
    MMT.Print("Dejunk: destroyed - " .. table.concat(parts, "; "))
end)
M:Listen("TEAM_MESSAGE", function(key, sender, text, _, channel)
    local id, count, why = text:match("^NOTE:DJ:(%d+):(%d+):(%a)$")
    if not id or not MMT.AcceptNotice(channel) then return end
    leaderBatch.Add({ key = key, id = tonumber(id), count = tonumber(count) or 1, why = why })
end)

-- destroys one bag item now (must run inside a hardware event)
local function DestroyNow(item, why)
    if InCombatLockdown() or UnitIsDeadOrGhost("player") then stats.skippedCombat = stats.skippedCombat + 1 return false end
    if GetCursorInfo() then return false end
    local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
    if not info or info.itemID ~= item.id or info.isLocked then return false end
    ClearCursor()
    C_Container.PickupContainerItem(item.bag, item.slot)
    local kind, cursorID = GetCursorInfo()
    if kind ~= "item" or cursorID ~= item.id then ClearCursor() return false end
    ours = true
    local ok = pcall(DeleteCursorItem)
    ours = false
    if GetCursorInfo() then ClearCursor() end
    if ok then
        stats.destroyed = stats.destroyed + 1
        stats.last = item.link
        Say("destroyed %s%s (%s).", tostring(info.hyperlink or item.link), (info.stackCount or 1) > 1 and ("x" .. info.stackCount) or "", why)
        TellLeader(item.id, info.stackCount or 1, why)
    end
    M:Debug("dejunk destroy %s x%s (%s) -> %s", tostring(item.link), tostring(info.stackCount), why, tostring(ok))
    return ok
end

-- button / key binding: the cheapest item, right away
function mod.DejunkNow()
    if not M.enabled then return end
    local item, value = mod.DejunkCandidate()
    if not item then Say("nothing to destroy (see Loot Distribution > Dejunk).") return end
    local coins = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    local ok, text = pcall(coins or tostring, value or 0)
    DestroyNow(item, "cheapest, " .. (ok and tostring(text) or tostring(value)))
end
function MMT_DejunkNow() mod.DejunkNow() end
BINDING_HEADER_MMT_DEJUNK = "Loot Distribution"
BINDING_NAME_MMT_DEJUNK = "Destroy the cheapest item"

---------------------------------------------------------------------------
-- The queue: destroyed during the next key presses / clicks
---------------------------------------------------------------------------
local function Queue(itemID, why, stacks)
    for _, q in ipairs(queue) do
        if q.id == itemID then q.count = math.max(q.count, stacks) return end
    end
    queue[#queue + 1] = { id = itemID, why = why, count = stacks }
    stats.queued = stats.queued + 1
end

-- one queued item (or the cheapest when the bags are at the limit) per press
local function Step()
    if not M.enabled or InCombatLockdown() then return end
    while queue[1] do
        local q = queue[1]
        local target
        for _, item in ipairs(BagItems()) do
            if item.id == q.id and not item.locked then target = item break end
        end
        if not target or q.count <= 0 then
            table.remove(queue, 1)
        else
            local ok = Allowed(target, q.why == "team" or q.why == "looted")
            if not ok then table.remove(queue, 1)
            else
                if DestroyNow(target, q.why == "team" and "asked by the team" or q.why) then q.count = q.count - 1 end
                return
            end
        end
    end
    -- bags at the limit: the cheapest one
    if Cfg().dejunkFull then
        local status = MMT.UpdateOwnStatus and MMT.UpdateOwnStatus()
        local free = status and status.free
        if free and free <= (Cfg().reserve or 0) then
            local item = mod.DejunkCandidate()
            if item then DestroyNow(item, "free bag slot limit") end
        end
    end
end
mod.DejunkStep = Step   -- (tests)

-- every key press and mouse click (keys go on to the game as usual)
local input = CreateFrame("Frame", "MMTDejunkInput", UIParent)
local function Wanted()
    if not M.enabled then return false end
    if queue[1] then return true end
    if not Cfg().dejunkFull then return false end
    local status = MMT.status and MMT.status[MMT.PlayerFull()]
    local free = status and status.free
    return free == nil or free <= (Cfg().reserve or 0)
end
input:SetScript("OnKeyDown", function() if Wanted() then Step() end end)
if input.SetPropagateKeyboardInput then input:SetPropagateKeyboardInput(true) end
input:EnableKeyboard(true)
WorldFrame:HookScript("OnMouseDown", function() if Wanted() then Step() end end)

-- "Always destroy" roles, "when looted": queue them after the bags change
local function ScanLooted()
    if not (M.enabled and Cfg().dejunkAlwaysLooted) then return end
    if GetTime() - lastScan < 0.5 then return end
    lastScan = GetTime()
    for _, item in ipairs(BagItems()) do
        if not item.quest and InRoles(Cfg().dejunkAlways, item.link) and not InRoles(Cfg().dejunkNever, item.link) then
            Queue(item.id, "looted", 99)
        end
    end
end
M:On("BAG_UPDATE_DELAYED", MMT.Coalesce(ScanLooted, 0.1))   -- (at a vendor: once selling pauses)

---------------------------------------------------------------------------
-- The same item on the team
---------------------------------------------------------------------------
M:On("CURSOR_CHANGED", function()
    local kind, id, link = GetCursorInfo()
    if kind == "item" and id then cursorItem = { id = id, link = link } end
end)
hooksecurefunc("DeleteCursorItem", function()
    if ours or not M.enabled or not Cfg().dejunkTeam then return end
    local item = cursorItem
    if not item or not IsInGroup() then return end
    stats.asked = stats.asked + 1
    MMT.UI.Confirm(("You destroyed %s.\nDestroy it on the team too (all stacks, during their next key presses)?"):format(tostring(item.link or item.id)),
        "Destroy on team", function() MMT.SendToTeam("DJX:" .. item.id) end, "No")
end)
M:Listen("TEAM_MESSAGE", function(key, sender, text)
    local id = tonumber(text:match("^DJX:(%d+)"))
    if not id or MMT.IsSelf(key) then return end
    if not Cfg().dejunkTeam then
        M:Debug("dejunk: %s asked to destroy item %d, but \"Destroy on the team\" is off here", MMT.Repr(key), id)
        return
    end
    local n = 0
    for _, item in ipairs(BagItems()) do if item.id == id then n = n + 1 end end
    if n == 0 then return end
    Queue(id, "team", n)
    local _, link = MMT.ItemInfo(id)
    Say("%s asked to destroy %s: %d stack(s), during your next key presses.", MMT.ShownName(key), tostring(link or id), n)
end)

function mod.DejunkReport(add)
    local c = Cfg()
    local function Set(t) local l = {} for k, v in pairs(t or {}) do if v then l[#l + 1] = k end end table.sort(l) return table.concat(l, ",") end
    local q = {}
    for _, e in ipairs(queue) do q[#q + 1] = ("%d(%s,%d)"):format(e.id, e.why, e.count) end
    local cand, value = mod.DejunkCandidate()
    add(("dejunk: full=%s reserve=%s maxQuality=%s team=%s looted=%s never=[%s] always=[%s]  destroyed=%d queued=%d asked=%d combat=%d  queue=[%s]  next cheapest=%s (%s)"):format(
        tostring(c.dejunkFull), tostring(c.reserve), tostring(c.dejunkMaxQuality), tostring(c.dejunkTeam), tostring(c.dejunkAlwaysLooted),
        Set(c.dejunkNever), Set(c.dejunkAlways), stats.destroyed, stats.queued, stats.asked, stats.skippedCombat,
        table.concat(q, " "), cand and tostring(cand.link) or "-", tostring(value)))
end
