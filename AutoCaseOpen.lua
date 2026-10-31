--[[
    Auto Case Open GUI
    -------------------
    Buys + opens cases in a loop by firing the same remote the game's own "Open" button uses:
        ReplicatedStorage.Remotes.MainEvent:FireServer("OpenCase", <case name>, <amount>)

      Case     - exact or partial name of a case in ReplicatedStorage.Cases ("fracture" works).
      Amount   - cases per open. 0 = as many as your Case Open Slots allow (the in-game "Open Nx").
      Delay    - extra seconds to wait after a roll finishes, before the next open.
      Stop after - stop after this many cases (0 = unlimited).
      Sell Junk  - when the inventory is too full for the next batch, sells items whose rarity is in
                   Config.SellRarities (never locked / equipped / StatTrak / blue gem items).
      Stop on Gold - stops once a rarity in Config.StopRarities drops, so you can look at it.
      Skip Animation - while running, sets your LOCAL "Fast Open" + "Animation Speed" values so the
                   game's own roll finishes in a fraction of a second (roll time = 5 / speed), and
                   keeps the roll screen (MainGui.Opening + the vignette) hidden. Nothing is sent to
                   the server; the values are put back when you stop. Items still land in your
                   inventory exactly as before.

    Pacing: after each open the script waits for the server's "CaseOpened" / "CaseOpenRejected"
    reply, then for the game's own roll animation to end (MainGui attribute "CaseRollInProgress").
    With Skip Animation off that is the normal 5s roll (Fast Open / Animation Speed shorten it).

    The game's own Auto Roll toggle should be OFF while this runs (both would fire OpenCase).
    The game's own AutoSell threshold (inventory screen) keeps working on every roll.

    RightCtrl hides / shows the window (Config.ToggleKey).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = {
    CaseName = "Fracture Case",
    Amount = 0, -- 0 = max Case Open Slots
    DelayBetweenOpens = 0.25,
    MaxOpens = 0, -- 0 = unlimited
    SellJunk = true,
    -- Rarity names as stored in ReplicatedStorage.Weapons.<item>.Rarity
    SellRarities = { "Consumer Grade", "Industrial Grade", "Mil-Spec" },
    KeepStatTrak = true,
    StopOnRare = false,
    SkipAnimation = true,
    SkipSpeed = 50, -- local Animation Speed while skipping (roll time = 5 / this = 0.1s)
    StopRarities = { "Extraordinary" }, -- add "Covert" to also stop on reds
    ReplyTimeout = 6, -- seconds to wait for the server to answer an OpenCase
    RollTimeout = 40, -- max seconds to wait for one roll animation
    PostRollWait = 0.6, -- the game sells/refreshes ~0.5s after the roll ends
    ToggleKey = Enum.KeyCode.RightControl,
}

-- Re-running the script replaces the old window instead of stacking a second one.
local env = (getgenv and getgenv()) or _G
if env.AutoCaseDestroy then
    pcall(env.AutoCaseDestroy)
end

local LocalPlayer = Players.LocalPlayer

local function need(parent, name)
    local child = parent:WaitForChild(name, 10)
    if not child then
        error("[AutoCase] " .. parent:GetFullName() .. "." .. name .. " not found - wrong game?")
    end
    return child
end

local MainEvent = need(need(ReplicatedStorage, "Remotes"), "MainEvent")
local Weapons = need(ReplicatedStorage, "Weapons")
local Cases = need(ReplicatedStorage, "Cases")
local PlayerGui = need(LocalPlayer, "PlayerGui")
local MainGui = need(PlayerGui, "MainGui")
local Wallet = need(LocalPlayer, "Wallet")
local Inventory = need(LocalPlayer, "Inventory")
local InventorySize = need(LocalPlayer, "InventorySize")
local Settings = need(LocalPlayer, "Settings")
local CaseSlots = need(Settings, "Case Open Slots")

local state = {
    alive = true,
    running = false,
    runId = 0,
    count = 0,
    spent = 0,
    caseName = Config.CaseName,
    amount = Config.Amount,
    delay = Config.DelayBetweenOpens,
    maxOpens = Config.MaxOpens,
    sellJunk = Config.SellJunk,
    stopOnRare = Config.StopOnRare,
    skip = Config.SkipAnimation,
}

local connections = {}
local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(connections, c)
    return c
end

----------------------------------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------------------------------

local COLORS = {
    bg = Color3.fromRGB(24, 24, 30),
    bar = Color3.fromRGB(34, 34, 44),
    field = Color3.fromRGB(40, 40, 52),
    text = Color3.fromRGB(235, 235, 240),
    dim = Color3.fromRGB(150, 150, 165),
    green = Color3.fromRGB(67, 181, 129),
    red = Color3.fromRGB(237, 66, 69),
    grey = Color3.fromRGB(70, 70, 85),
}

local function create(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    return inst
end

local function corner(radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius or 6) })
end

local function newLabel(text, props)
    local base = {
        Text = text,
        BackgroundTransparency = 1,
        TextColor3 = COLORS.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }
    for k, v in pairs(props or {}) do
        base[k] = v
    end
    return create("TextLabel", base)
end

local function newButton(text, color, height)
    return create("TextButton", {
        Text = text,
        Size = UDim2.new(1, 0, 0, height or 30),
        BackgroundColor3 = color,
        TextColor3 = Color3.new(1, 1, 1),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        AutoButtonColor = true,
    }, { corner() })
end

local function newInputRow(labelText, initial, labelWidth)
    labelWidth = labelWidth or 0.5
    local row = create("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 })
    newLabel(labelText, { Size = UDim2.new(labelWidth, 0, 1, 0), Parent = row })
    local box = create("TextBox", {
        Size = UDim2.new(1 - labelWidth, 0, 1, 0),
        Position = UDim2.new(labelWidth, 0, 0, 0),
        BackgroundColor3 = COLORS.field,
        TextColor3 = COLORS.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        Text = tostring(initial),
        ClearTextOnFocus = false,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    }, { corner(5) })
    return row, box
end

local guiParent
do
    local ok, result = pcall(function()
        return (gethui and gethui()) or game:GetService("CoreGui")
    end)
    guiParent = ok and result or PlayerGui
end

local gui = create("ScreenGui", {
    Name = "AutoCaseGui",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function()
    if syn and syn.protect_gui then
        syn.protect_gui(gui)
    end
end)
gui.Parent = guiParent

local FULL_SIZE = UDim2.fromOffset(280, 434)
local MINI_SIZE = UDim2.fromOffset(280, 30)

local main = create("Frame", {
    Name = "Main",
    Size = FULL_SIZE,
    Position = UDim2.new(0, 40, 0.5, -217),
    BackgroundColor3 = COLORS.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Parent = gui,
}, { corner(8) })

local titleBar = create("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = COLORS.bar,
    BorderSizePixel = 0,
    Parent = main,
})
newLabel("Auto Case Open", {
    Size = UDim2.new(1, -70, 1, 0),
    Position = UDim2.fromOffset(12, 0),
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    Parent = titleBar,
})

local minimizeBtn = create("TextButton", {
    Text = "–",
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -60, 0, 0),
    BackgroundTransparency = 1,
    TextColor3 = COLORS.text,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    Parent = titleBar,
})
local closeBtn = create("TextButton", {
    Text = "X",
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -30, 0, 0),
    BackgroundTransparency = 1,
    TextColor3 = COLORS.red,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    Parent = titleBar,
})

local content = create("Frame", {
    Size = UDim2.new(1, 0, 1, -30),
    Position = UDim2.fromOffset(0, 30),
    BackgroundTransparency = 1,
    Parent = main,
}, {
    create("UIPadding", {
        PaddingTop = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
    }),
    create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
})

local function addToContent(inst, order)
    inst.LayoutOrder = order
    inst.Parent = content
    return inst
end

local caseRow, caseBox = newInputRow("Case", state.caseName, 0.28)
addToContent(caseRow, 1)
local amountRow, amountBox = newInputRow("Amount (0 = max slots)", state.amount, 0.6)
addToContent(amountRow, 2)
local delayRow, delayBox = newInputRow("Delay (seconds)", state.delay, 0.6)
addToContent(delayRow, 3)
local maxRow, maxBox = newInputRow("Stop after (0 = ∞)", state.maxOpens, 0.6)
addToContent(maxRow, 4)

local sellBtn = addToContent(newButton("", COLORS.grey, 26), 5)
local rareBtn = addToContent(newButton("", COLORS.grey, 26), 6)
local skipBtn = addToContent(newButton("", COLORS.grey, 26), 7)
local toggleBtn = addToContent(newButton("Start", COLORS.green, 36), 8)
local statusLabel = addToContent(newLabel("Idle", {
    Size = UDim2.new(1, 0, 0, 18),
    TextXAlignment = Enum.TextXAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
}), 9)
local statsLabel = addToContent(newLabel("Opened: 0   Spent: $0", {
    Size = UDim2.new(1, 0, 0, 18),
    TextColor3 = COLORS.dim,
    TextXAlignment = Enum.TextXAlignment.Center,
}), 10)
local listBtn = addToContent(newButton("Print Case List (F9)", COLORS.grey, 24), 11)
addToContent(newLabel(Config.ToggleKey.Name .. " hides / shows this window", {
    Size = UDim2.new(1, 0, 0, 16),
    TextSize = 11,
    TextColor3 = COLORS.dim,
    TextXAlignment = Enum.TextXAlignment.Center,
}), 12)

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos
    connect(handle.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
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
            local delta = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end
makeDraggable(titleBar, main)

local function setStatus(text, color)
    statusLabel.Text = text
    statusLabel.TextColor3 = color or COLORS.text
end

local function refreshStats()
    statsLabel.Text = ("Opened: %d   Spent: $%s"):format(state.count, string.format("%.2f", state.spent))
end

local function refreshToggleButtons()
    sellBtn.Text = "Sell Junk When Full: " .. (state.sellJunk and "ON" or "OFF")
    sellBtn.BackgroundColor3 = state.sellJunk and COLORS.green or COLORS.grey
    rareBtn.Text = "Stop On Gold: " .. (state.stopOnRare and "ON" or "OFF")
    rareBtn.BackgroundColor3 = state.stopOnRare and COLORS.green or COLORS.grey
    skipBtn.Text = "Skip Animation: " .. (state.skip and "ON" or "OFF")
    skipBtn.BackgroundColor3 = state.skip and COLORS.green or COLORS.grey
end
refreshToggleButtons()

----------------------------------------------------------------------------------------------
-- Helpers around the game's data
----------------------------------------------------------------------------------------------

-- Exact name first, then case-insensitive exact, then substring. Unreleased cases are ignored.
local function resolveCase(name)
    local direct = Cases:FindFirstChild(name)
    if direct and direct:FindFirstChild("Price") then
        return direct
    end
    local lowered = name:lower()
    local partial
    for _, c in ipairs(Cases:GetChildren()) do
        if c:FindFirstChild("Price") and c:GetAttribute("Unreleased") ~= true then
            local candidate = c.Name:lower()
            if candidate == lowered then
                return c
            end
            if not partial and lowered ~= "" and candidate:find(lowered, 1, true) then
                partial = c
            end
        end
    end
    return partial
end

local function inventorySpace()
    return InventorySize.Value - #Inventory:GetChildren()
end

local function toSet(list)
    local set = {}
    for _, name in ipairs(list) do
        set[name] = true
    end
    return set
end

local sellSet = toSet(Config.SellRarities)
local stopSet = toSet(Config.StopRarities)

local function isBoolOn(item, childName)
    local v = item:FindFirstChild(childName)
    return v ~= nil and v.Value == true
end

local function isJunk(item)
    local data = Weapons:FindFirstChild(item.Name)
    local rarity = data and data:FindFirstChild("Rarity")
    if not rarity or not sellSet[rarity.Value] then
        return false
    end
    if data:GetAttribute("IsSticker") == true then
        return false
    end
    if isBoolOn(item, "Locked") or isBoolOn(item, "Equipped") then
        return false
    end
    if Config.KeepStatTrak and isBoolOn(item, "StatTrak") then
        return false
    end
    local gem = item:FindFirstChild("BlueGem")
    if gem and gem.Value > 0 then
        return false
    end
    return true
end

-- Sells everything isJunk() says is junk, in chunks. Returns the list that was sent.
local function sellJunk()
    local list = {}
    for _, item in ipairs(Inventory:GetChildren()) do
        if isJunk(item) then
            table.insert(list, item)
        end
    end
    for i = 1, #list, 50 do
        MainEvent:FireServer("SellItem", table.move(list, i, math.min(i + 49, #list), 1, {}))
        task.wait(0.1)
    end
    return list
end

local function waitUntilGone(list, timeout)
    local started = os.clock()
    while os.clock() - started < timeout do
        local pending = false
        for _, item in ipairs(list) do
            if item.Parent then
                pending = true
                break
            end
        end
        if not pending then
            return
        end
        task.wait(0.1)
    end
end

-- Sends OpenCase and returns the server's reply, or nil on timeout.
local function requestOpen(caseName, amount)
    local reply
    local conn = MainEvent.OnClientEvent:Connect(function(kind, a, b, c)
        if reply == nil and (kind == "CaseOpened" or kind == "CaseOpenRejected") then
            reply = { kind = kind, results = a, case = b, flag = c }
        end
    end)
    MainEvent:FireServer("OpenCase", caseName, amount)
    local started = os.clock()
    while reply == nil and os.clock() - started < Config.ReplyTimeout do
        task.wait()
    end
    conn:Disconnect()
    return reply
end

-- Returns a description of the first result whose rarity is in stopSet, or nil.
local function findRare(results)
    if type(results) ~= "table" then
        return nil
    end
    for _, r in ipairs(results) do
        local item = type(r) == "table" and r.Item
        local data = item and Weapons:FindFirstChild(item.Name)
        local rarity = data and data:FindFirstChild("Rarity")
        if rarity and stopSet[rarity.Value] then
            local weapon = data:FindFirstChild("Weapon")
            return ("%s | %s (%s)"):format(weapon and tostring(weapon.Value) or "?", tostring(data.Value), rarity.Value)
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------
-- Inputs
----------------------------------------------------------------------------------------------

connect(caseBox.FocusLost, function()
    local case = resolveCase(caseBox.Text)
    if case then
        state.caseName = case.Name
        setStatus(("%s - $%s each"):format(case.Name, tostring(case.Price.Value)))
    else
        setStatus("No case matches '" .. caseBox.Text .. "'", COLORS.red)
    end
    caseBox.Text = state.caseName
end)

connect(amountBox.FocusLost, function()
    local n = tonumber(amountBox.Text)
    if n and n >= 0 then
        state.amount = math.floor(n)
    end
    amountBox.Text = tostring(state.amount)
end)

connect(delayBox.FocusLost, function()
    local n = tonumber(delayBox.Text)
    if n and n >= 0 then
        state.delay = n
    end
    delayBox.Text = tostring(state.delay)
end)

connect(maxBox.FocusLost, function()
    local n = tonumber(maxBox.Text)
    if n and n >= 0 then
        state.maxOpens = math.floor(n)
    end
    maxBox.Text = tostring(state.maxOpens)
end)

connect(sellBtn.MouseButton1Click, function()
    state.sellJunk = not state.sellJunk
    refreshToggleButtons()
end)

connect(rareBtn.MouseButton1Click, function()
    state.stopOnRare = not state.stopOnRare
    refreshToggleButtons()
end)

connect(listBtn.MouseButton1Click, function()
    local list = {}
    for _, c in ipairs(Cases:GetChildren()) do
        if c:FindFirstChild("Price") and c:GetAttribute("Unreleased") ~= true then
            table.insert(list, c)
        end
    end
    table.sort(list, function(a, b)
        return a.Price.Value < b.Price.Value
    end)
    print("[AutoCase] Cases (cheapest first):")
    for _, c in ipairs(list) do
        print(("  $%s  %s"):format(tostring(c.Price.Value), c.Name))
    end
    setStatus(("Printed %d cases to console"):format(#list))
end)

----------------------------------------------------------------------------------------------
-- Skip animation
----------------------------------------------------------------------------------------------

-- The game reads its roll time from these two local values (5s, or 5 / Animation Speed when Fast
-- Open is on), so raising them on this client alone makes every roll nearly instant. The server
-- never sees the change, and endSkip() puts the real values back.
local FastOpen = Settings:FindFirstChild("Fast Open")
local AnimSpeed = Settings:FindFirstChild("Animation Speed")
local FullscreenEffects = PlayerGui:FindFirstChild("FullscreenEffects")

local hideTargets = {}
local openingFrame = MainGui:FindFirstChild("Opening")
if openingFrame then
    table.insert(hideTargets, openingFrame)
end
local vignette = FullscreenEffects and FullscreenEffects:FindFirstChild("Vignette")
if vignette then
    table.insert(hideTargets, vignette)
end

local skip = { active = false, saved = nil, conns = {} }

local function beginSkip()
    if skip.active then
        return
    end
    skip.active = true
    skip.saved = {
        fast = FastOpen and FastOpen.Value,
        speed = AnimSpeed and AnimSpeed.Value,
    }
    if FastOpen then
        FastOpen.Value = true
    end
    if AnimSpeed then
        AnimSpeed.Value = Config.SkipSpeed
    end
    -- Keep the roll screen off: every time the game turns it on, switch it straight back off.
    for _, inst in ipairs(hideTargets) do
        if inst.Visible then
            inst.Visible = false
        end
        table.insert(skip.conns, inst:GetPropertyChangedSignal("Visible"):Connect(function()
            if inst.Visible then
                inst.Visible = false
            end
        end))
    end
end

local function endSkip()
    if not skip.active then
        return
    end
    skip.active = false
    for _, c in ipairs(skip.conns) do
        c:Disconnect()
    end
    table.clear(skip.conns)
    local saved = skip.saved
    skip.saved = nil
    if saved then
        if FastOpen and saved.fast ~= nil then
            FastOpen.Value = saved.fast
        end
        -- Only restore the speed if nothing else (e.g. the server) changed it while we were running.
        if AnimSpeed and saved.speed ~= nil and AnimSpeed.Value == Config.SkipSpeed then
            AnimSpeed.Value = saved.speed
        end
    end
end

connect(skipBtn.MouseButton1Click, function()
    state.skip = not state.skip
    refreshToggleButtons()
    if state.running then
        if state.skip then
            beginSkip()
        else
            endSkip()
        end
    end
end)

----------------------------------------------------------------------------------------------
-- Open loop
----------------------------------------------------------------------------------------------

local function stopOpening(message, color)
    state.running = false
    state.runId += 1
    endSkip()
    toggleBtn.Text = "Start"
    toggleBtn.BackgroundColor3 = COLORS.green
    setStatus(message or ("Stopped - opened " .. state.count), color)
end

-- The game's roll animation flips MainGui's CaseRollInProgress attribute on for its whole duration.
local function waitForRoll(active)
    task.wait(0.2)
    local started = os.clock()
    while active() and MainGui:GetAttribute("CaseRollInProgress") == true and os.clock() - started < Config.RollTimeout do
        task.wait(0.1)
    end
    task.wait(Config.PostRollWait)
end

local function startOpening()
    for _, box in ipairs({ caseBox, amountBox, delayBox, maxBox }) do
        if box:IsFocused() then
            box:ReleaseFocus()
        end
    end

    if not resolveCase(state.caseName) then
        setStatus("No case matches '" .. state.caseName .. "'", COLORS.red)
        return
    end
    local autoOpen = Settings:FindFirstChild("Auto Open")
    if autoOpen and autoOpen.Value == true then
        setStatus("Turn the in-game AUTO ROLL off first", COLORS.red)
        return
    end

    state.running = true
    state.runId += 1
    state.count = 0
    state.spent = 0
    refreshStats()
    local myRun = state.runId
    toggleBtn.Text = "Stop"
    toggleBtn.BackgroundColor3 = COLORS.red
    if state.skip then
        beginSkip()
    end

    local function active()
        return state.alive and state.running and state.runId == myRun
    end

    task.spawn(function()
        local failures = 0
        while active() do
            local case = resolveCase(state.caseName)
            if not case then
                stopOpening("Case '" .. state.caseName .. "' disappeared", COLORS.red)
                return
            end
            local price = case.Price.Value

            local slots = math.max(CaseSlots.Value, 1)
            local desired = state.amount > 0 and math.min(state.amount, slots) or slots
            if state.maxOpens > 0 then
                desired = math.min(desired, state.maxOpens - state.count)
            end

            local batch = desired
            if price > 0 then
                local affordable = math.floor(Wallet.Value / price + 1e-9)
                if affordable < 1 then
                    setStatus(("Waiting for money ($%s needed)"):format(tostring(price)), COLORS.dim)
                    task.wait(1)
                    continue
                end
                batch = math.min(batch, affordable)
            end

            if inventorySpace() < batch and state.sellJunk then
                setStatus("Inventory full - selling junk")
                local sold = sellJunk()
                if #sold > 0 then
                    waitUntilGone(sold, 3)
                end
                if not active() then
                    return
                end
            end
            local space = inventorySpace()
            if space < 1 then
                stopOpening("Inventory full", COLORS.red)
                return
            end
            batch = math.min(batch, space)

            setStatus(("Opening %dx %s ..."):format(batch, case.Name))
            local reply = requestOpen(case.Name, batch)
            if not active() then
                return
            end

            if reply == nil or reply.kind == "CaseOpenRejected" then
                failures += 1
                local reason = reply and tostring(reply.results) or "no reply from the server"
                warn("[AutoCase] open failed: " .. reason)
                if failures >= 3 then
                    stopOpening("Stopped: " .. reason, COLORS.red)
                    return
                end
                setStatus("Rejected: " .. reason, COLORS.red)
                task.wait(1)
            else
                failures = 0
                local opened = type(reply.results) == "table" and #reply.results or batch
                state.count += opened
                state.spent += price * opened
                refreshStats()

                waitForRoll(active)
                if not active() then
                    return
                end

                local rare = state.stopOnRare and findRare(reply.results)
                if rare then
                    stopOpening("Dropped " .. rare, COLORS.green)
                    print("[AutoCase] Stopped on " .. rare)
                    return
                end
                if state.maxOpens > 0 and state.count >= state.maxOpens then
                    stopOpening("Done - opened " .. state.count)
                    return
                end
                task.wait(state.delay)
            end
        end
    end)
end

connect(toggleBtn.MouseButton1Click, function()
    if state.running then
        stopOpening()
    else
        startOpening()
    end
end)

----------------------------------------------------------------------------------------------
-- Window controls
----------------------------------------------------------------------------------------------

local minimized = false
connect(minimizeBtn.MouseButton1Click, function()
    minimized = not minimized
    main.Size = minimized and MINI_SIZE or FULL_SIZE
end)

connect(UserInputService.InputBegan, function(input, gameProcessed)
    if not gameProcessed and input.KeyCode == Config.ToggleKey then
        main.Visible = not main.Visible
    end
end)

local function destroy()
    state.alive = false
    state.running = false
    state.runId += 1
    endSkip()
    for _, c in ipairs(connections) do
        c:Disconnect()
    end
    table.clear(connections)
    gui:Destroy()
    env.AutoCaseDestroy = nil
end
env.AutoCaseDestroy = destroy
connect(closeBtn.MouseButton1Click, destroy)

setStatus("Idle - pick a case and press Start")
