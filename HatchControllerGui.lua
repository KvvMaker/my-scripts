--[[
    Hatch Controller GUI
    Control panel for Players.<you>.PlayerScripts.Client.Modules.Hatch.HatchController

    TABS
      Hatch    pick an egg / pet / tier / rarity, how many eggs and the playback speed, then Play.
               Runs the game's own hatch showcase (HatchController.HatchEggs) with the data you picked.
      Effects  toggles for the client settings the controller reads (egg glow, camera shake, confetti,
               light rays, secret cutscenes, rare-hatch animation threshold).
      Tools    stop the running hatch, end a chained hatch, force the chain flag, dump module info.

    USAGE
      * RightShift toggles the window, "-" collapses it, "x" unloads it (re-executing also replaces the old copy).
      * Play is a client-side preview: it runs the animation with the data you chose. It does not hatch an
        egg on the server and gives you no pets.
      * The Effects toggles go through ClientSettings. The setter name is not known from the controller
        source, so several common names are tried and the result is read back; if none of them take,
        use Tools > Dump ClientSettings to see what the module actually exposes.
      * "Auto" rarity reads the pet's Rarity from PetsConfig; if the field is missing it falls back to Common.
]]

local env = (getgenv and getgenv()) or _G
if env.HatchControllerGuiUnload then
    pcall(env.HatchControllerGuiUnload)
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- require()-ing a game ModuleScript can leave the thread at a lower identity, after which anything connected
-- later can no longer touch the GUI. Remember the starting identity and put it back.
local getIdentity = getthreadidentity or getidentity or get_thread_identity
local setIdentity = setthreadidentity or setidentity or set_thread_identity
local startIdentity = getIdentity and getIdentity()
local function restoreIdentity()
    if setIdentity and startIdentity then
        pcall(setIdentity, startIdentity)
    end
end

-- The game's configs call require() lazily inside their functions (e.g. PetsConfig.GetCutsceneName). Run from the
-- executor's elevated identity that throws "Cannot require a non-RobloxScript module from a RobloxScript", so game
-- functions are called at a normal LocalScript identity, then this script's own identity is put back.
local GAME_IDENTITY = 2
local function asGame(fn, ...)
    if setIdentity then
        pcall(setIdentity, GAME_IDENTITY)
    end
    local results = table.pack(pcall(fn, ...))
    restoreIdentity()
    if not results[1] then
        warn("[HatchGui] " .. tostring(results[2]))
    end
    return table.unpack(results, 1, results.n)
end

--------------------------------------------------------------------------------
-- Locate the game's modules
--------------------------------------------------------------------------------

local function findPath(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do
        if not node then
            return nil
        end
        node = node:WaitForChild(name, 10)
    end
    return node
end

local function tryRequire(module)
    if not module then
        return nil
    end
    local ok, result = pcall(require, module)
    restoreIdentity()
    if ok then
        return result
    end
    warn("[HatchGui] require failed for " .. module:GetFullName() .. ": " .. tostring(result))
    return nil
end

local playerScripts = player:WaitForChild("PlayerScripts")
local hatchFolder = findPath(playerScripts, "Client", "Modules", "Hatch")
local HatchController = tryRequire(hatchFolder and hatchFolder:FindFirstChild("HatchController"))
if type(HatchController) ~= "table" then
    warn("[HatchGui] HatchController not found at PlayerScripts.Client.Modules.Hatch.HatchController")
    return
end

local Rarities = tryRequire(hatchFolder:FindFirstChild("Modules") and hatchFolder.Modules:FindFirstChild("Rarities")) or {}
local shared = ReplicatedStorage:FindFirstChild("Shared")
local configs = shared and shared:FindFirstChild("Configs")
local EggsConfig = tryRequire(configs and configs:FindFirstChild("EggsConfig")) or {}
local PetsConfig = tryRequire(configs and configs:FindFirstChild("PetsConfig")) or {}
local ClientSettings = tryRequire(shared and shared:FindFirstChild("Modules") and shared.Modules:FindFirstChild("ClientSettings"))

local assets = ReplicatedStorage:FindFirstChild("Assets")
local eggModels = assets and assets:FindFirstChild("Eggs")

--------------------------------------------------------------------------------
-- Data helpers
--------------------------------------------------------------------------------

local function sortedKeys(tbl)
    local keys = {}
    if type(tbl) == "table" then
        for key in pairs(tbl) do
            table.insert(keys, tostring(key))
        end
    end
    table.sort(keys)
    return keys
end

local function listEggs()
    local names = {}
    if eggModels then
        for _, child in ipairs(eggModels:GetChildren()) do
            table.insert(names, child.Name)
        end
    end
    if #names == 0 then
        names = sortedKeys(EggsConfig.Eggs)
    end
    table.sort(names)
    if #names == 0 then
        names = { "Basic" }
    end
    return names
end

local function eggConfig(eggName, exclusive)
    if exclusive and type(EggsConfig.GetExclusiveEgg) == "function" then
        local ok, result = pcall(EggsConfig.GetExclusiveEgg, eggName)
        if ok and type(result) == "table" then
            return result
        end
    end
    return type(EggsConfig.Eggs) == "table" and EggsConfig.Eggs[eggName] or nil
end

local function petPool(eggName, exclusive)
    local cfg = eggConfig(eggName, exclusive)
    local pool = cfg and type(cfg.Pets) == "table" and sortedKeys(cfg.Pets) or {}
    if #pool == 0 then
        pool = sortedKeys(PetsConfig.Pets)
    end
    return pool
end

local function rarityOf(petName)
    local cfg = type(PetsConfig.Pets) == "table" and PetsConfig.Pets[petName]
    local rarity = type(cfg) == "table" and (cfg.Rarity or (type(cfg.Stats) == "table" and cfg.Stats.Rarity))
    if type(rarity) == "string" and (#Rarities == 0 or table.find(Rarities, rarity)) then
        return rarity
    end
    return "Common"
end

--------------------------------------------------------------------------------
-- UI library
--------------------------------------------------------------------------------

local Theme = {
    Background = Color3.fromRGB(22, 22, 28),
    Topbar = Color3.fromRGB(30, 30, 38),
    Element = Color3.fromRGB(36, 36, 46),
    ElementHover = Color3.fromRGB(48, 48, 60),
    Accent = Color3.fromRGB(255, 170, 60),
    Text = Color3.fromRGB(235, 235, 245),
    SubText = Color3.fromRGB(150, 150, 170),
    Good = Color3.fromRGB(90, 210, 130),
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

local WIDTH, HEIGHT = 500, 380

function Window.new(title)
    local self = setmetatable({ tabs = {}, connections = {}, activeTab = nil }, Window)

    local gui = create("ScreenGui", {
        Name = "HatchControllerGui",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 2000,
    })
    -- The hatch controller disables every other ScreenGui while it plays unless this is set.
    gui:SetAttribute("KeepDuringHatch", true)
    self.gui = gui

    local main = create("Frame", {
        Name = "Main",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(WIDTH, HEIGHT),
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = gui,
    }, { corner(8) })
    self.main = main

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

    local body = create("Frame", {
        Position = UDim2.fromOffset(0, 32),
        Size = UDim2.new(1, 0, 1, -32),
        BackgroundTransparency = 1,
        Parent = main,
    })

    self.sidebar = create("Frame", {
        Size = UDim2.new(0, 110, 1, -24),
        BackgroundTransparency = 1,
        Parent = body,
    }, {
        create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
        create("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
    })

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
        TextTruncate = Enum.TextTruncate.AtEnd,
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

    local minimized = false
    self:Connect(minimize.MouseButton1Click, function()
        minimized = not minimized
        body.Visible = not minimized
        tween(main, { Size = UDim2.fromOffset(WIDTH, minimized and 32 or HEIGHT) }, 0.2)
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

-- Runs fn(dt) once per frame from a thread started by the script itself (keeps this script's permissions).
function Window:Loop(fn)
    local alive = true
    table.insert(self.connections, { Disconnect = function() alive = false end })
    task.spawn(function()
        while alive do
            local dt = RunService.Heartbeat:Wait()
            restoreIdentity()
            local ok, err = pcall(fn, dt)
            if not ok then
                warn("[HatchGui] loop stopped: " .. tostring(err))
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
    return {
        SetText = function(_, value) label.Text = value end,
        SetColor = function(_, value) label.TextColor3 = value end,
    }
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
    return { Set = function(_, v, silent) set(v, silent) end, Get = function() return value end }
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
    -- Taller invisible hit area so the thin bar is easy to grab
    local hit = create("TextButton", {
        Text = "",
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 0, 1, -26),
        Size = UDim2.new(1, 0, 0, 26),
        Parent = row,
    })

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

    local dragging = false
    self.window:Connect(hit.InputBegan, function(input)
        if isPointer(input) then
            dragging = true
            fromInput(input)
        end
    end)
    self.window:Connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            fromInput(input)
        end
    end)
    self.window:Connect(UserInputService.InputEnded, function(input)
        if isPointer(input) then
            dragging = false
        end
    end)

    set(value, true)
    return { Set = function(_, v, silent) set(v, silent) end, Get = function() return value end }
end

-- "< value >" picker; click the value or the arrows to step through the options.
function Tab:AddCycle(text, options, default, callback)
    local index = table.find(options, default) or 1
    local row = self:_row(32)
    self:_label(row, text, UDim2.new(1, -200, 1, 0), UDim2.fromOffset(10, 0))

    local function small(label, xOffset, width)
        return create("TextButton", {
            Text = label,
            Font = Theme.FontBold,
            TextSize = 12,
            TextColor3 = Theme.Text,
            TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundColor3 = Theme.ElementHover,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, xOffset, 0.5, 0),
            Size = UDim2.fromOffset(width, 22),
            Parent = row,
        }, { corner(5) })
    end
    local nextButton = small(">", -8, 22)
    local valueButton = small(tostring(options[index] or "-"), -34, 130)
    local prevButton = small("<", -168, 22)

    local self_ = {}
    local function render()
        valueButton.Text = tostring(options[index] or "-")
    end
    local function step(delta, silent)
        if #options == 0 then
            return
        end
        index = (index - 1 + delta) % #options + 1
        render()
        if not silent and callback then
            task.spawn(callback, options[index])
        end
    end

    self.window:Connect(nextButton.MouseButton1Click, function() step(1) end)
    self.window:Connect(valueButton.MouseButton1Click, function() step(1) end)
    self.window:Connect(prevButton.MouseButton1Click, function() step(-1) end)

    function self_.Get()
        return options[index]
    end
    function self_.SetOptions(_, list, keepSelection)
        local current = options[index]
        options = list
        index = (keepSelection and table.find(list, current)) or 1
        render()
    end
    return self_
end

--------------------------------------------------------------------------------
-- Build the window
--------------------------------------------------------------------------------

local window = Window.new("Hatch Controller")

local state = {
    egg = nil,
    pet = "Random",
    tier = "None",
    rarity = "Auto",
    count = 1,
    speed = 1,
    exclusive = false,
    repeating = false,
}

local MAX_OPEN = math.max(2, tonumber(EggsConfig.MAX_OPEN) or 8) -- slider needs max > min
local eggNames = listEggs()
state.egg = eggNames[1]

local function currentPool()
    local pool = { "Random" }
    for _, name in ipairs(petPool(state.egg, state.exclusive)) do
        table.insert(pool, name)
    end
    return pool
end

local function buildPets()
    local pool = petPool(state.egg, state.exclusive)
    local pets = {}
    for i = 1, state.count do
        local name = state.pet
        if name == "Random" or not table.find(pool, name) then
            name = pool[math.random(#pool)]
        end
        pets[i] = {
            PetName = name,
            Tier = state.tier,
            Rarity = state.rarity ~= "Auto" and state.rarity or rarityOf(name),
            AutoDeleted = false,
        }
    end
    return pets
end

local function isActive()
    return HatchController.IsActive == true
end

local function playHatch()
    if isActive() then
        window:Notify("A hatch is already running")
        return false
    end
    local pets = buildPets()
    if #pets == 0 then
        window:Notify("No pets available for that egg")
        return false
    end
    window:Notify(("Hatching %d x %s"):format(#pets, state.egg))
    asGame(HatchController.HatchEggs, state.egg, pets, state.speed, { exclusive = state.exclusive })
    return true
end

-- Hatch tab ---------------------------------------------------------------
local hatchTab = window:AddTab("Hatch")
local statusLabel = hatchTab:AddLabel("Status: idle")

hatchTab:AddSection("Preview")
local petCycle
hatchTab:AddCycle("Egg", eggNames, state.egg, function(value)
    state.egg = value
    petCycle:SetOptions(currentPool(), true)
    state.pet = petCycle.Get()
end)
petCycle = hatchTab:AddCycle("Pet", currentPool(), state.pet, function(value)
    state.pet = value
end)
hatchTab:AddCycle("Tier", { "None", "Golden", "Rainbow" }, state.tier, function(value)
    state.tier = value
end)

local rarityOptions = { "Auto" }
for _, rarity in ipairs(Rarities) do
    table.insert(rarityOptions, rarity)
end
hatchTab:AddCycle("Rarity", rarityOptions, state.rarity, function(value)
    state.rarity = value
end)
hatchTab:AddSlider("Eggs at once", 1, MAX_OPEN, 1, 1, function(value)
    state.count = value
end)
hatchTab:AddSlider("Speed", 0.5, 5, 1, 0.5, function(value)
    state.speed = value
end)
hatchTab:AddToggle("Exclusive (premium) showcase", false, function(value)
    state.exclusive = value
    petCycle:SetOptions(currentPool(), true)
    state.pet = petCycle.Get()
end)

hatchTab:AddSection("Run")
hatchTab:AddButton("Play hatch", playHatch)
hatchTab:AddButton("Stop hatch", function()
    asGame(HatchController.ForceStop)
    window:Notify("Hatch stopped")
end)

local repeatToken = 0
hatchTab:AddToggle("Repeat until turned off", false, function(value)
    state.repeating = value
    repeatToken += 1
    if not value then
        return
    end
    local token = repeatToken
    while state.repeating and repeatToken == token and window.gui.Parent do
        if not isActive() then
            playHatch()
        end
        task.wait(0.5)
    end
end)

local lastStatus
local statusClock = 0
window:Loop(function(dt)
    statusClock += dt
    if statusClock < 0.2 then
        return
    end
    statusClock = 0
    local chained = type(HatchController.IsChained) == "function" and HatchController.IsChained()
    local text = isActive() and "Status: hatching" or (chained and "Status: chained (waiting for next hatch)" or "Status: idle")
    if text ~= lastStatus then
        lastStatus = text
        statusLabel:SetText(text)
        statusLabel:SetColor(isActive() and Theme.Good or Theme.SubText)
    end
end)

-- Effects tab -------------------------------------------------------------
local effectsTab = window:AddTab("Effects")

local SETTER_NAMES = { "set", "Set", "setSetting", "SetSetting", "setEnabled", "SetEnabled", "update", "Update" }

local function readSetting(key)
    if not ClientSettings then
        return nil
    end
    local ok, value = pcall(function()
        if type(ClientSettings.get) == "function" then
            return ClientSettings.get(key)
        end
        return ClientSettings[key]
    end)
    if ok and value ~= nil then
        return value
    end
    if type(ClientSettings.isEnabled) == "function" then
        local okEnabled, enabled = pcall(ClientSettings.isEnabled, key)
        if okEnabled then
            return enabled
        end
    end
    return nil
end

-- Tries the usual setter names (with and without self) and keeps the first one whose result reads back.
local function writeSetting(key, value)
    if not ClientSettings then
        return false
    end
    for _, name in ipairs(SETTER_NAMES) do
        local fn = ClientSettings[name]
        if type(fn) == "function" then
            for _, withSelf in ipairs({ false, true }) do
                local ok
                if withSelf then
                    ok = pcall(fn, ClientSettings, key, value)
                else
                    ok = pcall(fn, key, value)
                end
                if ok and readSetting(key) == value then
                    return true
                end
            end
        end
    end
    return false
end

if not ClientSettings then
    effectsTab:AddLabel("ClientSettings module not found, so these toggles are unavailable.")
else
    effectsTab:AddSection("Hatch effects")
    local function settingToggle(label, key)
        local current = readSetting(key)
        if current == nil and type(ClientSettings.isEnabled) == "function" then
            local ok, enabled = pcall(ClientSettings.isEnabled, key)
            current = ok and enabled or false
        end
        local toggle
        toggle = effectsTab:AddToggle(label, current == true, function(value)
            if writeSetting(key, value) then
                window:Notify(("%s: %s"):format(key, value and "on" or "off"))
            else
                toggle:Set(not value, true)
                window:Notify("Couldn't set " .. key .. " (see Tools > Dump ClientSettings)", 5)
            end
        end)
    end
    settingToggle("Egg glow", "HatchEggGlow")
    settingToggle("Camera shake + FOV punch", "HatchCameraShake")
    settingToggle("Confetti", "HatchConfetti")
    settingToggle("Light rays", "HatchLightRays")
    settingToggle("Secret cutscenes", "SecretCutscenes")

    effectsTab:AddSection("Rare hatch animation")
    local threshold = readSetting("RareHatchAnimations")
    local thresholdOptions = { "Off", "Epic+", "Mythical" }
    effectsTab:AddCycle("Longer charge for", thresholdOptions, table.find(thresholdOptions, threshold) and threshold or "Off", function(value)
        if writeSetting("RareHatchAnimations", value) then
            window:Notify("RareHatchAnimations: " .. value)
        else
            window:Notify("Couldn't set RareHatchAnimations", 5)
        end
    end)
end

-- Tools tab ---------------------------------------------------------------
local toolsTab = window:AddTab("Tools")
toolsTab:AddSection("Controller")
toolsTab:AddButton("Force stop (restore HUD + camera)", function()
    asGame(HatchController.ForceStop)
    window:Notify("Force stopped")
end)
toolsTab:AddButton("End chain", function()
    if type(HatchController.EndChain) == "function" then
        asGame(HatchController.EndChain)
    end
    window:Notify("Chain ended")
end)

local originalShouldChain = HatchController.ShouldChain
toolsTab:AddToggle("Keep camera/HUD between hatches (chain)", originalShouldChain ~= nil, function(value)
    if value then
        HatchController.ShouldChain = function() return true end
    else
        HatchController.ShouldChain = originalShouldChain
        if type(HatchController.EndChain) == "function" then
            asGame(HatchController.EndChain)
        end
    end
end)

toolsTab:AddSection("Debug")
toolsTab:AddButton("Dump ClientSettings", function()
    if not ClientSettings then
        window:Notify("ClientSettings not loaded")
        return
    end
    print("[HatchGui] ClientSettings (" .. type(ClientSettings) .. ")")
    for key, value in pairs(ClientSettings) do
        print("  ", key, typeof(value), type(value) ~= "function" and tostring(value) or "")
    end
    window:Notify("Dumped to the console (F9)")
end)
toolsTab:AddButton("Dump HatchController", function()
    print("[HatchGui] HatchController")
    for key, value in pairs(HatchController) do
        print("  ", key, typeof(value), type(value) ~= "function" and tostring(value) or "")
    end
    window:Notify("Dumped to the console (F9)")
end)

local hatchingGui = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("Hatching")
toolsTab:AddSection("Environment")
toolsTab:AddLabel(("Hatching ScreenGui: %s\nEgg models: %s\nMax eggs at once: %d\nRarities: %s"):format(
    hatchingGui and "found" or "missing",
    eggModels and tostring(#eggModels:GetChildren()) or "Assets.Eggs missing",
    MAX_OPEN,
    #Rarities > 0 and table.concat(Rarities, ", ") or "unknown"
))

-- Unload ----------------------------------------------------------------
window.onDestroy = function()
    state.repeating = false
    repeatToken += 1
    if HatchController.ShouldChain ~= originalShouldChain then
        HatchController.ShouldChain = originalShouldChain
    end
    env.HatchControllerGuiUnload = nil
end
env.HatchControllerGuiUnload = function()
    window:Destroy()
end

window:Notify("Loaded. RightShift hides/shows the window.")
