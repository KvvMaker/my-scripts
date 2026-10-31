--[[
    Trade Helper GUI
    Drives the game's own TradeEvent protocol (AddItem / RemoveItem / Ready / Confirm / Cancel)
    with exactly the argument shapes the stock InTradePanel sends.

    TABS
      Trade       browse your inventory, build an offer, Ready / Confirm / Cancel
      Send Trade  send requests to players, answer incoming ones
      Pet Quests  shows your quest progress and auto-claims finished quests
      Auto Use    auto-use potions and fruits, auto-open crates (everything starts OFF)
      Mining      the game's own Auto Mine switch, or an own mining loop that needs no unlock
      Treats      Halloween Trick or Treat: pad timers, and auto-claim when a pad is ready
      Breakables  Halloween event: auto-hit breakables (and the boss when you're in its ring)
      Misc        rejoin / new server / server hop, copy join info, anti-AFK, hatch animation
      Hatch       auto-hatch any egg from anywhere (Events.Hatch), with an optional move-to-egg fallback

    USAGE
      * Execute BEFORE a trade is accepted. The script learns the TradeId from the server's
        "Accept" event, so a trade that was already open when you executed is not seen.
      * RightShift toggles the window. "X" fully unloads it (re-executing also replaces the old copy).
]]

local CONFIG = {
    SendDelay = 0.15,   -- seconds between queued sends (the stock UI throttles clicks to 0.1s)
    AutoDelay = 0.4,    -- reaction delay for Auto-Ready / Auto-Confirm
    ToggleKey = Enum.KeyCode.RightShift,
    HatchModes = { "Single", "Triple" },  -- second argument of Events.Hatch (add others you see the game send)
    HatchDelay = 0,         -- default pause between auto-hatches, after each HatchResult arrives
    BreakMargin = 1.02,     -- Auto-break: hit every (the game's cooldown x this); the small margin covers network jitter
    BreakReachMargin = 1,   -- Auto-break: hit only when this many studs inside the game's hit range (raise it if hits are ignored)
    MineMargin = 1.03,      -- Own Auto Mine: swing every (server's interval x this). 1.03 is what the game's own loop uses;
                            --   lower it toward 1.0 for a little more speed, raise it if swings start getting dropped
    AutoTick = 0.25,        -- Auto Use: how often the inventory is checked while Auto-use is ON
    CrateGap = 0.3,         -- Auto Use: minimum seconds between sends of the same crate
    CrateTimeout = 1,       -- Auto Use: no drop in the crate count after this long = the send was ignored
    HatchRetry = 0.6,       -- if the server ignores a request, fire again after this many seconds
    HatchTimeout = 4,       -- seconds with no HatchResult at all before auto-hatch counts it as a stall
    MaxFailures = 4,        -- consecutive unanswered requests before auto-hatch gives up
    ReturnAfterHatch = true, -- walk back to where you were if the script had to move you to an egg
}

local env = (getgenv and getgenv()) or _G
if env.TradeHelper and env.TradeHelper.Destroy then
    pcall(env.TradeHelper.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Events = ReplicatedStorage:WaitForChild("Events")
local TradeEvent = Events:WaitForChild("TradeEvent")
local HatchRemote = Events:WaitForChild("Hatch", 5)
local HatchResult = Events:WaitForChild("HatchResult", 5)
local Modules = ReplicatedStorage:WaitForChild("Modules")

----------------------------------------------------------------------
-- Game modules
----------------------------------------------------------------------
local function loadModule(name, parent)
    local m = (parent or Modules):FindFirstChild(name)
    if not m then
        warn("[TradeHelper] missing module: " .. name)
        return nil
    end
    local ok, res = pcall(require, m)
    if not ok then
        warn("[TradeHelper] failed to require " .. name .. ": " .. tostring(res))
        return nil
    end
    return res
end

local Abbreviate = loadModule("Abbreviate")
local Collectables = loadModule("Collectables")
local Eggs = loadModule("Eggs")
local Items = loadModule("Items")
local RarityList = loadModule("RarityList")
local Auras = loadModule("Auras")
local Hoverboards = loadModule("Hoverboards")
local Trading = loadModule("Trading")
local PetQuest = loadModule("PetQuest")
local Crates = loadModule("Crates")
local Mining = loadModule("Mining")
local Settings = loadModule("Settings")
local Hatching = Modules:FindFirstChild("Hatching")
local HatchAnimator = Hatching and loadModule("HatchAnimator", Hatching)
local ExclusiveHatchAnimator = Hatching and loadModule("ExclusiveHatchAnimator", Hatching)
local SecretHatchAnimator = Hatching and loadModule("SecretHatchAnimator", Hatching)

-- The panel receives its stats module (u4) as an argument, so find the live table in memory.
local function findStatsModule()
    if not getgc then return nil end
    local ok, gc = pcall(getgc, true)
    if not ok then return nil end

    local function looksRight(t)
        return type(rawget(t, "GetPetInfo")) == "function"
            and type(rawget(t, "GetStat")) == "function"
            and type(rawget(t, "Get")) == "function"
    end

    for _, v in ipairs(gc) do
        if type(v) == "table" and looksRight(v) then
            return v
        end
    end
    -- fallback: class-style module whose methods live behind __index
    for _, v in ipairs(gc) do
        if type(v) == "table" then
            local mt = getmetatable(v)
            local idx = type(mt) == "table" and rawget(mt, "__index")
            if type(idx) == "table" and looksRight(idx) then
                return v
            end
        end
    end
    return nil
end

local StatsMod = findStatsModule()
if not StatsMod then
    warn("[TradeHelper] stats module not found - inventory browsing disabled (offers/ready/confirm still work)")
end

local function try(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function fmt(n)
    local s = Abbreviate and try(Abbreviate.Format, n)
    return s or tostring(n)
end

local function getTokens()
    local v = StatsMod and try(StatsMod.GetStat, "Tokens")
    return math.max(0, math.floor(tonumber(v) or 0))
end

----------------------------------------------------------------------
-- Hatch animation patch
--   Normal  untouched
--   Hide    the game's own "HideEggAnimation" setting is reported as on (it still plays its short version)
--   Skip    the animators' Play / Watch become no-ops
-- HatchClient fires HatchDone itself right after Play returns, so the server is still acknowledged.
----------------------------------------------------------------------
local hatchMode = "Normal"
local hatchPatched = {}

local function rawAssign(tbl, key, value)
    if setreadonly then pcall(setreadonly, tbl, false) end
    return (pcall(function() tbl[key] = value end))
end

local function patchFunction(tbl, key, replacement)
    if type(tbl) ~= "table" or type(tbl[key]) ~= "function" then return false end
    local orig = tbl[key]
    if rawAssign(tbl, key, replacement) then
        table.insert(hatchPatched, { tbl = tbl, key = key, orig = orig })
        return true
    end
    return false
end

local function restoreHatch()
    for i = #hatchPatched, 1, -1 do
        local e = hatchPatched[i]
        rawAssign(e.tbl, e.key, e.orig)
    end
    table.clear(hatchPatched)
    hatchMode = "Normal"
end

-- returns how many hooks were installed (0 = nothing could be patched)
local function setHatchMode(mode)
    restoreHatch()
    local installed = 0
    if mode == "Hide" then
        if Settings and type(Settings.GetLocal) == "function" then
            local orig = Settings.GetLocal
            if patchFunction(Settings, "GetLocal", function(key, ...)
                if key == "HideEggAnimation" then return true end
                return orig(key, ...)
            end) then
                installed = installed + 1
            end
        end
    elseif mode == "Skip" then
        local function noop() end
        for _, target in ipairs({
            { HatchAnimator, "Play" },
            { ExclusiveHatchAnimator, "Play" },
            { ExclusiveHatchAnimator, "Watch" },
            { SecretHatchAnimator, "Play" },
        }) do
            if patchFunction(target[1], target[2], noop) then
                installed = installed + 1
            end
        end
    end
    if installed > 0 then hatchMode = mode end
    return installed
end

----------------------------------------------------------------------
-- Trade state (mirrors what InTradePanel tracks)
----------------------------------------------------------------------
local function emptyOffer()
    return { Tokens = 0, Pets = {}, Items = {}, Auras = {}, Boards = {} }
end

local state
local offers = { me = emptyOffer(), them = emptyOffer() }
local queue, queueRunning = {}, false
local destroyed = false
local autoReady, autoConfirm = false, false
local requestRefresh, setPage -- forward declarations (assigned in the GUI section)
local incoming = {}   -- TradeId -> { from = username, expires = os.clock() deadline }
local lastRequest = 0

local function resetState()
    state = state or {}
    state.tradeId = nil
    state.partner = nil
    state.ready = { me = false, them = false }
    state.bothReady = false
    state.confirmed = { me = false, them = false }
    state.bothConfirmed = false
    state.countdownEnd = nil
    state.tab = state.tab or "Pets"
    state.page = state.page or "Trade"
    state.shown = state.shown or {}
    state.flash = state.flash or ""
    state.flashUntil = state.flashUntil or 0
    offers.me = emptyOffer()
    offers.them = emptyOffer()
    table.clear(queue)
end
resetState()

local function flash(text, seconds)
    state.flash = text
    state.flashUntil = os.clock() + (seconds or 3)
end

-- Runs fn without letting an error kill the caller (UI callbacks, the refresh loop).
-- The error goes to the status bar, and to the console at most once per 5s per message.
local function guard(name, fn)
    local lastErr, lastAt = nil, 0
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            err = tostring(err)
            if err ~= lastErr or os.clock() - lastAt > 5 then
                lastErr, lastAt = err, os.clock()
                warn("[TradeHelper] " .. name .. ": " .. err)
            end
            flash(name .. " error: " .. err, 8)
        end
    end
end

-- A thread that resumes from inside a game function can come back with the game script's lower permissions,
-- after which it can't touch our GUI (hidden container): "lacking capability Plugin". Game calls that may
-- yield therefore run in their own throwaway threads, and the long-lived threads put their identity back.
local IDENTITY = (getthreadidentity and getthreadidentity()) or (getidentity and getidentity())
local function restoreIdentity()
    if IDENTITY and setthreadidentity then pcall(setthreadidentity, IDENTITY) end
end

local function isLocked()
    return state.confirmed.me or state.bothConfirmed
end

local function send(action, payload)
    if not state.tradeId then
        flash("No active trade")
        return false
    end
    payload = payload or {}
    payload.TradeId = state.tradeId
    TradeEvent:FireServer(action, payload)
    return true
end

local function enqueue(action, payload)
    table.insert(queue, { action, payload })
    if queueRunning then return end
    queueRunning = true
    task.spawn(function()
        while #queue > 0 and not destroyed do
            local job = table.remove(queue, 1)
            if state.tradeId then
                send(job[1], job[2])
            end
            task.wait(CONFIG.SendDelay)
        end
        queueRunning = false
    end)
end

local function payloadFor(rec, amount)
    if rec.kind == "Pet" then
        return { Type = "Pet", Key = rec.key, Amount = amount }
    elseif rec.kind == "Aura" then
        return { Type = "Aura", Key = rec.key, Amount = amount }
    elseif rec.kind == "Board" then
        return { Type = "Board", Key = rec.key, Amount = amount }
    end
    return { Type = "Item", ItemID = rec.key, Amount = amount }
end

local function addOffer(rec, amount)
    if not state.tradeId then return flash("No active trade") end
    if isLocked() then return flash("Offer is locked") end
    amount = math.clamp(math.floor(amount), 1, math.max(1, rec.amount))
    enqueue("AddItem", payloadFor(rec, amount))
end

local function removeOffer(rec, amount)
    if not state.tradeId then return flash("No active trade") end
    if isLocked() then return flash("Offer is locked") end
    amount = math.clamp(math.floor(amount), 1, math.max(1, rec.amount))
    enqueue("RemoveItem", payloadFor(rec, amount))
end

local function setTokens(target)
    if not state.tradeId then return flash("No active trade") end
    if isLocked() then return flash("Offer is locked") end
    target = math.clamp(math.floor(target), 0, getTokens())
    local cur = offers.me.Tokens
    if target > cur then
        enqueue("AddItem", { Type = "Tokens", Amount = target - cur })
    elseif target < cur then
        enqueue("RemoveItem", { Type = "Tokens", Amount = cur - target })
    end
end

----------------------------------------------------------------------
-- Trade requests (mirrors SendTradePanel)
----------------------------------------------------------------------
local function tradingUnlocked()
    if not (Trading and Trading.IsUnlocked and Trading.GetEggs) then return true end
    local ok, unlocked = pcall(function()
        return Trading.IsUnlocked(Trading.GetEggs(LocalPlayer))
    end)
    return (not ok) or unlocked == true -- if the check itself fails, let the server decide
end

local function requestTimeout()
    return (Trading and tonumber(Trading.REQUEST_TIMEOUT)) or 30
end

local function sendRequest(plr)
    if not plr.Parent then return flash("That player left") end
    if not tradingUnlocked() then
        return flash("Trading locked - open " .. tostring(Trading and Trading.EGGS_REQUIRED or "more") .. " eggs first")
    end
    local cooldown = (Trading and tonumber(Trading.REQUEST_COOLDOWN)) or 1
    local remaining = cooldown - (os.clock() - lastRequest)
    if remaining > 0 then
        return flash(("Wait %.1fs before sending another request"):format(remaining), 2)
    end
    lastRequest = os.clock()
    TradeEvent:FireServer("Request", { Target = plr.Name })
    flash("Sending request to " .. plr.DisplayName .. "...", 2)
end

local function respondToRequest(id, accept)
    TradeEvent:FireServer(accept and "Accept" or "Decline", { TradeId = id })
    if not accept then incoming[id] = nil end
end

----------------------------------------------------------------------
-- Auto hatch
--   Events.Hatch:FireServer(eggName, mode)  ->  server answers with HatchResult on the client.
--   HatchClient fires HatchDone itself once its animation (or the skipped version) is over.
----------------------------------------------------------------------
local HATCH_MODES = CONFIG.HatchModes
local H = {
    mode = 1, running = false, goToEgg = true, turbo = false,
    total = 0, shinies = 0, batch = 0, recent = {},   -- recent = newest-first pet names
    samples = {}, reply = nil, lastResultAt = 0,   -- speed readout
    bind = Instance.new("BindableEvent"), waiting = false, waitId = 0,
    status = "Idle", home = nil,
}

local function onHatchResult(entries)
    local now = os.clock()
    H.lastResultAt = now
    if H.waiting then -- wake hatchOnce() the instant the reply arrives, no polling
        H.waiting = false
        H.bind:Fire(true)
    end
    if type(entries) == "table" then
        local names = {}
        for _, e in ipairs(entries) do
            if type(e) == "table" then
                H.total = H.total + 1
                if e.shiny == true then H.shinies = H.shinies + 1 end
                table.insert(names, tostring(e.petName) .. (e.shiny == true and " (shiny)" or ""))
            end
        end
        if #names > 0 then
            H.batch = #names
            for i = #names, 1, -1 do table.insert(H.recent, 1, names[i]) end
            while #H.recent > 6 do table.remove(H.recent) end
        end
    end
    table.insert(H.samples, { t = now, n = H.total })
    while #H.samples > 0 and now - H.samples[1].t > 8 do table.remove(H.samples, 1) end
end

-- eggs per second over the last 5 seconds (nil when there is nothing recent to measure)
local function hatchRate()
    local now, first, last = os.clock(), nil, nil
    for _, s in ipairs(H.samples) do
        if now - s.t <= 5 then
            first = first or s
            last = s
        end
    end
    if first and last and last.t > first.t then
        return (last.n - first.n) / (last.t - first.t)
    end
    return nil
end

local function listEggs()
    local names = {}
    if Eggs and type(Eggs.Eggs) == "table" then
        for name in pairs(Eggs.Eggs) do
            if type(name) == "string" then table.insert(names, name) end
        end
    end
    table.sort(names)
    return names
end

-- best effort: find the egg's stand in Workspace by name (ignoring case, spaces and underscores)
local standCache = {}
local function norm(s)
    return (string.lower(s):gsub("[%s_]", ""))
end

local function inACharacter(inst)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character and inst:IsDescendantOf(plr.Character) then return true end
    end
    return false
end

local function eggHolders()
    local scripted = workspace:FindFirstChild("Scripted")
    return scripted and scripted:FindFirstChild("EggHolders")
end

local function findEggStand(egg)
    local cached = standCache[egg]
    if cached and cached.Parent then return cached end
    local want = norm(egg)
    -- the game keeps its egg stands in workspace.Scripted.EggHolders; fall back to the whole workspace
    for _, root in ipairs({ eggHolders() or workspace, workspace }) do
        for _, inst in ipairs(root:GetDescendants()) do
            if (inst:IsA("Model") or inst:IsA("BasePart")) and norm(inst.Name) == want and not inACharacter(inst) then
                standCache[egg] = inst
                return inst
            end
        end
        if root == workspace then break end
    end
    return nil
end

local function moveToEgg(egg)
    local stand = findEggStand(egg)
    if not stand then
        local names = {}
        local holders = eggHolders()
        if holders then
            for _, c in ipairs(holders:GetChildren()) do
                if #names >= 5 then break end
                table.insert(names, c.Name)
            end
        end
        return false, ("no '%s' stand found%s"):format(egg, #names > 0 and (" (EggHolders has: " .. table.concat(names, ", ") .. ")") or "")
    end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false, "no character" end
    local cf = stand:IsA("Model") and stand:GetPivot() or stand.CFrame
    H.home = H.home or hrp.CFrame
    hrp.CFrame = cf + Vector3.new(0, 4, 0)
    return true
end

-- fires one hatch request; true if the server's HatchResult arrives within `timeout` seconds
local function hatchOnce(egg, mode, timeout)
    local sent = os.clock()
    H.waitId = H.waitId + 1
    local id = H.waitId
    H.waiting = true
    HatchRemote:FireServer(egg, mode)
    task.delay(timeout, function()
        if H.waiting and H.waitId == id then -- still this wait: give up on it
            H.waiting = false
            H.bind:Fire(false)
        end
    end)
    local got = H.bind.Event:Wait()
    if got then H.reply = os.clock() - sent end
    return got
end

-- once  = hatch a single time; otherwise keep going until stopAuto() or a stall
-- delay = seconds to pause after each hatch (defaults to CONFIG.HatchDelay)
-- turbo = fire on a fixed timer without waiting for each reply (the server drops what it can't take)
local function startAuto(egg, mode, allowMove, once, delay, turbo)
    if H.running then return end
    if not (HatchRemote and HatchResult) then
        H.status = "Hatch / HatchResult remote not found"
        return
    end
    if egg == "" then
        H.status = "Pick an egg first"
        return
    end
    delay = delay or CONFIG.HatchDelay
    turbo = turbo and not once
    local runningText = turbo and "Running (turbo)" or "Running"
    H.running = true
    H.status = runningText
    task.spawn(function()
        local fails, moved, stallAt = 0, false, 0

        -- no reply for CONFIG.HatchTimeout: move next to the egg once, then give up after MaxFailures
        local function stalled()
            fails = fails + 1
            stallAt = os.clock()
            if allowMove and not moved then
                moved = true
                local ok, why = moveToEgg(egg)
                H.status = ok and "No response - moved next to the egg, retrying" or ("No response, couldn't move: " .. why)
                return false
            elseif fails >= CONFIG.MaxFailures then
                H.status = "Stopped: the server isn't answering (currency? egg name? animation still playing?)"
                return true
            end
            H.status = ("No response (%d/%d)..."):format(fails, CONFIG.MaxFailures)
            return false
        end

        local lastGood = os.clock()
        H.lastResultAt = lastGood
        while H.running and not destroyed do
            if turbo then
                HatchRemote:FireServer(egg, mode)
                task.wait(math.max(delay, 0.05))
                if fails > 0 and H.lastResultAt > stallAt then
                    fails = 0
                    H.status = runningText
                end
                if os.clock() - math.max(H.lastResultAt, stallAt) >= CONFIG.HatchTimeout then
                    if stalled() then break end
                end
            elseif hatchOnce(egg, mode, once and CONFIG.HatchTimeout or CONFIG.HatchRetry) then
                lastGood = os.clock()
                if fails > 0 then
                    fails = 0
                    H.status = runningText
                end
                if once then
                    H.status = "Hatched"
                    break
                end
                if delay > 0 then task.wait(delay) end
            elseif once or os.clock() - lastGood >= CONFIG.HatchTimeout then
                if stalled() then break end
                lastGood = os.clock()
                task.wait(0.5)
            end
            -- otherwise a request was dropped or slow: loop and fire again straight away
        end
        H.running = false
        if H.status == "Running" or H.status == "Stopping..." then H.status = "Stopped" end
        if H.home and CONFIG.ReturnAfterHatch and not destroyed then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then hrp.CFrame = H.home end
        end
        H.home = nil
    end)
end

local function stopAuto()
    if H.running then
        H.running = false
        H.status = "Stopping..."
        if H.waiting then -- don't make Stop wait out a pending reply
            H.waiting = false
            H.bind:Fire(false)
        end
    end
end

----------------------------------------------------------------------
-- Pet quests
--   Functions.PetQuestAction:InvokeServer("Get")      -> { Tier, Claimed, Progress, Percent }
--   Functions.PetQuestAction:InvokeServer("Upgrade")  -> same shape; this is what the panel's button sends to claim
--   "Upgrade" is only sent after a fresh "Get" shows a finished, unclaimed quest in the current tier.
----------------------------------------------------------------------
local Q = {
    auto = false, interval = 5, busy = false, lastPoll = 0,
    state = nil, version = 0, status = "Open this page to check your quests.",
}
Q.remote = (function()
    local folder = ReplicatedStorage:WaitForChild("Functions", 5)
    return folder and folder:WaitForChild(PetQuest and PetQuest.REMOTE or "PetQuestAction", 5)
end)()

-- one request/response; returns the state table, or nil plus a reason
local function questCall(action)
    if not Q.remote then return nil, "PetQuestAction remote not found" end
    local done, ok, result = false, nil, nil
    task.spawn(function()
        ok, result = pcall(function() return Q.remote:InvokeServer(action) end)
        done = true
    end)
    local started = os.clock()
    while not done and os.clock() - started < 10 and not destroyed do task.wait(0.05) end
    if not done then return nil, "timed out after 10s" end
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then return nil, "the server answered with " .. typeof(result) end
    return result
end

-- the current tier's quests, classified the same way the game's panel does; returns (list, readyCount)
function Q.classify(qs)
    local list, ready = {}, 0
    if type(qs) ~= "table" or not PetQuest then return list, ready end
    local tier = PetQuest.TIERS[tonumber(qs.Tier) or 1]
    local claimed = type(qs.Claimed) == "table" and qs.Claimed or {}
    local progress = type(qs.Progress) == "table" and qs.Progress or {}
    for i, quest in ipairs(tier and tier.quests or {}) do
        local value = tonumber(progress[i]) or 0
        local status = "active"
        if claimed[tostring(i)] then
            status = "claimed"
        elseif quest.amount <= value then
            status = "ready"
            ready = ready + 1
        end
        list[i] = { quest = quest, value = value, status = status }
    end
    return list, ready
end

-- asks for the state; claims when claimNow (or auto-claim is on) and something is ready
function Q.refresh(claimNow)
    if Q.busy or destroyed then return end
    Q.busy = true
    Q.lastPoll = os.clock()
    task.spawn(function()
        local qs, err = questCall("Get")
        if not qs then
            Q.status = "No answer from the server: " .. tostring(err)
        else
            Q.state = qs
            Q.version = Q.version + 1
            local _, ready = Q.classify(qs)
            if (claimNow or Q.auto) and ready > 0 then
                local after, aerr = questCall("Upgrade")
                if after then
                    local _, left = Q.classify(after)
                    local got = (tonumber(after.Tier) ~= tonumber(qs.Tier)) and ready or (ready - left)
                    Q.state = after
                    Q.version = Q.version + 1
                    Q.status = got > 0 and ("Claimed %d quest%s"):format(got, got == 1 and "" or "s")
                        or "Sent Upgrade, but the server didn't claim anything"
                else
                    Q.status = "Upgrade failed: " .. tostring(aerr)
                end
            elseif claimNow then
                Q.status = "Nothing is ready to claim yet"
            else
                Q.status = "Up to date"
            end
        end
        Q.busy = false
    end)
end

-- called from the update loop: poll while the page is open or auto-claim is on
function Q.tick()
    if not (Q.auto or state.page == "Quests") then return end
    if os.clock() - Q.lastPoll < Q.interval then return end
    Q.refresh(false)
end

----------------------------------------------------------------------
-- Auto use (potions, fruits, crates)
--   Events.UseItem:FireServer(itemName, 1 | 5 | 25 | "all")   what the inventory's USE button sends
--   Events.OpenCrate:FireServer(crateName, amount)            amount comes from Crates.ClampAmount
--   Game modules are only touched by the worker thread below; the GUI just reads what it caches in A.
----------------------------------------------------------------------
local USE_AMOUNTS = { 1, 5, 25, "all" }
local A = {
    on = false, confirmCrates = false, amountIndex = 1, reuse = nil,
    potions = {}, crates = {},          -- itemName -> true while auto is enabled for it
    lastUse = {}, pending = {},         -- pending[name] = { t, count } until the count change is seen
    fails = {}, totals = {},            -- consecutive crate no-ops / running totals for the activity log
    view = { potions = {}, crates = {} }, sig = "", log = {}, force = false,
    useItem = Events:WaitForChild("UseItem", 5),
    openCrate = Events:WaitForChild("OpenCrate", 5),
}

-- one line per key: repeating events update their line (and its running total) instead of flooding the log
local function aLog(text, key)
    key = key or text
    for i, entry in ipairs(A.log) do
        if entry.key == key then
            table.remove(A.log, i)
            break
        end
    end
    table.insert(A.log, 1, { key = key, text = os.date("%H:%M:%S") .. "  " .. text })
    while #A.log > 8 do table.remove(A.log) end
end

local function tally(key, n)
    A.totals[key] = (A.totals[key] or 0) + n
    return A.totals[key]
end

-- what an item is never changes, so ask the game once per item instead of on every scan
local classCache = {}
local function classify(name)
    local c = classCache[name]
    if c ~= nil then return c end
    c = false
    local item = Items and try(Items.GetItem, name)
    if item then
        local section = tostring(item.section)
        local info = { item = item, display = tostring(item.displayName or name), order = tonumber(item.layout) or 0 }
        if Crates and try(Crates.IsCrate, name) then
            info.kind = "crate"
            info.confirm = try(Crates.NeedsConfirm, name) == true
            c = info
        elseif (section == "Potion" or section == "Fruit") and try(Items.IsConsumable, item) then
            info.kind = "potion"
            c = info
        end
    end
    classCache[name] = c
    return c
end

-- everything the inventory has (or that we're set to auto-use), split into potions/fruits and crates
local function scanInventory()
    local data = (StatsMod and try(StatsMod.Get)) or {}
    local owned = data.Items or {}
    local potions, crates, byName = {}, {}, {}

    local function add(name, count)
        local c = name ~= "Tokens" and classify(name)
        if not c then return end
        local entry = { name = name, item = c.item, display = c.display, order = c.order, confirm = c.confirm, count = count }
        if c.kind == "crate" then
            entry.enabled = A.crates[name] == true
            crates[#crates + 1] = entry
        else
            entry.enabled = A.potions[name] == true
            potions[#potions + 1] = entry
        end
        byName[name] = entry
    end

    local seen = {}
    for name, v in pairs(owned) do
        local count = (type(v) == "number" and v) or (type(v) == "table" and (v.Amount or 0)) or 0
        if count > 0 then
            seen[name] = true
            add(name, count)
        end
    end
    for name in pairs(A.potions) do if not seen[name] then add(name, 0) end end
    for name in pairs(A.crates) do if not seen[name] then add(name, 0) end end

    local function byOrder(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.display < b.display
    end
    table.sort(potions, byOrder)
    table.sort(crates, byOrder)
    return potions, crates, byName
end

function A.step()
    local potions, crates, byName = scanInventory()
    A.view = { potions = potions, crates = crates }
    local parts = {}
    for _, group in ipairs({ potions, crates }) do
        for _, e in ipairs(group) do
            parts[#parts + 1] = e.name .. ":" .. e.count .. ":" .. tostring(e.enabled)
        end
    end
    A.sig = table.concat(parts, "|")
    if not A.on then return end

    local now = os.clock()

    -- the inventory count is the server's answer: a drop means it took what we sent
    for name, p in pairs(A.pending) do
        local e = byName[name]
        local count = e and e.count or 0
        local label = e and e.display or name
        if count < p.count then
            A.pending[name] = nil
            A.fails[name] = nil
            local key = (p.crate and "open:" or "use:") .. name
            aLog(("%s %s x%d total"):format(p.crate and "Opened" or "Used", label, tally(key, p.count - count)), key)
        elseif now - p.t >= (p.crate and CONFIG.CrateTimeout or 1.5) then
            A.pending[name] = nil
            if p.crate then
                -- no change: retry, but give up on a crate the server keeps ignoring
                A.fails[name] = (A.fails[name] or 0) + 1
                if A.fails[name] >= 3 then
                    A.crates[name] = nil
                    A.fails[name] = nil
                    aLog("Stopped opening " .. label .. " (the server isn't taking them)")
                end
            else
                aLog(label .. " wasn't consumed (server said no - still active?)", "refused:" .. name)
            end
        end
    end

    local amount = USE_AMOUNTS[A.amountIndex]
    for _, e in ipairs(potions) do
        if e.enabled and e.count > 0 and not A.pending[e.name] then
            -- re-use after the item's own duration so a potion isn't wasted while one is still running
            local period = A.reuse or tonumber(e.item.duration) or 300
            if now - (A.lastUse[e.name] or -1e9) >= period then
                if not A.useItem then
                    aLog("Events.UseItem not found")
                    A.on = false
                    return
                end
                A.lastUse[e.name] = now
                A.pending[e.name] = { t = now, count = e.count }
                A.useItem:FireServer(e.name, amount == "all" and "all" or math.min(amount, e.count))
            end
        end
    end

    for _, e in ipairs(crates) do
        if e.enabled and e.count > 0 and not A.pending[e.name] and (not e.confirm or A.confirmCrates) then
            if now - (A.lastUse[e.name] or -1e9) >= CONFIG.CrateGap then
                if not A.openCrate then
                    aLog("Events.OpenCrate not found")
                    A.on = false
                    return
                end
                A.lastUse[e.name] = now
                A.pending[e.name] = { t = now, count = e.count, crate = true }
                A.openCrate:FireServer(e.name, (Crates and try(Crates.ClampAmount, e.count)) or e.count)
            end
        end
    end
end

task.spawn(function()
    while not destroyed do
        if A.on or state.page == "Auto" then
            local ok, err = pcall(A.step)
            if not ok then
                A.on = false
                aLog("Stopped: " .. tostring(err))
            end
        end
        task.wait(A.on and CONFIG.AutoTick or 1)
    end
end)

----------------------------------------------------------------------
-- Auto Mine
--   The game's mining loop is driven by a local flag inside its own client script, so the only way to
--   switch it on is the way a player does: press the "AutoMine" button it builds in Main.Buttons2.
--   That button's label ("Auto: ON" / "Auto: OFF" / "Auto: LOCKED") is also how we read the real state.
--   Game modules are only touched by the worker thread; the GUI reads M.snap and M.status.
----------------------------------------------------------------------
local M = {
    want = false, wasWant = false, lastClick = 0, snap = {}, status = "Open this page to check Auto Mine.",
    own = false, ownStatus = "Off.", hits = 0, nextSwing = 0, hopping = false, -- our own mining loop
}

local function findMiningState()
    local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local ui = scripts and scripts:FindFirstChild("UI")
    local module = ui and ui:FindFirstChild("MiningClientState")
    if not module then return nil end
    local ok, result = pcall(require, module)
    return ok and result or nil
end

-- returns the game's AutoMine button's Click child and its status label
local function findAutoButton()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local buttons = main and main:FindFirstChild("Buttons2")
    local button = buttons and buttons:FindFirstChild("AutoMine", true)
    if not button then return nil, nil end
    return button:FindFirstChild("Click"), button:FindFirstChild("Timer") or button:FindFirstChildWhichIsA("TextLabel")
end

local function pressButton(click)
    if firesignal and pcall(firesignal, click.MouseButton1Click) then return true end
    if getconnections then
        return (pcall(function()
            for _, c in ipairs(getconnections(click.MouseButton1Click)) do c:Fire() end
        end))
    end
    return false
end

function M.step()
    M.cs = M.cs or findMiningState()
    local cs = M.cs
    local inMine = Mining ~= nil and LocalPlayer:GetAttribute(Mining.IN_MINE_ATTRIBUTE) == true
    local qs = cs and try(cs.Get)
    local unlocked = qs ~= nil and Mining ~= nil and try(Mining.IsAutoUnlocked, qs.Upgrades) == true
    local click, label = findAutoButton()
    local labelText = label and label.Text or ""
    local autoOn = labelText == "Auto: ON"

    -- what the page shows
    local snap = { inMine = inMine, auto = unlocked and (autoOn and "ON" or "OFF") or (qs and "LOCKED" or "?") }
    local stats = LocalPlayer:FindFirstChild("ReplicatedStats")
    if Mining and stats then snap.ore = tonumber(stats:GetAttribute(Mining.CURRENCY)) end
    local pick = cs and try(cs.GetPickaxe)
    if type(pick) == "table" then
        snap.pickaxe = tostring(pick.name or pick.displayName or "")
        snap.power = tonumber(pick.power)
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if Mining and root then
        local key = try(Mining.GetZoneForPosition, root.Position)
        local zone = key and Mining.ZoneByKey and Mining.ZoneByKey[key]
        snap.zone = zone and zone.name or (key and tostring(key)) or nil
    end
    M.snap = snap

    if M.want then
        if not (Mining and cs) then
            M.status = "Mining modules not found, so Auto Mine can't be switched."
        elseif not unlocked then
            local info = Mining.UpgradeByKey and Mining.UpgradeByKey.AutoMine
            M.status = ("Locked: unlock Auto Mine in Mining Upgrades first (%s %s)."):format(
                fmt(info and info.base or 0), tostring(Mining.CURRENCY))
        elseif not inMine then
            M.status = "Waiting for you to enter the mine. It switches on when you do."
        elseif not click then
            M.status = "Couldn't find the game's Auto Mine button."
        elseif autoOn then
            M.status = "Auto Mine is running."
        elseif os.clock() - M.lastClick > 2 then
            M.lastClick = os.clock()
            if pressButton(click) then
                M.status = "Switched Auto Mine on."
            else
                M.status = "Your executor can't press the game's button (it needs firesignal or getconnections)."
                M.want = false
            end
        else
            M.status = "Switching on..."
        end
    else
        if M.wasWant and autoOn and click then pressButton(click) end -- the switch went off: turn the game's off too
        M.status = autoOn and "Auto Mine is ON in the game; this switch is off, so it isn't touching it." or "Off."
    end
    M.wasWant = M.want
end

task.spawn(function()
    while not destroyed do
        if M.want or M.wasWant or state.page == "Mine" then
            local ok, err = pcall(M.step)
            if not ok then
                M.want = false
                M.wasWant = false
                M.status = "Error: " .. tostring(err)
            end
        end
        task.wait(0.5)
    end
end)

----------------------------------------------------------------------
-- Own Auto Mine (needs no Auto Mine unlock)
--   Does what a player does by hand: stand next to ore and swing at the manual interval.
--   A swing is  Events.MiningHit:FireServer(node, false)  where node is a child of
--   workspace.Scripted.Islands.Mine.Nodes. Swings are paced by the interval the server reports
--   (MiningClientState.Get().Swing), so range and cooldown stay the server's rules.
--   Like the game's own auto, it stays in your current zone when you can mine it, otherwise it
--   goes to the best zone you can. Boss nodes are left alone.
--   This loop never touches the GUI; the page reads M.own, M.ownStatus, M.hits and M.ore*.
----------------------------------------------------------------------
do
    local hitRemote = Events:FindFirstChild((Mining and Mining.HIT_EVENT) or "MiningHit") or Events:WaitForChild("MiningHit", 5)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.RespectCanCollide = true

    local function nodesFolder()
        local scripted = workspace:FindFirstChild("Scripted")
        local islands = scripted and scripted:FindFirstChild("Islands")
        local mine = islands and islands:FindFirstChild("Mine")
        return mine and mine:FindFirstChild("Nodes")
    end

    local function alive()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and hum and hum.Health > 0 then return root, hum end
        return nil, nil
    end

    -- can this node be mined right now with the zones you've unlocked and your pickaxe? (the game's own rule)
    local function usable(node, folder)
        if not node or node.Parent ~= folder or node:GetAttribute("Boss") == true then return false end
        if (tonumber(node:GetAttribute("HP")) or 0) <= 0 then return false end
        local zone = Mining.ZoneByKey[node:GetAttribute("Zone")]
        if not zone or not M.cs.IsZoneUnlocked(zone.key) then return false end
        local pick = M.cs.GetPickaxe()
        return type(pick) == "table" and (tonumber(pick.power) or 0) >= zone.power
    end

    local function reach() return Mining.HIT_RANGE - 4 end -- stay inside the server's range with some margin

    local function nearestInReach(root, folder)
        local best, bestDist = nil, reach()
        for _, node in ipairs(folder:GetChildren()) do
            if node:IsA("Model") then
                local d = (node:GetPivot().Position - root.Position).Magnitude
                if d <= bestDist and usable(node, folder) then best, bestDist = node, d end
            end
        end
        return best
    end

    -- Where to go when nothing is in reach. Candidates are the ore in the current zone (or, if you can't mine
    -- here, the best zone you can). Among those it picks the SPOT with the most ore within reach, because a hop
    -- costs 0.25-0.85s and a good pickaxe kills a node in a swing or two; ties go to the nearest.
    local function pickDestination(root, folder)
        local key = try(Mining.GetZoneForPosition, root.Position)
        local zone = key and Mining.ZoneByKey[key]
        local pick = M.cs.GetPickaxe()
        local stay = zone ~= nil and M.cs.IsZoneUnlocked(zone.key) and type(pick) == "table"
            and (tonumber(pick.power) or 0) >= zone.power

        local candidates, topRank = {}, -1
        for _, node in ipairs(folder:GetChildren()) do
            if node:IsA("Model") and usable(node, folder) then
                local nodeZone = node:GetAttribute("Zone")
                if not stay or nodeZone == zone.key then
                    local rank = stay and 0 or (Mining.ZoneIndex[nodeZone] or 0)
                    candidates[#candidates + 1] = { node = node, pos = node:GetPivot().Position, rank = rank }
                    if rank > topRank then topRank = rank end
                end
            end
        end

        local best, bestCount, bestDist = nil, 0, math.huge
        local cluster = reach() - 3 -- the landing spot sits a little off the ore, so count a bit inside the reach
        for _, c in ipairs(candidates) do
            if c.rank == topRank then
                local count = 0
                for _, other in ipairs(candidates) do
                    if other.rank == topRank and (other.pos - c.pos).Magnitude <= cluster then count = count + 1 end
                end
                local d = (c.pos - root.Position).Magnitude
                if count > bestCount or (count == bestCount and d < bestDist) then
                    best, bestCount, bestDist = c.node, count, d
                end
            end
        end
        return best
    end

    -- the same short arc-hop the game's own auto uses to get next to a node
    local function hop(root, hum, node, folder)
        local pos = node:GetPivot().Position
        local away = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
        local dir = (away.Magnitude < 0.1 and Vector3.new(0, 0, 1) or away).Unit
        local ext = node:GetExtentsSize()
        local landing = pos + dir * (math.max(ext.X, ext.Z) * 0.5 + 2.5)
        rayParams.FilterDescendantsInstances = { LocalPlayer.Character, folder }
        local floor = workspace:Raycast(Vector3.new(landing.X, pos.Y + 10, landing.Z), Vector3.new(0, -30, 0), rayParams)
        if not floor then return false end
        local from = root.Position
        local to = Vector3.new(landing.X, floor.Position.Y + hum.HipHeight + root.Size.Y / 2 + 0.1, landing.Z)
        local dist = (to - from).Magnitude
        local duration = math.clamp(0.2 + dist / 90, 0.25, 0.85)
        local arc = math.clamp(dist * 0.25, 2.5, 6)
        local started = os.clock()
        while M.own and not destroyed do
            if alive() ~= root then return false end
            local t = math.min(1, (os.clock() - started) / duration)
            local p = from:Lerp(to, t) + Vector3.new(0, math.sin(math.pi * t) * arc, 0)
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.lookAt(p, Vector3.new(pos.X, p.Y, pos.Z))
            if t >= 1 then return true end
            RunService.Heartbeat:Wait()
        end
        return false
    end

    local function oreNow()
        local stats = LocalPlayer:FindFirstChild("ReplicatedStats")
        return stats and tonumber(stats:GetAttribute(Mining.CURRENCY)) or nil
    end

    function M.ownStep()
        -- cheapest check first: this runs every frame, and most frames there is nothing to do yet
        local now = os.clock()
        if now < M.nextSwing or M.hopping then return end

        M.cs = M.cs or findMiningState()
        if not (Mining and M.cs and hitRemote) then
            M.ownStatus = "Mining modules or the MiningHit remote weren't found."
            M.own = false
            return
        end
        if LocalPlayer:GetAttribute(Mining.IN_MINE_ATTRIBUTE) ~= true then
            M.ownStatus = "Waiting for you to enter the mine..."
            M.nextSwing = now + 0.25
            return
        end
        if now - (M.autoCheckAt or 0) > 1 then -- the game's button state barely changes, so look once a second
            M.autoCheckAt = now
            local _, label = findAutoButton()
            M.gameAutoOn = label ~= nil and label.Text == "Auto: ON"
        end
        if M.gameAutoOn then
            M.ownStatus = "The game's own Auto Mine is on. Turn it off so the two don't double-hit."
            M.nextSwing = now + 0.5
            return
        end
        local folder = nodesFolder()
        local root, hum = alive()
        if not folder then M.ownStatus = "Couldn't find the mine's Nodes folder." M.nextSwing = now + 0.5 return end
        if not root then M.ownStatus = "Waiting for your character..." M.nextSwing = now + 0.25 return end

        local target = M.target
        if not (target and usable(target, folder) and (target:GetPivot().Position - root.Position).Magnitude <= reach()) then
            target = nearestInReach(root, folder)
            M.target = target
        end

        if target then
            local qs = try(M.cs.Get)
            local interval = (qs and tonumber(qs.Swing)) or Mining.GetSwingInterval(nil, nil, false)
            M.nextSwing = now + interval * CONFIG.MineMargin
            if hum.MoveDirection.Magnitude < 0.1 then -- face the ore like a player would
                local p = target:GetPivot().Position
                root.CFrame = CFrame.lookAt(root.Position, Vector3.new(p.X, root.Position.Y, p.Z))
            end
            if pcall(function() hitRemote:FireServer(target, false) end) then M.hits = M.hits + 1 end
            local ore = oreNow()
            if ore then
                M.oreStart = M.oreStart or ore
                M.oreNow = ore
            end
            local zone = Mining.ZoneByKey[target:GetAttribute("Zone")]
            M.ownStatus = "Mining " .. (zone and zone.name or "ore") .. "."
        else
            local dest = pickDestination(root, folder)
            if dest then
                M.ownStatus = "Moving to ore..."
                M.hopping = true
                local ok = pcall(hop, root, hum, dest, folder)
                M.hopping = false
                M.nextSwing = os.clock() + (ok and 0.15 or 0.5)
            else
                M.ownStatus = "No ore you can mine right now (zone locks or pickaxe power?)."
                M.nextSwing = now + 1
            end
        end
    end

    task.spawn(function()
        while not destroyed do
            if M.own then
                local ok, err = pcall(M.ownStep)
                if not ok then
                    M.own = false
                    M.hopping = false
                    M.ownStatus = "Stopped: " .. tostring(err)
                end
                RunService.Heartbeat:Wait() -- once per frame, so a swing goes out within ~8ms of being due
            else
                task.wait(0.3)
            end
        end
    end)
end

----------------------------------------------------------------------
-- Trick or Treat (Halloween event)
--   Pads are the children of workspace.Halloween26.Objects.TrickOrTreat. A pad is ready when its ReadyAt
--   attribute <= workspace:GetServerTimeNow() (in the game's "Local" mode the cooldowns arrive through
--   Remotes.TrickOrTreatState instead). Remotes.TreatClaimed fires when a claim goes through.
--   The game's TrickOrTreatController only DISPLAYS pads, so claiming is done the way a player does it:
--   stand at the pad and use whatever it has (a ProximityPrompt, or a touch part), detected at runtime.
--   This worker never touches the GUI; the page reads T.view, T.status, T.claims.
----------------------------------------------------------------------
local T = {
    auto = false, request = nil, status = "Open this page to scan for pads.",
    state = {}, claimedAt = {}, triedAt = {}, claims = 0, view = {}, sig = "", home = nil,
}

do
    local rayless = Vector3.new(0, 3, 0) -- stand a little above the claim point

    local function padsFolder()
        local root = workspace:FindFirstChild("Halloween26")
        local objects = root and root:FindFirstChild("Objects")
        return objects and objects:FindFirstChild("TrickOrTreat")
    end

    local function aliveChar()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and hum and hum.Health > 0 then return root, hum end
        return nil, nil
    end

    local function readyAt(pad)
        local attr = pad:GetAttribute("ReadyAt")
        if type(attr) == "number" then return attr end
        return tonumber(T.state[pad.Name]) or 0
    end

    -- what a player would use on this pad: its ProximityPrompt, else a part that has a touch listener
    local function claimPoint(pad)
        local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then return "prompt", prompt end
        for _, d in ipairs(pad:GetDescendants()) do
            if d:IsA("TouchTransmitter") and d.Parent:IsA("BasePart") then return "touch", d.Parent end
        end
        return nil, nil
    end

    local function pointPosition(pad, kind, target)
        if kind == "prompt" then
            local p = target.Parent
            if p and p:IsA("BasePart") then return p.Position end
            if p and p:IsA("Attachment") then return p.WorldPosition end
        elseif kind == "touch" then
            return target.Position
        end
        return pad:GetPivot().Position
    end

    -- "Part x3, Billboard x1, ..." so an unknown pad can be described to me
    local function describe(pad)
        local counts, order = {}, {}
        for _, d in ipairs(pad:GetDescendants()) do
            if not counts[d.ClassName] then
                counts[d.ClassName] = 0
                order[#order + 1] = d.ClassName
            end
            counts[d.ClassName] = counts[d.ClassName] + 1
        end
        local out = {}
        for i, class in ipairs(order) do
            if i > 8 then break end
            out[#out + 1] = class .. " x" .. counts[class]
        end
        return table.concat(out, ", ")
    end

    -- keep our own copy of the cooldowns and notice confirmed claims (the remotes appear with the event)
    task.spawn(function()
        local remotes
        for _ = 1, 20 do
            local root = ReplicatedStorage:FindFirstChild("Halloween26")
            local shared = root and root:FindFirstChild("Shared")
            remotes = shared and shared:FindFirstChild("Remotes")
            if remotes or destroyed then break end
            task.wait(1)
        end
        if not remotes then return end
        local stateEvent = remotes:FindFirstChild("TrickOrTreatState")
        if stateEvent then
            stateEvent.OnClientEvent:Connect(function(data)
                if destroyed or type(data) ~= "table" then return end
                for name, value in pairs(data) do T.state[name] = value end
            end)
        end
        local claimedEvent = remotes:FindFirstChild("TreatClaimed")
        if claimedEvent then
            claimedEvent.OnClientEvent:Connect(function(data)
                if destroyed or type(data) ~= "table" or not data.Pad then return end
                T.claimedAt[data.Pad] = os.clock()
                T.claims = T.claims + 1
            end)
        end
    end)

    function T.scan()
        local folder = padsFolder()
        if not folder then
            T.view, T.sig = {}, "none"
            T.status = "No Trick or Treat pads found (workspace.Halloween26.Objects.TrickOrTreat). The event may not be running."
            return
        end
        local now = workspace:GetServerTimeNow()
        local view, parts = {}, {}
        for _, pad in ipairs(folder:GetChildren()) do
            local kind = claimPoint(pad)
            local remain = readyAt(pad) - now
            view[#view + 1] = { name = pad.Name, pad = pad, remain = remain, ready = remain <= 0, method = kind }
        end
        table.sort(view, function(a, b) return a.name < b.name end)
        for _, e in ipairs(view) do parts[#parts + 1] = e.name .. ":" .. tostring(e.method) end
        T.view, T.sig = view, table.concat(parts, "|")
    end

    -- a short eased arc to the claim point (never an instant jump)
    local function travel(root, to)
        local from = root.Position
        local dist = (to - from).Magnitude
        if dist < 6 then return true end
        local duration = math.clamp(0.2 + dist / 90, 0.25, 1.2)
        local arc = math.clamp(dist * 0.1, 2, 8)
        local started = os.clock()
        while not destroyed do
            if aliveChar() ~= root then return false end
            local t = math.min(1, (os.clock() - started) / duration)
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.new(from:Lerp(to, t) + Vector3.new(0, math.sin(math.pi * t) * arc, 0))
            if t >= 1 then return true end
            RunService.Heartbeat:Wait()
        end
        return false
    end

    local function claim(entry)
        local pad = entry.pad
        local kind, target = claimPoint(pad)
        if not kind then return false, "no ProximityPrompt or touch part on this pad (it has: " .. describe(pad) .. ")" end
        if kind == "prompt" and target.Enabled == false then return false, "its prompt is disabled" end
        local root = aliveChar()
        if not root then return false, "no character" end
        T.home = T.home or root.CFrame
        if not travel(root, pointPosition(pad, kind, target) + rayless) then return false, "couldn't get there" end

        local before = T.claimedAt[pad.Name]
        local ok, err
        if kind == "prompt" then
            if not fireproximityprompt then return false, "your executor has no fireproximityprompt" end
            local hold = target.HoldDuration
            target.HoldDuration = 0
            ok, err = pcall(fireproximityprompt, target)
            target.HoldDuration = hold
        else
            if not firetouchinterest then return false, "your executor has no firetouchinterest" end
            ok, err = pcall(function()
                firetouchinterest(root, target, 0)
                task.wait()
                firetouchinterest(root, target, 1)
            end)
        end
        if not ok then return false, tostring(err) end

        -- the game confirms with TreatClaimed, or the pad's cooldown starts over
        local deadline = os.clock() + 2
        while os.clock() < deadline and not destroyed do
            if T.claimedAt[pad.Name] ~= before or readyAt(pad) > workspace:GetServerTimeNow() then return true end
            task.wait(0.1)
        end
        return false, "the game didn't confirm it (wrong spot, or the pad needs something else)"
    end

    function T.step()
        T.scan()
        if not (T.auto or T.request) then return end
        if M.own or M.want then
            T.status = "Mining is switched on, so Trick or Treat waits (they'd both move you)."
            return
        end

        local want, now = {}, os.clock()
        local request = T.request
        T.request = nil
        if request == "ALL" then
            for _, e in ipairs(T.view) do if e.ready then want[#want + 1] = e end end
            if #want == 0 then T.status = "Nothing is ready to claim yet." end
        elseif request then
            for _, e in ipairs(T.view) do
                if e.name == request then
                    if e.ready then want[1] = e else T.status = e.name .. " isn't ready yet." end
                end
            end
        else
            for _, e in ipairs(T.view) do
                if e.ready and now - (T.triedAt[e.name] or -1e9) > 5 then want[#want + 1] = e end
            end
        end

        T.moving = #want > 0 -- tells auto-break (which also moves you) to wait while we're away claiming
        for _, e in ipairs(want) do
            if destroyed then return end
            T.triedAt[e.name] = os.clock()
            local ok, why = claim(e)
            T.status = ok and ("Claimed " .. e.name .. ".") or ("Couldn't claim " .. e.name .. ": " .. tostring(why))
        end

        if T.home and #want > 0 then -- put the character back where it was
            local root = aliveChar()
            if root then travel(root, T.home.Position) end
            T.home = nil
        elseif #want == 0 then
            T.home = nil
        end
        T.moving = false
    end

    task.spawn(function()
        while not destroyed do
            if T.auto or T.request or state.page == "Treat" then
                local ok, err = pcall(T.step)
                if not ok then
                    T.auto = false
                    T.home = nil
                    T.moving = false
                    T.status = "Stopped: " .. tostring(err)
                end
            end
            task.wait(T.auto and 0.5 or 1)
        end
    end)
end

----------------------------------------------------------------------
-- Auto-break (Halloween event breakables and boss)
--   Breakables: workspace.Halloween26.Zones.<Zone>.Breakables.<model>, each with an "Id" attribute.
--   Hit one:  ReplicatedStorage.Halloween26.Shared.Remotes.AttackBreakable:FireServer(model:GetAttribute("Id"))
--   Boss:     Remotes.AttackBoss:FireServer()   (only while you stand inside the boss ring)
--   It follows the same client-side rules as the game's ClickController: the zone must not be locked,
--   you must be within Settings.Click.MaxDistance, and hits are spaced by Upgrades.GetCooldown(LocalPlayer).
--   Movement is Humanoid:MoveTo, like the game's own auto; it never teleports.
--   This loop never touches the GUI; the page reads B.on, B.status, B.hits, B.bossHits and B.snap.
----------------------------------------------------------------------
local B = {
    on = false, status = "Switch Auto-break on to start.", hits = 0, bossHits = 0,
    lastAttack = 0, lastMove = 0, lastScan = 0, walking = false, snap = {},
}

do
    local function req(parent, name)
        local module = parent and parent:FindFirstChild(name)
        if not module then return nil end
        local ok, result = pcall(require, module)
        return ok and result or nil
    end

    -- find the event's modules and remotes once; everything optional is checked where it is used
    local function resolve()
        if B.ready then return true end
        local halloween = ReplicatedStorage:FindFirstChild("Halloween26")
        local shared = halloween and halloween:FindFirstChild("Shared")
        if not shared then
            B.problem = "The Halloween event files aren't in this game right now (ReplicatedStorage.Halloween26)."
            return false
        end
        local modules, config, remotes = shared:FindFirstChild("Modules"), shared:FindFirstChild("Config"), shared:FindFirstChild("Remotes")
        B.Upgrades = req(modules, "Upgrades")
        B.BossRing = req(modules, "BossRing")
        B.EventState = req(modules, "EventState")
        B.Settings = req(config, "Settings")
        B.attackBreakable = remotes and remotes:FindFirstChild("AttackBreakable")
        B.attackBoss = remotes and remotes:FindFirstChild("AttackBoss")
        local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local hs = scripts and scripts:FindFirstChild("Halloween26")
        B.Gate = req(hs and hs:FindFirstChild("Controllers"), "GateController")
        if not (B.Upgrades and B.Settings and B.Settings.Click and B.attackBreakable) then
            B.problem = "Couldn't load the event's Upgrades/Settings modules or the AttackBreakable remote."
            return false
        end
        B.ready = true
        return true
    end

    local function alive()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and hum and hum.Health > 0 then return root, hum end
        return nil, nil
    end

    local function zonesFolder()
        local halloween = workspace:FindFirstChild("Halloween26")
        return halloween and halloween:FindFirstChild("Zones")
    end

    -- the zone whose ZonePart you are standing in (the game's own test)
    local function currentZone(pos)
        local zones = zonesFolder()
        if not zones then return nil end
        for _, zone in ipairs(zones:GetChildren()) do
            local part = zone:FindFirstChild("ZonePart")
            if part and part:IsA("BasePart") then
                local rel = part.CFrame:PointToObjectSpace(pos)
                if math.abs(rel.X) <= part.Size.X / 2 and math.abs(rel.Z) <= part.Size.Z / 2 and rel.Y >= -part.Size.Y / 2 then
                    return zone
                end
            end
        end
        return nil
    end

    local function locked(zone)
        return B.Gate ~= nil and try(B.Gate.IsZoneLocked, B.Gate, zone.Name) == true
    end

    -- nearest breakable in your zone (or, outside every zone, in any unlocked zone)
    local function nearest(pos)
        local zones = zonesFolder()
        if not zones then return nil end
        local here = currentZone(pos)
        local best, bestDist = nil, math.huge
        for _, zone in ipairs(here and { here } or zones:GetChildren()) do
            if not locked(zone) then
                local folder = zone:FindFirstChild("Breakables")
                if folder then
                    for _, node in ipairs(folder:GetChildren()) do
                        if node:GetAttribute("Id") then
                            local d = (pos - node:GetPivot().Position).Magnitude
                            if d < bestDist then best, bestDist = node, d end
                        end
                    end
                end
            end
        end
        return best, bestDist
    end

    function B.look()
        if not resolve() then return end
        local root = alive()
        local zone = root and currentZone(root.Position)
        B.snap = {
            eventOn = B.EventState and try(B.EventState.IsEnabled),
            zone = zone and zone.Name or (root and "outside the zones" or nil),
            cooldown = tonumber(try(B.Upgrades.GetCooldown, LocalPlayer)),
            reach = tonumber(B.Settings.Click.MaxDistance),
        }
    end

    function B.step()
        if not resolve() then
            B.status = B.problem
            B.on = false
            return
        end
        if B.EventState and try(B.EventState.IsEnabled) == false then
            B.status = "The event isn't enabled right now."
            return
        end
        if M.own or M.want or T.moving then
            B.status = "Waiting: mining or Trick or Treat is moving you right now."
            return
        end
        local root, hum = alive()
        if not root then
            B.status = "Waiting for your character..."
            return
        end

        local now = os.clock()
        local cooldown = tonumber(try(B.Upgrades.GetCooldown, LocalPlayer)) or 0.5
        local due = now - B.lastAttack >= cooldown * CONFIG.BreakMargin

        -- inside the boss ring: fight the boss (the game's own auto does the same)
        local ring = workspace:FindFirstChild("Halloween26") and workspace.Halloween26:FindFirstChild("BossRing")
        if ring and ring:GetAttribute("Boss") and B.BossRing and B.attackBoss and try(B.BossRing.Contains, root.Position) then
            B.status = "Fighting the boss (" .. tostring(ring:GetAttribute("Boss")) .. ")."
            if due then
                B.lastAttack = now
                if pcall(function() B.attackBoss:FireServer() end) then B.bossHits = B.bossHits + 1 end
            end
            return
        end

        -- The server only needs you within Click.MaxDistance, so hit whatever is already in reach without
        -- moving, and only walk when nothing is. A small margin keeps us safely inside the range.
        local reach = (tonumber(B.Settings.Click.MaxDistance) or 0) - CONFIG.BreakReachMargin

        local target = B.target
        local valid = target ~= nil and target.Parent ~= nil and target:GetAttribute("Id") ~= nil
        local dist = valid and (root.Position - target:GetPivot().Position).Magnitude or nil
        -- re-pick when the target is gone, or (while still out of reach) a few times a second, because a
        -- different breakable may have come into reach on the way
        if not valid or (dist > reach and now - B.lastScan > 0.2) then
            B.lastScan = now
            target, dist = nearest(root.Position)
            B.target = target
        end
        if not target then
            B.status = "No breakables to hit (locked zones, or none have spawned yet)."
            return
        end

        if dist <= reach then
            if B.walking then -- in reach: stop where we are, like the game's own stopWalking
                B.walking = false
                hum:MoveTo(root.Position)
            end
            B.status = "Breaking things in " .. (B.snap.zone or "the event") .. "."
            if due then
                B.lastAttack = now
                if pcall(function() B.attackBreakable:FireServer(target:GetAttribute("Id")) end) then B.hits = B.hits + 1 end
            end
            return
        end

        -- out of reach: walk until it is inside the range (not all the way up to it), a few MoveTo updates a second
        B.walking = true
        B.status = "Walking to a breakable..."
        if now - B.lastMove > 0.2 then
            B.lastMove = now
            local pos = target:GetPivot().Position
            local away = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
            local stopAt = math.max(2, reach - 3) -- horizontal stop; the 3 studs leave room for height differences
            hum:MoveTo(pos + (away.Magnitude > 0 and away.Unit or Vector3.new(0, 0, 0)) * stopAt)
        end
    end

    task.spawn(function()
        local lastLook = 0
        while not destroyed do
            if B.on then
                local ok, err = pcall(B.step)
                if not ok then
                    B.on = false
                    B.status = "Stopped: " .. tostring(err)
                end
                if os.clock() - lastLook > 0.5 then
                    lastLook = os.clock()
                    pcall(B.look)
                end
                RunService.Heartbeat:Wait() -- once per frame, like the game's own render-step loop
            else
                if state.page == "Break" and os.clock() - lastLook > 0.5 then
                    lastLook = os.clock()
                    pcall(B.look)
                end
                task.wait(0.25)
            end
        end
    end)
end

----------------------------------------------------------------------
-- Display helpers
----------------------------------------------------------------------
local DIM = "#8d93aa"

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function dim(s)
    return '<font color="' .. DIM .. '">' .. esc(s) .. "</font>"
end

local function rarityColor(r)
    if not (RarityList and RarityList.Rarities and r) then return nil end
    local ok, color = pcall(function()
        return RarityList.Rarities[r].uiData.gradColor.Keypoints[1].Value
    end)
    return ok and color or nil
end

local function petName(entry)
    local name
    if Collectables and Collectables.ResolvePet then
        local r = try(Collectables.ResolvePet, entry.PetID, entry.PetType, entry.Shiny == true)
        if type(r) == "table" then
            name = r.name or r.Name or r.displayName
        end
    end
    return tostring(name or entry.PetID or "Pet")
end

local function petText(entry, info)
    local plain = (entry.Shiny == true and "Shiny " or "") .. petName(entry)
    local serial = (info and info.serial) or entry.Serial
    if serial then plain = plain .. " #" .. tostring(serial) end
    local rich = esc(plain)
    local power = info and (info.scaledText or info.powerText)
    if power then rich = rich .. dim("  " .. tostring(power)) end
    return rich, plain
end

local function itemText(key, item)
    local plain = tostring((item and (item.name or item.Name or item.displayName)) or key)
    return esc(plain), plain
end

local function auraText(entry)
    local name = Auras and try(Auras.GetDisplayName, entry.Aura) or entry.Aura
    local plain = tostring(name) .. (entry.Serial and (" #" .. tostring(entry.Serial)) or "")
    return esc(plain), plain
end

local function boardText(key, entry)
    local name = Hoverboards and try(Hoverboards.GetDisplayName, key) or key
    local plain = tostring(name) .. ((entry and entry.Serial) and (" #" .. tostring(entry.Serial)) or "")
    return esc(plain), plain
end

----------------------------------------------------------------------
-- Inventory (same rules as the stock panel's buildMine)
----------------------------------------------------------------------
local function getInventory(tab)
    local out = {}
    local data = (StatsMod and try(StatsMod.Get)) or {}

    if tab == "Pets" then
        if not (StatsMod and StatsMod.GetPetInfo) then return out end
        local merged = {}
        for k, v in pairs(data.Pets or {}) do
            merged[k] = { entry = v, amount = v.Amount or 0 }
        end
        for k, v in pairs(data.EquippedPets or {}) do
            local m = merged[k]
            if m then
                m.amount = m.amount + (v.Amount or 0)
            else
                merged[k] = { entry = v, amount = v.Amount or 0 }
            end
        end
        for k, m in pairs(merged) do
            local offered = offers.me.Pets[k] and offers.me.Pets[k].Amount or 0
            local avail = m.amount - offered
            local tradable = true
            if Eggs and Eggs.IsPetTradable then
                tradable = Eggs.IsPetTradable(m.entry.PetID)
            end
            if avail > 0 and not m.entry.Locked and tradable then
                local info = try(StatsMod.GetPetInfo, m.entry)
                if info then
                    local rich, plain = petText(m.entry, info)
                    table.insert(out, {
                        kind = "Pet", key = k, amount = avail, rich = rich, plain = plain,
                        rarity = info.rarity, sort1 = -(tonumber(info.power) or 0), sort2 = -(tonumber(info.rarity) or 0),
                    })
                end
            end
        end

    elseif tab == "Auras" then
        if not Auras then return out end
        for k, v in pairs(data.Auras or {}) do
            local def = type(v) == "table" and Auras.Get(v.Aura)
            if def then
                local avail = (v.Amount or 0) - (offers.me.Auras[k] and offers.me.Auras[k].Amount or 0)
                if avail > 0 then
                    local rich, plain = auraText(v)
                    table.insert(out, {
                        kind = "Aura", key = k, amount = avail, rich = rich, plain = plain,
                        rarity = def.rarity or 1, sort1 = -(def.rarity or 1), sort2 = 0,
                    })
                end
            end
        end

    elseif tab == "Hoverboard" then
        local rs = LocalPlayer:FindFirstChild("ReplicatedStats")
        if not (rs and Hoverboards) then return out end
        for key, def in pairs(Hoverboards.List) do
            local owned = rs:GetAttribute(Hoverboards.GetOwnedAttribute(key)) == true
            if owned and Hoverboards.IsTradable(key) then
                local count = tonumber(rs:GetAttribute(Hoverboards.GetCountAttribute(key))) or 0
                local avail = math.max(count, 1) - (offers.me.Boards[key] and offers.me.Boards[key].Amount or 0)
                if avail > 0 then
                    local serial = tonumber(rs:GetAttribute(Hoverboards.GetSerialAttribute(key)))
                    local rich, plain = boardText(key, { Serial = serial })
                    table.insert(out, {
                        kind = "Board", key = key, amount = avail, rich = rich, plain = plain,
                        rarity = def.rarity or 1, sort1 = -(def.rarity or 1), sort2 = 0,
                    })
                end
            end
        end

    else -- "Items" / "Eggs"
        if not Items then return out end
        local wantEggs = tab == "Eggs"
        for k, v in pairs(data.Items or {}) do
            local item = Items.GetItem(k)
            if item and k ~= "Tokens" and ((Items.IsEgg(item) and true or false) == wantEggs) and Items.IsTradable(k) then
                local count = type(v) == "number" and v or (type(v) == "table" and (v.Amount or 0)) or 0
                local avail = count - (offers.me.Items[k] or 0)
                if avail > 0 then
                    local rich, plain = itemText(k, item)
                    table.insert(out, {
                        kind = "Item", key = k, amount = avail, rich = rich, plain = plain,
                        rarity = item.rarity, sort1 = item.layout or 0, sort2 = 0,
                    })
                end
            end
        end
    end

    table.sort(out, function(a, b)
        if a.sort1 ~= b.sort1 then return a.sort1 < b.sort1 end
        if a.sort2 ~= b.sort2 then return a.sort2 < b.sort2 end
        return tostring(a.key) < tostring(b.key)
    end)
    return out
end

-- Offered items -> records (used for both sides of the trade)
local function offerRecords(o)
    local list = {}
    for k, e in pairs(o.Pets) do
        if (e.Amount or 0) > 0 then
            local info = StatsMod and try(StatsMod.GetPetInfo, e)
            local rich, plain = petText(e, info)
            table.insert(list, { kind = "Pet", key = k, amount = e.Amount, rich = rich, plain = plain, order = 1, rarity = info and info.rarity })
        end
    end
    for k, e in pairs(o.Auras) do
        if (e.Amount or 0) > 0 then
            local rich, plain = auraText(e)
            local def = Auras and try(Auras.Get, e.Aura)
            table.insert(list, { kind = "Aura", key = k, amount = e.Amount, rich = rich, plain = plain, order = 2, rarity = def and def.rarity })
        end
    end
    for k, e in pairs(o.Boards) do
        if (e.Amount or 0) > 0 then
            local rich, plain = boardText(k, e)
            local def = Hoverboards and try(Hoverboards.Get, k)
            table.insert(list, { kind = "Board", key = k, amount = e.Amount, rich = rich, plain = plain, order = 3, rarity = def and def.rarity })
        end
    end
    for k, n in pairs(o.Items) do
        if n > 0 then
            local item = Items and try(Items.GetItem, k)
            local rich, plain = itemText(k, item)
            table.insert(list, { kind = "Item", key = k, amount = n, rich = rich, plain = plain, order = 4, rarity = item and item.rarity })
        end
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.plain ~= b.plain then return a.plain < b.plain end
        return tostring(a.key) < tostring(b.key)
    end)
    return list
end

----------------------------------------------------------------------
-- Server events
----------------------------------------------------------------------
local function applyOfferChange(p)
    local side = (p.Owner == LocalPlayer.Name) and offers.me or offers.them
    local total = tonumber(p.TotalOffered) or 0

    if p.Type == "Pet" and type(p.Key) == "string" then
        if total > 0 then
            local e = side.Pets[p.Key]
            if not e then
                e = {
                    PetID = p.PetID, PetType = p.PetType, Serial = p.Serial, Shiny = p.Shiny == true,
                    SignatureID = p.SignatureID, SignatureText = p.SignatureText,
                }
                side.Pets[p.Key] = e
            end
            e.Amount = total
        else
            side.Pets[p.Key] = nil
        end
    elseif p.Type == "Item" and type(p.ItemID) == "string" then
        side.Items[p.ItemID] = total > 0 and total or nil
    elseif p.Type == "Aura" and type(p.Key) == "string" then
        if total > 0 then
            local e = side.Auras[p.Key]
            if not e then
                e = { Aura = p.Aura, Serial = p.Serial, Enchant = p.Enchant }
                side.Auras[p.Key] = e
            end
            e.Amount = total
        else
            side.Auras[p.Key] = nil
        end
    elseif p.Type == "Board" and type(p.Key) == "string" then
        if total > 0 then
            local e = side.Boards[p.Key]
            if not e then
                e = { Board = p.Key, Serial = p.Serial }
                side.Boards[p.Key] = e
            end
            e.Amount = total
        else
            side.Boards[p.Key] = nil
        end
    elseif p.Type == "Tokens" then
        side.Tokens = total
    else
        return
    end

    -- any offer change clears ready / confirm on the server
    state.ready.me, state.ready.them = false, false
    state.bothReady = false
    state.confirmed.me, state.confirmed.them = false, false
    state.bothConfirmed = false
    state.countdownEnd = nil
end

local function onTradeEvent(action, p)
    if destroyed or type(p) ~= "table" then return end

    -- request phase: these arrive before any trade id exists
    if action == "Request" then
        if p.Role == "Sent" then
            flash("Trade request sent to " .. tostring(p.With))
        elseif p.Role == "Incoming" and p.TradeId ~= nil then
            incoming[p.TradeId] = { from = tostring(p.From), expires = os.clock() + requestTimeout() }
            flash("Trade request from " .. tostring(p.From), 5)
        end
        requestRefresh()
        return
    end
    if action == "Accept" or action == "Cancel" then
        table.clear(incoming)
    elseif action == "Decline" then
        if p.TradeId ~= nil and incoming[p.TradeId] then
            incoming[p.TradeId] = nil
        else
            table.clear(incoming)
        end
        if not state.tradeId or p.TradeId ~= state.tradeId then
            flash(p.Reason == "Timeout" and "Trade request timed out" or "Trade request declined", 4)
        end
    end

    if action == "Accept" then
        resetState()
        state.tradeId = p.TradeId
        state.partner = (p.PlayerA == LocalPlayer.Name) and p.PlayerB or p.PlayerA
        flash("Trade started with " .. tostring(state.partner))
        setPage("Trade")
        return
    end

    if not state.tradeId or p.TradeId ~= state.tradeId then
        requestRefresh() -- request-phase Decline/Cancel may have just cleared `incoming`
        return
    end
    local id = state.tradeId

    if action == "AddItem" or action == "RemoveItem" then
        applyOfferChange(p)

    elseif action == "Ready" then
        local who = (p.Player == LocalPlayer.Name) and "me" or "them"
        state.ready[who] = p.Ready == true
        state.bothReady = p.BothReady == true
        if not state.ready[who] then
            state.confirmed.me, state.confirmed.them = false, false
            state.bothConfirmed = false
        end
        state.countdownEnd = nil

        if who == "them" and state.ready.them and autoReady and not state.ready.me then
            task.delay(CONFIG.AutoDelay, function()
                if state.tradeId == id and state.ready.them and not state.ready.me then
                    send("Ready", { State = true })
                end
            end)
        end
        if state.bothReady and autoConfirm and not state.confirmed.me then
            task.delay(CONFIG.AutoDelay, function()
                if state.tradeId == id and state.bothReady and not state.confirmed.me then
                    send("Confirm")
                end
            end)
        end

    elseif action == "Confirm" then
        local who = (p.Player == LocalPlayer.Name) and "me" or "them"
        state.confirmed[who] = p.Confirmed == true
        state.bothConfirmed = p.BothConfirmed == true
        if state.bothConfirmed and type(p.Seconds) == "number" then
            state.countdownEnd = os.clock() + p.Seconds
        end

    elseif action == "Completed" then
        resetState()
        flash("Trade completed!", 5)

    elseif action == "Cancel" or action == "Decline" then
        resetState()
        flash("Trade cancelled", 4)
    end

    requestRefresh()
end

----------------------------------------------------------------------
-- GUI
--   title bar / sidebar (pages) / content (cards) / status bar
--
-- NOTE: Luau allows at most 200 locals per function. Each page below is built inside its own
-- `do ... end` block, and only the widgets that refresh/updateStatus need are declared up here.
----------------------------------------------------------------------
local WIN_W, WIN_H = 760, 500
local TITLE_H, STATUS_H, SIDEBAR_W, PAD = 36, 28, 150, 12
local PAGE_W = WIN_W - SIDEBAR_W - PAD * 2                 -- 586
local PAGE_H = WIN_H - TITLE_H - STATUS_H - PAD * 2        -- 412

local C = {
    bg = Color3.fromRGB(20, 21, 27),
    chrome = Color3.fromRGB(25, 26, 34),   -- title bar, sidebar, status bar
    card = Color3.fromRGB(31, 33, 43),
    row = Color3.fromRGB(41, 44, 58),
    stroke = Color3.fromRGB(48, 51, 66),
    text = Color3.fromRGB(232, 234, 242),
    muted = Color3.fromRGB(141, 147, 170),
    accent = Color3.fromRGB(88, 101, 242),
    green = Color3.fromRGB(63, 156, 98),
    red = Color3.fromRGB(205, 76, 86),
    amber = Color3.fromRGB(214, 150, 50),
    grey = Color3.fromRGB(68, 72, 92),
}

local conns = {}
local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(conns, c)
    return c
end

local function new(class, props)
    local inst = Instance.new(class)
    local parent = props.Parent
    props.Parent = nil
    for k, v in pairs(props) do inst[k] = v end
    inst.Parent = parent
    return inst
end

local function corner(inst, r)
    new("UICorner", { CornerRadius = UDim.new(0, r or 6), Parent = inst })
end

local function stroke(inst, color)
    new("UIStroke", {
        Parent = inst, Color = color or C.stroke, Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function makeButton(parent, text, size, pos, color, callback)
    local b = new("TextButton", {
        Parent = parent, Text = text, Size = size, Position = pos, BackgroundColor3 = color,
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamMedium, TextSize = 12,
        AutoButtonColor = true, BorderSizePixel = 0,
    })
    corner(b, 6)
    -- not tracked in `conns`: list rows are rebuilt constantly, and destroying the button drops the connection
    b.MouseButton1Click:Connect(callback)
    return b
end

local function makeLabel(parent, text, size, pos, props)
    local l = new("TextLabel", {
        Parent = parent, Text = text, Size = size, Position = pos, BackgroundTransparency = 1,
        TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    })
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

local function makeBox(parent, text, placeholder, size, pos)
    local b = new("TextBox", {
        Parent = parent, Text = text, PlaceholderText = placeholder, Size = size, Position = pos,
        BackgroundColor3 = C.row, TextColor3 = C.text, PlaceholderColor3 = Color3.fromRGB(110, 114, 134),
        Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false, BorderSizePixel = 0,
    })
    corner(b, 6)
    stroke(b)
    new("UIPadding", { Parent = b, PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) })
    return b
end

-- lists sit inside cards, so they are transparent and let the card colour show through
local function makeList(parent, pos, size)
    local sf = new("ScrollingFrame", {
        Parent = parent, Position = pos, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.grey,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    })
    new("UIListLayout", { Parent = sf, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder })
    new("UIPadding", {
        Parent = sf, PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
    })
    return sf
end

-- titled panel; children are positioned from the card's own top-left corner
local function card(parent, pos, size, title)
    local f = new("Frame", { Parent = parent, Position = pos, Size = size, BackgroundColor3 = C.card, BorderSizePixel = 0 })
    corner(f, 8)
    stroke(f)
    if title then
        makeLabel(f, string.upper(title), UDim2.new(1, -24, 0, 16), UDim2.fromOffset(12, 8), {
            Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.muted,
        })
    end
    return f
end

local function clearList(list)
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
end

local function addRow(list, order, rec, actions)
    local row = new("Frame", {
        Parent = list, Size = UDim2.new(1, -6, 0, 30), BackgroundColor3 = C.row,
        BorderSizePixel = 0, LayoutOrder = order,
    })
    corner(row, 6)

    local strip = rarityColor(rec.rarity)
    if strip then
        new("Frame", { Parent = row, Size = UDim2.new(0, 3, 1, -10), Position = UDim2.fromOffset(4, 5), BackgroundColor3 = strip, BorderSizePixel = 0 })
    end

    local reserved = #actions * 44
    local text = rec.rich
    if rec.amount and rec.amount > 1 or rec.showAmount then
        text = text .. dim("  x" .. fmt(rec.amount))
    end
    local label = makeLabel(row, text, UDim2.new(1, -(reserved + 16), 1, 0), UDim2.fromOffset(12, 0), {
        RichText = true, TextTruncate = Enum.TextTruncate.AtEnd,
    })
    for i, a in ipairs(actions) do
        makeButton(row, a.text, UDim2.fromOffset(40, 22), UDim2.new(1, -((#actions - i + 1) * 44), 0.5, -11), a.color, a.fn)
    end
    return row, label
end

local function addInfoRow(list, text)
    makeLabel(list, text, UDim2.new(1, -6, 0, 40), UDim2.new(), { TextColor3 = C.muted, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
end

-- widgets that code outside their own page block needs to reach ----------------
local pages, statusDot, statusLabel, navBadges, paintNav
local tabButtons, searchBox, invList, myList, theirList, getQty, readyBtn, confirmBtn
local playerSearch, playerList, incomingList, unlockLabel
local incomingLabels = {} -- TradeId -> TextLabel, so countdowns update without rebuilding rows
local miscInfo
local hatchSearch, eggList, eggBox, modeBtn, moveBtn, turboBtn, autoBtn, hatchStats

----------------------------------------------------------------------
-- Window chrome: title bar, sidebar navigation, status bar
----------------------------------------------------------------------
do
    local gui = Instance.new("ScreenGui")
    gui.Name = "TradeHelper"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 999
    local parentOk = pcall(function()
        gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
    end)
    if not parentOk or not gui.Parent then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    local main = new("Frame", {
        Parent = gui, Size = UDim2.fromOffset(WIN_W, WIN_H), Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2),
        BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true,
    })
    corner(main, 10)
    stroke(main)

    -- title bar
    local titleBar = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 0, TITLE_H), BackgroundColor3 = C.chrome, BorderSizePixel = 0 })
    makeLabel(titleBar, "Trade Helper", UDim2.fromOffset(200, TITLE_H), UDim2.fromOffset(16, 0), { Font = Enum.Font.GothamBold, TextSize = 14 })
    new("Frame", { Parent = titleBar, Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BackgroundColor3 = C.stroke, BorderSizePixel = 0 })

    -- everything below the title bar (hidden when minimised)
    local body = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 1, -TITLE_H), Position = UDim2.fromOffset(0, TITLE_H), BackgroundTransparency = 1 })
    local sidebar = new("Frame", { Parent = body, Size = UDim2.new(0, SIDEBAR_W, 1, -STATUS_H), BackgroundColor3 = C.chrome, BorderSizePixel = 0 })
    new("Frame", { Parent = sidebar, Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, -1, 0, 0), BackgroundColor3 = C.stroke, BorderSizePixel = 0 })
    local content = new("Frame", { Parent = body, Size = UDim2.new(1, -SIDEBAR_W, 1, -STATUS_H), Position = UDim2.fromOffset(SIDEBAR_W, 0), BackgroundTransparency = 1 })
    local statusBar = new("Frame", { Parent = body, Size = UDim2.new(1, 0, 0, STATUS_H), Position = UDim2.new(0, 0, 1, -STATUS_H), BackgroundColor3 = C.chrome, BorderSizePixel = 0 })

    local function newPage(visible)
        return new("Frame", {
            Parent = content, Position = UDim2.fromOffset(PAD, PAD), Size = UDim2.fromOffset(PAGE_W, PAGE_H),
            BackgroundTransparency = 1, Visible = visible,
        })
    end
    pages = { Trade = newPage(true), Send = newPage(false), Hatch = newPage(false), Quests = newPage(false), Auto = newPage(false), Mine = newPage(false), Treat = newPage(false), Break = newPage(false), Misc = newPage(false) }

    -- status bar
    new("Frame", { Parent = statusBar, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.stroke, BorderSizePixel = 0 })
    statusDot = new("Frame", { Parent = statusBar, Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 14, 0.5, -4), BackgroundColor3 = C.muted, BorderSizePixel = 0 })
    corner(statusDot, 4)
    statusLabel = makeLabel(statusBar, "", UDim2.new(1, -44, 1, 0), UDim2.fromOffset(32, 0), { TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })

    -- unload
    local function destroy()
        if destroyed then return end
        destroyed = true
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        table.clear(conns)
        table.clear(queue)
        H.running = false
        if H.waiting then
            H.waiting = false
            H.bind:Fire(false)
        end
        H.bind:Destroy()
        pcall(restoreHatch)
        gui:Destroy()
        if env.TradeHelper and env.TradeHelper.Destroy == destroy then env.TradeHelper = nil end
    end
    env.TradeHelper = { Destroy = destroy }

    -- window controls (flat until hovered)
    local function ghostButton(text, rightOffset, hoverColor, callback)
        local b = makeButton(titleBar, text, UDim2.fromOffset(28, 24), UDim2.new(1, -rightOffset, 0.5, -12), hoverColor, callback)
        b.AutoButtonColor = false
        b.BackgroundTransparency = 1
        b.TextColor3 = C.muted
        b.TextSize = 14
        b.MouseEnter:Connect(function()
            b.BackgroundTransparency = 0
            b.TextColor3 = Color3.new(1, 1, 1)
        end)
        b.MouseLeave:Connect(function()
            b.BackgroundTransparency = 1
            b.TextColor3 = C.muted
        end)
        return b
    end
    local minimized = false
    ghostButton("-", 68, C.grey, function()
        minimized = not minimized
        body.Visible = not minimized
        main.Size = UDim2.fromOffset(WIN_W, minimized and TITLE_H or WIN_H)
    end)
    ghostButton("X", 36, C.red, destroy)

    -- dragging + hotkey
    local dragging, dragStart, startPos
    connect(titleBar.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
            local c
            c = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    c:Disconnect()
                end
            end)
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    connect(UserInputService.InputBegan, function(input, processed)
        if not processed and input.KeyCode == CONFIG.ToggleKey then
            main.Visible = not main.Visible
        end
    end)

    -- sidebar navigation
    local NAV = { { "Trade", "Trade" }, { "Send", "Send Trade" }, { "Hatch", "Auto Hatch" }, { "Quests", "Pet Quests" }, { "Auto", "Auto Use" }, { "Mine", "Mining" }, { "Treat", "Treats" }, { "Break", "Breakables" }, { "Misc", "Misc" } }
    local navButtons, navLabels, navBars = {}, {}, {}
    navBadges = {}

    paintNav = function()
        for key, btn in pairs(navButtons) do
            local active = key == state.page
            btn.BackgroundTransparency = active and 0 or 1
            navLabels[key].TextColor3 = active and C.text or C.muted
            navBars[key].Visible = active
        end
    end

    for i, item in ipairs(NAV) do
        local key, text = item[1], item[2]
        local btn = new("TextButton", {
            Parent = sidebar, Text = "", Size = UDim2.new(1, -16, 0, 36), Position = UDim2.fromOffset(8, 12 + (i - 1) * 40),
            BackgroundColor3 = C.row, BackgroundTransparency = 1, AutoButtonColor = false, BorderSizePixel = 0,
        })
        corner(btn, 7)
        navBars[key] = new("Frame", {
            Parent = btn, Size = UDim2.new(0, 3, 1, -14), Position = UDim2.fromOffset(0, 7),
            BackgroundColor3 = C.accent, BorderSizePixel = 0, Visible = false,
        })
        corner(navBars[key], 2)
        navLabels[key] = makeLabel(btn, text, UDim2.new(1, -50, 1, 0), UDim2.fromOffset(16, 0), { Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.muted })
        local badge = makeLabel(btn, "", UDim2.fromOffset(22, 18), UDim2.new(1, -30, 0.5, -9), {
            BackgroundTransparency = 0, BackgroundColor3 = C.accent, TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, Visible = false,
        })
        corner(badge, 9)
        navBadges[key] = badge

        navButtons[key] = btn
        btn.MouseButton1Click:Connect(function() setPage(key) end)
        btn.MouseEnter:Connect(function()
            if state.page ~= key then btn.BackgroundTransparency = 0.6 end
        end)
        btn.MouseLeave:Connect(function() paintNav() end)
    end
    makeLabel(sidebar, CONFIG.ToggleKey.Name .. " hides the window", UDim2.new(1, -24, 0, 16), UDim2.new(0, 14, 1, -26), { TextSize = 10, TextColor3 = C.muted })
end

----------------------------------------------------------------------
-- Trade page
----------------------------------------------------------------------
do
    local page = pages.Trade
    local invCard = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(290, 348), "Inventory")

    local TABS = { { "Pets", "Pets" }, { "Items", "Items" }, { "Eggs", "Eggs" }, { "Auras", "Auras" }, { "Hoverboard", "Boards" } }
    tabButtons = {}
    for i, t in ipairs(TABS) do
        tabButtons[t[1]] = makeButton(invCard, t[2], UDim2.fromOffset(51, 24), UDim2.fromOffset(8 + (i - 1) * 55, 28), C.grey, function()
            state.tab = t[1]
            requestRefresh()
        end)
    end

    searchBox = makeBox(invCard, "", "Search...", UDim2.fromOffset(170, 26), UDim2.fromOffset(8, 58))
    makeButton(invCard, "Add all shown", UDim2.fromOffset(96, 26), UDim2.fromOffset(186, 58), C.accent, function()
        for _, rec in ipairs(state.shown) do
            addOffer(rec, rec.amount)
        end
    end)
    invList = makeList(invCard, UDim2.fromOffset(4, 92), UDim2.fromOffset(282, 250))

    local myCard = card(page, UDim2.fromOffset(298, 0), UDim2.fromOffset(288, 120), "Your offer")
    myList = makeList(myCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(280, 90))
    local theirCard = card(page, UDim2.fromOffset(298, 128), UDim2.fromOffset(288, 120), "Their offer")
    theirList = makeList(theirCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(280, 90))

    local ctlCard = card(page, UDim2.fromOffset(298, 256), UDim2.fromOffset(288, 92), "Tokens & quantity")
    makeLabel(ctlCard, "Tokens", UDim2.fromOffset(54, 26), UDim2.fromOffset(10, 28))
    local tokenBox = makeBox(ctlCard, "", "amount", UDim2.fromOffset(90, 26), UDim2.fromOffset(66, 28))
    local function readTokenBox()
        return tonumber((tokenBox.Text:gsub("[^%d]", ""))) or 0
    end
    makeButton(ctlCard, "Set", UDim2.fromOffset(58, 26), UDim2.fromOffset(162, 28), C.green, function() setTokens(readTokenBox()) end)
    makeButton(ctlCard, "Max", UDim2.fromOffset(52, 26), UDim2.fromOffset(226, 28), C.accent, function()
        tokenBox.Text = tostring(getTokens())
        setTokens(getTokens())
    end)

    makeLabel(ctlCard, "Quantity", UDim2.fromOffset(54, 26), UDim2.fromOffset(10, 60))
    local qtyBox = makeBox(ctlCard, "1", "1", UDim2.fromOffset(90, 26), UDim2.fromOffset(66, 60))
    getQty = function()
        return math.max(1, math.floor(tonumber(qtyBox.Text) or 1))
    end
    makeButton(ctlCard, "Clear my offer", UDim2.fromOffset(116, 26), UDim2.fromOffset(162, 60), C.red, function()
        if not state.tradeId then return flash("No active trade") end
        if isLocked() then return flash("Offer is locked") end
        for _, rec in ipairs(offerRecords(offers.me)) do
            removeOffer(rec, rec.amount)
        end
        if offers.me.Tokens > 0 then
            enqueue("RemoveItem", { Type = "Tokens", Amount = offers.me.Tokens })
        end
    end)

    -- action bar
    local actionBar = card(page, UDim2.fromOffset(0, 356), UDim2.fromOffset(PAGE_W, 56))
    readyBtn = makeButton(actionBar, "Ready", UDim2.fromOffset(92, 36), UDim2.fromOffset(12, 10), C.green, function()
        if not state.tradeId then return flash("No active trade") end
        if state.confirmed.me then return flash("Already locked in") end
        send("Ready", { State = not state.ready.me })
    end)
    confirmBtn = makeButton(actionBar, "Confirm", UDim2.fromOffset(92, 36), UDim2.fromOffset(112, 10), C.amber, function()
        if not state.tradeId then return flash("No active trade") end
        if not state.bothReady then return flash("Both players must be Ready first") end
        if state.confirmed.me then return flash("Already confirmed") end
        send("Confirm")
    end)
    makeButton(actionBar, "Cancel", UDim2.fromOffset(92, 36), UDim2.fromOffset(212, 10), C.red, function()
        send("Cancel")
    end)

    local autoReadyBtn, autoConfirmBtn
    local function paintToggles()
        autoReadyBtn.Text = "Auto-Ready: " .. (autoReady and "ON" or "OFF")
        autoReadyBtn.BackgroundColor3 = autoReady and C.accent or C.grey
        autoConfirmBtn.Text = "Auto-Confirm: " .. (autoConfirm and "ON" or "OFF")
        autoConfirmBtn.BackgroundColor3 = autoConfirm and C.accent or C.grey
    end
    autoReadyBtn = makeButton(actionBar, "", UDim2.fromOffset(124, 36), UDim2.fromOffset(318, 10), C.grey, function()
        autoReady = not autoReady
        paintToggles()
    end)
    autoConfirmBtn = makeButton(actionBar, "", UDim2.fromOffset(124, 36), UDim2.fromOffset(450, 10), C.grey, function()
        autoConfirm = not autoConfirm
        paintToggles()
    end)
    paintToggles()
end

----------------------------------------------------------------------
-- Send Trade page
----------------------------------------------------------------------
do
    local page = pages.Send
    local playersCard = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(372, PAGE_H), "Players")
    playerSearch = makeBox(playersCard, "", "Search players...", UDim2.fromOffset(356, 26), UDim2.fromOffset(8, 28))
    playerList = makeList(playersCard, UDim2.fromOffset(4, 62), UDim2.fromOffset(364, 342))

    local incomingCard = card(page, UDim2.fromOffset(380, 0), UDim2.fromOffset(206, 250), "Incoming requests")
    incomingList = makeList(incomingCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(198, 218))

    local tradingCard = card(page, UDim2.fromOffset(380, 258), UDim2.fromOffset(206, 154), "Trading")
    unlockLabel = makeLabel(tradingCard, "", UDim2.fromOffset(182, 118), UDim2.fromOffset(12, 28), {
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.muted,
    })
end

----------------------------------------------------------------------
-- Misc page
----------------------------------------------------------------------
do
    local page = pages.Misc
    local serverCard = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(PAGE_W, 236), "Server")
    local toolsCard = card(page, UDim2.fromOffset(0, 244), UDim2.fromOffset(PAGE_W, 124), "Tools")

    miscInfo = makeLabel(serverCard, "", UDim2.fromOffset(PAGE_W - 24, 16), UDim2.fromOffset(12, 26), {
        TextSize = 11, TextColor3 = C.muted, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    local function miscRow(parent, y, title, desc, btnText, color, fn)
        local row = new("Frame", {
            Parent = parent, Size = UDim2.fromOffset(PAGE_W - 16, 40), Position = UDim2.fromOffset(8, y),
            BackgroundColor3 = C.row, BorderSizePixel = 0,
        })
        corner(row, 7)
        makeLabel(row, title, UDim2.fromOffset(380, 18), UDim2.fromOffset(12, 3), { Font = Enum.Font.GothamMedium, TextSize = 13 })
        makeLabel(row, desc, UDim2.fromOffset(430, 16), UDim2.fromOffset(12, 21), { TextSize = 11, TextColor3 = C.muted })
        return makeButton(row, btnText, UDim2.fromOffset(104, 26), UDim2.new(1, -112, 0.5, -13), color, fn)
    end

    -- leaving the server cancels any open trade, so ask for a second click while one is active
    local armed = {}
    local function guarded(key, fn)
        return function()
            if state.tradeId and not (armed[key] and os.clock() < armed[key]) then
                armed[key] = os.clock() + 4
                flash("You're in a trade - press again within 4s to leave anyway", 4)
                return
            end
            armed[key] = nil
            fn()
        end
    end

    local function teleport(fn, message)
        flash(message, 15)
        local ok, err = pcall(fn)
        if not ok then flash("Teleport failed: " .. tostring(err), 5) end
    end

    local function httpGet(url)
        local req = request or http_request or (syn and syn.request)
        if req then
            local ok, res = pcall(req, { Url = url, Method = "GET" })
            if ok and type(res) == "table" and res.Body and (res.StatusCode == nil or res.StatusCode == 200) then
                return res.Body
            end
        end
        local ok, body = pcall(function() return game:HttpGet(url) end)
        return ok and body or nil
    end

    -- Roblox refuses client-side teleports into a sub-place of a multi-place experience
    -- ("restricted place", error 773); only the experience's root place can be joined directly.
    local rootPlaceId
    local function resolveRootPlace()
        if rootPlaceId then return rootPlaceId end
        local body = httpGet("https://games.roblox.com/v1/games?universeIds=" .. tostring(game.GameId))
        local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
        local entry = ok and type(data) == "table" and type(data.data) == "table" and data.data[1]
        local id = entry and tonumber(entry.rootPlaceId)
        if id then rootPlaceId = id end
        return id or game.PlaceId
    end

    local function rejoin()
        flash("Checking place...", 10)
        task.spawn(function()
            local root = resolveRootPlace()
            if destroyed then return end
            if root ~= game.PlaceId then
                teleport(function()
                    TeleportService:Teleport(root, LocalPlayer)
                end, "Sub-place can't be rejoined - going to the main place...")
            elseif #Players:GetPlayers() <= 1 then
                -- alone in the server: it would shut down, so this lands you in a fresh one
                teleport(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end, "Rejoining...")
            else
                teleport(function()
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
                end, "Rejoining...")
            end
        end)
    end

    local function newServer()
        flash("Checking place...", 10)
        task.spawn(function()
            local root = resolveRootPlace()
            if destroyed then return end
            teleport(function() TeleportService:Teleport(root, LocalPlayer) end, "Joining a new server...")
        end)
    end

    local function serverHop()
        flash("Searching for a server...", 20)
        task.spawn(function()
            local place = resolveRootPlace()
            local candidates, cursor = {}, nil
            for _ = 1, 3 do
                local url = "https://games.roblox.com/v1/games/" .. tostring(place) .. "/servers/Public?sortOrder=Asc&limit=100"
                if cursor then url = url .. "&cursor=" .. cursor end
                local body = httpGet(url)
                local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
                if not (body and ok and type(data) == "table" and type(data.data) == "table") then break end
                for _, s in ipairs(data.data) do
                    if s.id ~= game.JobId and (s.playing or 0) < (s.maxPlayers or 0) - 1 then
                        table.insert(candidates, s.id)
                    end
                end
                cursor = data.nextPageCursor
                if not cursor or #candidates >= 20 then break end
            end
            if destroyed then return end
            if #candidates == 0 then
                return flash("No other server found", 4)
            end
            teleport(function()
                TeleportService:TeleportToPlaceInstance(place, candidates[math.random(#candidates)], LocalPlayer)
            end, "Joining another server...")
        end)
    end

    -- surface Roblox's own failure reason in the status bar
    connect(TeleportService.TeleportInitFailed, function(player, result, message)
        if player ~= LocalPlayer then return end
        flash("Teleport failed (" .. tostring(result) .. "): " .. tostring(message), 8)
    end)

    miscRow(serverCard, 48, "Rejoin server", "Reconnect to this server (sub-places go to the main place instead)", "Rejoin", C.amber, guarded("rejoin", rejoin))
    miscRow(serverCard, 94, "New server", "Teleport to a fresh server of this game (via its main place)", "New server", C.accent, guarded("new", newServer))
    miscRow(serverCard, 140, "Server hop", "Join a different public server that still has room", "Hop", C.accent, guarded("hop", serverHop))
    miscRow(serverCard, 186, "Copy join info", "Copies a script line that teleports into this exact server", "Copy", C.grey, function()
        local clip = setclipboard or toclipboard
        if not clip then return flash("Your executor has no clipboard function") end
        clip(('game:GetService("TeleportService"):TeleportToPlaceInstance(%s, "%s", game:GetService("Players").LocalPlayer)'):format(
            tostring(game.PlaceId), tostring(game.JobId)))
        flash("Copied", 2)
    end)

    local antiAfkConn
    local antiAfkBtn
    antiAfkBtn = miscRow(toolsCard, 28, "Anti-AFK", "Stops the 20-minute idle kick while the window is unfocused", "OFF", C.grey, function()
        if antiAfkConn then
            antiAfkConn:Disconnect()
            antiAfkConn = nil
        else
            antiAfkConn = LocalPlayer.Idled:Connect(function()
                pcall(function()
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new())
                end)
            end)
            table.insert(conns, antiAfkConn)
        end
        antiAfkBtn.Text = antiAfkConn and "ON" or "OFF"
        antiAfkBtn.BackgroundColor3 = antiAfkConn and C.green or C.grey
    end)

    local hatchBtn
    local hatchAttempt = "Normal" -- the mode the button last tried, so a failed patch doesn't block the cycle
    hatchBtn = miscRow(toolsCard, 74, "Hatch animation", "Normal / Hide (the game's own setting, short version) / Skip (nothing plays)", "Normal", C.grey, function()
        hatchAttempt = ({ Normal = "Hide", Hide = "Skip", Skip = "Normal" })[hatchAttempt]
        local installed = setHatchMode(hatchAttempt)
        hatchBtn.Text = hatchMode
        hatchBtn.BackgroundColor3 = hatchMode == "Normal" and C.grey or (hatchMode == "Hide" and C.accent or C.green)
        if hatchAttempt ~= "Normal" and installed == 0 then
            flash("Couldn't patch '" .. hatchAttempt .. "' (module missing or locked)", 5)
        else
            flash("Hatch animation: " .. hatchMode, 2)
        end
    end)
end

----------------------------------------------------------------------
-- Auto Hatch page
----------------------------------------------------------------------
do
    local page = pages.Hatch
    local eggsCard = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(290, PAGE_H), "Eggs")
    hatchSearch = makeBox(eggsCard, "", "Search eggs...", UDim2.fromOffset(274, 26), UDim2.fromOffset(8, 28))
    eggList = makeList(eggsCard, UDim2.fromOffset(4, 62), UDim2.fromOffset(282, 342))

    local setCard = card(page, UDim2.fromOffset(298, 0), UDim2.fromOffset(288, 196), "Settings")
    makeLabel(setCard, "Egg", UDim2.fromOffset(54, 26), UDim2.fromOffset(10, 28))
    eggBox = makeBox(setCard, "", "pick from the list or type the exact name", UDim2.fromOffset(212, 26), UDim2.fromOffset(66, 28))

    makeLabel(setCard, "Mode", UDim2.fromOffset(54, 26), UDim2.fromOffset(10, 60))
    modeBtn = makeButton(setCard, HATCH_MODES[1], UDim2.fromOffset(84, 26), UDim2.fromOffset(66, 60), C.accent, guard("mode", function()
        H.mode = H.mode % #HATCH_MODES + 1
        modeBtn.Text = HATCH_MODES[H.mode] -- repaint now instead of waiting for the next update tick
    end))
    makeLabel(setCard, "Delay (s)", UDim2.fromOffset(52, 26), UDim2.fromOffset(158, 60))
    local delayBox = makeBox(setCard, tostring(CONFIG.HatchDelay), tostring(CONFIG.HatchDelay), UDim2.fromOffset(66, 26), UDim2.fromOffset(212, 60))

    moveBtn = makeButton(setCard, "", UDim2.fromOffset(268, 26), UDim2.fromOffset(10, 92), C.grey, guard("go-to-egg toggle", function()
        H.goToEgg = not H.goToEgg
        requestRefresh()
    end))
    turboBtn = makeButton(setCard, "", UDim2.fromOffset(268, 26), UDim2.fromOffset(10, 124), C.grey, guard("turbo toggle", function()
        H.turbo = not H.turbo
        requestRefresh()
    end))

    local function readHatchSettings()
        local delay = math.max(0, tonumber(delayBox.Text) or CONFIG.HatchDelay)
        return eggBox.Text:match("^%s*(.-)%s*$"), HATCH_MODES[H.mode], H.goToEgg, delay, H.turbo
    end

    makeButton(setCard, "Hatch once", UDim2.fromOffset(96, 30), UDim2.fromOffset(10, 158), C.accent, guard("hatch once", function()
        local egg, mode, allowMove, delay = readHatchSettings()
        startAuto(egg, mode, allowMove, true, delay, false)
        requestRefresh()
    end))
    autoBtn = makeButton(setCard, "Start auto-hatch", UDim2.fromOffset(164, 30), UDim2.fromOffset(114, 158), C.green, guard("auto-hatch", function()
        if H.running then
            stopAuto()
        else
            local egg, mode, allowMove, delay, turbo = readHatchSettings()
            startAuto(egg, mode, allowMove, false, delay, turbo)
        end
        requestRefresh()
    end))

    local resultsCard = card(page, UDim2.fromOffset(298, 204), UDim2.fromOffset(288, 146), "Results")
    hatchStats = makeLabel(resultsCard, "", UDim2.fromOffset(264, 110), UDim2.fromOffset(12, 28), {
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })

    local tipCard = card(page, UDim2.fromOffset(298, 358), UDim2.fromOffset(288, 54))
    makeLabel(tipCard, "Tip: set Hatch animation to Hide or Skip on the Misc page, or the server can sit waiting for the animation and drop your next hatch.",
        UDim2.fromOffset(264, 42), UDim2.fromOffset(12, 6), {
            TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11, TextColor3 = C.muted,
        })
end

----------------------------------------------------------------------
-- Pet Quests page
----------------------------------------------------------------------
do
    local page = pages.Quests
    local ctl = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(PAGE_W, 100), "Pet quests")
    makeLabel(ctl, "Check every", UDim2.fromOffset(74, 26), UDim2.fromOffset(10, 28))
    local intervalBox = makeBox(ctl, "5", "5", UDim2.fromOffset(46, 26), UDim2.fromOffset(86, 28))
    makeLabel(ctl, "s", UDim2.fromOffset(12, 26), UDim2.fromOffset(136, 28))
    connect(intervalBox:GetPropertyChangedSignal("Text"), function()
        Q.interval = math.max(2, tonumber(intervalBox.Text) or 5) -- the game's own panel polls every 2s
    end)

    makeButton(ctl, "Claim ready", UDim2.fromOffset(110, 26), UDim2.fromOffset(160, 28), C.green, guard("claim quests", function()
        Q.status = "Checking..."
        Q.refresh(true)
    end))
    local qAutoBtn = makeButton(ctl, "", UDim2.fromOffset(150, 26), UDim2.fromOffset(278, 28), C.grey, guard("auto-claim", function()
        Q.auto = not Q.auto
        Q.lastPoll = 0 -- check right away
    end))
    makeButton(ctl, "Refresh", UDim2.fromOffset(100, 26), UDim2.fromOffset(436, 28), C.accent, guard("refresh quests", function()
        Q.refresh(false)
    end))
    local summary = makeLabel(ctl, "", UDim2.fromOffset(PAGE_W - 24, 34), UDim2.fromOffset(12, 60), {
        RichText = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })

    local listCard = card(page, UDim2.fromOffset(0, 108), UDim2.fromOffset(PAGE_W, 304), "Quests in your current tier")
    local list = makeList(listCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(PAGE_W - 8, 272))

    local drawn = -1
    Q.draw = function()
        qAutoBtn.Text = "Auto-claim: " .. (Q.auto and "ON" or "OFF")
        qAutoBtn.BackgroundColor3 = Q.auto and C.accent or C.grey

        local qs = Q.state
        local line = "No quest data yet."
        if type(qs) == "table" and PetQuest then
            local tier = tonumber(qs.Tier) or 1
            local info = PetQuest.TIERS[tier]
            local _, ready = Q.classify(qs)
            line = ("<b>Tier %d/%d%s</b>   |   %s: +%d%% of %d%%   |   ready: %d"):format(
                tier, #PetQuest.TIERS, info and (" - " .. info.name) or " - all done",
                PetQuest.PET_NAME, tonumber(qs.Percent) or 0, PetQuest.MAX_PERCENT, ready)
        end
        local note = (PetQuest and PetQuest.ENABLED == false)
            and ("\n" .. dim("The game's own panel is switched off in this build; the server may not answer.")) or ""
        summary.Text = line .. "   " .. dim(Q.status) .. note

        if drawn == Q.version then return end -- rows only change when new data arrives
        drawn = Q.version
        clearList(list)
        local items = Q.classify(qs)
        if #items == 0 then
            addInfoRow(list, type(qs) == "table" and "Every tier is complete." or "Waiting for the server's answer...")
            return
        end
        local TAGS = {
            ready = '<font color="#59c37a">READY</font>',
            active = dim("in progress"),
            claimed = dim("claimed"),
        }
        for i, item in ipairs(items) do
            local shown = item.status == "active" and item.value or item.quest.amount
            local text = PetQuest.GetQuestText(item.quest, shown)
            addRow(list, i, {
                rich = esc(text) .. "   " .. TAGS[item.status] .. dim("   +" .. item.quest.reward .. "%"),
                plain = text,
            }, {})
        end
    end
end

----------------------------------------------------------------------
-- Auto Use page
----------------------------------------------------------------------
do
    local page = pages.Auto
    local ctl = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(PAGE_W, 64), "Auto use")
    local onBtn = makeButton(ctl, "", UDim2.fromOffset(140, 26), UDim2.fromOffset(10, 28), C.grey, guard("auto-use", function()
        A.on = not A.on
    end))
    makeLabel(ctl, "Amount", UDim2.fromOffset(50, 26), UDim2.fromOffset(160, 28))
    local amountBtn = makeButton(ctl, "1", UDim2.fromOffset(64, 26), UDim2.fromOffset(212, 28), C.accent, guard("amount", function()
        A.amountIndex = A.amountIndex % #USE_AMOUNTS + 1
    end))
    makeLabel(ctl, "Re-use (s)", UDim2.fromOffset(62, 26), UDim2.fromOffset(286, 28))
    local reuseBox = makeBox(ctl, "", "duration", UDim2.fromOffset(56, 26), UDim2.fromOffset(350, 28))
    connect(reuseBox:GetPropertyChangedSignal("Text"), function()
        local n = tonumber(reuseBox.Text)
        A.reuse = n and math.max(1, n) or nil -- blank = use each item's own duration
    end)
    local cfmBtn = makeButton(ctl, "", UDim2.fromOffset(160, 26), UDim2.fromOffset(416, 28), C.grey, guard("confirm crates", function()
        A.confirmCrates = not A.confirmCrates
    end))

    local potCard = card(page, UDim2.fromOffset(0, 72), UDim2.fromOffset(286, 340), "Potions & fruits")
    local potList = makeList(potCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(278, 308))
    local crateCard = card(page, UDim2.fromOffset(294, 72), UDim2.fromOffset(292, 196), "Crates")
    local crateList = makeList(crateCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(284, 164))
    local logCard = card(page, UDim2.fromOffset(294, 276), UDim2.fromOffset(292, 136), "Activity")
    local logLabel = makeLabel(logCard, "", UDim2.fromOffset(268, 102), UDim2.fromOffset(12, 28), {
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextSize = 11,
    })

    local function fill(list, entries, enabledTable, emptyText)
        clearList(list)
        if #entries == 0 then
            addInfoRow(list, emptyText)
            return
        end
        for i, e in ipairs(entries) do
            local extra = e.confirm and dim("  asks to confirm") or ""
            addRow(list, i, { rich = esc(e.display) .. dim("  x" .. fmt(e.count)) .. extra, plain = e.display }, {
                {
                    text = e.enabled and "ON" or "OFF", color = e.enabled and C.green or C.grey,
                    fn = function()
                        e.enabled = not e.enabled
                        enabledTable[e.name] = e.enabled or nil
                        A.force = true -- redraw right away instead of waiting for the next inventory scan
                    end,
                },
            })
        end
    end

    local drawnSig, drawnAt = nil, 0
    A.draw = function()
        onBtn.Text = "Auto-use: " .. (A.on and "ON" or "OFF")
        onBtn.BackgroundColor3 = A.on and C.green or C.grey
        amountBtn.Text = string.upper(tostring(USE_AMOUNTS[A.amountIndex]))
        cfmBtn.Text = "Confirm crates: " .. (A.confirmCrates and "INCLUDED" or "SKIPPED")
        cfmBtn.BackgroundColor3 = A.confirmCrates and C.amber or C.grey
        local lines = {}
        for i, entry in ipairs(A.log) do lines[i] = entry.text end
        logLabel.Text = #lines > 0 and table.concat(lines, "\n") or "Nothing yet. Turn on Auto-use, then switch ON the items you want."

        -- rows rebuild when the inventory changes, but at most twice a second, so fast opening
        -- doesn't make them flicker or swallow clicks (a toggle forces an immediate redraw)
        local now = os.clock()
        if not A.force and (drawnSig == A.sig or now - drawnAt < 0.5) then return end
        A.force = false
        drawnSig = A.sig
        drawnAt = now
        fill(potList, A.view.potions, A.potions, "No potions or fruits in your inventory.")
        fill(crateList, A.view.crates, A.crates, "No crates in your inventory.")
    end
end

----------------------------------------------------------------------
-- Mining page
----------------------------------------------------------------------
do
    local page = pages.Mine
    local ctl = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(PAGE_W, 112), "Auto Mine")
    local mineBtn = makeButton(ctl, "", UDim2.fromOffset(200, 34), UDim2.fromOffset(10, 28), C.grey, guard("auto mine", function()
        M.want = not M.want
        if M.want then M.own = false end -- the two modes would double-hit
    end))
    local ownBtn = makeButton(ctl, "", UDim2.fromOffset(220, 34), UDim2.fromOffset(218, 28), C.grey, guard("own auto mine", function()
        M.own = not M.own
        if M.own then
            M.want = false
            M.hits, M.oreStart, M.oreNow, M.target, M.nextSwing = 0, nil, nil, nil, 0
            M.startedAt = os.clock()
            M.ownStatus = "Starting..."
        end
    end))
    local statusLbl = makeLabel(ctl, "", UDim2.fromOffset(PAGE_W - 24, 36), UDim2.fromOffset(12, 70), {
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.muted,
    })

    local infoCard = card(page, UDim2.fromOffset(0, 120), UDim2.fromOffset(PAGE_W, 150), "Mine status")
    local infoLbl = makeLabel(infoCard, "", UDim2.fromOffset(PAGE_W - 24, 114), UDim2.fromOffset(12, 28), {
        RichText = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })

    local noteCard = card(page, UDim2.fromOffset(0, 278), UDim2.fromOffset(PAGE_W, 76))
    makeLabel(noteCard, "Game's Auto Mine presses the game's own button, so it must be unlocked in Mining Upgrades. "
        .. "Own Auto Mine needs no unlock: it walks to ore and swings at the manual speed, which is faster than "
        .. "the game's Auto Mine at low levels. Both only run while you're in the mine, and only one runs at a time.",
        UDim2.fromOffset(PAGE_W - 24, 64), UDim2.fromOffset(12, 6), {
            TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11, TextColor3 = C.muted,
        })

    local function row(key, value)
        return dim(key .. ": ") .. esc(value == nil and "-" or tostring(value))
    end

    M.draw = function()
        mineBtn.Text = "Game's Auto Mine: " .. (M.want and "ON" or "OFF")
        mineBtn.BackgroundColor3 = M.want and C.green or C.grey
        ownBtn.Text = "Own Auto Mine: " .. (M.own and "ON" or "OFF")
        ownBtn.BackgroundColor3 = M.own and C.green or C.grey
        statusLbl.Text = M.own and M.ownStatus or M.status

        local s = M.snap
        local lines = {
            row("Ore", s.ore and fmt(s.ore) or nil),
            row("Pickaxe", (s.pickaxe and s.pickaxe ~= "" and s.pickaxe or "?") .. (s.power and ("  (power " .. fmt(s.power) .. ")") or "")),
            row("Zone", s.zone),
            row("In the mine", s.inMine == nil and nil or (s.inMine and "yes" or "no")),
            row("Game's Auto Mine", s.auto),
        }
        if M.own and M.oreStart and M.oreNow then
            local gained = M.oreNow - M.oreStart
            local minutes = math.max((os.clock() - (M.startedAt or os.clock())) / 60, 1e-6)
            lines[#lines + 1] = row("Own mining", ("%d swings, +%s ore (%s per hour)"):format(M.hits, fmt(gained), fmt(gained / minutes * 60)))
        end
        infoLbl.Text = table.concat(lines, "\n")
    end
end

----------------------------------------------------------------------
-- Trick or Treat page
----------------------------------------------------------------------
do
    local page = pages.Treat
    local ctl = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(PAGE_W, 116), "Trick or Treat")
    local autoSwitch = makeButton(ctl, "", UDim2.fromOffset(190, 34), UDim2.fromOffset(10, 28), C.grey, guard("auto treat", function()
        T.auto = not T.auto
    end))
    makeButton(ctl, "Claim all ready", UDim2.fromOffset(150, 34), UDim2.fromOffset(208, 28), C.accent, guard("claim treats", function()
        T.request = "ALL"
    end))
    local summary = makeLabel(ctl, "", UDim2.fromOffset(PAGE_W - 24, 44), UDim2.fromOffset(12, 68), {
        RichText = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })

    local listCard = card(page, UDim2.fromOffset(0, 124), UDim2.fromOffset(PAGE_W, 288), "Pads")
    local list = makeList(listCard, UDim2.fromOffset(4, 26), UDim2.fromOffset(PAGE_W - 8, 256))

    local function clockText(seconds)
        seconds = math.max(0, math.floor(seconds + 0.5))
        local h, m, s = seconds // 3600, seconds % 3600 // 60, seconds % 60
        return h > 0 and ("%d:%02d:%02d"):format(h, m, s) or ("%d:%02d"):format(m, s)
    end

    local labels, drawnSig = {}, nil -- pad name -> its row label, so timers update without rebuilding rows
    T.draw = function()
        autoSwitch.Text = "Auto-claim: " .. (T.auto and "ON" or "OFF")
        autoSwitch.BackgroundColor3 = T.auto and C.green or C.grey

        local ready = 0
        for _, e in ipairs(T.view) do if e.ready then ready = ready + 1 end end
        summary.Text = ("<b>%d pad%s</b>, %d ready   |   claimed this session: %d\n"):format(
            #T.view, #T.view == 1 and "" or "s", ready, T.claims) .. dim(T.status)

        if drawnSig ~= T.sig then -- only rebuild rows when the set of pads (or how they claim) changes
            drawnSig = T.sig
            clearList(list)
            table.clear(labels)
            if #T.view == 0 then
                addInfoRow(list, "No pads found. The event may not be running right now.")
                return
            end
            for i, e in ipairs(T.view) do
                local _, label = addRow(list, i, { rich = esc(e.name), plain = e.name }, {
                    { text = "Go", color = C.green, fn = function() T.request = e.name end },
                })
                labels[e.name] = label
            end
        end
        for _, e in ipairs(T.view) do
            local label = labels[e.name]
            if label then
                label.Text = esc(e.name) .. "   "
                    .. (e.ready and '<font color="#59c37a">Ready!</font>' or dim(clockText(e.remain)))
                    .. dim("   [" .. (e.method or "no claim point found") .. "]")
            end
        end
    end
end

----------------------------------------------------------------------
-- Breakables page
----------------------------------------------------------------------
do
    local page = pages.Break
    local ctl = card(page, UDim2.fromOffset(0, 0), UDim2.fromOffset(PAGE_W, 112), "Auto-break")
    local breakSwitch = makeButton(ctl, "", UDim2.fromOffset(200, 34), UDim2.fromOffset(10, 28), C.grey, guard("auto break", function()
        B.on = not B.on
        if B.on then
            B.hits, B.bossHits, B.target, B.lastAttack = 0, 0, nil, 0
            B.startedAt = os.clock()
            B.status = "Starting..."
        end
    end))
    local statusLbl = makeLabel(ctl, "", UDim2.fromOffset(PAGE_W - 24, 36), UDim2.fromOffset(12, 70), {
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.muted,
    })

    local infoCard = card(page, UDim2.fromOffset(0, 120), UDim2.fromOffset(PAGE_W, 150), "Event status")
    local infoLbl = makeLabel(infoCard, "", UDim2.fromOffset(PAGE_W - 24, 114), UDim2.fromOffset(12, 28), {
        RichText = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })

    local noteCard = card(page, UDim2.fromOffset(0, 278), UDim2.fromOffset(PAGE_W, 76))
    makeLabel(noteCard, "It hits the nearest breakable in your zone and walks to the next one, using the same rules as the game's "
        .. "own click: unlocked zones only, within hit range, one hit per cooldown. Stand inside the boss ring and it fights the boss "
        .. "instead. It pauses while mining or Trick or Treat is moving you.",
        UDim2.fromOffset(PAGE_W - 24, 64), UDim2.fromOffset(12, 6), {
            TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11, TextColor3 = C.muted,
        })

    local function row(key, value)
        return dim(key .. ": ") .. esc(value == nil and "-" or tostring(value))
    end

    B.draw = function()
        breakSwitch.Text = "Auto-break: " .. (B.on and "ON" or "OFF")
        breakSwitch.BackgroundColor3 = B.on and C.green or C.grey
        statusLbl.Text = B.status

        local s = B.snap
        local lines = {
            row("Event", s.eventOn == nil and nil or (s.eventOn and "on" or "off")),
            row("Your zone", s.zone),
            row("Hit cooldown", s.cooldown and (("%.2fs"):format(s.cooldown)) or nil),
            row("Hit range", s.reach and (("%s studs"):format(tostring(s.reach))) or nil),
        }
        if B.on or B.hits > 0 or B.bossHits > 0 then
            local minutes = math.max((os.clock() - (B.startedAt or os.clock())) / 60, 1e-6)
            lines[#lines + 1] = row("This run", ("%d breakable hits, %d boss hits (%d per minute)"):format(
                B.hits, B.bossHits, math.floor((B.hits + B.bossHits) / minutes)))
        end
        infoLbl.Text = table.concat(lines, "\n")
    end
end

local function rebuildEggs()
    clearList(eggList)
    local q = string.lower(hatchSearch.Text)
    local current = eggBox.Text
    local n = 0
    for _, name in ipairs(listEggs()) do
        if q == "" or string.find(string.lower(name), q, 1, true) then
            n = n + 1
            addRow(eggList, n, { rich = esc(name) .. (name == current and dim("  selected") or ""), plain = name }, {
                { text = "Pick", color = C.accent, fn = function() eggBox.Text = name end },
            })
        end
    end
    if n == 0 then
        addInfoRow(eggList, Eggs and "No eggs match." or "Eggs module not found - type the egg name on the right.")
    end
end

local function updateHatchUi()
    modeBtn.Text = HATCH_MODES[H.mode]
    moveBtn.Text = "Go to the egg if the server doesn't reply: " .. (H.goToEgg and "ON" or "OFF")
    moveBtn.BackgroundColor3 = H.goToEgg and C.accent or C.grey
    turboBtn.Text = "Turbo (don't wait for each reply): " .. (H.turbo and "ON" or "OFF")
    turboBtn.BackgroundColor3 = H.turbo and C.accent or C.grey
    autoBtn.Text = H.running and "Stop" or "Start auto-hatch"
    autoBtn.BackgroundColor3 = H.running and C.red or C.green
    local rate = hatchRate()
    local lines = {
        ("Hatched: %d     Shiny: %d     Last batch: %s"):format(H.total, H.shinies, H.batch > 0 and tostring(H.batch) or "-"),
        ("Speed: %s     Server reply: %s"):format(
            rate and ("%.1f eggs/s"):format(rate) or "-",
            H.reply and ("%d ms"):format(math.floor(H.reply * 1000)) or "-"),
        "Recent: " .. (#H.recent > 0 and table.concat(H.recent, ", ") or "-"),
        "Status: " .. H.status,
    }
    if not (HatchRemote and HatchResult) then
        table.insert(lines, 1, "Missing remote: " .. (HatchRemote and "" or "Hatch ") .. (HatchResult and "" or "HatchResult"))
    end
    hatchStats.Text = table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Refresh
----------------------------------------------------------------------
local function incomingText(req)
    local plr = Players:FindFirstChild(req.from)
    local secs = math.max(0, math.ceil(req.expires - os.clock()))
    return esc(plr and plr.DisplayName or req.from) .. dim("  (" .. secs .. "s)")
end

local function unlockText()
    if not Trading then return "Trading module not found - the server decides whether you can trade." end
    if tradingUnlocked() then return "Trading is unlocked.\n\nPick a player on the left and press Send. Requests you receive show up above." end
    local eggs = try(Trading.GetEggs, LocalPlayer)
    return ("Trading is locked: open %s eggs to unlock (opened so far: %s)."):format(tostring(Trading.EGGS_REQUIRED), tostring(eggs))
end

local function rebuildPlayers()
    clearList(playerList)
    local q = string.lower(playerSearch.Text)
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local plain = plr.DisplayName .. " @" .. plr.Name
            if q == "" or string.find(string.lower(plain), q, 1, true) then
                table.insert(list, { plr = plr, plain = plain })
            end
        end
    end
    table.sort(list, function(a, b)
        return string.lower(a.plr.DisplayName) < string.lower(b.plr.DisplayName)
    end)

    if #list == 0 then
        addInfoRow(playerList, "No other players found.")
        return
    end
    for i, e in ipairs(list) do
        addRow(playerList, i, { rich = esc(e.plr.DisplayName) .. dim("  @" .. e.plr.Name), plain = e.plain }, {
            { text = "Send", color = C.green, fn = function() sendRequest(e.plr) end },
        })
    end
end

local function rebuildIncoming()
    clearList(incomingList)
    table.clear(incomingLabels)
    local ids = {}
    for id in pairs(incoming) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return incoming[a].expires < incoming[b].expires end)

    for i, id in ipairs(ids) do
        local _, label = addRow(incomingList, i, { rich = incomingText(incoming[id]), plain = incoming[id].from }, {
            { text = "Yes", color = C.green, fn = function() respondToRequest(id, true) end },
            { text = "No", color = C.red, fn = function() respondToRequest(id, false); requestRefresh() end },
        })
        incomingLabels[id] = label
    end
    if #ids == 0 then addInfoRow(incomingList, "No incoming requests.") end
end

local function updateIncomingTimers()
    local now, expired = os.clock(), false
    for id, req in pairs(incoming) do
        if now >= req.expires then
            incoming[id] = nil
            expired = true
        end
    end
    if expired then
        requestRefresh()
        return
    end
    for id, label in pairs(incomingLabels) do
        local req = incoming[id]
        if req and label.Parent then label.Text = incomingText(req) end
    end
end

local function rebuildInventory()
    clearList(invList)
    for name, btn in pairs(tabButtons) do
        btn.BackgroundColor3 = (name == state.tab) and C.accent or C.grey
    end

    if not StatsMod then
        state.shown = {}
        addInfoRow(invList, "Stats module not found, so the inventory can't be listed. Offers, Ready, Confirm and Cancel still work.")
        return
    end

    local ok, recs = pcall(getInventory, state.tab)
    if not ok then
        state.shown = {}
        warn("[TradeHelper] inventory error: " .. tostring(recs))
        addInfoRow(invList, "Couldn't read this tab (see console).")
        return
    end

    local q = string.lower(searchBox.Text)
    local shown = {}
    for _, rec in ipairs(recs) do
        if q == "" or string.find(string.lower(rec.plain), q, 1, true) then
            table.insert(shown, rec)
        end
    end
    state.shown = shown

    if #shown == 0 then
        addInfoRow(invList, "Nothing tradable here.")
        return
    end
    for i, rec in ipairs(shown) do
        rec.showAmount = true
        addRow(invList, i, rec, {
            { text = "+", color = C.green, fn = function() addOffer(rec, getQty()) end },
            { text = "All", color = C.accent, fn = function() addOffer(rec, rec.amount) end },
        })
    end
end

local function rebuildOffers()
    clearList(myList)
    clearList(theirList)

    local mine = offerRecords(offers.me)
    for i, rec in ipairs(mine) do
        rec.showAmount = true
        addRow(myList, i, rec, {
            { text = "-", color = C.amber, fn = function() removeOffer(rec, getQty()) end },
            { text = "X", color = C.red, fn = function() removeOffer(rec, rec.amount) end },
        })
    end
    if offers.me.Tokens > 0 then
        addRow(myList, 1000, { rich = "Tokens", amount = offers.me.Tokens, showAmount = true }, {
            { text = "X", color = C.red, fn = function() setTokens(0) end },
        })
    end
    if #mine == 0 and offers.me.Tokens == 0 then addInfoRow(myList, "Nothing offered yet.") end

    local theirs = offerRecords(offers.them)
    for i, rec in ipairs(theirs) do
        rec.showAmount = true
        addRow(theirList, i, rec, {})
    end
    if offers.them.Tokens > 0 then
        addRow(theirList, 1000, { rich = "Tokens", amount = offers.them.Tokens, showAmount = true }, {})
    end
    if #theirs == 0 and offers.them.Tokens == 0 then addInfoRow(theirList, "Nothing offered yet.") end
end

local function updateStatus()
    local txt
    local flashing = os.clock() < state.flashUntil
    if flashing then
        txt = state.flash
    elseif not state.tradeId then
        if state.page == "Send" then
            txt = "Pick a player and press Send. Incoming requests show on the right."
        elseif state.page == "Misc" then
            txt = "Misc tools"
        elseif state.page == "Hatch" then
            txt = H.running and "Auto-hatching..." or "Auto hatch: pick an egg and a mode, then press Start."
        elseif state.page == "Quests" then
            txt = Q.auto and "Auto-claiming finished pet quests..." or "Pet quests: turn on Auto-claim, or press Claim ready."
        elseif state.page == "Auto" then
            txt = A.on and "Auto-using the items you switched ON..." or "Auto use is off. Switch items ON, then turn Auto-use on."
        elseif state.page == "Mine" then
            txt = (M.own or M.want) and "Auto mining is ON." or "Mining: switch an Auto Mine mode on once you're in the mine."
        elseif state.page == "Treat" then
            txt = T.auto and "Auto-claiming Trick or Treat pads as they come ready..." or "Trick or Treat: turn on Auto-claim, or press Claim all ready."
        elseif state.page == "Break" then
            txt = B.on and "Auto-breaking event breakables..." or "Breakables: switch Auto-break on while you're in the Halloween event."
        else
            txt = "No active trade. Send or accept a request on the Send Trade page."
        end
    else
        local function s(b) return b and "READY" or "-" end
        txt = ("Trading with %s   |   you: %s   them: %s"):format(tostring(state.partner), s(state.ready.me), s(state.ready.them))
        if state.bothConfirmed then
            txt = txt .. "   |   locked in"
            if state.countdownEnd then
                txt = txt .. (", completing in %ds"):format(math.max(0, math.ceil(state.countdownEnd - os.clock())))
            end
        elseif state.confirmed.me then
            txt = txt .. "   |   you confirmed"
        elseif state.bothReady then
            txt = txt .. "   |   press Confirm"
        end
    end
    statusLabel.Text = txt
    statusDot.BackgroundColor3 = flashing and C.accent or (state.tradeId and C.green or (H.running and C.amber or C.muted))

    readyBtn.Text = state.ready.me and "Unready" or "Ready"
    confirmBtn.BackgroundColor3 = state.bothReady and C.amber or C.grey

    local pending = 0
    for _ in pairs(incoming) do pending = pending + 1 end
    navBadges.Send.Visible = pending > 0
    navBadges.Send.Text = tostring(pending)

    -- page-specific labels run protected, so a failure here is reported (with where it happened)
    -- instead of repeating forever or taking the rest of the window down with it
    local ok, err = xpcall(function()
        if state.page == "Send" then
            local now = os.clock()
            if now - (state.unlockAt or 0) > 1 and not state.unlockBusy then
                -- the game's Trading module is asked once a second, in its own thread (see restoreIdentity)
                state.unlockAt = now
                state.unlockBusy = true
                task.spawn(function()
                    local good, text = xpcall(unlockText, debug.traceback)
                    state.unlockMsg = good and text or ("Couldn't read the trade lock status:\n" .. tostring(text))
                    state.unlockBusy = false
                end)
            end
            unlockLabel.Text = state.unlockMsg or "Checking..."
        elseif state.page == "Misc" then
            miscInfo.Text = ("Players %d/%d   |   PlaceId %s   |   JobId %s"):format(
                #Players:GetPlayers(), Players.MaxPlayers, tostring(game.PlaceId), tostring(game.JobId))
        elseif state.page == "Hatch" then
            updateHatchUi()
        elseif state.page == "Quests" then
            Q.draw()
        elseif state.page == "Auto" then
            A.draw()
        elseif state.page == "Mine" then
            M.draw()
        elseif state.page == "Treat" then
            T.draw()
        elseif state.page == "Break" then
            B.draw()
        end
    end, debug.traceback)
    if not ok then
        local parts = {}
        for line in tostring(err):gmatch("[^\n]+") do
            if #parts < 4 and not line:find("Stack Begin", 1, true) then parts[#parts + 1] = line end
        end
        flash("page update failed: " .. table.concat(parts, " | "), 8)
    end
end

local function refresh()
    if destroyed then return end
    restoreIdentity()
    if state.page == "Send" then
        rebuildPlayers()
        rebuildIncoming()
    elseif state.page == "Trade" then
        rebuildInventory()
        rebuildOffers()
    elseif state.page == "Hatch" then
        rebuildEggs()
    end
    updateStatus()
end

local refreshPending = false
function requestRefresh()
    if refreshPending or destroyed then return end
    refreshPending = true
    task.defer(function()
        refreshPending = false
        refresh()
    end)
end

function setPage(name)
    state.page = name
    for key, page in pairs(pages) do
        page.Visible = key == name
    end
    paintNav()
    requestRefresh()
end

connect(searchBox:GetPropertyChangedSignal("Text"), requestRefresh)
connect(playerSearch:GetPropertyChangedSignal("Text"), requestRefresh)
connect(hatchSearch:GetPropertyChangedSignal("Text"), requestRefresh)
connect(eggBox:GetPropertyChangedSignal("Text"), requestRefresh)
if HatchResult then connect(HatchResult.OnClientEvent, guard("hatch result", onHatchResult)) end
connect(Players.PlayerAdded, requestRefresh)
connect(Players.PlayerRemoving, function()
    task.delay(0.2, requestRefresh) -- the leaving player is still in GetPlayers() while this fires
end)
connect(TradeEvent.OnClientEvent, onTradeEvent)
-- The game calls this from its own thread, which has fewer capabilities than ours. Work started from there
-- (task.defer inherits the caller's permissions) can fail on things our own threads may touch, so the
-- callback only raises a flag and the update loop below does the refresh.
local statsDirty = false
if StatsMod and StatsMod.OnChanged then
    pcall(StatsMod.OnChanged, function() statsDirty = true end)
end

task.spawn(function()
    -- guarded so one bad tick can't kill the loop and freeze every label in the window
    local tick = guard("update", function()
        restoreIdentity()
        if statsDirty then
            statsDirty = false
            if state.tradeId then requestRefresh() end
        end
        Q.tick()
        updateIncomingTimers()
        updateStatus()
    end)
    while not destroyed do
        tick()
        task.wait(0.2)
    end
end)

paintNav()
refresh()
