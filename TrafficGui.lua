--[[
    Traffic Control GUI + Auto Drive
    --------------------------------
    Two tabs. Everything is client-side; nothing is sent to the server.

    TRAFFIC tab (ReplicatedStorage.Modules.Shared.Traffic)
      * Traffic ON/OFF   - wraps Traffic.Pose so it returns nil while OFF, which is
                           the result the module gives for a lane it can't find.
      * Lane set         - Default / Normal / Extreme. Forces the argument that
                           Traffic.Set receives ("Baked" vs "BakedExtreme").
      * HighwayMapOnly   - flips the module's flag (experimental).
      * Preload / stats  - preload lanes on the live instance, live Pose rates.

    AUTO DRIVE tab
      Sit in a vehicle, pick a route source and press Start (or RightCtrl).
      * Route = Waypoint : click "Pick destination", then click the world. A route is
                           computed with PathfindingService (falls back to a straight
                           line if that fails).
      * Route = Recorded : press "Record route", drive the route yourself, press stop.
                           Auto drive then replays it (optionally looping). Routes can
                           be saved to / loaded from a file. This is the reliable mode.
      * Steering + speed use pure-pursuit on the route, slow down for corners, brake
        for obstacles (raycasts), and reverse out when stuck.
      * Input = Keys     : simulates W/A/S/D. This is the one to use in this game: the
                           cars are A-Chassis style (see VehicleRig) and read the
                           keyboard. Input = Seat writes VehicleSeat.Throttle/Steer
                           instead; A-Chassis ignores those, so it's only for other games.
      * Forward = DriveSeat.CFrame.LookVector (VehicleRig builds the car around it).

    Window: drag the title bar, "-" collapses, "x" closes and restores everything.
    RightShift hides/shows the window, RightCtrl starts/stops auto drive.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local PathfindingService = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local GUI_NAME = "TrafficControlGui"
local TOGGLE_KEY = Enum.KeyCode.RightShift
local DRIVE_KEY = Enum.KeyCode.RightControl
local ROUTE_FILE = "TrafficGui_route.json"

local RECORD_SPACING = 6 -- studs between recorded route points
local STEER_FULL_ANGLE = 0.55 -- radians of heading error that map to full steering lock
local YAW_DAMPING = 0.3
local RAY_OFFSETS = { 0, -1.2, 1.2 }

local THEME = {
    bg = Color3.fromRGB(24, 26, 32),
    panel = Color3.fromRGB(34, 37, 46),
    stroke = Color3.fromRGB(58, 62, 76),
    text = Color3.fromRGB(235, 237, 242),
    dim = Color3.fromRGB(150, 156, 172),
    accent = Color3.fromRGB(80, 140, 255),
    off = Color3.fromRGB(70, 74, 88),
    good = Color3.fromRGB(90, 200, 130),
    bad = Color3.fromRGB(235, 100, 100),
}

-- A second execution tears the previous window down first.
local genv = (typeof(getgenv) == "function" and getgenv()) or _G
if genv.TrafficControlGui then
    pcall(genv.TrafficControlGui.Destroy)
end

local connections = {}

----------------------------------------------------------------------
-- Traffic module (optional: auto drive works without it)
----------------------------------------------------------------------

local Traffic
do
    local trafficScript = ReplicatedStorage:WaitForChild("Modules", 5)
    trafficScript = trafficScript and trafficScript:WaitForChild("Shared", 3)
    trafficScript = trafficScript and trafficScript:WaitForChild("Traffic", 3)
    if trafficScript then
        local okRequire, result = pcall(require, trafficScript)
        if okRequire and type(result) == "table" then
            Traffic = result
        else
            warn("[TrafficGui] could not require the Traffic module: " .. tostring(result))
        end
    else
        warn("[TrafficGui] Traffic module not found; the Traffic tab is disabled")
    end
end

local trafficState = {
    enabled = true,
    mode = "Default", -- "Default" | "Normal" | "Extreme"
    instance = nil, -- the live Traffic object the game created with Traffic.Setup
    calls = 0,
    served = 0,
    empty = 0,
    hidden = 0,
}

local originalPose = Traffic and Traffic.Pose
local originalSet = Traffic and Traffic.Set
local originalHighway = Traffic and Traffic.HighwayMapOnly

local function resolveMode(requested)
    if trafficState.mode == "Extreme" then
        return "Extreme"
    elseif trafficState.mode == "Normal" then
        return nil
    end
    return requested
end

-- Counts whether Pose produced anything without allocating, and passes
-- every return value through untouched.
local function track(...)
    if (...) == nil then
        trafficState.empty += 1
    else
        trafficState.served += 1
    end
    return ...
end

local function wrappedPose(self, laneId, a, b, c, mode)
    if not trafficState.instance then
        trafficState.instance = self
    end
    trafficState.calls += 1
    if not trafficState.enabled then
        trafficState.hidden += 1
        return nil
    end
    return track(originalPose(self, laneId, a, b, c, mode))
end

local function wrappedSet(self, mode)
    if not trafficState.instance then
        trafficState.instance = self
    end
    return originalSet(self, resolveMode(mode))
end

local hooked, hookError = false, "module missing"
if Traffic then
    hooked, hookError = pcall(function()
        Traffic.Pose = wrappedPose
        Traffic.Set = wrappedSet
    end)
    if not hooked then
        warn("[TrafficGui] could not hook the Traffic module (read-only?): " .. tostring(hookError))
    end
end

-- Fallback for when the game made its instance before we hooked anything.
local function scanForInstance()
    if trafficState.instance then
        return trafficState.instance
    end
    if not Traffic or typeof(getgc) ~= "function" then
        return nil
    end
    local okScan, objects = pcall(getgc, true)
    if not okScan then
        return nil
    end
    for _, object in ipairs(objects) do
        if type(object) == "table" and getmetatable(object) == Traffic and rawget(object, "Lanes") then
            trafficState.instance = object
            return object
        end
    end
    return nil
end

local function bakedSummary(key)
    local instance = trafficState.instance
    if not instance then
        return "-"
    end
    local baked = rawget(instance, key)
    if baked == nil then
        return "not baked yet"
    elseif baked == false then
        return "no usable lanes"
    elseif type(baked) == "table" and type(baked.Order) == "table" then
        return #baked.Order .. " lanes"
    end
    return "baked"
end

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------

local function create(className, props, children)
    local instance = Instance.new(className)
    for key, value in pairs(props) do
        instance[key] = value
    end
    for _, child in ipairs(children or {}) do
        child.Parent = instance
    end
    return instance
end

local function corner(radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color)
    return create("UIStroke", { Color = color, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local gui = create("ScreenGui", {
    Name = GUI_NAME,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
})

local function mountGui()
    if typeof(gethui) == "function" then
        local okHui, hui = pcall(gethui)
        if okHui and hui and pcall(function() gui.Parent = hui end) then
            return
        end
    end
    if pcall(function() gui.Parent = game:GetService("CoreGui") end) then
        return
    end
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local main = create("Frame", {
    Name = "Main",
    Position = UDim2.fromOffset(40, 80),
    Size = UDim2.fromOffset(320, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0,
}, {
    corner(10),
    stroke(THEME.stroke),
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
})
main.Parent = gui

-- Title bar -----------------------------------------------------------

local titleBar = create("Frame", {
    Name = "TitleBar",
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundTransparency = 1,
    LayoutOrder = 1,
}, {
    create("Frame", {
        Name = "Divider",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = THEME.stroke,
        BorderSizePixel = 0,
    }),
    create("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -80, 1, 0),
        BackgroundTransparency = 1,
        Text = "Traffic Control",
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = THEME.text,
    }),
})
titleBar.Parent = main

local function titleButton(text, offsetFromRight)
    local button = create("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -offsetFromRight, 0.5, 0),
        Size = UDim2.fromOffset(24, 24),
        BackgroundColor3 = THEME.panel,
        AutoButtonColor = true,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = THEME.dim,
    }, { corner(6) })
    button.Parent = titleBar
    return button
end

local closeButton = titleButton("x", 8)
local minimizeButton = titleButton("-", 38)

-- Content: tab strip + one scrolling page per tab ----------------------

local content = create("Frame", {
    Name = "Content",
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = 2,
}, {
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
})
content.Parent = main

local function makePage(order, height)
    local page = create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, height),
        LayoutOrder = order,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = THEME.stroke,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
    }, {
        create("UIPadding", {
            PaddingTop = UDim.new(0, 4),
            PaddingBottom = UDim.new(0, 10),
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 14),
        }),
        create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
    page.Parent = content
    return page
end

local function addToggle(parent, order, text, initial, onChange)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1,
        LayoutOrder = order,
    }, {
        create("TextLabel", {
            Size = UDim2.new(1, -60, 1, 0),
            BackgroundTransparency = 1,
            Text = text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = THEME.text,
        }),
    })
    row.Parent = parent

    local knob = create("Frame", {
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, { corner(9) })
    local pill = create("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(46, 24),
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, { corner(12) })
    knob.Parent = pill
    pill.Parent = row

    local value = initial
    local function render(animate)
        local goal = value and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
        pill.BackgroundColor3 = value and THEME.accent or THEME.off
        if animate then
            TweenService:Create(knob, TweenInfo.new(0.12), { Position = goal }):Play()
        else
            knob.Position = goal
        end
    end
    pill.MouseButton1Click:Connect(function()
        value = not value
        render(true)
        onChange(value)
    end)
    render(false)

    -- Returns a setter so code can move the switch without firing onChange.
    return function(newValue)
        value = newValue
        render(true)
    end
end

-- Fills `strip` with one button per option; returns a function that selects one.
local function buildSegments(strip, options, initial, onChange)
    local buttons = {}
    local function render(selected)
        for name, button in pairs(buttons) do
            local active = name == selected
            button.BackgroundColor3 = active and THEME.accent or THEME.panel
            button.TextColor3 = active and Color3.new(1, 1, 1) or THEME.dim
        end
    end

    local count = #options
    local offset = -6 * (count - 1) / count
    for index, name in ipairs(options) do
        local button = create("TextButton", {
            Size = UDim2.new(1 / count, offset, 1, 0),
            LayoutOrder = index,
            AutoButtonColor = false,
            BorderSizePixel = 0,
            Text = name,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
        }, { corner(6) })
        button.Parent = strip
        button.MouseButton1Click:Connect(function()
            render(name)
            onChange(name)
        end)
        buttons[name] = button
    end
    render(initial)
    return render
end

local function addSegmented(parent, order, text, options, initial, onChange)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundTransparency = 1,
        LayoutOrder = order,
    }, {
        create("TextLabel", {
            Size = UDim2.new(1, 0, 0, 18),
            BackgroundTransparency = 1,
            Text = text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = THEME.text,
        }),
    })
    local strip = create("Frame", {
        Position = UDim2.fromOffset(0, 22),
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1,
    }, {
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
    strip.Parent = row
    row.Parent = parent
    return buildSegments(strip, options, initial, onChange)
end

-- specs = { { text = "...", onClick = fn }, ... }; returns the buttons.
local function addButtonRow(parent, order, specs)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
        LayoutOrder = order,
    }, {
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
    row.Parent = parent

    local count = #specs
    local offset = -6 * (count - 1) / count
    local buttons = {}
    for index, spec in ipairs(specs) do
        local button = create("TextButton", {
            Size = UDim2.new(1 / count, offset, 1, 0),
            LayoutOrder = index,
            BackgroundColor3 = THEME.panel,
            AutoButtonColor = true,
            BorderSizePixel = 0,
            Text = spec.text,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = THEME.text,
        }, { corner(6), stroke(THEME.stroke) })
        button.Parent = row
        button.MouseButton1Click:Connect(spec.onClick)
        buttons[index] = button
    end
    return buttons
end

local function addLabel(parent, order, font, size, color)
    local label = create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = order,
        BackgroundTransparency = 1,
        Text = "",
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Font = font,
        TextSize = size,
        TextColor3 = color,
    })
    label.Parent = parent
    return label
end

local function addStepper(parent, order, text, initial, step, minValue, maxValue, onChange)
    local value = initial
    local function stepButton(label, offsetFromRight)
        local button = create("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -offsetFromRight, 0.5, 0),
            Size = UDim2.fromOffset(24, 24),
            BackgroundColor3 = THEME.panel,
            AutoButtonColor = true,
            BorderSizePixel = 0,
            Text = label,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = THEME.text,
        }, { corner(6), stroke(THEME.stroke) })
        return button
    end

    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1,
        LayoutOrder = order,
    }, {
        create("TextLabel", {
            Size = UDim2.new(1, -110, 1, 0),
            BackgroundTransparency = 1,
            Text = text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = THEME.text,
        }),
    })
    row.Parent = parent

    local valueLabel = create("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -28, 0.5, 0),
        Size = UDim2.fromOffset(44, 24),
        BackgroundTransparency = 1,
        Text = tostring(value),
        Font = Enum.Font.Code,
        TextSize = 13,
        TextColor3 = THEME.text,
    })
    valueLabel.Parent = row
    local minus = stepButton("-", 76)
    local plus = stepButton("+", 0)
    minus.Parent = row
    plus.Parent = row

    local function change(delta)
        value = math.clamp(value + delta, minValue, maxValue)
        valueLabel.Text = tostring(value)
        onChange(value)
    end
    minus.MouseButton1Click:Connect(function() change(-step) end)
    plus.MouseButton1Click:Connect(function() change(step) end)
end

-- Tabs ------------------------------------------------------------------

local tabStrip = create("Frame", {
    Size = UDim2.new(1, 0, 0, 46),
    BackgroundTransparency = 1,
    LayoutOrder = 1,
}, {
    create("UIPadding", {
        PaddingTop = UDim.new(0, 9),
        PaddingBottom = UDim.new(0, 9),
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 12),
    }),
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }),
})
tabStrip.Parent = content

local trafficPage = makePage(2, 300)
local drivePage = makePage(3, 430)

local function showTab(name)
    trafficPage.Visible = name == "Traffic"
    drivePage.Visible = name == "Auto drive"
end
buildSegments(tabStrip, { "Traffic", "Auto drive" }, "Auto drive", showTab)
showTab("Auto drive")

----------------------------------------------------------------------
-- Auto drive: state, input backends, route handling
----------------------------------------------------------------------

local drive = {
    active = false,
    route = "Waypoint", -- "Waypoint" | "Recorded"
    input = "Keys", -- "Keys" | "Seat"
    maxSpeed = 70, -- studs/s
    loop = true,
    avoid = true,
    showPath = true,
    invertSteer = false,
    invertForward = false,
    destination = nil,
    path = nil,
    pathFallback = false,
    pathIndex = 1,
    pathing = false,
    recorded = {},
    recording = false,
    picking = false,
    status = "idle",
    steerOut = 0,
    stuckFor = 0,
    backwardFor = 0,
    recoverUntil = 0,
    recoverSteer = 0,
    lastRepath = 0,
    frontOffset = 5,
    info = { speed = 0, err = 0, targetDistance = 0, clearance = math.huge, index = 0, count = 0 },
}

-- UI callbacks are assigned once the Auto drive controls exist further down.
local driveUi = {
    note = function() end,
    setActive = function() end,
    setRecordLabel = function() end,
    setInvertForward = function() end,
}

-- Debug visuals live under the camera so they never touch the map itself.
local debugFolder = Instance.new("Folder")
debugFolder.Name = "TrafficGuiDebug"
pcall(function()
    debugFolder.Parent = workspace.CurrentCamera or workspace
end)

local pathFolder = Instance.new("Folder")
pathFolder.Name = "Path"
pathFolder.Parent = debugFolder

local function makeMarker(size, color)
    return create("Part", {
        Anchored = true,
        CanCollide = false,
        CanQuery = false,
        CanTouch = false,
        CastShadow = false,
        Material = Enum.Material.Neon,
        Color = color,
        Transparency = 0.25,
        Size = size,
    })
end

local destinationMarker = makeMarker(Vector3.new(2, 40, 2), THEME.good)

local function renderPath(points)
    pathFolder:ClearAllChildren()
    if not drive.showPath or not points then
        return
    end
    local stride = math.max(1, math.ceil(#points / 300))
    for index = 1, #points, stride do
        local dot = makeMarker(Vector3.new(1.4, 1.4, 1.4), THEME.accent)
        dot.Shape = Enum.PartType.Ball
        dot.Position = points[index] + Vector3.new(0, 1, 0)
        dot.Parent = pathFolder
    end
end

local function renderDestination(position)
    if position then
        destinationMarker.Position = position + Vector3.new(0, 20, 0)
        destinationMarker.Parent = debugFolder
    else
        destinationMarker.Parent = nil
    end
end

-- Seat / vehicle -------------------------------------------------------

local function currentSeat()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid and humanoid.SeatPart or nil
end

local function flat(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end

local function flatDistance(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- Horizontal heading of the car. VehicleSeat's front is the seat's LookVector;
-- "Invert forward" (or the automatic reverse-detection) flips it.
local function forwardVector(seat)
    local look = flat(seat.CFrame.LookVector)
    if look.Magnitude < 1e-3 then
        return nil
    end
    look = look.Unit
    return drive.invertForward and -look or look
end

local function extentAlong(cframe, size, direction)
    return 0.5 * (
        math.abs(direction:Dot(cframe.RightVector)) * size.X
        + math.abs(direction:Dot(cframe.UpVector)) * size.Y
        + math.abs(direction:Dot(cframe.LookVector)) * size.Z
    )
end

-- Obstacle raycasts ignore the player's own car and character.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local filterStamp = -math.huge

local function refreshFilter(seat, forward, now)
    if now - filterStamp < 2 then
        return
    end
    filterStamp = now

    local list = { debugFolder, seat }
    if LocalPlayer.Character then
        table.insert(list, LocalPlayer.Character)
    end

    -- How far the front bumper sits ahead of the seat, so rays start past our own car.
    local frontOffset = 3
    local model = seat.Parent
    if seat.Name == "DriveSeat" and model and model:IsA("Model") then
        -- VehicleRig parents DriveSeat directly under the car model, with the wheels
        -- (attached by constraints, so not "connected parts") and any trailer inside it.
        table.insert(list, model)
        local okBox, boxCFrame, boxSize = pcall(model.GetBoundingBox, model)
        if okBox then
            frontOffset = (boxCFrame.Position - seat.Position):Dot(forward) + extentAlong(boxCFrame, boxSize, forward)
        end
    else
        local okParts, parts = pcall(seat.GetConnectedParts, seat, true)
        if okParts then
            for _, part in ipairs(parts) do
                table.insert(list, part)
                local ahead = (part.Position - seat.Position):Dot(forward) + extentAlong(part.CFrame, part.Size, forward)
                frontOffset = math.max(frontOffset, ahead)
            end
        end
    end
    drive.frontOffset = math.clamp(frontOffset + 1, 3, 14)
    rayParams.FilterDescendantsInstances = list
end

local function measureClearance(seat, forward, right, speed)
    local length = 14 + math.max(speed, 0) * 1.1
    local origin = seat.Position + forward * drive.frontOffset + Vector3.new(0, 0.5, 0)
    local best = math.huge
    for _, lateral in ipairs(RAY_OFFSETS) do
        local result = workspace:Raycast(origin + right * lateral, forward * length, rayParams)
        -- Surfaces that face up are slopes/ramps we can drive over, not obstacles.
        if result and result.Normal.Y < 0.6 and result.Distance < best then
            best = result.Distance
        end
    end
    return best
end

-- Input backends -------------------------------------------------------

local okVim, VirtualInputManager = pcall(function()
    return game:GetService("VirtualInputManager")
end)
if not okVim then
    VirtualInputManager = nil
end

local KEY_CODES = { W = Enum.KeyCode.W, A = Enum.KeyCode.A, S = Enum.KeyCode.S, D = Enum.KeyCode.D }
local VIRTUAL_KEYS = { W = 0x57, A = 0x41, S = 0x53, D = 0x44 }
local keyDown = { W = false, A = false, S = false, D = false }
local keyAccumulator = { W = 0, A = 0, S = 0, D = 0 }

local function setKey(name, down)
    if keyDown[name] == down then
        return
    end
    keyDown[name] = down
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(down, KEY_CODES[name], false, game)
        end)
    else
        local press
        if down then
            press = keypress
        else
            press = keyrelease
        end
        if typeof(press) == "function" then
            pcall(press, VIRTUAL_KEYS[name])
        end
    end
end

-- Turns an analog 0..1 amount into a duty cycle on a digital key.
local function pulseKey(name, amount)
    if amount <= 0.05 then
        keyAccumulator[name] = 0
        setKey(name, false)
    elseif amount >= 0.95 then
        setKey(name, true)
    else
        keyAccumulator[name] += amount
        if keyAccumulator[name] >= 1 then
            keyAccumulator[name] -= 1
            setKey(name, true)
        else
            setKey(name, false)
        end
    end
end

local function applyInput(seat, throttle, steer)
    drive.lastThrottle, drive.lastSteer = throttle, steer
    if drive.input == "Seat" then
        if seat:IsA("VehicleSeat") then
            pcall(function()
                seat.Throttle = throttle > 0.1 and 1 or (throttle < -0.1 and -1 or 0)
                seat.Steer = steer > 0.1 and 1 or (steer < -0.1 and -1 or 0)
            end)
            pcall(function()
                seat.ThrottleFloat = throttle
                seat.SteerFloat = steer
            end)
        end
    else
        pulseKey("W", math.max(throttle, 0))
        pulseKey("S", math.max(-throttle, 0))
        pulseKey("D", math.max(steer, 0))
        pulseKey("A", math.max(-steer, 0))
    end
end

local function releaseInputs(seat)
    for name in pairs(keyDown) do
        keyAccumulator[name] = 0
        setKey(name, false)
    end
    if seat and seat:IsA("VehicleSeat") then
        pcall(function()
            seat.Throttle = 0
            seat.Steer = 0
            seat.ThrottleFloat = 0
            seat.SteerFloat = 0
        end)
    end
end

-- Routes ---------------------------------------------------------------

local routeToken = 0

local function stopDrive(reason)
    drive.active = false
    drive.pathing = false
    routeToken += 1
    releaseInputs(currentSeat())
    drive.status = reason or "idle"
    driveUi.setActive(false)
    if reason then
        driveUi.note("Stopped: " .. reason .. ".")
    end
end

local function pointAt(path, index, loop)
    if loop then
        return path[(index - 1) % #path + 1]
    end
    return path[math.clamp(index, 1, #path)]
end

local function nearestIndex(path, position, fromIndex, toIndex, loop)
    local bestIndex, bestDistance = fromIndex, math.huge
    for index = fromIndex, toIndex do
        local distance = flatDistance(pointAt(path, index, loop), position)
        if distance < bestDistance then
            bestIndex, bestDistance = index, distance
        end
    end
    return bestIndex, bestDistance
end

local function groundBelow(position)
    local result = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), rayParams)
    return result and result.Position or position
end

local function computeRoute(startPosition, destination)
    local path = PathfindingService:CreatePath({
        AgentRadius = 4,
        AgentHeight = 5,
        AgentCanJump = false,
        AgentCanClimb = false,
        WaypointSpacing = 10,
    })
    local okCompute, err = pcall(function()
        path:ComputeAsync(startPosition, destination)
    end)
    if not okCompute then
        return nil, tostring(err)
    end
    if path.Status ~= Enum.PathStatus.Success then
        return nil, tostring(path.Status)
    end
    local points = {}
    for _, waypoint in ipairs(path:GetWaypoints()) do
        table.insert(points, waypoint.Position)
    end
    if #points < 2 then
        return nil, "empty route"
    end
    return points
end

local function requestRoute()
    local seat = currentSeat()
    if not seat or not drive.destination then
        return
    end
    routeToken += 1
    local token = routeToken
    drive.pathing = true
    drive.path = nil
    local startPosition = groundBelow(seat.Position)
    local destination = drive.destination

    task.spawn(function()
        local points, reason = computeRoute(startPosition, destination)
        if token ~= routeToken or not drive.active then
            return
        end
        drive.pathing = false
        if points then
            drive.pathFallback = false
            driveUi.note(string.format("Route ready: %d waypoints.", #points), THEME.good)
        else
            points = { startPosition, destination }
            drive.pathFallback = true
            driveUi.note("Pathfinding failed (" .. tostring(reason) .. "); driving straight at the destination.", THEME.bad)
        end
        drive.path = points
        drive.pathIndex = 1
        renderPath(points)
    end)
end

local function startDrive()
    local seat = currentSeat()
    if not seat then
        return driveUi.note("Sit in a vehicle first.", THEME.bad)
    end
    if drive.recording then
        return driveUi.note("Stop recording first.", THEME.bad)
    end
    if drive.input == "Seat" and not seat:IsA("VehicleSeat") then
        return driveUi.note("This vehicle's seat isn't a VehicleSeat. Switch Input to Keys.", THEME.bad)
    end

    local forward = forwardVector(seat)
    if not forward then
        return driveUi.note("Can't work out which way the vehicle is facing.", THEME.bad)
    end
    filterStamp = -math.huge
    refreshFilter(seat, forward, os.clock())

    drive.steerOut = 0
    drive.stuckFor = 0
    drive.backwardFor = 0
    drive.recoverUntil = 0
    drive.lastRepath = os.clock()

    if drive.route == "Recorded" then
        if #drive.recorded < 2 then
            return driveUi.note("No recorded route. Use Record route and drive one first.", THEME.bad)
        end
        drive.path = table.move(drive.recorded, 1, #drive.recorded, 1, {})
        drive.pathFallback = false
        drive.pathing = false
        drive.pathIndex = nearestIndex(drive.path, seat.Position, 1, #drive.path, false)
        renderPath(drive.path)
        local gap = flatDistance(drive.path[1], drive.path[#drive.path])
        if drive.loop and gap > 50 then
            driveUi.note(string.format("Route doesn't close (%.0f stud gap); it will cut across. Record a closed circuit or turn Loop off.", gap), THEME.bad)
        else
            driveUi.note("Driving the recorded route.", THEME.good)
        end
        drive.active = true
    else
        if not drive.destination then
            return driveUi.note("Pick a destination first.", THEME.bad)
        end
        drive.active = true
        requestRoute()
        driveUi.note("Computing route...")
    end

    drive.status = "driving"
    driveUi.setActive(true)
end

local function toggleDrive()
    if drive.active then
        stopDrive("stopped by you")
    else
        startDrive()
    end
end

-- The control loop -----------------------------------------------------

local function driveStep(dt)
    local seat = currentSeat()
    if not seat then
        return stopDrive("left the vehicle")
    end
    local now = os.clock()
    local forward = forwardVector(seat)
    if not forward then
        return
    end
    refreshFilter(seat, forward, now)

    local position = seat.Position
    local speed = seat.AssemblyLinearVelocity:Dot(forward)
    local right = forward:Cross(Vector3.yAxis)
    local info = drive.info
    info.speed = speed

    if drive.pathing or not drive.path then
        applyInput(seat, 0, 0)
        drive.status = "computing route"
        return
    end

    if now < drive.recoverUntil then
        drive.status = "reversing out"
        applyInput(seat, -1, drive.recoverSteer)
        return
    end

    local path = drive.path
    local count = #path
    local loop = drive.route == "Recorded" and drive.loop
    info.count = count

    -- Where are we along the route?
    local fromIndex = drive.pathIndex - 3
    local toIndex = drive.pathIndex + 60
    if not loop then
        fromIndex = math.max(fromIndex, 1)
        toIndex = math.min(toIndex, count)
    end
    local nearest, nearestDistance = nearestIndex(path, position, fromIndex, toIndex, loop)
    drive.pathIndex = loop and ((nearest - 1) % count + 1) or nearest
    info.index = drive.pathIndex

    if drive.route == "Waypoint" and not drive.pathFallback and nearestDistance > 50 and now - drive.lastRepath > 5 then
        drive.lastRepath = now
        requestRoute()
        return
    end

    if not loop and drive.pathIndex >= count - 1 and flatDistance(path[count], position) < 12 then
        return stopDrive("arrived")
    end

    -- Pure pursuit: aim at the first route point that is far enough ahead.
    local lookahead = math.clamp(10 + math.max(speed, 0) * 0.45, 12, 45)
    local targetIndex = drive.pathIndex
    local target = pointAt(path, targetIndex, loop)
    for step = 1, 80 do
        local index = drive.pathIndex + step
        if not loop and index > count then
            break
        end
        targetIndex = index
        target = pointAt(path, index, loop)
        if flatDistance(target, position) >= lookahead then
            break
        end
    end
    info.targetDistance = flatDistance(target, position)

    -- How sharp is the bend just beyond the target? Used to slow down early.
    local cornerAngle = 0
    local beyond = pointAt(path, targetIndex + 3, loop)
    local legA = flat(target - position)
    local legB = flat(beyond - target)
    if legA.Magnitude > 1 and legB.Magnitude > 1 then
        cornerAngle = math.acos(math.clamp(legA.Unit:Dot(legB.Unit), -1, 1))
    end

    -- Steering: heading error, damped by the current yaw rate.
    local toTarget = flat(target - position)
    local err = math.atan2(toTarget:Dot(right), toTarget:Dot(forward))
    info.err = err
    local yawRate = seat.AssemblyAngularVelocity.Y
    local steer = err / STEER_FULL_ANGLE + yawRate * YAW_DAMPING
    steer = steer / (1 + math.max(speed - 35, 0) / 80)
    steer = math.clamp(steer, -1, 1)
    drive.steerOut += (steer - drive.steerOut) * math.min(1, dt * 12)

    -- Speed target: slower for heading error, upcoming bends, the end of the route.
    local targetSpeed = drive.maxSpeed
        * (1 - math.min(math.abs(err) / 1.2, 1) * 0.6)
        * (1 - math.min(cornerAngle / 1.3, 1) * 0.55)
    targetSpeed = math.max(targetSpeed, 12)
    if not loop then
        targetSpeed = math.min(targetSpeed, math.max(6, flatDistance(path[count], position) * 0.7))
    end

    -- Obstacles.
    local blocked = false
    local clearance = math.huge
    if drive.avoid then
        clearance = measureClearance(seat, forward, right, speed)
        local stopDistance = 7 + math.max(speed, 0) * 0.3
        if clearance < stopDistance then
            blocked = true
            targetSpeed = 0
        else
            targetSpeed = math.min(targetSpeed, (clearance - stopDistance) * 1.2 + 8)
        end
    end
    info.clearance = clearance

    local throttle = math.clamp((targetSpeed - speed) * 0.12, -1, 1)
    if throttle < 0 and (speed < 4 or throttle > -0.15) then
        throttle = 0 -- coast instead of reversing or feathering the brake
    end

    local applied = drive.invertSteer and -drive.steerOut or drive.steerOut

    -- Stuck? Reverse out, steering the other way.
    if math.abs(speed) < 1.5 and (targetSpeed > 5 or blocked) then
        drive.stuckFor += dt
    else
        drive.stuckFor = 0
    end
    if drive.stuckFor > (blocked and 6 or 2.5) then
        drive.stuckFor = 0
        drive.recoverUntil = now + 1.6
        drive.recoverSteer = -applied
    end

    -- Throttle forward but rolling backward: the seat's front isn't the car's front.
    if throttle > 0.4 and speed < -2 then
        drive.backwardFor += dt
        if drive.backwardFor > 1.5 then
            drive.backwardFor = 0
            drive.invertForward = not drive.invertForward
            driveUi.setInvertForward(drive.invertForward)
            driveUi.note("Car moved backward under throttle; flipped the forward direction.")
        end
    else
        drive.backwardFor = 0
    end

    drive.status = blocked and "blocked, waiting" or "driving"
    applyInput(seat, throttle, applied)
end

-- Recording / persistence / picking ------------------------------------

local function recordStep()
    local seat = currentSeat()
    local character = LocalPlayer.Character
    local root = seat or (character and character:FindFirstChild("HumanoidRootPart"))
    if not root then
        return
    end
    local position = root.Position
    local lastPoint = drive.recorded[#drive.recorded]
    if (not lastPoint or (position - lastPoint).Magnitude >= RECORD_SPACING) and #drive.recorded < 4000 then
        table.insert(drive.recorded, position)
    end
end

local function toggleRecording()
    if drive.recording then
        drive.recording = false
        driveUi.setRecordLabel(false, 0)
        renderPath(drive.recorded)
        driveUi.note(string.format("Recorded %d points. Set Route to Recorded and press Start.", #drive.recorded), THEME.good)
    else
        if drive.active then
            stopDrive("recording started")
        end
        drive.recorded = {}
        drive.recording = true
        pathFolder:ClearAllChildren()
        driveUi.setRecordLabel(true, 0)
        driveUi.note("Recording. Drive the route you want repeated, then press Stop recording.")
    end
end

local function saveRoute()
    if typeof(writefile) ~= "function" then
        return driveUi.note("This executor has no writefile.", THEME.bad)
    end
    if #drive.recorded < 2 then
        return driveUi.note("Nothing recorded yet.", THEME.bad)
    end
    local data = table.create(#drive.recorded)
    for index, point in ipairs(drive.recorded) do
        data[index] = {
            math.floor(point.X * 10 + 0.5) / 10,
            math.floor(point.Y * 10 + 0.5) / 10,
            math.floor(point.Z * 10 + 0.5) / 10,
        }
    end
    local okSave, err = pcall(writefile, ROUTE_FILE, HttpService:JSONEncode(data))
    if okSave then
        driveUi.note(string.format("Saved %d points to %s.", #data, ROUTE_FILE), THEME.good)
    else
        driveUi.note("Save failed: " .. tostring(err), THEME.bad)
    end
end

local function loadRoute()
    if typeof(readfile) ~= "function" or typeof(isfile) ~= "function" or not isfile(ROUTE_FILE) then
        return driveUi.note("No saved route found (" .. ROUTE_FILE .. ").", THEME.bad)
    end
    local okLoad, data = pcall(function()
        return HttpService:JSONDecode(readfile(ROUTE_FILE))
    end)
    if not okLoad or type(data) ~= "table" then
        return driveUi.note("Saved route could not be read.", THEME.bad)
    end
    local points = {}
    for _, entry in ipairs(data) do
        if type(entry) == "table" and type(entry[1]) == "number" and type(entry[2]) == "number" and type(entry[3]) == "number" then
            table.insert(points, Vector3.new(entry[1], entry[2], entry[3]))
        end
    end
    if #points < 2 then
        return driveUi.note("Saved route has too few points.", THEME.bad)
    end
    drive.recorded = points
    renderPath(points)
    driveUi.note(string.format("Loaded %d points.", #points), THEME.good)
end

local function pickDestinationAt(screenPosition)
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { debugFolder }
    if LocalPlayer.Character then
        table.insert(ignore, LocalPlayer.Character)
    end
    params.FilterDescendantsInstances = ignore
    local result = workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
    if not result then
        return driveUi.note("That click didn't hit anything. Click the ground again.", THEME.bad)
    end
    drive.destination = result.Position
    renderDestination(result.Position)
    driveUi.note("Destination set.", THEME.good)
    if drive.active and drive.route == "Waypoint" then
        requestRoute()
    end
end

----------------------------------------------------------------------
-- Traffic tab controls
----------------------------------------------------------------------

addToggle(trafficPage, 1, "Traffic enabled", true, function(value)
    trafficState.enabled = value
end)

addSegmented(trafficPage, 2, "Lane set", { "Default", "Normal", "Extreme" }, trafficState.mode, function(name)
    trafficState.mode = name
end)

addToggle(trafficPage, 3, "HighwayMapOnly flag", originalHighway == true, function(value)
    if Traffic then
        pcall(function()
            Traffic.HighwayMapOnly = value
        end)
    end
end)

local trafficNote = addLabel(trafficPage, 5, Enum.Font.Gotham, 12, THEME.dim)

local function setTrafficNote(text, color)
    trafficNote.Text = text
    trafficNote.TextColor3 = color or THEME.dim
end

addButtonRow(trafficPage, 4, { {
    text = "Preload lanes",
    onClick = function()
        local instance = scanForInstance()
        if not instance then
            return setTrafficNote("No traffic instance found yet. Wait for the game to spawn traffic, then retry.", THEME.bad)
        end
        local okPreload, err = pcall(instance.Preload, instance, nil)
        if okPreload then
            setTrafficNote("Preload requested (" .. trafficState.mode .. ").", THEME.good)
        else
            setTrafficNote("Preload failed: " .. tostring(err), THEME.bad)
        end
    end,
} })

if not Traffic then
    setTrafficNote("Traffic module not found in this game: these controls do nothing.", THEME.bad)
elseif not hooked then
    setTrafficNote("Module is read-only: toggles will not take effect.", THEME.bad)
else
    setTrafficNote("Switching lane set mid-session can reshuffle cars; lane ids differ between sets.")
end

local trafficStats = addLabel(trafficPage, 6, Enum.Font.Code, 12, THEME.dim)

----------------------------------------------------------------------
-- Auto drive tab controls
----------------------------------------------------------------------

local startButton = addButtonRow(drivePage, 1, { { text = "Start auto drive (RightCtrl)", onClick = toggleDrive } })[1]
startButton.TextSize = 13

local driveNote = addLabel(drivePage, 2, Enum.Font.Gotham, 12, THEME.dim)

addSegmented(drivePage, 3, "Route", { "Waypoint", "Recorded" }, drive.route, function(name)
    drive.route = name
end)

local actionButtons = addButtonRow(drivePage, 4, {
    {
        text = "Pick destination",
        onClick = function()
            drive.picking = true
            driveUi.note("Click the ground in the world to set the destination.")
        end,
    },
    { text = "Record route", onClick = toggleRecording },
})
local recordButton = actionButtons[2]

addButtonRow(drivePage, 5, {
    { text = "Save route", onClick = saveRoute },
    { text = "Load route", onClick = loadRoute },
})

addToggle(drivePage, 6, "Loop recorded route", drive.loop, function(value)
    drive.loop = value
end)

addToggle(drivePage, 7, "Brake for obstacles", drive.avoid, function(value)
    drive.avoid = value
end)

addToggle(drivePage, 8, "Show path markers", drive.showPath, function(value)
    drive.showPath = value
    if value then
        renderPath(drive.path or drive.recorded)
    else
        pathFolder:ClearAllChildren()
    end
end)

addSegmented(drivePage, 9, "Input (Keys for A-Chassis cars)", { "Keys", "Seat" }, drive.input, function(name)
    releaseInputs(currentSeat())
    drive.input = name
end)

addStepper(drivePage, 10, "Max speed (studs/s)", drive.maxSpeed, 10, 10, 300, function(value)
    drive.maxSpeed = value
end)

addToggle(drivePage, 11, "Invert steering", drive.invertSteer, function(value)
    drive.invertSteer = value
end)

local setInvertForwardToggle = addToggle(drivePage, 12, "Invert forward direction", drive.invertForward, function(value)
    drive.invertForward = value
end)

local driveStats = addLabel(drivePage, 13, Enum.Font.Code, 12, THEME.dim)

local driveHint = addLabel(drivePage, 14, Enum.Font.Gotham, 11, THEME.dim)
driveHint.Text = "RightShift hides the window. If the car steers the wrong way, use Invert steering."

driveUi.note = function(text, color)
    driveNote.Text = text
    driveNote.TextColor3 = color or THEME.dim
end
driveUi.setActive = function(active)
    startButton.Text = active and "Stop auto drive (RightCtrl)" or "Start auto drive (RightCtrl)"
    startButton.BackgroundColor3 = active and THEME.bad or THEME.panel
end
driveUi.setRecordLabel = function(recording, pointCount)
    recordButton.Text = recording and string.format("Stop recording (%d)", pointCount) or "Record route"
    recordButton.BackgroundColor3 = recording and THEME.bad or THEME.panel
end
driveUi.setInvertForward = setInvertForwardToggle

driveUi.note("Sit in a vehicle, choose a route, press Start.")

----------------------------------------------------------------------
-- Main loop + live stats
----------------------------------------------------------------------

local last = { calls = 0, served = 0, empty = 0, hidden = 0 }
local lastClock = os.clock()
local accumulated = 0

local function perSecond(key, elapsed)
    local rate = (trafficState[key] - last[key]) / elapsed
    last[key] = trafficState[key]
    return rate
end

table.insert(connections, RunService.Heartbeat:Connect(function(dt)
    if drive.recording then
        pcall(recordStep)
    end

    if drive.active then
        local okStep, err = pcall(driveStep, dt)
        if not okStep then
            warn("[TrafficGui] auto drive error: " .. tostring(err))
            stopDrive("error, see console")
        end
    end

    accumulated += dt
    if accumulated < 0.5 then
        return
    end
    accumulated = 0

    local now = os.clock()
    local elapsed = math.max(now - lastClock, 1e-3)
    lastClock = now

    local calls = perSecond("calls", elapsed)
    local served = perSecond("served", elapsed)
    local empty = perSecond("empty", elapsed)
    local hiddenRate = perSecond("hidden", elapsed)

    trafficStats.Text = string.format(
        "Instance : %s\nNormal   : %s\nExtreme  : %s\nPose/s   : %.0f\n  served : %.0f\n  empty  : %.0f\n  hidden : %.0f\nServer t : %.1f",
        trafficState.instance and "captured" or "waiting for game",
        bakedSummary("Baked"),
        bakedSummary("BakedExtreme"),
        calls,
        served,
        empty,
        hiddenRate,
        workspace:GetServerTimeNow()
    )

    if drive.recording then
        driveUi.setRecordLabel(true, #drive.recorded)
    end

    local info = drive.info
    driveStats.Text = string.format(
        "State    : %s\nSpeed    : %.0f studs/s\nSteer    : %+.2f  Thr %+.2f\nHeading  : %+.0f deg to target\nObstacle : %s\nRoute    : %d / %d\nRecorded : %d pts",
        drive.status,
        info.speed,
        drive.lastSteer or 0,
        drive.lastThrottle or 0,
        math.deg(info.err),
        info.clearance == math.huge and "clear" or string.format("%.0f studs", info.clearance),
        info.index,
        info.count,
        #drive.recorded
    )
end))

----------------------------------------------------------------------
-- Window behaviour
----------------------------------------------------------------------

local dragging, dragStart, startPosition

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPosition = main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

table.insert(connections, UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end))

table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    if input.KeyCode == TOGGLE_KEY then
        main.Visible = not main.Visible
    elseif input.KeyCode == DRIVE_KEY then
        toggleDrive()
    elseif drive.picking and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
        drive.picking = false
        if input.UserInputType == Enum.UserInputType.Touch then
            pickDestinationAt(Vector2.new(input.Position.X, input.Position.Y))
        else
            pickDestinationAt(UserInputService:GetMouseLocation())
        end
    end
end))

minimizeButton.MouseButton1Click:Connect(function()
    content.Visible = not content.Visible
    minimizeButton.Text = content.Visible and "-" or "+"
end)

local destroyed = false
local function destroy()
    if destroyed then
        return
    end
    destroyed = true

    drive.recording = false
    stopDrive()

    if Traffic then
        pcall(function()
            if Traffic.Pose == wrappedPose then
                Traffic.Pose = originalPose
            end
            if Traffic.Set == wrappedSet then
                Traffic.Set = originalSet
            end
            Traffic.HighwayMapOnly = originalHighway
        end)
    end

    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    debugFolder:Destroy()
    destinationMarker:Destroy()
    gui:Destroy()

    if genv.TrafficControlGui and genv.TrafficControlGui.Destroy == destroy then
        genv.TrafficControlGui = nil
    end
end

closeButton.MouseButton1Click:Connect(destroy)

genv.TrafficControlGui = { Destroy = destroy, State = trafficState, Drive = drive }

mountGui()
task.spawn(scanForInstance)
