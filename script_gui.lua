--[[
    Script GUI
    - RightShift toggles the window, drag the title bar to move it.
    - Add features at the bottom: window:AddTab("Name") then
      tab:AddToggle / AddButton / AddSlider / AddLabel / AddSection.
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
if env.ScriptGuiUnload then
    pcall(env.ScriptGuiUnload)
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
        Name = "ScriptGui",
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
                warn("[Script GUI] loop stopped: " .. tostring(err))
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
-- Features
--------------------------------------------------------------------------------

local window = Window.new("Script GUI")
env.ScriptGuiUnload = function() window:Destroy() end
window.onDestroy = function()
    if env.ScriptGuiUnload then
        env.ScriptGuiUnload = nil
    end
end

-- The game's own modules (from the pasted scripts). Optional: every use
-- below falls back gracefully if one can't be required.
local function loadModule(name, folderName)
    local ok, result = pcall(function()
        local folder = folderName and ReplicatedStorage:WaitForChild(folderName, 5) or ReplicatedStorage
        return require(folder:WaitForChild(name, 5))
    end)
    restoreIdentity()
    return ok and result or nil
end

local actions = loadModule("character_actions", "Modules")
local questsModule = loadModule("quests", "Modules")
-- The game's own (Blink-generated) network layer: Remotes.<group>.<name>
-- with :Fire(...) for events and :Invoke() returning a Promise.
local Remotes = loadModule("Remotes")

local function getCharacter()
    local char = player.Character
    return char, char and char:FindFirstChildOfClass("Humanoid"), char and char:FindFirstChild("HumanoidRootPart")
end

local state = {
    doubleJump = false,
    sprint = false,
    speed = false,
    speedValue = 16,
}
local DOUBLE_JUMP_ATTR = actions and actions.attributes.double_jump_unlocked or "double_jump_unlocked"
local SPRINT_TAG = actions and actions.tags.sprint or "sprint"
local STATUS_TAGS = { "sprint", "sprintboost", "attacking", "blocking", "stunned", "skill_freeze", "broom_mounted" }

-- Character tab ---------------------------------------------------------------
local character = window:AddTab("Character")

character:AddSection("Movement")

character:AddToggle("Unlock double jump", false, function(on)
    state.doubleJump = on
    if not on then
        local char = getCharacter()
        if char then
            char:SetAttribute(DOUBLE_JUMP_ATTR, nil)
        end
    end
end)

character:AddToggle("Force sprint", false, function(on)
    state.sprint = on
    if not on then
        local char = getCharacter()
        if char then
            if actions then
                actions.set_sprint_tag(char, false)
            else
                char:RemoveTag(SPRINT_TAG)
            end
        end
    end
end)

character:AddToggle("Custom walk speed", false, function(on)
    state.speed = on
end)
character:AddSlider("Walk speed", 16, 100, 16, 1, function(value)
    state.speedValue = value
end)

character:AddSection("Actions")

character:AddButton("Dash forward", function()
    local char, humanoid, root = getCharacter()
    if not (char and humanoid and root) then
        return window:Notify("No character")
    end
    if not actions then
        return window:Notify("character_actions module not found")
    end
    if not actions.can_dash(char, humanoid) then
        return window:Notify("Can't dash right now")
    end
    local ok, err = pcall(actions.dash, char, root.CFrame.LookVector)
    window:Notify(ok and "Dashed" or ("Dash failed: " .. tostring(err)), 4)
end)

character:AddSection("Status")
local statusLabel = character:AddLabel("...")

-- Quests tab ------------------------------------------------------------------
local updateQuestStatus = function() end
local updateFarmStatus = function() end
local updateAutoStatus = function() end

-- Helpers shared by the Quests and Farm tabs
local NPC_TAG = (questsModule and questsModule.MARKER_TAG) or "quest_npc"

local function questName(quest)
    return tostring(quest.name or quest.title or quest.id)
end

-- Runs a Remotes ...Invoke call (which returns a Promise) off the calling
-- thread. onDone(value) on success, onDone(nil, message) on failure.
local function invoke(call, onDone)
    task.spawn(function()
        local ok, resolved, value = pcall(function()
            return call():await()
        end)
        if ok and resolved then
            onDone(value)
        else
            onDone(nil, tostring(ok and value or resolved))
        end
    end)
end

-- The player's quests, fetched with the same call the game's quest UI makes:
-- { current = "", active = { { id, completed, objectives = { { id, progress,
-- required, completed } } } }, completed = { ids } }
local questState = { data = nil, fetchedAt = 0, fetching = false }

local function fetchQuestData(onDone)
    if not Remotes then
        if onDone then
            onDone(nil, "Remotes module not found")
        end
        return
    end
    if questState.fetching then
        return
    end
    questState.fetching = true
    invoke(function() return Remotes.quests.get.Invoke() end, function(data, err)
        questState.fetching = false
        if data then
            questState.data = data
            questState.fetchedAt = os.clock()
        end
        if onDone then
            onDone(data, err)
        end
    end)
end

-- True if the instance's name, its parent's name, or any string attribute
-- contains one of the (lowercase, non-empty) needles.
local function matchesNeedles(inst, needles)
    local haystack = { inst.Name }
    if inst.Parent then
        table.insert(haystack, inst.Parent.Name)
    end
    for _, attribute in pairs(inst:GetAttributes()) do
        if type(attribute) == "string" then
            table.insert(haystack, attribute)
        end
    end
    for _, text in ipairs(haystack) do
        local lowered = string.lower(text)
        for _, needle in ipairs(needles) do
            if lowered == needle or lowered:find(needle, 1, true) then
                return true
            end
        end
    end
    return false
end

local function pivotOf(inst)
    if inst:IsA("Model") then
        return inst:GetPivot()
    elseif inst:IsA("BasePart") then
        return inst.CFrame
    elseif inst:IsA("Attachment") then
        return inst.WorldCFrame
    end
    local model = inst:FindFirstAncestorOfClass("Model")
    if model then
        return model:GetPivot()
    end
    local part = inst:FindFirstAncestorWhichIsA("BasePart")
    return part and part.CFrame
end

-- Quest givers are models named quest_npc_<giver_id> in workspace.quest_npcs
local function findGiverNpc(giverId)
    local folder = workspace:FindFirstChild("quest_npcs")
    local model = folder and folder:FindFirstChild("quest_npc_" .. tostring(giverId))
    if model then
        return model
    end
    -- Fallback: tagged marker whose name or attributes mention the giver id
    local needles = { string.lower(tostring(giverId)) }
    for _, inst in ipairs(CollectionService:GetTagged(NPC_TAG)) do
        if matchesNeedles(inst, needles) then
            return inst
        end
    end
end

local questTab = window:AddTab("Quests")
if not questsModule then
    questTab:AddLabel("ReplicatedStorage.Modules.quests could not be loaded.")
else
    -- Current quest ---------------------------------------------------------
    questTab:AddSection("Current quest")
    local currentLabel = questTab:AddLabel("No quest data yet. Press 'Refresh quests'.")

    updateQuestStatus = function()
        local data = questState.data
        if not data then
            return
        end
        local ok, view = pcall(questsModule.get_current_view, data)
        if not ok then
            currentLabel:SetText("Couldn't read quest data (press 'Refresh quests')")
        elseif not view then
            currentLabel:SetText(string.format("No active quest\nCompleted: %d", #data.completed))
        else
            currentLabel:SetText(string.format(
                "%s\n%s\nProgress: %d/%d (%d%%)",
                questName(view.quest), view.text, view.progress, view.required, math.floor(view.percent * 100)
            ))
        end
    end

    questTab:AddButton("Refresh quests", function()
        fetchQuestData(function(data, err)
            if data then
                updateQuestStatus()
                window:Notify("Quests refreshed")
            else
                currentLabel:SetText("Couldn't fetch quests: " .. tostring(err))
                window:Notify("Quest fetch failed")
            end
        end)
    end)

    -- Quest browser ---------------------------------------------------------
    questTab:AddSection("Quest browser")

    local questIds, seen = {}, {}
    for _, id in ipairs(questsModule.config.order or {}) do
        if questsModule.get_quest(id) and not seen[id] then
            seen[id] = true
            table.insert(questIds, id)
        end
    end
    local extra = {}
    for id in pairs(questsModule.config.quests) do
        if not seen[id] then
            table.insert(extra, id)
        end
    end
    table.sort(extra)
    table.move(extra, 1, #extra, #questIds + 1, questIds)

    local detailsLabel = questTab:AddLabel("")
    local function describeQuest(id)
        local quest = id and questsModule.get_quest(id)
        if not quest then
            return "No quest selected"
        end
        local lines = {
            questName(quest),
            string.format(
                "Giver: %s   Min level: %s   Optional: %s",
                tostring(quest.giver_id), tostring(quest.min_level or 1), tostring(quest.is_optional == true)
            ),
        }
        for _, objective in ipairs(quest.objectives or {}) do
            local target = objective.target and (" -> " .. tostring(objective.target)) or ""
            table.insert(lines, "- " .. questsModule.format_objective(objective, 0) .. target)
        end
        return table.concat(lines, "\n")
    end

    local questDropdown = questTab:AddDropdown("Quest", questIds, questIds[1], function(id)
        detailsLabel:SetText(describeQuest(id))
    end)
    detailsLabel:SetText(describeQuest(questDropdown:Get()))

    -- Quest NPCs ------------------------------------------------------------
    questTab:AddSection("Quest NPCs")

    local npcs = {}
    local npcDropdown = questTab:AddDropdown("NPC", {}, nil)

    local function teleportTo(inst)
        local char, _, root = getCharacter()
        if not (char and root) then
            return window:Notify("No character")
        end
        local pivot = pivotOf(inst)
        if not pivot then
            return window:Notify("Can't locate " .. inst.Name)
        end
        char:PivotTo(pivot * CFrame.new(0, 0, -5))
        window:Notify("Teleported to " .. inst.Name)
    end

    local function refreshNpcs()
        table.clear(npcs)
        local names = {}
        for _, inst in ipairs(CollectionService:GetTagged(NPC_TAG)) do
            local key, count = inst.Name, 1
            while npcs[key] do
                count += 1
                key = inst.Name .. " #" .. count
            end
            npcs[key] = inst
            table.insert(names, key)
        end
        table.sort(names)
        npcDropdown:SetOptions(names, true)
        return #names
    end

    questTab:AddButton("Refresh NPC list", function()
        window:Notify(refreshNpcs() .. " quest NPC(s) found")
    end)
    questTab:AddButton("Teleport to selected NPC", function()
        local inst = npcs[npcDropdown:Get()]
        if inst and inst.Parent then
            teleportTo(inst)
        else
            window:Notify("Pick an NPC first (refresh the list)")
        end
    end)
    questTab:AddButton("Teleport to selected quest's giver", function()
        local quest = questsModule.get_quest(questDropdown:Get())
        local inst = quest and quest.giver_id and findGiverNpc(quest.giver_id)
        if inst then
            teleportTo(inst)
        else
            window:Notify("No tagged NPC matched that giver")
        end
    end)

    refreshNpcs()
end

-- Farm tab --------------------------------------------------------------------
-- Quest mode reads the current objective and does it:
--   no active quest -> walk to the next quest giver, Remotes.quests.accept
--   kill_npc        -> find that enemy type in workspace.entities (or travel to
--                      its spawn markers), stand next to it, attack with
--                      Remotes.combat.request_hit
--   collect_item    -> fire matching proximity prompts
--   quest finished  -> visit the giver in case turn-in is a prompt
-- Other objective types are reported but not automated. Only NPCs in
-- workspace.entities are ever targeted, never players. Movement is CFrame
-- stepping; the server still decides hits, rewards and quest progress.
local VirtualInputManager = game:GetService("VirtualInputManager")

local MODE_QUEST, MODE_ENEMY = "Quest objective", "Nearest enemy"
local ATTACK_PRESS, ATTACK_SINGLE, ATTACK_CLICK = "Remote press/release", "Remote single", "Mouse click"
local SKILL_KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }

local farm = {
    enabled = false,
    mode = MODE_QUEST,
    attackMode = ATTACK_PRESS,
    filter = "",
    autoQuest = true,
    abandonUnsupported = false,
    useSkills = false,
    skillKeys = 2,
    speed = 120,
    standDistance = 4,
    attackDelay = 0.2,
    level = 1,
    profileLevel = nil,
    status = "Idle",
    task = nil,
    taskKey = nil,
    target = nil,
    targetSince = 0,
    -- Instances (humanoids, prompts) or quest ids to leave alone until a time
    skip = {},
    acceptTries = {},
    skillIndex = 0,
    nextDecide = 0,
    nextQuestFetch = 0,
    nextProfileFetch = 0,
    nextSearch = 0,
    nextAttack = 0,
    nextSkill = 0,
    nextInteract = 0,
}

-- Proximity prompts in workspace, kept up to date from descendant events so the
-- farm never has to scan the whole tree while running.
local prompts = {}
local worldCached = false

local function ensureWorldCache()
    if worldCached then
        return
    end
    worldCached = true
    for _, inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("ProximityPrompt") then
            prompts[inst] = true
        end
    end
    window:Connect(workspace.DescendantAdded, function(inst)
        if inst:IsA("ProximityPrompt") then
            prompts[inst] = true
        end
    end)
    window:Connect(workspace.DescendantRemoving, function(inst)
        prompts[inst] = nil
    end)
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

-- Config ids look like "forest_bandit"; in-world names may not
local function needlesFor(text)
    local lowered = string.lower(text)
    local spaced = lowered:gsub("_", " ")
    local joined = lowered:gsub("_", "")
    return { lowered, spaced, joined }
end

local function getLevel()
    return farm.profileLevel or farm.level
end

-- Input -----------------------------------------------------------------------
local function attack()
    if farm.attackMode ~= ATTACK_CLICK and Remotes then
        local hit = Remotes.combat.request_hit
        if farm.attackMode == ATTACK_PRESS then
            hit.Fire(true)
            task.delay(0.05, function()
                hit.Fire(false)
            end)
        else
            hit.Fire(false)
        end
        return
    end
    -- Synthetic click in the top inset, away from the game's HUD and this window
    local camera = workspace.CurrentCamera
    local x = camera and camera.ViewportSize.X / 2 or 400
    VirtualInputManager:SendMouseButtonEvent(x, 2, 0, true, game, 0)
    task.delay(0.03, function()
        VirtualInputManager:SendMouseButtonEvent(x, 2, 0, false, game, 0)
    end)
end

local function pressSkill()
    farm.skillIndex = farm.skillIndex % farm.skillKeys + 1
    local key = SKILL_KEYS[farm.skillIndex]
    VirtualInputManager:SendKeyEvent(true, key, false, game)
    task.delay(0.05, function()
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

local function firePrompt(prompt)
    if typeof(fireproximityprompt) == "function" then
        fireproximityprompt(prompt)
    else
        prompt:InputHoldBegin()
        task.delay(prompt.HoldDuration + 0.1, function()
            prompt:InputHoldEnd()
        end)
    end
end

-- Movement --------------------------------------------------------------------
-- Steps the character toward goal at farm.speed, always facing lookAt
-- horizontally. Returns the distance to goal before the step.
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

-- Target finders --------------------------------------------------------------
-- Live enemies are the models in workspace.entities; a model's type is its
-- npc_type attribute (or its name), e.g. "hage_bandit".
local function entityType(model)
    local npcType = model:GetAttribute("npc_type")
    return type(npcType) == "string" and npcType or model.Name
end

-- spec.exact = entity id; spec.contains = lowercase needles; neither = any
local function enemyMatches(model, spec)
    if spec.exact then
        return entityType(model) == spec.exact or model.Name == spec.exact
    end
    if spec.contains then
        local lowered = string.lower(model.Name .. " " .. entityType(model))
        for _, needle in ipairs(spec.contains) do
            if lowered:find(needle, 1, true) then
                return true
            end
        end
        return false
    end
    return true
end

local function nearestEnemy(origin, spec, now)
    local folder = workspace:FindFirstChild("entities")
    if not folder then
        return nil
    end
    local best, bestDist
    for _, model in ipairs(folder:GetChildren()) do
        local hum = model:IsA("Model") and model:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0
            and not (farm.skip[hum] and farm.skip[hum] > now)
            and not Players:GetPlayerFromCharacter(model)
            and not CollectionService:HasTag(model, "invulnerable")
            and enemyMatches(model, spec) then
            local part = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
            if part then
                local dist = (part.Position - origin).Magnitude
                if not bestDist or dist < bestDist then
                    best, bestDist = hum, dist
                end
            end
        end
    end
    return best
end

-- workspace.npc_markers holds a model per spawn point, named by entity id.
-- Enemies stream in around the player, so this is where to head when none of
-- the wanted type are loaded.
local function nearestSpawnMarker(origin, entityId)
    local folder = workspace:FindFirstChild("npc_markers")
    if not folder then
        return nil
    end
    local best, bestDist
    for _, marker in ipairs(folder:GetChildren()) do
        if marker.Name == entityId or marker:GetAttribute("npc") == entityId then
            local pivot = pivotOf(marker)
            if pivot then
                local dist = (pivot.Position - origin).Magnitude
                if not bestDist or dist < bestDist then
                    best, bestDist = pivot.Position, dist
                end
            end
        end
    end
    return best, bestDist
end

local function promptMatches(prompt, needles)
    local parent = prompt.Parent
    if matchesNeedles(prompt, needles) or matchesNeedles(parent, needles) then
        return true
    end
    for _, text in ipairs({ string.lower(prompt.ObjectText), string.lower(prompt.ActionText) }) do
        for _, needle in ipairs(needles) do
            if text:find(needle, 1, true) then
                return true
            end
        end
    end
    return false
end

local function nearestPrompt(origin, needles, now)
    local best, bestDist
    for prompt in pairs(prompts) do
        local parent = prompt.Parent
        if prompt.Enabled and parent
            and not (farm.skip[prompt] and farm.skip[prompt] > now)
            and not CollectionService:HasTag(parent:FindFirstAncestorOfClass("Model") or parent, NPC_TAG)
            and promptMatches(prompt, needles) then
            local pivot = pivotOf(parent)
            if pivot then
                local dist = (pivot.Position - origin).Magnitude
                if not bestDist or dist < bestDist then
                    best, bestDist = prompt, dist
                end
            end
        end
    end
    return best
end

-- Task selection --------------------------------------------------------------
local function idle(text)
    return { kind = "idle", text = text }
end

local function canAutomate(quest)
    for _, objective in ipairs(quest.objectives or {}) do
        if objective.type ~= questsModule.types.kill_npc and objective.type ~= questsModule.types.collect_item then
            return false
        end
    end
    return true
end

-- The quest that fits the player's level: the first one in story order that
-- isn't done and whose level range (min_level..max_level) contains the level.
-- When none is in range, the first undone quest the player has reached.
-- opts.automatableOnly: only quests the farm can do; opts.includeOptional:
-- side quests too.
local function pickQuest(data, level, now, opts)
    local done = {}
    for _, id in ipairs(data.completed) do
        done[id] = true
    end
    local fallback
    for _, id in ipairs(questsModule.config.order or {}) do
        local quest = questsModule.get_quest(id)
        if quest and quest.giver_id
            and not done[id]
            and (opts.includeOptional or quest.is_optional ~= true)
            and (quest.min_level or 1) <= level
            and not (farm.skip[id] and farm.skip[id] > now)
            and (not opts.automatableOnly or canAutomate(quest)) then
            if not quest.max_level or level <= quest.max_level then
                return quest
            end
            fallback = fallback or quest
        end
    end
    return fallback
end

local function decideTask(now)
    if farm.mode == MODE_ENEMY then
        return { kind = "kill", spec = { contains = parseNeedles(farm.filter) }, key = farm.filter,
                 text = farm.filter ~= "" and farm.filter or "any enemy" }
    end
    if not questsModule then
        return idle("Quests module not loaded")
    end
    local data = questState.data
    if not data then
        return idle("Fetching quests...")
    end

    local level = getLevel()
    local entry = questsModule.get_current_entry(data) or questsModule.get_assigned_entry(data)
    if not entry then
        if not farm.autoQuest then
            return idle("No active quest")
        end
        local quest = pickQuest(data, level, now, { automatableOnly = true })
        if not quest then
            return idle("No quest to accept at level " .. level)
        end
        return { kind = "giver", giverId = quest.giver_id, acceptQuestId = quest.id, key = quest.id,
                 text = "accepting " .. questName(quest) }
    end
    farm.acceptTries[entry.id] = nil

    local quest = questsModule.get_quest(entry.id)
    if not quest then
        return idle("Unknown quest '" .. tostring(entry.id) .. "'")
    end
    local primary = questsModule.get_primary_objective(quest, entry)
    if entry.completed == true or not primary or primary.completed then
        if not (farm.autoQuest and quest.giver_id) then
            return idle(questName(quest) .. " is complete")
        end
        return { kind = "giver", giverId = quest.giver_id, key = "turnin:" .. quest.id,
                 text = "turning in " .. questName(quest) }
    end

    local objective = primary.objective
    local target = objective.target and tostring(objective.target)
    if objective.type == questsModule.types.kill_npc then
        return { kind = "kill", spec = target and { exact = target } or {}, key = target or "",
                 text = target or "any enemy" }
    elseif objective.type == questsModule.types.collect_item and target then
        return { kind = "collect", needles = needlesFor(target), key = target, text = target }
    end

    if farm.abandonUnsupported and Remotes then
        Remotes.quests.remove.Fire(entry.id)
        farm.skip[entry.id] = now + 3600
        farm.nextQuestFetch = now + 0.6
        return idle("Abandoned " .. questName(quest))
    end
    return idle(string.format("%s: '%s' isn't automated", questName(quest), tostring(objective.type)))
end

-- Task steps ------------------------------------------------------------------
local function stepKill(task_, root, dt, now)
    local target = farm.target
    local valid = target and target.Parent and target.Health > 0
    if valid and now > farm.targetSince + 25 then
        -- Not dying (unreachable or invulnerable): give up on it for a while
        farm.skip[target] = now + 20
        valid = false
    end
    if not valid then
        farm.target = nil
        target = nil
        if now >= farm.nextSearch then
            farm.nextSearch = now + 0.5
            target = nearestEnemy(root.Position, task_.spec, now)
            if target then
                farm.target = target
                farm.targetSince = now
            end
        end
        if not target then
            -- None of this type loaded nearby: head for where it spawns
            local marker, markerDist
            if task_.spec.exact then
                marker, markerDist = nearestSpawnMarker(root.Position, task_.spec.exact)
            end
            if marker and markerDist > 8 then
                approach(root, marker + Vector3.new(0, 3, 0), marker, dt)
                farm.status = "Travelling to " .. task_.text .. " spawn"
            elseif marker then
                farm.status = "Waiting for " .. task_.text .. " to spawn"
            else
                farm.status = "No " .. task_.text .. " found"
            end
            return
        end
    end

    local model = target.Parent
    local enemyRoot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if not enemyRoot then
        farm.skip[target] = now + 20
        farm.target = nil
        return
    end

    -- Stay on whichever side we arrived from, standDistance away
    local enemyPos = enemyRoot.Position
    local flat = Vector3.new(root.Position.X - enemyPos.X, 0, root.Position.Z - enemyPos.Z)
    local dist = flat.Magnitude
    local away = dist > 0.05 and flat.Unit or Vector3.new(0, 0, 1)
    local reach = farm.standDistance + 1.5
    local goal = dist > reach and (enemyPos + away * farm.standDistance) or root.Position
    approach(root, goal, enemyPos, dt)

    if dist <= reach + 2 then
        if now >= farm.nextAttack then
            farm.nextAttack = now + farm.attackDelay
            attack()
        end
        if farm.useSkills and now >= farm.nextSkill then
            farm.nextSkill = now + 1.2
            pressSkill()
        end
    end
    farm.status = string.format("Fighting %s (%.0f/%.0f hp)", model.Name, target.Health, target.MaxHealth)
end

local function stepCollect(task_, root, dt, now)
    local prompt = farm.target
    local valid = prompt and prompt.Parent and prompt.Enabled
    if valid and now > farm.targetSince + 15 then
        farm.skip[prompt] = now + 30
        valid = false
    end
    if not valid then
        farm.target = nil
        if now < farm.nextSearch then
            return
        end
        farm.nextSearch = now + 0.5
        prompt = nearestPrompt(root.Position, task_.needles, now)
        if not prompt then
            farm.status = "No " .. task_.text .. " to collect nearby"
            return
        end
        farm.target = prompt
        farm.targetSince = now
    end

    local pivot = pivotOf(prompt.Parent)
    if not pivot then
        farm.skip[prompt] = now + 30
        farm.target = nil
        return
    end
    local dist = approach(root, pivot.Position, pivot.Position, dt)
    if dist <= math.max(prompt.MaxActivationDistance - 2, 3) and now >= farm.nextInteract then
        farm.nextInteract = now + 0.4
        firePrompt(prompt)
    end
    farm.status = "Collecting " .. task_.text
end

local function stepGiver(task_, root, dt, now)
    local npc = findGiverNpc(task_.giverId)
    local pivot = npc and pivotOf(npc)
    if not pivot then
        farm.status = "Giver '" .. tostring(task_.giverId) .. "' not found (not streamed in?)"
        return
    end
    local offset = root.Position - pivot.Position
    local dist = offset.Magnitude
    local goal = dist > 7 and (pivot.Position + offset.Unit * 4) or root.Position
    approach(root, goal, pivot.Position, dt)
    farm.status = string.format("%s (%s)", task_.text, npc.Name)

    if dist > 8 or now < farm.nextInteract then
        return
    end
    farm.nextInteract = now + 1.5
    if task_.acceptQuestId and Remotes then
        local tries = (farm.acceptTries[task_.acceptQuestId] or 0) + 1
        farm.acceptTries[task_.acceptQuestId] = tries
        if tries > 6 then
            -- The server keeps refusing it (level cap, prerequisite...): move on
            farm.skip[task_.acceptQuestId] = now + 120
            farm.acceptTries[task_.acceptQuestId] = nil
            return
        end
        Remotes.quests.accept.Fire(task_.acceptQuestId)
        farm.nextQuestFetch = now + 0.6
    else
        local scope = npc:FindFirstAncestorOfClass("Model") or npc
        for _, inst in ipairs(scope:GetDescendants()) do
            if inst:IsA("ProximityPrompt") and inst.Enabled then
                firePrompt(inst)
            end
        end
    end
end

-- Quests and level come from the server (the calls the game's own UI makes).
-- Shared by the farm and the Auto tab so neither duplicates the requests.
local function ensureQuests(now)
    if Remotes and now >= farm.nextQuestFetch then
        farm.nextQuestFetch = now + 2
        fetchQuestData()
    end
end

local function ensureProfile(now)
    if Remotes and now >= farm.nextProfileFetch then
        farm.nextProfileFetch = now + 20
        invoke(function() return Remotes.profile.get.Invoke() end, function(profile)
            if profile and type(profile.level) == "number" then
                farm.profileLevel = profile.level
            end
        end)
    end
end

local function stepFarm(dt)
    local char, hum, root = getCharacter()
    if not (char and hum and root) or hum.Health <= 0 then
        farm.status = "Waiting for character"
        return
    end
    if char:GetAttribute("IsRagdoll") == true or char:HasTag("stunned") then
        farm.status = "Stunned / ragdolled"
        return
    end

    local now = os.clock()
    if farm.mode == MODE_QUEST then
        ensureQuests(now)
    end
    ensureProfile(now)

    if now >= farm.nextDecide then
        farm.nextDecide = now + 0.2
        local ok, result = pcall(decideTask, now)
        farm.task = ok and result or idle("Task error: " .. tostring(result))
    end
    local task_ = farm.task
    if not task_ then
        return
    end

    -- A different task (new quest, new objective, new filter) drops the target
    local key = task_.kind .. ":" .. (task_.key or "")
    if key ~= farm.taskKey then
        farm.taskKey = key
        farm.target = nil
        farm.nextSearch = 0
    end

    if task_.kind == "kill" then
        stepKill(task_, root, dt, now)
    elseif task_.kind == "collect" then
        stepCollect(task_, root, dt, now)
    elseif task_.kind == "giver" then
        stepGiver(task_, root, dt, now)
    else
        farm.status = task_.text
    end
end

-- UI ----------------------------------------------------------------------------
local farmTab = window:AddTab("Farm")

farmTab:AddSection("Auto farm")
local farmToggle = farmTab:AddToggle("Auto farm", false, function(on)
    farm.enabled = on
    farm.target = nil
    if on then
        ensureWorldCache()
        farm.nextQuestFetch = 0
        farm.nextProfileFetch = 0
        farm.nextDecide = 0
    elseif not string.find(farm.status, "^Stopped") then
        farm.status = "Idle"
    end
end)
farmTab:AddDropdown("Mode", { MODE_QUEST, MODE_ENEMY }, farm.mode, function(choice)
    farm.mode = choice
end)
farmTab:AddTextbox("Enemy filter", "", "blank = any (a, b)", function(text)
    farm.filter = text
end)
farmTab:AddToggle("Auto accept / turn in quests", true, function(on)
    farm.autoQuest = on
end)
farmTab:AddToggle("Abandon quests I can't automate", false, function(on)
    farm.abandonUnsupported = on
end)
farmTab:AddDropdown("Attack method", { ATTACK_PRESS, ATTACK_SINGLE, ATTACK_CLICK }, farm.attackMode, function(choice)
    farm.attackMode = choice
end)
farmTab:AddToggle("Use skills (number keys)", false, function(on)
    farm.useSkills = on
end)
farmTab:AddSlider("Skill keys (1 to N)", 1, 4, 2, 1, function(value)
    farm.skillKeys = value
end)

farmTab:AddSection("Tuning")
farmTab:AddSlider("Move speed (studs/s)", 30, 300, 120, 5, function(value)
    farm.speed = value
end)
farmTab:AddSlider("Stand distance", 2, 10, 4, 1, function(value)
    farm.standDistance = value
end)
farmTab:AddSlider("Attack delay (ms)", 80, 600, 200, 10, function(value)
    farm.attackDelay = value / 1000
end)
farmTab:AddSlider("Level (if profile fetch fails)", 1, 200, 1, 1, function(value)
    farm.level = value
end)

farmTab:AddSection("Tools")
farmTab:AddButton("Print enemies in workspace.entities", function()
    local _, _, root = getCharacter()
    local folder = workspace:FindFirstChild("entities")
    if not (root and folder) then
        return window:Notify("No character or workspace.entities")
    end
    local rows = {}
    for _, model in ipairs(folder:GetChildren()) do
        local hum = model:FindFirstChildOfClass("Humanoid")
        local part = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
        if hum and part then
            local dist = (part.Position - root.Position).Magnitude
            table.insert(rows, {
                dist = dist,
                text = string.format("%-26s type %-22s hp %.0f/%.0f  %.0f studs",
                    model.Name, entityType(model), hum.Health, hum.MaxHealth, dist),
            })
        end
    end
    table.sort(rows, function(a, b) return a.dist < b.dist end)
    print(string.format("[Script GUI] %d entities, nearest first:", #rows))
    for index = 1, math.min(#rows, 25) do
        print("  " .. rows[index].text)
    end
    window:Notify(#rows .. " entities printed to the console")
end)
farmTab:AddButton("Refresh quests", function()
    fetchQuestData(function(data, err)
        window:Notify(data and "Quests refreshed" or ("Quest fetch failed: " .. tostring(err)))
    end)
end)

farmTab:AddSection("Status")
local farmLabel = farmTab:AddLabel("Idle")
updateFarmStatus = function()
    farmLabel:SetText(string.format("%s - %s", farm.enabled and "ON" or "OFF", farm.status))
end

window:Loop(function(dt)
    if not farm.enabled then
        return
    end
    local ok, err = pcall(stepFarm, dt)
    if not ok then
        farmToggle:Set(false)
        farm.status = "Stopped: " .. tostring(err)
        warn("[Script GUI] farm stopped: " .. tostring(err))
        window:Notify("Farm stopped (see console)", 8)
    end
end)

-- Auto tab --------------------------------------------------------------------
-- Standalone helpers for when you play yourself: attack enemies that come
-- within range, and accept the quest that fits your level. The farm does both
-- on its own while it is running, so these stand down then.
local auto = {
    attack = false,
    range = 12,
    face = true,
    accept = false,
    walk = true,
    side = false,
    target = nil,
    nextSearch = 0,
    nextAttack = 0,
    nextAccept = 0,
    attackStatus = "Off",
    acceptStatus = "Off",
}

local function stepAutoAttack(root, now)
    if farm.enabled then
        auto.attackStatus = "Farm is handling combat"
        return
    end
    local target = auto.target
    if target and not (target.Parent and target.Health > 0) then
        target = nil
    end
    if now >= auto.nextSearch then
        auto.nextSearch = now + 0.15
        target = nearestEnemy(root.Position, {}, now)
    end
    auto.target = target

    local model = target and target.Parent
    local part = model and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
    if not part then
        auto.attackStatus = "No enemy around"
        return
    end
    local dist = (part.Position - root.Position).Magnitude
    if dist > auto.range then
        auto.attackStatus = string.format("Nearest: %s (%.0f studs, out of range)", model.Name, dist)
        return
    end

    if auto.face then
        local look = Vector3.new(part.Position.X, root.Position.Y, part.Position.Z)
        if (look - root.Position).Magnitude > 0.05 then
            root.CFrame = CFrame.lookAt(root.Position, look)
        end
    end
    if now >= auto.nextAttack then
        auto.nextAttack = now + farm.attackDelay
        attack()
    end
    auto.attackStatus = string.format("Attacking %s (%.0f/%.0f hp)", model.Name, target.Health, target.MaxHealth)
end

local function stepAutoAccept(root, dt, now)
    if farm.enabled and farm.mode == MODE_QUEST and farm.autoQuest then
        auto.acceptStatus = "Farm is handling quests"
        return
    end
    ensureQuests(now)
    ensureProfile(now)
    local data = questState.data
    if not (questsModule and data) then
        auto.acceptStatus = "Fetching quests..."
        return
    end

    local entry = questsModule.get_current_entry(data) or questsModule.get_assigned_entry(data)
    if entry then
        farm.acceptTries[entry.id] = nil
        local active = questsModule.get_quest(entry.id)
        auto.acceptStatus = "Active quest: " .. (active and questName(active) or entry.id)
        return
    end

    local level = getLevel()
    local quest = pickQuest(data, level, now, { includeOptional = auto.side })
    if not quest then
        auto.acceptStatus = "No quest available at level " .. level
        return
    end
    auto.acceptStatus = "Accepting " .. questName(quest)

    -- The remote alone may be enough; only walk to the giver once it has failed twice
    local tries = farm.acceptTries[quest.id] or 0
    local near = true
    if auto.walk and tries >= 2 then
        local npc = findGiverNpc(quest.giver_id)
        local pivot = npc and pivotOf(npc)
        if pivot then
            local offset = root.Position - pivot.Position
            local dist = offset.Magnitude
            if dist > 7 then
                near = false
                approach(root, pivot.Position + offset.Unit * 4, pivot.Position, dt)
                auto.acceptStatus = "Walking to " .. quest.giver_id .. " to accept " .. questName(quest)
            end
        end
    end

    if near and now >= auto.nextAccept then
        auto.nextAccept = now + 1.5
        if tries >= 8 then
            -- Refused over and over (prerequisite, level cap...): try another one
            farm.skip[quest.id] = now + 120
            farm.acceptTries[quest.id] = nil
            return
        end
        farm.acceptTries[quest.id] = tries + 1
        Remotes.quests.accept.Fire(quest.id)
        farm.nextQuestFetch = now + 0.6
    end
end

local autoAttackToggle, autoAcceptToggle

local autoTab = window:AddTab("Auto")

autoTab:AddSection("Auto attack")
autoAttackToggle = autoTab:AddToggle("Attack enemies in range", false, function(on)
    auto.attack = on
    auto.target = nil
    auto.attackStatus = on and "Looking for enemies..." or "Off"
end)
autoTab:AddSlider("Attack range (studs)", 4, 40, 12, 1, function(value)
    auto.range = value
end)
autoTab:AddToggle("Face the enemy", true, function(on)
    auto.face = on
end)
autoTab:AddLabel("Uses the attack method and delay from the Farm tab.")
local autoAttackLabel = autoTab:AddLabel("Off")

autoTab:AddSection("Auto accept quests")
autoAcceptToggle = autoTab:AddToggle("Accept the quest for my level", false, function(on)
    auto.accept = on
    auto.acceptStatus = on and "Fetching quests..." or "Off"
    if on then
        farm.nextQuestFetch = 0
        farm.nextProfileFetch = 0
    end
end)
autoTab:AddToggle("Walk to the quest giver if needed", true, function(on)
    auto.walk = on
end)
autoTab:AddToggle("Include side quests", false, function(on)
    auto.side = on
end)
local autoAcceptLabel = autoTab:AddLabel("Off")
local autoLevelLabel = autoTab:AddLabel("")

updateAutoStatus = function()
    autoAttackLabel:SetText(auto.attackStatus)
    autoAcceptLabel:SetText(auto.acceptStatus)
    local data = questState.data
    if not (questsModule and data) then
        autoLevelLabel:SetText(string.format("Level %d%s", getLevel(), farm.profileLevel and "" or " (fallback slider on the Farm tab)"))
        return
    end
    local level = getLevel()
    local quest = pickQuest(data, level, os.clock(), { includeOptional = auto.side })
    if quest then
        autoLevelLabel:SetText(string.format(
            "Level %d - fitting quest: %s (levels %s-%s, giver %s)",
            level, questName(quest), tostring(quest.min_level or 1), tostring(quest.max_level or "?"), quest.giver_id
        ))
    else
        autoLevelLabel:SetText(string.format("Level %d - no unfinished quest fits", level))
    end
end

window:Loop(function(dt)
    if not (auto.attack or auto.accept) then
        return
    end
    local char, hum, root = getCharacter()
    if not (char and hum and root) or hum.Health <= 0 then
        return
    end
    local now = os.clock()
    local ok, err = pcall(function()
        if auto.attack and not (char:GetAttribute("IsRagdoll") == true or char:HasTag("stunned")) then
            stepAutoAttack(root, now)
        end
        if auto.accept then
            stepAutoAccept(root, dt, now)
        end
    end)
    if not ok then
        autoAttackToggle:Set(false)
        autoAcceptToggle:Set(false)
        warn("[Script GUI] auto features stopped: " .. tostring(err))
        window:Notify("Auto features stopped (see console)", 8)
    end
end)

-- Info tab --------------------------------------------------------------------
local info = window:AddTab("Info")
info:AddSection("Dash config")
if actions then
    info:AddLabel(string.format("Cooldown: %ss   Duration: %ss", actions.get_dash_cooldown(), actions.get_dash_duration()))
    info:AddLabel("Stamina cost at 100 max: " .. actions.get_dash_stamina_cost(100))
else
    info:AddLabel("character_actions module not loaded")
end
info:AddSection("Hotkeys")
info:AddLabel("RightShift: show / hide window")

-- Per-frame logic -------------------------------------------------------------
local nextStatus = 0
local statusEnabled = true

local function refreshStatus(char, humanoid)
    updateQuestStatus()
    updateFarmStatus()
    updateAutoStatus()
    local active = {}
    for _, tag in ipairs(STATUS_TAGS) do
        if char:HasTag(tag) then
            table.insert(active, tag)
        end
    end
    local canDash, canDouble = "?", "?"
    if actions and humanoid then
        local okDash, dashResult = pcall(actions.can_dash, char, humanoid)
        local okJump, jumpResult = pcall(actions.can_double_jump, char, humanoid)
        canDash = okDash and tostring(dashResult) or "err"
        canDouble = okJump and tostring(jumpResult) or "err"
    end
    statusLabel:SetText(string.format(
        "Tags: %s\nCan dash: %s   Can double jump: %s\nRagdoll: %s   Silenced: %s",
        #active > 0 and table.concat(active, ", ") or "none",
        canDash, canDouble,
        tostring(char:GetAttribute("IsRagdoll") == true),
        tostring(char:GetAttribute("silenced") == true)
    ))
end

window:Loop(function()
    local char, humanoid = getCharacter()
    if not char then
        return
    end

    if state.doubleJump and char:GetAttribute(DOUBLE_JUMP_ATTR) ~= true then
        char:SetAttribute(DOUBLE_JUMP_ATTR, true)
    end
    if state.sprint and not char:HasTag(SPRINT_TAG) then
        if actions then
            actions.set_sprint_tag(char, true)
        else
            char:AddTag(SPRINT_TAG)
        end
    end
    if state.speed and humanoid then
        humanoid.WalkSpeed = state.speedValue
    end

    local now = os.clock()
    if statusEnabled and now >= nextStatus then
        nextStatus = now + 0.25
        local ok, err = pcall(refreshStatus, char, humanoid)
        if not ok then
            -- Report once instead of flooding the console every tick
            statusEnabled = false
            warn("[Script GUI] status updates stopped: " .. tostring(err))
            window:Notify("Status updates stopped (see console)", 6)
        end
    end
end)

window:Notify(actions and "Loaded (character_actions found)" or "Loaded (character_actions NOT found)", 4)
