--[[
    Auto Hatch GUI
    ---------------
    Calls ReplicatedStorage.Remotes.Funcs.PromptHatch:InvokeServer(EggId, Amount) in a loop,
    e.g. the call you captured:  PromptHatch:InvokeServer(9, "Max")

      Egg ID   - first argument (9 in your example). Numbers are sent as numbers.
      Amount   - second argument. "Max" is sent as a string, "1" / "3" as numbers.
      Delay    - extra seconds to wait after the server replies, before the next hatch.
      Max      - stop after this many hatches (0 = unlimited).
      Skip     - while hatching, hides any GUI whose name matches Config.AnimationGuiPatterns
                 (the egg-opening animation). The game's own scripts keep running, only the
                 visuals are hidden. Matches are printed to the F9 console.

    InvokeServer waits for the server's reply, so the loop already paces itself on the server;
    raise the delay if the game rejects hatches that come too fast.

    RightCtrl hides / shows the window (Config.ToggleKey).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = {
    RemotePath = { "Remotes", "Funcs", "PromptHatch" }, -- under ReplicatedStorage
    EggId = 9,
    Amount = "Max",
    DelayBetweenHatches = 0.5,
    MaxHatches = 0,
    SkipAnimation = true,
    -- Lowercase fragments of GUI names (ScreenGui / Frame / CanvasGroup / ViewportFrame) to hide.
    -- If the animation still plays, check the F9 console for "New ScreenGui" lines and add its name.
    AnimationGuiPatterns = { "hatch", "reveal", "eggopen", "openegg", "opening", "eggresult" },
    ToggleKey = Enum.KeyCode.RightControl,
}

-- Re-running the script replaces the old window instead of stacking a second one.
local env = (getgenv and getgenv()) or _G
if env.AutoHatchDestroy then
    pcall(env.AutoHatchDestroy)
end

local state = {
    alive = true,
    running = false,
    runId = 0,
    count = 0,
    eggId = Config.EggId,
    amount = Config.Amount,
    delay = Config.DelayBetweenHatches,
    maxHatches = Config.MaxHatches,
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

local function newInputRow(labelText, initial)
    local row = create("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 })
    newLabel(labelText, { Size = UDim2.new(0.58, 0, 1, 0), Parent = row })
    local box = create("TextBox", {
        Size = UDim2.new(0.42, 0, 1, 0),
        Position = UDim2.new(0.58, 0, 0, 0),
        BackgroundColor3 = COLORS.field,
        TextColor3 = COLORS.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        Text = tostring(initial),
        ClearTextOnFocus = false,
        Parent = row,
    }, { corner(5) })
    return row, box
end

local guiParent
do
    local ok, result = pcall(function()
        return (gethui and gethui()) or game:GetService("CoreGui")
    end)
    guiParent = ok and result or Players.LocalPlayer:WaitForChild("PlayerGui")
end

local gui = create("ScreenGui", {
    Name = "AutoHatchGui",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function()
    if syn and syn.protect_gui then
        syn.protect_gui(gui)
    end
end)
gui.Parent = guiParent

local FULL_SIZE = UDim2.fromOffset(280, 364)
local MINI_SIZE = UDim2.fromOffset(280, 30)

local main = create("Frame", {
    Name = "Main",
    Size = FULL_SIZE,
    Position = UDim2.new(0, 40, 0.5, -182),
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
newLabel("Auto Hatch", {
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

local remoteLabel = addToContent(newLabel("Remote: …", {
    Size = UDim2.new(1, 0, 0, 18),
    TextColor3 = COLORS.dim,
}), 1)

local eggRow, eggBox = newInputRow("Egg ID", state.eggId)
addToContent(eggRow, 2)
local amountRow, amountBox = newInputRow("Amount (Max / 1 / 3…)", state.amount)
addToContent(amountRow, 3)
local delayRow, delayBox = newInputRow("Delay (seconds)", state.delay)
addToContent(delayRow, 4)
local maxRow, maxBox = newInputRow("Stop after (0 = ∞)", state.maxHatches)
addToContent(maxRow, 5)

local skipBtn = addToContent(newButton("", COLORS.grey, 26), 6)
local toggleBtn = addToContent(newButton("Start", COLORS.green, 36), 7)
local statusLabel = addToContent(newLabel("Idle", {
    Size = UDim2.new(1, 0, 0, 18),
    TextXAlignment = Enum.TextXAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
}), 8)
local dumpBtn = addToContent(newButton("Print Replica Data (F9)", COLORS.grey, 24), 9)
addToContent(newLabel(Config.ToggleKey.Name .. " hides / shows this window", {
    Size = UDim2.new(1, 0, 0, 16),
    TextSize = 11,
    TextColor3 = COLORS.dim,
    TextXAlignment = Enum.TextXAlignment.Center,
}), 10)

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

----------------------------------------------------------------------------------------------
-- Remote lookup + inputs
----------------------------------------------------------------------------------------------

local function setStatus(text, color)
    statusLabel.Text = text
    statusLabel.TextColor3 = color or COLORS.text
end

local remoteName = Config.RemotePath[#Config.RemotePath]

local function findRemote()
    local node = ReplicatedStorage
    for _, name in ipairs(Config.RemotePath) do
        node = node:FindFirstChild(name)
        if not node then
            return nil
        end
    end
    if node:IsA("RemoteFunction") or node:IsA("RemoteEvent") then
        return node
    end
    return nil
end

local function refreshRemoteLabel()
    if findRemote() then
        remoteLabel.Text = "Remote: " .. remoteName .. " found"
        remoteLabel.TextColor3 = COLORS.green
    else
        remoteLabel.Text = "Remote: " .. remoteName .. " NOT found"
        remoteLabel.TextColor3 = COLORS.red
    end
end

-- "9" -> 9, "Max" -> "Max"
local function parseArg(text)
    return tonumber(text) or text
end

connect(eggBox.FocusLost, function()
    if eggBox.Text ~= "" then
        state.eggId = parseArg(eggBox.Text)
    end
    eggBox.Text = tostring(state.eggId)
end)

connect(amountBox.FocusLost, function()
    if amountBox.Text ~= "" then
        state.amount = parseArg(amountBox.Text)
    end
    amountBox.Text = tostring(state.amount)
end)

connect(delayBox.FocusLost, function()
    local n = tonumber(delayBox.Text)
    if n and n >= 0.05 then
        state.delay = n
    end
    delayBox.Text = tostring(state.delay)
end)

connect(maxBox.FocusLost, function()
    local n = tonumber(maxBox.Text)
    if n and n >= 0 then
        state.maxHatches = math.floor(n)
    end
    maxBox.Text = tostring(state.maxHatches)
end)

----------------------------------------------------------------------------------------------
-- Skip animation: hide the hatch animation GUI while auto-hatching
----------------------------------------------------------------------------------------------

local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local skip = { active = false, tracked = {}, conns = {}, seen = {} }

local function guiProp(inst)
    return inst:IsA("ScreenGui") and "Enabled" or "Visible"
end

local function isAnimationGui(inst)
    if not (inst:IsA("ScreenGui") or inst:IsA("Frame") or inst:IsA("CanvasGroup") or inst:IsA("ViewportFrame")) then
        return false
    end
    if inst == gui or inst:IsDescendantOf(gui) then
        return false
    end
    local name = inst.Name:lower()
    for _, pattern in ipairs(Config.AnimationGuiPatterns) do
        if name:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

-- Prints each message once, so the console isn't flooded on every hatch.
local function logOnce(key, message)
    if not skip.seen[key] then
        skip.seen[key] = true
        print("[AutoHatch] " .. message)
    end
end

local function hide(inst)
    local prop = guiProp(inst)
    if inst[prop] then
        inst[prop] = false
        logOnce("hid:" .. inst:GetFullName(), "Hid animation GUI: " .. inst:GetFullName())
    end
end

local function untrack(inst)
    local entry = skip.tracked[inst]
    if entry then
        for _, c in ipairs(entry) do
            c:Disconnect()
        end
        skip.tracked[inst] = nil
    end
end

-- Keeps a matching GUI hidden: every time the game turns it on, switch it straight back off.
local function track(inst, hideNow)
    if skip.tracked[inst] then
        return
    end
    local prop = guiProp(inst)
    local entry = {}
    skip.tracked[inst] = entry
    entry[1] = inst:GetPropertyChangedSignal(prop):Connect(function()
        if inst[prop] then
            hide(inst)
        end
    end)
    entry[2] = inst.AncestryChanged:Connect(function()
        if not inst:IsDescendantOf(PlayerGui) then
            untrack(inst)
        end
    end)
    if hideNow then
        hide(inst)
    end
end

local function beginSkip()
    if skip.active then
        return
    end
    skip.active = true

    -- GUIs that already exist: only react when the game turns them on (don't touch ones already showing).
    for _, inst in ipairs(PlayerGui:GetDescendants()) do
        if isAnimationGui(inst) then
            track(inst, false)
        elseif inst.Parent == PlayerGui and inst:IsA("ScreenGui") and inst ~= gui then
            -- Diagnostics: tell the user which other ScreenGuis light up, in case the animation isn't matched.
            table.insert(skip.conns, inst:GetPropertyChangedSignal("Enabled"):Connect(function()
                if inst.Enabled then
                    logOnce("on:" .. inst.Name, "ScreenGui turned on: " .. inst:GetFullName() .. " (not hidden – add part of its name to Config.AnimationGuiPatterns if it is the hatch animation)")
                end
            end))
        end
    end

    -- GUIs created later (the game cloning the animation into PlayerGui): hide on arrival.
    table.insert(skip.conns, PlayerGui.DescendantAdded:Connect(function(inst)
        if isAnimationGui(inst) then
            track(inst, true)
        elseif inst.Parent == PlayerGui and inst:IsA("ScreenGui") and inst ~= gui then
            logOnce("new:" .. inst.Name, "New ScreenGui: " .. inst:GetFullName() .. " (not hidden – add part of its name to Config.AnimationGuiPatterns if it is the hatch animation)")
        end
    end))
end

local function endSkip()
    skip.active = false
    for _, c in ipairs(skip.conns) do
        c:Disconnect()
    end
    table.clear(skip.conns)
    for inst in pairs(skip.tracked) do
        untrack(inst)
    end
end

local function refreshSkipBtn()
    skipBtn.Text = "Skip Animation: " .. (state.skip and "ON" or "OFF")
    skipBtn.BackgroundColor3 = state.skip and COLORS.green or COLORS.grey
end

connect(skipBtn.MouseButton1Click, function()
    state.skip = not state.skip
    refreshSkipBtn()
    if state.running then
        if state.skip then
            beginSkip()
        else
            endSkip()
        end
    end
end)

----------------------------------------------------------------------------------------------
-- Hatch loop
----------------------------------------------------------------------------------------------

local function stopHatching(message, color)
    state.running = false
    state.runId += 1
    endSkip()
    toggleBtn.Text = "Start"
    toggleBtn.BackgroundColor3 = COLORS.green
    setStatus(message or ("Stopped – hatched " .. state.count), color)
end

local function fireOnce(remote)
    if remote:IsA("RemoteFunction") then
        return remote:InvokeServer(state.eggId, state.amount)
    end
    remote:FireServer(state.eggId, state.amount)
    return nil
end

local function startHatching()
    -- Commit whatever is still being typed in the boxes.
    for _, box in ipairs({ eggBox, amountBox, delayBox, maxBox }) do
        if box:IsFocused() then
            box:ReleaseFocus()
        end
    end

    refreshRemoteLabel()
    if not findRemote() then
        setStatus(remoteName .. " not found in ReplicatedStorage", COLORS.red)
        return
    end

    state.running = true
    state.runId += 1
    state.count = 0
    local myRun = state.runId
    toggleBtn.Text = "Stop"
    toggleBtn.BackgroundColor3 = COLORS.red
    if state.skip then
        beginSkip()
    end

    task.spawn(function()
        while state.alive and state.running and state.runId == myRun do
            local remote = findRemote()
            if not remote then
                stopHatching(remoteName .. " disappeared", COLORS.red)
                return
            end

            local ok, reply = pcall(fireOnce, remote)
            if state.runId ~= myRun then
                return
            end
            if not ok then
                warn("[AutoHatch] " .. tostring(reply))
                stopHatching("Error – see F9 console", COLORS.red)
                return
            end

            state.count += 1
            setStatus(("Hatched: %d  (reply: %s)"):format(state.count, tostring(reply)), COLORS.green)

            if state.maxHatches > 0 and state.count >= state.maxHatches then
                stopHatching("Done – hatched " .. state.count)
                return
            end
            task.wait(state.delay)
        end
    end)
end

connect(toggleBtn.MouseButton1Click, function()
    if state.running then
        stopHatching()
    else
        startHatching()
    end
end)

----------------------------------------------------------------------------------------------
-- Replica data dump (uses the ReplicaController you pasted, to help find egg IDs / currency)
----------------------------------------------------------------------------------------------

local function dumpTable(tbl, indent, depth, seen)
    if depth > 3 then
        print(indent .. "…")
        return
    end
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            if seen[v] then
                print(indent .. tostring(k) .. " = <already shown>")
            else
                seen[v] = true
                print(indent .. tostring(k) .. " = {")
                dumpTable(v, indent .. "  ", depth + 1, seen)
                print(indent .. "}")
            end
        else
            print(indent .. tostring(k) .. " = " .. tostring(v))
        end
    end
end

connect(dumpBtn.MouseButton1Click, function()
    local module = ReplicatedStorage:FindFirstChild("ReplicaController", true)
    if not (module and module:IsA("ModuleScript")) then
        setStatus("ReplicaController module not found", COLORS.red)
        return
    end
    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" or type(controller._replicas) ~= "table" then
        setStatus("Could not read ReplicaController", COLORS.red)
        return
    end

    local shown = 0
    for id, replica in pairs(controller._replicas) do
        shown += 1
        print(("[AutoHatch] Replica %s – class %s"):format(tostring(id), tostring(replica.Class)))
        if type(replica.Data) == "table" then
            dumpTable(replica.Data, "  ", 1, {})
        end
    end
    setStatus(("Printed %d replicas to console"):format(shown))
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
    endSkip()
    for _, c in ipairs(connections) do
        c:Disconnect()
    end
    table.clear(connections)
    gui:Destroy()
    if env.AutoHatchDestroy == destroy then
        env.AutoHatchDestroy = nil
    end
end
env.AutoHatchDestroy = destroy
connect(closeBtn.MouseButton1Click, destroy)

refreshRemoteLabel()
refreshSkipBtn()
