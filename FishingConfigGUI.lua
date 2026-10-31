--[[
    Fishing Config GUI
    Live editor for ReplicatedStorage.Data.Config.FishingConfig (the table the fishing client reads).

    TABS
      Quick Mods   one-click presets (instant cast, fast bite, easy tension, wide counter window, ...)
      <sections>   every numeric / boolean value in the config (Cast, Bite, Combat, Boss, ...), editable
      Search box   filters every value in every section at once

    USAGE
      * Edit a value and press Enter. Changed rows turn amber; "R" resets a row to the value it had at execute time.
      * RightShift toggles the window, "-" collapses it. "X" restores every value to its default, then unloads
        (re-executing also replaces the old copy the same way).
      * Copy Changes puts a ready-to-paste Lua snippet of everything you modified on the clipboard.

    NOTES
      * The module returns table.freeze(config), which only freezes the TOP level. The section tables
        (Cast, Bite, Combat, ...) are still writable, so values are changed in place and every script that
        holds a reference to the module sees them. setreadonly is used as a fallback when available.
      * Anything the game copied into a local at load time (e.g. `local d = Config.Cast.BaitMaxDist` at the top
        of a module) will not see changes until that code re-reads it - recast / re-equip / rejoin.
      * This only changes the client's copy. Anything the server validates (ServerMaxDistance, damage,
        bite timing, boss rolls) can still be rejected or ignored server-side.
]]

local CONFIG = {
    ToggleKey = Enum.KeyCode.RightShift,
    MaxSearchResults = 120,
}

local env = (getgenv and getgenv()) or _G
if env.FishingConfigGUI and env.FishingConfigGUI.Destroy then
    pcall(env.FishingConfigGUI.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local ConfigModule = ReplicatedStorage:WaitForChild("Data"):WaitForChild("Config"):WaitForChild("FishingConfig")
local okReq, cfg = pcall(require, ConfigModule)
if not okReq or type(cfg) ~= "table" then
    warn("[FishingConfig] failed to require FishingConfig: " .. tostring(cfg))
    return
end

----------------------------------------------------------------------
-- Config model: flatten every number / boolean into an entry
----------------------------------------------------------------------
local SECTION_ORDER = {
    "Cast", "LuckBar", "Bite", "PullBar", "FirstPull", "Latency", "Reel", "Tension", "Counter", "Skill",
    "Fight", "Combat", "Boss", "SessionDebt", "General", "EventEffectCap", "Pity", "Click", "AutoFishing",
    "Tutorial", "Loot", "CatchScene", "ReelCounterUI", "ClickFX", "Boundary", "RemoteFishing", "FishVisual",
    "SessionInfoUI", "LuckBarUI", "FloatingNoti", "PerfectFX", "FloatingDmg", "CatchXpByRarity", "HeldFish",
}

local entries = {}      -- every editable leaf, in display order
local byKey = {}        -- "Cast/BaitMinDist" -> entry
local sections = {}     -- section name -> list of entries
local sectionNames = {} -- sections that have at least one editable leaf

local function keyOf(path)
    local parts = {}
    for i, k in ipairs(path) do parts[i] = tostring(k) end
    return table.concat(parts, "/")
end

-- builds ".Levels.Hard.growPerSec" / "[1].threshold" style text; prefix "" for labels, "cfg" for Lua snippets
local function pathText(path, from, prefix)
    local s = prefix
    for i = from, #path do
        local k = path[i]
        if type(k) == "number" then
            s = s .. "[" .. k .. "]"
        elseif k:match("^[%a_][%w_]*$") then
            s = s .. (s ~= "" and "." or "") .. k
        else
            s = s .. string.format("[%q]", k)
        end
    end
    return s
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        local tk = type(k)
        if tk == "string" or tk == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta == "number" end
        return a < b
    end)
    return keys
end

local function collect(tbl, path, section, out, depth)
    if depth > 6 then return end
    for _, k in ipairs(sortedKeys(tbl)) do
        local v = tbl[k]
        local t = type(v)
        if t == "number" or t == "boolean" then
            local p = table.clone(path)
            p[#p + 1] = k
            out[#out + 1] = {
                path = p, key = keyOf(p), section = section,
                label = pathText(p, 2, ""), orig = v, isBool = (t == "boolean"),
            }
        elseif t == "table" then
            local p = table.clone(path)
            p[#p + 1] = k
            collect(v, p, section, out, depth + 1)
        end
    end
end

do
    local rank = {}
    for i, name in ipairs(SECTION_ORDER) do rank[name] = i end
    local names = {}
    for k, v in pairs(cfg) do
        if type(k) == "string" and type(v) == "table" then names[#names + 1] = k end
    end
    table.sort(names, function(a, b)
        local ra, rb = rank[a] or math.huge, rank[b] or math.huge
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    for _, name in ipairs(names) do
        local list = {}
        collect(cfg[name], { name }, name, list, 1)
        if #list > 0 then
            sections[name] = list
            sectionNames[#sectionNames + 1] = name
            for _, e in ipairs(list) do
                entries[#entries + 1] = e
                byKey[e.key] = e
            end
        end
    end
end

if #entries == 0 then
    warn("[FishingConfig] FishingConfig has no editable values")
    return
end

local function parentOf(path)
    local t = cfg
    for i = 1, #path - 1 do
        t = t[path[i]]
        if type(t) ~= "table" then return nil end
    end
    return t
end

local function getValue(path)
    local p = parentOf(path)
    if p then return p[path[#path]] end
    return nil
end

local function setValue(path, value)
    local p = parentOf(path)
    if not p then return false end
    if table.isfrozen(p) and setreadonly then pcall(setreadonly, p, false) end
    return (pcall(function() p[path[#path]] = value end))
end

local function fmtValue(v)
    if type(v) == "number" then
        if v % 1 == 0 and math.abs(v) < 1e9 then return string.format("%d", v) end
        return string.format("%.6g", v)
    end
    return tostring(v)
end

----------------------------------------------------------------------
-- Quick mods
----------------------------------------------------------------------
local quickActive = {}  -- mod id -> list of entries it currently overrides
local quickValues = {}  -- mod id -> current value-box number

local function scaled(path, mult)
    local e = byKey[keyOf(path)]
    return e and e.orig * mult
end

local LEVELS = { "Normal", "Hard", "Boss", "BossPhase2" }

local QUICK = {
    {
        id = "InstantCast", name = "Instant Cast",
        desc = "Removes the minimum hold, throw and cancel delays and shortens the bait flight.",
        build = function(add)
            add({ "Cast", "MinHoldTime" }, 0)
            add({ "Cast", "ThrowDelay" }, 0)
            add({ "Cast", "BaitTweenTime" }, 0.25)
            add({ "General", "CastCancelDelay" }, 0)
        end,
    },
    {
        id = "CastRange", name = "Cast Range",
        desc = "Multiplies bait min / max distance and the max distance the client allows.",
        value = { label = "mult", default = 2 },
        build = function(add, v)
            for _, k in ipairs({ "BaitMinDist", "BaitMaxDist", "ServerMaxDistance" }) do
                add({ "Cast", k }, scaled({ "Cast", k }, v))
            end
        end,
    },
    {
        id = "FastBite", name = "Fast Bite",
        desc = "Sets the bite wait (seconds) and drops the warning and minimum effective wait.",
        value = { label = "secs", default = 0.1 },
        build = function(add, v)
            add({ "Bite", "MinWaitTime" }, v)
            add({ "Bite", "MaxWaitTime" }, v)
            add({ "Bite", "BiteWarningTime" }, 0)
            add({ "Bite", "MinimumEffectiveWaitTime" }, 0)
        end,
    },
    {
        id = "SlowLuckBar", name = "Slow Luck Bar",
        desc = "Multiplies the luck bar cycle time. A slower bar is easier to stop on Perfect.",
        value = { label = "mult", default = 3 },
        build = function(add, v)
            add({ "LuckBar", "CycleMin" }, scaled({ "LuckBar", "CycleMin" }, v))
            add({ "LuckBar", "CycleMax" }, scaled({ "LuckBar", "CycleMax" }, v))
        end,
    },
    {
        id = "EasyTension", name = "Easy Tension",
        desc = "Multiplies tension growth and miss penalty on every difficulty level. Lower is easier.",
        value = { label = "mult", default = 0.25 },
        build = function(add, v)
            for _, level in ipairs(LEVELS) do
                for _, k in ipairs({ "growPerSec", "missMag" }) do
                    add({ "Combat", "Levels", level, k }, scaled({ "Combat", "Levels", level, k }, v))
                end
            end
        end,
    },
    {
        id = "WideQTE", name = "Wide Counter Window",
        desc = "Multiplies the A / D / W counter prompt window and when it starts fading.",
        value = { label = "mult", default = 2.5 },
        build = function(add, v)
            add({ "Counter", "QTEWindow" }, scaled({ "Counter", "QTEWindow" }, v))
            add({ "Counter", "QTEFadeStart" }, scaled({ "Counter", "QTEFadeStart" }, v))
        end,
    },
    {
        id = "ReelPower", name = "Reel Power",
        desc = "Multiplies base reel damage.",
        value = { label = "mult", default = 3 },
        build = function(add, v)
            add({ "Reel", "BaseDamage" }, scaled({ "Reel", "BaseDamage" }, v))
        end,
    },
    {
        id = "InstantSkill", name = "Instant Skills",
        desc = "Drops the minimum skill cast time to 0.05s.",
        build = function(add)
            add({ "Skill", "MinCastTime" }, 0.05)
        end,
    },
    {
        id = "FastAuto", name = "Faster Auto-Fishing",
        desc = "Recast delay 0.1s. The value box is the gap (seconds) between auto-fishing skills.",
        value = { label = "secs", default = 3 },
        build = function(add, v)
            add({ "AutoFishing", "RecastDelay" }, 0.1)
            add({ "AutoFishing", "SkillGapSec" }, v)
        end,
    },
    {
        id = "BossTweaks", name = "Boss Tweaks",
        desc = "Removes the boss miss lockout and multiplies how long a stun lasts.",
        value = { label = "mult", default = 2 },
        build = function(add, v)
            add({ "Boss", "MissLockoutSec" }, 0)
            add({ "Boss", "StunDurationSec" }, scaled({ "Boss", "StunDurationSec" }, v))
        end,
    },
}

for _, mod in ipairs(QUICK) do
    quickValues[mod.id] = mod.value and mod.value.default or nil
end

local function quickDisable(mod)
    local list = quickActive[mod.id]
    if not list then return end
    for _, e in ipairs(list) do setValue(e.path, e.orig) end
    quickActive[mod.id] = nil
end

local function quickEnable(mod, v)
    quickDisable(mod)
    local list = {}
    mod.build(function(path, value)
        local e = byKey[keyOf(path)]
        if e and value ~= nil and setValue(path, value) then
            list[#list + 1] = e
        end
    end, v)
    if #list > 0 then quickActive[mod.id] = list end
end

local function resetEntry(e)
    setValue(e.path, e.orig)
    for id, list in pairs(quickActive) do
        local i = table.find(list, e)
        if i then
            table.remove(list, i)
            if #list == 0 then quickActive[id] = nil end
        end
    end
end

local function resetAll()
    for _, e in ipairs(entries) do setValue(e.path, e.orig) end
    table.clear(quickActive)
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local C = {
    bg = Color3.fromRGB(24, 25, 32),
    title = Color3.fromRGB(34, 36, 46),
    panel = Color3.fromRGB(30, 32, 41),
    row = Color3.fromRGB(41, 44, 57),
    text = Color3.fromRGB(230, 232, 240),
    dim = Color3.fromRGB(141, 147, 170),
    accent = Color3.fromRGB(88, 101, 242),
    green = Color3.fromRGB(67, 160, 100),
    red = Color3.fromRGB(200, 70, 80),
    amber = Color3.fromRGB(214, 150, 50),
    grey = Color3.fromRGB(70, 74, 92),
}

local conns = {}
local destroyed = false

local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(conns, c)
    return c
end

local function new(class, props)
    local inst = Instance.new(class)
    local parent = props.Parent
    props.Parent = nil
    for k, v in pairs(props) do inst[k] = v end
    inst.Parent = parent
    return inst
end

local function corner(inst, r)
    new("UICorner", { CornerRadius = UDim.new(0, r or 6), Parent = inst })
end

local function makeButton(parent, text, size, pos, color, callback, props)
    local b = new("TextButton", {
        Parent = parent, Text = text, Size = size, Position = pos, BackgroundColor3 = color,
        TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamMedium, TextSize = 12,
        AutoButtonColor = true, BorderSizePixel = 0,
    })
    for k, v in pairs(props or {}) do b[k] = v end
    corner(b, 5)
    -- not tracked in `conns`: rows are rebuilt constantly, and destroying the button drops the connection
    if callback then b.MouseButton1Click:Connect(callback) end
    return b
end

local function makeLabel(parent, text, size, pos, props)
    local l = new("TextLabel", {
        Parent = parent, Text = text, Size = size, Position = pos, BackgroundTransparency = 1,
        TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    })
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

local function makeBox(parent, text, placeholder, size, pos)
    local b = new("TextBox", {
        Parent = parent, Text = text, PlaceholderText = placeholder, Size = size, Position = pos,
        BackgroundColor3 = C.row, TextColor3 = C.text, PlaceholderColor3 = Color3.fromRGB(120, 124, 142),
        Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false, BorderSizePixel = 0,
    })
    corner(b, 5)
    return b
end

local function makeList(parent, pos, size)
    local sf = new("ScrollingFrame", {
        Parent = parent, Position = pos, Size = size, BackgroundColor3 = C.panel, BorderSizePixel = 0,
        ScrollBarThickness = 4, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    })
    corner(sf, 6)
    new("UIListLayout", { Parent = sf, Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder })
    new("UIPadding", {
        Parent = sf, PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
    })
    return sf
end

local function clearList(list)
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
end

-- window ----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "FishingConfigGUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
local parentOk = pcall(function()
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not parentOk or not gui.Parent then
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local WIN_W, WIN_H = 660, 440
local main = new("Frame", {
    Parent = gui, Size = UDim2.fromOffset(WIN_W, WIN_H), Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2),
    BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true,
})
corner(main, 8)

local titleBar = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.title, BorderSizePixel = 0 })
-- drag handle sits behind the controls so clicking the search box / buttons never starts a drag
local dragArea = new("Frame", { Parent = titleBar, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
makeLabel(titleBar, "Fishing Config", UDim2.fromOffset(110, 30), UDim2.new(0, 12, 0, 0), { Font = Enum.Font.GothamBold, TextSize = 14 })
local search = makeBox(titleBar, "", "Search all values...", UDim2.fromOffset(220, 22), UDim2.fromOffset(130, 4))

local body = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 1, -30), Position = UDim2.new(0, 0, 0, 30), BackgroundTransparency = 1 })
local sidebar = makeList(body, UDim2.fromOffset(6, 6), UDim2.new(0, 130, 1, -46))
local content = makeList(body, UDim2.fromOffset(142, 6), UDim2.new(1, -148, 1, -46))
local bottom = new("Frame", { Parent = body, Size = UDim2.new(1, -12, 0, 28), Position = UDim2.new(0, 6, 1, -34), BackgroundTransparency = 1 })
local statusLabel = makeLabel(bottom, "", UDim2.new(1, -300, 1, 0), UDim2.new(0, 4, 0, 0), { TextColor3 = C.dim, TextTruncate = Enum.TextTruncate.AtEnd })

local currentTab = "Quick Mods"
local tabButtons = {}
local flashUntil = 0
local render -- forward declaration

local function updateStatus()
    local total = 0
    local changedIn = {}
    for _, e in ipairs(entries) do
        if getValue(e.path) ~= e.orig then
            total = total + 1
            changedIn[e.section] = true
        end
    end
    for name, b in pairs(tabButtons) do
        local marked = (name == "Quick Mods") and next(quickActive) ~= nil or changedIn[name]
        b.Text = name .. (marked and "  \u{2022}" or "")
    end
    if os.clock() >= flashUntil then
        statusLabel.Text = total == 0 and "No values modified" or (total .. " value(s) modified")
    end
end

local function flash(text, seconds)
    seconds = seconds or 3
    statusLabel.Text = text
    flashUntil = os.clock() + seconds
    task.delay(seconds + 0.05, function()
        if not destroyed and os.clock() >= flashUntil then updateStatus() end
    end)
end

local function setTab(name)
    currentTab = name
    for n, b in pairs(tabButtons) do
        b.BackgroundColor3 = (n == name) and C.accent or C.row
    end
    if search.Text ~= "" then search.Text = "" end
    render()
end

do
    local order = 0
    local function addTab(name)
        order = order + 1
        tabButtons[name] = makeButton(sidebar, name, UDim2.new(1, -6, 0, 24), UDim2.new(), C.row, function() setTab(name) end, {
            LayoutOrder = order, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        })
        new("UIPadding", { Parent = tabButtons[name], PaddingLeft = UDim.new(0, 8) })
    end
    addTab("Quick Mods")
    for _, name in ipairs(sectionNames) do addTab(name) end
end

-- value rows --------------------------------------------------------------
local function addValueRow(list, order, e, showSection)
    local row = new("Frame", { Parent = list, Size = UDim2.new(1, -6, 0, 28), BackgroundColor3 = C.row, BorderSizePixel = 0, LayoutOrder = order })
    corner(row, 5)

    local label = makeLabel(row, (showSection and (e.section .. ".") or "") .. e.label, UDim2.new(1, -206, 1, 0), UDim2.new(0, 10, 0, 0), {
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    makeLabel(row, "def " .. fmtValue(e.orig), UDim2.fromOffset(84, 28), UDim2.new(1, -194, 0, 0), {
        TextColor3 = C.dim, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right,
    })
    local reset = makeButton(row, "R", UDim2.fromOffset(22, 20), UDim2.new(1, -28, 0.5, -10), C.grey)

    local input
    if e.isBool then
        input = makeButton(row, "", UDim2.fromOffset(64, 20), UDim2.new(1, -98, 0.5, -10), C.grey)
    else
        input = makeBox(row, "", "", UDim2.fromOffset(64, 20), UDim2.new(1, -98, 0.5, -10))
        input.BackgroundColor3 = C.panel
        input.TextXAlignment = Enum.TextXAlignment.Center
    end

    local shown
    local function paint()
        local cur = getValue(e.path)
        local changed = cur ~= e.orig
        label.TextColor3 = changed and C.amber or C.text
        reset.Visible = changed
        if e.isBool then
            input.Text = cur and "ON" or "OFF"
            input.BackgroundColor3 = cur and C.green or C.grey
        else
            shown = fmtValue(cur)
            input.Text = shown
            input.TextColor3 = changed and C.amber or C.text
        end
    end
    paint()

    if e.isBool then
        input.MouseButton1Click:Connect(function()
            if not setValue(e.path, not getValue(e.path)) then flash("Write failed - table is read-only here", 4) end
            paint()
            updateStatus()
        end)
    else
        input.FocusLost:Connect(function()
            if input.Text ~= shown then
                local n = tonumber(input.Text)
                if n and n == n and n ~= math.huge and n ~= -math.huge then
                    if not setValue(e.path, n) then flash("Write failed - table is read-only here", 4) end
                end
            end
            paint()
            updateStatus()
        end)
    end
    reset.MouseButton1Click:Connect(function()
        resetEntry(e)
        paint()
        updateStatus()
    end)
end

-- quick mod cards -----------------------------------------------------------
local function addQuickRow(list, order, mod)
    local active = quickActive[mod.id] ~= nil
    local row = new("Frame", { Parent = list, Size = UDim2.new(1, -6, 0, 56), BackgroundColor3 = C.row, BorderSizePixel = 0, LayoutOrder = order })
    corner(row, 5)
    makeLabel(row, mod.name, UDim2.new(1, -220, 0, 18), UDim2.new(0, 10, 0, 5), { Font = Enum.Font.GothamBold, TextSize = 13 })
    makeLabel(row, mod.desc, UDim2.new(1, -220, 0, 28), UDim2.new(0, 10, 0, 23), {
        TextColor3 = C.dim, TextSize = 11, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })

    makeButton(row, active and "ON" or "OFF", UDim2.fromOffset(60, 24), UDim2.new(1, -70, 0.5, -12), active and C.green or C.grey, function()
        if quickActive[mod.id] then
            quickDisable(mod)
        else
            quickEnable(mod, quickValues[mod.id])
        end
        render()
        updateStatus()
    end)

    if mod.value then
        makeLabel(row, mod.value.label, UDim2.fromOffset(40, 24), UDim2.new(1, -184, 0.5, -12), {
            TextColor3 = C.dim, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right,
        })
        local box = makeBox(row, fmtValue(quickValues[mod.id]), "", UDim2.fromOffset(60, 24), UDim2.new(1, -140, 0.5, -12))
        box.BackgroundColor3 = C.panel
        box.TextXAlignment = Enum.TextXAlignment.Center
        box.FocusLost:Connect(function()
            local n = tonumber(box.Text)
            if n and n >= 0 and n < math.huge then
                quickValues[mod.id] = n
                if quickActive[mod.id] then
                    quickEnable(mod, n)
                    updateStatus()
                end
            end
            box.Text = fmtValue(quickValues[mod.id])
        end)
    end
end

function render()
    clearList(content)
    local query = search.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")

    if query == "" and currentTab == "Quick Mods" then
        makeLabel(content, "Presets edit the live config tables. The server's own checks are not affected.", UDim2.new(1, -6, 0, 20), UDim2.new(), {
            TextColor3 = C.dim, TextSize = 11, TextWrapped = true, LayoutOrder = 0,
        })
        for i, mod in ipairs(QUICK) do addQuickRow(content, i, mod) end
        return
    end

    local list, showSection = sections[currentTab] or {}, false
    if query ~= "" then
        list, showSection = {}, true
        for _, e in ipairs(entries) do
            if (e.section .. "." .. e.label):lower():find(query, 1, true) then
                list[#list + 1] = e
                if #list >= CONFIG.MaxSearchResults then break end
            end
        end
    end

    if #list == 0 then
        makeLabel(content, "No matching values.", UDim2.new(1, -6, 0, 24), UDim2.new(), { TextColor3 = C.dim })
        return
    end
    for i, e in ipairs(list) do addValueRow(content, i, e, showSection) end
end

-- bottom bar ---------------------------------------------------------------
makeButton(bottom, "Copy Changes", UDim2.fromOffset(96, 24), UDim2.new(1, -96, 0, 2), C.accent, function()
    local lines = {}
    for _, e in ipairs(entries) do
        local cur = getValue(e.path)
        if cur ~= e.orig then
            lines[#lines + 1] = pathText(e.path, 1, "cfg") .. " = " .. tostring(cur)
        end
    end
    if #lines == 0 then
        flash("Nothing modified yet")
        return
    end
    local text = "local cfg = require(game:GetService(\"ReplicatedStorage\").Data.Config.FishingConfig)\n" .. table.concat(lines, "\n")
    local clip = setclipboard or toclipboard
    if clip then
        clip(text)
        flash("Copied " .. #lines .. " change(s) to the clipboard")
    else
        print(text)
        flash("No clipboard function - printed to the console instead", 4)
    end
end)
makeButton(bottom, "Reset All", UDim2.fromOffset(80, 24), UDim2.new(1, -182, 0, 2), C.red, function()
    resetAll()
    render()
    updateStatus()
    flash("Everything reset to defaults")
end)
makeButton(bottom, "Reset Section", UDim2.fromOffset(100, 24), UDim2.new(1, -288, 0, 2), C.amber, function()
    if currentTab == "Quick Mods" then
        for _, mod in ipairs(QUICK) do quickDisable(mod) end
    else
        for _, e in ipairs(sections[currentTab] or {}) do resetEntry(e) end
    end
    render()
    updateStatus()
end)

-- title bar buttons / dragging / hotkey ------------------------------------------
local minimized = false

local function destroy()
    if destroyed then return end
    destroyed = true
    resetAll()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if gui then gui:Destroy() end
    if env.FishingConfigGUI and env.FishingConfigGUI.Destroy == destroy then env.FishingConfigGUI = nil end
end
env.FishingConfigGUI = { Destroy = destroy }

makeButton(titleBar, "-", UDim2.fromOffset(24, 20), UDim2.new(1, -56, 0.5, -10), C.grey, function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(WIN_W, 30) or UDim2.fromOffset(WIN_W, WIN_H)
end)
makeButton(titleBar, "X", UDim2.fromOffset(24, 20), UDim2.new(1, -28, 0.5, -10), C.red, destroy)

do
    local dragging, dragStart, startPos
    connect(dragArea.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
            local c
            c = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    c:Disconnect()
                end
            end)
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    connect(UserInputService.InputBegan, function(input, processed)
        if not processed and input.KeyCode == CONFIG.ToggleKey then
            main.Visible = not main.Visible
        end
    end)
end

local searchToken = 0
connect(search:GetPropertyChangedSignal("Text"), function()
    searchToken = searchToken + 1
    local token = searchToken
    task.delay(0.15, function()
        if token == searchToken and not destroyed then render() end
    end)
end)

setTab("Quick Mods")
updateStatus()

-- writes can silently fail on executors that deep-freeze tables; tell the user up front
do
    local probe = entries[1]
    if not setValue(probe.path, probe.orig) then
        flash("Config looks read-only on this executor - edits will not apply", 8)
    end
end
