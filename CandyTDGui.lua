--[[
    Candy TD GUI
    A control panel for the Candy TD match client (the script that builds ReplicatedStorage.CandyTD's match UI).
    RightShift toggles the window, drag the title bar to move it, "-" collapses it, "x" unloads it.
    Re-executing the script unloads the previous copy first.

    HOW IT WORKS
      It finds the running match in memory (needs an executor with getgc) and then only sends the same requests the
      game's own buttons send: start / upgrade / target / again / next through MatchNet.request, and placing through
      MatchNet.place after loading the hero the way the game does. The server still decides everything (money, costs,
      caps, cooldowns). Nothing here edits money, lives or gems.

    MATCH TAB    status, auto start waves, skip the wave countdown, auto play again / next stage when the match ends
    HEROES TAB   auto place (spots beside the road that cover the most of it), auto upgrade, set targeting
    MISC TAB     anti AFK, print match info to the console, rescan, unload

    Everything is off by default except Anti AFK.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.CandyTDGuiUnload then
    pcall(env.CandyTDGuiUnload)
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
        Name = "CandyTDGui",
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
                warn("[Candy TD GUI] loop stopped: " .. tostring(err))
                break
            end
        end
    end)
end

function Window:Notify(text, duration)
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
-- Candy TD
--------------------------------------------------------------------------------

local window = Window.new("Candy TD")
local alive = true
table.insert(window.connections, { Disconnect = function() alive = false end })
env.CandyTDGuiUnload = function() window:Destroy() end
window.onDestroy = function()
    env.CandyTDGuiUnload = nil
end

local CandyTD = ReplicatedStorage:FindFirstChild("CandyTD")
if not CandyTD then
    window:AddTab("Candy TD"):AddLabel(
        "ReplicatedStorage.CandyTD wasn't found, so this isn't the Candy TD game (or it hasn't loaded yet). "
        .. "Re-execute once you are inside a match."
    )
    do return end
end

-- The game's own modules (already required by its client script, so require() hands back the cached tables).
local function loadModule(name)
    local module = CandyTD:FindFirstChild(name)
    if not module then
        return nil
    end
    local ok, result = pcall(require, module)
    restoreIdentity()
    return ok and result or nil
end

local ToonKit = loadModule("ToonKit")
local Targeting = loadModule("Targeting")
local WORLD = (ToonKit and tonumber(ToonKit.WORLD)) or 3 -- studs per game unit; only used to size the hero range when scoring spots

--------------------------------------------------------------------------------
-- Finding the running match
--
-- The game's client script keeps everything in locals, but it hands one table around (MATCH, with .ctx and .net on it).
-- It is found once in memory by its shape, then used through the same calls the game's own buttons make.
--------------------------------------------------------------------------------

local MATCH, ctx, net
local lastScan = -10

local function matchAlive()
    return MATCH ~= nil and ctx ~= nil and net ~= nil and ctx.gui ~= nil and ctx.gui.Parent ~= nil
end

local function discover()
    if typeof(getgc) ~= "function" then
        return false, "this executor has no getgc"
    end
    local ok, objects = pcall(getgc, true)
    if not ok or type(objects) ~= "table" then
        return false, "getgc failed"
    end
    for _, obj in ipairs(objects) do
        if type(obj) == "table"
            and rawget(obj, "pickHero") ~= nil
            and rawget(obj, "slots") ~= nil
            and type(rawget(obj, "net")) == "table"
            and type(rawget(obj, "ctx")) == "table"
        then
            local candidate = rawget(obj, "ctx")
            local gui = rawget(candidate, "gui")
            if typeof(gui) == "Instance" and gui.Parent ~= nil
                and type(rawget(candidate, "state")) == "function"
                and type(rawget(candidate, "towers")) == "table"
            then
                MATCH, ctx, net = obj, candidate, rawget(obj, "net")
                return true
            end
        end
    end
    return false, "match not found yet"
end

local function matchState()
    local ok, s = pcall(ctx.state)
    if ok and type(s) == "table" then
        return s
    end
    return nil
end

local function request(...)
    local ok, res = pcall(net.request, ...)
    if not ok then
        return { ok = false, reason = tostring(res) }
    end
    if type(res) ~= "table" then
        return { ok = false, reason = "no answer" }
    end
    return res
end

local function myTowers()
    local list = {}
    for _, tower in ipairs(ctx.towers) do
        local ok, mine = pcall(net.mine, tower)
        if ok and mine then
            table.insert(list, tower)
        end
    end
    return list
end

local function heroName(kind)
    local def = ctx.HERO and ctx.HERO[kind]
    return (def and def.name) or tostring(kind)
end

local function note(text)
    window:Notify(text, 4)
end

--------------------------------------------------------------------------------
-- Settings and small helpers
--------------------------------------------------------------------------------

local cfg = {
    autoStart = false,
    skipTimer = false,
    autoAgain = false,
    autoNext = false,
    autoPlace = false,
    placeKind = "All slots",
    maxPer = 3,
    reserve = 0,
    autoUpgrade = false,
    order = "Cheapest first",
    maxLevel = 15,
    keepTarget = false,
    antiAfk = true,
    targetMode = (Targeting and type(Targeting.MODES) == "table" and Targeting.MODES[1]) or "first",
}

local timers = { start = 0, skip = 0, replay = 0, upgrade = 0, place = 0, target = 0 }
local holds = {}
local overSince

local function held(key)
    return (holds[key] or 0) > os.clock()
end
local function hold(key, seconds)
    holds[key] = os.clock() + seconds
end

local function nextLevel(tower)
    local levels = tower.levels
    if not levels then
        local unit = ctx.UNITS and ctx.UNITS[tower.unit]
        levels = unit and unit.LEVELS
    end
    return levels and levels[(tower.level or 1) + 1]
end

--------------------------------------------------------------------------------
-- Picking a spot: sample the road, try spots beside it, keep the one whose range covers the most road
--------------------------------------------------------------------------------

local pathCache
local function pathSamples()
    local map = ctx.map
    if pathCache and pathCache.map == map and #pathCache.list > 0 then
        return pathCache.list
    end
    local list = {}
    local path = map and map.path
    if path and path.at and tonumber(path.length) then
        local d = 0
        while d <= path.length do
            local ok, pos = pcall(path.at, path, d)
            if ok and typeof(pos) == "Vector3" then
                table.insert(list, { pos = pos })
            end
            d += 2
        end
    end
    if #list == 0 and path and type(path.pts) == "table" then
        for _, pos in ipairs(path.pts) do
            if typeof(pos) == "Vector3" then
                table.insert(list, { pos = pos })
            end
        end
    end
    for i, sample in ipairs(list) do
        local a = list[math.max(i - 1, 1)].pos
        local b = list[math.min(i + 1, #list)].pos
        local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
        sample.dir = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, 1)
    end
    pathCache = { map = map, list = list }
    return list
end

local OFFSETS = { 3, 4.5, 6, 8, 10.5, 13, 16, 20 }

local function canPlaceAt(pos)
    local ok, result = pcall(ctx.map.canPlace, ctx.map, pos, ctx.towers)
    return ok and result and true or false
end

local function findSpot(kind)
    local samples = pathSamples()
    if #samples == 0 then
        return nil
    end
    local unit = ctx.UNITS[kind]
    local first = unit and unit.LEVELS and unit.LEVELS[1]
    local range = (first and tonumber(first.range) or 8) * WORLD
    local rangeSq = range * range
    local groundY = ctx.groundY

    local best, bestScore
    local tried = 0
    for i = 1, #samples, 2 do
        local sample = samples[i]
        local normal = Vector3.new(-sample.dir.Z, 0, sample.dir.X)
        for _, side in ipairs({ 1, -1 }) do
            for _, offset in ipairs(OFFSETS) do
                local pos = Vector3.new(
                    sample.pos.X + normal.X * offset * side,
                    groundY,
                    sample.pos.Z + normal.Z * offset * side
                )
                local score = 0
                for _, q in ipairs(samples) do
                    local dx, dz = q.pos.X - pos.X, q.pos.Z - pos.Z
                    if dx * dx + dz * dz <= rangeSq then
                        score += 1
                    end
                end
                if (not bestScore or score > bestScore) and score > 0 and canPlaceAt(pos) then
                    best, bestScore = pos, score
                end
                tried += 1
                if tried % 150 == 0 then
                    task.wait()
                end
            end
        end
    end
    return best
end

--------------------------------------------------------------------------------
-- Actions (each one is a request the game's own UI would also send)
--------------------------------------------------------------------------------

local function placeHero(kind)
    local loader = ctx.loader
    -- Same order as the game's own placing: build the hero's model, find a spot, send the place request.
    loader.busy = kind
    local wokeOk, woke = pcall(loader.wake, kind, "mine")
    loader.busy = nil
    if not (wokeOk and woke ~= false) then
        hold("place" .. kind, 8)
        pcall(loader.rest, kind)
        note("No room to load " .. heroName(kind))
        return
    end

    local pos = findSpot(kind)
    local s = matchState()
    if not pos or not s or s.over then
        hold("place" .. kind, 6)
        pcall(loader.rest, kind)
        if s and not s.over then
            note("No free spot found for " .. heroName(kind))
        end
        return
    end

    MATCH.pendingKind = kind
    local ok, res = pcall(net.place, kind, pos)
    MATCH.pendingKind = nil
    if not ok or type(res) ~= "table" then
        res = { ok = false, reason = tostring(res) }
    end
    if res.ok then
        task.delay(5, function()
            pcall(loader.rest, kind)
        end)
    else
        hold("place" .. kind, 5)
        pcall(loader.rest, kind)
        note("Place " .. heroName(kind) .. ": " .. tostring(res.reason or "refused"))
    end
end

local function heroKinds()
    local kinds = {}
    for _, kind in ipairs(MATCH.slots) do
        if ctx.UNITS[kind] and ctx.HERO[kind] then
            table.insert(kinds, kind)
        end
    end
    return kinds
end

local heroDropdown
local heroNameToKind = {}
local function refreshHeroList()
    local options = { "All slots" }
    table.clear(heroNameToKind)
    for _, kind in ipairs(heroKinds()) do
        local name = heroName(kind)
        table.insert(options, name)
        heroNameToKind[name] = kind
    end
    if heroDropdown then
        heroDropdown:SetOptions(options, true)
    end
end

local function stepReplay(s)
    if not s.over then
        overSince = nil
        return
    end
    overSince = overSince or os.clock()
    if not (cfg.autoNext or cfg.autoAgain) or os.clock() - overSince < 3 or os.clock() < timers.replay then
        return
    end
    timers.replay = os.clock() + 4
    local what
    local okNext, hasNext = pcall(MATCH.hasNext)
    if cfg.autoNext and okNext and hasNext then
        what = "next"
    elseif cfg.autoAgain then
        what = "again"
    end
    if what then
        local res = request(what)
        if not res.ok and res.reason then
            note(("Vote %s: %s"):format(what, tostring(res.reason)))
        end
    end
end

local function stepStart(s)
    if s.over then
        return
    end
    if cfg.autoStart and not s.running and os.clock() >= timers.start then
        local button = ctx.gui:FindFirstChild("StartWave")
        if button and button.Visible then
            timers.start = os.clock() + 2
            local res = request("start")
            if not res.ok and res.reason then
                note("Start wave: " .. tostring(res.reason))
            end
        end
    end
    if cfg.skipTimer and s.running and os.clock() >= timers.skip then
        local remotes = ctx.remotes
        if remotes and remotes:GetAttribute("WaveSkip") == true
            and (tonumber(remotes:GetAttribute("WaveNextAt")) or 0) > 0
        then
            timers.skip = os.clock() + 1.5
            request("start")
        end
    end
end

local function stepUpgrade(s)
    if not cfg.autoUpgrade or s.over or os.clock() < timers.upgrade then
        return
    end
    local money = tonumber(s.money) or 0
    local best, bestKey
    for _, tower in ipairs(myTowers()) do
        local nxt = nextLevel(tower)
        local level = tower.level or 1
        local cost = nxt and tonumber(nxt.cost)
        if cost and level < cfg.maxLevel and money - cost >= cfg.reserve and not held("up" .. tostring(tower.id)) then
            local key
            if cfg.order == "Cheapest first" then
                key = cost
            elseif cfg.order == "Lowest level first" then
                key = level * 100000 + cost
            else
                key = -level * 100000 + cost
            end
            if not bestKey or key < bestKey then
                best, bestKey = tower, key
            end
        end
    end
    if not best then
        return
    end
    timers.upgrade = os.clock() + 0.35
    local res = request("upgrade", best.id)
    if not res.ok then
        hold("up" .. tostring(best.id), 4)
        if res.reason then
            note("Upgrade: " .. tostring(res.reason))
        end
    end
end

local function stepPlace(s)
    if not cfg.autoPlace or s.over or os.clock() < timers.place then
        return
    end
    if (ctx.placingKind and ctx.placingKind()) or (ctx.pendingKind and ctx.pendingKind())
        or MATCH.pendingKind or ctx.loader.busy
    then
        return -- the player is placing something by hand
    end

    local kinds
    local chosen = heroNameToKind[cfg.placeKind]
    if chosen then
        kinds = { chosen }
    else
        kinds = heroKinds()
    end

    for _, kind in ipairs(kinds) do
        local limit = math.min(cfg.maxPer, MATCH.capOf(kind))
        if MATCH.placedOf(kind) < limit and not held("place" .. kind) then
            local price = MATCH.placePrice(kind)
            local money = tonumber(s.money) or 0
            if MATCH.freePlace() or (MATCH.canPay(kind) and money - price >= cfg.reserve) then
                timers.place = os.clock() + 1
                placeHero(kind)
            end
            return -- first hero that still needs copies decides; if it can't be afforded yet, save up
        end
    end
end

local function applyTargeting(mode)
    local changed = 0
    for _, tower in ipairs(myTowers()) do
        if (tower.targeting or "first") ~= mode then
            tower.targeting = mode
            request("target", tower.id, mode)
            changed += 1
            task.wait(0.15)
        end
    end
    return changed
end

local function stepTarget()
    if not cfg.keepTarget or os.clock() < timers.target then
        return
    end
    timers.target = os.clock() + 2
    applyTargeting(cfg.targetMode)
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local matchTab = window:AddTab("Match")
matchTab:AddSection("Status")
local statusLabel = matchTab:AddLabel("Looking for the match...")

matchTab:AddSection("Waves")
matchTab:AddToggle("Auto start waves", cfg.autoStart, function(v) cfg.autoStart = v end)
matchTab:AddToggle("Skip the wave countdown", cfg.skipTimer, function(v) cfg.skipTimer = v end)

matchTab:AddSection("When the match ends")
matchTab:AddToggle("Auto play again / try again", cfg.autoAgain, function(v) cfg.autoAgain = v end)
matchTab:AddToggle("Auto next stage (if there is one)", cfg.autoNext, function(v) cfg.autoNext = v end)

local heroTab = window:AddTab("Heroes")
heroTab:AddSection("Auto place")
heroTab:AddToggle("Auto place heroes", cfg.autoPlace, function(v) cfg.autoPlace = v end)
heroDropdown = heroTab:AddDropdown("Hero", { "All slots" }, cfg.placeKind, function(v) cfg.placeKind = v end)
heroTab:AddSlider("Max copies per hero", 1, 12, cfg.maxPer, 1, function(v) cfg.maxPer = v end)
heroTab:AddSlider("Keep this much $ in reserve", 0, 1000, cfg.reserve, 25, function(v) cfg.reserve = v end)

heroTab:AddSection("Auto upgrade")
heroTab:AddToggle("Auto upgrade my heroes", cfg.autoUpgrade, function(v) cfg.autoUpgrade = v end)
heroTab:AddDropdown(
    "Order",
    { "Cheapest first", "Lowest level first", "Highest level first" },
    cfg.order,
    function(v) cfg.order = v end
)
heroTab:AddSlider("Upgrade up to level", 1, 15, cfg.maxLevel, 1, function(v) cfg.maxLevel = v end)

local targetLabels, labelToMode = {}, {}
if Targeting and type(Targeting.MODES) == "table" then
    for _, mode in ipairs(Targeting.MODES) do
        local label = (Targeting.LABELS and Targeting.LABELS[mode]) or tostring(mode)
        table.insert(targetLabels, label)
        labelToMode[label] = mode
    end
end
if #targetLabels > 0 then
    heroTab:AddSection("Targeting")
    heroTab:AddDropdown("Target", targetLabels, targetLabels[1], function(v)
        cfg.targetMode = labelToMode[v] or cfg.targetMode
    end)
    heroTab:AddButton("Apply to all my heroes now", function()
        if not matchAlive() then
            return note("Match not found yet")
        end
        note(("Targeting set on %d heroes"):format(applyTargeting(cfg.targetMode)))
    end)
    heroTab:AddToggle("Keep all my heroes on this", cfg.keepTarget, function(v) cfg.keepTarget = v end)
end

local miscTab = window:AddTab("Misc")
miscTab:AddSection("Session")
miscTab:AddToggle("Anti AFK", cfg.antiAfk, function(v) cfg.antiAfk = v end)
local VirtualUser = game:GetService("VirtualUser")
window:Connect(player.Idled, function()
    if cfg.antiAfk then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

miscTab:AddSection("Troubleshooting")
miscTab:AddButton("Look for the match again", function()
    lastScan = -10
    MATCH, ctx, net = nil, nil, nil
    note("Scanning...")
end)
miscTab:AddButton("Print match info to the console (F9)", function()
    if not matchAlive() then
        return note("Match not found yet")
    end
    print("=== Candy TD match ===")
    print("stage", MATCH.stageId, MATCH.name, MATCH.world, "endless:", MATCH.endless)
    print("slots", table.concat(MATCH.slots, ", "))
    local names = {}
    for key, value in pairs(net) do
        table.insert(names, ("%s (%s)"):format(tostring(key), type(value)))
    end
    table.sort(names)
    print("net: " .. table.concat(names, ", "))
    if ctx.remotes then
        for _, child in ipairs(ctx.remotes:GetChildren()) do
            print("remote", child.Name, child.ClassName)
        end
    end
    for _, tower in ipairs(myTowers()) do
        print("tower", tower.id, tower.unit, "level", tower.level, "targeting", tower.targeting)
    end
end)
miscTab:AddButton("Unload", function()
    window:Destroy()
end)

--------------------------------------------------------------------------------
-- Worker
--------------------------------------------------------------------------------

local steps = { stepReplay, stepStart, stepUpgrade, stepPlace, stepTarget }
local lastError, lastErrorAt = nil, 0
local lastStatus = 0

local function refreshStatus(s)
    local towers = #myTowers()
    local wave = s.wave or 0
    local phase = s.over and "match over" or (s.running and "wave running" or "between waves")
    statusLabel:SetText(("Stage %s: %s\nWave %d | %s\nLives %s | $%s | %d heroes of mine"):format(
        tostring(MATCH.stageId), tostring(MATCH.name), wave, phase, tostring(s.lives), tostring(s.money), towers
    ))
end

task.spawn(function()
    while alive do
        restoreIdentity()
        if not matchAlive() and os.clock() - lastScan > 3 then
            lastScan = os.clock()
            local found, reason = discover()
            if found then
                pathCache = nil
                refreshHeroList()
                note("Match found")
            else
                statusLabel:SetText("Looking for the match... (" .. tostring(reason) .. ")")
            end
        end

        if matchAlive() then
            local s = matchState()
            if s then
                if os.clock() - lastStatus > 0.5 then
                    lastStatus = os.clock()
                    pcall(refreshStatus, s)
                end
                for _, step in ipairs(steps) do
                    local ok, err = pcall(step, s)
                    if not ok and (err ~= lastError or os.clock() - lastErrorAt > 10) then
                        lastError, lastErrorAt = err, os.clock()
                        warn("[Candy TD GUI] " .. tostring(err))
                        note("Error: " .. tostring(err))
                    end
                    if not alive or not matchAlive() then
                        break
                    end
                end
            end
        end
        task.wait(0.2)
    end
end)

