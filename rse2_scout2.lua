-- RSE2 Scout 2 (read-only): dumps the price/trade module sources + APIs, and logs the Trade remote.
-- 1) Run in your executor.
-- 2) Wait for "[Scout2] sources dumped" in the console.
-- 3) Click ONE Buy then ONE Sell of a small amount in the game UI (any stock).
-- Files land in the executor workspace; Claude reads them directly.

local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local function find(path)
    local cur = game
    for part in path:gmatch("[^%.]+") do
        cur = cur and cur:FindFirstChild(part)
    end
    return cur
end

local function ser(v, d)
    d = d or 0
    local t = typeof(v)
    if t == "string" then
        return string.format("%q", #v > 80 and (v:sub(1, 80) .. "...") or v)
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
        if n > 16 then
            parts[#parts + 1] = "..."
            break
        end
        parts[#parts + 1] = "[" .. ser(k, d + 1) .. "]=" .. ser(x, d + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local base = "Players." .. LP.Name .. ".PlayerScripts.Client.Terminal."
local targets = {
    "ReplicatedStorage.Shared.LivePrice",
    "ReplicatedStorage.Shared.MarketClock",
    "ReplicatedStorage.Shared.PriceEngine",
    "ReplicatedStorage.Shared.IntradayEngine",
    "ReplicatedStorage.Shared.MarketKey",
    base .. "PriceFeed",
    base .. "Views.Pulse.TradePanel",
    base .. "Views.Portfolio.Data",
}

local apiLines = {}

local function dumpModule(path)
    local inst = find(path)
    if not inst then
        apiLines[#apiLines + 1] = "!! not found: " .. path
        return
    end
    local short = path:match("([^%.]+)$")

    -- decompiled source
    if decompile then
        local ok, src = pcall(decompile, inst)
        if ok and type(src) == "string" and writefile then
            pcall(writefile, "rse2_src_" .. short .. ".lua", src)
        else
            apiLines[#apiLines + 1] = "!! decompile failed: " .. path .. " " .. tostring(src)
        end
    else
        apiLines[#apiLines + 1] = "!! decompile() not available"
    end

    -- module API (functions / fields)
    local ok, mod = pcall(require, inst)
    apiLines[#apiLines + 1] = "=== " .. path .. " ==="
    if not ok then
        apiLines[#apiLines + 1] = "require failed: " .. tostring(mod)
    elseif type(mod) == "table" then
        local keys = {}
        for k, v in pairs(mod) do
            local tv = type(v)
            local desc = tv == "function" and "fn" or (tv == "table" and "table" or ("=" .. ser(v)))
            keys[#keys + 1] = tostring(k) .. " : " .. desc
        end
        table.sort(keys)
        for _, line in ipairs(keys) do
            apiLines[#apiLines + 1] = "  " .. line
        end
    else
        apiLines[#apiLines + 1] = "  returns " .. type(mod)
    end
end

for _, p in ipairs(targets) do
    pcall(dumpModule, p)
end
if writefile then
    pcall(writefile, "rse2_api.txt", table.concat(apiLines, "\n"))
end
print("[Scout2] sources dumped - now click ONE Buy then ONE Sell in the game UI")

-- Direct hook on RemoteFunction.InvokeServer (catches calls that bypass __namecall)
local tradeLog = {}
local function flushTrade()
    if writefile then
        pcall(writefile, "rse2_trade.txt", table.concat(tradeLog, "\n"))
    end
end

local counts = {}
local rf = Instance.new("RemoteFunction")
local oldInvoke
oldInvoke = hookfunction(rf.InvokeServer, newcclosure(function(self, ...)
    if checkcaller and checkcaller() then
        return oldInvoke(self, ...)
    end
    local args = table.pack(...)
    local res = table.pack(pcall(oldInvoke, self, ...))
    pcall(function()
        local name = self.Name
        counts[name] = (counts[name] or 0) + 1
        if name ~= "CompanyAction" and counts[name] <= 25 then
            local a = {}
            for i = 1, args.n do
                a[i] = ser(args[i])
            end
            local r = {}
            for i = 2, res.n do
                r[#r + 1] = ser(res[i])
            end
            tradeLog[#tradeLog + 1] = "INVOKE " .. self:GetFullName() .. " | args: " .. table.concat(a, ", ")
                .. " | ok=" .. tostring(res[1]) .. " | returned: " .. table.concat(r, ", ")
            flushTrade()
        end
    end)
    if not res[1] then
        error(res[2], 0)
    end
    return table.unpack(res, 2, res.n)
end))

-- Same for FireServer, minus the WatchAssets spam
local re = Instance.new("RemoteEvent")
local oldFire
oldFire = hookfunction(re.FireServer, newcclosure(function(self, ...)
    if not (checkcaller and checkcaller()) then
        local args = table.pack(...)
        pcall(function()
            local name = self.Name
            if name ~= "WatchAssets" then
                counts[name] = (counts[name] or 0) + 1
                if counts[name] <= 25 then
                    local a = {}
                    for i = 1, args.n do
                        a[i] = ser(args[i])
                    end
                    tradeLog[#tradeLog + 1] = "FIRE   " .. self:GetFullName() .. " | args: " .. table.concat(a, ", ")
                    flushTrade()
                end
            end
        end)
    end
    return oldFire(self, ...)
end))
