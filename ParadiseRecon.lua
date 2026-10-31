--[[
    Paradise Recon
    Records how combat farming works in Paradise so an auto-farm GUI can be written against real names instead of guesses.
    Nothing is sent to the server and no gameplay is changed - it only listens and writes a text file.

    WHAT IT RECORDS
      * World          your attributes / leaderstats, CollectionService tags, proximity prompts, click detectors,
                       workspace top level, the shape of the Paradise_Client module, every script's path
      * Remotes        every RemoteEvent / RemoteFunction in ReplicatedStorage (farm-looking ones listed first)
      * Traffic        every client->server call (FireServer / InvokeServer) and server->client event, with arguments
      * GUI snapshots  the text / buttons currently visible on screen, each time you press F8
      * Quest data     Paradise_Client.Data.Quest / SideQuests (your current quest progress)
      * Scripts        decompiled source of the quest scripts (Quest UI, Quest_Utils, quest giver / prompt scripts)
                       and of any other script that mentions "quest"

    HOW TO USE
      1. Execute this and wait until the label says "ready" (the script scan takes a minute or two).
      2. Then, by hand and in this order:
           a. walk to the Quest Giver and talk to him (press F8 while the quest window is open)
           b. accept the quest
           c. kill a few of the quest's enemies (press F8 once the quest tracker shows progress)
           d. finish the quest and claim / turn in the reward (press F8 when the claim button is showing,
              and again right after claiming)
           e. if the next quest starts on its own, or needs another visit to the giver, do that too
         If finishing the first quest takes too long, one accept plus a few kills is enough - but a full
         claim is what I need most.
      3. Press F9 to save, F10 to stop. The file is ParadiseRecon.txt in your executor's workspace folder.
         Paste its contents (or copy it next to these scripts) and the farming GUI can be built from it.

    Needs an executor with hookmetamethod / decompile / writefile. Anything missing is skipped and noted in the file.
]]

local CONFIG = {
    OutFile = "ParadiseRecon.txt",
    SnapshotKey = Enum.KeyCode.F8,
    SaveKey = Enum.KeyCode.F9,
    StopKey = Enum.KeyCode.F10,
    Keywords = { "enem", "attack", "click", "auto", "damage", "kill", "summon", "shadow", "star", "raid", "tower", "trial",
        "teleport", "travel", "portal", "quest", "drop", "coin", "paradise" },
    -- Scripts under these paths are always kept; any other script is kept only if its source mentions a TopicWord
    KeepPaths = { "Paradise_Client.Scripts.UserInterface.Scripts.Quest", "Shared.Quest_Utils",
        "Paradise_Client.Scripts.General.Scripts.QuestGiverVisuals", "Paradise_Client.Scripts.General.Scripts.Prompt",
        "Paradise_Client.Scripts.General.Scripts.Proximity_Prompt", "Paradise_Client.Scripts.General.Scripts.Interact",
        "Paradise_Client.Scripts.UserInterface.Scripts.GamemodeNotify" },
    TopicWords = { "quest" },
    SkipPaths = { "WindController", "CmdrClient" },
    MaxListedScripts = 400,
    MaxPrompts = 150,
    PerRemoteLogCap = 25,      -- full logging per call type, then every 50th call (some are spammed every frame)
    MaxDecompileScan = 250,    -- scripts decompiled at most
    MaxKeptScripts = 40,       -- scripts written to the file at most
    MaxScriptChars = 40000,    -- per script
    ScanBudgetSec = 90,
    MaxSnapshotLines = 300,
}

local env = (getgenv and getgenv()) or _G
if env.ParadiseRecon and env.ParadiseRecon.Destroy then
    pcall(env.ParadiseRecon.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local t0 = os.clock()
local lines = {}
local dirty = false
local active = true
local conns = {}
local status = "starting"

local function raw(text)
    lines[#lines + 1] = text
    dirty = true
end

local function log(text)
    raw(string.format("[%8.2f] %s", os.clock() - t0, text))
end

local function fullName(inst)
    local parts = {}
    local cur = inst
    local guard = 0
    while cur and cur ~= game and guard < 60 do
        parts[#parts + 1] = cur.Name
        cur = cur.Parent
        guard = guard + 1
    end
    local n = #parts
    for i = 1, math.floor(n / 2) do
        parts[i], parts[n - i + 1] = parts[n - i + 1], parts[i]
    end
    return table.concat(parts, ".")
end

local function matchesKeyword(name)
    local l = name:lower()
    for _, kw in ipairs(CONFIG.Keywords) do
        if l:find(kw, 1, true) then return true end
    end
    return false
end

local function ser(v, depth)
    local t = typeof(v)
    if t == "string" then
        return string.format("%q", #v > 200 and (v:sub(1, 200) .. "...") or v)
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "Instance" then
        return "<" .. v.ClassName .. " " .. fullName(v) .. ">"
    elseif t == "table" then
        if depth >= 3 then return "{...}" end
        local parts, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 20 then parts[#parts + 1] = "..."; break end
            parts[#parts + 1] = "[" .. ser(k, depth + 1) .. "]=" .. ser(x, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "<" .. t .. ":" .. tostring(v) .. ">"
end

local function save()
    if not writefile then
        status = "no writefile - cannot save"
        return false
    end
    local ok = pcall(writefile, CONFIG.OutFile, table.concat(lines, "\n"))
    dirty = not ok
    status = ok and ("saved " .. CONFIG.OutFile) or "save failed"
    return ok
end

----------------------------------------------------------------------
-- Remote traffic
----------------------------------------------------------------------
local counts = {}
local remoteCalls = 0

local function noteRemote(dir, remote, args, n)
    -- Bridge carries everything, so count per (group, category, name) rather than per remote
    local sig = ""
    for i = 1, math.min(n, 3) do
        if type(args[i]) == "string" then sig = sig .. "/" .. args[i] end
    end
    local key = dir .. " " .. fullName(remote) .. sig
    local c = (counts[key] or 0) + 1
    counts[key] = c
    remoteCalls = remoteCalls + 1
    if c <= CONFIG.PerRemoteLogCap or c % 50 == 0 then
        local parts = {}
        for i = 1, n do parts[i] = ser(args[i], 0) end
        log(string.format("%s %s(%s)%s", dir, fullName(remote), table.concat(parts, ", "), c > CONFIG.PerRemoteLogCap and ("  [#" .. c .. "]") or ""))
    end
end

local hookState = "unavailable (no hookmetamethod/getnamecallmethod) - client->server calls will NOT be recorded"
if hookmetamethod and getnamecallmethod then
    local old
    local function handler(self, ...)
        local method = getnamecallmethod()
        if active and (method == "FireServer" or method == "InvokeServer") and not (checkcaller and checkcaller()) then
            pcall(noteRemote, "C->S " .. method, self, { ... }, select("#", ...))
            if setnamecallmethod then setnamecallmethod(method) end
        end
        return old(self, ...)
    end
    local ok, res = pcall(hookmetamethod, game, "__namecall", newcclosure and newcclosure(handler) or handler)
    if ok then
        old = res
        hookState = "ok"
    else
        hookState = "failed: " .. tostring(res)
    end
end

local watched = {}
local function watchRemote(r)
    if watched[r] then return end
    if r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent") then
        watched[r] = true
        local ok, c = pcall(function()
            return r.OnClientEvent:Connect(function(...)
                if active then pcall(noteRemote, "S->C", r, { ... }, select("#", ...)) end
            end)
        end)
        if ok then conns[#conns + 1] = c end
    end
end

----------------------------------------------------------------------
-- Inventory, GUI snapshots, script dump
----------------------------------------------------------------------
local function inventory()
    raw("=== REMOTES (ReplicatedStorage) ===")
    local hits, others = {}, {}
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then
            local line = d.ClassName .. "  " .. fullName(d)
            if matchesKeyword(fullName(d)) then
                hits[#hits + 1] = line
            else
                others[#others + 1] = line
            end
        end
    end
    table.sort(hits)
    table.sort(others)
    raw("-- farm-looking (" .. #hits .. ") --")
    for _, l in ipairs(hits) do raw(l) end
    raw("-- everything else (" .. #others .. ", first 300) --")
    for i = 1, math.min(#others, 300) do raw(others[i]) end
    raw("")
end

local function isVisible(g)
    local cur = g
    while cur and cur ~= PlayerGui do
        if cur:IsA("GuiObject") then
            if not cur.Visible then return false end
        elseif cur:IsA("ScreenGui") then
            if not cur.Enabled then return false end
        end
        cur = cur.Parent
    end
    return true
end

local snapshotCount = 0
local function snapshot()
    snapshotCount = snapshotCount + 1
    raw("")
    raw(string.format("=== GUI SNAPSHOT #%d @ %.2fs (visible text / buttons / farm-named elements) ===", snapshotCount, os.clock() - t0))
    local count = 0
    for _, g in ipairs(PlayerGui:GetDescendants()) do
        if g:IsA("GuiObject") and g.AbsoluteSize.X > 0 and g.AbsoluteSize.Y > 0 and isVisible(g) then
            local isText = g:IsA("TextLabel") or g:IsA("TextButton") or g:IsA("TextBox")
            local text = isText and g.Text or ""
            local isImage = g:IsA("ImageLabel") or g:IsA("ImageButton")
            if (isText and text ~= "") or g:IsA("TextButton") or g:IsA("ImageButton") or matchesKeyword(g.Name) then
                count = count + 1
                if count > CONFIG.MaxSnapshotLines then
                    raw("  ... truncated at " .. CONFIG.MaxSnapshotLines .. " lines")
                    break
                end
                local extra = ""
                if isText and text ~= "" then extra = "  text=" .. string.format("%q", text:sub(1, 80)) end
                if isImage then extra = extra .. "  image=" .. tostring(g.Image):sub(1, 60) end
                local rel = (fullName(g):gsub("^Players%.[^.]+%.PlayerGui%.", ""))
                raw(string.format("  %s  <%s>  pos=(%.0f,%.0f) size=(%.0f,%.0f)%s", rel, g.ClassName,
                    g.AbsolutePosition.X, g.AbsolutePosition.Y, g.AbsoluteSize.X, g.AbsoluteSize.Y, extra))
            end
        end
    end
    status = "snapshot #" .. snapshotCount .. " taken"
end

local function mentionsTopic(src)
    local lowered = src:lower()
    for _, word in ipairs(CONFIG.TopicWords) do
        if lowered:find(word, 1, true) then return true end
    end
    return false
end

local function pathHasAny(path, list)
    for _, part in ipairs(list) do
        if path:find(part, 1, true) then return true end
    end
    return false
end

local function safeValue(inst)
    local ok, value = pcall(function() return inst.Value end)
    return ok and tostring(value) or "?"
end

-- key : type (= value) listing of a table, nested to `depth` more levels
local function shape(value, depth, indent)
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for i, k in ipairs(keys) do
        if i > 80 then raw(indent .. "...") break end
        local v = value[k]
        local t = typeof(v)
        local desc = t
        if t == "string" or t == "number" or t == "boolean" then desc = t .. " = " .. ser(v, 0) end
        raw(string.format("%s%s : %s", indent, tostring(k), desc))
        if t == "table" and depth > 0 then shape(v, depth - 1, indent .. "  ") end
    end
end

local function worldInventory()
    raw("=== PLAYER ===")
    for k, v in pairs(LocalPlayer:GetAttributes()) do
        raw(string.format("  attribute %s = %s", k, ser(v, 0)))
    end
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    if stats then
        for _, v in ipairs(stats:GetChildren()) do
            raw(string.format("  leaderstats.%s = %s", v.Name, safeValue(v)))
        end
    end
    raw("")

    raw("=== TAGS (CollectionService; * = farm-looking) ===")
    local tags = CollectionService:GetAllTags()
    table.sort(tags)
    for _, tag in ipairs(tags) do
        raw(string.format("  %s%s  x%d", matchesKeyword(tag) and "* " or "  ", tag, #CollectionService:GetTagged(tag)))
    end
    raw("")

    raw("=== PROXIMITY PROMPTS / CLICK DETECTORS (workspace; farm-looking first) ===")
    local hits, others = {}, {}
    for _, d in ipairs(workspace:GetDescendants()) do
        local line
        if d:IsA("ProximityPrompt") then
            line = string.format("Prompt  %s  action=%q object=%q hold=%.1f dist=%.0f enabled=%s",
                fullName(d), d.ActionText, d.ObjectText, d.HoldDuration, d.MaxActivationDistance, tostring(d.Enabled))
        elseif d:IsA("ClickDetector") then
            line = string.format("Click   %s  dist=%.0f", fullName(d), d.MaxActivationDistance)
        end
        if line then
            local list = matchesKeyword(line) and hits or others
            list[#list + 1] = line
        end
    end
    raw("-- farm-looking (" .. #hits .. ", first " .. CONFIG.MaxPrompts .. ") --")
    for i = 1, math.min(#hits, CONFIG.MaxPrompts) do raw(hits[i]) end
    raw("-- everything else (" .. #others .. ", first 60) --")
    for i = 1, math.min(#others, 60) do raw(others[i]) end
    raw("")

    raw("=== WORKSPACE (top level) ===")
    for i, child in ipairs(workspace:GetChildren()) do
        if i > 120 then raw("  ...") break end
        raw(string.format("  %s <%s> (%d children)", child.Name, child.ClassName, #child:GetChildren()))
    end
    raw("")

    raw("=== PARADISE_CLIENT MODULE (shape, 3 levels) ===")
    local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local module = scripts and scripts:FindFirstChild("Paradise_Client")
    if not module then
        raw("  PlayerScripts.Paradise_Client not found")
    else
        local startIdentity = (getthreadidentity or getidentity or function() end)()
        local ok, result = pcall(require, module)
        local setIdentity = setthreadidentity or setidentity
        if setIdentity and startIdentity then pcall(setIdentity, startIdentity) end
        if not ok then
            raw("  require failed: " .. tostring(result))
        elseif type(result) ~= "table" then
            raw("  returned " .. typeof(result))
        else
            local shaped, err = pcall(shape, result, 2, "  ")
            if not shaped then raw("  shape failed: " .. tostring(err)) end
            if type(result.Scripts) == "table" then
                raw("")
                raw("=== PARADISE_CLIENT.Scripts (shape, 5 levels) ===")
                local ok2, err2 = pcall(shape, result.Scripts, 4, "  ")
                if not ok2 then raw("  shape failed: " .. tostring(err2)) end
            end
            if type(result.Data) == "table" then
                raw("")
                raw("=== PARADISE_CLIENT.Data.Quest / SideQuests (shape, 5 levels) ===")
                for _, key in ipairs({ "Quest", "SideQuests" }) do
                    raw("  " .. key .. ":")
                    if type(result.Data[key]) == "table" then
                        local ok3, err3 = pcall(shape, result.Data[key], 4, "    ")
                        if not ok3 then raw("    shape failed: " .. tostring(err3)) end
                    end
                end
            end
        end
    end
    raw("")

    raw("=== SCRIPT PATHS (LocalScript / ModuleScript) ===")
    local count = 0
    local roots = { ReplicatedStorage, game:GetService("ReplicatedFirst"), PlayerGui }
    if scripts then table.insert(roots, scripts) end
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("LocalScript") or d:IsA("ModuleScript") then
                count = count + 1
                if count <= CONFIG.MaxListedScripts then
                    raw(string.format("  %s %s", matchesKeyword(fullName(d)) and "*" or " ", fullName(d)))
                end
            end
        end
    end
    if count > CONFIG.MaxListedScripts then raw("  ... " .. (count - CONFIG.MaxListedScripts) .. " more") end
    raw("")
end

local function scanScripts()
    if not decompile then
        raw("=== SCRIPTS: decompile() unavailable - paste the farming scripts manually ===")
        return
    end
    local roots = {}
    local function addRoot(r) if r then roots[#roots + 1] = r end end
    addRoot(ReplicatedStorage)
    addRoot(LocalPlayer:FindFirstChild("PlayerScripts"))
    addRoot(PlayerGui)
    addRoot(game:GetService("ReplicatedFirst"))

    local priority, rest = {}, {}
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("LocalScript") or d:IsA("ModuleScript") then
                local path = fullName(d)
                if pathHasAny(path, CONFIG.SkipPaths) then
                    -- noise (wind effects, admin console)
                elseif pathHasAny(path, CONFIG.KeepPaths) then
                    priority[#priority + 1] = d
                else
                    rest[#rest + 1] = d
                end
            end
        end
    end
    local ordered = {}
    for _, s in ipairs(priority) do ordered[#ordered + 1] = s end
    for _, s in ipairs(rest) do ordered[#ordered + 1] = s end

    raw(string.format("=== SCRIPTS: %d candidates (%d under Paradise_Client.Scripts game folders), keeping those and any that mention auto flags / FireServer ===", #ordered, #priority))
    local kept, started = 0, os.clock()
    for i, s in ipairs(ordered) do
        if not active or i > CONFIG.MaxDecompileScan or kept >= CONFIG.MaxKeptScripts or os.clock() - started > CONFIG.ScanBudgetSec then
            break
        end
        status = string.format("scanning scripts %d/%d (kept %d)", i, math.min(#ordered, CONFIG.MaxDecompileScan), kept)
        local ok, src = pcall(decompile, s)
        if ok and type(src) == "string" and (pathHasAny(fullName(s), CONFIG.KeepPaths) or mentionsTopic(src)) then
            kept = kept + 1
            raw("")
            raw(string.format("----- %s (%s, %d chars) -----", fullName(s), s.ClassName, #src))
            raw(#src > CONFIG.MaxScriptChars and (src:sub(1, CONFIG.MaxScriptChars) .. "\n-- [truncated]") or src)
        end
        if i % 5 == 0 then task.wait() end
    end
    raw(string.format("=== SCRIPT SCAN DONE: kept %d ===", kept))
    raw("")
end

----------------------------------------------------------------------
-- Tiny status window + hotkeys
----------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ParadiseRecon"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
local parentOk = pcall(function()
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not parentOk or not gui.Parent then
    gui.Parent = PlayerGui
end

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(330, 58)
label.Position = UDim2.new(0, 12, 1, -70)
label.BackgroundColor3 = Color3.fromRGB(24, 25, 32)
label.BackgroundTransparency = 0.15
label.TextColor3 = Color3.fromRGB(230, 232, 240)
label.Font = Enum.Font.Gotham
label.TextSize = 12
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.BorderSizePixel = 0
label.Parent = gui
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingTop = UDim.new(0, 6)
pad.Parent = label

local function destroy()
    if not active then return end
    active = false
    save()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if gui then gui:Destroy() end
    if env.ParadiseRecon and env.ParadiseRecon.Destroy == destroy then env.ParadiseRecon = nil end
end
env.ParadiseRecon = { Destroy = destroy }

conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, processed)
    if processed or not active then return end
    if input.KeyCode == CONFIG.SnapshotKey then
        snapshot()
    elseif input.KeyCode == CONFIG.SaveKey then
        save()
    elseif input.KeyCode == CONFIG.StopKey then
        destroy()
    end
end)

----------------------------------------------------------------------
-- Go
----------------------------------------------------------------------
raw("Paradise Recon - " .. os.date("%Y-%m-%d %H:%M:%S"))
raw("PlaceId " .. tostring(game.PlaceId) .. "   GameId " .. tostring(game.GameId))
raw("hookmetamethod: " .. hookState)
raw("decompile: " .. (decompile and "ok" or "unavailable") .. "   writefile: " .. (writefile and "ok" or "unavailable"))
raw("")

for _, d in ipairs(ReplicatedStorage:GetDescendants()) do watchRemote(d) end
conns[#conns + 1] = ReplicatedStorage.DescendantAdded:Connect(watchRemote)
inventory()
local worldOk, worldErr = pcall(worldInventory)
if not worldOk then raw("=== WORLD INVENTORY FAILED: " .. tostring(worldErr) .. " ===") end
raw("=== TRAFFIC / SNAPSHOTS (seconds since start) ===")

task.spawn(function()
    scanScripts()
    status = "ready - farm by hand"
    save()
end)

task.spawn(function()
    local lastSave = os.clock()
    while active do
        label.Text = string.format("Paradise Recon  |  F8 snapshot   F9 save   F10 stop\n%s\nremote calls: %d   snapshots: %d", status, remoteCalls, snapshotCount)
        if dirty and os.clock() - lastSave > 15 then
            save()
            lastSave = os.clock()
        end
        task.wait(0.5)
    end
end)
