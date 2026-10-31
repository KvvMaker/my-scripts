--[[
    Lava Helper

    Tabs
      Overview      live stats (craters landed / in flight, lucky blocks, requests sent, teleports)
      Craters       Auto Collect (+ range), Auto Farm, Crater ESP
      Lucky Blocks  Auto Collect (+ range), Auto Farm, Lucky Block ESP
      Settings      farm delay, No Screen Shake, menu key, UI scale, notifications, unload

    Auto Farm for craters and lucky blocks share one loop and one delay slider;
    when both are on it always heads for whichever target is nearest.

    RightShift hides / shows the window (rebind it in Settings). Drag the title bar
    to move, "-" to collapse, "X" to unload everything.
]]

if _G.__LavaCraterGuiUnload then
    pcall(_G.__LavaCraterGuiUnload)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Upgrades = require(Modules:WaitForChild("Upgrades"))
local TechTree = require(Modules:WaitForChild("TechTree"))
local Mastery = require(Modules:WaitForChild("Mastery"))
local LuckyData = require(Modules:WaitForChild("LuckyBlocks"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CollectCrater = Remotes:WaitForChild("CollectCrater")
local CollectLuckyBlock = Remotes:WaitForChild("CollectLuckyBlock")

LocalPlayer:WaitForChild("Loaded")
local Lava = LocalPlayer:WaitForChild("Lava")
local LuckyFolder = LocalPlayer:WaitForChild(LuckyData.Folder)
local UpgradesFolder = LocalPlayer:WaitForChild("Upgrades")
local TechTreeFolder = LocalPlayer:WaitForChild("TechTree")
local Area1 = workspace:WaitForChild("LavaSpawns"):WaitForChild("Area1")
local SpawnedCraters = workspace:WaitForChild("SpawnedCraters", 10)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local Config = {
    AutoCollect = false,
    CollectRange = 20,
    AutoFarm = false,
    LuckyCollect = false,
    LuckyRange = 25,
    LuckyFarm = false,
    FarmDelay = 0.15,
    NoShake = false,
    ESP = false,
    LuckyESP = false,
}

local Stats = {
    CraterFires = 0, -- CollectCrater requests sent by Auto Collect
    LuckyFires = 0,  -- CollectLuckyBlock requests sent by Auto Collect
    Teleports = 0,   -- hops made by Auto Farm
}

local alive = true
local connections = {}
local pendingUntil = {} -- [drop] = os.clock() before which we won't re-fire
local farmSkip = {}     -- [drop] = os.clock() before which auto farm ignores it

local function Connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(connections, c)
    return c
end

--------------------------------------------------------------------------------
-- Game helpers (mirrors the original client script)
--------------------------------------------------------------------------------

local function GetRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- Same formula the game's own collector uses (without the per-crater reach).
local function GetGameRange()
    local ok, range = pcall(function()
        local owned = {}
        for _, child in ipairs(TechTreeFolder:GetChildren()) do
            owned[child.Name] = true
        end
        local tech = TechTree.GetBestEffect(owned, "CollectRadiusBonus", 0)
        local mastery = Mastery.GetBonus(LocalPlayer, "CollectRadius") * 2

        local level = UpgradesFolder:FindFirstChild("CollectRadius")
        level = level and level.Value or 0
        if level > 0 then
            local def = Upgrades.CollectRadius
            local data = def and def.Data and def.Data[level]
            if data and data.Reward > 0 then
                return (5 + data.Reward + tech + mastery) / 2
            end
        end
        return 8 + (tech + mastery) / 2
    end)
    return ok and range or nil
end

-- Position of a drop's crater if it has landed, otherwise nil.
local function GetLandedPosition(drop, serverNow)
    if serverNow < (drop:GetAttribute("LandAt") or 0) then
        return nil
    end
    local spawn = Area1:FindFirstChild(drop:GetAttribute("Spawn") or "")
    return spawn and spawn.Position
end

local function CountDrops()
    local landed, flying = 0, 0
    local now = workspace:GetServerTimeNow()
    for _, drop in ipairs(Lava:GetChildren()) do
        if now >= (drop:GetAttribute("LandAt") or 0) then
            landed += 1
        else
            flying += 1
        end
    end
    return landed, flying
end

--------------------------------------------------------------------------------
-- Auto Collect
--------------------------------------------------------------------------------

Connect(RunService.Heartbeat, function()
    if not Config.AutoCollect then
        return
    end
    local root = GetRoot()
    if not root then
        return
    end

    local now = os.clock()
    local serverNow = workspace:GetServerTimeNow()
    local rootPos = root.Position

    for _, drop in ipairs(Lava:GetChildren()) do
        if (pendingUntil[drop] or 0) <= now then
            local pos = GetLandedPosition(drop, serverNow)
            local id = drop:GetAttribute("Id")
            if pos and id then
                local dx, dz = rootPos.X - pos.X, rootPos.Z - pos.Z
                if math.sqrt(dx * dx + dz * dz) <= Config.CollectRange then
                    pendingUntil[drop] = now + 0.25
                    Stats.CraterFires += 1
                    CollectCrater:FireServer(id)
                end
            end
        end
    end
end)

Connect(Lava.ChildRemoved, function(drop)
    pendingUntil[drop] = nil
    farmSkip[drop] = nil
end)

--------------------------------------------------------------------------------
-- Lucky Blocks
--
-- The game's own script tweens each block down from DropHeight over FallTime and
-- only collects once it has landed, so we track the same landing time ourselves.
--------------------------------------------------------------------------------

local luckyLandAt = {}   -- [block] = os.clock() at which it has finished falling
local luckyFiredAt = {}  -- [block] = os.clock() before which we won't re-fire

local function TrackLucky(block)
    if not luckyLandAt[block] then
        luckyLandAt[block] = os.clock() + LuckyData.FallTime + 0.1
    end
end

for _, block in ipairs(LuckyFolder:GetChildren()) do
    TrackLucky(block)
end
Connect(LuckyFolder.ChildAdded, TrackLucky)
Connect(LuckyFolder.ChildRemoved, function(block)
    luckyLandAt[block] = nil
    luckyFiredAt[block] = nil
    farmSkip[block] = nil
end)

-- Rest position of a lucky block if it has landed, otherwise nil.
local function GetLuckyLandedPosition(block, now)
    if (luckyLandAt[block] or math.huge) > now then
        return nil
    end
    local pos = block:GetAttribute("Position")
    return typeof(pos) == "Vector3" and pos or nil
end

Connect(RunService.Heartbeat, function()
    if not Config.LuckyCollect then
        return
    end
    local root = GetRoot()
    if not root then
        return
    end

    local now = os.clock()
    local rootPos = root.Position

    for _, block in ipairs(LuckyFolder:GetChildren()) do
        if (luckyFiredAt[block] or 0) <= now then
            local pos = GetLuckyLandedPosition(block, now)
            local id = block:GetAttribute("Id")
            if pos and type(id) == "string" and (pos - rootPos).Magnitude <= Config.LuckyRange then
                luckyFiredAt[block] = now + 1
                Stats.LuckyFires += 1
                CollectLuckyBlock:FireServer(id)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Auto Farm (craters and / or lucky blocks)
--------------------------------------------------------------------------------

task.spawn(function()
    while alive do
        if Config.AutoFarm or Config.LuckyFarm then
            local root = GetRoot()
            if root then
                local now = os.clock()
                local serverNow = workspace:GetServerTimeNow()
                local rootPos = root.Position
                local bestKey, bestPos, bestDist = nil, nil, math.huge

                if Config.AutoFarm then
                    for _, drop in ipairs(Lava:GetChildren()) do
                        if (farmSkip[drop] or 0) <= now then
                            local pos = GetLandedPosition(drop, serverNow)
                            if pos then
                                local dist = (pos - rootPos).Magnitude
                                if dist < bestDist then
                                    bestKey, bestPos, bestDist = drop, pos, dist
                                end
                            end
                        end
                    end
                end

                if Config.LuckyFarm then
                    for _, block in ipairs(LuckyFolder:GetChildren()) do
                        if (farmSkip[block] or 0) <= now then
                            local pos = GetLuckyLandedPosition(block, now)
                            if pos then
                                local dist = (pos - rootPos).Magnitude
                                if dist < bestDist then
                                    bestKey, bestPos, bestDist = block, pos, dist
                                end
                            end
                        end
                    end
                end

                if bestKey then
                    farmSkip[bestKey] = now + 1.5
                    Stats.Teleports += 1
                    root.CFrame = CFrame.new(bestPos + Vector3.new(0, 3, 0))
                    root.AssemblyLinearVelocity = Vector3.zero
                end
            end
            task.wait(Config.FarmDelay)
        else
            task.wait(0.25)
        end
    end
end)

--------------------------------------------------------------------------------
-- No Screen Shake
--------------------------------------------------------------------------------

local savedShake = LocalPlayer:GetAttribute("SettingScreenShake")
local shakeConn

local function SetNoShake(on)
    Config.NoShake = on
    if shakeConn then
        shakeConn:Disconnect()
        shakeConn = nil
    end
    if on then
        savedShake = LocalPlayer:GetAttribute("SettingScreenShake")
        LocalPlayer:SetAttribute("SettingScreenShake", false)
        shakeConn = LocalPlayer:GetAttributeChangedSignal("SettingScreenShake"):Connect(function()
            if LocalPlayer:GetAttribute("SettingScreenShake") ~= false then
                LocalPlayer:SetAttribute("SettingScreenShake", false)
            end
        end)
    else
        LocalPlayer:SetAttribute("SettingScreenShake", savedShake)
    end
end

--------------------------------------------------------------------------------
-- ESP (craters and lucky blocks)
--------------------------------------------------------------------------------

local ESP_NAME = "LavaGuiESP"

-- Returns a setter that highlights everything inside getContainer() while on.
-- Roblox only renders a limited number of Highlights at once, so on a busy map
-- some of the farthest ones may not draw.
local function MakeESP(configKey, getContainer, color)
    local added

    local function apply(obj)
        if not (obj:IsA("Model") or obj:IsA("BasePart")) or obj:FindFirstChild(ESP_NAME) then
            return
        end
        local h = Instance.new("Highlight")
        h.Name = ESP_NAME
        h.FillColor = color
        h.OutlineColor = Color3.new(1, 1, 1)
        h.FillTransparency = 0.5
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent = obj
    end

    local function clear()
        if added then
            added:Disconnect()
            added = nil
        end
        local container = getContainer()
        if container then
            for _, obj in ipairs(container:GetChildren()) do
                local h = obj:FindFirstChild(ESP_NAME)
                if h then
                    h:Destroy()
                end
            end
        end
    end

    return function(on)
        Config[configKey] = on
        clear()
        if on then
            local container = getContainer()
            if container then
                for _, obj in ipairs(container:GetChildren()) do
                    apply(obj)
                end
                added = container.ChildAdded:Connect(apply)
            end
        end
    end
end

local SetESP = MakeESP("ESP", function()
    return SpawnedCraters
end, Color3.fromRGB(255, 120, 30))

local SetLuckyESP = MakeESP("LuckyESP", function()
    return workspace:FindFirstChild(LuckyData.HolderName)
end, Color3.fromRGB(255, 220, 60))

--------------------------------------------------------------------------------
-- GUI: theme and building blocks
--------------------------------------------------------------------------------

local Theme = {
    Window = Color3.fromRGB(17, 17, 21),
    Sidebar = Color3.fromRGB(22, 22, 27),
    Card = Color3.fromRGB(27, 27, 33),
    Elevated = Color3.fromRGB(38, 38, 46),
    Stroke = Color3.fromRGB(46, 46, 56),
    Text = Color3.fromRGB(240, 240, 245),
    Dim = Color3.fromRGB(139, 139, 153),
    Accent = Color3.fromRGB(255, 112, 48),
    AccentLight = Color3.fromRGB(255, 168, 64),
    Success = Color3.fromRGB(76, 201, 120),
    Danger = Color3.fromRGB(232, 78, 78),
    Off = Color3.fromRGB(58, 58, 68),
}

local WINDOW_W, WINDOW_H = 600, 410
local TITLE_H, SIDEBAR_W = 48, 140

local FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MED = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local INSTANT = TweenInfo.new(0)

local function Tween(inst, info, props)
    local tween = TweenService:Create(inst, info, props)
    tween:Play()
    return tween
end

-- Parent is applied last so the instance is only parented once it is configured.
local function New(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do
        inst[k] = v
    end
    inst.Parent = parent
    return inst
end

local function Corner(parent, radius)
    return New("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function Stroke(parent, color, transparency)
    return New("UIStroke", {
        Color = color,
        Thickness = 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        BorderStrokePosition = Enum.BorderStrokePosition.Inner,
    }, parent)
end

local function Padding(parent, left, top, right, bottom)
    return New("UIPadding", {
        PaddingLeft = UDim.new(0, left),
        PaddingTop = UDim.new(0, top),
        PaddingRight = UDim.new(0, right),
        PaddingBottom = UDim.new(0, bottom),
    }, parent)
end

local function List(parent, spacing)
    return New("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, spacing or 0),
    }, parent)
end

local function Gradient(parent, from, to, rotation)
    return New("UIGradient", {
        Color = ColorSequence.new(from, to),
        Rotation = rotation or 0,
    }, parent)
end

local function Label(parent, text, size, color, font)
    return New("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        TextSize = size,
        TextColor3 = color,
        Font = font or Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Size = UDim2.new(1, 0, 0, size + 4),
    }, parent)
end

local function HoverColor(button, normal, hover)
    button.MouseEnter:Connect(function()
        Tween(button, FAST, { BackgroundColor3 = hover })
    end)
    button.MouseLeave:Connect(function()
        Tween(button, FAST, { BackgroundColor3 = normal })
    end)
end

--------------------------------------------------------------------------------
-- GUI: root, toasts and window frame
--------------------------------------------------------------------------------

local gui = New("ScreenGui", {
    Name = "LavaCraterGui",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
})

do
    local candidates = {}
    if typeof(gethui) == "function" then
        table.insert(candidates, gethui)
    end
    table.insert(candidates, function()
        return game:GetService("CoreGui")
    end)

    local mounted = false
    for _, get in ipairs(candidates) do
        local ok, parent = pcall(get)
        if ok and parent then
            local ok2 = pcall(function()
                gui.Parent = parent
            end)
            if ok2 and gui.Parent == parent then
                mounted = true
                break
            end
        end
    end
    if not mounted then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
end

local viewport = gui.AbsoluteSize
if viewport.X < 100 or viewport.Y < 100 then
    viewport = Vector2.new(1280, 720)
end

-- Shrink on small screens (phones / small windows); adjustable later in Settings.
local uiScale = math.clamp(math.min(viewport.X / (WINDOW_W + 40), viewport.Y / (WINDOW_H + 40)), 0.55, 1)
uiScale = math.floor(uiScale * 20) / 20

local notificationsOn = true
local MenuKey = Enum.KeyCode.RightShift
local minimized = false
local visible = true

-- Toasts ----------------------------------------------------------------------

local toastHolder = New("Frame", {
    Name = "Toasts",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -18, 1, -18),
    Size = UDim2.fromOffset(270, 320),
    BackgroundTransparency = 1,
}, gui)
New("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 8),
}, toastHolder)

local toastOrder = 0

local function Notify(title, message, color)
    if not notificationsOn then
        return
    end
    toastOrder += 1

    local toast = New("CanvasGroup", {
        Size = UDim2.new(1, 0, 0, 50),
        BackgroundColor3 = Theme.Card,
        BorderSizePixel = 0,
        GroupTransparency = 1,
        LayoutOrder = toastOrder,
    }, toastHolder)
    Corner(toast, 8)
    Stroke(toast, Theme.Stroke)
    New("Frame", {
        Size = UDim2.new(0, 3, 1, 0),
        BackgroundColor3 = color or Theme.Accent,
        BorderSizePixel = 0,
    }, toast)

    local t = Label(toast, title, 13, Theme.Text, Enum.Font.GothamBold)
    t.Position = UDim2.fromOffset(14, 8)
    t.Size = UDim2.new(1, -24, 0, 16)
    local m = Label(toast, message, 12, Theme.Dim)
    m.Position = UDim2.fromOffset(14, 27)
    m.Size = UDim2.new(1, -24, 0, 16)

    Tween(toast, MED, { GroupTransparency = 0 })
    task.delay(2.6, function()
        if toast.Parent then
            Tween(toast, MED, { GroupTransparency = 1 }).Completed:Once(function()
                toast:Destroy()
            end)
        end
    end)

    -- Keep at most four on screen.
    local live = {}
    for _, child in ipairs(toastHolder:GetChildren()) do
        if child:IsA("CanvasGroup") then
            table.insert(live, child)
        end
    end
    if #live > 4 then
        live[1]:Destroy()
    end
end

-- Window ----------------------------------------------------------------------
-- `window` is a plain frame we drag around. `main` is laid out in design units and
-- scaled by a UIScale, so its on-screen size is design size * uiScale.

local window = New("Frame", {
    Name = "Window",
    BackgroundTransparency = 1,
    Size = UDim2.fromOffset(WINDOW_W * uiScale, WINDOW_H * uiScale),
    Position = UDim2.fromOffset(
        math.floor((viewport.X - WINDOW_W * uiScale) / 2),
        math.floor((viewport.Y - WINDOW_H * uiScale) / 2)
    ),
}, gui)

local main = New("CanvasGroup", {
    Name = "Main",
    Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
    BackgroundColor3 = Theme.Window,
    BorderSizePixel = 0,
    GroupTransparency = 1,
}, window)
Corner(main, 12)
local mainScale = New("UIScale", { Scale = uiScale }, main)

local function ApplySize(animate)
    local h = minimized and TITLE_H or WINDOW_H
    local info = animate and MED or INSTANT
    Tween(window, info, { Size = UDim2.fromOffset(WINDOW_W * uiScale, h * uiScale) })
    Tween(main, info, { Size = UDim2.fromOffset(WINDOW_W, h) })
end

local function SetVisible(show)
    visible = show
    if show then
        window.Visible = true
        Tween(main, MED, { GroupTransparency = 0 })
    else
        Tween(main, FAST, { GroupTransparency = 1 })
        task.delay(0.14, function()
            if not visible and window.Parent then
                window.Visible = false
            end
        end)
    end
end

-- Accent strip along the top edge.
local strip = New("Frame", {
    Size = UDim2.new(1, 0, 0, 2),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 10,
}, main)
Gradient(strip, Theme.Accent, Theme.AccentLight)

-- Outline drawn above everything so the title bar / sidebar don't cover it.
local outline = New("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ZIndex = 50,
}, main)
Corner(outline, 12)
Stroke(outline, Theme.Stroke)

-- Title bar -------------------------------------------------------------------

local titleBar = New("Frame", {
    Name = "TitleBar",
    Size = UDim2.fromOffset(WINDOW_W, TITLE_H),
    BackgroundColor3 = Theme.Sidebar,
    BorderSizePixel = 0,
}, main)
New("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.fromScale(0, 1),
    BackgroundColor3 = Theme.Stroke,
    BorderSizePixel = 0,
}, titleBar)

local logo = New("Frame", {
    Size = UDim2.fromOffset(28, 28),
    Position = UDim2.fromOffset(14, 10),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
}, titleBar)
Corner(logo, 8)
Gradient(logo, Theme.Accent, Theme.AccentLight, 45)
local logoText = Label(logo, "L", 16, Color3.new(1, 1, 1), Enum.Font.GothamBold)
logoText.Size = UDim2.fromScale(1, 1)
logoText.TextXAlignment = Enum.TextXAlignment.Center

local titleText = Label(titleBar, "Lava Helper", 15, Theme.Text, Enum.Font.GothamBold)
titleText.Position = UDim2.fromOffset(52, 8)
titleText.Size = UDim2.fromOffset(220, 18)
local subtitleText = Label(titleBar, "Craters & lucky blocks  |  v2.0", 11, Theme.Dim)
subtitleText.Position = UDim2.fromOffset(52, 26)
subtitleText.Size = UDim2.fromOffset(220, 14)

local function TitleButton(text, offsetX, hoverColor)
    local b = New("TextButton", {
        Size = UDim2.fromOffset(30, 30),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, offsetX, 0.5, 0),
        BackgroundColor3 = hoverColor,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Theme.Dim,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, titleBar)
    Corner(b, 8)
    b.MouseEnter:Connect(function()
        Tween(b, FAST, { BackgroundTransparency = 0, TextColor3 = Theme.Text })
    end)
    b.MouseLeave:Connect(function()
        Tween(b, FAST, { BackgroundTransparency = 1, TextColor3 = Theme.Dim })
    end)
    return b
end

local minimizeBtn = TitleButton("-", -48, Theme.Elevated)
local closeBtn = TitleButton("X", -12, Theme.Danger)

-- Sidebar ---------------------------------------------------------------------

local sidebar = New("Frame", {
    Name = "Sidebar",
    Position = UDim2.fromOffset(0, TITLE_H),
    Size = UDim2.fromOffset(SIDEBAR_W, WINDOW_H - TITLE_H),
    BackgroundColor3 = Theme.Sidebar,
    BorderSizePixel = 0,
}, main)
New("Frame", {
    Size = UDim2.new(0, 1, 1, 0),
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.fromScale(1, 0),
    BackgroundColor3 = Theme.Stroke,
    BorderSizePixel = 0,
}, sidebar)

local tabList = New("Frame", {
    Size = UDim2.new(1, 0, 1, -54),
    BackgroundTransparency = 1,
}, sidebar)
Padding(tabList, 10, 12, 11, 0)
List(tabList, 4)

local footer = New("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.fromScale(0, 1),
    Size = UDim2.new(1, -1, 0, 54),
    BackgroundTransparency = 1,
}, sidebar)
New("Frame", {
    Size = UDim2.new(1, -20, 0, 1),
    Position = UDim2.fromOffset(10, 0),
    BackgroundColor3 = Theme.Stroke,
    BorderSizePixel = 0,
}, footer)
local statusDot = New("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.fromOffset(14, 20),
    BackgroundColor3 = Theme.Off,
    BorderSizePixel = 0,
}, footer)
Corner(statusDot, 4)
local playerLabel = Label(footer, LocalPlayer.DisplayName, 12, Theme.Text, Enum.Font.GothamMedium)
playerLabel.Position = UDim2.fromOffset(28, 11)
playerLabel.Size = UDim2.new(1, -38, 0, 16)
playerLabel.TextTruncate = Enum.TextTruncate.AtEnd
local activeLabel = Label(footer, "0 features active", 11, Theme.Dim)
activeLabel.Position = UDim2.fromOffset(28, 28)
activeLabel.Size = UDim2.new(1, -38, 0, 14)

-- Content area ----------------------------------------------------------------

local content = New("Frame", {
    Name = "Content",
    Position = UDim2.fromOffset(SIDEBAR_W, TITLE_H),
    Size = UDim2.fromOffset(WINDOW_W - SIDEBAR_W, WINDOW_H - TITLE_H),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
}, main)

--------------------------------------------------------------------------------
-- GUI: tabs and controls
--------------------------------------------------------------------------------

local tabs = {}
local activeTab
local toggles = {}

local function UpdateActiveCount()
    local n = 0
    for _, t in ipairs(toggles) do
        if t.Get() then
            n += 1
        end
    end
    activeLabel.Text = n == 1 and "1 feature active" or (n .. " features active")
    Tween(statusDot, FAST, { BackgroundColor3 = n > 0 and Theme.Success or Theme.Off })
end

local function SelectTab(tab)
    if activeTab == tab then
        return
    end
    activeTab = tab
    for _, t in ipairs(tabs) do
        local on = t == tab
        t.Page.Visible = on
        Tween(t.Button, FAST, { BackgroundTransparency = on and 0 or 1 })
        Tween(t.Label, FAST, { TextColor3 = on and Theme.Text or Theme.Dim })
        Tween(t.Indicator, FAST, { BackgroundTransparency = on and 0 or 1 })
    end
end

local function AddTab(name)
    local tab = { Name = name }

    tab.Button = New("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = Theme.Elevated,
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, tabList)
    Corner(tab.Button, 8)

    tab.Indicator = New("Frame", {
        Size = UDim2.fromOffset(3, 16),
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        BackgroundColor3 = Theme.Accent,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, tab.Button)
    Corner(tab.Indicator, 2)

    tab.Label = Label(tab.Button, name, 13, Theme.Dim, Enum.Font.GothamMedium)
    tab.Label.Position = UDim2.fromOffset(16, 0)
    tab.Label.Size = UDim2.new(1, -16, 1, 0)

    tab.Page = New("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Off,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
    }, content)
    Padding(tab.Page, 14, 14, 14, 14)
    List(tab.Page, 10)

    tab.Button.MouseEnter:Connect(function()
        if activeTab ~= tab then
            Tween(tab.Button, FAST, { BackgroundTransparency = 0.7 })
        end
    end)
    tab.Button.MouseLeave:Connect(function()
        if activeTab ~= tab then
            Tween(tab.Button, FAST, { BackgroundTransparency = 1 })
        end
    end)
    tab.Button.MouseButton1Click:Connect(function()
        SelectTab(tab)
    end)

    table.insert(tabs, tab)
    return tab.Page
end

local function AddPageHeader(page, title, subtitle)
    local box = New("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, page)
    List(box, 2)
    Label(box, title, 20, Theme.Text, Enum.Font.GothamBold)
    Label(box, subtitle, 12, Theme.Dim)
end

local function AddCard(page, title)
    local card = New("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Card,
        BorderSizePixel = 0,
    }, page)
    Corner(card, 10)
    Stroke(card, Theme.Stroke, 0.3)
    Padding(card, 14, 12, 14, 14)
    List(card, 12)
    card:SetAttribute("Title", title)

    local heading = Label(card, string.upper(title), 11, Theme.Accent, Enum.Font.GothamBold)
    heading.Size = UDim2.new(1, 0, 0, 14)
    return card
end

-- A row with a title (and optional description) on the left; the caller places a
-- control of `rightWidth` pixels on the right.
local function AddRow(card, title, desc, rightWidth)
    local row = New("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, card)
    local textBox = New("Frame", {
        Size = UDim2.new(1, -(rightWidth + 16), 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, row)
    List(textBox, 2)
    Label(textBox, title, 14, Theme.Text, Enum.Font.GothamMedium)
    if desc then
        local d = Label(textBox, desc, 12, Theme.Dim)
        d.AutomaticSize = Enum.AutomaticSize.Y
        d.Size = UDim2.new(1, 0, 0, 0)
        d.TextWrapped = true
        d.TextYAlignment = Enum.TextYAlignment.Top
    end
    return row
end

-- opts: Title, Desc, Default, Callback(on), Silent (no toast), Internal (not counted
-- as a feature and untouched by "Disable all").
local function AddToggle(card, opts)
    local row = AddRow(card, opts.Title, opts.Desc, 42)

    local switch = New("TextButton", {
        Size = UDim2.fromOffset(42, 22),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        BackgroundColor3 = Theme.Off,
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, row)
    Corner(switch, 11)
    local knob = New("Frame", {
        Size = UDim2.fromOffset(16, 16),
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        BackgroundColor3 = Theme.Text,
        BorderSizePixel = 0,
    }, switch)
    Corner(knob, 8)

    local state = opts.Default or false
    local control = {}

    local function render(animate)
        local info = animate and FAST or INSTANT
        Tween(switch, info, { BackgroundColor3 = state and Theme.Accent or Theme.Off })
        Tween(knob, info, { Position = state and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) })
    end
    render(false)

    function control.Get()
        return state
    end

    function control.Set(value, silent)
        if state == value then
            return
        end
        state = value
        render(true)
        opts.Callback(value)
        if not silent and not opts.Silent then
            Notify(card:GetAttribute("Title") or "Lava Helper", opts.Title .. (value and " enabled" or " disabled"),
                value and Theme.Success or Theme.Dim)
        end
        UpdateActiveCount()
    end

    switch.MouseButton1Click:Connect(function()
        control.Set(not state)
    end)

    if not opts.Internal then
        table.insert(toggles, control)
    end
    return control
end

-- opts: Title, Min, Max, Default, Decimals, Callback(value)
local function AddSlider(card, opts)
    local row = New("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundTransparency = 1,
    }, card)
    local title = Label(row, opts.Title, 14, Theme.Text, Enum.Font.GothamMedium)
    title.Size = UDim2.new(1, -80, 0, 20)

    local box = New("TextBox", {
        Size = UDim2.fromOffset(64, 22),
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        BackgroundColor3 = Theme.Elevated,
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        Text = "",
        ClearTextOnFocus = false,
        BorderSizePixel = 0,
    }, row)
    Corner(box, 6)
    Stroke(box, Theme.Stroke)

    local hit = New("TextButton", {
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.fromOffset(0, 26),
        BackgroundTransparency = 1,
        Text = "",
    }, row)
    local track = New("Frame", {
        Size = UDim2.new(1, 0, 0, 4),
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        BackgroundColor3 = Theme.Off,
        BorderSizePixel = 0,
    }, hit)
    Corner(track, 2)
    local fill = New("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, track)
    Corner(fill, 2)
    Gradient(fill, Theme.Accent, Theme.AccentLight)
    local knob = New("Frame", {
        Size = UDim2.fromOffset(14, 14),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        BackgroundColor3 = Theme.Text,
        BorderSizePixel = 0,
        ZIndex = 2,
    }, track)
    Corner(knob, 7)

    local mult = 10 ^ (opts.Decimals or 0)
    local current = opts.Default

    local function setValue(v, fire)
        v = math.clamp(math.floor(v * mult + 0.5) / mult, opts.Min, opts.Max)
        current = v
        local alpha = (v - opts.Min) / (opts.Max - opts.Min)
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        box.Text = tostring(v)
        if fire then
            opts.Callback(v)
        end
    end
    setValue(opts.Default, false)

    local dragging = false
    local function fromInput(input)
        local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        setValue(opts.Min + alpha * (opts.Max - opts.Min), true)
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            Tween(knob, FAST, { Size = UDim2.fromOffset(18, 18) })
            fromInput(input)
        end
    end)
    Connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            fromInput(input)
        end
    end)
    Connect(UserInputService.InputEnded, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            Tween(knob, FAST, { Size = UDim2.fromOffset(14, 14) })
        end
    end)

    -- Typing a value directly.
    box.Focused:Connect(function()
        box.Text = tostring(current)
    end)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then
            setValue(n, true)
        else
            setValue(current, false)
        end
    end)
end

local function AddButton(card, text, callback, style)
    local normal = style == "danger" and Theme.Danger or Theme.Elevated
    local hover = normal:Lerp(Color3.new(1, 1, 1), 0.1)
    local btn = New("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = normal,
        Text = text,
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 13,
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, card)
    Corner(btn, 8)
    if style ~= "danger" then
        Stroke(btn, Theme.Stroke)
    end
    HoverColor(btn, normal, hover)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

local function AddStatGrid(page)
    local grid = New("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, page)
    New("UIGridLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        CellSize = UDim2.new(0.5, -5, 0, 64),
        CellPadding = UDim2.fromOffset(10, 10),
    }, grid)
    return grid
end

local function AddStat(grid, caption)
    local tile = New("Frame", {
        BackgroundColor3 = Theme.Card,
        BorderSizePixel = 0,
    }, grid)
    Corner(tile, 10)
    Stroke(tile, Theme.Stroke, 0.3)
    local value = Label(tile, "0", 22, Theme.Text, Enum.Font.GothamBold)
    value.Position = UDim2.fromOffset(14, 10)
    value.Size = UDim2.new(1, -28, 0, 26)
    local cap = Label(tile, caption, 12, Theme.Dim)
    cap.Position = UDim2.fromOffset(14, 38)
    cap.Size = UDim2.new(1, -28, 0, 16)
    return value
end

--------------------------------------------------------------------------------
-- GUI: pages
--------------------------------------------------------------------------------

do
    local gameRange = GetGameRange()
    Config.CollectRange = math.clamp(math.floor((gameRange or 20) + 0.5), 5, 500)
end

-- Overview --------------------------------------------------------------------

local overview = AddTab("Overview")
AddPageHeader(overview, "Overview", "Live status of the crater and lucky block systems.")

local grid = AddStatGrid(overview)
local statLanded = AddStat(grid, "Craters landed")
local statFlying = AddStat(grid, "Craters in flight")
local statLucky = AddStat(grid, "Lucky blocks")
local statRange = AddStat(grid, "Game collect range")
local statFires = AddStat(grid, "Collect requests sent")
local statHops = AddStat(grid, "Farm teleports")

local quick = AddCard(overview, "Quick actions")
AddButton(quick, "Disable all features", function()
    for _, t in ipairs(toggles) do
        t.Set(false, true)
    end
    Notify("Lava Helper", "All features disabled", Theme.Dim)
end)

-- Craters ---------------------------------------------------------------------

local craters = AddTab("Craters")
AddPageHeader(craters, "Craters", "Automate lava crater collection.")

local craterCollect = AddCard(craters, "Craters")
AddToggle(craterCollect, {
    Title = "Auto Collect",
    Desc = "Sends the collect request for landed craters inside your range, even when the game's own pickup radius wouldn't reach them.",
    Callback = function(on)
        Config.AutoCollect = on
    end,
})
AddSlider(craterCollect, {
    Title = "Collect Range (studs)",
    Min = 5,
    Max = 500,
    Default = Config.CollectRange,
    Decimals = 0,
    Callback = function(v)
        Config.CollectRange = v
    end,
})

local craterFarm = AddCard(craters, "Craters")
AddToggle(craterFarm, {
    Title = "Auto Farm",
    Desc = "Teleports onto the nearest landed crater so the game's own collector picks it up.",
    Callback = function(on)
        Config.AutoFarm = on
    end,
})
AddToggle(craterFarm, {
    Title = "Crater ESP",
    Desc = "Highlights craters and incoming fireballs through walls.",
    Callback = SetESP,
})

-- Lucky blocks ----------------------------------------------------------------

local lucky = AddTab("Lucky Blocks")
AddPageHeader(lucky, "Lucky Blocks", "Automate lucky block pickups.")

local luckyCollect = AddCard(lucky, "Lucky Blocks")
AddToggle(luckyCollect, {
    Title = "Auto Collect",
    Desc = "Sends the collect request for landed blocks inside your range. The server may reject anything beyond its own pickup radius.",
    Callback = function(on)
        Config.LuckyCollect = on
    end,
})
AddSlider(luckyCollect, {
    Title = "Collect Range (studs)",
    Min = 5,
    Max = 500,
    Default = Config.LuckyRange,
    Decimals = 0,
    Callback = function(v)
        Config.LuckyRange = v
    end,
})

local luckyFarm = AddCard(lucky, "Lucky Blocks")
AddToggle(luckyFarm, {
    Title = "Auto Farm",
    Desc = "Teleports to each landed block so the game's own collector picks it up.",
    Callback = function(on)
        Config.LuckyFarm = on
    end,
})
AddToggle(luckyFarm, {
    Title = "Lucky Block ESP",
    Desc = "Highlights lucky blocks through walls.",
    Callback = SetLuckyESP,
})

-- Settings --------------------------------------------------------------------

local settings = AddTab("Settings")
AddPageHeader(settings, "Settings", "Farming behaviour and interface options.")

local gameplay = AddCard(settings, "Gameplay")
AddSlider(gameplay, {
    Title = "Farm Delay (seconds)",
    Min = 0.05,
    Max = 1,
    Default = Config.FarmDelay,
    Decimals = 2,
    Callback = function(v)
        Config.FarmDelay = v
    end,
})
AddToggle(gameplay, {
    Title = "No Screen Shake",
    Desc = "Disables the camera shake from fireball impacts.",
    Callback = SetNoShake,
})

local interface = AddCard(settings, "Interface")

-- Menu key row (click, then press a key).
local keyRow = AddRow(interface, "Menu Key", "Click, then press a key. Escape cancels.", 92)
local keyButton = New("TextButton", {
    Size = UDim2.fromOffset(92, 26),
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, 0, 0.5, 0),
    BackgroundColor3 = Theme.Elevated,
    Text = MenuKey.Name,
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamMedium,
    TextSize = 12,
    AutoButtonColor = false,
    BorderSizePixel = 0,
}, keyRow)
Corner(keyButton, 6)
Stroke(keyButton, Theme.Stroke)
HoverColor(keyButton, Theme.Elevated, Color3.fromRGB(48, 48, 58))

local listening = false
keyButton.MouseButton1Click:Connect(function()
    listening = true
    keyButton.Text = "Press a key..."
end)

AddSlider(interface, {
    Title = "UI Scale",
    Min = 0.5,
    Max = 1.4,
    Default = uiScale,
    Decimals = 2,
    Callback = function(v)
        uiScale = v
        mainScale.Scale = v
        ApplySize(false)
    end,
})
AddToggle(interface, {
    Title = "Notifications",
    Desc = "Show a small toast when a feature is switched on or off.",
    Default = true,
    Silent = true,
    Internal = true,
    Callback = function(on)
        notificationsOn = on
    end,
})

local session = AddCard(settings, "Session")
AddButton(session, "Unload script", function()
    if _G.__LavaCraterGuiUnload then
        _G.__LavaCraterGuiUnload()
    end
end, "danger")

SelectTab(overview)

--------------------------------------------------------------------------------
-- Live stats
--------------------------------------------------------------------------------

task.spawn(function()
    while alive do
        local landed, flying = CountDrops()
        local range = GetGameRange()
        statLanded.Text = tostring(landed)
        statFlying.Text = tostring(flying)
        statLucky.Text = tostring(#LuckyFolder:GetChildren())
        statRange.Text = range and string.format("%.1f", range) or "?"
        statFires.Text = tostring(Stats.CraterFires + Stats.LuckyFires)
        statHops.Text = tostring(Stats.Teleports)
        task.wait(0.4)
    end
end)

--------------------------------------------------------------------------------
-- Window behaviour
--------------------------------------------------------------------------------

do
    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = window.Position
        end
    end)
    Connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            window.Position = UDim2.fromOffset(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y)
        end
    end)
    Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

minimizeBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    minimizeBtn.Text = minimized and "+" or "-"
    ApplySize(true)
end)

Connect(UserInputService.InputBegan, function(input, processed)
    if listening then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            listening = false
            if input.KeyCode ~= Enum.KeyCode.Escape then
                MenuKey = input.KeyCode
                Notify("Menu key", "Set to " .. MenuKey.Name, Theme.Accent)
            end
            keyButton.Text = MenuKey.Name
        end
        return
    end

    if not processed and input.KeyCode == MenuKey then
        if visible then
            Notify("Menu hidden", "Press " .. MenuKey.Name .. " to show it again", Theme.Dim)
        end
        SetVisible(not visible)
    end
end)

--------------------------------------------------------------------------------
-- Unload
--------------------------------------------------------------------------------

local function Unload()
    alive = false
    Config.AutoCollect = false
    Config.AutoFarm = false
    Config.LuckyCollect = false
    Config.LuckyFarm = false
    if Config.NoShake then
        SetNoShake(false)
    end
    if Config.ESP then
        SetESP(false)
    end
    if Config.LuckyESP then
        SetLuckyESP(false)
    end
    for _, c in ipairs(connections) do
        c:Disconnect()
    end
    table.clear(connections)
    gui:Destroy()
    _G.__LavaCraterGuiUnload = nil
end

_G.__LavaCraterGuiUnload = Unload
closeBtn.MouseButton1Click:Connect(Unload)

-- Fade in.
SetVisible(true)
task.defer(Notify, "Lava Helper", "Loaded. Press " .. MenuKey.Name .. " to hide the menu.", Theme.Accent)
