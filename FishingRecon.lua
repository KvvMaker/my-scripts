--[[
    Fishing Recon
    Records what the fishing game does so an auto-player can be written against real names instead of guesses.
    Nothing is sent to the server and no gameplay is changed - it only listens and writes a text file.

    WHAT IT RECORDS
      * Remotes        every RemoteEvent / RemoteFunction in ReplicatedStorage (fishing-looking ones listed first)
      * Traffic        every client->server call (FireServer / InvokeServer) and server->client event, with arguments
      * GUI snapshots  the text / buttons currently visible on screen, each time you press F8
      * Scripts        decompiled source of every script that mentions "Fishing" (the fishing controller)

    HOW TO USE
      1. Execute this, then fish ONE full catch by hand (cast, wait, pull, reel, counters, skills, result).
      2. Press F8 at each stage so I can see which GUI belongs to which phase:
           idle -> luck bar showing -> bait in water -> bite warning -> first pull bar
           -> reeling -> a counter prompt (A / D / W) showing -> catch result screen
      3. Press F9 to save, F10 to stop. The file is FishingRecon.txt in your executor's workspace folder.
         Copy it next to these scripts (or paste its contents) and the auto-player can be built from it.

    Needs an executor with hookmetamethod / decompile / writefile. Anything missing is skipped and noted in the file.
]]

local CONFIG = {
    OutFile = "FishingRecon.txt",
    SnapshotKey = Enum.KeyCode.F8,
    SaveKey = Enum.KeyCode.F9,
    StopKey = Enum.KeyCode.F10,
    Keywords = { "fish", "cast", "reel", "rod", "bait", "qte", "luck", "pull", "tension", "counter", "boss", "skill", "catch", "loot" },
    PerRemoteLogCap = 60,      -- full logging per remote, then every 50th call (some remotes are spammed every frame)
    MaxDecompileScan = 250,    -- scripts decompiled at most
    MaxKeptScripts = 20,       -- scripts written to the file at most
    MaxScriptChars = 60000,    -- per script
    ScanBudgetSec = 90,
    MaxSnapshotLines = 300,
}

local env = (getgenv and getgenv()) or _G
if env.FishingRecon and env.FishingRecon.Destroy then
    pcall(env.FishingRecon.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

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
    local key = dir .. " " .. fullName(remote)
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
    raw("-- fishing-looking (" .. #hits .. ") --")
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
    raw(string.format("=== GUI SNAPSHOT #%d @ %.2fs (visible text / buttons / fishing-named elements) ===", snapshotCount, os.clock() - t0))
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

local function scanScripts()
    if not decompile then
        raw("=== SCRIPTS: decompile() unavailable - paste the fishing controller script manually ===")
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
                if matchesKeyword(fullName(d)) then
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

    raw(string.format("=== SCRIPTS: %d candidates (%d by name), keeping those that mention \"Fishing\" ===", #ordered, #priority))
    local kept, started = 0, os.clock()
    for i, s in ipairs(ordered) do
        if not active or i > CONFIG.MaxDecompileScan or kept >= CONFIG.MaxKeptScripts or os.clock() - started > CONFIG.ScanBudgetSec then
            break
        end
        status = string.format("scanning scripts %d/%d (kept %d)", i, math.min(#ordered, CONFIG.MaxDecompileScan), kept)
        local ok, src = pcall(decompile, s)
        if ok and type(src) == "string" and src:find("Fishing", 1, true) then
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
gui.Name = "FishingRecon"
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
    if env.FishingRecon and env.FishingRecon.Destroy == destroy then env.FishingRecon = nil end
end
env.FishingRecon = { Destroy = destroy }

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
raw("Fishing Recon - " .. os.date("%Y-%m-%d %H:%M:%S"))
raw("PlaceId " .. tostring(game.PlaceId) .. "   GameId " .. tostring(game.GameId))
raw("hookmetamethod: " .. hookState)
raw("decompile: " .. (decompile and "ok" or "unavailable") .. "   writefile: " .. (writefile and "ok" or "unavailable"))
raw("")

for _, d in ipairs(ReplicatedStorage:GetDescendants()) do watchRemote(d) end
conns[#conns + 1] = ReplicatedStorage.DescendantAdded:Connect(watchRemote)
inventory()
raw("=== TRAFFIC / SNAPSHOTS (seconds since start) ===")

task.spawn(function()
    scanScripts()
    status = "ready - fish by hand"
    save()
end)

task.spawn(function()
    local lastSave = os.clock()
    while active do
        label.Text = string.format("Fishing Recon  |  F8 snapshot   F9 save   F10 stop\n%s\nremote calls: %d   snapshots: %d", status, remoteCalls, snapshotCount)
        if dirty and os.clock() - lastSave > 15 then
            save()
            lastSave = os.clock()
        end
        task.wait(0.5)
    end
end)
