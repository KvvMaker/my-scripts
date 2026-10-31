--[[
    Fishing Auto-Play
    Plays the fishing minigame through the game's OWN input handlers (the same ones a real click / key press
    reaches), so the client state machine, click prediction and UI behave exactly as in manual play.
    Reads FishingController (state + luck bar / pull bar signals + counter prompts) and fires the
    FishingPrimary / QTE_* input actions from KeybindsController.

    WHAT IT DOES
      Auto Cast       holds the cast and lets go inside the Perfect zone of the luck bar (>= LuckBar.Threshold)
      Perfect Pull    clicks the first-pull bar when it sits in the best multiplier zone
      Auto Reel       clicks at the manual click rate (Click.ManualCps) while reeling
      Auto Counter    answers the A / D / W counter prompts after a human-like reaction delay
      Auto Skills     presses your skill actions while reeling (the last FinisherPct of fish HP needs skills)
      Auto Loot       dismisses the catch popup so the next cast can start
      Anti-AFK        stops the 20 minute idle kick

    WINDOW
      Play        Start / Stop, what the bot is doing right now, fish HP, session stats
      Settings    switch each automation on or off, tune the human-like timings (saved between sessions)
      Rods        the shop's rods with price / owned / locked state; buy one with in-game currency (two clicks,
                  never Robux)
      Log         recent events: casts, perfect pulls, catches, escapes, warnings

    USAGE
      * Equip your rod, stand at the water facing open water, execute this, press Start (or F6).
      * RightShift hides the window, "-" collapses it, "x" stops the bot and unloads (re-executing replaces it).

    NOTES
      * Needs an executor with firesignal (or getconnections). Everything is skipped with a warning if missing.
      * Skills are cast with the slot keys from the game's SkillSlotConfig (Z / X / C / V), held for the skill's
        minimum cast time. Auto Loot closes the catch popup the way the game does: with a click anywhere on screen
        (not on a loot card, not on this window). Real clicks go through VirtualInputManager, so the Roblox window
        needs to be in focus; if the popup is still open after 8 tries the details are printed to the console.
      * Reaction times are randomised and kept above Latency.QteReactionFloor, clicks never exceed the
        client's own click-rate limiter. This is still automation: the server can see an unusually perfect player.
]]

local CONFIG = {
    ToggleKey = Enum.KeyCode.RightShift,   -- show / hide the window
    StartKey = Enum.KeyCode.F6,            -- start / stop the bot
    Recast = { 0.35, 1.0 },                -- extra random wait (s) before each cast (Settings tab slider)
    QteReaction = { 0.18, 0.42 },          -- random delay (s) before answering a counter prompt (slider)
    SkillInterval = { 1.2, 1.8 },          -- seconds between skill presses while reeling (slider)
    FinisherSkillInterval = 0.8,           -- ... once the fish is at the finisher gate
    SkillKeys = {},                        -- leave empty: the keys come from the game's SkillSlotConfig (Z / X / C / V). Override with e.g. { Enum.KeyCode.One }
    SettingsFile = "FishingAutoPlay.json", -- saved toggles / sliders (needs readfile / writefile)
}

local opts = {
    AutoCast = true,
    PerfectCast = true,
    PerfectFirstPull = true,
    AutoReel = true,
    AutoCounter = true,
    AutoSkills = true,
    AutoLoot = true,
    AntiAfk = true,
}

-- human-like timing sliders: the slider sets the low end, `span` is added for the high end
local SLIDERS = {
    { key = "QteReaction", label = "Counter reaction", min = 0.18, max = 0.60, span = 0.24, default = 0.18 },
    { key = "Recast", label = "Recast delay", min = 0.20, max = 3.00, span = 0.65, default = 0.35 },
    { key = "SkillInterval", label = "Skill interval", min = 0.60, max = 4.00, span = 0.60, default = 1.20 },
}
local sliderValues = {}
for _, s in ipairs(SLIDERS) do sliderValues[s.key] = s.default end

local env = (getgenv and getgenv()) or _G
if env.FishingAutoPlay and env.FishingAutoPlay.Destroy then
    pcall(env.FishingAutoPlay.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local function try(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local VirtualInputManager = try(function() return game:GetService("VirtualInputManager") end)
local VirtualUser = try(function() return game:GetService("VirtualUser") end)
local HttpService = try(function() return game:GetService("HttpService") end)
local TweenService = try(function() return game:GetService("TweenService") end)

-- Calling into the game's own code can leave the calling thread with the game's (lower) identity, and a thread like
-- that may not touch our window ("lacking capability Plugin"). So: remember our identity now and put it back after
-- every call into game code, and never let a game callback touch the window directly (see logEvent).
local restoreIdentity
do
    local getIdentity = getthreadidentity or getidentity or get_thread_identity or getthreadcontext
    local setIdentity = setthreadidentity or setidentity or set_thread_identity or setthreadcontext
    local baseIdentity = getIdentity and try(getIdentity) or nil
    function restoreIdentity()
        if setIdentity and baseIdentity then pcall(setIdentity, baseIdentity) end
    end
end

local function rand(a, b)
    return a + math.random() * (b - a)
end

local function applySlider(s, v)
    sliderValues[s.key] = v
    CONFIG[s.key] = { v, v + s.span }
end

----------------------------------------------------------------------
-- Saved settings
----------------------------------------------------------------------
local function loadSettings()
    if not (readfile and isfile and HttpService) then return end
    local data = try(function()
        if not isfile(CONFIG.SettingsFile) then return nil end
        return HttpService:JSONDecode(readfile(CONFIG.SettingsFile))
    end)
    if type(data) ~= "table" then return end
    if type(data.opts) == "table" then
        for k in pairs(opts) do
            if type(data.opts[k]) == "boolean" then opts[k] = data.opts[k] end
        end
    end
    if type(data.sliders) == "table" then
        for _, s in ipairs(SLIDERS) do
            local v = tonumber(data.sliders[s.key])
            if v then sliderValues[s.key] = math.max(s.min, math.min(s.max, v)) end
        end
    end
end

local function saveNow()
    if not (writefile and HttpService) then return end
    pcall(function()
        writefile(CONFIG.SettingsFile, HttpService:JSONEncode({ opts = opts, sliders = sliderValues }))
    end)
end

local saveToken = 0
local function saveSoon()
    saveToken = saveToken + 1
    local token = saveToken
    task.delay(0.6, function()
        if token == saveToken then saveNow() end
    end)
end

loadSettings()
for _, s in ipairs(SLIDERS) do applySlider(s, sliderValues[s.key]) end

----------------------------------------------------------------------
-- Game modules
----------------------------------------------------------------------
local Controllers = ReplicatedStorage:WaitForChild("Controllers", 15)

local function getController(name)
    local m = Controllers and Controllers:FindFirstChild(name)
    if m then
        local r = try(require, m)
        if type(r) == "table" then return r end
    end
    local Stardust = try(function() return require(ReplicatedStorage:WaitForChild("Stardust", 5)) end)
    if Stardust and Stardust.Client and Stardust.Client.GetController then
        return try(Stardust.Client.GetController, name)
    end
    return nil
end

local Data = ReplicatedStorage:WaitForChild("Data", 15)
local FishingConfig = Data and try(function() return require(Data.Config.FishingConfig) end)
local FishingEnums = Data and try(function() return require(Data.Enums.FishingEnums) end)
local Fishing = getController("FishingController")
local Keybinds = getController("KeybindsController")
local PullBarMath = try(function() return require(ReplicatedStorage.Shared.Lib.PullBarMath) end)

-- optional: the game's satchel rules, only used to explain why a cast was blocked (the bot works without them)
local PlayerData = getController("PlayerDataV2Controller")
local FishStorageRules = try(function() return require(ReplicatedStorage.Shared.Lib.FishStorageRules) end)

local function satchelFull()
    if not (FishStorageRules and FishStorageRules.GetState and PlayerData) then return false end
    local full = try(function()
        local data = PlayerData:Fetch(LocalPlayer)
        return data ~= nil and FishStorageRules.GetState(data).isFull == true
    end) == true
    restoreIdentity()
    return full
end

local missing = {}
if not FishingConfig then missing[#missing + 1] = "FishingConfig" end
if not (FishingEnums and FishingEnums.State) then missing[#missing + 1] = "FishingEnums" end
if not (Fishing and type(Fishing.GetState) == "function") then missing[#missing + 1] = "FishingController" end
if not (Keybinds and type(Keybinds.GetAction) == "function") then missing[#missing + 1] = "KeybindsController" end
if #missing > 0 then
    warn("[FishingAutoPlay] could not load: " .. table.concat(missing, ", ") .. " - is the game fully loaded?")
    return
end
if not (firesignal or getconnections) then
    warn("[FishingAutoPlay] this executor has neither firesignal nor getconnections - cannot drive the game's input")
    return
end

local State = FishingEnums.State
local stateName = {}
for k, v in pairs(State) do stateName[v] = k end

----------------------------------------------------------------------
-- Input helpers
----------------------------------------------------------------------
local function fireSignal(sig, ...)
    if not sig then return false end
    if firesignal and pcall(firesignal, sig, ...) then return true end
    if getconnections then
        local ok, list = pcall(getconnections, sig)
        if ok and type(list) == "table" then
            for _, c in ipairs(list) do pcall(function(...) c:Fire(...) end, ...) end
            return #list > 0
        end
    end
    return false
end

local actionCache = {}
local function getAction(name)
    local a = actionCache[name]
    if a and (typeof(a) ~= "Instance" or a.Parent) then return a end
    a = try(function() return Keybinds:GetAction(name) end)
    actionCache[name] = a
    return a
end

local function press(name, which)
    local a = getAction(name)
    if not a then return false end
    return fireSignal(a[which or "Pressed"])
end

local function clickAt(x, y)
    if not VirtualInputManager then return end
    task.spawn(pcall, function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
end

local function pressKey(keyCode, hold)
    if not VirtualInputManager then return end
    pcall(function() VirtualInputManager:SendKeyEvent(true, keyCode, false, game) end)
    task.delay(hold or 0.05, function()
        pcall(function() VirtualInputManager:SendKeyEvent(false, keyCode, false, game) end)
    end)
end

----------------------------------------------------------------------
-- Pull bar zones (same zones the game scores the first pull with)
----------------------------------------------------------------------
local zones = {}
for _, z in ipairs(FishingConfig.PullBar.Zones) do zones[#zones + 1] = z end
table.sort(zones, function(a, b) return a.threshold < b.threshold end)

local function multiplierAt(v)
    if PullBarMath and PullBarMath.Multiplier then
        local m = try(PullBarMath.Multiplier, v)
        if type(m) == "number" then return m end
    end
    for _, z in ipairs(zones) do
        if v <= z.threshold then return z.multiplier end
    end
    return zones[#zones].multiplier
end

local bestMultiplier = zones[#zones].multiplier
-- aim for the middle of the best zone, not its edge
local lastZoneLow = (#zones >= 2) and zones[#zones - 1].threshold or 0
local pullTarget = lastZoneLow + (zones[#zones].threshold - lastZoneLow) * 0.5

----------------------------------------------------------------------
-- Bot state, stats and event log
----------------------------------------------------------------------
local running = false
local destroyed = false
local conns = {}

local stats = { casts = 0, perfectCasts = 0, pulls = 0, perfectPulls = 0, counters = 0, counterHits = 0, catches = 0, escapes = 0, skills = 0, loot = 0 }
local lastCatch = ""
local runAccum, runStartedAt = 0, 0   -- seconds the bot has been running (accumulated + current stretch)

local function runSeconds()
    return runAccum + (running and (os.clock() - runStartedAt) or 0)
end

-- logEvent is called from game callbacks too, so it only records; the window's refresh loop turns the queue into lines
local logBuffer = {}
local logQueue = {}
local function logEvent(text, kind)
    local entry = { t = runSeconds(), text = text, kind = kind or "info" }
    logBuffer[#logBuffer + 1] = entry
    if #logBuffer > 80 then table.remove(logBuffer, 1) end
    logQueue[#logQueue + 1] = entry
    if #logQueue > 80 then table.remove(logQueue, 1) end
end

local note, noteUntil, warnUntil = "", 0, 0
local lastNoteText, lastNoteLogAt = "", -100
local function setNote(text, seconds, kind)
    kind = kind or "warn"
    note = text
    noteUntil = os.clock() + (seconds or 8)
    if kind == "warn" then warnUntil = noteUntil end
    local now = os.clock()
    if text ~= lastNoteText or now - lastNoteLogAt > 10 then
        lastNoteText, lastNoteLogAt = text, now
        logEvent(text, kind)
    end
end

local function resetStats()
    for k in pairs(stats) do stats[k] = 0 end
    lastCatch = ""
    runAccum, runStartedAt = 0, os.clock()
end

----------------------------------------------------------------------
-- Skill discovery (best effort: the controller does not say how skills are triggered)
----------------------------------------------------------------------
local skillActions = {}
local skillKeys = {}           -- KeyCodes pressed through VirtualInputManager (CONFIG.SkillKeys, else SkillSlotConfig)
local inputActionNames = {}

local function keyName(k)
    return tostring(k):match("[^.]+$") or tostring(k)
end

local function discoverSkills()
    local seen = {}
    local function scan(root)
        if not root then return end
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("InputAction") and not seen[d.Name] then
                seen[d.Name] = true
                inputActionNames[#inputActionNames + 1] = d.Name
                -- Skill1 / Skill_2 / SkillSlot3 - but not things like SkillMenu_Toggle
                if d.Name:lower():find("^skill.-%d+$") then
                    skillActions[#skillActions + 1] = { name = d.Name, inst = d }
                end
            end
        end
    end
    scan(ReplicatedStorage)
    scan(LocalPlayer)
    scan(game:GetService("StarterPlayer"))
    table.sort(skillActions, function(a, b) return a.name < b.name end)
    table.sort(inputActionNames)
    print("[FishingAutoPlay] input actions: " .. (#inputActionNames > 0 and table.concat(inputActionNames, ", ") or "(none found)"))
    print("[FishingAutoPlay] skill actions used: " .. (#skillActions > 0 and #skillActions or "none"))

    -- no skill InputActions: press the skill slot keys the game itself defines (SkillSlotConfig: Z / X / C / V)
    for _, k in ipairs(CONFIG.SkillKeys) do skillKeys[#skillKeys + 1] = k end
    if #skillKeys == 0 and #skillActions == 0 then
        local slotConfig = Data and try(function() return require(Data.Config.SkillSlotConfig) end)
        if type(slotConfig) == "table" and type(slotConfig.Slots) == "table" then
            for _, slot in ipairs(slotConfig.Slots) do
                if slot.key ~= nil then skillKeys[#skillKeys + 1] = slot.key end
            end
        end
    end

    if #skillActions > 0 then
        local names = {}
        for i, a in ipairs(skillActions) do names[i] = a.name end
        logEvent("Skill actions found: " .. table.concat(names, ", "), "info")
    elseif #skillKeys > 0 then
        local names = {}
        for i, k in ipairs(skillKeys) do names[i] = keyName(k) end
        print("[FishingAutoPlay] skill keys used: " .. table.concat(names, " "))
        logEvent("Skills on keys: " .. table.concat(names, " "), "info")
    else
        logEvent("No skills found - set CONFIG.SkillKeys or send me your skill controller", "warn")
    end
end

local castStage = nil          -- nil | "pressed" | "luck" | "released"
local castStageAt = 0
local castPerfect = false
local lastPower = 0
local failStreak = 0
local safeCasts = 0            -- casts left to make at normal power after Perfect casts kept getting blocked
local luckTarget = 0.9
local nextCastAt = 0
local firstPullDone = false
local firstPullToken = 0
local nextClickAt = 0
local nextSkillAt = 0
local skillIndex = 0
local gateWarned = false
local qteToken = 0
local lootTries = 0
local nextLootAt = 0

local function pickLuckTarget()
    local threshold = FishingConfig.LuckBar.Threshold
    if opts.PerfectCast and safeCasts == 0 then
        -- somewhere inside the Perfect zone, not always the first frame that qualifies
        return threshold + 0.02 + math.random() * math.max(0.01, 1 - threshold - 0.05)
    end
    -- Perfect distance is blocked at this spot (no open water that far out) or Perfect is off: normal power
    return rand(0.35, 0.65)
end

local function startCast(now)
    castStage = "pressed"
    castStageAt = now
    press("FishingPrimary", "Pressed")
    if Fishing:GetState() ~= State.Holding then
        castStage = nil
        nextCastAt = now + 1.5
        if satchelFull() then
            nextCastAt = now + 4
            setNote("Satchel is full - sell some fish to keep casting")
        else
            setNote("Cast blocked - rod equipped? menu open? facing water?")
        end
    end
end

local function clickFirstPull()
    if firstPullDone then return end
    firstPullDone = true
    press("FishingPrimary", "Pressed")
end

local function doReelClick(now)
    local cps = FishingConfig.Click.ManualCps
    press("FishingPrimary", "Pressed")
    nextClickAt = now + 1 / cps + 0.012 + math.random() * 0.03
end

local function doSkill(now)
    local n, m = #skillActions, #skillKeys
    local _, hp, maxHp = Fishing:GetFishInfo()
    local atGate = type(hp) == "number" and type(maxHp) == "number" and maxHp > 0
        and hp / maxHp <= FishingConfig.Fight.FinisherPct + 0.04
    if n == 0 and m == 0 then
        nextSkillAt = now + 2
        if atGate and not gateWarned then
            gateWarned = true
            setNote("Fish is at the finisher gate but no skills are available")
        end
        return
    end
    -- hold for the skill's minimum cast time, so a hold-to-cast skill is not cancelled by a quick tap
    local hold = ((FishingConfig.Skill and FishingConfig.Skill.MinCastTime) or 0.5) + 0.1
    local gap = atGate and CONFIG.FinisherSkillInterval or rand(CONFIG.SkillInterval[1], CONFIG.SkillInterval[2])
    nextSkillAt = now + math.max(gap, hold + 0.1)
    stats.skills = stats.skills + 1
    if n > 0 then
        skillIndex = skillIndex % n + 1
        local entry = skillActions[skillIndex]
        local action = getAction(entry.name) or entry.inst
        fireSignal(action.Pressed)
        task.delay(hold, function() fireSignal(action.Released) end)
    else
        skillIndex = skillIndex % m + 1
        pressKey(skillKeys[skillIndex], hold)
    end
end

-- loot popup ---------------------------------------------------------------
-- The game closes its catch popup on ANY mouse click / tap once it is ready (LootController listens to
-- UserInputService.InputBegan for MouseButton1 or Touch), except a click that lands on one of the loot item cards.
-- So the bot clicks somewhere safe: not on a card and not on this window.
local windowRect = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }   -- kept up to date by the window's refresh loop (plain numbers)
local dismissLoot
do
    local LootController = getController("LootController")
    -- where to click, as fractions of the screen; later tries rotate through them
    local CANDIDATES = { { 0.08, 0.5 }, { 0.5, 0.9 }, { 0.5, 0.1 }, { 0.1, 0.15 }, { 0.1, 0.85 }, { 0.9, 0.15 }, { 0.9, 0.85 }, { 0.25, 0.5 }, { 0.75, 0.5 }, { 0.5, 0.5 } }

    -- nil if the controller isn't available; otherwise whether a fishing loot popup is currently open
    local function popupActive()
        if not (LootController and LootController.IsFishingLootActive) then return nil end
        local active = try(function() return LootController:IsFishingLootActive() end)
        restoreIdentity()
        return active
    end

    -- the same test the game uses to ignore clicks on item cards
    local function hitsItemCard(x, y)
        local objects = try(function() return PlayerGui:GetGuiObjectsAtPosition(x, y) end)
        if type(objects) ~= "table" then return false end
        for _, g in ipairs(objects) do
            local cur = g
            while cur and cur ~= PlayerGui do
                if cur:GetAttribute("LootItemCard") == true then return true end
                cur = cur.Parent
            end
        end
        return false
    end

    local function insideWindow(x, y)
        return x >= windowRect.x0 - 12 and x <= windowRect.x1 + 12 and y >= windowRect.y0 - 12 and y <= windowRect.y1 + 12
    end

    -- a point (GUI coordinates) that is neither on an item card nor on this window
    local function safePoint(attempt)
        local cam = workspace.CurrentCamera
        local size = cam and cam.ViewportSize or Vector2.new(1280, 720)
        local w, h = size.X, size.Y - GuiService:GetGuiInset().Y
        local first
        for i = 0, #CANDIDATES - 1 do
            local c = CANDIDATES[(attempt - 1 + i) % #CANDIDATES + 1]
            local x, y = c[1] * w, c[2] * h
            first = first or { x, y }
            if not insideWindow(x, y) and not hitsItemCard(x, y) then return x, y end
        end
        return first[1], first[2]
    end

    -- hands the game's own InputBegan handler a left click directly (used if real clicks are not getting through)
    local function fakeClick(x, y)
        fireSignal(UserInputService.InputBegan, {
            UserInputType = Enum.UserInputType.MouseButton1, UserInputState = Enum.UserInputState.Begin,
            KeyCode = Enum.KeyCode.Unknown, Position = Vector3.new(x, y, 0),
        }, false)
    end

    function dismissLoot(now)
        lootTries = lootTries + 1
        nextLootAt = now + 0.9
        local active = popupActive()
        if active == false then return end   -- the popup is already closing
        local x, y = safePoint(lootTries)
        if lootTries >= 4 and lootTries % 3 == 1 then
            fakeClick(x, y)
        else
            clickAt(x, y + GuiService:GetGuiInset().Y)   -- a real click through VirtualInputManager (screen coordinates)
        end
        stats.loot = stats.loot + 1
        setNote(string.format("Loot: clicked to close the popup (try %d)", lootTries), 6, "info")
        if lootTries == 8 then
            print(string.format("[FishingAutoPlay] the catch popup is still open after %d clicks (IsFishingLootActive = %s)", lootTries, tostring(active)))
            logEvent("Catch popup still open after 8 clicks - send me the console output", "warn")
        end
    end
end

----------------------------------------------------------------------
-- Game events
----------------------------------------------------------------------
local warned = false
local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok and not warned then
            warned = true
            warn("[FishingAutoPlay] handler error (further errors muted): " .. tostring(err))
            logEvent("Handler error: " .. tostring(err), "bad")
        end
    end
end

local function connect(sig, fn, label)
    if not sig then
        warn("[FishingAutoPlay] missing signal: " .. label)
        return
    end
    local c = sig:Connect(safe(fn))
    conns[#conns + 1] = c
end

local function onStateChanged(newState, data)
    if not running then return end
    local now = os.clock()
    if newState == State.Throwing then
        if castStage == "pressed" then
            castStage = "luck"
            castStageAt = now
            luckTarget = pickLuckTarget()
        end
    elseif newState == State.Waiting then
        if castStage then
            stats.casts = stats.casts + 1
            if castPerfect then stats.perfectCasts = stats.perfectCasts + 1 end
            logEvent(string.format("Cast %.2f%s", lastPower, castPerfect and " - Perfect" or ""), castPerfect and "good" or "info")
            failStreak = 0
            if safeCasts > 0 then safeCasts = safeCasts - 1 end
            castStage = nil
        end
    elseif newState == State.FirstPull then
        firstPullDone = false
        firstPullToken = firstPullToken + 1
        local token = firstPullToken
        local limit = type(data) == "table" and data.timeLimit or FishingConfig.FirstPull.TimeLimit
        -- safety net: if the bar never reports a good moment, still click before the time limit runs out
        task.delay(math.max(0.2, limit - 0.3), function()
            if running and token == firstPullToken and Fishing:GetState() == State.FirstPull then clickFirstPull() end
        end)
    elseif newState == State.Reeling then
        gateWarned = false
        nextClickAt = now + rand(0.15, 0.35)
        nextSkillAt = now + rand(0.6, 1.2)
    elseif newState == State.Caught then
        lootTries = 0
        nextLootAt = now + FishingConfig.Loot.ConfirmReadyDelay + 0.35
    elseif newState == State.Idling then
        if castStage then
            failStreak = failStreak + 1
            castStage = nil
            logEvent("Cast failed - back to idle", "warn")
            if failStreak >= 2 and safeCasts == 0 and opts.PerfectCast then
                safeCasts = 6
                setNote("Perfect casts keep getting blocked here - using normal power for a few casts", 12)
            end
        end
        nextCastAt = now + FishingConfig.General.CastCancelDelay + rand(CONFIG.Recast[1], CONFIG.Recast[2])
    end
end

local function onLuckBar(value)
    if not running or castStage ~= "luck" or type(value) ~= "number" then return end
    if value >= luckTarget then
        castStage = "released"
        castStageAt = os.clock()
        lastPower = value
        castPerfect = value >= FishingConfig.LuckBar.Threshold
        press("FishingPrimary", "Released")
    end
end

local function onPullBar(value)
    if not running or firstPullDone or type(value) ~= "number" then return end
    if Fishing:GetState() ~= State.FirstPull then return end
    if opts.PerfectFirstPull then
        if value >= pullTarget and multiplierAt(value) >= bestMultiplier then clickFirstPull() end
    else
        clickFirstPull()
    end
end

local function onQtePrompt(direction, window)
    qteToken = qteToken + 1
    if not (running and opts.AutoCounter) then return end
    local key = FishingConfig.Counter.DirectionToKey[direction]
    if not key then return end
    local token = qteToken
    local floor = FishingConfig.Latency.QteReactionFloor
    local lo, hi = CONFIG.QteReaction[1], CONFIG.QteReaction[2]
    local delay = math.max(lo, floor + 0.08) + math.random() * (hi - lo)
    delay = math.min(delay, (type(window) == "number" and window or 1.25) * 0.7)
    task.delay(delay, function()
        if not running or token ~= qteToken or Fishing:GetState() ~= State.Reeling then return end
        stats.counters = stats.counters + 1
        press("QTE_" .. key, "Pressed")
    end)
end

local function onQteResult(ok)
    qteToken = qteToken + 1
    if ok then
        stats.counterHits = stats.counterHits + 1
    elseif running then
        logEvent("Counter missed", "bad")
    end
end

local function onQteCancel()
    qteToken = qteToken + 1
end

local function onFirstPullResult(multiplier)
    if not running then return end
    stats.pulls = stats.pulls + 1
    local best = type(multiplier) == "number" and multiplier >= bestMultiplier
    if best then stats.perfectPulls = stats.perfectPulls + 1 end
    logEvent("First pull x" .. tostring(multiplier), best and "good" or "info")
end

local function onCatchResult(success, fishId, _, weight)
    if not running then return end
    if success then
        stats.catches = stats.catches + 1
        lastCatch = string.format("%s (%.1f kg)", tostring(fishId), tonumber(weight) or 0)
        logEvent("Caught " .. lastCatch, "good")
    else
        stats.escapes = stats.escapes + 1
        lastCatch = tostring(fishId ~= "" and fishId or "fish") .. " escaped"
        logEvent(lastCatch, "bad")
    end
end

local function tick()
    if not running then return end
    local now = os.clock()
    local s = Fishing:GetState()

    if castStage and now - castStageAt > (castStage == "released" and 10 or 4) then
        if castStage ~= "released" then press("FishingPrimary", "Released") end
        castStage = nil
        nextCastAt = now + 1
    end

    if s == State.Idling then
        if opts.AutoCast and not castStage and now >= nextCastAt then startCast(now) end
    elseif s == State.Reeling then
        if opts.AutoReel and now >= nextClickAt then doReelClick(now) end
        if opts.AutoSkills and now >= nextSkillAt then doSkill(now) end
    elseif s == State.Caught then
        if opts.AutoLoot and now >= nextLootAt then dismissLoot(now) end
    end
end

local function setRunning(on)
    if on == running then return end
    local now = os.clock()
    if on then
        running = true
        runStartedAt = now
        castStage = nil
        failStreak = 0
        safeCasts = 0
        nextCastAt = now + 0.5
        setNote("Started", 3, "info")
    else
        runAccum = runAccum + (now - runStartedAt)
        running = false
        if castStage == "pressed" or castStage == "luck" then press("FishingPrimary", "Released") end
        castStage = nil
        qteToken = qteToken + 1
        firstPullToken = firstPullToken + 1
        setNote("Stopped", 3, "info")
    end
end

connect(Fishing.StateChanged, onStateChanged, "StateChanged")
connect(Fishing.LuckBarUpdated, onLuckBar, "LuckBarUpdated")
connect(Fishing.PullBarUpdated, onPullBar, "PullBarUpdated")
connect(Fishing.FishQTEPrompt and Fishing.FishQTEPrompt.OnClientEvent, onQtePrompt, "FishQTEPrompt")
connect(Fishing.FishQTEResult and Fishing.FishQTEResult.OnClientEvent, onQteResult, "FishQTEResult")
connect(Fishing.FishQTECancel and Fishing.FishQTECancel.OnClientEvent, onQteCancel, "FishQTECancel")
connect(Fishing.FishBossStun and Fishing.FishBossStun.OnClientEvent, onQteCancel, "FishBossStun")
connect(Fishing.FishFirstPullResult and Fishing.FishFirstPullResult.OnClientEvent, onFirstPullResult, "FishFirstPullResult")
connect(Fishing.FishCatchResult and Fishing.FishCatchResult.OnClientEvent, onCatchResult, "FishCatchResult")
connect(RunService.Heartbeat, tick, "Heartbeat")

conns[#conns + 1] = LocalPlayer.Idled:Connect(function()
    if opts.AntiAfk and VirtualUser then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

task.spawn(discoverSkills)

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local C = {
    bg = Color3.fromRGB(18, 20, 27),
    surface = Color3.fromRGB(27, 30, 40),
    surface2 = Color3.fromRGB(37, 41, 54),
    stroke = Color3.fromRGB(52, 57, 74),
    text = Color3.fromRGB(232, 235, 245),
    dim = Color3.fromRGB(140, 147, 168),
    accent = Color3.fromRGB(94, 129, 244),
    green = Color3.fromRGB(64, 192, 134),
    red = Color3.fromRGB(236, 94, 106),
    amber = Color3.fromRGB(243, 178, 66),
    white = Color3.new(1, 1, 1),
}
local LOG_COLORS = { info = C.dim, good = C.green, bad = C.red, warn = C.amber }

local function new(class, props)
    local inst = Instance.new(class)
    local parent = props.Parent
    props.Parent = nil
    for k, v in pairs(props) do inst[k] = v end
    inst.Parent = parent
    return inst
end

local function tween(inst, props, t)
    if not TweenService then
        for k, v in pairs(props) do inst[k] = v end
        return
    end
    local ok = pcall(function()
        TweenService:Create(inst, TweenInfo.new(t or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
    end)
    if not ok then
        for k, v in pairs(props) do pcall(function() inst[k] = v end) end
    end
end

local function corner(inst, r)
    new("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = inst })
end

local function outline(inst, transparency)
    new("UIStroke", { Color = C.stroke, Thickness = 1, Transparency = transparency or 0.35, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = inst })
end

local function box(parent, size, pos, color, props)
    local f = new("Frame", { Parent = parent, Size = size, Position = pos or UDim2.new(), BackgroundColor3 = color or C.surface, BorderSizePixel = 0 })
    for k, v in pairs(props or {}) do f[k] = v end
    return f
end

local function text(parent, str, size, pos, props)
    local l = new("TextLabel", {
        Parent = parent, Text = str, Size = size, Position = pos or UDim2.new(), BackgroundTransparency = 1,
        TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd,
    })
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

local function button(parent, str, size, pos, color, callback, props)
    local b = new("TextButton", {
        Parent = parent, Text = str, Size = size, Position = pos or UDim2.new(), BackgroundColor3 = color or C.surface2,
        TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = true, BorderSizePixel = 0,
    })
    for k, v in pairs(props or {}) do b[k] = v end
    corner(b, 6)
    if callback then b.MouseButton1Click:Connect(callback) end
    return b
end

local gui = Instance.new("ScreenGui")
gui.Name = "FishingAutoPlay"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
local parentOk = pcall(function()
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not parentOk or not gui.Parent then
    gui.Parent = PlayerGui
end

local WIN_W, WIN_H = 340, 400
local HEADER_H, TABS_H = 40, 32
local main = box(gui, UDim2.fromOffset(WIN_W, WIN_H), UDim2.new(1, -WIN_W - 16, 0.5, -WIN_H / 2), C.bg, { ClipsDescendants = true })
corner(main, 10)
outline(main, 0.2)

-- header --------------------------------------------------------------------
local header = box(main, UDim2.new(1, 0, 0, HEADER_H), UDim2.new(), C.bg, { BackgroundTransparency = 1 })
local dragArea = box(header, UDim2.fromScale(1, 1), UDim2.new(), C.bg, { BackgroundTransparency = 1 })
local statusDot = box(header, UDim2.fromOffset(10, 10), UDim2.fromOffset(16, 15), C.dim)
corner(statusDot, 5)
text(header, "Fishing Auto-Play", UDim2.fromOffset(140, HEADER_H), UDim2.fromOffset(34, 0), { Font = Enum.Font.GothamBold, TextSize = 14 })
local headerStatus = text(header, "Stopped", UDim2.new(1, -228, 1, 0), UDim2.fromOffset(156, 0), {
    TextSize = 11, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Right,
})
local minButton = button(header, "–", UDim2.fromOffset(24, 24), UDim2.new(1, -64, 0, 8), C.surface2, nil, { TextSize = 14 })
local closeButton = button(header, "×", UDim2.fromOffset(24, 24), UDim2.new(1, -34, 0, 8), C.surface2, nil, { TextSize = 16, TextColor3 = C.red })

-- tabs ----------------------------------------------------------------------
local tabBar = box(main, UDim2.new(1, 0, 0, TABS_H), UDim2.fromOffset(0, HEADER_H), C.bg, { BackgroundTransparency = 1 })
local tabDivider = box(main, UDim2.new(1, 0, 0, 1), UDim2.fromOffset(0, HEADER_H + TABS_H), C.stroke, { BackgroundTransparency = 0.4 })
local TAB_NAMES = { "Play", "Settings", "Rods", "Log" }
local tabW = WIN_W / #TAB_NAMES
local tabIndicator = box(main, UDim2.fromOffset(tabW - 48, 2), UDim2.fromOffset(24, HEADER_H + TABS_H - 1), C.accent)
corner(tabIndicator, 1)

local pagesHolder = box(main, UDim2.new(1, 0, 1, -(HEADER_H + TABS_H + 1)), UDim2.fromOffset(0, HEADER_H + TABS_H + 1), C.bg, { BackgroundTransparency = 1 })
local pages, tabButtons = {}, {}

local function showTab(i)
    for n, page in ipairs(pages) do
        page.Visible = (n == i)
        tabButtons[n].TextColor3 = (n == i) and C.text or C.dim
    end
    tween(tabIndicator, { Position = UDim2.fromOffset((i - 1) * tabW + 24, HEADER_H + TABS_H - 1) }, 0.18)
end

for i, name in ipairs(TAB_NAMES) do
    tabButtons[i] = button(tabBar, name, UDim2.new(1 / #TAB_NAMES, 0, 1, 0), UDim2.new((i - 1) / #TAB_NAMES, 0, 0, 0), C.bg, function() showTab(i) end, {
        BackgroundTransparency = 1, AutoButtonColor = false, TextColor3 = C.dim, Font = Enum.Font.GothamMedium, Name = "Tab_" .. name,
    })
    pages[i] = box(pagesHolder, UDim2.fromScale(1, 1), UDim2.new(), C.bg, { BackgroundTransparency = 1, Visible = false, Name = "Page_" .. name })
end

-- PLAY page -------------------------------------------------------------------
local play = pages[1]
local startButton = button(play, "Start  (F6)", UDim2.new(1, -24, 0, 40), UDim2.fromOffset(12, 10), C.green, function()
    setRunning(not running)
end, { Font = Enum.Font.GothamBold, TextSize = 14, Name = "StartButton" })

local card = box(play, UDim2.new(1, -24, 0, 96), UDim2.fromOffset(12, 60), C.surface)
corner(card, 8)
outline(card)
local phaseLabel = text(card, "Stopped", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(12, 8), { Font = Enum.Font.GothamBold, TextSize = 14 })
local detailLabel = text(card, "", UDim2.new(1, -24, 0, 16), UDim2.fromOffset(12, 29), { TextSize = 11, TextColor3 = C.dim })

local pillRow = box(card, UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 52), C.surface, { BackgroundTransparency = 1 })
new("UIListLayout", { Parent = pillRow, FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })
local STAGES = { "Cast", "Bite", "Pull", "Reel", "Loot" }
local pills = {}
for i, name in ipairs(STAGES) do
    local pill = box(pillRow, UDim2.new(0.2, -5, 1, 0), UDim2.new(), C.surface2, { LayoutOrder = i, Name = "Stage_" .. name })
    corner(pill, 6)
    pills[i] = { frame = pill, label = text(pill, name, UDim2.fromScale(1, 1), UDim2.new(), { TextSize = 11, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamMedium }) }
end

local hpTrack = box(card, UDim2.new(1, -24, 0, 6), UDim2.fromOffset(12, 82), C.surface2, { Visible = false })
corner(hpTrack, 3)
local hpFill = box(hpTrack, UDim2.fromScale(0, 1), UDim2.new(), C.green)
corner(hpFill, 3)
box(hpTrack, UDim2.new(0, 2, 0, 10), UDim2.new(FishingConfig.Fight.FinisherPct, 0, 0.5, -5), C.amber)   -- marks the finisher gate on the HP bar

local grid = box(play, UDim2.new(1, -24, 0, 106), UDim2.fromOffset(12, 168), C.bg, { BackgroundTransparency = 1 })
new("UIGridLayout", { Parent = grid, CellSize = UDim2.new(1 / 3, -4, 0, 50), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder })
local TILES = { "Catches", "Escapes", "Casts", "Perfect casts", "Counters hit", "Skills used" }
local tiles = {}
for i, name in ipairs(TILES) do
    local tile = box(grid, UDim2.new(), UDim2.new(), C.surface, { LayoutOrder = i, Name = "Tile_" .. name })
    corner(tile, 8)
    outline(tile)
    tiles[i] = {
        value = text(tile, "0", UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, 5), { Font = Enum.Font.GothamBold, TextSize = 18 }),
        caption = text(tile, name, UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 30), { TextSize = 11, TextColor3 = C.dim }),
    }
end

local footerLabel = text(play, "", UDim2.new(1, -130, 0, 22), UDim2.fromOffset(14, 282), { TextSize = 11, TextColor3 = C.dim })
button(play, "Reset stats", UDim2.fromOffset(84, 22), UDim2.new(1, -96, 0, 282), C.surface2, function()
    resetStats()
    logEvent("Stats reset", "info")
end, { TextSize = 11, TextColor3 = C.dim, Name = "ResetStats" })

-- SETTINGS page -----------------------------------------------------------------
local settings = new("ScrollingFrame", {
    Parent = pages[2], Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
})
new("UIListLayout", { Parent = settings, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })
new("UIPadding", { Parent = settings, PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 14) })

local order = 0
local function nextOrder() order = order + 1 return order end

local function section(title)
    text(settings, title, UDim2.new(1, 0, 0, 16), UDim2.new(), { Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.dim, LayoutOrder = nextOrder() })
end

local TOGGLES = {
    { "AutoCast", "Auto Cast", "Cast whenever the rod is idle" },
    { "PerfectCast", "Perfect Cast", "Release the luck bar in the Perfect zone" },
    { "PerfectFirstPull", "Perfect Pull", "Click the first-pull bar in the best zone" },
    { "AutoReel", "Auto Reel", "Click while reeling at the game's click rate" },
    { "AutoCounter", "Auto Counter", "Answer the A / D / W prompts" },
    { "AutoSkills", "Auto Skills", "Press skills while reeling" },
    { "AutoLoot", "Auto Loot", "Close the catch popup" },
    { "AntiAfk", "Anti-AFK", "Stop the idle kick" },
}
local switches = {}

local function switchVisual(track, knob, on, animate)
    local goalTrack = on and C.accent or C.surface2
    local goalKnob = on and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
    if animate then
        tween(track, { BackgroundColor3 = goalTrack }, 0.15)
        tween(knob, { Position = goalKnob }, 0.15)
    else
        track.BackgroundColor3 = goalTrack
        knob.Position = goalKnob
    end
end

local function paintSwitch(key, animate)
    local sw = switches[key]
    switchVisual(sw.track, sw.knob, opts[key], animate)
end

section("AUTOMATION")
for _, t in ipairs(TOGGLES) do
    local key, name, desc = t[1], t[2], t[3]
    local row = box(settings, UDim2.new(1, 0, 0, 44), UDim2.new(), C.surface, { LayoutOrder = nextOrder() })
    corner(row, 8)
    outline(row)
    text(row, name, UDim2.new(1, -76, 0, 16), UDim2.fromOffset(12, 6), { Font = Enum.Font.GothamMedium })
    text(row, desc, UDim2.new(1, -76, 0, 14), UDim2.fromOffset(12, 23), { TextSize = 11, TextColor3 = C.dim })
    local track = new("TextButton", {
        Parent = row, Text = "", Size = UDim2.fromOffset(40, 22), Position = UDim2.new(1, -52, 0.5, -11),
        BackgroundColor3 = C.surface2, BorderSizePixel = 0, AutoButtonColor = false, Name = "Switch_" .. key,
    })
    corner(track, 11)
    local knob = box(track, UDim2.fromOffset(16, 16), UDim2.new(0, 3, 0.5, -8), C.white)
    corner(knob, 8)
    switches[key] = { track = track, knob = knob }
    paintSwitch(key, false)
    track.MouseButton1Click:Connect(function()
        opts[key] = not opts[key]
        paintSwitch(key, true)
        saveSoon()
    end)
end

local sliderUI = {}
local activeSlider = nil

local function paintSlider(s)
    local ui = sliderUI[s.key]
    local v = sliderValues[s.key]
    local frac = (v - s.min) / (s.max - s.min)
    ui.fill.Size = UDim2.new(frac, 0, 1, 0)
    ui.knob.Position = UDim2.new(frac, -7, 0.5, -7)
    ui.value.Text = string.format("%.2f - %.2f s", v, v + s.span)
end

local function setSliderFromX(s, x)
    local ui = sliderUI[s.key]
    local w = ui.track.AbsoluteSize.X
    if w <= 0 then return end
    local f = math.max(0, math.min(1, (x - ui.track.AbsolutePosition.X) / w))
    local v = math.floor((s.min + f * (s.max - s.min)) * 100 + 0.5) / 100
    applySlider(s, v)
    paintSlider(s)
    saveSoon()
end

section("HUMAN-LIKE TIMING")
for _, s in ipairs(SLIDERS) do
    local row = box(settings, UDim2.new(1, 0, 0, 54), UDim2.new(), C.surface, { LayoutOrder = nextOrder() })
    corner(row, 8)
    outline(row)
    text(row, s.label, UDim2.new(1, -130, 0, 16), UDim2.fromOffset(12, 7), { Font = Enum.Font.GothamMedium })
    local value = text(row, "", UDim2.fromOffset(110, 16), UDim2.new(1, -122, 0, 7), { TextSize = 11, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Right })
    local track = box(row, UDim2.new(1, -24, 0, 6), UDim2.fromOffset(12, 36), C.surface2, { Name = "Slider_" .. s.key })
    corner(track, 3)
    local fill = box(track, UDim2.fromScale(0, 1), UDim2.new(), C.accent)
    corner(fill, 3)
    local knob = box(track, UDim2.fromOffset(14, 14), UDim2.new(0, -7, 0.5, -7), C.white)
    corner(knob, 7)
    sliderUI[s.key] = { track = track, fill = fill, knob = knob, value = value }
    paintSlider(s)
    -- generous invisible hit area so the thin track is easy to grab
    local hit = box(row, UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 26), C.surface, { BackgroundTransparency = 1, Active = true, Name = "SliderHit_" .. s.key })
    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            activeSlider = s
            setSliderFromX(s, input.Position.X)
        end
    end)
end

section("OTHER")
do
    local row = box(settings, UDim2.new(1, 0, 0, 36), UDim2.new(), C.bg, { BackgroundTransparency = 1, LayoutOrder = nextOrder() })
    button(row, "Reset settings to defaults", UDim2.new(1, 0, 1, 0), UDim2.new(), C.surface2, function()
        local defaults = { AutoCast = true, PerfectCast = true, PerfectFirstPull = true, AutoReel = true, AutoCounter = true, AutoSkills = true, AutoLoot = true, AntiAfk = true }
        for k, v in pairs(defaults) do
            opts[k] = v
            if switches[k] then paintSwitch(k, true) end
        end
        for _, s in ipairs(SLIDERS) do
            applySlider(s, s.default)
            paintSlider(s)
        end
        saveSoon()
        logEvent("Settings reset to defaults", "info")
    end, { Name = "ResetSettings" })
    text(settings, "F6 starts / stops the bot. RightShift hides this window.", UDim2.new(1, 0, 0, 16), UDim2.new(), { TextSize = 11, TextColor3 = C.dim, LayoutOrder = nextOrder() })
end

-- RODS page ---------------------------------------------------------------------
-- Lists the shop's rods and buys them with in-game currency through the game's own PurchaseRod request (the one its shop
-- button sends, after the same owned / island / balance checks). Robux purchases are never made from here, and every
-- purchase needs a second click. Game data is read by a background thread into plain tables; only the refresh loop
-- touches the window.
local paintRodsIfNeeded
do
    local RodShop = getController("FishingRodShopController")
    local RodShopConfig = Data and try(function() return require(Data.Config.RodShopConfig) end)
    local IslandConfig = Data and try(function() return require(Data.Config.IslandConfig) end)
    local Catalog = Data and try(function() return require(Data.Catalog) end)
    local ready = RodShop ~= nil and RodShop.PurchaseRod ~= nil and RodShopConfig ~= nil and Catalog ~= nil and Catalog.Rod ~= nil and PlayerData ~= nil

    local function compact(n)
        n = tonumber(n) or 0
        local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
        for _, u in ipairs(units) do
            if n >= u[1] then return (string.format("%.1f", n / u[1]):gsub("%.0$", "")) .. u[2] end
        end
        return string.format("%.0f", n)
    end

    local entries = {}
    if ready then
        local all = try(function() return Catalog.Rod.GetAll() end)
        restoreIdentity()
        for _, rod in pairs(type(all) == "table" and all or {}) do
            local cfg = RodShopConfig[rod.id]
            if cfg ~= nil and type(cfg.price) == "number" then
                entries[#entries + 1] = { rod = rod, cfg = cfg, currency = cfg.currency or "Coin" }
            end
        end
        table.sort(entries, function(a, b) return a.cfg.price < b.cfg.price end)
    end

    local scroll = new("ScrollingFrame", {
        Parent = pages[3], Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    })
    new("UIListLayout", { Parent = scroll, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })
    new("UIPadding", { Parent = scroll, PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 14) })

    local order = 0
    local function nextOrder() order = order + 1 return order end
    text(scroll, "ROD SHOP", UDim2.new(1, 0, 0, 16), UDim2.new(), { Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.dim, LayoutOrder = nextOrder() })
    text(scroll, "Buys with in-game currency only - Robux purchases are never made from here. Click Buy, then click Confirm? within 3 seconds.",
        UDim2.new(1, 0, 0, 44), UDim2.new(), {
            TextSize = 11, TextColor3 = C.dim, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
            TextTruncate = Enum.TextTruncate.None, LayoutOrder = nextOrder(),
        })
    local balanceLabel = text(scroll, "Balance: -", UDim2.new(1, 0, 0, 16), UDim2.new(), { TextSize = 12, LayoutOrder = nextOrder() })

    local states, balances, inFlight, armedUntil = {}, {}, {}, {}
    local stamp, pollNow, paintWarned = 0, true, false

    local function isUnlocked(entry, data)
        local island = entry.cfg.islandId
        if not island then return true end
        local config = IslandConfig and IslandConfig[island]
        if config and config.defaultUnlocked then return true end
        return type(data.UnlockedIslands) == "table" and data.UnlockedIslands[island] == true
    end

    local function poll()
        local data = try(function() return PlayerData:Fetch() end)
        restoreIdentity()
        if type(data) ~= "table" then return end
        local owned = type(data.Rods) == "table" and data.Rods or {}
        for _, entry in ipairs(entries) do
            local id = entry.rod.id
            states[id] = { owned = owned[id] ~= nil, unlocked = isUnlocked(entry, data) }
            balances[entry.currency] = type(data[entry.currency]) == "number" and data[entry.currency] or 0
        end
        stamp = stamp + 1
    end

    local function purchase(entry)
        local id, name = entry.rod.id, tostring(entry.rod.name or entry.rod.id)
        inFlight[id] = true
        local data = try(function() return PlayerData:Fetch() end)
        restoreIdentity()
        local reason
        if type(data) ~= "table" then
            reason = "player data isn't loaded yet"
        elseif type(data.Rods) == "table" and data.Rods[id] ~= nil then
            reason = "you already own it"
        elseif not isUnlocked(entry, data) then
            reason = "its island isn't unlocked yet"
        elseif type(data[entry.currency]) ~= "number" or data[entry.currency] < entry.cfg.price then
            reason = "not enough " .. entry.currency
        end
        if reason then
            inFlight[id] = nil
            logEvent("Can't buy " .. name .. ": " .. reason, "warn")
            return
        end
        -- the same request the shop button sends; it answers true/false
        local ok, result = pcall(RodShop.PurchaseRod.Fire, RodShop.PurchaseRod, id)
        restoreIdentity()
        inFlight[id] = nil
        if ok and result == true then
            logEvent(string.format("Bought %s for %s %s", name, compact(entry.cfg.price), entry.currency), "good")
        else
            logEvent("Purchase of " .. name .. " was rejected" .. (ok and "" or (": " .. tostring(result))), "bad")
        end
        pollNow = true
    end

    if not ready then
        text(scroll, "The game's rod shop data wasn't found, so rods can't be listed here.", UDim2.new(1, 0, 0, 30), UDim2.new(), {
            TextSize = 11, TextColor3 = C.amber, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
            TextTruncate = Enum.TextTruncate.None, LayoutOrder = nextOrder(),
        })
    end

    for _, entry in ipairs(entries) do
        local row = box(scroll, UDim2.new(1, 0, 0, 50), UDim2.new(), C.surface, { LayoutOrder = nextOrder(), Name = "RodRow_" .. tostring(entry.rod.id) })
        corner(row, 8)
        outline(row)
        text(row, tostring(entry.rod.name or entry.rod.id), UDim2.new(1, -92, 0, 16), UDim2.fromOffset(12, 7), { Font = Enum.Font.GothamMedium })
        local desc = text(row, "", UDim2.new(1, -92, 0, 14), UDim2.fromOffset(12, 27), { TextSize = 11, TextColor3 = C.dim })
        local buy = button(row, "Buy", UDim2.fromOffset(68, 26), UDim2.new(1, -80, 0.5, -13), C.surface2, nil, { Name = "RodBuy_" .. tostring(entry.rod.id) })
        entry.ui = { desc = desc, buy = buy }
        buy.MouseButton1Click:Connect(function()
            local id = entry.rod.id
            if inFlight[id] then return end
            local st = states[id]
            if st and st.owned then return end
            local affordable = st ~= nil and st.unlocked and (balances[entry.currency] or 0) >= entry.cfg.price
            local now = os.clock()
            if not affordable or (armedUntil[id] or 0) > now then
                armedUntil[id] = nil
                task.spawn(purchase, entry)   -- not affordable: this only reports why; affordable + confirmed: buys
            else
                armedUntil[id] = now + 3
            end
        end)
    end

    local function paint()
        local now = os.clock()
        local parts = {}
        for currency, amount in pairs(balances) do parts[#parts + 1] = currency .. " " .. compact(amount) end
        table.sort(parts)
        balanceLabel.Text = #parts > 0 and ("Balance:  " .. table.concat(parts, "    ")) or "Balance: -"
        for _, entry in ipairs(entries) do
            local id, price = entry.rod.id, entry.cfg.price
            local st = states[id]
            local balance = balances[entry.currency] or 0
            local label, bg, fg = "Buy", C.surface2, C.dim
            local desc = string.format("%s %s", compact(price), entry.currency)
            if inFlight[id] then
                label = "..."
            elseif st and st.owned then
                label, desc = "Owned", "Already owned"
            elseif st and not st.unlocked then
                label, fg, desc = "Locked", C.amber, "Unlock " .. tostring(entry.cfg.islandId) .. " first"
            elseif st and balance < price then
                desc = string.format("%s %s  |  need %s more", compact(price), entry.currency, compact(price - balance))
            elseif st then
                if (armedUntil[id] or 0) > now then
                    label, bg, fg = "Confirm?", C.amber, C.white
                else
                    label, bg, fg = "Buy", C.accent, C.white
                end
            end
            entry.ui.desc.Text = desc
            entry.ui.buy.Text, entry.ui.buy.BackgroundColor3, entry.ui.buy.TextColor3 = label, bg, fg
        end
    end

    -- the one thing the refresh loop needs from this tab
    function paintRodsIfNeeded()
        if not ready then return end
        local ok, err = pcall(paint)
        if not ok and not paintWarned then
            paintWarned = true
            logEvent("Rods tab paint failed: " .. tostring(err), "bad")
        end
    end

    if ready then
        task.spawn(function()
            local nextPoll = 0
            while not destroyed do
                local now = os.clock()
                if pollNow or now >= nextPoll then
                    pollNow = false
                    nextPoll = now + 1
                    poll()
                end
                task.wait(0.25)
            end
        end)
    end
end

-- LOG page ----------------------------------------------------------------------
local addLogLine   -- the rest of the Log tab is scoped in a block (Luau allows at most 200 top-level locals)
do
    local logPage = pages[4]
    text(logPage, "Recent events", UDim2.fromOffset(160, 22), UDim2.fromOffset(14, 8), { Font = Enum.Font.GothamMedium })
    local logList = new("ScrollingFrame", {
        Parent = logPage, Position = UDim2.fromOffset(12, 36), Size = UDim2.new(1, -24, 1, -48), BackgroundColor3 = C.surface, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.stroke, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    })
    corner(logList, 8)
    outline(logList)
    new("UIListLayout", { Parent = logList, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder })
    new("UIPadding", { Parent = logList, PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) })

    local logLines, logCounter = {}, 0
    local function clock(seconds)
        seconds = math.floor(seconds)
        return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
    end

    function addLogLine(entry)
        logCounter = logCounter + 1
        local line = text(logList, string.format("[%s] %s", clock(entry.t), entry.text), UDim2.new(1, 0, 0, 15), UDim2.new(), {
            TextSize = 11, TextColor3 = LOG_COLORS[entry.kind] or C.dim, LayoutOrder = logCounter, Name = "LogLine",
        })
        logLines[#logLines + 1] = line
        if #logLines > 80 then
            table.remove(logLines, 1):Destroy()
        end
        task.defer(function()
            if not destroyed then logList.CanvasPosition = Vector2.new(0, 100000) end
        end)
    end

    button(logPage, "Clear", UDim2.fromOffset(60, 22), UDim2.new(1, -72, 0, 8), C.surface2, function()
        for _, l in ipairs(logLines) do l:Destroy() end
        table.clear(logLines)
        table.clear(logBuffer)
        table.clear(logQueue)
    end, { TextSize = 11, TextColor3 = C.dim, Name = "ClearLog" })

    -- everything logged so far, then the refresh loop adds new entries from logQueue
    for _, entry in ipairs(logBuffer) do addLogLine(entry) end
    table.clear(logQueue)
end

-- live status ----------------------------------------------------------------------
local function describe()
    local now = os.clock()
    if not running then return "Stopped", "Press Start or F6 to begin", 0 end
    local s = Fishing:GetState()
    if s == State.Idling then
        if castStage then return "Casting", "Pressing the cast button", 1 end
        if not opts.AutoCast then return "Idle", "Auto Cast is off", 1 end
        return "Ready", string.format("Next cast in %.1fs", math.max(0, nextCastAt - now)), 1
    elseif s == State.Holding or s == State.Throwing then
        if castStage == "luck" then return "Casting", string.format("Timing the luck bar (aiming for %.2f)", luckTarget), 1 end
        return "Casting", "Holding the cast", 1
    elseif s == State.Waiting then
        return "Waiting for a bite", "Bait is in the water", 2
    elseif s == State.FirstPull then
        return "First pull", "Timing the pull bar", 3
    elseif s == State.Reeling then
        local name, hp, maxHp = Fishing:GetFishInfo()
        local pct = (type(hp) == "number" and type(maxHp) == "number" and maxHp > 0) and math.max(0, math.min(100, hp / maxHp * 100)) or 0
        return "Reeling", string.format("%s  |  HP %.0f%%", (type(name) == "string" and name ~= "") and name or "fish", pct), 4, pct / 100
    elseif s == State.Caught then
        return "Caught!", lootTries > 0 and string.format("Closing the popup (try %d)", lootTries) or "Waiting for the loot popup", 5
    elseif s == State.Escaped then
        return "Escaped", "The fish got away", 0
    end
    return tostring(stateName[s] or s), "", 0
end

local lastStage, lastDot = -1, nil
local lastRunning = nil

local function refresh()
    restoreIdentity()   -- describe() below calls into game code; this thread must keep our identity to touch the window
    local now = os.clock()

    -- window parts that depend on other threads: each in its own pcall so one failure can't freeze the status display
    pcall(function()
        while #logQueue > 0 do addLogLine(table.remove(logQueue, 1)) end
    end)
    paintRodsIfNeeded()
    -- tell the loot code where this window is, so its clicks never land on it (plain numbers, read from other threads)
    pcall(function()
        if main.Visible then
            local p, s = main.AbsolutePosition, main.AbsoluteSize
            windowRect.x0, windowRect.y0, windowRect.x1, windowRect.y1 = p.X, p.Y, p.X + s.X, p.Y + s.Y
        else
            windowRect.x0, windowRect.y0, windowRect.x1, windowRect.y1 = 0, 0, 0, 0
        end
    end)

    local title, detail, stage, hp = describe()
    restoreIdentity()
    phaseLabel.Text = title
    detailLabel.Text = (now < noteUntil and running and note ~= "") and note or detail

    if stage ~= lastStage then
        lastStage = stage
        for i, p in ipairs(pills) do
            local active = (i == stage)
            tween(p.frame, { BackgroundColor3 = active and C.accent or C.surface2 }, 0.15)
            p.label.TextColor3 = active and C.white or C.dim
        end
    end

    hpTrack.Visible = hp ~= nil
    if hp then
        hpFill.Size = UDim2.new(hp, 0, 1, 0)
        hpFill.BackgroundColor3 = (hp <= FishingConfig.Fight.FinisherPct + 0.04) and C.amber or C.green
    end

    if running ~= lastRunning then
        lastRunning = running
        startButton.Text = running and "Stop  (F6)" or "Start  (F6)"
        tween(startButton, { BackgroundColor3 = running and C.red or C.green }, 0.15)
    end

    local dot = (not running) and C.dim or (now < warnUntil and C.amber or C.green)
    if dot ~= lastDot then
        lastDot = dot
        tween(statusDot, { BackgroundColor3 = dot }, 0.2)
    end
    headerStatus.Text = running and (stats.catches > 0 and (stats.catches .. " caught") or "Running") or "Stopped"

    tiles[1].value.Text = tostring(stats.catches)
    tiles[2].value.Text = tostring(stats.escapes)
    tiles[3].value.Text = tostring(stats.casts)
    tiles[4].value.Text = stats.casts > 0 and string.format("%.0f%%", stats.perfectCasts / stats.casts * 100) or "-"
    tiles[5].value.Text = stats.counters > 0 and string.format("%d/%d", stats.counterHits, stats.counters) or "-"
    tiles[6].value.Text = tostring(stats.skills)

    local secs = runSeconds()
    local perHour = secs >= 60 and string.format("%.0f fish/h", stats.catches / secs * 3600) or "-"
    footerLabel.Text = string.format("Session %s  |  %s%s", string.format("%d:%02d:%02d", math.floor(secs / 3600), math.floor(secs / 60) % 60, math.floor(secs) % 60),
        perHour, lastCatch ~= "" and ("  |  " .. lastCatch) or "")
end

local function destroy()
    if destroyed then return end
    destroyed = true
    setRunning(false)
    saveNow()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if gui then gui:Destroy() end
    if env.FishingAutoPlay and env.FishingAutoPlay.Destroy == destroy then env.FishingAutoPlay = nil end
end
env.FishingAutoPlay = { Destroy = destroy, SetRunning = setRunning, Options = opts, Values = sliderValues }

local minimized = false
minButton.MouseButton1Click:Connect(function()
    minimized = not minimized
    tabBar.Visible = not minimized
    tabDivider.Visible = not minimized
    tabIndicator.Visible = not minimized
    pagesHolder.Visible = not minimized
    tween(main, { Size = minimized and UDim2.fromOffset(WIN_W, HEADER_H) or UDim2.fromOffset(WIN_W, WIN_H) }, 0.18)
end)
closeButton.MouseButton1Click:Connect(destroy)

do
    local dragging, dragStart, startPos
    conns[#conns + 1] = dragArea.InputBegan:Connect(function(input)
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
    conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
        local moving = input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
        if not moving then return end
        if dragging then
            local d = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        elseif activeSlider then
            setSliderFromX(activeSlider, input.Position.X)
        end
    end)
    conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            activeSlider = nil
        end
    end)
    conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == CONFIG.ToggleKey then
            main.Visible = not main.Visible
        elseif input.KeyCode == CONFIG.StartKey then
            setRunning(not running)
        end
    end)
end

showTab(1)
task.spawn(function()
    while not destroyed do
        pcall(refresh)
        task.wait(0.2)
    end
end)
