--[[
    Wave Skipper
    Small control panel that votes to skip the wave for you on a delay, and hides the "attempting to vote too fast"
    message the game shows when votes are sent too quickly.
    RightShift toggles the window, drag the title bar to move it, "-" collapses it, "x" unloads it.
    Re-executing the script unloads the previous copy first.

    HOW IT WORKS
      Auto Skip   calls ReplicatedStorage.endpoints.client_to_server.vote_wave_skip:InvokeServer() - the same request the
                  game's own vote-skip button / Auto-Skip Waves setting sends - once every Delay seconds. The server still
                  decides whether the vote counts. A new call never starts while the previous one is still waiting for the
                  server, and the delay is measured from when the last call came back.
      Hide msg    hides any on-screen text that looks like "voting too fast" (a label, plus its box if the box holds
                  nothing else) and drops StarterGui:SetCore notifications with that text. Turn it off to see it again.
      Skip Now    sends one vote right away, ignoring the delay.

    The line under the buttons shows the countdown and what the server answered to the last vote.
    Auto skip is off by default, Hide msg is on.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local env = (getgenv and getgenv()) or _G
if env.WaveSkipperUnload then
    pcall(env.WaveSkipperUnload)
end

local CONFIG = {
    delay = 2, -- seconds between votes
    remotePath = { "endpoints", "client_to_server", "vote_wave_skip" },
    toggleKey = Enum.KeyCode.RightShift,
}

local settings = {
    enabled = false,
    hideSpam = true,
    delay = CONFIG.delay,
}

local alive = true
local connections = {}

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local statusLabel
local lastResult = "none yet"

local function setStatus(headline)
    if statusLabel then
        statusLabel.Text = headline .. "\nLast: " .. lastResult
    end
end

--------------------------------------------------------------------------------
-- Hiding the "voting too fast" message
--------------------------------------------------------------------------------

local function isSpamText(text)
    text = text:lower()
    return text:find("vot", 1, true) ~= nil
        and (text:find("fast", 1, true) ~= nil or text:find("slow down", 1, true) ~= nil)
end

local suppressed = {} -- [label] = { targets = {...}, conns = {...} }
local watched = setmetatable({}, { __mode = "k" })

-- A box that holds nothing but the message is hidden with it, so no empty bubble is left behind.
-- Boxes with a list/grid layout are shared notification stacks and are left alone.
local function hasOtherContent(container, label)
    for _, descendant in ipairs(container:GetDescendants()) do
        if descendant:IsA("UIListLayout") or descendant:IsA("UIGridLayout") then
            return true
        end
        if descendant ~= label and (descendant:IsA("TextLabel") or descendant:IsA("TextButton")) and descendant.Text ~= "" then
            return true
        end
    end
    return false
end

local function findTargets(label)
    local targets = { label }
    local parent = label.Parent
    for _ = 1, 2 do
        if parent and parent:IsA("GuiObject") and not parent:IsA("ScrollingFrame") and not hasOtherContent(parent, label) then
            table.insert(targets, parent)
            parent = parent.Parent
        else
            break
        end
    end
    return targets
end

local function release(label)
    local entry = suppressed[label]
    if not entry then
        return
    end
    suppressed[label] = nil
    for _, connection in ipairs(entry.conns) do
        connection:Disconnect()
    end
    for _, target in ipairs(entry.targets) do
        if target.Parent and (target ~= label or label.Text ~= "") then
            target.Visible = true
        end
    end
end

local function refresh(label)
    if not alive then
        return
    end
    local text = label.Text
    if settings.hideSpam and isSpamText(text) then
        local entry = suppressed[label]
        if not entry then
            entry = { targets = findTargets(label), conns = {} }
            suppressed[label] = entry
            -- the game may flip Visible back on for the same message, so keep it hidden while the text matches
            for _, target in ipairs(entry.targets) do
                table.insert(entry.conns, target:GetPropertyChangedSignal("Visible"):Connect(function()
                    refresh(label)
                end))
            end
        end
        for _, target in ipairs(entry.targets) do
            if target.Visible then
                target.Visible = false
            end
        end
    elseif suppressed[label] and (text ~= "" or not settings.hideSpam) then
        release(label)
    end
end

local function watch(object)
    if watched[object] or not (object:IsA("TextLabel") or object:IsA("TextButton")) then
        return
    end
    watched[object] = true
    object:GetPropertyChangedSignal("Text"):Connect(function()
        refresh(object)
    end)
    object.Destroying:Connect(function()
        release(object)
    end)
    refresh(object)
end

local function refreshAll()
    for label in pairs(watched) do
        refresh(label)
    end
    if not settings.hideSpam then
        for label in pairs(suppressed) do
            release(label)
        end
    end
end

for _, descendant in ipairs(playerGui:GetDescendants()) do
    watch(descendant)
end
connect(playerGui.DescendantAdded, watch)

-- Some games send it as a Roblox notification instead of drawing their own label.
if hookfunction and newcclosure then
    pcall(function()
        local original
        original = hookfunction(StarterGui.SetCore, newcclosure(function(self, name, data, ...)
            if alive and settings.hideSpam and name == "SendNotification" and type(data) == "table"
                and isSpamText(tostring(data.Title or "") .. " " .. tostring(data.Text or "")) then
                return
            end
            return original(self, name, data, ...)
        end))
    end)
end

--------------------------------------------------------------------------------
-- Skipping the wave
--------------------------------------------------------------------------------

local function findRemote()
    local current = ReplicatedStorage
    for _, name in ipairs(CONFIG.remotePath) do
        current = current and current:FindFirstChild(name)
    end
    return current
end

local votes = 0
local voting = false
local lastVote = os.clock()

local function vote()
    if voting then
        return
    end
    local remote = findRemote()
    if not remote then
        lastResult = "remote not found"
        setStatus("vote_wave_skip is missing")
        return
    end
    voting = true
    task.spawn(function()
        local ok, result = pcall(function()
            if remote:IsA("RemoteFunction") then
                return remote:InvokeServer()
            end
            remote:FireServer()
        end)
        voting = false
        lastVote = os.clock()
        if not alive then
            return
        end
        if ok then
            votes += 1
            lastResult = result ~= nil and ("#%d -> %s"):format(votes, tostring(result)) or ("#%d sent"):format(votes)
        else
            lastResult = "error: " .. tostring(result)
        end
        if not settings.enabled then
            setStatus("Auto skip off")
        end
    end)
end

task.spawn(function()
    while alive do
        task.wait(0.1)
        if settings.enabled then
            if voting then
                setStatus("Waiting for the server...")
            else
                local remaining = lastVote + settings.delay - os.clock()
                if remaining <= 0 then
                    vote()
                else
                    setStatus(("Next vote in %.1fs"):format(remaining))
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local Theme = {
    Background = Color3.fromRGB(22, 22, 28),
    Topbar = Color3.fromRGB(30, 30, 38),
    Element = Color3.fromRGB(36, 36, 46),
    Accent = Color3.fromRGB(110, 90, 255),
    On = Color3.fromRGB(70, 180, 120),
    Off = Color3.fromRGB(70, 70, 86),
    Text = Color3.fromRGB(235, 235, 245),
    SubText = Color3.fromRGB(150, 150, 170),
    Font = Enum.Font.Gotham,
    FontBold = Enum.Font.GothamBold,
}

local function create(class, props, children)
    local inst = Instance.new(class)
    local parent
    for k, v in pairs(props) do
        if k == "Parent" then
            parent = v
        else
            inst[k] = v
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    inst.Parent = parent
    return inst
end

local function corner(radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius or 6) })
end

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function guiParent()
    if gethui then
        local ok, container = pcall(gethui)
        if ok and container then
            return container
        end
    end
    return game:GetService("CoreGui")
end

local gui = create("ScreenGui", {
    Name = "WaveSkipper",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
})
if syn and syn.protect_gui then
    pcall(syn.protect_gui, gui)
end
gui.Parent = guiParent()

local window = create("Frame", {
    Name = "Window",
    Position = UDim2.new(0, 40, 0.5, -90),
    Size = UDim2.fromOffset(250, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundColor3 = Theme.Background,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Parent = gui,
}, {
    corner(8),
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
})

local topbar = create("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = Theme.Topbar,
    BorderSizePixel = 0,
    LayoutOrder = 1,
    Parent = window,
})

create("TextLabel", {
    Position = UDim2.fromOffset(12, 0),
    Size = UDim2.new(1, -70, 1, 0),
    BackgroundTransparency = 1,
    Text = "Wave Skipper",
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = Theme.Text,
    Font = Theme.FontBold,
    TextSize = 14,
    Parent = topbar,
})

local function topbarButton(text, offset)
    return create("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, offset, 0.5, 0),
        Size = UDim2.fromOffset(24, 22),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Theme.SubText,
        Font = Theme.FontBold,
        TextSize = 16,
        Parent = topbar,
    })
end

local collapseButton = topbarButton("-", -34)
local closeButton = topbarButton("x", -8)

local body = create("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = 2,
    Parent = window,
}, {
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
    create("UIPadding", {
        PaddingTop = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 12),
    }),
})

local function row(height)
    return create("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
        Parent = body,
    })
end

local function rowLabel(parent, text, width)
    return create("TextLabel", {
        Size = UDim2.new(1, -width, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = Theme.Text,
        Font = Theme.Font,
        TextSize = 13,
        Parent = parent,
    })
end

local function smallButton(parent, text, props)
    props.Text = text
    props.BackgroundColor3 = props.BackgroundColor3 or Theme.Element
    props.TextColor3 = Theme.Text
    props.Font = Theme.FontBold
    props.TextSize = 13
    props.BorderSizePixel = 0
    props.Parent = parent
    return create("TextButton", props, { corner(5) })
end

local function textBox(parent, text, props)
    props.Text = text
    props.BackgroundColor3 = Theme.Element
    props.TextColor3 = Theme.Text
    props.Font = Theme.Font
    props.TextSize = 13
    props.ClearTextOnFocus = false
    props.BorderSizePixel = 0
    props.Parent = parent
    return create("TextBox", props, { corner(5) })
end

local function toggle(label, initial, onChange)
    local r = row(24)
    rowLabel(r, label, 56)
    local value = initial
    local button = smallButton(r, "", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(48, 22),
        AutoButtonColor = false,
    })
    local function apply()
        button.Text = value and "ON" or "OFF"
        button.BackgroundColor3 = value and Theme.On or Theme.Off
    end
    apply()
    connect(button.MouseButton1Click, function()
        value = not value
        apply()
        onChange(value)
    end)
end

toggle("Auto skip waves", settings.enabled, function(value)
    settings.enabled = value
    lastVote = os.clock() -- the first vote comes one full delay after switching on
    setStatus(value and "Starting..." or "Auto skip off")
end)

local delayRow = row(24)
rowLabel(delayRow, "Delay (seconds)", 96)
local plusButton = smallButton(delayRow, "+", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, 0, 0.5, 0),
    Size = UDim2.fromOffset(22, 22),
})
local delayBox = textBox(delayRow, "", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -25, 0.5, 0),
    Size = UDim2.fromOffset(40, 22),
})
local minusButton = smallButton(delayRow, "-", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -68, 0.5, 0),
    Size = UDim2.fromOffset(22, 22),
})

local function setDelay(value)
    value = math.clamp(math.floor(value * 10 + 0.5) / 10, 0, 60)
    settings.delay = value
    delayBox.Text = ("%.1f"):format(value)
end
setDelay(settings.delay)

connect(plusButton.MouseButton1Click, function()
    setDelay(settings.delay + 0.5)
end)
connect(minusButton.MouseButton1Click, function()
    setDelay(settings.delay - 0.5)
end)
connect(delayBox.FocusLost, function()
    setDelay(tonumber(delayBox.Text) or settings.delay)
end)

toggle("Hide \"voting too fast\"", settings.hideSpam, function(value)
    settings.hideSpam = value
    refreshAll()
end)

local skipNowButton = smallButton(row(28), "Skip Now", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = Theme.Accent,
})
connect(skipNowButton.MouseButton1Click, function()
    if voting then
        return
    end
    vote()
    if not settings.enabled then
        setStatus("Voting...")
    end
end)

statusLabel = create("TextLabel", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundTransparency = 1,
    Text = "",
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = Theme.SubText,
    Font = Theme.Font,
    TextSize = 12,
    Parent = body,
})
setStatus("Auto skip off")

-- dragging
local dragging, dragStart, startPosition

connect(topbar.InputBegan, function(input)
    if isPointer(input) then
        dragging = true
        dragStart = input.Position
        startPosition = window.Position
    end
end)
connect(UserInputService.InputEnded, function(input)
    if isPointer(input) then
        dragging = false
    end
end)
connect(UserInputService.InputChanged, function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        window.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end)

connect(collapseButton.MouseButton1Click, function()
    body.Visible = not body.Visible
    collapseButton.Text = body.Visible and "-" or "+"
end)

connect(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == CONFIG.toggleKey then
        gui.Enabled = not gui.Enabled
    end
end)

local function unload()
    if not alive then
        return
    end
    alive = false
    settings.enabled = false
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    for label in pairs(suppressed) do
        release(label)
    end
    gui:Destroy()
    if env.WaveSkipperUnload == unload then
        env.WaveSkipperUnload = nil
    end
end

env.WaveSkipperUnload = unload
connect(closeButton.MouseButton1Click, unload)
