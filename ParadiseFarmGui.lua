--[[
    Paradise Farm
    - RightShift toggles the window, drag the title bar to move it.
    - Farm tab: walks to the nearest enemy in your current map, sends your shadows at it
      the same way clicking it does, clicks for damage, and collects leftover drops.
    - If you switch on the game's own Auto Attack / Auto Click buttons, this script leaves
      that job to them and only walks.
    - Summon tab: opens the star for you (one star or multi), walks to it first, and stops
      when your unit inventory is full or the server stops answering. Auto farm pauses
      while auto summon is walking.
    - Re-executing the script unloads the previous copy first.
]]
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.ParadiseFarmUnload then
    pcall(env.ParadiseFarmUnload)
end

-- require()-ing a game ModuleScript can leave the thread at a lower identity,
-- after which anything connected later can no longer touch the GUI ("lacking
-- capability Plugin"). Remember the starting identity and put it back.
local getIdentity = getthreadidentity or getidentity or get_thread_identity
local setIdentity = setthreadidentity or setidentity or set_thread_identity
local startIdentity = getIdentity and getIdentity()
local function restoreIdentity()
    if setIdentity and startIdentity then
        pcall(setIdentity, startIdentity)
    end
end

--------------------------------------------------------------------------------
-- UI library
--------------------------------------------------------------------------------

local Theme = {
    Background = Color3.fromRGB(22, 22, 28),
    Topbar = Color3.fromRGB(30, 30, 38),
    Element = Color3.fromRGB(36, 36, 46),
    ElementHover = Color3.fromRGB(48, 48, 60),
    Accent = Color3.fromRGB(110, 90, 255),
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

local function tween(inst, props, time)
    TweenService:Create(inst, TweenInfo.new(time or 0.15, Enum.EasingStyle.Quad), props):Play()
end

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local Window = {}
Window.__index = Window

local Tab = {}
Tab.__index = Tab

function Window.new(title)
    local self = setmetatable({ tabs = {}, connections = {}, activeTab = nil }, Window)

    local gui = create("ScreenGui", {
        Name = "ParadiseFarmGui",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 999,
    })
    self.gui = gui

    local main = create("Frame", {
        Name = "Main",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(500, 340),
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = gui,
    }, { corner(8) })
    self.main = main

    -- Title bar
    local topbar = create("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = Theme.Topbar,
        BorderSizePixel = 0,
        Parent = main,
    })

    create("TextLabel", {
        Text = title,
        Font = Theme.FontBold,
        TextSize = 14,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -80, 1, 0),
        Parent = topbar,
    })

    local function topButton(text, offset)
        return create("TextButton", {
            Text = text,
            Font = Theme.FontBold,
            TextSize = 16,
            TextColor3 = Theme.SubText,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, offset, 0, 0),
            Size = UDim2.fromOffset(32, 32),
            Parent = topbar,
        })
    end
    local minimize = topButton("-", -32)
    local close = topButton("x", 0)

    -- Body
    local body = create("Frame", {
        Position = UDim2.fromOffset(0, 32),
        Size = UDim2.new(1, 0, 1, -32),
        BackgroundTransparency = 1,
        Parent = main,
    })

    local sidebar = create("Frame", {
        Size = UDim2.new(0, 110, 1, -24),
        BackgroundTransparency = 1,
        Parent = body,
    }, {
        create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
        create("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
    })
    self.sidebar = sidebar

    self.pages = create("Frame", {
        Position = UDim2.fromOffset(118, 8),
        Size = UDim2.new(1, -126, 1, -40),
        BackgroundTransparency = 1,
        Parent = body,
    })

    self.footer = create("TextLabel", {
        Text = "Ready",
        Font = Theme.Font,
        TextSize = 12,
        TextColor3 = Theme.SubText,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 12, 1, -24),
        Size = UDim2.new(1, -24, 0, 24),
        Parent = body,
    })

    -- Dragging
    local dragging, dragStart, startPos
    self:Connect(topbar.InputBegan, function(input)
        if isPointer(input) then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end)
    self:Connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
    self:Connect(UserInputService.InputEnded, function(input)
        if isPointer(input) then
            dragging = false
        end
    end)

    -- Minimize / close / hotkey
    local minimized = false
    self:Connect(minimize.MouseButton1Click, function()
        minimized = not minimized
        body.Visible = not minimized
        tween(main, { Size = UDim2.fromOffset(500, minimized and 32 or 340) }, 0.2)
    end)
    self:Connect(close.MouseButton1Click, function()
        self:Destroy()
    end)
    self:Connect(UserInputService.InputBegan, function(input, processed)
        if not processed and input.KeyCode == Enum.KeyCode.RightShift then
            gui.Enabled = not gui.Enabled
        end
    end)

    -- Parent last so executors that hide GUIs get a fully built tree
    if typeof(gethui) == "function" then
        gui.Parent = gethui()
    elseif not pcall(function() gui.Parent = game:GetService("CoreGui") end) then
        gui.Parent = player:WaitForChild("PlayerGui")
    end

    return self
end

function Window:Connect(signal, fn)
    local connection = signal:Connect(function(...)
        restoreIdentity()
        return fn(...)
    end)
    table.insert(self.connections, connection)
    return connection
end

-- Runs fn(dt) once per frame from a thread started by the script itself.
-- RunService.Heartbeat callbacks run with fewer permissions in some executors
-- (they can't touch this GUI: "lacking capability Plugin"), while a loop that
-- waits on Heartbeat keeps the permissions of the thread that started it.
function Window:Loop(fn)
    local alive = true
    table.insert(self.connections, { Disconnect = function() alive = false end })
    task.spawn(function()
        while alive do
            local dt = RunService.Heartbeat:Wait()
            restoreIdentity()
            local ok, err = pcall(fn, dt)
            if not ok then
                warn("[Paradise Farm] loop stopped: " .. tostring(err))
                break
            end
        end
    end)
end

function Window:Notify(text, duration)
    -- Callers often run a game function first, which can drop the thread's identity
    restoreIdentity()
    self.footer.Text = text
    local token = {}
    self.notifyToken = token
    task.delay(duration or 3, function()
        if self.notifyToken == token and self.footer.Parent then
            self.footer.Text = "Ready"
        end
    end)
end

function Window:Destroy()
    for _, connection in ipairs(self.connections) do
        connection:Disconnect()
    end
    table.clear(self.connections)
    self.gui:Destroy()
    if self.onDestroy then
        self.onDestroy()
    end
end

function Window:AddTab(name)
    local button = create("TextButton", {
        Text = name,
        Font = Theme.Font,
        TextSize = 13,
        TextColor3 = Theme.SubText,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 28),
        LayoutOrder = #self.tabs + 1,
        Parent = self.sidebar,
    }, { corner(6) })

    local page = create("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(),
        Visible = false,
        Parent = self.pages,
    }, {
        create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local tab = setmetatable({ window = self, button = button, page = page, order = 0 }, Tab)
    table.insert(self.tabs, tab)

    self:Connect(button.MouseButton1Click, function()
        self:SelectTab(tab)
    end)
    if not self.activeTab then
        self:SelectTab(tab)
    end
    return tab
end

function Window:SelectTab(selected)
    self.activeTab = selected
    for _, tab in ipairs(self.tabs) do
        local active = tab == selected
        tab.page.Visible = active
        tab.button.TextColor3 = active and Theme.Text or Theme.SubText
        tween(tab.button, { BackgroundTransparency = active and 0 or 1 })
    end
end

-- Elements ---------------------------------------------------------------

function Tab:_row(height)
    self.order += 1
    return create("Frame", {
        Size = UDim2.new(1, -8, 0, height),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        LayoutOrder = self.order,
        Parent = self.page,
    }, { corner(6) })
end

function Tab:_label(parent, text, size, position, align)
    return create("TextLabel", {
        Text = text,
        Font = Theme.Font,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = align or Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Position = position,
        Size = size,
        Parent = parent,
    })
end

function Tab:AddSection(text)
    self.order += 1
    return create("TextLabel", {
        Text = string.upper(text),
        Font = Theme.FontBold,
        TextSize = 11,
        TextColor3 = Theme.Accent,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -8, 0, 18),
        LayoutOrder = self.order,
        Parent = self.page,
    })
end

function Tab:AddLabel(text)
    local row = self:_row(28)
    row.AutomaticSize = Enum.AutomaticSize.Y
    create("UIPadding", {
        PaddingTop = UDim.new(0, 6),
        PaddingBottom = UDim.new(0, 6),
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
        Parent = row,
    })
    local label = create("TextLabel", {
        Text = text,
        Font = Theme.Font,
        TextSize = 13,
        TextColor3 = Theme.SubText,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.fromScale(1, 0),
        Parent = row,
    })
    return { SetText = function(_, value) label.Text = value end }
end

function Tab:AddButton(text, callback)
    local row = self:_row(32)
    local button = create("TextButton", {
        Text = text,
        Font = Theme.Font,
        TextSize = 13,
        TextColor3 = Theme.Text,
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Parent = row,
    })
    self.window:Connect(button.MouseEnter, function() tween(row, { BackgroundColor3 = Theme.ElementHover }) end)
    self.window:Connect(button.MouseLeave, function() tween(row, { BackgroundColor3 = Theme.Element }) end)
    self.window:Connect(button.MouseButton1Click, function()
        task.spawn(callback)
    end)
end

function Tab:AddToggle(text, default, callback)
    local value = default and true or false
    local row = self:_row(32)
    self:_label(row, text, UDim2.new(1, -60, 1, 0), UDim2.fromOffset(10, 0))

    local pill = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(34, 18),
        BackgroundColor3 = Theme.ElementHover,
        BorderSizePixel = 0,
        Parent = row,
    }, { corner(9) })
    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 2, 0.5, 0),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Theme.Text,
        BorderSizePixel = 0,
        Parent = pill,
    }, { corner(7) })
    local button = create("TextButton", {
        Text = "",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Parent = row,
    })

    local function render()
        tween(pill, { BackgroundColor3 = value and Theme.Accent or Theme.ElementHover })
        tween(knob, { Position = UDim2.new(0, value and 18 or 2, 0.5, 0) })
    end
    local function set(newValue, silent)
        value = newValue and true or false
        render()
        if not silent and callback then
            task.spawn(callback, value)
        end
    end

    self.window:Connect(button.MouseButton1Click, function() set(not value) end)
    set(value, true)
    return { Set = function(_, v) set(v) end, Get = function() return value end }
end

function Tab:AddSlider(text, min, max, default, step, callback)
    step = step or 1
    local value = default
    local row = self:_row(46)
    self:_label(row, text, UDim2.new(1, -80, 0, 22), UDim2.fromOffset(10, 2))
    local valueLabel = self:_label(row, tostring(value), UDim2.fromOffset(60, 22), UDim2.new(1, -70, 0, 2), Enum.TextXAlignment.Right)
    valueLabel.TextColor3 = Theme.SubText

    local bar = create("Frame", {
        Position = UDim2.new(0, 10, 1, -14),
        Size = UDim2.new(1, -20, 0, 6),
        BackgroundColor3 = Theme.ElementHover,
        BorderSizePixel = 0,
        Parent = row,
    }, { corner(3) })
    local fill = create("Frame", {
        Size = UDim2.fromScale((value - min) / (max - min), 1),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = bar,
    }, { corner(3) })

    local function set(newValue, silent)
        value = math.clamp(math.round(newValue / step) * step, min, max)
        valueLabel.Text = tostring(value)
        fill.Size = UDim2.fromScale((value - min) / (max - min), 1)
        if not silent and callback then
            task.spawn(callback, value)
        end
    end
    local function fromInput(input)
        local alpha = math.clamp((input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        set(min + (max - min) * alpha)
    end

    local sliding = false
    self.window:Connect(bar.InputBegan, function(input)
        if isPointer(input) then
            sliding = true
            fromInput(input)
        end
    end)
    self.window:Connect(UserInputService.InputChanged, function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            fromInput(input)
        end
    end)
    self.window:Connect(UserInputService.InputEnded, function(input)
        if isPointer(input) then
            sliding = false
        end
    end)

    return { Set = function(_, v) set(v) end, Get = function() return value end }
end

function Tab:AddTextbox(text, default, placeholder, callback)
    local row = self:_row(32)
    self:_label(row, text, UDim2.new(0.4, 0, 1, 0), UDim2.fromOffset(10, 0))
    local box = create("TextBox", {
        Text = default or "",
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = Theme.SubText,
        Font = Theme.Font,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        BackgroundColor3 = Theme.ElementHover,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0.4, 0, 0.5, 0),
        Size = UDim2.new(0.6, -10, 0, 22),
        Parent = row,
    }, {
        corner(4),
        create("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
    })
    -- Fires when the box loses focus (Enter or clicking away)
    self.window:Connect(box.FocusLost, function()
        if callback then
            task.spawn(callback, box.Text)
        end
    end)
    return {
        Get = function() return box.Text end,
        Set = function(_, v) box.Text = v end,
    }
end

-- Expands inline when clicked. options is a list of strings.
function Tab:AddDropdown(text, options, default, callback)
    local VISIBLE_ROWS, ROW_HEIGHT = 6, 24
    local value = default
    local open = false
    local row = self:_row(32)
    row.ClipsDescendants = true
    self:_label(row, text, UDim2.new(0.4, 0, 0, 32), UDim2.fromOffset(10, 0))

    local selected = create("TextLabel", {
        Text = "",
        Font = Theme.Font,
        TextSize = 13,
        TextColor3 = Theme.SubText,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        Position = UDim2.new(0.4, 0, 0, 0),
        Size = UDim2.new(0.6, -10, 0, 32),
        Parent = row,
    })
    local header = create("TextButton", {
        Text = "",
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 32),
        Parent = row,
    })
    local list = create("ScrollingFrame", {
        Position = UDim2.fromOffset(6, 36),
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(),
        Parent = row,
    }, {
        corner(4),
        create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local function layout()
        local listHeight = math.min(#options, VISIBLE_ROWS) * ROW_HEIGHT
        list.Size = UDim2.new(1, -12, 0, listHeight)
        row.Size = UDim2.new(1, -8, 0, open and (36 + listHeight + 6) or 32)
        selected.Text = (value and tostring(value) or "-") .. (open and "  ^" or "  v")
    end

    local function set(newValue, silent)
        value = newValue
        open = false
        layout()
        if not silent and callback then
            task.spawn(callback, value)
        end
    end

    local function rebuild()
        for _, child in ipairs(list:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
        for index, option in ipairs(options) do
            local button = create("TextButton", {
                Text = tostring(option),
                Font = Theme.Font,
                TextSize = 12,
                TextColor3 = Theme.Text,
                BackgroundColor3 = Theme.ElementHover,
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
                LayoutOrder = index,
                Parent = list,
            })
            self.window:Connect(button.MouseEnter, function() tween(button, { BackgroundTransparency = 0 }) end)
            self.window:Connect(button.MouseLeave, function() tween(button, { BackgroundTransparency = 1 }) end)
            self.window:Connect(button.MouseButton1Click, function() set(option) end)
        end
        layout()
    end

    self.window:Connect(header.MouseButton1Click, function()
        open = not open
        layout()
    end)

    rebuild()
    return {
        Get = function() return value end,
        Set = function(_, v) set(v) end,
        SetOptions = function(_, newOptions, keepSelection)
            options = newOptions
            if not (keepSelection and table.find(options, value)) then
                value = options[1]
            end
            open = false
            rebuild()
        end,
    }
end

--------------------------------------------------------------------------------
-- Features
--------------------------------------------------------------------------------

local window = Window.new("Paradise Farm")
env.ParadiseFarmUnload = function() window:Destroy() end
window.onDestroy = function()
    env.ParadiseFarmUnload = nil
end

-- The game's client module (the table PlayerScripts.Paradise_Client returns).
-- Bridge:FireSelf / Bridge:FireServer are the same calls the game's own UI makes.
local function loadGame()
    local scripts = player:WaitForChild("PlayerScripts", 10)
    local module = scripts and scripts:WaitForChild("Paradise_Client", 10)
    if not module then
        return nil
    end
    local ok, result = pcall(require, module)
    restoreIdentity()
    if ok and type(result) == "table" then
        return result
    end
    warn("[Paradise Farm] couldn't require Paradise_Client: " .. tostring(result))
end

local Game = loadGame()
local VirtualUser = game:GetService("VirtualUser")

-- Observed protocol (Bridge is ReplicatedStorage.Remotes.Bridge):
--   click an enemy  -> Bridge:FireSelf("Shadows", "Attack", "Interact", "World", enemyObject)
--                      which toggles Attack / Retreat for your shadows and sends
--                      Attack_All("World", serverPart) to the server
--   click damage    -> Bridge:FireServer("Shadows", "Attack", "Click")   (~5 per second)
--   leftover drops  -> Bridge:FireServer("General", "Drops", "Collect", dropId)
-- Server enemies are Parts in workspace.Server.Enemies.<Map>; the part carries the
-- attributes ID / Health / MaxHealth / Died. enemyObject = Game.Enemies_Storage.World[ID].

local farm = {
    enabled = false,
    click = true,
    clickDelay = 0.2,
    collect = true,
    antiAfk = true,
    filter = "",
    maxDistance = 500,
    standDistance = 6,
    speed = 120,
    giveUpAfter = 25,
    status = "Idle",
    target = nil,
    targetSince = 0,
    killed = 0,
    skip = setmetatable({}, { __mode = "k" }), -- server part -> os.clock() it is ignored until
    drops = {},                                -- drop id -> { created = os.clock(), tries = 0 }
    nextPick = 0,
    nextInteract = 0,
    nextClick = 0,
    nextCollect = 0,
    nextLabel = 0,
}

-- Auto quest. Storyline progress is Data.Quest[mapName] = { Current, Progress, Active } and
-- Shared.Quest_Utils:Status(Data, giverName) returns questDef, state, status, mapName where
-- status is "locked" | "available" | "active" | "complete" | "finished".
local quest = {
    enabled = false,
    needles = nil, -- exact-name filter on the quest's enemy while auto quest is on
    status = "Off",
    nextCheck = 0,
}

local function getCharacter()
    local char = player.Character
    return char, char and char:FindFirstChildOfClass("Humanoid"), char and char:FindFirstChild("HumanoidRootPart")
end

-- "a, b" -> { "a", "b" } (lowercase), or nil when empty
local function parseNeedles(text)
    local needles = {}
    for piece in string.gmatch(text or "", "[^,]+") do
        piece = string.lower(piece:match("^%s*(.-)%s*$"))
        if piece ~= "" then
            table.insert(needles, piece)
        end
    end
    return #needles > 0 and needles or nil
end

-- Enemies ---------------------------------------------------------------------
local function currentWorld()
    local map = Game and Game.Data and Game.Data.Map
    return type(map) == "string" and map or nil
end

local function enemyFolders()
    local server = workspace:FindFirstChild("Server")
    local enemies = server and server:FindFirstChild("Enemies")
    if not enemies then
        return {}
    end
    local world = currentWorld()
    local folder = world and enemies:FindFirstChild(world)
    return folder and { folder } or enemies:GetChildren()
end

local function isAlive(part)
    if not part.Parent or part:GetAttribute("Died") then
        return false
    end
    local health = part:GetAttribute("Health")
    return health == nil or health > 0
end

-- The client-side enemy object; only exists while the enemy is alive and streamed in
local function enemyObject(part)
    local id = part:GetAttribute("ID")
    local storage = Game and Game.Enemies_Storage and Game.Enemies_Storage.World
    return id ~= nil and storage and storage[id] or nil
end

local function matchesFilter(part, needles)
    if not needles then
        return true
    end
    local name = string.lower(part.Name)
    for _, needle in ipairs(needles) do
        -- "=ant" matches the exact name only (plain "ant" would also match AntiKingi)
        if needle:sub(1, 1) == "=" then
            if name == needle:sub(2) then
                return true
            end
        elseif name:find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function nearestEnemy(origin, now)
    local needles = quest.needles or parseNeedles(farm.filter)
    local best, bestDist
    for _, folder in ipairs(enemyFolders()) do
        for _, part in ipairs(folder:GetChildren()) do
            if part:IsA("BasePart")
                and isAlive(part)
                and not (farm.skip[part] and farm.skip[part] > now)
                and matchesFilter(part, needles)
                and enemyObject(part) then
                local dist = (part.Position - origin).Magnitude
                if dist <= farm.maxDistance and (not bestDist or dist < bestDist) then
                    best, bestDist = part, dist
                end
            end
        end
    end
    return best
end

-- True when every one of your shadows is already set on this enemy. The game's
-- Interact toggles Attack/Retreat, so it must not be sent again in that case.
local function shadowsOn(part)
    local server = workspace:FindFirstChild("Server")
    local shadows = server and server:FindFirstChild("Shadows")
    local mine = shadows and shadows:FindFirstChild(tostring(player.UserId))
    if not mine then
        return false
    end
    local any = false
    for _, shadow in ipairs(mine:GetChildren()) do
        local target = shadow:FindFirstChild("Target_Enemy")
        if target then
            any = true
            if target.Value ~= part then
                return false
            end
        end
    end
    return any
end

-- The game's own Auto Attack / Auto Click buttons (bottom of the HUD) target and
-- click by themselves; when one is on, this script leaves that job to it and
-- only does the walking, so the two never fight over the Attack/Retreat toggle.
local function gameAuto(name)
    return (Game and Game[name] == true) or player:GetAttribute(name) == true
end

-- Movement --------------------------------------------------------------------
-- Steps the character toward goal at farm.speed, facing lookAt horizontally.
local function approach(root, goal, lookAt, dt)
    local delta = goal - root.Position
    local dist = delta.Magnitude
    local position = goal
    if dist > 0.01 and dist > farm.speed * dt then
        position = root.Position + delta.Unit * (farm.speed * dt)
    end
    local flat = Vector3.new(lookAt.X - position.X, 0, lookAt.Z - position.Z)
    if flat.Magnitude > 0.05 then
        root.CFrame = CFrame.lookAt(position, position + flat)
    else
        root.CFrame = CFrame.new(position) * root.CFrame.Rotation
    end
    root.AssemblyLinearVelocity = Vector3.zero
    return dist
end

-- Farm ------------------------------------------------------------------------
local function stepFarm(dt, now)
    if not (Game and Game.Bridge) then
        farm.status = "Paradise_Client not loaded"
        return
    end
    local char, hum, root = getCharacter()
    if not (char and hum and root) or hum.Health <= 0 then
        farm.status = "Waiting for character"
        return
    end

    local target = farm.target
    if target and not (isAlive(target) and enemyObject(target)) then
        if target.Parent and target:GetAttribute("Died") then
            farm.killed += 1
        end
        farm.target = nil
        target = nil
    end
    if target and now - farm.targetSince > farm.giveUpAfter then
        -- Not dying (unreachable or too tanky): leave it for a while
        farm.skip[target] = now + 20
        farm.target = nil
        target = nil
    end
    if not target and now >= farm.nextPick then
        farm.nextPick = now + 0.25
        target = nearestEnemy(root.Position, now)
        if target then
            farm.target = target
            farm.targetSince = now
            farm.nextInteract = 0
        end
    end
    if not target then
        farm.status = "No enemy found in " .. (currentWorld() or "this map")
        return
    end

    -- Stay on whichever side we arrived from, standDistance away
    local enemyPos = target.Position
    local base = enemyPos + Vector3.new(0, 3, 0)
    local flat = Vector3.new(root.Position.X - enemyPos.X, 0, root.Position.Z - enemyPos.Z)
    local away = flat.Magnitude > 0.05 and flat.Unit or Vector3.new(0, 0, 1)
    local dist = (root.Position - enemyPos).Magnitude
    local goal = dist > farm.standDistance + 1.5 and (base + away * farm.standDistance) or root.Position
    approach(root, goal, enemyPos, dt)

    -- Same reach as the game's ClickDetector on enemies (30 studs)
    local autoAttack, autoClick = gameAuto("Auto_Attack"), gameAuto("Auto_Click")
    if dist <= 28 and now >= farm.nextInteract and not autoAttack then
        farm.nextInteract = now + 1
        if not shadowsOn(target) then
            local object = enemyObject(target)
            if object then
                Game.Bridge:FireSelf("Shadows", "Attack", "Interact", "World", object)
            end
        end
    end

    local range = player:GetAttribute("Range")
    if farm.click and not autoClick and dist <= (type(range) == "number" and range or 12) + 3 and now >= farm.nextClick then
        farm.nextClick = now + farm.clickDelay
        Game.Bridge:FireServer("Shadows", "Attack", "Click")
    end

    local note = (autoAttack or autoClick) and " [game auto: " .. (autoAttack and "attack " or "") .. (autoClick and "click" or "") .. "]" or ""
    local health, maxHealth = target:GetAttribute("Health"), target:GetAttribute("MaxHealth")
    if type(health) == "number" and type(maxHealth) == "number" then
        farm.status = string.format("Fighting %s (%.0f/%.0f hp, %.0f studs)%s", target.Name, health, maxHealth, dist, note)
    else
        farm.status = string.format("Fighting %s (%.0f studs)%s", target.Name, dist, note)
    end
end

-- Star summon, from the game's own Star_Summon UI script:
--   one star   -> Bridge:FireServer("General", "Stars", "Open",  worldName)   (E key)
--   multi open -> Bridge:FireServer("General", "Stars", "Multi", worldName)   (Q key)
-- The player attribute "Star_Opening" is true while a summon plays out; the game never
-- sends another until it is false. The reveal arrives as
-- UserInterface/Star_Animation/Play { { shadowName, rarity }, ... }. The star is
-- workspace.Server.Stars.<Map>.Star and the game sets Game.NearStar when you are close
-- enough to use it. The game's own auto summon stops when the unit inventory is full:
-- 50 slots (250 with the Extra Inventory Slots pass) plus "Inventory" achievement perks.
local STAR_WORLDS = { "Solo City", "Ninja Village", "Marine Island", "Dragon World" }
local SUMMON_ONE, SUMMON_MULTI = "Open (1 star)", "Multi"

local summon = {
    enabled = false,
    world = "Solo City",
    mode = SUMMON_ONE,
    walk = true,
    delay = 0.5,
    sent = 0,
    got = 0,
    misses = 0,
    waiting = false,
    sentAt = 0,
    nextSend = 0,
    last = "-",
    status = "Off",
}

do
    local world = currentWorld()
    if world and table.find(STAR_WORLDS, world) then
        summon.world = world
    end
end

-- Units owned vs. slots available
local function inventoryUsage()
    local data = Game and Game.Data
    if not data then
        return 0, 50
    end
    local slots = (data.Gamepasses and data.Gamepasses["Extra Inventory Slots"]) and 250 or 50
    local achievements = Game.Shared and Game.Shared.Achievements
    if type(data.Achievements) == "table" and type(achievements) == "table" then
        for name, done in pairs(data.Achievements) do
            local perks = done and achievements[name] and achievements[name].Perks
            if type(perks) == "table" and type(perks.Inventory) == "number" then
                slots += perks.Inventory
            end
        end
    end
    local count = 0
    if type(data.Shadows) == "table" then
        for _ in pairs(data.Shadows) do
            count += 1
        end
    end
    return count, slots
end

local function starPosition(world)
    local server = workspace:FindFirstChild("Server")
    local stars = server and server:FindFirstChild("Stars")
    local folder = stars and stars:FindFirstChild(world)
    local star = folder and folder:FindFirstChild("Star")
    if not star then
        return nil
    end
    if star:IsA("Model") then
        return star:GetPivot().Position
    elseif star:IsA("BasePart") then
        return star.Position
    end
end

local function onSummoned(results)
    summon.got += 1
    summon.waiting = false
    summon.misses = 0
    local names = {}
    if type(results) == "table" then
        for _, entry in ipairs(results) do
            if type(entry) == "table" then
                table.insert(names, string.format("%s (%s)", tostring(entry[1]), tostring(entry[2])))
            end
        end
    end
    summon.last = #names > 0 and table.concat(names, ", ") or "?"
end

local function sendSummon()
    summon.sent += 1
    summon.waiting = true
    summon.sentAt = os.clock()
    Game.Bridge:FireServer("General", "Stars", summon.mode == SUMMON_MULTI and "Multi" or "Open", summon.world)
end

local function stepSummon(now, dt)
    if not summon.enabled then
        return
    end
    if not (Game and Game.Bridge) then
        summon.status = "Paradise_Client not loaded"
        return
    end

    if Game.Auto_Summon then
        summon.status = "The game's own auto summon is running"
        return
    end

    local opening = player:GetAttribute("Star_Opening")
    if summon.waiting and opening then
        summon.waiting = false -- the server accepted it
        summon.misses = 0
    end
    if summon.waiting then
        if now - summon.sentAt < 5 then
            summon.status = "Waiting for the server..."
            return
        end
        summon.waiting = false
        summon.misses += 1
        if summon.misses >= 3 then
            summon.enabled = false
            summon.status = "Stopped: no reply to 3 opens (not enough currency, or too far from the star?)"
            return
        end
    end
    if opening then
        summon.status = "Opening..."
        return
    end

    local count, slots = inventoryUsage()
    if count >= slots then
        summon.enabled = false
        summon.status = string.format("Stopped: unit inventory is full (%d/%d)", count, slots)
        return
    end

    if summon.walk and not Game.NearStar then
        local position = starPosition(summon.world)
        local _, hum, root = getCharacter()
        if position and root and hum and hum.Health > 0 then
            local goal = position + Vector3.new(4, 3, 0)
            if (root.Position - goal).Magnitude > 3 then
                approach(root, goal, position, dt)
                summon.status = "Walking to the " .. summon.world .. " star"
                return
            end
        end
    end

    summon.status = "Summoning at " .. summon.world
    if now >= summon.nextSend then
        summon.nextSend = now + summon.delay
        sendSummon()
    end
end

-- Auto quest: while a storyline quest is available or active, the farm only hunts that
-- quest's enemy. Accepting and turning in the quest still happens at the quest giver.
local function questGiverFor(world)
    local npcs = Game and Game.Shared and Game.Shared.Quest_Data and Game.Shared.Quest_Data.Npcs
    if type(npcs) ~= "table" then
        return nil
    end
    for giver, mapName in pairs(npcs) do
        if mapName == world then
            return giver
        end
    end
end

local function stepQuest(now)
    if not quest.enabled or now < quest.nextCheck then
        return
    end
    quest.nextCheck = now + 0.5

    local utils = Game and Game.Shared and Game.Shared.Quest_Utils
    local world = currentWorld()
    local giver = world and questGiverFor(world)
    if not (utils and Game.Data and giver) then
        quest.needles = nil
        quest.status = "No storyline quest in " .. (world or "this map")
        return
    end

    local ok, def, state, status = pcall(utils.Status, utils, Game.Data, giver)
    if not ok then
        quest.needles = nil
        quest.status = "Quest check failed: " .. tostring(def)
        return
    end

    quest.needles = (status == "active" or status == "available") and { "=" .. string.lower(def.Enemy) } or nil
    if status == "locked" then
        quest.status = "Storyline locked: finish the previous map's quests first"
    elseif status == "finished" or not def then
        quest.status = "All " .. world .. " storyline quests are done"
    else
        local progress = tonumber(state and state.Progress) or 0
        if status == "available" then
            quest.status = string.format("Quest %d \"%s\" is available - accept it from the quest giver\nKill %d %s (hunting them already)",
                def.Id, def.Title, def.Required, def.Enemy)
        elseif status == "active" then
            quest.status = string.format("Quest %d \"%s\": %d/%d %s", def.Id, def.Title, progress, def.Required, def.Enemy)
        else
            quest.status = string.format("Quest %d \"%s\" is complete (%d/%d) - turn it in at the quest giver",
                def.Id, def.Title, progress, def.Required)
        end
    end
end

-- Drops: the game collects its own drops about 2.5 s after they appear, so only
-- ones still around after 4 s are collected here.
local bridgeRemote
do
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    bridgeRemote = remotes and remotes:FindFirstChild("Bridge")
end
if bridgeRemote then
    window:Connect(bridgeRemote.OnClientEvent, function(category, group, name, id)
        if category == "General" and group == "Drops" and type(id) == "string" then
            if name == "Create" then
                farm.drops[id] = { created = os.clock(), tries = 0 }
            elseif name == "Destroy" then
                farm.drops[id] = nil
            end
        elseif category == "UserInterface" and group == "Star_Animation" and name == "Play" then
            onSummoned(id)
        end
    end)
end

local function stepCollect(now)
    if not (farm.collect and Game and Game.Bridge) or now < farm.nextCollect then
        return
    end
    for id, drop in pairs(farm.drops) do
        if now - drop.created >= 4 then
            farm.nextCollect = now + 0.15
            drop.tries += 1
            if drop.tries > 3 then
                farm.drops[id] = nil
            else
                drop.created = now - 2 -- retry in about 2 s if it is still there
                Game.Bridge:FireServer("General", "Drops", "Collect", id)
            end
            return
        end
    end
end

-- Anti-AFK (Roblox kicks after 20 minutes without input)
window:Connect(player.Idled, function()
    if farm.antiAfk then
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end
end)

-- UI ----------------------------------------------------------------------------
local farmTab = window:AddTab("Farm")

farmTab:AddSection("Auto farm")
local farmToggle = farmTab:AddToggle("Auto farm", false, function(on)
    farm.enabled = on
    farm.target = nil
    farm.nextPick = 0
    if not on and not string.find(farm.status, "^Stopped") then
        farm.status = "Idle"
    end
end)
farmTab:AddToggle("Auto click (click damage)", true, function(on)
    farm.click = on
end)
farmTab:AddToggle("Collect leftover drops", true, function(on)
    farm.collect = on
end)
farmTab:AddToggle("Anti-AFK", true, function(on)
    farm.antiAfk = on
end)
farmTab:AddTextbox("Enemy filter", "", "blank = any, =ant exact (a, b)", function(text)
    farm.filter = text
end)

farmTab:AddSection("Tuning")
farmTab:AddSlider("Click delay (ms)", 180, 600, 200, 10, function(value)
    farm.clickDelay = value / 1000
end)
farmTab:AddSlider("Max enemy distance", 50, 1500, 500, 25, function(value)
    farm.maxDistance = value
end)
farmTab:AddSlider("Stand distance", 2, 12, 6, 1, function(value)
    farm.standDistance = value
end)
farmTab:AddSlider("Move speed (studs/s)", 30, 250, 120, 5, function(value)
    farm.speed = value
end)
farmTab:AddSlider("Give up on an enemy after (s)", 10, 60, 25, 5, function(value)
    farm.giveUpAfter = value
end)

farmTab:AddSection("Tools")
farmTab:AddButton("Skip current enemy", function()
    if farm.target then
        farm.skip[farm.target] = os.clock() + 60
        farm.target = nil
        window:Notify("Skipped")
    else
        window:Notify("No current enemy")
    end
end)
farmTab:AddButton("Print enemies in this map", function()
    local _, _, root = getCharacter()
    if not root then
        return window:Notify("No character")
    end
    local rows = {}
    for _, folder in ipairs(enemyFolders()) do
        for _, part in ipairs(folder:GetChildren()) do
            if part:IsA("BasePart") and isAlive(part) then
                local dist = (part.Position - root.Position).Magnitude
                table.insert(rows, {
                    dist = dist,
                    text = string.format("%-22s hp %s/%s  %.0f studs%s",
                        part.Name, tostring(part:GetAttribute("Health")), tostring(part:GetAttribute("MaxHealth")),
                        dist, enemyObject(part) and "" or "  (not streamed in)"),
                })
            end
        end
    end
    table.sort(rows, function(a, b) return a.dist < b.dist end)
    print(string.format("[Paradise Farm] %d enemies in %s, nearest first:", #rows, currentWorld() or "?"))
    for index = 1, math.min(#rows, 25) do
        print("  " .. rows[index].text)
    end
    window:Notify(#rows .. " enemies printed to the console")
end)

farmTab:AddSection("Status")
local statusLabel = farmTab:AddLabel("Idle")

-- Quest tab -------------------------------------------------------------------
local questTab = window:AddTab("Quest")

questTab:AddSection("Auto quest")
questTab:AddToggle("Auto quest (hunt the quest's enemy)", false, function(on)
    quest.enabled = on
    quest.needles = nil
    quest.nextCheck = 0
    quest.status = on and "Checking..." or "Off"
    if on and not farm.enabled then
        farmToggle:Set(true)
    end
end)
questTab:AddLabel("Turns Auto farm on and points it at the enemy of your current storyline quest "
    .. "(exact name). Accepting and turning in quests is still done at the quest giver.")

questTab:AddSection("Status")
local questLabel = questTab:AddLabel("Off")

-- Summon tab ------------------------------------------------------------------
local summonTab = window:AddTab("Summon")

summonTab:AddSection("Star summon")
local summonToggle = summonTab:AddToggle("Auto summon", false, function(on)
    summon.enabled = on
    summon.waiting = false
    summon.misses = 0
    summon.nextSend = 0
    summon.status = on and "Starting" or "Off"
end)
summonTab:AddDropdown("Star", STAR_WORLDS, summon.world, function(choice)
    summon.world = choice
end)
summonTab:AddDropdown("Open", { SUMMON_ONE, SUMMON_MULTI }, summon.mode, function(choice)
    summon.mode = choice
end)
summonTab:AddToggle("Walk to the star first", true, function(on)
    summon.walk = on
end)
summonTab:AddSlider("Minimum delay between opens (s)", 0.25, 5, 0.5, 0.25, function(value)
    summon.delay = value
end)
summonTab:AddButton("Open star once", function()
    if not (Game and Game.Bridge) then
        return window:Notify("Paradise_Client not loaded")
    end
    if player:GetAttribute("Star_Opening") then
        return window:Notify("A summon is already playing")
    end
    sendSummon()
    restoreIdentity()
    window:Notify("Sent: " .. summon.mode .. " at " .. summon.world)
end)

summonTab:AddSection("Status")
local summonLabel = summonTab:AddLabel("Off")

window:Loop(function(dt)
    local now = os.clock()
    if farm.enabled and summon.enabled and summon.walk then
        -- Both move the character, so the summon gets it while it runs
        farm.status = "Paused while auto summon runs"
    elseif farm.enabled then
        local ok, err = pcall(stepFarm, dt, now)
        restoreIdentity()
        if not ok then
            farm.enabled = false
            farmToggle:Set(false)
            farm.status = "Stopped: " .. tostring(err)
            warn("[Paradise Farm] farm stopped: " .. tostring(err))
            window:Notify("Farm stopped (see console)", 8)
        end
    end
    pcall(stepCollect, now)
    pcall(stepQuest, now)
    local summoning = summon.enabled
    pcall(stepSummon, now, dt)
    -- stepFarm / stepCollect / stepSummon call game functions; get the GUI permissions back
    restoreIdentity()
    if summoning and not summon.enabled then
        summonToggle:Set(false)
        window:Notify("Auto summon stopped", 6)
    end
    if now >= farm.nextLabel then
        farm.nextLabel = now + 0.4
        statusLabel:SetText(string.format("%s - %s\nKilled: %d", farm.enabled and "ON" or "OFF", farm.status, farm.killed))
        questLabel:SetText(quest.status)
        local units, slots = inventoryUsage()
        summonLabel:SetText(string.format("%s\nOpens sent: %d   revealed: %d   units: %d/%d\nLast: %s",
            summon.status, summon.sent, summon.got, units, slots, summon.last))
    end
end)

if not Game then
    window:Notify("Paradise_Client not found - farming disabled", 8)
end
