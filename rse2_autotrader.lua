--[[
    RSE2 Auto Trader (GUI)
    - Samples live prices from the game's own PriceFeed once per second.
    - Enters on an EMA trend (fast above slow, gap widening, price rising) and exits on
      take-profit / stop-loss / trailing stop / trend flip / max hold.
    - Only manages positions IT opened. Do not hold the same ticker manually while it runs.
    - DRY RUN (paper trading) is ON by default: nothing is sent to the server until you turn it off.

    Run:  loadstring(readfile("rse2_autotrader.lua"))()
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local LP = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.RSE_BOT_CLEANUP then
    pcall(env.RSE_BOT_CLEANUP)
end

---------------------------------------------------------------------------
-- Game modules
---------------------------------------------------------------------------
local PriceEngine, MarketClock, TradeRemote, PriceFeed, State
do
    local ok, err = pcall(function()
        local Shared = RS:WaitForChild("Shared", 10)
        PriceEngine = require(Shared:WaitForChild("PriceEngine"))
        MarketClock = require(Shared:WaitForChild("MarketClock"))
        TradeRemote = RS:WaitForChild("Remotes", 10):WaitForChild("Trade", 10)
        local terminal = LP:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Terminal")
        PriceFeed = require(terminal:WaitForChild("PriceFeed"))
        State = require(terminal.Parent:WaitForChild("State"))
    end)
    if not ok then
        warn("[AutoTrader] could not load game modules: " .. tostring(err))
        return
    end
end

---------------------------------------------------------------------------
-- Settings (percent values are in percent, e.g. 1.5 = 1.5%)
---------------------------------------------------------------------------
local CFG = {
    tickers = "OBBY,PWN,CHIP",
    sizePct = 2,          -- % of cash per trade
    maxPos = 3,           -- max positions the bot holds at once
    maxNotional = 25000,  -- hard cap per trade ($)
    minNotional = 100,
    tp = 1.5,             -- take profit %
    sl = 1.0,             -- stop loss %
    trail = 0.6,          -- trailing stop % (arms once peak profit >= trail)
    lev = 1,
    maxHold = 240,        -- real seconds (1 real sec = 2 game minutes)
    maxLoss = 25000,      -- stop the bot if session P&L falls below -$maxLoss
    fastN = 12,
    slowN = 45,
    minTrend = 0.15,      -- min EMA gap % to enter
    maxTrend = 2.0,       -- don't chase moves already stretched beyond this gap %
    cooldown = 20,        -- real seconds before re-entering a ticker
    shorts = false,
    regularOnly = true,
    dry = true,
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local alive, running, closeAllReq = true, false, false
local T = {}        -- per-ticker market data
local held = {}     -- positions the bot opened, keyed by ticker
local book = { positions = nil, cash = nil, at = 0 } -- last account snapshot from our own Trade calls
local lastTradeAt = 0
local stats = { opens = 0, closes = 0, wins = 0, livePnl = 0, simPnl = 0 }
local uiLog = function() end

local function log(msg)
    msg = os.date("%H:%M:%S") .. "  " .. msg
    print("[AutoTrader] " .. msg)
    uiLog(msg)
end

local function count(tbl)
    local n = 0
    for _ in pairs(tbl) do
        n += 1
    end
    return n
end

---------------------------------------------------------------------------
-- Account helpers
---------------------------------------------------------------------------
local function profile()
    return State.profile
end

local function freshBook()
    return book.positions ~= nil and (os.clock() - book.at) < 20
end

local function getCash()
    if freshBook() and tonumber(book.cash) then
        return tonumber(book.cash)
    end
    local p = profile()
    return (p and tonumber(p.cash)) or tonumber(book.cash)
end

local function positionSources()
    local p = profile()
    local fromState = p and p.positions or nil
    if freshBook() then
        return { book.positions, fromState }
    end
    return { fromState, book.positions }
end

local function sideOf(pos)
    local s = tonumber(pos.side)
    if s then
        return s >= 0 and 1 or -1
    end
    return (tonumber(pos.qty) or 0) >= 0 and 1 or -1
end

local function findIndex(list, id, dir, qty)
    local firstMatch
    for i, pos in ipairs(list or {}) do
        if pos.id == id and sideOf(pos) == dir then
            firstMatch = firstMatch or i
            local q = math.abs(tonumber(pos.qty) or 0)
            if math.abs(q - qty) <= qty * 0.02 + 1e-6 then
                return i, pos
            end
        end
    end
    if firstMatch then
        return firstMatch, list[firstMatch]
    end
    return nil
end

local function trade(args)
    local wait = 1.2 - (os.clock() - lastTradeAt)
    if wait > 0 then
        task.wait(wait)
    end
    lastTradeAt = os.clock()
    local ok, res = pcall(function()
        return TradeRemote:InvokeServer(args)
    end)
    if not ok then
        return false, tostring(res)
    end
    if type(res) ~= "table" or res.ok ~= true then
        local why = type(res) == "table" and (res.err or res.error or res.reason or res.message) or res
        return false, tostring(why or "rejected")
    end
    if type(res.positions) == "table" then
        book.positions = res.positions
        book.cash = res.cash
        book.at = os.clock()
    end
    return true, res
end

---------------------------------------------------------------------------
-- Market data + signals
---------------------------------------------------------------------------
local function getAsset(id)
    local asset
    if State.resolveAsset then
        local ok, r = pcall(State.resolveAsset, id)
        if ok then
            asset = r
        end
    end
    if not asset then
        local ok, r = pcall(PriceEngine.assetById, id)
        if ok then
            asset = r
        end
    end
    return asset
end

local function applyTickers()
    local want = {}
    for sym in CFG.tickers:gmatch("[%w_]+") do
        want[sym:upper()] = true
    end
    for id, t in pairs(T) do
        if not want[id] and not held[id] then
            if t.unwatch then
                pcall(t.unwatch)
            end
            T[id] = nil
        end
    end
    for id in pairs(want) do
        if not T[id] then
            local asset = getAsset(id)
            if asset then
                local okw, unwatch = pcall(PriceFeed.watch, asset)
                T[id] = {
                    asset = asset, unwatch = okw and unwatch or nil,
                    n = 0, hist = {}, rise = 0, fall = 0, cool = 0,
                }
            else
                log("unknown ticker: " .. id)
            end
        end
    end
end

local function updateTicker(t, p)
    t.n += 1
    t.price = p
    if not t.fast then
        t.fast, t.slow = p, p
    else
        t.fast += (p - t.fast) * (2 / (CFG.fastN + 1))
        t.slow += (p - t.slow) * (2 / (CFG.slowN + 1))
    end
    local h = t.hist
    h[#h + 1] = p
    if #h > 12 then
        table.remove(h, 1)
    end
    local gap = (t.fast - t.slow) / t.slow * 100
    if t.gap then
        if gap > t.gap then
            t.rise += 1
            t.fall = 0
        elseif gap < t.gap then
            t.fall += 1
            t.rise = 0
        end
    end
    t.gap = gap
end

local function signal(t, p)
    if t.n < CFG.slowN or #t.hist < 6 then
        return 0
    end
    local mom = p / t.hist[#t.hist - 5] - 1
    if t.gap >= CFG.minTrend and t.gap <= CFG.maxTrend and t.rise >= 3 and p > t.fast and mom > 0 then
        return 1
    end
    if CFG.shorts and t.gap <= -CFG.minTrend and t.gap >= -CFG.maxTrend and t.fall >= 3 and p < t.fast and mom < 0 then
        return -1
    end
    return 0
end

local function sessionOk(t)
    if not t.gnow then
        return true
    end
    local cls = t.asset.class or "stock"
    local okc, open = pcall(MarketClock.isOpen, cls, t.gnow)
    if okc and not open then
        return false
    end
    if CFG.regularOnly then
        local okp, phase = pcall(MarketClock.phase, cls, t.gnow)
        if okp and phase ~= "regular" then
            return false
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------
local function openPos(id, t, dir, p)
    local cash = getCash() or (CFG.dry and 100000 or nil)
    if not cash then
        log("no cash info yet, skipping " .. id)
        return
    end
    local notional = math.min(cash * CFG.sizePct / 100, CFG.maxNotional)
    if notional < CFG.minNotional then
        log("size too small for " .. id .. " ($" .. math.floor(notional) .. ")")
        t.cool = os.clock() + 30
        return
    end
    local qty = math.floor(notional / p * 1e6) / 1e6
    local lev = math.max(1, math.floor(CFG.lev))
    local label = dir == 1 and "LONG" or "SHORT"

    if CFG.dry then
        held[id] = { dir = dir, entry = p, peak = 0, t0 = os.clock(), qty = qty, lev = lev, notional = notional, dry = true }
        stats.opens += 1
        log(string.format("[DRY] OPEN %s %s $%.0f @ %.4f (gap %.2f%%)", label, id, notional, p, t.gap))
        return
    end

    local ok, res = trade({ action = "open", id = id, direction = dir, lev = lev, qty = qty, maxOrder = false })
    if not ok then
        log("OPEN " .. id .. " failed: " .. tostring(res))
        t.cool = os.clock() + 30
        return
    end
    local fill = tonumber(res.price) or p
    held[id] = { dir = dir, entry = fill, peak = 0, t0 = os.clock(), qty = qty, lev = lev, notional = notional, dry = false }
    stats.opens += 1
    log(string.format("OPEN %s %s $%.0f @ %.4f", label, id, notional, fill))
end

local function closePos(id, reason, pnlPct)
    local h = held[id]
    local t = T[id]
    if not h then
        return
    end
    if h.dry then
        local usd = h.notional * (pnlPct / 100 - 0.002) -- ~0.2% round-trip fees
        stats.simPnl += usd
        stats.closes += 1
        if usd > 0 then
            stats.wins += 1
        end
        held[id] = nil
        if t then
            t.cool = os.clock() + CFG.cooldown
        end
        log(string.format("[DRY] CLOSE %s (%s) %+.2f%% = %+.0f$", id, reason, pnlPct, usd))
        return
    end

    local lastErr, triedIdx
    for _, src in ipairs(positionSources()) do
        local idx, pos = findIndex(src, id, h.dir, h.qty)
        if idx and idx ~= triedIdx then
            triedIdx = idx
            local ok, res = trade({
                action = "close", index = idx, expectedAssetId = id, expectedSide = h.dir,
                expectedLev = tonumber(pos.lev) or h.lev, fraction = 1,
            })
            if ok then
                local pnl = tonumber(res.pnl) or 0
                stats.livePnl += pnl
                stats.closes += 1
                if pnl > 0 then
                    stats.wins += 1
                end
                held[id] = nil
                if t then
                    t.cool = os.clock() + CFG.cooldown
                end
                log(string.format("CLOSE %s (%s) %+.2f%% pnl %+.2f$", id, reason, pnlPct, pnl))
                return
            end
            lastErr = res
        end
    end

    h.fails = (h.fails or 0) + 1
    h.retryAt = os.clock() + 10
    if not lastErr then
        h.notFound = (h.notFound or 0) + 1
        lastErr = "position not found in account"
        if h.notFound >= 5 then
            log("CLOSE " .. id .. ": giving up tracking (" .. lastErr .. ")")
            held[id] = nil
            return
        end
    end
    if h.fails == 1 or h.fails % 6 == 0 then
        log("CLOSE " .. id .. " failed: " .. tostring(lastErr))
    end
end

local function exitReason(t, h, p)
    local pnl = h.dir * (p - h.entry) / h.entry * 100
    if pnl > h.peak then
        h.peak = pnl
    end
    local age = os.clock() - h.t0
    if pnl >= CFG.tp then
        return "take-profit", pnl
    end
    if pnl <= -CFG.sl then
        return "stop-loss", pnl
    end
    if h.peak >= CFG.trail and pnl <= h.peak - CFG.trail then
        return "trailing", pnl
    end
    if age >= CFG.maxHold then
        return "max-hold", pnl
    end
    if age > 10 and t.n >= CFG.slowN and t.gap
        and ((h.dir == 1 and t.gap <= -CFG.minTrend) or (h.dir == -1 and t.gap >= CFG.minTrend)) then
        return "trend-flip", pnl
    end
    return nil, pnl
end

---------------------------------------------------------------------------
-- Main step (1 Hz)
---------------------------------------------------------------------------
local function step()
    -- sample prices
    for _, t in pairs(T) do
        local price, _, gnow = PriceFeed.last(t.asset)
        if type(price) == "number" and price > 0 then
            t.gnow = gnow
            updateTicker(t, price)
        end
    end

    -- exits (also runs when "close all" was requested, even if stopped)
    for id, h in pairs(held) do
        local t = T[id]
        if t and t.price and (not h.retryAt or os.clock() >= h.retryAt) then
            local reason, pnl = exitReason(t, h, t.price)
            if closeAllReq then
                reason = "manual close-all"
            end
            if reason then
                closePos(id, reason, pnl)
            end
        end
    end
    if closeAllReq and count(held) == 0 then
        closeAllReq = false
        log("all bot positions closed")
    end

    if not running then
        return
    end

    -- risk stop
    local sessionPnl = stats.livePnl + stats.simPnl
    if sessionPnl <= -CFG.maxLoss then
        running = false
        log(string.format("max session loss hit (%+.0f$) - bot stopped", sessionPnl))
        return
    end

    -- entries
    for id, t in pairs(T) do
        if not held[id] and t.price and os.clock() >= t.cool and count(held) < CFG.maxPos and sessionOk(t) then
            local dir = signal(t, t.price)
            if dir ~= 0 then
                openPos(id, t, dir, t.price)
            end
        end
    end
end

---------------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------------
local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        o[k] = v
    end
    o.Parent = parent
    return o
end

local COL = {
    bg = Color3.fromRGB(18, 20, 26), panel = Color3.fromRGB(28, 31, 40), text = Color3.fromRGB(225, 228, 235),
    dim = Color3.fromRGB(140, 146, 160), green = Color3.fromRGB(46, 160, 90), red = Color3.fromRGB(190, 60, 60),
    grey = Color3.fromRGB(60, 64, 76), accent = Color3.fromRGB(70, 120, 220),
}

local gui = mk("ScreenGui", { Name = "RSE_AutoTrader", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, nil)
local okParent = pcall(function()
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not okParent then
    gui.Parent = LP:WaitForChild("PlayerGui")
end

local main = mk("Frame", {
    Size = UDim2.fromOffset(340, 520), Position = UDim2.new(0, 40, 0.5, -260),
    BackgroundColor3 = COL.bg, BorderSizePixel = 0,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 8) }, main)

local title = mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = COL.panel, BorderSizePixel = 0,
    Text = "  RSE2 Auto Trader", TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = COL.text,
}, main)
mk("UICorner", { CornerRadius = UDim.new(0, 8) }, title)

-- dragging
local conns = {}
do
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
        end
    end)
    conns[#conns + 1] = UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

local content = mk("ScrollingFrame", {
    Position = UDim2.fromOffset(6, 32), Size = UDim2.new(1, -12, 0, 300), BackgroundTransparency = 1,
    BorderSizePixel = 0, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
}, main)
mk("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, content)

local order = 0
local function nextOrder()
    order += 1
    return order
end

local function button(text, color, onClick)
    local b = mk("TextButton", {
        Size = UDim2.new(1, -6, 0, 26), BackgroundColor3 = color, BorderSizePixel = 0, Text = text,
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = COL.text, LayoutOrder = nextOrder(), AutoButtonColor = true,
    }, content)
    mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    b.MouseButton1Click:Connect(onClick)
    return b
end

local function toggle(key, label)
    local b
    local function paint()
        b.Text = label .. ": " .. (CFG[key] and "ON" or "OFF")
        b.BackgroundColor3 = CFG[key] and COL.green or COL.grey
    end
    b = button(label, COL.grey, function()
        CFG[key] = not CFG[key]
        paint()
        if key == "dry" then
            log(CFG.dry and "DRY RUN on (paper trading)" or "LIVE MODE: real orders will be sent to the server")
        end
    end)
    paint()
end

local function input(key, label, kind)
    local row = mk("Frame", { Size = UDim2.new(1, -6, 0, 24), BackgroundColor3 = COL.panel, BorderSizePixel = 0, LayoutOrder = nextOrder() }, content)
    mk("UICorner", { CornerRadius = UDim.new(0, 5) }, row)
    mk("TextLabel", {
        Size = UDim2.new(0.55, 0, 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1, Text = label,
        TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = COL.dim,
    }, row)
    local box = mk("TextBox", {
        Size = UDim2.new(0.45, -6, 1, -6), Position = UDim2.new(0.55, 0, 0, 3), BackgroundColor3 = COL.bg, BorderSizePixel = 0,
        Text = tostring(CFG[key]), ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = COL.text,
    }, row)
    mk("UICorner", { CornerRadius = UDim.new(0, 4) }, box)
    box.FocusLost:Connect(function()
        if kind == "num" then
            local v = tonumber(box.Text)
            if v then
                CFG[key] = v
            end
            box.Text = tostring(CFG[key])
        else
            CFG[key] = box.Text
            applyTickers()
        end
    end)
end

local runBtn
runBtn = button("START", COL.green, function()
    running = not running
    runBtn.Text = running and "STOP" or "START"
    runBtn.BackgroundColor3 = running and COL.red or COL.green
    log(running and ("started (" .. (CFG.dry and "DRY RUN" or "LIVE") .. ")") or "stopped (open bot positions are still managed)")
end)
toggle("dry", "DRY RUN (paper)")
toggle("shorts", "Allow shorts")
toggle("regularOnly", "Regular hours only")
input("tickers", "Tickers (comma)", "text")
input("sizePct", "Size % of cash", "num")
input("maxPos", "Max open positions", "num")
input("maxNotional", "Max $ per trade", "num")
input("tp", "Take profit %", "num")
input("sl", "Stop loss %", "num")
input("trail", "Trailing stop %", "num")
input("lev", "Leverage (x)", "num")
input("maxHold", "Max hold (real sec)", "num")
input("maxLoss", "Stop bot at loss $", "num")
input("minTrend", "Min trend gap %", "num")
button("CLOSE ALL BOT POSITIONS", COL.accent, function()
    running = false
    runBtn.Text = "START"
    runBtn.BackgroundColor3 = COL.green
    closeAllReq = true
    log("closing all bot positions...")
end)
button("UNLOAD", COL.grey, function()
    if env.RSE_BOT_CLEANUP then
        env.RSE_BOT_CLEANUP()
    end
end)

local status = mk("TextLabel", {
    Position = UDim2.fromOffset(8, 336), Size = UDim2.new(1, -16, 0, 34), BackgroundTransparency = 1, Text = "",
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
    Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = COL.text,
}, main)

local logBox = mk("ScrollingFrame", {
    Position = UDim2.fromOffset(6, 374), Size = UDim2.new(1, -12, 0, 140), BackgroundColor3 = COL.panel, BorderSizePixel = 0,
    ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
}, main)
mk("UICorner", { CornerRadius = UDim.new(0, 5) }, logBox)
mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, logBox)
local logN = 0
uiLog = function(msg)
    logN += 1
    mk("TextLabel", {
        Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Text = msg,
        TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Code, TextSize = 11,
        TextColor3 = COL.text, LayoutOrder = logN,
    }, logBox)
    local kids = logBox:GetChildren()
    local labels = {}
    for _, k in ipairs(kids) do
        if k:IsA("TextLabel") then
            labels[#labels + 1] = k
        end
    end
    if #labels > 80 then
        labels[1]:Destroy()
    end
    logBox.CanvasPosition = Vector2.new(0, 1e6)
end

local function updateStatus()
    local warm = 0
    for _, t in pairs(T) do
        warm = math.max(warm, t.n)
    end
    status.Text = string.format(
        "%s | %s | held %d/%d | warm-up %d/%d\nLive P&L %+.0f$ | Paper P&L %+.0f$ | trades %d (wins %d)",
        running and "RUNNING" or "STOPPED", CFG.dry and "DRY RUN" or "LIVE", count(held), CFG.maxPos,
        math.min(warm, CFG.slowN), CFG.slowN, stats.livePnl, stats.simPnl, stats.closes, stats.wins
    )
end

---------------------------------------------------------------------------
-- Start / cleanup
---------------------------------------------------------------------------
env.RSE_BOT_CLEANUP = function()
    alive, running = false, false
    for _, c in ipairs(conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    for _, t in pairs(T) do
        if t.unwatch then
            pcall(t.unwatch)
        end
    end
    pcall(function()
        gui:Destroy()
    end)
    env.RSE_BOT_CLEANUP = nil
end

applyTickers()
log("ready. DRY RUN is ON - watch it paper-trade first. Warm-up takes ~" .. CFG.slowN .. "s.")

task.spawn(function()
    local lastErr
    while alive do
        local ok, err = pcall(step)
        if not ok and err ~= lastErr then
            lastErr = err
            log("step error: " .. tostring(err))
        end
        updateStatus()
        task.wait(1)
    end
end)
