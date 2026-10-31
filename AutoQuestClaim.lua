--[[
    Auto Quest Claim + Macro + Misc (GUI)

    QUESTS TAB
    - Claims finished quests for you through the game's own remote (Remotes.Quests "list" / "claim").
    - Remotes.QuestUpdate triggers an immediate claim; "Check every" is only the fallback poll.

    MACRO TAB
    - Record: captures what you do (placements, upgrades, sells, target changes, other MatchAction verbs) with
      its timing, by watching the game's own outgoing remote calls. Needs an executor with hookmetamethod.
      A placement is only kept if the server accepted it, an upgrade only if the unit's level went up.
    - Play: replays the steps in order. Units are found by POSITION (ids change every match). A step that is not
      possible yet (no yen, unit not there) is retried until "Step timeout", then skipped and reported.
    - Press Record / Play at the same moment you did when recording (e.g. when the match starts) so the timing lines up.
    - Save / Load / Delete keep named macros in AutoQuestClaim_macros.json (needs writefile; otherwise this session only).
    - Hotkeys: F8 record / stop, F9 play / stop.
    - Auto play each match: starts the macro by itself when a match begins (prep phase, before wave 1), after
      "Start delay" seconds. It stops a macro that is still running when the match ends, so nothing carries over into
      the next match. Pair it with Misc > Auto start + After a match (replay / next level) for a hands-off loop.
      The switch starts off; turning it on while a match is already under way waits for the next match.

    MISC TAB
    - Match-flow helpers that send the same requests the game's match UI does (Remotes.MatchAction):
        Auto start       votes to start while you are in the lobby, and again in the pre-game (the prep phase before
                         wave 1, "Press Yes to start!") after "Pre-game wait" seconds. The line under the switch shows
                         the state the script sees (lobby / pre-game / in the match / not in a match).
        After a match    when the results screen arrives: nothing / replay / next level (else replay) / return to the
                         lobby, after "...after waiting" seconds. It sends the request straight away, so the results
                         animations are skipped.
        Auto skip waves  one skip vote per wave timer, the same as the game's own auto-skip setting
    - The two switches always start off; "After a match" starts on Nothing.

    WINDOW
    - Sidebar navigation with a green dot on every tab whose automation is running, and an "N active" pill in the
      title bar. Drag the title bar to move the window; "-" collapses it, "X" unloads.
    - The Activity console at the bottom is the script's log (it can be hidden); errors also pop up as toasts.
    - Settings tab: UI scale, show / hide the console, unload. The scale is always capped so the window fits the screen.

    USAGE
      * Flip "Auto Claim" on. Use the switches to pick quest groups; "Claim Now" does a single pass while it is off.
      * RightShift hides / shows the window, "-" collapses it, "X" stops everything and unloads.
        Re-executing replaces the old copy (your choices are kept).

    Run:  loadstring(readfile("AutoQuestClaim.lua"))()
]]

--!nolint UnknownGlobal

local CONFIG = {
    Version = "1.0",
    ToggleKey = Enum.KeyCode.RightShift,
    MaxLogLines = 60,

    -- quests
    DefaultInterval = 5,   -- seconds between fallback checks
    MinInterval = 1,
    MaxInterval = 60,
    ClaimGap = 0.3,        -- seconds between individual claims
    FailCooldown = 30,     -- seconds before retrying a quest the server rejected

    -- macro
    MacroRecordKey = Enum.KeyCode.F8,   -- start / stop recording
    MacroPlayKey = Enum.KeyCode.F9,     -- start / stop playback
    MacroFile = "AutoQuestClaim_macros.json", -- saved macros (needs writefile / readfile)
    MacroRetryGap = 0.6,   -- seconds between retries of a step that is not possible yet (no yen, unit not there, ...)
    MacroMinTimeout = 5,   -- "Step timeout" stepper range (seconds)
    MacroMaxTimeout = 120,
    MacroUnitRadius = 6,   -- studs; how close a unit must be to a recorded spot to count as "that unit"
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local env = (getgenv and getgenv()) or _G
if env.AutoQuestClaimCleanup then
    pcall(env.AutoQuestClaimCleanup)
end

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

---------------------------------------------------------------------------
-- Game hooks
---------------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
if not Remotes then
    warn("[AutoQuestClaim] ReplicatedStorage.Remotes not found")
    return
end

local function remote(name)
    return Remotes:WaitForChild(name, 8)
end

local function gameModule(name)
    local inst = ReplicatedStorage:WaitForChild(name, 8)
    if not inst then
        return nil
    end
    local ok, mod = pcall(require, inst)
    return ok and mod or nil
end

local Quests, QuestUpdate = remote("Quests"), remote("QuestUpdate")
local questReady = Quests ~= nil and QuestUpdate ~= nil

-- Macro: PlaceRequest / PlaceResult are what a recorded placement needs. Everything else is optional - without
-- the matching remote or module that kind of step is simply not recorded / replayed (or not cost-checked).
local PlaceRequest, PlaceResult = remote("PlaceRequest"), remote("PlaceResult")
local MatchAction = remote("MatchAction")
local SellRequest = remote("SellRequest")
local MatchConfig = gameModule("MatchConfig")
local PlacementConfig = gameModule("PlacementConfig")
local PlacementRules = gameModule("PlacementRules")
local UpgradePath = gameModule("UpgradePath")
local macroReady = PlaceRequest ~= nil and PlaceResult ~= nil

-- Misc: the match-flow remotes the game's own match UI uses (MatchAction itself is shared with the macro above).
local MatchState = remote("MatchState")
local MatchEvent = remote("MatchEvent")
local miscReady = MatchAction ~= nil and MatchState ~= nil and MatchConfig ~= nil

if not questReady and not macroReady and not miscReady then
    warn("[AutoQuestClaim] none of the quest / place / match remotes were found in this game")
    return
end

---------------------------------------------------------------------------
-- Settings / shared state
---------------------------------------------------------------------------
local saved = env.AutoQuestClaimSettings or {}
local config = {
    -- quests
    claimEnabled = false,
    interval = saved.interval or CONFIG.DefaultInterval,
    groups = {},
    -- window
    uiScale = saved.uiScale or 1,
    consoleOpen = saved.consoleOpen ~= false,
    -- macro
    macroSpeedIndex = saved.macroSpeedIndex or 2, -- index into the speed list (2 = 1x)
    macroTimeout = saved.macroTimeout or 30,      -- seconds a step may keep retrying before it is skipped
    macroTrim = saved.macroTrim ~= false,         -- skip the idle time before the first recorded step
    macroAutoPlay = false,                        -- play the macro by itself when a match begins (starts off, like the other switches)
    macroAutoDelay = saved.macroAutoDelay or 2,   -- seconds after the match begins before it starts
    -- misc (the automation switches always start off, like the other tabs')
    miscAutoStart = false,
    miscAutoSkip = false,
    miscAfter = 1,                                -- what to do after a match: index into the tab's list (1 = nothing)
    miscDelay = saved.miscDelay or 3,             -- seconds to wait on the results screen before doing it
    miscStartDelay = saved.miscStartDelay or 0,   -- seconds to wait in the pre-game before voting to start wave 1
}

local alive = true
local connections = {}

local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function saveSettings()
    env.AutoQuestClaimSettings = {
        interval = config.interval,
        groups = table.clone(config.groups),
        uiScale = config.uiScale,
        consoleOpen = config.consoleOpen,
        macroSpeedIndex = config.macroSpeedIndex,
        macroTimeout = config.macroTimeout,
        macroTrim = config.macroTrim,
        macroAutoDelay = config.macroAutoDelay,
        miscDelay = config.miscDelay,
        miscStartDelay = config.miscStartDelay,
    }
end

---------------------------------------------------------------------------
-- Shared state
---------------------------------------------------------------------------
local shared = {
    macro = {         -- macro recorder / player state (the namecall hook reads this)
        recording = false,
        playing = false,
        stop = false,
        t0 = 0,
        hooked = nil, -- nil = not tried yet, true / false = result of installing the hook
        onRemote = nil,
    },
}

local function money()
    local v = MatchConfig and LocalPlayer:GetAttribute(MatchConfig.MONEY_ATTRIBUTE)
    return type(v) == "number" and v or 0
end

-- Macro playback sends every placement through here, one at a time, and waits for the server's PlaceResult.
-- This is exactly the call the game's own placement UI makes:
--   Remotes.PlaceRequest:FireServer({ slot = n, position = Vector3, yaw = degrees })
local lastPlaceResult = nil
local placeSending = false
if PlaceResult then
    track(PlaceResult.OnClientEvent:Connect(function(p)
        if type(p) == "table" and not p.sold then
            lastPlaceResult = p
        end
    end))
end

local function sendPlaceRequest(slot, pos, yaw)
    local queued = os.clock()
    while placeSending and alive and os.clock() - queued < 5 do
        task.wait(0.05)
    end
    placeSending = true
    lastPlaceResult = nil
    PlaceRequest:FireServer({ slot = slot, position = pos, yaw = yaw })
    local started = os.clock()
    while alive and not lastPlaceResult and os.clock() - started < 2.5 do
        task.wait(0.05)
    end
    placeSending = false
    local res = lastPlaceResult
    if res and res.success then
        return true
    end
    return false, res and tostring(res.reason or "rejected") or "no response"
end

---------------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------------
local COLORS = {
    bg = Color3.fromRGB(12, 13, 19),         -- window
    sidebar = Color3.fromRGB(17, 18, 26),
    main = Color3.fromRGB(19, 20, 29),
    panel = Color3.fromRGB(27, 29, 41),      -- cards
    panel2 = Color3.fromRGB(39, 42, 59),     -- buttons, inputs, badges
    line = Color3.fromRGB(41, 44, 62),       -- hairlines / strokes
    text = Color3.fromRGB(236, 238, 247),
    muted = Color3.fromRGB(139, 145, 168),
    accent = Color3.fromRGB(104, 96, 255),
    accent2 = Color3.fromRGB(64, 156, 255),
    on = Color3.fromRGB(46, 204, 133),
    off = Color3.fromRGB(62, 66, 88),
    warn = Color3.fromRGB(255, 196, 77),
    bad = Color3.fromRGB(244, 98, 106),
    logBg = Color3.fromRGB(10, 11, 16),
}
local LOG_COLORS = { info = COLORS.text, muted = COLORS.muted, success = COLORS.on, error = COLORS.bad }

local function create(class, props, children)
    local inst = Instance.new(class)
    local parent
    for k, v in pairs(props or {}) do
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

local function corner(r)
    return create("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function pill()
    return create("UICorner", { CornerRadius = UDim.new(1, 0) })
end

local function stroke(color, thickness, transparency)
    return create("UIStroke", {
        Color = color or COLORS.line,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function tween(inst, props, t)
    TweenService:Create(inst, TweenInfo.new(t or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local function commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function label(props)
    local base = {
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COLORS.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }
    for k, v in pairs(props) do
        base[k] = v
    end
    return create("TextLabel", base)
end

local function button(props)
    local base = {
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = COLORS.text,
        BackgroundColor3 = COLORS.panel2,
    }
    for k, v in pairs(props) do
        base[k] = v
    end
    local b = create("TextButton", base, { corner(8), stroke(COLORS.line, 1) })
    local rest = b.BackgroundColor3
    local function shade(amount, towards)
        return rest:Lerp(towards, amount)
    end
    b.MouseEnter:Connect(function()
        tween(b, { BackgroundColor3 = shade(0.1, Color3.new(1, 1, 1)) }, 0.12)
    end)
    b.MouseLeave:Connect(function()
        tween(b, { BackgroundColor3 = rest }, 0.12)
    end)
    b.MouseButton1Down:Connect(function()
        tween(b, { BackgroundColor3 = shade(0.18, Color3.new(0, 0, 0)) }, 0.06)
    end)
    b.MouseButton1Up:Connect(function()
        tween(b, { BackgroundColor3 = shade(0.1, Color3.new(1, 1, 1)) }, 0.1)
    end)
    return b
end

-- a flat text-only button (used for the small console controls)
local function textButton(props)
    local base = {
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = COLORS.muted,
    }
    for k, v in pairs(props) do
        base[k] = v
    end
    local b = create("TextButton", base)
    b.MouseEnter:Connect(function()
        tween(b, { TextColor3 = COLORS.text }, 0.1)
    end)
    b.MouseLeave:Connect(function()
        tween(b, { TextColor3 = COLORS.muted }, 0.1)
    end)
    return b
end

local function makeSwitch(parent, initial, onChange)
    local value = initial
    local W, H, K = 42, 22, 16
    local function knobPos(v)
        return v and UDim2.new(1, -(K + 3), 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
    end
    local track_ = create("TextButton", {
        Name = "Switch",
        AutoButtonColor = false,
        Text = "",
        Size = UDim2.fromOffset(W, H),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        BackgroundColor3 = initial and COLORS.on or COLORS.off,
        Parent = parent,
    }, { pill() })
    local knob = create("Frame", {
        Size = UDim2.fromOffset(K, K),
        AnchorPoint = Vector2.new(0, 0.5),
        Position = knobPos(initial),
        BackgroundColor3 = Color3.new(1, 1, 1),
        Parent = track_,
    }, { pill() })

    local api = {}
    function api.set(v, silent)
        value = v
        tween(track_, { BackgroundColor3 = v and COLORS.on or COLORS.off }, 0.15)
        tween(knob, { Position = knobPos(v) }, 0.15)
        if not silent and onChange then
            onChange(v)
        end
    end
    function api.get()
        return value
    end
    track_.Activated:Connect(function()
        api.set(not value)
    end)
    return api
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local WIN_W, WIN_H = 640, 480
local TOP_H = 48          -- title bar
local SIDE_W = 156        -- navigation
local PAD = 8             -- gap between the panels
local HEADER_H = 56       -- page title area
local CONSOLE_H = 124     -- activity console, open

local gui = create("ScreenGui", {
    Name = "AutoQuestClaim",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
    IgnoreGuiInset = true,
})

do
    local mounted = false
    local targets = {}
    if gethui then
        table.insert(targets, function() return gethui() end)
    end
    table.insert(targets, function() return game:GetService("CoreGui") end)
    table.insert(targets, function() return PlayerGui end)
    for _, get in ipairs(targets) do
        local ok = pcall(function()
            gui.Parent = get()
        end)
        if ok and gui.Parent then
            mounted = true
            break
        end
    end
    if not mounted then
        warn("[AutoQuestClaim] could not parent the GUI")
        return
    end
end

-- `win` is the draggable / hideable container; `panel` is the visible window drawn inside it.
local win = create("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0.5, -WIN_H / 2),
    Size = UDim2.fromOffset(WIN_W, WIN_H),
    BackgroundTransparency = 1,
    Parent = gui,
})
local uiScale = create("UIScale", { Scale = 1, Parent = win })

create("ImageLabel", {
    Name = "Shadow",
    BackgroundTransparency = 1,
    Image = "rbxassetid://1316045217",
    ImageColor3 = Color3.new(0, 0, 0),
    ImageTransparency = 0.5,
    ScaleType = Enum.ScaleType.Slice,
    SliceCenter = Rect.new(10, 10, 118, 118),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 8),
    Size = UDim2.new(1, 48, 1, 48),
    ZIndex = 0,
    Parent = win,
})

local panel = create("Frame", {
    Name = "Panel",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COLORS.bg,
    BorderSizePixel = 0,
    ZIndex = 1,
    Parent = win,
}, { corner(12), stroke(COLORS.line, 1) })

-- Title bar -----------------------------------------------------------------
local topbar = create("Frame", {
    Name = "Topbar",
    Size = UDim2.new(1, 0, 0, TOP_H),
    BackgroundTransparency = 1,
    Parent = panel,
})
local logo = create("Frame", {
    Size = UDim2.fromOffset(28, 28),
    Position = UDim2.fromOffset(16, 10),
    BackgroundColor3 = COLORS.accent,
    Parent = topbar,
}, {
    corner(8),
    create("UIGradient", { Color = ColorSequence.new(COLORS.accent, COLORS.accent2), Rotation = 45 }),
})
label({
    Text = "A",
    Font = Enum.Font.GothamBlack,
    TextSize = 15,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Center,
    Size = UDim2.fromScale(1, 1),
    Parent = logo,
})
label({
    Text = "Auto Helper",
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    Position = UDim2.fromOffset(54, 7),
    Size = UDim2.fromOffset(200, 18),
    Parent = topbar,
})
label({
    Text = ("v%s  -  %s to hide"):format(CONFIG.Version, CONFIG.ToggleKey.Name),
    TextSize = 11,
    TextColor3 = COLORS.muted,
    Position = UDim2.fromOffset(54, 26),
    Size = UDim2.fromOffset(240, 14),
    Parent = topbar,
})

local closeBtn = button({
    Text = "X",
    Size = UDim2.fromOffset(28, 28),
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0.5, 0),
    Parent = topbar,
})
local minimizeBtn = button({
    Text = "-",
    Size = UDim2.fromOffset(28, 28),
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -48, 0.5, 0),
    Parent = topbar,
})

-- live "N active" indicator
local statusPill = create("Frame", {
    Name = "Status",
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -84, 0.5, 0),
    Size = UDim2.fromOffset(0, 26),
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundColor3 = COLORS.panel,
    BorderSizePixel = 0,
    Parent = topbar,
}, {
    pill(),
    stroke(COLORS.line, 1),
    create("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 12) }),
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 7),
    }),
})
local pillDot = create("Frame", {
    Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = COLORS.off,
    LayoutOrder = 1,
    Parent = statusPill,
}, { pill() })
local pillText = label({
    Text = "Idle",
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = COLORS.muted,
    Size = UDim2.fromOffset(0, 26),
    AutomaticSize = Enum.AutomaticSize.X,
    LayoutOrder = 2,
    Parent = statusPill,
})

-- Sidebar (navigation) --------------------------------------------------------
local sidebar = create("Frame", {
    Name = "Sidebar",
    Position = UDim2.fromOffset(PAD, TOP_H),
    Size = UDim2.new(0, SIDE_W, 1, -(TOP_H + PAD)),
    BackgroundColor3 = COLORS.sidebar,
    BorderSizePixel = 0,
    Parent = panel,
}, { corner(10), stroke(COLORS.line, 1) })

local navTop = create("Frame", {
    Position = UDim2.fromOffset(0, 10),
    Size = UDim2.new(1, 0, 1, -66),
    BackgroundTransparency = 1,
    Parent = sidebar,
}, {
    create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
})
local navBottom = create("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 0, 1, -10),
    Size = UDim2.new(1, 0, 0, 40),
    BackgroundTransparency = 1,
    Parent = sidebar,
}, {
    create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
})

-- Main area (page header, pages, console) ---------------------------------------
local main = create("Frame", {
    Name = "Main",
    Position = UDim2.fromOffset(SIDE_W + PAD * 2, TOP_H),
    Size = UDim2.new(1, -(SIDE_W + PAD * 3), 1, -(TOP_H + PAD)),
    BackgroundColor3 = COLORS.main,
    BorderSizePixel = 0,
    Parent = panel,
}, { corner(10), stroke(COLORS.line, 1) })

local pageTitle = label({
    Text = "",
    Font = Enum.Font.GothamBold,
    TextSize = 17,
    Position = UDim2.fromOffset(18, 10),
    Size = UDim2.new(1, -36, 0, 22),
    Parent = main,
})
local pageDesc = label({
    Text = "",
    TextSize = 11,
    TextColor3 = COLORS.muted,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.fromOffset(18, 32),
    Size = UDim2.new(1, -36, 0, 16),
    Parent = main,
})

local content = create("Frame", {
    Name = "Content",
    Position = UDim2.fromOffset(0, HEADER_H),
    Size = UDim2.new(1, 0, 1, -(HEADER_H + CONSOLE_H + PAD * 2)),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    Parent = main,
})

-- Activity console ------------------------------------------------------------------
local consoleOpen = config.consoleOpen
local console = create("Frame", {
    Name = "Console",
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, PAD, 1, -PAD),
    Size = UDim2.new(1, -PAD * 2, 0, consoleOpen and CONSOLE_H or 28),
    BackgroundColor3 = COLORS.logBg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Parent = main,
}, { corner(8), stroke(COLORS.line, 1) })
label({
    Text = "ACTIVITY",
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextColor3 = COLORS.muted,
    Position = UDim2.fromOffset(12, 0),
    Size = UDim2.new(0.5, 0, 0, 28),
    Parent = console,
})
local consoleToggleBtn = textButton({
    Text = consoleOpen and "Hide" or "Show",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -8, 0, 0),
    Size = UDim2.fromOffset(44, 28),
    Parent = console,
})
local consoleClearBtn = textButton({
    Text = "Clear",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -54, 0, 0),
    Size = UDim2.fromOffset(44, 28),
    Parent = console,
})
local consoleBody = create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 28),
    Size = UDim2.new(1, 0, 1, -28),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = COLORS.muted,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Visible = consoleOpen,
    Parent = console,
}, {
    create("UIPadding", {
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 6),
    }),
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
})

local function layoutMain()
    local ch = consoleOpen and CONSOLE_H or 28
    tween(console, { Size = UDim2.new(1, -PAD * 2, 0, ch) }, 0.15)
    tween(content, { Size = UDim2.new(1, 0, 1, -(HEADER_H + ch + PAD * 2)) }, 0.15)
    consoleBody.Visible = consoleOpen
    consoleToggleBtn.Text = consoleOpen and "Hide" or "Show"
end

local function setConsoleOpen(v)
    consoleOpen = v and true or false
    config.consoleOpen = consoleOpen
    saveSettings()
    if shared.consoleSwitch then
        shared.consoleSwitch.set(consoleOpen, true)
    end
    layoutMain()
end
consoleToggleBtn.Activated:Connect(function()
    setConsoleOpen(not consoleOpen)
end)
layoutMain()

-- Scale: the user's choice, capped so the window always fits the screen ---------------------
local function applyScale()
    local fit = 1
    local cam = workspace.CurrentCamera
    if cam then
        local v = cam.ViewportSize
        fit = math.min((v.X - 24) / WIN_W, (v.Y - 24) / WIN_H)
    end
    uiScale.Scale = math.max(0.4, math.min(config.uiScale, fit))
end
applyScale()
if workspace.CurrentCamera then
    track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale))
end

-- Toast notifications ------------------------------------------------------------------------
local toastHost = create("Frame", {
    Name = "Toasts",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -18, 0, TOP_H + 8),
    Size = UDim2.fromOffset(290, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    ZIndex = 50,
    Parent = win,
}, {
    create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, 6),
    }),
})
local toastCount = 0

local function escapeRich(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function showToast(text, kind)
    toastCount += 1
    local color = kind == "error" and COLORS.bad or (kind == "success" and COLORS.on or COLORS.accent)
    local t = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = COLORS.panel,
        BorderSizePixel = 0,
        LayoutOrder = toastCount,
        ZIndex = 51,
        Parent = toastHost,
    }, {
        corner(8),
        stroke(color, 1, 0.35),
        create("UIPadding", {
            PaddingTop = UDim.new(0, 9),
            PaddingBottom = UDim.new(0, 9),
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 12),
        }),
    })
    local msg = label({
        Text = ("<font color=\"#%s\">\u{25CF}</font>  %s"):format(color:ToHex(), escapeRich(text)),
        RichText = true,
        TextSize = 12,
        TextWrapped = true,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = 52,
        Parent = t,
    })

    -- keep at most four on screen
    local kids = toastHost:GetChildren()
    local frames = {}
    for _, k in ipairs(kids) do
        if k:IsA("Frame") then
            table.insert(frames, k)
        end
    end
    table.sort(frames, function(a, b)
        return a.LayoutOrder < b.LayoutOrder
    end)
    while #frames > 4 do
        table.remove(frames, 1):Destroy()
    end

    task.delay(3.5, function()
        if not t.Parent then
            return
        end
        tween(t, { BackgroundTransparency = 1 }, 0.25)
        tween(msg, { TextTransparency = 1 }, 0.25)
        for _, d in ipairs(t:GetDescendants()) do
            if d:IsA("UIStroke") then
                tween(d, { Transparency = 1 }, 0.25)
            end
        end
        task.delay(0.3, function()
            if t.Parent then
                t:Destroy()
            end
        end)
    end)
end

-- Navigation -------------------------------------------------------------------------------------
local pages, navButtons, tabOrder = {}, {}, {}
local TAB_META = {
    Quests = { title = "Quests", desc = "Claim finished quests automatically.", icon = "Q" },
    Macro = { title = "Macro", desc = "Record what you do in a match and play it back.", icon = "M" },
    Misc = { title = "Misc", desc = "Auto start, skip waves, and what to do after a match.", icon = "+" },
    Settings = { title = "Settings", desc = "Appearance and script controls.", icon = "S" },
}
local currentTab = nil

local function showTab(name)
    if not pages[name] then
        return
    end
    currentTab = name
    for n, page in pairs(pages) do
        page.Visible = n == name
    end
    for n, nav in pairs(navButtons) do
        local on = n == name
        nav.selected = on
        tween(nav.button, { BackgroundTransparency = on and 0 or 1 }, 0.15)
        tween(nav.name, { TextColor3 = on and COLORS.text or COLORS.muted }, 0.15)
        tween(nav.bar, { BackgroundTransparency = on and 0 or 1 }, 0.15)
        tween(nav.icon, { BackgroundColor3 = on and COLORS.accent or COLORS.panel2 }, 0.15)
    end
    local meta = TAB_META[name] or { title = name, desc = "" }
    pageTitle.Text = meta.title
    pageDesc.Text = meta.desc
end

local function registerTab(name, page, pinned)
    pages[name] = page
    table.insert(tabOrder, name)
    local meta = TAB_META[name] or { icon = name:sub(1, 1) }

    local btn = create("TextButton", {
        Name = name,
        Text = "",
        AutoButtonColor = false,
        BackgroundColor3 = COLORS.panel,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 38),
        LayoutOrder = #tabOrder,
        Parent = pinned and navBottom or navTop,
    }, { corner(8) })
    local bar = create("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(3, 18),
        BackgroundColor3 = COLORS.accent,
        BackgroundTransparency = 1,
        Parent = btn,
    }, { pill() })
    local icon = create("Frame", {
        Position = UDim2.fromOffset(12, 7),
        Size = UDim2.fromOffset(24, 24),
        BackgroundColor3 = COLORS.panel2,
        Parent = btn,
    }, { corner(7) })
    label({
        Text = meta.icon,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Center,
        Size = UDim2.fromScale(1, 1),
        Parent = icon,
    })
    local nameLabel = label({
        Text = name,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = COLORS.muted,
        Position = UDim2.fromOffset(46, 0),
        Size = UDim2.new(1, -72, 1, 0),
        Parent = btn,
    })
    local dot = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(8, 8),
        BackgroundColor3 = COLORS.on,
        Visible = false,
        Parent = btn,
    }, { pill() })

    local nav = { button = btn, bar = bar, icon = icon, name = nameLabel, dot = dot, selected = false }
    navButtons[name] = nav
    btn.MouseEnter:Connect(function()
        if not nav.selected then
            tween(btn, { BackgroundTransparency = 0.65 }, 0.1)
        end
    end)
    btn.MouseLeave:Connect(function()
        if not nav.selected then
            tween(btn, { BackgroundTransparency = 1 }, 0.1)
        end
    end)
    btn.Activated:Connect(function()
        showTab(name)
    end)
end

---------------------------------------------------------------------------
-- Activity log
---------------------------------------------------------------------------
-- log() only QUEUES the line (plain Lua, no GUI access), so it is safe to call from any thread. Threads started
-- from a hooked game call or a game callback can lose the permission to touch this window ("lacking capability
-- Plugin"); a pump thread started here, by the script itself, does the actual GUI work.
local logCount = 0
local logQueue = {}
local logLines = {}

local function addLogLine(item)
    logCount += 1
    local color = LOG_COLORS[item.kind or "info"] or COLORS.text
    local line = label({
        Text = ("<font color=\"#%s\">%s</font>  %s"):format(COLORS.muted:ToHex(), item.at, escapeRich(item.text)),
        RichText = true,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = color,
        TextWrapped = true,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = logCount,
        Parent = consoleBody,
    })
    table.insert(logLines, line)
    while #logLines > CONFIG.MaxLogLines do
        table.remove(logLines, 1):Destroy()
    end
    task.defer(function()
        if consoleBody.Parent then
            consoleBody.CanvasPosition = Vector2.new(0, consoleBody.AbsoluteCanvasSize.Y)
        end
    end)
    if item.kind == "error" or item.notify then
        showToast(item.text, item.kind)
    end
end

-- log(text, kind, notify): kind is info / muted / success / error; errors (and notify = true) also pop a toast
local function log(text, kind, notify)
    table.insert(logQueue, { text = tostring(text), kind = kind, notify = notify, at = os.date("%H:%M:%S") })
end

task.spawn(function()
    while alive do
        while #logQueue > 0 do
            local item = table.remove(logQueue, 1)
            pcall(addLogLine, item)
        end
        task.wait(0.1)
    end
end)

consoleClearBtn.Activated:Connect(function()
    for _, l in ipairs(logLines) do
        l:Destroy()
    end
    table.clear(logLines)
end)

---------------------------------------------------------------------------
-- Page builders
---------------------------------------------------------------------------
-- A page is a scrolling column of cards. `order` is kept for call-site compatibility.
local function newPage(order)
    return create("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.muted,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        LayoutOrder = order or 0,
        Visible = false,
        Parent = content,
    }, {
        create("UIPadding", {
            PaddingTop = UDim.new(0, 2),
            PaddingBottom = UDim.new(0, 12),
            PaddingLeft = UDim.new(0, 14),
            PaddingRight = UDim.new(0, 14),
        }),
        create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
    })
end

local function caption(parent, text, order)
    return label({
        Text = text:upper(),
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = COLORS.muted,
        TextYAlignment = Enum.TextYAlignment.Bottom,
        Size = UDim2.new(1, 0, 0, 20),
        LayoutOrder = order,
        Parent = parent,
    })
end

local function card(parent, height, order)
    return create("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = COLORS.panel,
        BorderSizePixel = 0,
        LayoutOrder = order,
        Parent = parent,
    }, { corner(10), stroke(COLORS.line, 1) })
end

-- a card that grows with its rows (used for the quest group list)
local function listCard(parent, order)
    return create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = COLORS.panel,
        BorderSizePixel = 0,
        LayoutOrder = order,
        Parent = parent,
    }, {
        corner(10),
        stroke(COLORS.line, 1),
        create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }),
        create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
    })
end

local function masterCard(parent, title, order, onChange)
    local c = card(parent, 58, order)
    label({
        Text = title,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        Position = UDim2.fromOffset(16, 10),
        Size = UDim2.new(1, -90, 0, 18),
        Parent = c,
    })
    local status = label({
        Text = "Paused",
        TextSize = 11,
        TextColor3 = COLORS.muted,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.fromOffset(16, 32),
        Size = UDim2.new(1, -90, 0, 16),
        Parent = c,
    })
    local sw = makeSwitch(c, false, onChange)
    return c, status, sw
end

-- returns the card, the switch, and (when a description was given) the description label so it can be updated live
local function toggleCard(parent, title, order, initial, onChange, description)
    local c = card(parent, description and 58 or 46, order)
    label({
        Text = title,
        Position = UDim2.fromOffset(16, description and 10 or 0),
        Size = UDim2.new(1, -90, 0, description and 18 or 46),
        Parent = c,
    })
    local descLabel
    if description then
        descLabel = label({
            Text = description,
            TextSize = 11,
            TextColor3 = COLORS.muted,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.fromOffset(16, 32),
            Size = UDim2.new(1, -90, 0, 16),
            Parent = c,
        })
    end
    return c, makeSwitch(c, initial, onChange), descLabel
end

local function stepperCard(parent, title, order, onStep, valueWidth)
    local vw = valueWidth or 56
    local c = card(parent, 46, order)
    label({
        Text = title,
        Position = UDim2.fromOffset(16, 0),
        Size = UDim2.new(1, -(vw + 106), 1, 0),
        Parent = c,
    })
    local plus = button({
        Text = "+",
        Size = UDim2.fromOffset(28, 28),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Parent = c,
    })
    local value = label({
        Text = "",
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Center,
        BackgroundTransparency = 0,
        BackgroundColor3 = COLORS.logBg,
        Size = UDim2.fromOffset(vw, 28),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -48, 0.5, 0),
        Parent = c,
    })
    corner(8).Parent = value
    local minus = button({
        Text = "-",
        Size = UDim2.fromOffset(28, 28),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(54 + vw), 0.5, 0),
        Parent = c,
    })
    minus.Activated:Connect(function()
        onStep(-1)
    end)
    plus.Activated:Connect(function()
        onStep(1)
    end)
    return c, value
end

local function statsRow(parent, order, leftText, rightText)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        LayoutOrder = order,
        Parent = parent,
    })
    local left = label({
        Text = leftText,
        TextSize = 12,
        TextColor3 = COLORS.on,
        Position = UDim2.fromOffset(4, 0),
        Size = UDim2.new(0.5, -4, 1, 0),
        Parent = row,
    })
    local right = label({
        Text = rightText,
        TextSize = 12,
        TextColor3 = COLORS.muted,
        TextXAlignment = Enum.TextXAlignment.Right,
        Size = UDim2.new(0.5, -4, 1, 0),
        Position = UDim2.fromScale(0.5, 0),
        Parent = row,
    })
    return left, right
end

local function buttonPair(parent, leftText, rightText, order, leftColor)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
        LayoutOrder = order,
        Parent = parent,
    })
    local left = button({
        Text = leftText,
        BackgroundColor3 = leftColor or COLORS.accent,
        Size = UDim2.new(0.5, -4, 1, 0),
        Parent = row,
    })
    local right = button({
        Text = rightText,
        Size = UDim2.new(0.5, -4, 1, 0),
        Position = UDim2.new(0.5, 4, 0, 0),
        Parent = row,
    })
    return left, right
end

local function actionButton(parent, text, order, color)
    return button({
        Text = text,
        BackgroundColor3 = color or COLORS.accent,
        Size = UDim2.new(1, 0, 0, 36),
        LayoutOrder = order,
        Parent = parent,
    })
end

---------------------------------------------------------------------------
-- QUESTS
---------------------------------------------------------------------------
local function setupQuests()
    local GROUPS = { "daily", "weekly", "infinite", "story", "event" }
    pcall(function()
        local data = require(ReplicatedStorage:WaitForChild("QuestData", 5))
        if type(data.GROUPS) == "table" and #data.GROUPS > 0 then
            GROUPS = table.clone(data.GROUPS)
        end
    end)
    for _, g in ipairs(GROUPS) do
        local keep = saved.groups and saved.groups[g]
        config.groups[g] = keep == nil and true or keep
    end

    local busy = false
    local wake = false
    local elapsed = 0
    local lastCycle = 0
    local claimable = {}   -- group -> number of finished-but-unclaimed quests
    local cooldown = {}    -- "group/id" -> os.clock() when we may retry
    local stats = { claimed = 0 }
    local badges = {}

    local page = newPage(1)

    -- UI
    local _, statusLabel = masterCard(page, "Auto Claim", 1, function(v)
        config.claimEnabled = v
        elapsed = config.interval -- run a pass right away when switched on
        log(v and "Auto claim enabled" or "Auto claim paused", v and "success" or "muted")
    end)

    caption(page, "QUEST GROUPS", 2)
    local groupsCard = listCard(page, 3)
    for i, g in ipairs(GROUPS) do
        local row = create("Frame", {
            Size = UDim2.new(1, 0, 0, 36),
            BackgroundTransparency = 1,
            LayoutOrder = i,
            Parent = groupsCard,
        })
        label({
            Text = g:sub(1, 1):upper() .. g:sub(2),
            Position = UDim2.fromOffset(16, 0),
            Size = UDim2.new(0.5, 0, 1, 0),
            Parent = row,
        })
        badges[g] = create("TextLabel", {
            Text = "+0",
            Visible = false,
            Font = Enum.Font.GothamBold,
            TextSize = 11,
            TextColor3 = Color3.fromRGB(30, 24, 0),
            BackgroundColor3 = COLORS.warn,
            Size = UDim2.fromOffset(34, 20),
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -68, 0.5, 0),
            Parent = row,
        }, { pill() })
        makeSwitch(row, config.groups[g], function(v)
            config.groups[g] = v
            saveSettings()
        end)
    end

    local intervalCard, intervalValue
    intervalCard, intervalValue = stepperCard(page, "Check every", 4, function(delta)
        config.interval = math.clamp(config.interval + delta, CONFIG.MinInterval, CONFIG.MaxInterval)
        intervalValue.Text = config.interval .. "s"
        saveSettings()
    end)
    intervalValue.Text = config.interval .. "s"

    local claimedLabel, pendingLabel = statsRow(page, 5, "Claimed: 0", "Ready to claim: 0")
    local claimNowBtn, refreshBtn = buttonPair(page, "Claim Now", "Refresh", 6)

    local function paintCounts()
        local total = 0
        for _, g in ipairs(GROUPS) do
            local n = tonumber(claimable[g]) or 0
            total += n
            badges[g].Visible = n > 0
            badges[g].Text = "+" .. n
        end
        pendingLabel.Text = "Ready to claim: " .. total
        pendingLabel.TextColor3 = total > 0 and COLORS.warn or COLORS.muted
        claimedLabel.Text = "Claimed: " .. stats.claimed
    end

    local function paintStatus()
        if busy then
            statusLabel.Text = "Claiming..."
            statusLabel.TextColor3 = COLORS.warn
        elseif config.claimEnabled then
            statusLabel.Text = ("Watching - next check in %ds"):format(math.max(0, math.ceil(config.interval - elapsed)))
            statusLabel.TextColor3 = COLORS.on
        else
            statusLabel.Text = "Paused"
            statusLabel.TextColor3 = COLORS.muted
        end
    end

    -- Logic
    local function invoke(...)
        local args = table.pack(...)
        local ok, res = pcall(function()
            return Quests:InvokeServer(table.unpack(args, 1, args.n))
        end)
        if ok and type(res) == "table" then
            return res
        end
        return nil
    end

    local function countFromList(list)
        local counts = {}
        for _, g in ipairs(GROUPS) do
            local n = 0
            for _, q in ipairs((list.groups and list.groups[g]) or {}) do
                if q.complete and not q.claimed then
                    n += 1
                end
            end
            counts[g] = n
        end
        return counts
    end

    local function refreshCounts()
        local res = invoke("list")
        local list = res and res.list
        if not list then
            log("Could not read the quest list", "error")
            return nil
        end
        claimable = countFromList(list)
        paintCounts()
        return list
    end

    local function claimCycle(manual)
        if busy then
            return
        end
        busy = true
        lastCycle = os.clock()
        paintStatus()

        local ok, err = pcall(function()
            local list = refreshCounts()
            if not list then
                return
            end

            local queue = {}
            for _, g in ipairs(GROUPS) do
                if config.groups[g] then
                    for _, q in ipairs((list.groups and list.groups[g]) or {}) do
                        local key = g .. "/" .. tostring(q.id)
                        if q.complete and not q.claimed and (cooldown[key] or 0) <= os.clock() then
                            table.insert(queue, { group = g, quest = q, key = key })
                        end
                    end
                end
            end

            if #queue == 0 then
                if manual then
                    log("Nothing to claim", "muted")
                end
                return
            end

            for _, item in ipairs(queue) do
                if not alive or (not manual and not config.claimEnabled) then
                    break
                end
                local q = item.quest
                local name = tostring(q.name or q.id)
                local res = invoke("claim", item.group, q.id)
                if res and res.success then
                    stats.claimed += 1
                    cooldown[item.key] = nil
                    log(("Claimed %s [%s]"):format(name, item.group), "success")
                else
                    cooldown[item.key] = os.clock() + CONFIG.FailCooldown
                    log(("Could not claim %s: %s"):format(name, tostring(res and res.message or "no response")), "error")
                end
                if res and type(res.list) == "table" then
                    claimable = countFromList(res.list)
                end
                paintCounts()
                task.wait(CONFIG.ClaimGap)
            end
        end)

        if not ok then
            log("Error: " .. tostring(err), "error")
        end
        busy = false
        elapsed = 0
        paintStatus()
    end

    claimNowBtn.Activated:Connect(function()
        task.spawn(claimCycle, true)
    end)
    refreshBtn.Activated:Connect(function()
        task.spawn(function()
            if refreshCounts() then
                log("Quests refreshed", "muted")
            end
        end)
    end)

    -- Instant reaction: the game fires QuestUpdate with { group = claimableCount } whenever quest state changes.
    track(QuestUpdate.OnClientEvent:Connect(function(counts)
        if type(counts) ~= "table" then
            return
        end
        claimable = counts
        paintCounts()
        if config.claimEnabled and not busy then
            for _, g in ipairs(GROUPS) do
                if config.groups[g] and (tonumber(counts[g]) or 0) > 0 then
                    wake = true
                    break
                end
            end
        end
    end))

    task.spawn(function()
        local TICK = 0.25
        while alive do
            task.wait(TICK)
            if not alive then
                break
            end
            if config.claimEnabled and not busy then
                elapsed += TICK
                local woken = wake and (os.clock() - lastCycle >= 1)
                if woken or elapsed >= config.interval then
                    wake = false
                    claimCycle(false)
                end
            end
            paintStatus()
        end
    end)

    paintCounts()
    paintStatus()
    task.spawn(refreshCounts)
    return page
end

---------------------------------------------------------------------------
-- MACRO
---------------------------------------------------------------------------
-- RECORD: hooks the game's own outgoing remote calls (PlaceRequest / MatchAction / SellRequest) so what you do
-- by hand is captured with its timing. Needs hookmetamethod (executor).
-- PLAY:   replays the steps in order. Units are found by POSITION (their ids change every match), and a step
-- that is not possible yet (no yen, unit not there) is retried until its timeout, then skipped.
local function setupMacro()
    local HttpService = game:GetService("HttpService")
    local SPEEDS = { 0.5, 1, 2, 4, 0 } -- 0 = do not wait between steps
    local SPEED_TEXT = { "0.5x", "1x", "2x", "4x", "Max" }
    local state = shared.macro
    local upgradeAttr = MatchConfig and MatchConfig.UPGRADE_ATTRIBUTE

    local events = {}       -- the current macro: { t, kind, ... } sorted by t
    local pendingPlace = {} -- place requests waiting for the server's answer
    local playStatus = "Idle"

    -- Storage -----------------------------------------------------------------
    local store = env.AutoQuestClaimMacroStore
    if not store then
        store = {}
        if isfile and readfile then
            local ok, data = pcall(function()
                if isfile(CONFIG.MacroFile) then
                    return HttpService:JSONDecode(readfile(CONFIG.MacroFile))
                end
                return nil
            end)
            if ok and type(data) == "table" then
                store = data
            end
        end
        env.AutoQuestClaimMacroStore = store
    end

    local function persist()
        if writefile then
            local ok, err = pcall(function()
                writefile(CONFIG.MacroFile, HttpService:JSONEncode(store))
            end)
            if not ok then
                log("Could not write " .. CONFIG.MacroFile .. ": " .. tostring(err), "error")
            end
        end
    end

    local function deepcopy(t)
        if type(t) ~= "table" then
            return t
        end
        local out = {}
        for k, v in pairs(t) do
            out[k] = deepcopy(v)
        end
        return out
    end

    -- Units -------------------------------------------------------------------
    local function placedFolder()
        if PlacementRules then
            local ok, folder = pcall(PlacementRules.placedFolder)
            if ok and folder then
                return folder
            end
        end
        if PlacementConfig and PlacementConfig.PLACED_FOLDER then
            return workspace:FindFirstChild(PlacementConfig.PLACED_FOLDER)
        end
        return nil
    end

    local function unitById(id)
        local folder = placedFolder()
        if not folder or id == nil then
            return nil
        end
        for _, m in ipairs(folder:GetChildren()) do
            if m:GetAttribute("PlaceId") == id or m:GetAttribute("CopyId") == id then
                return m
            end
        end
        return nil
    end

    local function unitIdOf(m)
        return m:GetAttribute("PlaceId") or m:GetAttribute("CopyId")
    end

    local function ownUnitNear(pos)
        local folder = placedFolder()
        if not folder then
            return nil
        end
        local best, bestDist = nil, CONFIG.MacroUnitRadius
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") and m:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
                local p = m:GetPivot().Position
                local d = math.sqrt((p.X - pos.X) ^ 2 + (p.Z - pos.Z) ^ 2)
                if d < bestDist then
                    best, bestDist = m, d
                end
            end
        end
        return best
    end

    local function vec(a)
        return Vector3.new(a[1], a[2], a[3])
    end

    local function arr(v)
        return { v.X, v.Y, v.Z }
    end

    local function describe(ev)
        local where = ev.pos and ("(%.0f, %.0f, %.0f)"):format(ev.pos[1], ev.pos[2], ev.pos[3]) or ""
        if ev.kind == "place" then
            return ("place slot %s at %s"):format(tostring(ev.slot), where)
        elseif ev.kind == "upgrade" then
            return "upgrade unit at " .. where
        elseif ev.kind == "sell" then
            return "sell unit at " .. where
        elseif ev.kind == "target" then
            return ("target %s at %s"):format(tostring(ev.mode), where)
        end
        return "action " .. tostring(ev.verb)
    end

    local function fmtTime(s)
        s = math.max(0, math.floor(s))
        return ("%d:%02d"):format(s // 60, s % 60)
    end

    -- UI ----------------------------------------------------------------------
    local page = newPage(5)

    local headCard = card(page, 58, 1)
    label({
        Text = "Macro",
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        Position = UDim2.fromOffset(16, 10),
        Size = UDim2.new(1, -32, 0, 18),
        Parent = headCard,
    })
    local statusLabel = label({
        Text = "Idle",
        TextSize = 11,
        TextColor3 = COLORS.muted,
        Position = UDim2.fromOffset(16, 32),
        Size = UDim2.new(1, -32, 0, 16),
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = headCard,
    })

    local recBtn, playBtn = buttonPair(page, "Record", "Play", 2)
    local stepsLabel, lengthLabel = statsRow(page, 3, "Steps: 0", "Length: 0:00")

    local speedCard, speedValue
    speedCard, speedValue = stepperCard(page, "Replay speed", 4, function(delta)
        config.macroSpeedIndex = (config.macroSpeedIndex - 1 + delta) % #SPEEDS + 1
        speedValue.Text = SPEED_TEXT[config.macroSpeedIndex]
        saveSettings()
    end)
    speedValue.Text = SPEED_TEXT[config.macroSpeedIndex]

    local timeoutCard, timeoutValue
    timeoutCard, timeoutValue = stepperCard(page, "Step timeout", 5, function(delta)
        config.macroTimeout = math.clamp(config.macroTimeout + delta * 5, CONFIG.MacroMinTimeout, CONFIG.MacroMaxTimeout)
        timeoutValue.Text = config.macroTimeout .. "s"
        saveSettings()
    end)
    timeoutValue.Text = config.macroTimeout .. "s"

    toggleCard(page, "Skip idle time before step 1", 6, config.macroTrim, function(v)
        config.macroTrim = v
        saveSettings()
    end)

    -- Auto play needs the match state; without it the two controls are simply not shown.
    local onAutoPlayToggled -- assigned once playback exists (further down)
    local canAutoPlay = MatchState ~= nil and MatchConfig ~= nil
    if canAutoPlay then
        toggleCard(page, "Auto play each match", 7, config.macroAutoPlay, function(v)
            config.macroAutoPlay = v
            if onAutoPlayToggled then
                onAutoPlayToggled(v)
            end
        end, "Plays it at the start of every match.")

        local autoDelayCard, autoDelayValue
        autoDelayCard, autoDelayValue = stepperCard(page, "Start delay", 8, function(delta)
            config.macroAutoDelay = math.clamp(config.macroAutoDelay + delta, 0, 30)
            autoDelayValue.Text = config.macroAutoDelay .. "s"
            saveSettings()
        end)
        autoDelayValue.Text = config.macroAutoDelay .. "s"
    end

    local nameCard = card(page, 36, 9)
    local nameBox = create("TextBox", {
        Text = "",
        PlaceholderText = "macro name",
        PlaceholderColor3 = COLORS.muted,
        TextColor3 = COLORS.text,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
        BackgroundColor3 = COLORS.logBg,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -16, 0, 24),
        Position = UDim2.fromOffset(8, 6),
        Parent = nameCard,
    }, {
        corner(6),
        create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
    })
    local saveBtn, loadBtn = buttonPair(page, "Save", "Load", 10)
    local deleteBtn, clearBtn = buttonPair(page, "Delete", "Clear steps", 11, COLORS.panel2)
    local savedLabel = label({
        Text = "",
        TextSize = 11,
        TextColor3 = COLORS.muted,
        TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top,
        Size = UDim2.new(1, 0, 0, 28),
        LayoutOrder = 12,
        Parent = page,
    })

    local function refreshSaved()
        local names = {}
        for name in pairs(store) do
            table.insert(names, name)
        end
        table.sort(names)
        savedLabel.Text = "Saved: " .. (#names > 0 and table.concat(names, ", ") or "none")
    end

    local function refreshUI()
        local n = #events
        local minT, maxT = math.huge, 0
        for _, e in ipairs(events) do
            minT = math.min(minT, e.t)
            maxT = math.max(maxT, e.t)
        end
        if n == 0 then
            minT = 0
        end
        stepsLabel.Text = "Steps: " .. n
        lengthLabel.Text = "Length: " .. fmtTime(maxT - (config.macroTrim and minT or 0))

        recBtn.Text = state.recording and "Stop rec" or "Record"
        playBtn.Text = state.playing and "Stop" or "Play"

        if state.recording then
            statusLabel.Text = ("Recording... %d steps, %s"):format(n, fmtTime(os.clock() - state.t0))
            statusLabel.TextColor3 = COLORS.bad
        elseif state.playing then
            statusLabel.Text = playStatus
            statusLabel.TextColor3 = COLORS.on
        elseif config.macroAutoPlay then
            statusLabel.Text = ("Auto play on - starts %ds after the next match begins"):format(config.macroAutoDelay)
            statusLabel.TextColor3 = COLORS.on
        elseif state.hooked == false then
            statusLabel.Text = "Idle - recording unavailable (no hookmetamethod); playback works"
            statusLabel.TextColor3 = COLORS.warn
        else
            statusLabel.Text = ("Idle - %s record, %s play"):format(CONFIG.MacroRecordKey.Name, CONFIG.MacroPlayKey.Name)
            statusLabel.TextColor3 = COLORS.muted
        end
    end

    -- Recording ---------------------------------------------------------------
    local function commit(ev)
        table.insert(events, ev)
        log("Rec: " .. describe(ev), "muted")
    end

    -- Called (in its own thread, after the real call went through) for every FireServer while recording.
    local function onRemote(remote, args)
        if not state.recording then
            return
        end
        local t = os.clock() - state.t0

        if remote == PlaceRequest then
            local a = args[1]
            if type(a) == "table" and typeof(a.position) == "Vector3" and a.slot ~= nil then
                table.insert(pendingPlace, { t = t, at = os.clock(), slot = a.slot, pos = a.position, yaw = tonumber(a.yaw) or 0 })
            end

        elseif SellRequest and remote == SellRequest then
            local a = args[1]
            local m = type(a) == "table" and unitById(a.copyId) or nil
            if m then
                commit({ t = t, kind = "sell", pos = arr(m:GetPivot().Position) })
            end

        elseif MatchAction and remote == MatchAction then
            local verb = args[1]
            if verb == "upgrade" then
                local m = unitById(args[2])
                if m then
                    local pos = arr(m:GetPivot().Position)
                    if not upgradeAttr then
                        commit({ t = t, kind = "upgrade", pos = pos })
                        return
                    end
                    -- only keep upgrades the server actually accepted (the unit's level goes up)
                    local level = tonumber(m:GetAttribute(upgradeAttr)) or 0
                    local started = os.clock()
                    while os.clock() - started < 1.5 do
                        if (tonumber(m:GetAttribute(upgradeAttr)) or 0) > level then
                            commit({ t = t, kind = "upgrade", pos = pos })
                            return
                        end
                        task.wait(0.05)
                    end
                end
            elseif verb == "setTarget" then
                local m = unitById(args[2])
                if m and type(args[3]) == "string" then
                    commit({ t = t, kind = "target", pos = arr(m:GetPivot().Position), mode = args[3] })
                end
            elseif type(verb) == "string" then
                -- any other MatchAction verb is kept as-is when its arguments are plain values
                local plain = true
                local list = {}
                for i = 1, args.n do
                    local v = args[i]
                    if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
                        plain = false
                        break
                    end
                    list[i] = v
                end
                if plain then
                    commit({ t = t, kind = "action", verb = verb, args = list, n = args.n })
                end
            end
        end
    end
    state.onRemote = onRemote

    -- a place request only counts once the server says it worked
    track(PlaceResult.OnClientEvent:Connect(function(p)
        if type(p) ~= "table" or p.sold or #pendingPlace == 0 then
            return
        end
        while #pendingPlace > 0 and os.clock() - pendingPlace[1].at > 8 do
            table.remove(pendingPlace, 1) -- an answer that never came
        end
        local req = table.remove(pendingPlace, 1)
        if req and p.success then
            commit({ t = req.t, kind = "place", slot = req.slot, pos = arr(req.pos), yaw = req.yaw })
        end
    end))

    local function installHook()
        if state.hooked ~= nil then
            return state.hooked
        end
        if not (hookmetamethod and getnamecallmethod) then
            state.hooked = false
            return false
        end
        local old
        local wrap = newcclosure or function(f)
            return f
        end
        local ok = pcall(function()
            old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
                local method = getnamecallmethod()
                if not state.recording or method ~= "FireServer" then
                    return old(self, ...)
                end
                -- let the real call go first (it needs the namecall method intact), then look at it
                local args = table.pack(...)
                local results = table.pack(old(self, ...))
                local handler = state.onRemote
                if handler then
                    task.spawn(function()
                        pcall(handler, self, args)
                    end)
                end
                return table.unpack(results, 1, results.n)
            end))
        end)
        state.hooked = ok
        return ok
    end

    local function startRecording()
        if state.recording or state.playing then
            return
        end
        if not installHook() then
            log("Recording needs hookmetamethod, which this executor does not provide. You can still play saved macros.", "error")
            return
        end
        events = {}
        pendingPlace = {}
        state.t0 = os.clock()
        state.recording = true
        log("Recording - play normally; placements, upgrades, sells and target changes are captured", "success")
    end

    local function stopRecording()
        if not state.recording then
            return
        end
        state.recording = false
        log("Stopped recording...", "muted")
        task.delay(2, function() -- let in-flight confirmations land first
            table.sort(events, function(a, b)
                return a.t < b.t
            end)
            log(("Recorded %d steps"):format(#events), "success")
        end)
    end

    -- Playback ----------------------------------------------------------------
    local function halted()
        return state.stop or not alive
    end

    local runners = {}

    function runners.place(ev, note)
        local pos = vec(ev.pos)
        local deadline = os.clock() + config.macroTimeout
        local reason = "timed out"
        while not halted() and os.clock() < deadline do
            local ok, why = sendPlaceRequest(ev.slot, pos, ev.yaw or 0)
            if ok then
                return true
            end
            reason = why or reason
            note(reason)
            task.wait(CONFIG.MacroRetryGap)
        end
        return false, reason
    end

    function runners.upgrade(ev, note)
        if not MatchAction then
            return false, "MatchAction remote missing"
        end
        local pos = vec(ev.pos)
        local deadline = os.clock() + config.macroTimeout
        local reason = "unit not found"
        while not halted() and os.clock() < deadline do
            local m = ownUnitNear(pos)
            if not m then
                reason = "waiting for the unit at that spot"
                note(reason)
            elseif not upgradeAttr then
                MatchAction:FireServer("upgrade", unitIdOf(m))
                return true
            else
                local level = tonumber(m:GetAttribute(upgradeAttr)) or 0
                local cost, maxed = nil, false
                if UpgradePath then
                    local ok, c = pcall(UpgradePath.cost, m:GetAttribute("UnitName") or m.Name, m:GetAttribute("Cost") or 0, level + 1)
                    if ok then
                        if type(c) == "number" then
                            cost = c
                        else
                            maxed = true
                        end
                    end
                end
                if maxed then
                    return true, "already fully upgraded"
                end
                if cost and money() < cost then
                    reason = "waiting for yen (" .. commas(cost) .. ")"
                    note(reason)
                else
                    MatchAction:FireServer("upgrade", unitIdOf(m))
                    local started = os.clock()
                    while not halted() and os.clock() - started < 1.5 do
                        if (tonumber(m:GetAttribute(upgradeAttr)) or 0) > level then
                            return true
                        end
                        task.wait(0.05)
                    end
                    reason = "the server did not accept the upgrade"
                    note(reason)
                end
            end
            task.wait(CONFIG.MacroRetryGap)
        end
        return false, reason
    end

    function runners.sell(ev, note)
        if not SellRequest then
            return false, "SellRequest remote missing"
        end
        local pos = vec(ev.pos)
        local deadline = os.clock() + math.min(config.macroTimeout, 10)
        while not halted() and os.clock() < deadline do
            local m = ownUnitNear(pos)
            if not m then
                return true, "nothing there (already sold?)"
            end
            SellRequest:FireServer({ copyId = unitIdOf(m) })
            local started = os.clock()
            while not halted() and os.clock() - started < 2 do
                if not m.Parent then
                    return true
                end
                task.wait(0.05)
            end
            note("sell not confirmed yet")
        end
        return false, "sell not confirmed"
    end

    function runners.target(ev, note)
        if not MatchAction then
            return false, "MatchAction remote missing"
        end
        local pos = vec(ev.pos)
        local deadline = os.clock() + math.min(config.macroTimeout, 15)
        while not halted() and os.clock() < deadline do
            local m = ownUnitNear(pos)
            if m then
                if PlacementConfig and PlacementConfig.TARGET_MODE_ATTRIBUTE then
                    pcall(m.SetAttribute, m, PlacementConfig.TARGET_MODE_ATTRIBUTE, ev.mode) -- what the game's own UI does first
                end
                MatchAction:FireServer("setTarget", unitIdOf(m), ev.mode)
                return true
            end
            note("waiting for the unit at that spot")
            task.wait(CONFIG.MacroRetryGap)
        end
        return false, "unit not found"
    end

    function runners.action(ev)
        if not MatchAction then
            return false, "MatchAction remote missing"
        end
        MatchAction:FireServer(ev.verb, table.unpack(ev.args or {}, 2, ev.n or #(ev.args or {})))
        return true
    end

    local function playMacro()
        if state.playing or state.recording then
            return
        end
        if #events == 0 then
            log("Nothing to play - record something or Load a saved macro", "muted")
            return
        end
        state.playing = true
        state.stop = false
        table.sort(events, function(a, b)
            return a.t < b.t
        end)
        task.spawn(function()
            -- whatever happens in the body, playback must end cleanly (never leave the Play button stuck on "Stop")
            local bodyOk, bodyErr = pcall(function()
            local speed = SPEEDS[config.macroSpeedIndex]
            local offset = config.macroTrim and events[1].t or 0
            local base = os.clock()
            local done, skipped = 0, 0
            log(("Playing %d steps at %s"):format(#events, SPEED_TEXT[config.macroSpeedIndex]), "success")

            for i, ev in ipairs(events) do
                if halted() then
                    break
                end
                if speed > 0 then
                    local target = base + (ev.t - offset) / speed
                    while not halted() and os.clock() < target do
                        playStatus = ("Step %d/%d in %.0fs: %s"):format(i, #events, math.max(0, target - os.clock()), describe(ev))
                        task.wait(0.05)
                    end
                end
                if halted() then
                    break
                end
                playStatus = ("Step %d/%d: %s"):format(i, #events, describe(ev))

                local noted
                local function note(msg)
                    if msg ~= noted then
                        noted = msg
                        log(("  step %d: %s"):format(i, msg), "muted")
                    end
                end
                local runner = runners[ev.kind]
                local ok, success, why = false, false, "unknown step type"
                if runner then
                    ok, success, why = pcall(runner, ev, note)
                    if not ok then
                        success, why = false, tostring(success)
                    end
                end
                if success then
                    done += 1
                else
                    skipped += 1
                    log(("Skipped step %d (%s): %s"):format(i, describe(ev), tostring(why)), "error")
                end
            end

            if state.stop then
                log(("Playback stopped (%d done, %d skipped)"):format(done, skipped), "muted")
            else
                log(("Macro finished: %d done, %d skipped"):format(done, skipped), skipped == 0 and "success" or "muted")
            end
            end)
            state.playing = false
            if not bodyOk then
                log("Playback error: " .. tostring(bodyErr), "error")
            end
        end)
    end

    local function stopPlaying()
        if state.playing then
            state.stop = true
        end
    end

    local function toggleRecord()
        if state.recording then
            stopRecording()
        else
            startRecording()
        end
    end

    local function togglePlay()
        if state.playing then
            stopPlaying()
        else
            playMacro()
        end
    end

    -- Auto play ---------------------------------------------------------------
    -- Starts the macro by itself when a match begins: in the match, prep phase, before wave 1 (the game's "pre-game").
    -- It is armed by anything that is not a running match (lobby, starting, the results) so it fires once per match,
    -- and a match ending stops a macro that is still running - so it never carries over into the next match.
    -- Pair it with Misc > "After a match" (replay / next level) for a hands-off loop.
    local STATE = (MatchConfig and MatchConfig.STATE) or {}
    local autoArmed = false
    local autoToken = 0   -- bumps whenever a pending start should be forgotten
    local lastMatch = nil -- last Remotes.MatchState payload

    local function joined()
        return MatchConfig ~= nil and LocalPlayer:GetAttribute(MatchConfig.JOINED_ATTRIBUTE) == true
    end

    local function preGame(p)
        return p ~= nil and p.state == STATE.PREP and (p.wave or 0) == 0
    end

    local function autoCheck()
        if not (config.macroAutoPlay and autoArmed and preGame(lastMatch) and joined()) then
            return
        end
        if state.playing or state.recording then
            return
        end
        autoArmed = false
        autoToken += 1
        local token = autoToken
        log(("Match started - playing the macro in %ds"):format(config.macroAutoDelay), "success", true)
        task.delay(config.macroAutoDelay, function()
            if token == autoToken and alive and config.macroAutoPlay and joined() and not state.playing and not state.recording then
                playMacro()
            end
        end)
    end

    local function onMatchState(p)
        if type(p) ~= "table" then
            return
        end
        lastMatch = p
        local s = p.state
        if s == STATE.VICTORY or s == STATE.DEFEAT then
            autoToken += 1 -- forget a start that was still waiting out its delay
            if config.macroAutoPlay then
                autoArmed = true
                if state.playing then
                    state.stop = true
                    log("Match ended - stopped the macro", "muted")
                end
            end
        elseif s == STATE.LOBBY or s == STATE.STARTING then
            if config.macroAutoPlay then
                autoArmed = true
            end
        end
        autoCheck()
    end

    onAutoPlayToggled = function(on)
        if on then
            -- armed for a match that has not really started yet, or for the next one - not for one already under way
            local p = lastMatch
            autoArmed = not joined() or p == nil or preGame(p) or p.state == STATE.LOBBY or p.state == STATE.STARTING
            log("Auto play on - the macro starts with the next match", "success")
            autoCheck()
        else
            autoArmed = false
            autoToken += 1
            log("Auto play off", "muted")
        end
    end

    if canAutoPlay then
        track(MatchState.OnClientEvent:Connect(onMatchState))
        track(LocalPlayer:GetAttributeChangedSignal(MatchConfig.JOINED_ATTRIBUTE):Connect(function()
            task.defer(autoCheck)
        end))
        task.spawn(function()
            -- the game asks for the current state when it starts; do the same so auto play is not blind until the next event
            if MatchAction then
                MatchAction:FireServer("sync", nil, nil)
            end
            while alive do
                autoCheck()
                task.wait(1)
            end
        end)
    end

    -- Wiring ------------------------------------------------------------------
    recBtn.Activated:Connect(toggleRecord)
    playBtn.Activated:Connect(togglePlay)

    local function currentName()
        return (nameBox.Text:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    saveBtn.Activated:Connect(function()
        local name = currentName()
        if name == "" then
            log("Type a name for the macro first", "muted")
        elseif #events == 0 then
            log("Nothing to save - record something first", "muted")
        else
            store[name] = { events = deepcopy(events) }
            persist()
            refreshSaved()
            log(("Saved \"%s\" (%d steps)%s"):format(name, #events, writefile and "" or " - this session only (no writefile)"), "success")
        end
    end)

    loadBtn.Activated:Connect(function()
        if state.recording or state.playing then
            log("Stop recording / playback first", "muted")
            return
        end
        local name = currentName()
        local entry = store[name]
        if not entry or type(entry.events) ~= "table" then
            log(("No saved macro named \"%s\""):format(name), "error")
            return
        end
        events = deepcopy(entry.events)
        table.sort(events, function(a, b)
            return a.t < b.t
        end)
        log(("Loaded \"%s\" (%d steps)"):format(name, #events), "success")
    end)

    deleteBtn.Activated:Connect(function()
        local name = currentName()
        if store[name] then
            store[name] = nil
            persist()
            refreshSaved()
            log(("Deleted \"%s\""):format(name), "muted")
        else
            log(("No saved macro named \"%s\""):format(name), "error")
        end
    end)

    clearBtn.Activated:Connect(function()
        if state.recording or state.playing then
            log("Stop recording / playback first", "muted")
            return
        end
        events = {}
        log("Cleared the current steps", "muted")
    end)

    track(UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end
        if input.KeyCode == CONFIG.MacroRecordKey then
            toggleRecord()
        elseif input.KeyCode == CONFIG.MacroPlayKey then
            togglePlay()
        end
    end))

    task.spawn(function()
        while alive do
            refreshUI()
            task.wait(0.25)
        end
    end)

    refreshSaved()
    refreshUI()
    return page
end

---------------------------------------------------------------------------
-- MISC
---------------------------------------------------------------------------
-- Match-flow helpers that send the same requests the game's own match UI does (Remotes.MatchAction):
--   voteStart(true)   start the match from the lobby      voteSkip(true)   skip the wave timer
--   replay / nextLevel / return   what the results screen's buttons do
local function setupMisc()
    local STATE = MatchConfig.STATE or {}
    local AFTER = { "Nothing", "Replay", "Next level", "Return" }

    local match = nil       -- last Remotes.MatchState payload
    local resultsToken = 0  -- bumps on every results screen so an old timer can tell it is stale
    local skipKey = nil     -- "wave:endsAt" of the wave timer we already voted to skip
    local pregameSince = nil -- os.clock() when the pre-game (prep before wave 1) began
    local lastFire = {}     -- throttle key -> os.clock() of the last time it fired

    local page = newPage(6)

    -- Helpers -----------------------------------------------------------------
    local function joined()
        return LocalPlayer:GetAttribute(MatchConfig.JOINED_ATTRIBUTE) == true
    end

    local function fire(verb, arg)
        MatchAction:FireServer(verb, arg, nil)
    end

    local function throttled(key, seconds)
        local now = os.clock()
        if lastFire[key] and now - lastFire[key] < seconds then
            return false
        end
        lastFire[key] = now
        return true
    end

    local function replayNow()
        -- the same bookkeeping the game's Replay button does for "seamless retry"
        local seamless = LocalPlayer:GetAttribute("Setting_seamlessRetry") == true
        if seamless then
            LocalPlayer:SetAttribute("SeamlessRetryAt", os.clock())
        end
        MatchAction:FireServer("replay", seamless and "seamless" or nil, nil)
    end

    local function hideResults()
        pcall(function()
            local ui = PlayerGui:FindFirstChild("ResultsUI")
            if ui and ui:IsA("ScreenGui") then
                ui.Enabled = false
            end
        end)
    end

    local function stateName(s)
        for k, v in pairs(STATE) do
            if v == s then
                local name = tostring(k)
                return name:sub(1, 1):upper() .. name:sub(2):lower()
            end
        end
        return tostring(s)
    end

    -- what the script currently sees, in words (shown under the Auto start switch and logged when it is switched on)
    local function startHintText()
        if not match then
            return "No match data yet - enter a match first"
        end
        local s = match.state
        if not joined() then
            return ("Not in a match (state: %s)"):format(stateName(s))
        end
        if s == STATE.LOBBY then
            return "Lobby - voting to start the match"
        elseif s == STATE.STARTING then
            return "Match is starting..."
        elseif s == STATE.PREP and (match.wave or 0) == 0 then
            local left = config.miscStartDelay - (pregameSince and (os.clock() - pregameSince) or 0)
            if left > 0.5 then
                return ("Pre-game - voting to start in %ds"):format(math.ceil(left))
            end
            return "Pre-game - voting to start wave 1"
        end
        return ("In the match: %s, wave %s"):format(stateName(s), tostring(match.wave or 0))
    end

    -- UI ----------------------------------------------------------------------
    local _, _, startHint = toggleCard(page, "Auto start", 1, config.miscAutoStart, function(v)
        config.miscAutoStart = v
        log(v and "Auto start on" or "Auto start off", v and "success" or "muted")
        if v then
            log("Auto start: " .. startHintText(), "muted")
        end
    end, "Waiting for match data...")

    local preCard, preValue
    preCard, preValue = stepperCard(page, "Pre-game wait", 2, function(delta)
        config.miscStartDelay = math.clamp(config.miscStartDelay + delta, 0, 60)
        preValue.Text = config.miscStartDelay .. "s"
        saveSettings()
    end)
    preValue.Text = config.miscStartDelay .. "s"

    local afterCard, afterValue
    afterCard, afterValue = stepperCard(page, "After a match", 3, function(delta)
        config.miscAfter = (config.miscAfter - 1 + delta) % #AFTER + 1
        afterValue.Text = AFTER[config.miscAfter]
    end, 84)
    afterValue.Text = AFTER[config.miscAfter]

    local delayCard, delayValue
    delayCard, delayValue = stepperCard(page, "...after waiting", 4, function(delta)
        config.miscDelay = math.clamp(config.miscDelay + delta, 0, 30)
        delayValue.Text = config.miscDelay .. "s"
        saveSettings()
    end)
    delayValue.Text = config.miscDelay .. "s"

    toggleCard(page, "Auto skip waves", 5, config.miscAutoSkip, function(v)
        config.miscAutoSkip = v
        log(v and "Auto skip on" or "Auto skip off", v and "success" or "muted")
    end)

    -- Behaviour ---------------------------------------------------------------
    local function react()
        if not alive or not match then
            return
        end
        local s = match.state
        local isJoined = joined()

        -- The game waits for a "voteStart" twice: in the lobby (start the match) and again in the pre-game, the prep
        -- phase before wave 1 ("Press Yes to start!"). Auto start answers both.
        local inPregame = isJoined and s == STATE.PREP and (match.wave or 0) == 0
        if inPregame then
            pregameSince = pregameSince or os.clock()
        else
            pregameSince = nil
        end

        if config.miscAutoStart and isJoined then
            if s == STATE.LOBBY and throttled("start", 4) then
                fire("voteStart", true)
                log("Auto start: voted to start the match", "muted")
            elseif inPregame and os.clock() - pregameSince >= config.miscStartDelay and throttled("pregame", 4) then
                fire("voteStart", true)
                log("Auto start: voted to start wave 1", "muted")
            end
        end

        -- one skip vote per wave timer, exactly like the game's own auto-skip setting
        if isJoined and s == STATE.PREP then
            if config.miscAutoSkip and (match.wave or 0) > 0 then
                local key = tostring(match.wave) .. ":" .. tostring(match.endsAt)
                if skipKey ~= key then
                    skipKey = key
                    fire("voteSkip", true)
                    log(("Auto skip: wave %s"):format(tostring(match.wave)), "muted")
                end
            end
        else
            skipKey = nil
        end
    end

    local function afterMatch(res)
        local choice = AFTER[config.miscAfter]
        if choice == "Nothing" then
            return
        end
        hideResults()
        local canReplay = res.canReplay ~= false
        if choice == "Next level" and res.won == true and res.nextLevel ~= nil then
            log("After match: next level", "success")
            fire("nextLevel")
        elseif choice == "Return" or not canReplay then
            log("After match: back to the lobby", "success")
            fire("return")
        else
            log("After match: replay", "success")
            replayNow()
        end
    end

    track(MatchState.OnClientEvent:Connect(function(p)
        if type(p) == "table" then
            local before = match and match.state
            match = p
            if config.miscAutoStart and p.state ~= before then
                log("Auto start: match state is now " .. stateName(p.state), "muted")
            end
            task.defer(react)
        end
    end))

    track(LocalPlayer:GetAttributeChangedSignal(MatchConfig.JOINED_ATTRIBUTE):Connect(function()
        task.defer(react)
    end))

    if MatchEvent then
        track(MatchEvent.OnClientEvent:Connect(function(kind, data)
            if kind ~= "results" then
                return
            end
            resultsToken += 1
            local token = resultsToken
            local res = type(data) == "table" and data or {}
            log(("Match over: %s"):format(res.won and "victory" or "defeat"), res.won and "success" or "muted")
            if AFTER[config.miscAfter] ~= "Nothing" then
                log(("Will %s in %ds"):format(AFTER[config.miscAfter]:lower(), config.miscDelay), "muted")
                task.delay(config.miscDelay, function()
                    if token == resultsToken and alive then
                        afterMatch(res)
                    end
                end)
            end
        end))
    end

    task.spawn(function()
        -- the game asks for the current state when it starts; do the same so we are not blind until the next event
        MatchAction:FireServer("sync", nil, nil)
        while alive do
            react()
            if startHint then
                startHint.Text = startHintText()
            end
            task.wait(0.5)
        end
    end)

    return page
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------
-- A tab shows a green dot in the sidebar (and counts towards the "N active" pill) while its automation is running.
local TAB_ACTIVE = {
    Quests = function()
        return config.claimEnabled
    end,
    Macro = function()
        return shared.macro.recording or shared.macro.playing or config.macroAutoPlay
    end,
    Misc = function()
        return config.miscAutoStart or config.miscAutoSkip or config.miscAfter > 1
    end,
}

if questReady then
    registerTab("Quests", setupQuests())
else
    log("Quest remotes not found - Quests tab disabled", "muted")
end
if macroReady then
    registerTab("Macro", setupMacro())
else
    log("PlaceRequest / PlaceResult not found - Macro tab disabled", "muted")
end
if miscReady then
    registerTab("Misc", setupMisc())
else
    log("MatchState / MatchAction / MatchConfig not found - Misc tab disabled", "muted")
end

---------------------------------------------------------------------------
-- Window controls
---------------------------------------------------------------------------
local collapsed = false
minimizeBtn.Activated:Connect(function()
    collapsed = not collapsed
    sidebar.Visible = not collapsed
    main.Visible = not collapsed
    tween(win, { Size = UDim2.fromOffset(WIN_W, collapsed and TOP_H or WIN_H) }, 0.18)
    minimizeBtn.Text = collapsed and "+" or "-"
end)

local function cleanup()
    alive = false
    config.claimEnabled = false
    shared.macro.recording = false -- the namecall hook (which cannot be removed) becomes a plain pass-through
    shared.macro.stop = true
    for _, c in ipairs(connections) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(connections)
    if gui then
        gui:Destroy()
    end
    if env.AutoQuestClaimCleanup == cleanup then
        env.AutoQuestClaimCleanup = nil
    end
end
env.AutoQuestClaimCleanup = cleanup
closeBtn.Activated:Connect(cleanup)

-- Settings (created here because "Unload" needs cleanup) -------------------------------------
local function setupSettings()
    local page = newPage(9)

    caption(page, "Appearance", 1)
    local scaleCard, scaleValue
    scaleCard, scaleValue = stepperCard(page, "UI scale", 2, function(delta)
        config.uiScale = math.clamp(math.floor((config.uiScale + delta * 0.1) * 10 + 0.5) / 10, 0.7, 1.3)
        scaleValue.Text = ("%d%%"):format(math.floor(config.uiScale * 100 + 0.5))
        applyScale()
        saveSettings()
    end, 60)
    scaleValue.Text = ("%d%%"):format(math.floor(config.uiScale * 100 + 0.5))

    local _, consoleSwitch = toggleCard(page, "Activity console", 3, consoleOpen, function(v)
        setConsoleOpen(v)
    end, "Show the running log at the bottom of the window.")
    shared.consoleSwitch = consoleSwitch

    caption(page, "Script", 4)
    local about = card(page, 82, 5)
    label({
        Text = ("Auto Helper  v%s"):format(CONFIG.Version),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        Position = UDim2.fromOffset(16, 10),
        Size = UDim2.new(1, -32, 0, 18),
        Parent = about,
    })
    label({
        Text = ("%s hides / shows this window.  Macro hotkeys: %s to record, %s to play."):format(
            CONFIG.ToggleKey.Name, CONFIG.MacroRecordKey.Name, CONFIG.MacroPlayKey.Name
        ),
        TextSize = 11,
        TextColor3 = COLORS.muted,
        TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top,
        Position = UDim2.fromOffset(16, 32),
        Size = UDim2.new(1, -32, 0, 40),
        Parent = about,
    })

    actionButton(page, "Unload script", 6, COLORS.bad).Activated:Connect(cleanup)
    return page
end
registerTab("Settings", setupSettings(), true)
showTab(tabOrder[1])

-- Dragging (by the title bar) ----------------------------------------------------------------
do
    local dragging, dragStart, startPos = false, nil, nil
    topbar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = win.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == CONFIG.ToggleKey then
        win.Visible = not win.Visible
    end
end))

-- Live indicators: sidebar dots + the "N active" pill ----------------------------------------------
task.spawn(function()
    while alive do
        local count = 0
        for name, nav in pairs(navButtons) do
            local fn = TAB_ACTIVE[name]
            local active = fn ~= nil and fn() == true
            nav.dot.Visible = active
            if active then
                count += 1
            end
        end
        pillDot.BackgroundColor3 = count > 0 and COLORS.on or COLORS.off
        pillText.Text = count > 0 and (count .. " active") or "Idle"
        pillText.TextColor3 = count > 0 and COLORS.text or COLORS.muted
        task.wait(0.5)
    end
end)

log("Ready. Flip a switch on.", "muted")
