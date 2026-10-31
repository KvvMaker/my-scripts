--[[
    Summon GUI
    Sends the banner summon packet a chosen number of times (or with a chosen amount) through
    ReplicatedStorage.Module.Library.ByteNetMax.system.ByteNetReliable.

    PACKET (read off the game's own FireServer call, 19 bytes for "Special Banner"):
        u8  packet id      41
        u16 amount         1       (little-endian, as ByteNet writes it)
        u16 name length    14
        ... name bytes     "Special Banner"

    MODES
      * Repeat   sends <Amount> packets, each with amount = 1, <Delay> seconds apart. This is exactly what the
                 game sends for a single pull, so it is the safe mode.
      * Packed   sends ONE packet with the amount field set to <Amount>. The amount field is a guess from the bytes;
                 check it by doing a x10 pull by hand with the logger on and comparing the bytes. If the server
                 ignores it, use Repeat.

    FIELDS
      * Banner     banner name, as the game writes it ("Special Banner").
      * Amount     1 - 9999.
      * Delay      seconds between packets in Repeat mode.
      * Packet ID  first byte of the packet. ByteNet numbers packets by declaration order, so a game update can
                   change it; copy the first byte of a logged real pull if summons stop working.

    NOTES
      * Open the summon screen first if the game needs it (the real pull is sent while it is open).
      * The server's own cooldowns, costs and rate limits still apply.
      * RightShift toggles the window, "-" collapses it, "x" unloads it (re-executing also replaces the old copy).
]]

local env = (getgenv and getgenv()) or _G
if env.SummonGuiUnload then
    pcall(env.SummonGuiUnload)
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local REMOTE_PATH = { "Module", "Library", "ByteNetMax", "system", "ByteNetReliable" }
local DEFAULT_PACKET_ID = 41
local DEFAULT_BANNER = "Special Banner"
local MAX_AMOUNT = 9999

local BG = Color3.fromRGB(28, 28, 34)
local BAR = Color3.fromRGB(40, 40, 48)
local FIELD = Color3.fromRGB(50, 50, 60)
local TEXT = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(160, 160, 172)
local ACCENT = Color3.fromRGB(88, 140, 255)
local GOOD = Color3.fromRGB(110, 210, 140)
local BAD = Color3.fromRGB(240, 100, 100)

--------------------------------------------------------------------------------
-- Packet
--------------------------------------------------------------------------------

local function buildPacket(packetId, amount, banner)
    local b = buffer.create(5 + #banner)
    buffer.writeu8(b, 0, packetId)
    buffer.writeu16(b, 1, amount)
    buffer.writeu16(b, 3, #banner)
    buffer.writestring(b, 5, banner)
    return b
end

local remote
local function getRemote()
    if remote and remote.Parent then
        return remote
    end
    local node = ReplicatedStorage
    for _, name in ipairs(REMOTE_PATH) do
        node = node:WaitForChild(name, 5)
        if not node then
            return nil, name
        end
    end
    remote = node
    return remote
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function new(class, props, parent)
    local inst = Instance.new(class)
    for key, value in pairs(props) do
        inst[key] = value
    end
    inst.Parent = parent
    return inst
end

local function guiParent()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then
            return hui
        end
    end
    return player:WaitForChild("PlayerGui")
end

local WINDOW_W, WINDOW_H, BAR_H = 270, 290, 28

local gui = new("ScreenGui", { Name = "SummonGui", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, guiParent())

local window = new("Frame", {
    Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
    Position = UDim2.new(0.5, -WINDOW_W / 2, 0.5, -WINDOW_H / 2),
    BackgroundColor3 = BG,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, window)

local titleBar = new("Frame", { Size = UDim2.new(1, 0, 0, BAR_H), BackgroundColor3 = BAR, BorderSizePixel = 0 }, window)
new("TextLabel", {
    Size = UDim2.new(1, -64, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "Summon",
    TextColor3 = TEXT,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
}, titleBar)

local function barButton(text, offsetX)
    return new("TextButton", {
        Size = UDim2.fromOffset(28, BAR_H),
        Position = UDim2.new(1, offsetX, 0, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = MUTED,
        Font = Enum.Font.GothamBold,
        TextSize = 16,
    }, titleBar)
end
local collapseBtn = barButton("-", -56)
local closeBtn = barButton("x", -28)

local body = new("Frame", {
    Size = UDim2.new(1, 0, 1, -BAR_H),
    Position = UDim2.fromOffset(0, BAR_H),
    BackgroundTransparency = 1,
}, window)
new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, body)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, body)

local order = 0
local function row(height)
    order += 1
    return new("Frame", { Size = UDim2.new(1, 0, 0, height), BackgroundTransparency = 1, LayoutOrder = order }, body)
end

local function field(labelText, default)
    local r = row(24)
    new("TextLabel", {
        Size = UDim2.new(0, 84, 1, 0),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = MUTED,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, r)
    local box = new("TextBox", {
        Size = UDim2.new(1, -88, 1, 0),
        Position = UDim2.fromOffset(88, 0),
        BackgroundColor3 = FIELD,
        BorderSizePixel = 0,
        Text = tostring(default),
        TextColor3 = TEXT,
        ClearTextOnFocus = false,
        Font = Enum.Font.Gotham,
        TextSize = 13,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(0, 4) }, box)
    return box
end

local function button(text, parent, size, position, color)
    local btn = new("TextButton", {
        Size = size,
        Position = position,
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        AutoButtonColor = true,
        Text = text,
        TextColor3 = TEXT,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
    }, parent)
    new("UICorner", { CornerRadius = UDim.new(0, 4) }, btn)
    return btn
end

local bannerBox = field("Banner", DEFAULT_BANNER)
local amountBox = field("Amount", 10)
local delayBox = field("Delay (s)", 0.25)
local idBox = field("Packet ID", DEFAULT_PACKET_ID)

local packed = false
local modeBtn = button("Mode: Repeat (1 per packet)", row(26), UDim2.fromScale(1, 1), UDim2.new(), FIELD)

local actions = row(30)
local startBtn = button("Summon", actions, UDim2.new(0.5, -3, 1, 0), UDim2.new(), ACCENT)
local stopBtn = button("Stop", actions, UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0), FIELD)

local status = new("TextLabel", {
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundTransparency = 1,
    Text = "Ready",
    TextColor3 = MUTED,
    Font = Enum.Font.Gotham,
    TextSize = 12,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    LayoutOrder = order + 1,
}, body)

local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or MUTED
end

--------------------------------------------------------------------------------
-- Summon loop
--------------------------------------------------------------------------------

local running = false
local runId = 0

local function stop(reason, color)
    running = false
    runId += 1
    startBtn.Text = "Summon"
    if reason then
        setStatus(reason, color)
    end
end

local function readInt(box, min, max)
    local n = tonumber(box.Text)
    if not n then
        return nil
    end
    n = math.clamp(math.floor(n), min, max)
    box.Text = tostring(n)
    return n
end

local function start()
    if running then
        return
    end

    local banner = bannerBox.Text
    if banner == "" then
        return setStatus("Banner name is empty", BAD)
    end
    local packetId = readInt(idBox, 0, 255)
    if not packetId then
        return setStatus("Packet ID must be a number (0-255)", BAD)
    end
    local amount = readInt(amountBox, 1, MAX_AMOUNT)
    if not amount then
        return setStatus("Amount must be a number (1-" .. MAX_AMOUNT .. ")", BAD)
    end
    local delay = tonumber(delayBox.Text)
    if not delay or delay < 0 then
        return setStatus("Delay must be 0 or more", BAD)
    end

    local event, missing = getRemote()
    if not event then
        return setStatus("Remote not found: nothing called '" .. missing .. "' on the path", BAD)
    end

    running = true
    runId += 1
    local myRun = runId
    startBtn.Text = "Running..."

    local calls = packed and 1 or amount
    local perCall = packed and amount or 1

    task.spawn(function()
        for i = 1, calls do
            if not running or runId ~= myRun then
                return
            end
            local ok, err = pcall(event.FireServer, event, buildPacket(packetId, perCall, banner), nil)
            if not ok then
                return stop("Fire failed: " .. tostring(err), BAD)
            end
            setStatus(("Sent %d/%d"):format(i, calls), TEXT)
            if i < calls then
                task.wait(delay)
            end
        end
        if runId == myRun then
            stop(("Done: %d summon%s sent (server may still reject some)"):format(amount, amount == 1 and "" or "s"), GOOD)
        end
    end)
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local connections = {}
local function connect(signal, fn)
    table.insert(connections, signal:Connect(fn))
end

connect(modeBtn.MouseButton1Click, function()
    packed = not packed
    modeBtn.Text = packed and "Mode: Packed (amount in packet)" or "Mode: Repeat (1 per packet)"
end)
connect(startBtn.MouseButton1Click, start)
connect(stopBtn.MouseButton1Click, function()
    if running then
        stop("Stopped", MUTED)
    end
end)

local collapsed = false
connect(collapseBtn.MouseButton1Click, function()
    collapsed = not collapsed
    window.Size = UDim2.fromOffset(WINDOW_W, collapsed and BAR_H or WINDOW_H)
end)

local function unload()
    running = false
    runId += 1
    for _, conn in ipairs(connections) do
        conn:Disconnect()
    end
    gui:Destroy()
    if env.SummonGuiUnload == unload then
        env.SummonGuiUnload = nil
    end
end
env.SummonGuiUnload = unload
connect(closeBtn.MouseButton1Click, unload)

connect(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        window.Visible = not window.Visible
    end
end)

-- Drag by the title bar.
local dragging, dragStart, startPos
local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
connect(titleBar.InputBegan, function(input)
    if isPointer(input) then
        dragging, dragStart, startPos = true, input.Position, window.Position
    end
end)
connect(UserInputService.InputChanged, function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
connect(UserInputService.InputEnded, function(input)
    if isPointer(input) then
        dragging = false
    end
end)
