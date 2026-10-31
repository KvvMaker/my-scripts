-- RSE2 Scout (read-only): finds the trade remotes, price feed and client modules.
-- 1) Run this in your executor.
-- 2) Manually BUY then SELL a small amount of any stock.
-- 3) Wait ~30s. Output is written to rse2_scout.txt (executor workspace) and copied to clipboard.
-- 4) Paste the output back to Claude.

local RS = game:GetService("ReplicatedStorage")
local out = {}

local function ser(v, d)
    d = d or 0
    local t = typeof(v)
    if t == "string" then
        return string.format("%q", #v > 60 and (v:sub(1, 60) .. "...") or v)
    end
    if t == "Instance" then
        return "<" .. v.ClassName .. " " .. v:GetFullName() .. ">"
    end
    if t ~= "table" then
        return tostring(v)
    end
    if d >= 3 then
        return "{...}"
    end
    local parts, n = {}, 0
    for k, x in pairs(v) do
        n += 1
        if n > 12 then
            parts[#parts + 1] = "..."
            break
        end
        parts[#parts + 1] = "[" .. ser(k, d + 1) .. "]=" .. ser(x, d + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function log(s)
    out[#out + 1] = s
end

local function flush(toClipboard)
    local text = table.concat(out, "\n")
    if writefile then
        pcall(writefile, "rse2_scout.txt", text)
    end
    if toClipboard and setclipboard then
        pcall(setclipboard, text)
    end
end

-- 1. Remotes and modules in ReplicatedStorage
log("=== ReplicatedStorage remotes / modules ===")
local remoteEvents = {}
local n = 0
for _, d in ipairs(RS:GetDescendants()) do
    if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") or d:IsA("ModuleScript") then
        n += 1
        if n <= 500 then
            log(d.ClassName .. " | " .. d:GetFullName())
        end
        if d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent") then
            remoteEvents[#remoteEvents + 1] = d
        end
    end
end

-- 2. Loaded client modules whose names look relevant
if getloadedmodules then
    log("=== Loaded modules (name filter) ===")
    local ok, mods = pcall(getloadedmodules)
    if ok then
        for _, m in ipairs(mods) do
            local name = m.Name:lower()
            if name:find("market") or name:find("price") or name:find("trade") or name:find("order")
                or name:find("portfolio") or name:find("engine") or name:find("data") or name:find("clock")
                or name:find("time") or name:find("client") or name:find("remote") then
                log("Module | " .. m:GetFullName())
            end
        end
    end
end

-- 3. Outgoing calls made by the game's own scripts (your manual buy/sell)
local sent = {}
if hookmetamethod and getnamecallmethod then
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if (method == "FireServer" or method == "InvokeServer") and not (checkcaller and checkcaller()) then
            local args = table.pack(...)
            pcall(function()
                local path = self:GetFullName()
                sent[path] = (sent[path] or 0) + 1
                if sent[path] <= 6 then
                    local parts = {}
                    for i = 1, args.n do
                        parts[i] = ser(args[i])
                    end
                    log("OUT " .. method .. " | " .. path .. " | " .. table.concat(parts, ", "))
                    flush(false)
                end
            end)
        end
        return old(self, ...)
    end))
else
    log("!! hookmetamethod/getnamecallmethod not available - outgoing calls cannot be logged")
end

-- 4. Incoming server events (first few payloads per remote, to spot the price feed)
local recv = {}
for _, r in ipairs(remoteEvents) do
    r.OnClientEvent:Connect(function(...)
        local path = r:GetFullName()
        recv[path] = (recv[path] or 0) + 1
        if recv[path] <= 3 then
            local args = table.pack(...)
            local parts = {}
            for i = 1, args.n do
                parts[i] = ser(args[i])
            end
            log("IN  | " .. path .. " | " .. table.concat(parts, ", "))
        end
    end)
end

print("[Scout] running - buy then sell a small amount manually, results in ~30s")

task.delay(30, function()
    log("=== Incoming event counts (30s) ===")
    for path, c in pairs(recv) do
        log(c .. "x | " .. path)
    end
    flush(true)
    print("[Scout] done - saved to rse2_scout.txt and copied to clipboard")
end)
