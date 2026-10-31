-- Mob auto farm with a GUI. Run it in your executor.
-- Start/stop from the window or with ToggleKey; GuiKey hides/shows the window.
-- Re-executing replaces the previous instance. Control it from getgenv().AutoFarm.
-- "Auto quest" follows the quest that fits your level: it hunts that quest's enemy type and
-- walks you to the quest giver when the quest has to be accepted or turned in.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local env = getgenv and getgenv() or _G
if env.AutoFarm then
    env.AutoFarm.Destroy()
end

local player = Players.LocalPlayer

local Config = {
    MobFolder = Workspace:FindFirstChild("Enemies"), -- nil scans all of workspace
    MobNames = {},              -- e.g. { "Bandit", "Goblin" }; empty targets every NPC
    UseSkills = false,
    AutoQuest = false,          -- hunt the quest for your level (see questPlan)
    ServerAuto = true,          -- also switch on the game's own "Auto Questing" for that quest
    ToggleKey = Enum.KeyCode.RightControl,
    GuiKey = Enum.KeyCode.RightShift,
    Speed = 120,                -- studs/second while closing in on a mob
    Distance = 3,               -- how far behind the mob to stand
    Height = 0,                 -- vertical offset from the mob's root
    AttackInterval = 0.12,      -- seconds between hits
    Skills = {},                -- e.g. { Enum.KeyCode.Z, Enum.KeyCode.X }
    SkillInterval = 3,          -- seconds between skill key presses
    RescanInterval = 1,         -- seconds between mob list refreshes
}

-- The game's M1 hitbox is a sphere `forward` studs in front of the root, so standing
-- exactly that far from a mob puts the sphere's centre on it.
pcall(function()
    local sphere = require(ReplicatedStorage.Modules.CombatConfig).m1Sphere
    if type(sphere.forward) == "number" then
        Config.Distance = sphere.forward
    end
end)

-- The game's own quest and enemy configs say which quest fits a level and what to hunt.
local QuestConfig, EnemyConfig
pcall(function()
    QuestConfig = require(ReplicatedStorage.Modules.Quest.QuestConfig)
    EnemyConfig = require(ReplicatedStorage.Modules.Enemy.EnemyConfig)
end)

local enabled = false
local alive = true
local target = nil
local mobs = {}
local plan = nil        -- what the level quest needs right now, nil when Auto quest is off
local lastTalk = 0
local lastAuto = 0
local connections = {}
local gui = nil
local window = nil
local onToggled = nil
local cursor = nil      -- last real (non-synthetic) cursor position, screen space
local lastClick = nil   -- where our own synthetic click landed
local binding = false   -- true while the window is waiting for a new key

local function notify(text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = "AutoFarm", Text = text, Duration = 2 })
    end)
end

local function isMob(model)
    if not model:IsA("Model") or Players:GetPlayerFromCharacter(model) then
        return false
    end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 or not model:FindFirstChild("HumanoidRootPart") then
        return false
    end
    local hunt = plan and plan.hunt
    if hunt then
        return model:GetAttribute(EnemyConfig.attribute) == hunt and not model:GetAttribute("ExamOwner")
    end
    return #Config.MobNames == 0 or table.find(Config.MobNames, model.Name) ~= nil
end

local function scan()
    local found = {}
    local folder = Config.MobFolder or Workspace
    if plan and plan.hunt then
        folder = Workspace:FindFirstChild(EnemyConfig.liveFolder) or folder
    end
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("Humanoid") and inst.Parent and isMob(inst.Parent) then
            table.insert(found, inst.Parent)
        end
    end
    return found
end

-- Every NPC name in scope, dead or alive, plus anything already selected.
local function collectNames()
    local seen, names = {}, {}
    local function add(name)
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for _, inst in ipairs((Config.MobFolder or Workspace):GetDescendants()) do
        local model = inst:IsA("Humanoid") and inst.Parent
        if model and model:IsA("Model") and not Players:GetPlayerFromCharacter(model) then
            add(model.Name)
        end
    end
    for _, name in ipairs(Config.MobNames) do
        add(name)
    end
    table.sort(names)
    return names
end

local function nearest(list, origin)
    local best, bestDistance = nil, math.huge
    for _, mob in ipairs(list) do
        local root = mob:FindFirstChild("HumanoidRootPart")
        if root then
            local distance = (root.Position - origin).Magnitude
            if distance < bestDistance then
                best, bestDistance = mob, distance
            end
        end
    end
    return best
end

local function targetValid()
    if not target or not target.Parent then
        return false
    end
    local humanoid = target:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0 and target:FindFirstChild("HumanoidRootPart") ~= nil
end

local function getCharacter()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if root and humanoid and humanoid.Health > 0 then
        return root
    end
end

local function inRange()
    local root = getCharacter()
    if not root or not targetValid() then
        return false
    end
    return (root.Position - target.HumanoidRootPart.Position).Magnitude <= Config.Distance + 8
end

local function findNpc(id, from)
    local best, bestDistance = nil, math.huge
    for _, model in ipairs(QuestConfig.npcModels()) do
        if model:GetAttribute(QuestConfig.attribute) == id then
            local distance = (model:GetPivot().Position - from).Magnitude
            if distance < bestDistance then
                best, bestDistance = model, distance
            end
        end
    end
    return best
end

-- Where an enemy type spawns, for when none of them are alive yet.
local function nearestSpawn(enemyType, from)
    local folder = Workspace:FindFirstChild(EnemyConfig.spawnFolder)
    local best, bestDistance = nil, math.huge
    for _, part in ipairs(folder and folder:GetChildren() or {}) do
        if part:IsA("BasePart") and part:GetAttribute(EnemyConfig.attribute) == enemyType then
            local distance = (part.Position - from).Magnitude
            if distance < bestDistance then
                best, bestDistance = part.Position, distance
            end
        end
    end
    return best
end

local function autoEnabled(id)
    local HttpService = game:GetService("HttpService")
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, player:GetAttribute("AutoQuests") or "{}")
    return QuestConfig.autoOn(ok and decoded or nil, player:GetAttribute("AutoQuest"), id)
end

-- What the quest for the player's level needs right now.
--   hunt: enemy type to kill            goal: where that type spawns, for when none are alive
--   npc:  quest giver to visit          hold: stand down from fighting while visiting them
local function questPlan(root)
    local quest = QuestConfig.forLevel(player:GetAttribute("Level") or 1)
    if not quest then
        return { text = "No quest for your level" }
    end

    local name = tostring(quest.display or quest.id)
    local state = QuestConfig.activeFor(player)[quest.id]
    local hunt = quest.kind == "kill" and quest.target or nil
    local goal = hunt and nearestSpawn(hunt, root.Position)

    if state and not state.ready then
        local remotes = ReplicatedStorage:FindFirstChild("Remotes")
        local remote = remotes and remotes:FindFirstChild("Quest")
        if Config.ServerAuto and remote and not (quest.tutorial or quest.daily or quest.noAuto)
            and not autoEnabled(quest.id) and os.clock() - lastAuto > 5 then
            lastAuto = os.clock()
            remote:FireServer("auto", quest.id, true)
        end
        local ok, objective = pcall(QuestConfig.objective, quest, state.count or 0)
        return { text = name .. ": " .. (ok and tostring(objective) or "in progress"), hunt = hunt, goal = goal }
    end

    if not state and quest.repeatable == false and player:GetAttribute("QuestDone_" .. quest.id) then
        return { text = name .. " done, hunting for levels", hunt = hunt, goal = goal }
    end

    return {
        text = ("%s %s (%s)"):format(state and "Turn in" or "Accept", name, tostring(quest.giver)),
        npc = findNpc(quest.giver, root.Position),
        hold = true,
    }
end

-- Moves the root toward a point at the capped speed; true once within `stop` studs of it.
local function approach(root, point, stop, dt)
    local delta = point - root.Position
    if delta.Magnitude <= stop then
        return true
    end
    local step = math.min(delta.Magnitude - stop, Config.Speed * dt)
    root.CFrame = CFrame.new(root.Position + delta.Unit * step) * root.CFrame.Rotation
    root.AssemblyLinearVelocity = Vector3.zero
    return false
end

local function follow(dt)
    if not enabled then
        return
    end
    local root = getCharacter()
    if not root then
        target = nil
        return
    end

    if plan and plan.hold then
        target = nil
        if plan.npc then
            approach(root, plan.npc:GetPivot().Position, 6, dt)
        end
        return
    end

    if not targetValid() then
        target = nearest(mobs, root.Position)
    end
    if not target then
        if plan and plan.goal then
            approach(root, plan.goal + Vector3.new(0, 3, 0), 4, dt)
        end
        return
    end

    local targetRoot = target.HumanoidRootPart
    local goal = (targetRoot.CFrame * CFrame.new(0, Config.Height, Config.Distance)).Position
    local delta = goal - root.Position
    local stepSize = Config.Speed * dt
    local position = delta.Magnitude <= stepSize and goal or root.Position + delta.Unit * stepSize

    root.CFrame = CFrame.lookAt(position, Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z))
    root.AssemblyLinearVelocity = Vector3.zero
end

local function overWindow(point)
    if not (window and gui and gui.Enabled) then
        return false
    end
    local position, size = window.AbsolutePosition, window.AbsoluteSize
    return point.X >= position.X and point.X <= position.X + size.X
        and point.Y >= position.Y and point.Y <= position.Y + size.Y
end

-- A synthetic click relocates the engine's cursor, which makes the window's buttons
-- impossible to hit. So stay quiet while the real cursor is over the window, and never
-- click on top of it.
local function click()
    if cursor and overWindow(cursor) then
        return
    end
    local viewport = Workspace.CurrentCamera.ViewportSize
    for _, fraction in ipairs({ 0.5, 0.75, 0.9 }) do
        local point = Vector2.new(viewport.X * fraction, viewport.Y / 2)
        if not overWindow(point) then
            lastClick = point
            VirtualInputManager:SendMouseButtonEvent(point.X, point.Y, 0, true, game, 0)
            VirtualInputManager:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
            return
        end
    end
end

local function pressKey(key)
    VirtualInputManager:SendKeyEvent(true, key, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, key, false, game)
end

local function toggle()
    enabled = not enabled
    target = nil
    if enabled then
        mobs = scan()
    end
    if onToggled then
        onToggled()
    end
    notify(enabled and "Enabled" or "Disabled")
end

-- Prints every NPC model type found so you can fill in Config.MobNames / MobFolder.
local function printScan()
    local counts = {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Humanoid") and inst.Parent and inst.Parent:IsA("Model")
            and not Players:GetPlayerFromCharacter(inst.Parent) then
            local key = inst.Parent.Parent:GetFullName() .. " :: " .. inst.Parent.Name
            counts[key] = (counts[key] or 0) + 1
        end
    end
    for key, count in pairs(counts) do
        print(("%s x%d"):format(key, count))
    end
end

local function destroy()
    alive = false
    enabled = false
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    if gui then
        gui:Destroy()
    end
    env.AutoFarm = nil
end

-- GUI --------------------------------------------------------------------

local WINDOW_WIDTH, WINDOW_HEIGHT, TITLE_HEIGHT = 300, 520, 34

local theme = {
    window = Color3.fromRGB(24, 24, 30),
    panel = Color3.fromRGB(36, 36, 46),
    text = Color3.fromRGB(235, 235, 240),
    muted = Color3.fromRGB(150, 150, 165),
    accent = Color3.fromRGB(88, 101, 242),
    on = Color3.fromRGB(67, 181, 129),
    off = Color3.fromRGB(237, 66, 69),
}

local DIGITS = { [0] = "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }

local function new(class, props, parent)
    local inst = Instance.new(class)
    for key, value in pairs(props) do
        inst[key] = value
    end
    inst.Parent = parent
    return inst
end

local function merge(base, extra)
    for key, value in pairs(extra or {}) do
        base[key] = value
    end
    return base
end

local function round(parent, radius)
    return new("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

local function label(parent, text, props)
    return new("TextLabel", merge({
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = theme.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, props), parent)
end

local function button(parent, text, color, props)
    local instance = new("TextButton", merge({
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Text = text,
        TextColor3 = theme.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
    }, props), parent)
    round(instance, 5)
    return instance
end

local function textBox(parent, text, props)
    local instance = new("TextBox", merge({
        BackgroundColor3 = theme.window,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Text = text,
        PlaceholderColor3 = theme.muted,
        TextColor3 = theme.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
    }, props), parent)
    round(instance, 4)
    return instance
end

local function parseKeys(text)
    local keys = {}
    for token in text:gmatch("[^%s,]+") do
        local name = token
        local digit = tonumber(token)
        if digit and DIGITS[digit] then
            name = DIGITS[digit]
        elseif #token == 1 then
            name = token:upper()
        end
        local ok, key = pcall(function()
            return Enum.KeyCode[name]
        end)
        if ok and key then
            table.insert(keys, key)
        end
    end
    return keys
end

local function keyNames(keys)
    local names = {}
    for _, key in ipairs(keys) do
        table.insert(names, key.Name)
    end
    return table.concat(names, ",")
end

local function buildGui()
    gui = new("ScreenGui", {
        Name = "AutoFarmGui",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 100,
        IgnoreGuiInset = true,
    })

    local main = new("Frame", {
        Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT),
        Position = UDim2.new(0, 40, 0.5, -WINDOW_HEIGHT / 2),
        BackgroundColor3 = theme.window,
        BorderSizePixel = 0,
        Active = true,
    }, gui)
    round(main, 8)
    window = main

    local titleBar = new("Frame", {
        Size = UDim2.new(1, 0, 0, TITLE_HEIGHT),
        BackgroundTransparency = 1,
    }, main)
    label(titleBar, "Auto Farm", {
        Size = UDim2.new(1, -70, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 14,
    })
    new("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = theme.panel,
        BorderSizePixel = 0,
    }, titleBar)

    local minimize = button(titleBar, "-", theme.panel, {
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, -60, 0.5, -12),
    })
    local close = button(titleBar, "x", theme.off, {
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, -32, 0.5, -12),
    })

    local body = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -TITLE_HEIGHT),
        Position = UDim2.fromOffset(0, TITLE_HEIGHT),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, main)
    new("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, body)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
    }, body)

    local order = 0
    local function slot()
        order += 1
        return order
    end

    local function row(height)
        local frame = new("Frame", {
            Size = UDim2.new(1, 0, 0, height or 30),
            BackgroundColor3 = theme.panel,
            BorderSizePixel = 0,
            LayoutOrder = slot(),
        }, body)
        round(frame)
        return frame
    end

    local startButton = button(body, "", theme.on, {
        Size = UDim2.new(1, 0, 0, 36),
        LayoutOrder = slot(),
        TextSize = 14,
    })
    local status = label(body, "", {
        Size = UDim2.new(1, 0, 0, 44),
        LayoutOrder = slot(),
        TextColor3 = theme.muted,
        TextSize = 12,
        TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top,
    })

    local function toggleRow(text, key)
        local frame = row()
        label(frame, text, {
            Size = UDim2.new(1, -70, 1, 0),
            Position = UDim2.fromOffset(10, 0),
        })
        local pill = button(frame, "", theme.off, {
            Size = UDim2.fromOffset(48, 20),
            Position = UDim2.new(1, -58, 0.5, -10),
            TextSize = 11,
        })
        local function render()
            pill.Text = Config[key] and "ON" or "OFF"
            pill.BackgroundColor3 = Config[key] and theme.on or theme.off
        end
        pill.MouseButton1Click:Connect(function()
            Config[key] = not Config[key]
            render()
        end)
        render()
    end

    local function numberRow(text, key, min, max)
        local frame = row()
        label(frame, text, {
            Size = UDim2.new(1, -90, 1, 0),
            Position = UDim2.fromOffset(10, 0),
        })
        local box = textBox(frame, tostring(Config[key]), {
            Size = UDim2.fromOffset(70, 22),
            Position = UDim2.new(1, -80, 0.5, -11),
        })
        box.FocusLost:Connect(function()
            local value = tonumber(box.Text)
            if value then
                Config[key] = math.clamp(value, min, max)
            end
            box.Text = tostring(Config[key])
        end)
    end

    local function bindRow(text, key)
        local frame = row()
        label(frame, text, {
            Size = UDim2.new(1, -120, 1, 0),
            Position = UDim2.fromOffset(10, 0),
        })
        local bind = button(frame, Config[key].Name, theme.window, {
            Size = UDim2.fromOffset(100, 22),
            Position = UDim2.new(1, -110, 0.5, -11),
            TextSize = 12,
        })
        bind.MouseButton1Click:Connect(function()
            if binding then
                return
            end
            binding = true
            bind.Text = "Press a key..."
            local input
            repeat
                input = UserInputService.InputBegan:Wait()
            until input.UserInputType == Enum.UserInputType.Keyboard
            if input.KeyCode ~= Enum.KeyCode.Escape then
                Config[key] = input.KeyCode
            end
            bind.Text = Config[key].Name
            task.wait(0.1)
            binding = false
        end)
    end

    bindRow("Start/stop key", "ToggleKey")
    bindRow("Show/hide key", "GuiKey")
    toggleRow("Auto quest (my level)", "AutoQuest")
    toggleRow("Game's Auto Questing", "ServerAuto")
    toggleRow("Auto skills", "UseSkills")
    numberRow("Speed (studs/s)", "Speed", 1, 500)
    numberRow("Distance behind mob", "Distance", 0, 30)
    numberRow("Height offset", "Height", -20, 30)
    numberRow("Attack delay (s)", "AttackInterval", 0.03, 5)
    numberRow("Skill delay (s)", "SkillInterval", 0.1, 60)

    local skillsRow = row()
    label(skillsRow, "Skill keys", {
        Size = UDim2.new(0, 80, 1, 0),
        Position = UDim2.fromOffset(10, 0),
    })
    local skillsBox = textBox(skillsRow, keyNames(Config.Skills), {
        Size = UDim2.new(1, -100, 0, 22),
        Position = UDim2.new(0, 90, 0.5, -11),
        PlaceholderText = "Z,X,C",
    })
    skillsBox.FocusLost:Connect(function()
        Config.Skills = parseKeys(skillsBox.Text)
        skillsBox.Text = keyNames(Config.Skills)
    end)

    local header = new("Frame", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        LayoutOrder = slot(),
    }, body)
    label(header, "Mob filter (none = all)", {
        Size = UDim2.new(1, -130, 1, 0),
        TextColor3 = theme.muted,
        TextSize = 12,
    })
    local refresh = button(header, "Refresh", theme.accent, {
        Size = UDim2.fromOffset(58, 22),
        Position = UDim2.new(1, -124, 0.5, -11),
        TextSize = 12,
    })
    local clear = button(header, "Clear", theme.panel, {
        Size = UDim2.fromOffset(58, 22),
        Position = UDim2.new(1, -62, 0.5, -11),
        TextSize = 12,
    })

    local chips = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = slot(),
    }, body)
    new("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, chips)

    local function retarget()
        target = nil
        if enabled then
            mobs = scan()
        end
    end

    local function renderChips()
        for _, child in ipairs(chips:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
        for index, name in ipairs(collectNames()) do
            local chip = button(chips, name, theme.panel, {
                Size = UDim2.new(1, 0, 0, 26),
                LayoutOrder = index,
                TextXAlignment = Enum.TextXAlignment.Left,
            })
            new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, chip)
            local function paint()
                chip.BackgroundColor3 = table.find(Config.MobNames, name) and theme.accent or theme.panel
            end
            chip.MouseButton1Click:Connect(function()
                local at = table.find(Config.MobNames, name)
                if at then
                    table.remove(Config.MobNames, at)
                else
                    table.insert(Config.MobNames, name)
                end
                paint()
                retarget()
            end)
            paint()
        end
    end

    refresh.MouseButton1Click:Connect(renderChips)
    clear.MouseButton1Click:Connect(function()
        table.clear(Config.MobNames)
        renderChips()
        retarget()
    end)
    renderChips()

    -- Start button, status line, dragging, minimize/close.
    onToggled = function()
        startButton.Text = enabled and "Stop farming" or "Start farming"
        startButton.BackgroundColor3 = enabled and theme.off or theme.on
    end
    onToggled()
    startButton.MouseButton1Click:Connect(toggle)

    task.spawn(function()
        while alive do
            local lines = {}
            if not enabled then
                lines[1] = ("Idle - %s toggles farming, %s hides this window."):format(
                    Config.ToggleKey.Name, Config.GuiKey.Name)
            else
                if plan then
                    table.insert(lines, plan.text)
                end
                if not (plan and plan.hold) then
                    if targetValid() then
                        table.insert(lines, ("Target: %s (%d mobs)"):format(target.Name, #mobs))
                    else
                        table.insert(lines, ("Searching for mobs... (%d found)"):format(#mobs))
                    end
                end
            end
            status.Text = table.concat(lines, "\n")
            task.wait(0.25)
        end
    end)

    local minimized = false
    minimize.MouseButton1Click:Connect(function()
        minimized = not minimized
        body.Visible = not minimized
        main.Size = UDim2.fromOffset(WINDOW_WIDTH, minimized and TITLE_HEIGHT or WINDOW_HEIGHT)
        minimize.Text = minimized and "+" or "-"
    end)
    close.MouseButton1Click:Connect(destroy)

    local dragging, dragStart, startPosition = false, nil, nil
    local function isPointer(input)
        return input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
    end
    titleBar.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging, dragStart, startPosition = true, input.Position, main.Position
        end
    end)
    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end))
    table.insert(connections, UserInputService.InputEnded:Connect(function(input)
        if isPointer(input) then
            dragging = false
        end
    end))

    -- Executors differ in where a GUI is allowed to live.
    for _, getParent in ipairs({
        function() return gethui() end,
        function() return game:GetService("CoreGui") end,
    }) do
        local ok, parent = pcall(getParent)
        if ok and parent then
            pcall(function()
                gui.Parent = parent
            end)
            if gui.Parent then
                return
            end
        end
    end
    gui.Parent = player:WaitForChild("PlayerGui")
end

-- Wiring -----------------------------------------------------------------

table.insert(connections, RunService.Heartbeat:Connect(follow))
table.insert(connections, UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then
        return
    end
    local position = Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
    if not (lastClick and (position - lastClick).Magnitude < 3) then
        cursor = position
    end
end))
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed or binding then
        return
    end
    if input.KeyCode == Config.ToggleKey then
        toggle()
    elseif input.KeyCode == Config.GuiKey and gui then
        gui.Enabled = not gui.Enabled
    end
end))

task.spawn(function()
    while alive do
        if enabled then
            mobs = scan()
        end
        task.wait(Config.RescanInterval)
    end
end)

task.spawn(function()
    while alive do
        local nextPlan = nil
        local root = enabled and Config.AutoQuest and QuestConfig and EnemyConfig and getCharacter()
        if root then
            local ok, result = pcall(questPlan, root)
            nextPlan = ok and result or { text = "Quest error: " .. tostring(result) }

            local npc = nextPlan.npc
            if npc then
                local prompt = fireproximityprompt and npc:FindFirstChildWhichIsA("ProximityPrompt", true)
                if (npc:GetPivot().Position - root.Position).Magnitude <= 12 then
                    if prompt and os.clock() - lastTalk > 6 then
                        lastTalk = os.clock()
                        fireproximityprompt(prompt)
                    elseif not prompt then
                        nextPlan.text = nextPlan.text .. " - talk to the NPC yourself"
                    end
                end
            elseif nextPlan.hold then
                nextPlan.text = nextPlan.text .. " - can't find the NPC, walk closer"
            end
        end

        local huntChanged = (nextPlan and nextPlan.hunt) ~= (plan and plan.hunt)
        plan = nextPlan
        if huntChanged and enabled then
            target = nil
            mobs = scan()
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while alive do
        if enabled and inRange() then
            click()
        end
        task.wait(Config.AttackInterval)
    end
end)

task.spawn(function()
    local index = 1
    while alive do
        if enabled and Config.UseSkills and #Config.Skills > 0 and inRange() then
            index = (index - 1) % #Config.Skills + 1
            pressKey(Config.Skills[index])
            index += 1
        end
        task.wait(Config.SkillInterval)
    end
end)

env.AutoFarm = {
    Config = Config,
    Toggle = toggle,
    Scan = printScan,
    Destroy = destroy,
}

buildGui()
notify(("Loaded. %s toggles farming, %s hides the window."):format(Config.ToggleKey.Name, Config.GuiKey.Name))
