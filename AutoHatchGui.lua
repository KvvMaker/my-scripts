--[[
    Auto Hatch GUI
    Hatches eggs on repeat for the game whose HatchController lives at
    Players.<you>.PlayerScripts.Client.Modules.Hatch.HatchController

    HOW IT WORKS
      Native mode (used whenever EggsController's events are found - the normal case): the game hatches with
      HatchEggs(eggName, count) and the server answers on HatchAnimation (Result / Reject / Busy). The panel sends
      exactly that call, with the egg you pick (or the nearest one - it walks to it) and the most the game lets you open
      (min(MaxOpen, floor(balance / price)), the game's own maths), then waits for the server's answer: Busy -> waits the
      time it gives, Reject x3 or "not enough currency" -> stops. No learning needed.

      Fallback (only if the game's events can't be found): the GUI learns the call by watching you:
        1. Press "Learn egg remote", then open ONE egg by hand (the way you normally do, same egg, same amount).
        2. When the hatch showcase starts, the GUI picks the remote call that came right before it and stores it.
           (You can also pick one yourself from the Remotes tab.)
        3. Turn on "Auto hatch" - it replays that exact call, waits for the hatch to land, and repeats.

    STOP RULES (defaults only - the controls were removed from the Auto Hatch tab; "stop at rarity" and "max hatches"
    are off, the no-response rule is on)
      * Max hatches            stops after N hatch calls (0 = no limit)
      * Stop at rarity         stops as soon as a pet at or above that rarity is hatched (needs the HatchEggs hook)
      * No response            stops after 3 calls in a row that produce no hatch (out of currency, inventory
                               full, or the call carries something that can't be replayed)

    HATCH MAX
      * Hatch the max amount  always on. Finds the egg amount inside the learned call (the argument equal to the number of
                              pets that hatch produced), raises it to EggsConfig.MAX_OPEN and sends that. If the server doesn't answer (can't afford it, not unlocked) it asks for one fewer
                              next time, and goes back to the max every 10 hatches.

    OPTIONS
      * Wait for animation     next call goes out only after the showcase finishes (default). Off = call on a timer;
                               the game ignores a showcase that is already playing, but the server still hatches.
      * Skip animation         the showcase is not played on your screen. The server result is unchanged.
      * Speed override         plays the showcase at the speed you pick instead of the game's own.

    FARM TAB (breakables, from BreakablesController)
      * Auto break            sends the game's own ClickBreakable call for the best target, at most as fast as the
                              game's CLICK_DAMAGE_MIN_INTERVAL. Targets are filtered the way the game's canTarget() does:
                              area owned, zone breakables only while you are inside that zone, other fields only within
                              CLICK_TARGET_MAX_DISTANCE. Priority: nearest / lowest HP / highest HP / bosses first.
      * Walk to nearest       Humanoid:MoveTo toward the nearest breakable outside click range (non-zone fields only).
      * Collect drops         sends PickupBreakableDrop for the drops of every destroyed breakable (same call the game
                              makes for breakables it has no record of; TowerCoins are left alone).
      * Pauses while a hatch showcase is playing (the game blocks clicks then too) - can be turned off.
      * Auto open chests      two methods. "Prompt" (default) walks to the chest and triggers its ProximityPrompt
                              ("<name> Chest - Open [E]") with fireproximityprompt, so the game's own handler sends
                              OpenChest with the arguments the server expects. "Remote" sends the game's
                              OpenChest(pendingId, position) call itself, with the position read from the chest model
                              (retried up to 3 times; the position is learned from chests you open by hand).

    COLLECT TAB (gems, from CollectiblesController)
      * Auto collect gems     works out which gems are available to you with the game's own checks (area owned, not
                              already found, tier unlocked), moves to the nearest one (walk or teleport) and sends the
                              game's CollectCollectible(id) call once you are within PICKUP_RADIUS of it.
      * The gem positions come from the CollectiblesConfig entries; the field name isn't visible from the controller, so
        the usual names are tried and "Dump a collectible entry" prints what is really there if none match.

    TAP TAB (from TapsController)
      * Auto tap              calls the game's TapsController:RequestTap at 1-20 taps per second (20/s is the game's own
                              manual limit). It does everything one tap does - reward, combo, crit roll - and the game
                              sends the queued taps to the server itself. Minimal effects skips sound/particles/ripple.
      * Game's own Auto Tap   switches the game's built-in auto tap on or off (needs the Auto Tap upgrade).

    MISC TAB
      * Anti AFK              on by default. When Roblox reports you idle (Player.Idled, shortly before the 20-minute
                              kick) it fakes input two ways: VirtualUser (resets Roblox's own timer) and a 1px mouse
                              nudge through VirtualInputManager (arrives as real input, so it also resets anything the
                              game watches itself). The pulse repeats that every minute. Game scripts connected to
                              Player.Idled are switched off while the panel runs (needs getconnections) and switched
                              back on when it unloads. "Test now" sends activity once and shows what worked.
      * Auto claim event egg  checks the same condition the game's Claim button does (EventEgg.ProgressSeconds reached
                              EventEggConfig.GetClaimDurationSeconds()) once a second and sends ClaimEventEgg when it is
                              met. If the server keeps leaving it claimable, it pauses 30s after 4 tries.

    NOTES
      * RightShift toggles the window, "-" collapses it, "x" unloads it (re-executing also replaces the old copy).
      * Needs an executor with hookmetamethod + getnamecallmethod (same as AutoQuestClaim.lua).
      * It replays what the game sent. If the call includes a one-time token or timestamp, replays will fail and the
        "no response" rule stops the loop. The server's own cooldowns and costs still apply.
      * The HatchEggs hook only sees calls the game makes through HatchController.HatchEggs; if the game kept its own
        copy of that function the stats / stop-at-rarity / skip / speed options won't fire (the Auto tab shows
        whether the hook has been seen). Hatching itself still works.
]]

local env = (getgenv and getgenv()) or _G
if env.AutoHatchGuiUnload then
    pcall(env.AutoHatchGuiUnload)
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer

-- require()-ing a game ModuleScript can leave the thread at a lower identity; remember ours and put it back.
local getIdentity = getthreadidentity or getidentity or get_thread_identity
local setIdentity = setthreadidentity or setidentity or set_thread_identity
local startIdentity = (getIdentity and getIdentity()) or 8 -- typical executor identity when it can't be read
local function restoreIdentity()
    if setIdentity and startIdentity then
        pcall(setIdentity, startIdentity)
    end
end

-- Some game config functions call require() lazily; from the executor's elevated identity that throws "Cannot require a
-- non-RobloxScript module from a RobloxScript". Run those at a normal LocalScript identity, then put ours back.
-- Returns pcall's results (ok, ...); the caller decides what to do with an error.
local GAME_IDENTITY = 2
local function asGame(fn, ...)
    if setIdentity then
        pcall(setIdentity, GAME_IDENTITY)
    end
    local results = table.pack(pcall(fn, ...))
    restoreIdentity()
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
    warn("[AutoHatch] require failed for " .. module:GetFullName() .. ": " .. tostring(result))
    return nil
end

local playerScripts = player:WaitForChild("PlayerScripts")
local hatchFolder = findPath(playerScripts, "Client", "Modules", "Hatch")
local HatchController = tryRequire(hatchFolder and hatchFolder:FindFirstChild("HatchController"))
if type(HatchController) ~= "table" then
    warn("[AutoHatch] HatchController not found at PlayerScripts.Client.Modules.Hatch.HatchController")
    return
end
local Rarities = tryRequire(hatchFolder:FindFirstChild("Modules") and hatchFolder.Modules:FindFirstChild("Rarities")) or {}

local function rarityRank(rarity)
    return table.find(Rarities, rarity) or 0
end

-- Breakables (all optional: the Farm tab just reports what is missing)
local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
local configsFolder = sharedFolder and sharedFolder:FindFirstChild("Configs")
local sharedModules = sharedFolder and sharedFolder:FindFirstChild("Modules")
local sharedUtils = sharedFolder and sharedFolder:FindFirstChild("Utils")
local packagesFolder = ReplicatedStorage:FindFirstChild("Packages")
local controllersFolder = findPath(playerScripts, "Client", "Controllers")

local BreakablesController = tryRequire(controllersFolder and controllersFolder:FindFirstChild("BreakablesController"))
local BreakablesConfig = tryRequire(configsFolder and configsFolder:FindFirstChild("BreakablesConfig"))
local BreakableZoneUtil = tryRequire(sharedModules and sharedModules:FindFirstChild("BreakableZoneUtil"))
local BreakableAreaUtils = tryRequire(sharedUtils and sharedUtils:FindFirstChild("BreakableAreaUtils"))
local dataservice = tryRequire(packagesFolder and packagesFolder:FindFirstChild("dataservice"))
local dataClient = type(dataservice) == "table" and dataservice.client or nil

-- Chests
local breakableModules = findPath(playerScripts, "Client", "Modules", "Breakables")
local ChestLootController = tryRequire(controllersFolder and controllersFolder:FindFirstChild("ChestLootController"))
local ChestConfig = tryRequire(configsFolder and configsFolder:FindFirstChild("ChestConfig"))
local LocalFxFolder = tryRequire(breakableModules and breakableModules:FindFirstChild("LocalFxFolder"))

-- Collectibles
local CollectiblesController = tryRequire(controllersFolder and controllersFolder:FindFirstChild("CollectiblesController"))
local CollectiblesConfig = tryRequire(configsFolder and configsFolder:FindFirstChild("CollectiblesConfig"))
local AreasConfig = tryRequire(configsFolder and configsFolder:FindFirstChild("AreasConfig"))

-- Taps
local TapsController = tryRequire(controllersFolder and controllersFolder:FindFirstChild("TapsController"))

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do
        copy[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return copy
end

local function describe(value, depth)
    depth = depth or 0
    local kind = typeof(value)
    if kind == "string" then
        return string.format("%q", string.sub(value, 1, 24))
    elseif kind == "Instance" then
        return "<" .. value.Name .. ">"
    elseif kind == "table" then
        if depth >= 1 then
            return "{...}"
        end
        local parts, count = {}, 0
        for k, v in pairs(value) do
            count += 1
            if count > 4 then
                table.insert(parts, "...")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. describe(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(value)
end

local function describeArgs(args)
    local parts = {}
    for i = 1, args.n or #args do
        table.insert(parts, describe(args[i]))
    end
    local text = table.concat(parts, ", ")
    if #text > 70 then
        text = string.sub(text, 1, 67) .. "..."
    end
    return text
end

local function describeCall(call)
    return ("%s (%s) %s"):format(call.remote.Name, call.method == "InvokeServer" and "Invoke" or "Fire", describeArgs(call.args))
end

--------------------------------------------------------------------------------
-- Remote recorder (one __namecall hook per executor session, handler is swapped on re-execute)
--------------------------------------------------------------------------------

local RING_SIZE = 60
local ring = {}
local ringSerial = 0 -- increases with every recorded call, so watchers can tell which entries are new

local function record(remote, method, args)
    if typeof(remote) ~= "Instance" then
        return
    end
    local class = remote.ClassName
    if class ~= "RemoteEvent" and class ~= "RemoteFunction" and class ~= "UnreliableRemoteEvent" then
        return
    end
    -- Hook context: no method calls on Instances / strings in here (they would clobber the namecall method).
    ringSerial += 1
    table.insert(ring, { remote = remote, method = method, args = args, t = os.clock(), serial = ringSerial })
    if #ring > RING_SIZE then
        table.remove(ring, 1)
    end
end

local hookReady = false
do
    local shared = env.AutoHatchRemoteHook
    if shared then
        shared.record = record
        hookReady = true
    elseif hookmetamethod and getnamecallmethod then
        shared = { record = record }
        local old
        local wrap = newcclosure or function(f)
            return f
        end
        local ok = pcall(function()
            old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
                local method = getnamecallmethod()
                local handler = shared.record
                if handler and (method == "FireServer" or method == "InvokeServer")
                    and not (checkcaller and checkcaller()) then
                    pcall(handler, self, method, table.pack(...))
                end
                return old(self, ...)
            end))
        end)
        if ok then
            env.AutoHatchRemoteHook = shared
            hookReady = true
        end
    end
end

local EGG_WORDS = { "egg", "hatch", "open", "buy", "purchase", "crack" }

local function nameScore(name)
    local lower = string.lower(name)
    for _, word in ipairs(EGG_WORDS) do
        if string.find(lower, word, 1, true) then
            return 1
        end
    end
    return 0
end

-- Best guess for "the call that opened the egg that just started hatching".
local function pickCandidate()
    local now = os.clock()
    local frequency = {}
    for _, call in ipairs(ring) do
        if now - call.t <= 6 then
            frequency[call.remote] = (frequency[call.remote] or 0) + 1
        end
    end
    local best, bestScore
    for i = #ring, 1, -1 do
        local call = ring[i]
        if now - call.t > 3 then
            break
        end
        if (frequency[call.remote] or 0) < 8 then -- skip remotes that fire constantly (movement, pings...)
            local score = nameScore(call.remote.Name) * 1000 + i
            if not bestScore or score > bestScore then
                best, bestScore = call, score
            end
        end
    end
    return best
end

--------------------------------------------------------------------------------
-- UI library
--------------------------------------------------------------------------------

local Theme = {
    Background = Color3.fromRGB(22, 22, 28),
    Topbar = Color3.fromRGB(30, 30, 38),
    Element = Color3.fromRGB(36, 36, 46),
    ElementHover = Color3.fromRGB(48, 48, 60),
    Accent = Color3.fromRGB(70, 200, 130),
    Text = Color3.fromRGB(235, 235, 245),
    SubText = Color3.fromRGB(150, 150, 170),
    Warn = Color3.fromRGB(255, 190, 80),
    Font = Enum.Font.Gotham,
    FontBold = Enum.Font.GothamBold,
}

local function create(class, props, children)
    restoreIdentity() -- game modules/tables can leave this thread at a lower identity (can't touch gethui GUIs)
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
    restoreIdentity()
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

local WIDTH, HEIGHT = 500, 400

function Window.new(title)
    local self = setmetatable({ tabs = {}, connections = {}, activeTab = nil, destroyed = false }, Window)

    local gui = create("ScreenGui", {
        Name = "AutoHatchGui",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 2000,
    })
    -- The hatch controller disables other ScreenGuis while it plays unless this is set.
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

-- Runs fn(dt) once per frame from a thread started by this script (keeps this script's permissions).
function Window:Loop(fn)
    local alive = true
    table.insert(self.connections, { Disconnect = function() alive = false end })
    task.spawn(function()
        while alive do
            local dt = RunService.Heartbeat:Wait()
            restoreIdentity()
            local ok, err = pcall(fn, dt)
            if not ok then
                warn("[AutoHatch] loop stopped: " .. tostring(err))
                break
            end
        end
    end)
end

function Window:Notify(text, duration)
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
    self.destroyed = true -- plain flag: background loops check this instead of reading a GUI instance
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
        SetText = function(_, value)
            restoreIdentity()
            if label.Text ~= value then
                label.Text = value
            end
        end,
        SetColor = function(_, value)
            restoreIdentity()
            label.TextColor3 = value
        end,
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
        value = math.round(value * 1000) / 1000 -- strip float noise (0.30000000000000004)
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
function Tab:AddCycle(text, options, default, callback, wide)
    local index = table.find(options, default) or 1
    local row = self:_row(32)
    local valueWidth = wide and 190 or 130
    self:_label(row, text, UDim2.new(1, -(valueWidth + 70), 1, 0), UDim2.fromOffset(10, 0))

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
    local valueButton = small(tostring(options[index] or "-"), -34, valueWidth)
    local prevButton = small("<", -(34 + valueWidth + 4), 22)

    local handle = {}
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
            task.spawn(callback, options[index], index)
        end
    end

    self.window:Connect(nextButton.MouseButton1Click, function() step(1) end)
    self.window:Connect(valueButton.MouseButton1Click, function() step(1) end)
    self.window:Connect(prevButton.MouseButton1Click, function() step(-1) end)

    function handle.Get()
        return options[index], index
    end
    function handle.SetOptions(_, list, keepSelection)
        local current = options[index]
        options = list
        index = (keepSelection and table.find(list, current)) or 1
        render()
    end
    return handle
end

--------------------------------------------------------------------------------
-- State + hatch hook
--------------------------------------------------------------------------------

local RESPONSE_TIMEOUT = 4 -- seconds to wait for a hatch to show up after a call
local MAX_MISSES = 3

local state = {
    running = false,
    learning = false,
    runToken = 0,
    runCount = 0,
    misses = 0,
    captured = nil,

    delay = 0.2,
    waitAnim = false,
    skipAnim = true,
    speedOn = true,
    speed = 0.5,
    maxHatches = 0,
    stopRarity = "Off",
    stopOnNoResponse = true,

    hatchMax = true, -- raise the egg amount in the replayed call to maxEggs, stepping down when the server refuses
    maxEggs = 8, -- default is read from EggsConfig.MAX_OPEN below
    currentAmount = nil, -- what the next call asks for while hatchMax is on
    successSinceDrop = 0,
    amountCandidates = {}, -- where the egg amount could sit in the captured call
    amountIndex = 1,
    candidatesFor = nil,
    learnedCount = nil, -- how many pets the hatch we learned from produced (identifies the amount argument)

    -- native mode (the game's own HatchEggs / HatchAnimation events)
    eggChoice = "Nearest", -- "Nearest" or an egg name
    eggOptionsKey = nil,
    actionSeq = 0, -- HatchAnimation events seen
    lastAction = nil, -- "Result" | "Reject" | "Busy"
    lastDuration = nil,
    nativeNote = nil,
    nativeAmount = nil,
    nativeEgg = nil,

    hatchSeq = 0, -- HatchEggs calls seen by the hook
    activeEdges = 0, -- IsActive false -> true transitions seen
    totalPets = 0,
    counts = {},
    best = nil,
    bestRank = -1,
    lastPets = nil,
    lastEgg = nil,
    status = "Idle",
}

local window = Window.new("Auto Hatch & Farm")

local function resetStats()
    state.hatchSeq = 0
    state.totalPets = 0
    state.counts = {}
    state.best = nil
    state.bestRank = -1
    state.lastPets = nil
    state.lastEgg = nil
end

local function capture(call)
    state.captured = {
        remote = call.remote,
        method = call.method,
        args = deepCopy(call.args),
    }
end

-- "Hatch max": the egg amount is one of the call's arguments (or a field of a table argument). Candidates are whole numbers
-- 1-100; the one equal to the number of pets the learned hatch produced is listed first.
local EggsConfig = tryRequire(configsFolder and configsFolder:FindFirstChild("EggsConfig")) or {}
state.maxEggs = math.clamp(math.floor(tonumber(EggsConfig.MAX_OPEN) or 8), 1, 50)

local AMOUNT_WORDS = { "amount", "count", "quantity", "qty", "num", "eggs" }

local function findAmountCandidates(args, preferValue)
    local list = {}
    local function isCount(value)
        return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 100
    end
    for i = 1, args.n or #args do
        local value = args[i]
        if isCount(value) then
            table.insert(list, { label = ("arg #%d (= %d)"):format(i, value), path = { i }, value = value })
        elseif type(value) == "table" then
            for key, item in pairs(value) do
                if type(key) == "string" and isCount(item) then
                    local lower = string.lower(key)
                    for _, word in ipairs(AMOUNT_WORDS) do
                        if string.find(lower, word, 1, true) then
                            table.insert(list, {
                                label = ("arg #%d.%s (= %d)"):format(i, key, item),
                                path = { i, key },
                                value = item,
                            })
                            break
                        end
                    end
                end
            end
        end
    end
    if preferValue then
        table.sort(list, function(a, b)
            local aPreferred, bPreferred = a.value == preferValue, b.value == preferValue
            if aPreferred ~= bPreferred then
                return aPreferred
            end
            return a.path[1] < b.path[1]
        end)
    end
    return list
end

local function setAmount(args, candidate, amount)
    if #candidate.path == 1 then
        args[candidate.path[1]] = amount
    elseif type(args[candidate.path[1]]) == "table" then
        args[candidate.path[1]][candidate.path[2]] = amount
    end
end

local function tryLearn()
    if not state.learning then
        return
    end
    local call = pickCandidate()
    if call then
        state.learnedCount = state.lastPets and #state.lastPets or nil
        capture(call)
        state.learning = false
        -- may run on the game's thread (HatchEggs hook), which can't touch this GUI: the label loop shows it
        state.pendingNotice = "Learned: " .. describeCall(call)
    end
end

-- Called by the HatchEggs wrapper on the game's own thread.
local function onHatch(eggName, pets)
    state.hatchSeq += 1
    state.lastEgg = eggName
    local summary = {}
    if type(pets) == "table" then
        for _, pet in ipairs(pets) do
            if type(pet) == "table" then
                local rarity = tostring(pet.Rarity)
                local tier = pet.Tier ~= nil and pet.Tier ~= "None" and (tostring(pet.Tier) .. " ") or ""
                local name = tier .. tostring(pet.PetName)
                table.insert(summary, { rarity = rarity, name = name })
                state.totalPets += 1
                state.counts[rarity] = (state.counts[rarity] or 0) + 1
                local rank = rarityRank(rarity)
                if rank > state.bestRank then
                    state.bestRank = rank
                    state.best = { rarity = rarity, name = name }
                end
            end
        end
    end
    state.lastPets = summary
    tryLearn()
end

local originalHatchEggs = HatchController.HatchEggs
local function hatchWrapper(eggName, pets, speed, options)
    pcall(onHatch, eggName, pets)
    if state.skipAnim then
        return
    end
    if state.speedOn then
        speed = state.speed
    end
    return originalHatchEggs(eggName, pets, speed, options)
end
if type(originalHatchEggs) == "function" then
    HatchController.HatchEggs = hatchWrapper
end

--------------------------------------------------------------------------------
-- Replay + loop
--------------------------------------------------------------------------------

local function fireCaptured(amount)
    local call = state.captured
    if not call then
        return false, "nothing captured"
    end
    local remote = call.remote
    if not (remote and remote.Parent) then
        return false, "the captured remote no longer exists (learn it again)"
    end
    local args = deepCopy(call.args)
    if amount then
        local candidate = state.amountCandidates[state.amountIndex]
        if candidate then
            setAmount(args, candidate, amount)
        end
    end
    if call.method == "InvokeServer" then
        task.spawn(function()
            local ok, result = pcall(function()
                return remote:InvokeServer(table.unpack(args, 1, args.n))
            end)
            state.lastInvoke = ok and describe(result) or ("error: " .. tostring(result))
        end)
        return true
    end
    local ok, err = pcall(function()
        remote:FireServer(table.unpack(args, 1, args.n))
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

local autoToggle

local function stopAuto(reason)
    if not state.running then
        return
    end
    state.running = false
    state.runToken += 1
    state.status = reason
    if autoToggle then
        autoToggle:Set(false, true)
    end
    window:Notify(reason, 6)
end

local function rarityHit()
    local threshold = rarityRank(state.stopRarity)
    if state.stopRarity == "Off" or threshold == 0 or not state.lastPets then
        return nil
    end
    for _, pet in ipairs(state.lastPets) do
        if rarityRank(pet.rarity) >= threshold then
            return pet
        end
    end
    return nil
end

-- Fallback for when the game's own hatch events can't be found: replay a call learned by watching you hatch by hand.
local function startAutoLearned()
    if state.running then
        return
    end
    if not state.captured then
        if autoToggle then
            autoToggle:Set(false, true)
        end
        window:Notify("Learn the egg remote first: press Learn, then open one egg by hand", 5)
        return
    end
    state.running = true
    state.runToken += 1
    state.runCount = 0
    state.misses = 0
    state.currentAmount = state.maxEggs
    state.successSinceDrop = 0
    state.status = "Running"
    local token = state.runToken

    local function alive()
        return state.running and state.runToken == token and not window.destroyed
    end

    task.spawn(function()
        while alive() do
            if state.maxHatches > 0 and state.runCount >= state.maxHatches then
                stopAuto(("Done: %d hatches"):format(state.runCount))
                break
            end

            -- never stack a call on top of a showcase that is still playing when waiting is on
            if state.waitAnim then
                local waited = os.clock()
                while alive() and HatchController.IsActive == true and os.clock() - waited < 90 do
                    task.wait(0.05)
                end
                if not alive() then
                    break
                end
            end

            local useMax = state.hatchMax and #state.amountCandidates > 0
            local amount
            if useMax then
                state.currentAmount = state.currentAmount or state.maxEggs
                amount = state.currentAmount
            end
            local seq, edges = state.hatchSeq, state.activeEdges
            local fired, err = fireCaptured(amount)
            if not fired then
                stopAuto("Stopped: could not send the call - " .. tostring(err))
                break
            end

            -- while stepping down from the max, a refusal is expected: don't wait the full timeout for it
            local probing = useMax and amount > 1
            local deadline = os.clock() + (probing and 2.5 or RESPONSE_TIMEOUT)
            while alive() and os.clock() < deadline and state.hatchSeq == seq and state.activeEdges == edges do
                task.wait(0.03)
            end
            if not alive() then
                break
            end

            if state.hatchSeq ~= seq or state.activeEdges ~= edges then
                state.misses = 0
                state.runCount += 1
                if useMax then
                    -- after a step down, try the max again every 10 hatches in case currency or unlocks changed
                    state.successSinceDrop += 1
                    if state.currentAmount < state.maxEggs and state.successSinceDrop >= 10 then
                        state.currentAmount = state.maxEggs
                        state.successSinceDrop = 0
                    end
                end
                local hit = rarityHit()
                if hit then
                    stopAuto(("Stopped: hatched %s (%s) after %d hatches"):format(hit.name, hit.rarity, state.runCount))
                    break
                end
            elseif probing then
                -- refused at this amount (can't afford that many, or not unlocked): ask for one fewer next time
                state.currentAmount = amount - 1
                state.successSinceDrop = 0
            else
                state.misses += 1
                if state.stopOnNoResponse and state.misses >= MAX_MISSES then
                    stopAuto("Stopped: no hatch after 3 tries (out of currency, inventory full, or the call can't be replayed)")
                    break
                end
            end

            -- let the showcase finish before the delay starts counting
            if state.waitAnim then
                local waited = os.clock()
                while alive() and HatchController.IsActive == true and os.clock() - waited < 90 do
                    task.wait(0.05)
                end
            end
            local resume = os.clock() + state.delay
            while alive() and os.clock() < resume do
                task.wait(0.05)
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Native hatching (EggsController)
--   The game's own hatch call is _events.HatchEggs:FireServer(eggName, count). The server answers on _events.HatchAnimation
--   with { Action = "Result" | "Reject" | "Busy", Duration, EggName, Pets }, and the client then plays the showcase through
--   HatchController.HatchEggs (which the hook above can skip or speed up). With that known there is nothing to learn: the
--   egg and the amount are worked out the way the game works them out.
--------------------------------------------------------------------------------

restoreIdentity()

local EggsController = tryRequire(controllersFolder and controllersFolder:FindFirstChild("EggsController"))
local nativeEvents = type(EggsController) == "table" and EggsController._events or nil
local nativeReady = type(EggsConfig.Eggs) == "table" and dataClient ~= nil and type(nativeEvents) == "table"
    and nativeEvents.HatchEggs ~= nil and nativeEvents.HatchAnimation ~= nil

local EGGS_TAG = type(EggsConfig.EGGS_TAG) == "string" and EggsConfig.EGGS_TAG or "Eggs"
local OPEN_DISTANCE = tonumber(EggsConfig.MAX_OPEN_DISTANCE) or 15 -- how close to an egg you have to be to hatch it

-- Eggs standing in the world: tagged models, plus anything under Workspace.Eggs.
local function findWorldEggs()
    local found, seen = {}, {}
    local function consider(instance)
        local ok, model, name = pcall(EggsConfig.ResolveWorldEgg, instance)
        if ok and model and name and not seen[model] then
            seen[model] = true
            local okPart, part = pcall(EggsConfig.GetWorldEggPrimaryPart, model)
            if okPart and part then
                table.insert(found, { model = model, name = name, position = part.Position })
            end
        end
    end
    for _, instance in ipairs(CollectionService:GetTagged(EGGS_TAG)) do
        consider(instance)
    end
    local folder = workspace:FindFirstChild("Eggs")
    if folder then
        for _, child in ipairs(folder:GetChildren()) do
            consider(child)
        end
    end
    return found
end

local function chooseEgg(eggs, position)
    local best, bestDistance
    for _, egg in ipairs(eggs) do
        if state.eggChoice == "Nearest" or egg.name == state.eggChoice then
            local distance = (egg.position - position).Magnitude
            if not bestDistance or distance < bestDistance then
                best, bestDistance = egg, distance
            end
        end
    end
    return best, bestDistance
end

-- The game's own maths: the most it lets you open is min(MaxOpen, floor(balance / price)).
local function affordableCount(eggName)
    local maxOpen = EggsConfig.GetMaxOpen(player)
    local egg = EggsConfig.Eggs[eggName]
    local currency = egg and egg.Currency
    if type(currency) ~= "string" or currency == "" then
        currency = "Taps"
    end
    local price = EggsConfig.GetEggPrice(player, eggName)
    if price > 0 then
        local balance = math.max(0, tonumber(dataClient:get({ currency })) or 0)
        maxOpen = math.clamp(math.floor(balance / price), 0, maxOpen)
    end
    return maxOpen, currency
end

if nativeReady then
    pcall(function()
        window:Connect(nativeEvents.HatchAnimation.OnClientEvent, function(data)
            if type(data) ~= "table" then
                return
            end
            state.lastAction = data.Action
            state.lastDuration = tonumber(data.Duration)
            state.actionSeq += 1
        end)
    end)
end

local function startAutoNative()
    if state.running then
        return
    end
    state.running = true
    state.runToken += 1
    state.runCount = 0
    state.misses = 0
    state.status = "Running"
    state.nativeNote = nil
    local token = state.runToken

    local function alive()
        return state.running and state.runToken == token and not window.destroyed
    end

    task.spawn(function()
        local lastWalk = 0
        local rejects = 0
        while alive() do
            restoreIdentity()
            if state.maxHatches > 0 and state.runCount >= state.maxHatches then
                stopAuto(("Done: %d hatches"):format(state.runCount))
                break
            end

            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not root then
                task.wait(0.5)
                continue
            end

            -- find the egg to hatch, and get within the game's opening distance of it
            local okEggs, eggs = asGame(findWorldEggs)
            local target, distance
            if okEggs and type(eggs) == "table" then
                target, distance = chooseEgg(eggs, root.Position)
            end
            if not target then
                state.nativeNote = state.eggChoice == "Nearest" and "No egg found nearby" or ("No " .. state.eggChoice .. " egg found")
                task.wait(1)
                continue
            end
            state.nativeEgg = target.name
            if distance > OPEN_DISTANCE - 1.5 then
                state.nativeNote = ("Walking to the %s egg (%d studs away)"):format(target.name, math.floor(distance))
                local now = os.clock()
                if now - lastWalk > 0.5 then
                    lastWalk = now
                    local humanoid = character:FindFirstChildOfClass("Humanoid")
                    if humanoid then
                        humanoid:MoveTo(target.position)
                    end
                end
                task.wait(0.15)
                continue
            end
            state.nativeNote = nil

            -- never stack a request on top of a showcase that is still playing when waiting is on
            if state.waitAnim then
                local waited = os.clock()
                while alive() and HatchController.IsActive == true and os.clock() - waited < 90 do
                    task.wait(0.05)
                end
                if not alive() then
                    break
                end
            end

            local okCount, count, currency = asGame(affordableCount, target.name)
            if not okCount then
                state.nativeNote = "Couldn't work out how many eggs you can afford: " .. tostring(count)
                task.wait(1)
                continue
            end
            if count < 1 then
                stopAuto(("Stopped: not enough %s for another %s egg"):format(currency, target.name))
                break
            end

            state.nativeAmount = count
            local seq = state.actionSeq
            pcall(function()
                nativeEvents.HatchEggs:FireServer(target.name, count)
            end)

            -- the server's answer: Result (hatching), Busy (try again after Duration) or Reject
            local deadline = os.clock() + RESPONSE_TIMEOUT
            while alive() and os.clock() < deadline and state.actionSeq == seq do
                task.wait(0.03)
            end
            if not alive() then
                break
            end

            if state.actionSeq == seq then
                state.misses += 1
                if state.stopOnNoResponse and state.misses >= MAX_MISSES then
                    stopAuto("Stopped: the server isn't answering hatch requests")
                    break
                end
            elseif state.lastAction == "Result" then
                state.misses = 0
                rejects = 0
                state.runCount += 1
                local hit = rarityHit()
                if hit then
                    stopAuto(("Stopped: hatched %s (%s) after %d hatches"):format(hit.name, hit.rarity, state.runCount))
                    break
                end
            elseif state.lastAction == "Busy" then
                -- still cooling down from the last hatch: wait as long as the server says
                local pause = math.clamp(state.lastDuration or 0.3, 0.05, 5)
                local resume = os.clock() + pause
                while alive() and os.clock() < resume do
                    task.wait(0.05)
                end
                continue
            elseif state.lastAction == "Reject" then
                rejects += 1
                if rejects >= 3 then
                    stopAuto("Stopped: the server rejected 3 hatches in a row (too far from the egg, area locked, or not enough currency)")
                    break
                end
                task.wait(0.5)
                continue
            end

            -- let the showcase finish before the delay starts counting
            if state.waitAnim then
                local waited = os.clock()
                while alive() and HatchController.IsActive == true and os.clock() - waited < 90 do
                    task.wait(0.05)
                end
            end
            local resume = os.clock() + state.delay
            while alive() and os.clock() < resume do
                task.wait(0.05)
            end
        end
    end)
end

local function startAuto()
    if nativeReady then
        startAutoNative()
    else
        startAutoLearned()
    end
end

--------------------------------------------------------------------------------
-- Auto Hatch tab
--------------------------------------------------------------------------------

local autoTab = window:AddTab("Auto Hatch")
local statusLabel = autoTab:AddLabel("Idle")

-- The learned call is shown in the status text now, so there is no separate label for it.
local remoteLabel = { SetText = function() end, SetColor = function() end }
local eggCycle = { SetOptions = function() end, Get = function() return "Nearest" end }
if nativeReady then
    -- the game's own hatch call is known, so there is nothing to learn: just pick which egg
    eggCycle = autoTab:AddCycle("Egg", { "Nearest" }, "Nearest", function(value)
        state.eggChoice = value
    end, true)
else
    autoTab:AddButton("Learn: then open one egg by hand", function()
        if not hookReady then
            window:Notify("This executor has no hookmetamethod, so the egg remote can't be learned", 6)
            return
        end
        state.learning = not state.learning
        window:Notify(state.learning and "Learning: open one egg now" or "Learning cancelled", 5)
    end)
end
autoToggle = autoTab:AddToggle("Auto hatch", false, function(value)
    if value then
        startAuto()
    else
        stopAuto("Stopped")
    end
end)
autoTab:AddSlider("Delay between hatches (s)", 0.1, 5, state.delay, 0.1, function(value)
    state.delay = value
end)
autoTab:AddToggle("Wait for the animation to finish", state.waitAnim, function(value)
    state.waitAnim = value
end)
autoTab:AddToggle("Skip animation (don't show the showcase)", state.skipAnim, function(value)
    state.skipAnim = value
end)
autoTab:AddToggle("Override showcase speed", state.speedOn, function(value)
    state.speedOn = value
end)
autoTab:AddSlider("Showcase speed", 0.5, 10, state.speed, 0.5, function(value)
    state.speed = value
end)

-- The other controls (hatch amount, stop rules) are no longer in the UI but their defaults still apply: hatch max is on
-- (the amount is found automatically), stop-at-rarity and the hatch limit are off, and 3 hatches in a row that produce
-- nothing stop the loop.
local amountCycle = { SetOptions = function() end }

--------------------------------------------------------------------------------
-- Remotes tab
--------------------------------------------------------------------------------

local remotesTab = window:AddTab("Remotes")
remotesTab:AddLabel("The game's own outgoing remote calls, newest first. If the automatic learn picked the wrong one, open an egg by hand, press Refresh, choose the call that opened it and press Use.")

local recentCalls = {}
local recentCycle = remotesTab:AddCycle("Recent call", { "(press Refresh)" }, "(press Refresh)", nil, true)

local function refreshRecent()
    local now = os.clock()
    local labels, calls, seen = {}, {}, {}
    for i = #ring, 1, -1 do
        local call = ring[i]
        if call.remote.Parent then
            local text = describeCall(call)
            if not seen[text] then
                seen[text] = true
                table.insert(labels, ("%ds  %s"):format(math.floor(now - call.t), text))
                table.insert(calls, call)
            end
        end
        if #labels >= 25 then
            break
        end
    end
    if #labels == 0 then
        labels = { "(no calls recorded yet)" }
    end
    recentCalls = calls
    recentCycle:SetOptions(labels)
end

remotesTab:AddButton("Refresh list", function()
    refreshRecent()
    window:Notify(("%d recent calls"):format(#recentCalls))
end)
remotesTab:AddButton("Use the selected call", function()
    local _, index = recentCycle.Get()
    local call = recentCalls[index]
    if not call then
        window:Notify("Nothing selected - press Refresh first")
        return
    end
    capture(call)
    window:Notify("Using: " .. describeCall(call), 5)
end)
remotesTab:AddButton("Clear the captured call", function()
    state.captured = nil
    window:Notify("Cleared")
end)

--------------------------------------------------------------------------------
-- Stats tab
--------------------------------------------------------------------------------

local statsTab = window:AddTab("Stats")
local statsLabel = statsTab:AddLabel("No hatches seen yet")
statsTab:AddButton("Reset stats", function()
    resetStats()
    window:Notify("Stats reset")
end)

--------------------------------------------------------------------------------
-- Farm tab (breakables)
--------------------------------------------------------------------------------

restoreIdentity()

local farm = {
    alive = true,
    autoBreak = false,
    walk = false,
    collect = false,
    pauseWhileHatching = true,
    priority = "Nearest",
    cps = 8,
    clicks = 0,
    destroyed = 0,
    dropsSent = 0,
    loaded = 0,
    zone = nil,
    target = nil,
    lastError = nil,
}

local farmEvents = BreakablesController and BreakablesController._events
local farmReady = type(BreakablesConfig) == "table" and type(farmEvents) == "table" and farmEvents.ClickBreakable ~= nil
local minClickInterval = farmReady and tonumber(BreakablesConfig.CLICK_DAMAGE_MIN_INTERVAL) or 0.1
local clickRange = farmReady and tonumber(BreakablesConfig.CLICK_TARGET_MAX_DISTANCE) or 30
farm.cps = math.clamp(math.floor(1 / math.max(minClickInterval, 0.02)), 1, 10)

local function getRootPart()
    local character = player.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function currentZone()
    if BreakablesController and type(BreakablesController.GetZoneOfLocalPlayer) == "function" then
        local ok, zone = pcall(BreakablesController.GetZoneOfLocalPlayer, BreakablesController)
        if ok then
            return zone
        end
    end
    return nil
end

local function fieldIsZone(field)
    if not BreakableZoneUtil then
        return false
    end
    local ok, result = pcall(BreakableZoneUtil.IsZone, field)
    return ok and result == true
end

-- Same ownership gate the game applies before it lets you click a breakable.
local function areaAccessible(field)
    if not (BreakableZoneUtil and BreakableAreaUtils and dataClient) then
        return true
    end
    local ok, result = pcall(function()
        local zone = BreakableZoneUtil.GetZone(field)
        local area = zone and zone.AreaName
        if not area then
            return true
        end
        return BreakableAreaUtils.isAreaOwned(dataClient:get({ "OwnedAreas" }), area)
    end)
    if not ok then
        return true
    end
    return result ~= false
end

local function modelDistance(container, position)
    if type(BreakablesConfig.GetDistanceToModel) == "function" then
        local ok, distance = pcall(BreakablesConfig.GetDistanceToModel, container, position)
        if ok and type(distance) == "number" then
            return distance
        end
    end
    return (container:GetPivot().Position - position).Magnitude
end

local PRIORITIES = { "Nearest", "Lowest HP", "Highest HP", "Bosses first" }

local function priorityKey(priority, distance, hp, boss)
    if priority == "Lowest HP" then
        return hp
    elseif priority == "Highest HP" then
        return -hp
    elseif priority == "Bosses first" then
        return (boss and 0 or 1e6) + distance
    end
    return distance
end

-- Mirrors the game's canTarget(): zone breakables are clickable from anywhere inside that zone, everything else
-- has to be within CLICK_TARGET_MAX_DISTANCE. Returns the best clickable target and some info for the status label.
local function scan()
    local root = getRootPart()
    if not root then
        return nil, { loaded = 0 }
    end
    local rootPos = root.Position
    local zone = currentZone()
    local attrId = BreakablesConfig.ATTR_ID
    local attrHp = BreakablesConfig.ATTR_HEALTH
    local attrMax = BreakablesConfig.ATTR_MAX_HEALTH
    local attrField = BreakablesConfig.ATTR_FIELD

    local access, zoneFlag = {}, {}
    local best, bestKey
    local walkPosition, walkDistance
    local loaded = 0

    for _, container in ipairs(CollectionService:GetTagged(BreakablesConfig.BREAKABLE_TAG)) do
        loaded += 1
        local id = container:GetAttribute(attrId)
        local field = container:GetAttribute(attrField)
        local hp = tonumber(container:GetAttribute(attrHp)) or 0
        if type(id) == "string" and type(field) == "string" and hp > 0 and container.Parent then
            if access[field] == nil then
                access[field] = areaAccessible(field)
                zoneFlag[field] = fieldIsZone(field)
            end
            if access[field] then
                local distance = modelDistance(container, rootPos)
                local isZone = zoneFlag[field]
                local clickable
                if isZone then
                    clickable = zone == field
                else
                    clickable = distance <= clickRange
                end
                if clickable then
                    local boss = container:GetAttribute("IsBoss") == true
                    local key = priorityKey(farm.priority, distance, hp, boss)
                    if not bestKey or key < bestKey then
                        bestKey = key
                        best = {
                            id = id,
                            name = container.Name,
                            hp = hp,
                            maxHp = tonumber(container:GetAttribute(attrMax)) or hp,
                        }
                    end
                elseif not isZone and (not walkDistance or distance < walkDistance) then
                    walkDistance = distance
                    walkPosition = container:GetPivot().Position
                end
            end
        end
    end

    return best, { loaded = loaded, zone = zone, walkPosition = walkPosition }
end

local farmTab = window:AddTab("Farm")
local farmStatus = farmTab:AddLabel("")

local function updateFarmLabel()
    if not farmReady then
        return
    end
    local lines = {
        farm.autoBreak and "Auto break: on" or "Auto break: off",
        ("Breakables loaded: %d   Zone: %s"):format(farm.loaded, tostring(farm.zone or "-")),
        ("Target: %s"):format(farm.target or "-"),
        ("Clicks sent: %d   Destroyed: %d   Drops sent: %d"):format(farm.clicks, farm.destroyed, farm.dropsSent),
    }
    if farm.lastError then
        table.insert(lines, "Error: " .. farm.lastError)
    end
    farmStatus:SetText(table.concat(lines, "\n"))
end

if not farmReady then
    local missing = {}
    if not BreakablesController then
        table.insert(missing, "BreakablesController")
    elseif type(farmEvents) ~= "table" or not farmEvents.ClickBreakable then
        table.insert(missing, "its _events.ClickBreakable (the controller's Init hasn't run?)")
    end
    if not BreakablesConfig then
        table.insert(missing, "BreakablesConfig")
    end
    farmStatus:SetText("Farm unavailable - missing: " .. table.concat(missing, ", "))
    farmStatus:SetColor(Theme.Warn)
else
    farmTab:AddSection("Auto break")
    farmTab:AddToggle("Auto break (click breakables)", false, function(value)
        farm.autoBreak = value
        farm.lastError = nil
        if not value then
            farm.target = nil
        end
    end)
    farmTab:AddCycle("Target priority", PRIORITIES, farm.priority, function(value)
        farm.priority = value
    end)
    farmTab:AddSlider(("Clicks per second (game limit %.2fs)"):format(minClickInterval), 1, 30, farm.cps, 1, function(value)
        farm.cps = value
    end)
    farmTab:AddToggle("Pause while a hatch is playing", farm.pauseWhileHatching, function(value)
        farm.pauseWhileHatching = value
    end)

    farmTab:AddSection("Movement")
    farmTab:AddToggle("Walk to nearest breakable if none in range", false, function(value)
        farm.walk = value
    end)

    farmTab:AddSection("Drops")
    farmTab:AddToggle("Collect drops from destroyed breakables", false, function(value)
        farm.collect = value
    end)
    farmTab:AddLabel(("Zone breakables can be clicked from anywhere inside their zone. Other fields need you within %d studs - the game's own limits, applied the same way here."):format(math.floor(clickRange)))
    farmTab:AddButton("Reset counters", function()
        farm.clicks, farm.destroyed, farm.dropsSent = 0, 0, 0
        window:Notify("Counters reset")
    end)

    -- Drops: the same pickup call the game makes for breakables it no longer has a record of (TowerCoins excluded).
    if farmEvents.BreakableDestroyed and farmEvents.PickupBreakableDrop then
        pcall(function()
            window:Connect(farmEvents.BreakableDestroyed.OnClientEvent, function(_, drops)
                farm.destroyed += 1
                if not farm.collect or type(drops) ~= "table" then
                    return
                end
                local ids = {}
                for _, drop in ipairs(drops) do
                    if type(drop) == "table" and type(drop.dropId) == "string" and drop.kind ~= "TowerCoins" then
                        table.insert(ids, drop.dropId)
                    end
                end
                if #ids > 0 and pcall(function() farmEvents.PickupBreakableDrop:FireServer(ids) end) then
                    farm.dropsSent += #ids
                end
            end)
        end)
    end

    task.spawn(function()
        local lastWalk = 0
        while farm.alive and not window.destroyed do
            restoreIdentity()
            if not farm.autoBreak or (farm.pauseWhileHatching and HatchController.IsActive == true) then
                task.wait(0.1)
            else
                local ok, best, info = asGame(scan)
                if not ok then
                    local message = tostring(best)
                    if farm.lastError ~= message then
                        farm.lastError = message
                        warn("[AutoHatch] farm scan failed: " .. message)
                    end
                    task.wait(1)
                else
                    farm.lastError = nil
                    farm.loaded = info and info.loaded or 0
                    farm.zone = info and info.zone
                    if best then
                        if pcall(function() farmEvents.ClickBreakable:FireServer(best.id) end) then
                            farm.clicks += 1
                        end
                        farm.target = ("%s  %d/%d"):format(best.name, best.hp, best.maxHp)
                        task.wait(math.max(minClickInterval, 1 / farm.cps))
                    else
                        farm.target = nil
                        if farm.walk and info and info.walkPosition and os.clock() - lastWalk > 0.5
                            and os.clock() > (farm.chestWalkUntil or 0) then
                            lastWalk = os.clock()
                            local character = player.Character
                            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                            if humanoid then
                                humanoid:MoveTo(info.walkPosition)
                            end
                        end
                        task.wait(0.15)
                    end
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Chests (ChestLootController)
--   Opening a chest is _events.OpenChest:FireServer(pendingId, position). The pendingId arrives as the third
--   argument of BreakableDestroyed ({ pendingId, templateName, folderName, ... }); the result comes back on
--   ChestLootAwarded ({ pendingId, rewards | reward | failed }).
--------------------------------------------------------------------------------

restoreIdentity()

local chestEvents = (ChestLootController and ChestLootController._events) or farmEvents
local chestReady = type(chestEvents) == "table" and chestEvents.OpenChest ~= nil
    and chestEvents.BreakableDestroyed ~= nil and chestEvents.ChestLootAwarded ~= nil

local CHEST_ID_ATTRS = { "PendingId", "pendingId", "ChestId", "ChestID", "Id", "ID" }
local CHEST_MAX_AGE = 90
local CHEST_MAX_ATTEMPTS = 3
local CHEST_GUESS_RADIUS = 14

-- The range the server accepts isn't visible from the controller, so look for a distance-like number in ChestConfig.
local function detectChestRange()
    if type(ChestConfig) ~= "table" then
        return 15, nil
    end
    local bestKey, bestValue, bestScore
    for key, value in pairs(ChestConfig) do
        if type(key) == "string" and type(value) == "number" and value > 0 then
            local lower = string.lower(key)
            local score = 0
            if string.find(lower, "dist", 1, true) or string.find(lower, "range", 1, true) or string.find(lower, "radius", 1, true) then
                score = 1
                if string.find(lower, "open", 1, true) then
                    score += 2
                end
                if string.find(lower, "interact", 1, true) or string.find(lower, "click", 1, true) or string.find(lower, "prompt", 1, true) then
                    score += 2
                end
            end
            if score > 0 and (not bestScore or score > bestScore) then
                bestKey, bestValue, bestScore = key, value, score
            end
        end
    end
    if bestKey then
        return bestValue, bestKey
    end
    return 15, nil
end

local detectedRange, detectedKey = detectChestRange()

local chestState = {
    alive = true,
    auto = false,
    walk = true,
    range = detectedRange,
    pending = {}, -- pendingId -> chest
    claimed = {}, -- model -> pendingId (models matched by position only)
    recent = {}, -- pendingId -> { basePos, source, origin } for chests that already left `pending`
    sent = 0,
    looted = 0,
    failed = 0,
    announced = 0, -- chests the game told us about via BreakableDestroyed
    lastLoot = nil,
    lastReply = nil,
    log = {}, -- last few log lines, shown in the GUI so a screenshot is enough
    method = "Prompt", -- "Prompt": trigger the chest's ProximityPrompt (what pressing E does); "Remote": send OpenChest ourselves
    verbose = true, -- console logging while this is being tuned
    offset = Vector3.zero, -- learned from the game's own OpenChest calls: what it sends minus where the chest model is
    dumps = 0,
}

local chestFolderCache
local function chestFolder()
    if chestFolderCache and chestFolderCache.Parent then
        return chestFolderCache
    end
    if LocalFxFolder and type(LocalFxFolder.get) == "function" and type(ChestConfig) == "table" and ChestConfig.SPAWNED_FOLDER then
        local ok, folder = pcall(LocalFxFolder.get, ChestConfig.SPAWNED_FOLDER)
        if ok and typeof(folder) == "Instance" then
            chestFolderCache = folder
            return folder
        end
    end
    return nil
end

local function dropChest(pendingId)
    local chest = chestState.pending[pendingId]
    if chest and chest.model then
        chestState.claimed[chest.model] = nil
    end
    if chest then
        chestState.recent[pendingId] = { basePos = chest.basePos, source = chest.source, origin = chest.origin }
    end
    chestState.pending[pendingId] = nil
end

-- Where the chest actually is: a model in the spawned-chest folder tagged with the pendingId, else the model nearest to
-- the breakable it dropped from, else (after a short wait) the breakable's own position.
local function chestPosition(chest, now)
    local folder = chestFolder()
    if folder then
        local nearest, nearestDistance
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("PVInstance") then
                local matched = model.Name == chest.pendingId or string.find(model.Name, chest.pendingId, 1, true) ~= nil
                if not matched then
                    for _, attribute in ipairs(CHEST_ID_ATTRS) do
                        if model:GetAttribute(attribute) == chest.pendingId then
                            matched = true
                            break
                        end
                    end
                end
                if matched then
                    chest.model = model
                    return model:GetPivot().Position, "model-id"
                end
                local owner = chestState.claimed[model]
                if chest.origin and (owner == nil or owner == chest.pendingId) then
                    local distance = (model:GetPivot().Position - chest.origin).Magnitude
                    if distance <= CHEST_GUESS_RADIUS and (not nearestDistance or distance < nearestDistance) then
                        nearest, nearestDistance = model, distance
                    end
                end
            end
        end
        if nearest then
            chest.model = nearest
            chestState.claimed[nearest] = chest.pendingId
            return nearest:GetPivot().Position, "model-near"
        end
    end
    if chest.origin and now - chest.t > 2.5 then
        return chest.origin, "origin"
    end
    return nil
end

local chestTab = farmTab
chestTab:AddSection("Chests")
local chestStatus = chestTab:AddLabel("")

local function updateChestLabel()
    if not chestReady then
        return
    end
    local count = 0
    for _ in pairs(chestState.pending) do
        count += 1
    end
    local lines = {
        chestState.auto and "Auto chests: on" or "Auto chests: off",
        ("Announced: %d   Pending: %d   Sent: %d   Looted: %d   Failed: %d"):format(
            chestState.announced, count, chestState.sent, chestState.looted, chestState.failed),
    }
    local _, firstChest = next(chestState.pending)
    if firstChest then
        local root = getRootPart()
        local distance = root and firstChest.basePos and math.floor((firstChest.basePos - root.Position).Magnitude)
        table.insert(lines, ("Next chest: position %s, %s studs away, tries %d"):format(
            firstChest.source or "not found yet", distance and tostring(distance) or "?", firstChest.attempts))
    end
    if chestState.offset ~= Vector3.zero then
        table.insert(lines, ("Learned position offset: %.1f, %.1f, %.1f"):format(
            chestState.offset.X, chestState.offset.Y, chestState.offset.Z))
    end
    if chestState.lastReply then
        table.insert(lines, "Last server reply: " .. chestState.lastReply)
    end
    if chestState.lastLoot then
        table.insert(lines, "Last loot: " .. chestState.lastLoot)
    end
    if #chestState.log > 0 then
        table.insert(lines, "Log:")
        for _, line in ipairs(chestState.log) do
            table.insert(lines, "  " .. line)
        end
    end
    chestStatus:SetText(table.concat(lines, "\n"))
end

if not chestReady then
    chestStatus:SetText("Chests unavailable - missing the OpenChest / ChestLootAwarded / BreakableDestroyed events")
    chestStatus:SetColor(Theme.Warn)
else
    chestTab:AddToggle("Auto open chests", false, function(value)
        chestState.auto = value
    end)
    chestTab:AddCycle("Open method", { "Prompt", "Remote" }, chestState.method, function(value)
        chestState.method = value
    end)
    chestTab:AddToggle("Walk to a chest that is out of range", chestState.walk, function(value)
        chestState.walk = value
    end)
    chestTab:AddSlider("Open range (Remote method)", 1, 100, math.clamp(math.floor(chestState.range), 1, 100), 1, function(value)
        chestState.range = value
    end)
    chestTab:AddLabel(detectedKey
        and ("Default range read from ChestConfig." .. detectedKey .. ". Lower it if opens keep failing.")
        or "No distance setting found in ChestConfig, so the default is a guess. Lower it if opens keep failing.")
    chestTab:AddButton("Dump ChestConfig to the console", function()
        if type(ChestConfig) ~= "table" then
            window:Notify("ChestConfig not loaded")
            return
        end
        print("[AutoHatch] ChestConfig")
        for key, value in pairs(ChestConfig) do
            print("  ", key, typeof(value), type(value) ~= "function" and tostring(value) or "")
        end
        window:Notify("Dumped to the console (F9)")
    end)

    chestTab:AddToggle("Log chest activity to the console (F9)", chestState.verbose, function(value)
        chestState.verbose = value
    end)
    chestTab:AddButton("Forget the learned position offset", function()
        chestState.offset = Vector3.zero
        window:Notify("Offset cleared")
    end)

    local function deepDescribe(value, depth)
        depth = depth or 0
        local kind = typeof(value)
        if kind == "string" then
            return string.format("%q", value)
        elseif kind == "Instance" then
            return "<" .. value:GetFullName() .. ">"
        elseif kind == "table" then
            if depth >= 3 then
                return "{...}"
            end
            local parts, count = {}, 0
            for key, item in pairs(value) do
                count += 1
                if count > 12 then
                    table.insert(parts, "...")
                    break
                end
                table.insert(parts, tostring(key) .. "=" .. deepDescribe(item, depth + 1))
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        return tostring(value)
    end

    local function shorten(text, limit)
        if #text > limit then
            return string.sub(text, 1, limit - 3) .. "..."
        end
        return text
    end

    local function clog(...)
        local parts = table.pack(...)
        local strings = {}
        for i = 1, parts.n do
            strings[i] = tostring(parts[i])
        end
        local line = table.concat(strings, " ")
        table.insert(chestState.log, shorten(line, 110))
        if #chestState.log > 6 then
            table.remove(chestState.log, 1)
        end
        if chestState.verbose then
            print("[AutoHatch/chest]", line)
        end
    end

    -- Shows how the game's spawned-chest folder is laid out, so the matching rules can be fixed if they're wrong.
    local function dumpChestFolder(pendingId)
        local folder = chestFolder()
        if not folder then
            clog("no spawned-chest folder found (ChestConfig.SPAWNED_FOLDER / LocalFxFolder)")
            return
        end
        clog(("spawned-chest folder %s has %d children (looking for %s)"):format(
            folder:GetFullName(), #folder:GetChildren(), pendingId))
        for _, child in ipairs(folder:GetChildren()) do
            local position = child:IsA("PVInstance") and tostring(child:GetPivot().Position) or "-"
            clog("  child", child.Name, child.ClassName, position, deepDescribe(child:GetAttributes()))
        end
    end

    local function resolveChest(chest, now)
        local position, source = chestPosition(chest, now)
        if position and (chest.basePos == nil or source ~= "origin") then
            chest.basePos, chest.source = position, source
        end
        return position, source
    end

    -- Attempt 1: where the chest is plus the learned offset. Attempt 2: the breakable's position. Attempt 3: our own position.
    local function sendPosition(chest, position, source, root)
        local attempt = chest.attempts + 1
        if source == "player-fallback" then
            return position, source
        end
        if attempt == 2 then
            if chest.origin and source ~= "origin" then
                return chest.origin, "origin"
            end
            return position, source
        elseif attempt >= 3 then
            return root.Position, "player"
        end
        if chestState.offset ~= Vector3.zero then
            return position + chestState.offset, source .. "+offset"
        end
        return position, source
    end

    -- The game opened a chest itself: log exactly what it sent and learn the offset from the chest's model position.
    local function onManualOpen(call)
        local pendingId, sentPosition = call.args[1], call.args[2]
        clog("game OpenChest", describeArgs(call.args))
        if type(pendingId) ~= "string" or typeof(sentPosition) ~= "Vector3" then
            return
        end
        local known = chestState.pending[pendingId] or chestState.recent[pendingId]
        if not (known and known.basePos) then
            clog("  (that chest wasn't resolved by this panel, nothing to compare)")
            return
        end
        clog(("  chest position (%s) = %s, game sent %s"):format(tostring(known.source), tostring(known.basePos), tostring(sentPosition)))
        if known.source ~= "origin" then
            chestState.offset = sentPosition - known.basePos
            clog("  learned offset", tostring(chestState.offset))
        end
    end

    -- Register every chest the game announces.
    pcall(function()
        window:Connect(chestEvents.BreakableDestroyed.OnClientEvent, function(breakableId, _, chest)
            if type(chest) ~= "table" or type(chest.pendingId) ~= "string" then
                return
            end
            local origin
            if BreakablesConfig and type(breakableId) == "string" then
                for _, container in ipairs(CollectionService:GetTagged(BreakablesConfig.BREAKABLE_TAG)) do
                    if container:GetAttribute(BreakablesConfig.ATTR_ID) == breakableId then
                        local ok, cframe = pcall(container.GetBoundingBox, container)
                        local center = ok and typeof(cframe) == "CFrame" and cframe.Position or container:GetPivot().Position
                        origin = center + Vector3.new(0, 1.5, 0)
                        break
                    end
                end
            end
            local now = os.clock()
            chestState.announced += 1
            chestState.pending[chest.pendingId] = {
                pendingId = chest.pendingId,
                origin = origin,
                t = now,
                nextTry = now + 0.5,
                attempts = 0,
            }
            clog("chest announced", chest.pendingId, deepDescribe(chest), "breakable position", tostring(origin))
            if chestState.dumps < 3 then
                chestState.dumps += 1
                task.delay(1.2, dumpChestFolder, chest.pendingId)
            end
        end)
        window:Connect(chestEvents.ChestLootAwarded.OnClientEvent, function(data)
            if type(data) ~= "table" or type(data.pendingId) ~= "string" then
                return
            end
            local chest = chestState.pending[data.pendingId]
            clog("ChestLootAwarded", deepDescribe(data))
            if data.failed == true then
                chestState.lastReply = "failed " .. shorten(deepDescribe(data), 80)
                if chest then
                    if chest.attempts >= CHEST_MAX_ATTEMPTS then
                        dropChest(data.pendingId)
                        chestState.failed += 1
                    else
                        chest.nextTry = os.clock() + 1
                    end
                end
                return
            end
            dropChest(data.pendingId)
            chestState.looted += 1
            chestState.lastReply = "loot"
            chestState.lastLoot = shorten(describe(data.rewards or data.reward), 90)
        end)
    end)

    -- Prompt method: chests are opened with a ProximityPrompt ("Nature Chest - Open [E]"). Triggering it runs the game's own
    -- handler, which sends OpenChest with the arguments the server expects.
    local promptTried = {} -- prompt -> { count, last, blockedUntil }
    local shownPrompts = {} -- chest prompts seen through ProximityPromptService.PromptShown
    local worldPrompts = {}
    local lastWorldScan = 0

    local function isChestPromptText(prompt)
        return string.find(string.lower(prompt.ObjectText), "chest", 1, true) ~= nil
    end

    pcall(function()
        window:Connect(game:GetService("ProximityPromptService").PromptShown, function(prompt)
            if isChestPromptText(prompt) then
                shownPrompts[prompt] = true
            end
        end)
    end)

    local function promptPosition(prompt)
        local parent = prompt.Parent
        if parent and parent:IsA("Attachment") then
            return parent.WorldPosition
        elseif parent and parent:IsA("PVInstance") then
            return parent:GetPivot().Position
        end
        return nil
    end

    local function findChestPrompts(now)
        local found = {}
        local folder = chestFolder()
        if folder then
            for _, descendant in ipairs(folder:GetDescendants()) do
                if descendant:IsA("ProximityPrompt") then
                    table.insert(found, descendant)
                end
            end
        end
        for prompt in pairs(shownPrompts) do
            if prompt.Parent then
                table.insert(found, prompt)
            else
                shownPrompts[prompt] = nil
            end
        end
        -- Only sweep the whole world when a chest has been announced but no prompt turned up yet.
        if #found == 0 and next(chestState.pending) ~= nil and now - lastWorldScan > 3 then
            lastWorldScan = now
            worldPrompts = {}
            for _, descendant in ipairs(workspace:GetDescendants()) do
                if descendant:IsA("ProximityPrompt") and isChestPromptText(descendant) then
                    table.insert(worldPrompts, descendant)
                end
            end
        end
        if #found == 0 then
            for _, prompt in ipairs(worldPrompts) do
                if prompt.Parent then
                    table.insert(found, prompt)
                end
            end
        end
        return found
    end

    local function firePrompt(prompt)
        pcall(function()
            prompt.HoldDuration = 0
        end)
        if type(fireproximityprompt) == "function" then
            return pcall(fireproximityprompt, prompt)
        end
        -- no executor helper: hold and release the prompt like a key press (only works while it is in range)
        return pcall(function()
            prompt:InputHoldBegin()
            task.wait(0.05)
            prompt:InputHoldEnd()
        end)
    end

    local function promptStep(now, root)
        if not root then
            return
        end
        local best, bestDistance, bestPosition
        for _, prompt in ipairs(findChestPrompts(now)) do
            local info = promptTried[prompt]
            if prompt.Enabled and not (info and info.blockedUntil and now < info.blockedUntil) then
                local position = promptPosition(prompt)
                if position then
                    local distance = (position - root.Position).Magnitude
                    if not bestDistance or distance < bestDistance then
                        best, bestDistance, bestPosition = prompt, distance, position
                    end
                end
            end
        end
        if not best then
            return
        end
        local reach = math.max(best.MaxActivationDistance - 1, 4)
        if bestDistance <= reach then
            local info = promptTried[best]
            if not info then
                info = { count = 0, last = 0 }
                promptTried[best] = info
            end
            if now - info.last >= 1.5 then
                info.last = now
                info.count += 1
                if info.count > 4 then
                    info.blockedUntil = now + 20 -- it keeps not opening; stop hammering it
                    info.count = 0
                    clog("giving up on this prompt for 20s:", best:GetFullName())
                else
                    local ok, err = firePrompt(best)
                    chestState.sent += 1
                    clog(("triggered chest prompt '%s' (try %d, %d studs away, ok=%s)"):format(
                        best.ObjectText, info.count, math.floor(bestDistance), tostring(ok)))
                    if not ok then
                        chestState.lastReply = "prompt error: " .. shorten(tostring(err), 70)
                    end
                end
            end
        elseif chestState.walk then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if humanoid then
                humanoid:MoveTo(bestPosition)
                farm.chestWalkUntil = now + 1 -- keep the breakable walker from pulling us away
            end
        end
    end

    task.spawn(function()
        local lastSerial = ring[#ring] and ring[#ring].serial or 0
        while chestState.alive and not window.destroyed do
            restoreIdentity()
            task.wait(0.25)
            local now = os.clock()

            -- learn from chests the game opens itself
            for _, call in ipairs(ring) do
                if call.serial > lastSerial then
                    lastSerial = call.serial
                    if call.remote.Name == "OpenChest" then
                        pcall(onManualOpen, call)
                    end
                end
            end

            local root = getRootPart()
            if chestState.auto and chestState.method == "Prompt" then
                local ok, err = pcall(promptStep, now, root)
                if not ok then
                    chestState.lastReply = "prompt step error: " .. shorten(tostring(err), 70)
                end
            end
            for pendingId, chest in pairs(chestState.pending) do
                if now - chest.t > CHEST_MAX_AGE then
                    dropChest(pendingId)
                else
                    -- resolved even while auto is off, so a manual open can be compared against it
                    local position, source = resolveChest(chest, now)
                    if not position and root and now - chest.t > 3 then
                        -- neither a model nor the breakable's position could be found: let the server decide
                        position, source = root.Position, "player-fallback"
                    end
                    if chestState.auto and chestState.method == "Remote" then
                        if chest.attempts >= CHEST_MAX_ATTEMPTS then
                            if now - (chest.sentAt or now) > 4 then -- sent the last allowed try and nothing came back
                                clog("giving up on", pendingId)
                                dropChest(pendingId)
                                chestState.failed += 1
                            end
                        elseif now >= chest.nextTry and root and position then
                            -- A misdetected (tiny) range must not block opens: never use less than 8 studs, and if walking
                            -- hasn't got us there after 3s, send anyway and let the server accept or refuse.
                            local reach = math.max(chestState.range, 8)
                            local distance = (position - root.Position).Magnitude
                            chest.outOfRangeSince = distance > reach and (chest.outOfRangeSince or now) or nil
                            if distance <= reach
                                or (chestState.walk and chest.outOfRangeSince and now - chest.outOfRangeSince > 3) then
                                local sendAt, how = sendPosition(chest, position, source, root)
                                local ok = pcall(function()
                                    chestEvents.OpenChest:FireServer(chest.pendingId, sendAt)
                                end)
                                if ok then
                                    chest.attempts += 1
                                    chest.sentAt = now
                                    chest.nextTry = now + 1.5
                                    chestState.sent += 1
                                    clog(("OpenChest attempt %d for %s at %s (%s)"):format(
                                        chest.attempts, pendingId, tostring(sendAt), how))
                                end
                            elseif chestState.walk then
                                local character = player.Character
                                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                                if humanoid then
                                    humanoid:MoveTo(position)
                                    farm.chestWalkUntil = now + 1 -- keep the breakable walker from pulling us away
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Collectibles (CollectiblesController)
--   The game collects a gem by firing _events.CollectCollectible:FireServer(id) once you are within
--   CollectiblesConfig.PICKUP_RADIUS of it (re-sent at most every 4s per id). A gem exists for you when its area is
--   owned, it isn't already Found, and its tier is unlocked - the same three checks are used here.
--------------------------------------------------------------------------------

restoreIdentity()

local collectEvents = (CollectiblesController and CollectiblesController._events) or farmEvents or chestEvents
local collectReady = type(CollectiblesConfig) == "table" and type(AreasConfig) == "table" and dataClient ~= nil
    and type(collectEvents) == "table" and collectEvents.CollectCollectible ~= nil
local pickupRadius = collectReady and tonumber(CollectiblesConfig.PICKUP_RADIUS) or 10

local collect = {
    alive = true,
    auto = false,
    teleport = false,
    fire = true,
    priority = "Nearest",
    sent = 0,
    available = 0,
    foundNow = 0,
    foundStart = nil,
    noPositions = 0,
    target = nil,
    lastError = nil,
}

local COLLECT_PRIORITIES = { "Nearest", "Diamond first", "Gold first" }
local POSITION_KEYS = { "Position", "Pos", "CFrame", "CF", "Location", "WorldPosition", "BasePosition" }
local positionCache = {}

local function toVector(value)
    local kind = typeof(value)
    if kind == "Vector3" then
        return value
    elseif kind == "CFrame" then
        return value.Position
    elseif type(value) == "table" then
        local x = value.X or value.x or value[1]
        local y = value.Y or value.y or value[2]
        local z = value.Z or value.z or value[3]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return Vector3.new(x, y, z)
        end
    end
    return nil
end

-- Config entries' position field isn't visible from the controller, so look for the usual names, then any Vector3/CFrame.
local function collectiblePosition(entry)
    local cached = positionCache[entry.Id]
    if cached ~= nil then
        return cached or nil
    end
    local position
    for _, key in ipairs(POSITION_KEYS) do
        position = toVector(entry[key])
        if position then
            break
        end
    end
    if not position then
        for _, value in pairs(entry) do
            local kind = typeof(value)
            if kind == "Vector3" or kind == "CFrame" then
                position = toVector(value)
                break
            end
        end
    end
    positionCache[entry.Id] = position or false
    return position
end

local function collectKey(entry, distance)
    if collect.priority == "Diamond first" then
        return (entry.Tier == "Diamond" and 0 or 1e6) + distance
    elseif collect.priority == "Gold first" then
        return (entry.Tier == "Gold" and 0 or 1e6) + distance
    end
    return distance
end

local function pickCollectible()
    local root = getRootPart()
    local owned = dataClient:get({ "OwnedAreas" })
    local save = CollectiblesConfig.NormalizeSave(dataClient:get({ CollectiblesConfig.DATA_KEY }))
    local found = 0
    for _ in pairs(save.Found) do
        found += 1
    end

    local best, bestKey
    local available, noPositions = 0, 0
    for _, entry in pairs(CollectiblesConfig.GetAll()) do
        local id = entry.Id
        if id ~= nil and AreasConfig.IsOwned(owned, entry.Area) and not save.Found[id]
            and CollectiblesConfig.IsTierUnlocked(save, entry.Area, entry.Tier) then
            available += 1
            local position = collectiblePosition(entry)
            if not position then
                noPositions += 1
            elseif root then
                local distance = (position - root.Position).Magnitude
                local key = collectKey(entry, distance)
                if not bestKey or key < bestKey then
                    bestKey = key
                    best = { id = id, tier = entry.Tier, area = entry.Area, position = position, distance = distance }
                end
            end
        end
    end
    return best, { available = available, found = found, noPositions = noPositions }
end

local collectTab = window:AddTab("Collect")
local collectStatus = collectTab:AddLabel("")

local function updateCollectLabel()
    if not collectReady then
        return
    end
    local lines = {
        collect.auto and "Auto collect: on" or "Auto collect: off",
        ("Available now: %d   Collected this session: %d"):format(
            collect.available, math.max(0, collect.foundNow - (collect.foundStart or collect.foundNow))),
        ("Target: %s"):format(collect.target or "-"),
        ("Collect calls sent by this panel: %d"):format(collect.sent),
    }
    if collect.available > 0 and collect.noPositions == collect.available then
        table.insert(lines, "No position found on the config entries - use 'Dump a collectible entry' below and send me the output.")
    end
    if collect.lastError then
        table.insert(lines, "Error: " .. collect.lastError)
    end
    collectStatus:SetText(table.concat(lines, "\n"))
end

if not collectReady then
    local missing = {}
    if type(CollectiblesConfig) ~= "table" then
        table.insert(missing, "CollectiblesConfig")
    end
    if type(AreasConfig) ~= "table" then
        table.insert(missing, "AreasConfig")
    end
    if not dataClient then
        table.insert(missing, "dataservice")
    end
    if type(collectEvents) ~= "table" or not collectEvents.CollectCollectible then
        table.insert(missing, "the CollectCollectible event")
    end
    collectStatus:SetText("Collect unavailable - missing: " .. table.concat(missing, ", "))
    collectStatus:SetColor(Theme.Warn)
else
    collectTab:AddSection("Auto collect")
    collectTab:AddToggle("Auto collect gems", false, function(value)
        collect.auto = value
        collect.lastError = nil
        if not value then
            collect.target = nil
        end
    end)
    collectTab:AddCycle("Movement", { "Walk", "Teleport" }, "Walk", function(value)
        collect.teleport = value == "Teleport"
    end)
    collectTab:AddCycle("Order", COLLECT_PRIORITIES, collect.priority, function(value)
        collect.priority = value
    end)
    collectTab:AddToggle("Also send the collect call when in range", collect.fire, function(value)
        collect.fire = value
    end)
    collectTab:AddLabel(("Moves to the nearest gem that is available to you. The game collects it by itself once you are within %d studs; the call is also sent from here (at most every 4s per gem). Pauses while a hatch is playing if that option is on in the Farm tab."):format(math.floor(pickupRadius)))

    collectTab:AddSection("Debug")
    collectTab:AddButton("Dump a collectible entry to the console", function()
        local shown = 0
        print("[AutoHatch] CollectiblesConfig top-level values")
        for key, value in pairs(CollectiblesConfig) do
            if type(value) ~= "function" and type(value) ~= "table" then
                print("  ", key, typeof(value), tostring(value))
            end
        end
        for _, entry in pairs(CollectiblesConfig.GetAll()) do
            shown += 1
            print("[AutoHatch] entry " .. shown)
            for key, value in pairs(entry) do
                print("  ", key, typeof(value), type(value) ~= "table" and tostring(value) or "{...}")
            end
            if shown >= 3 then
                break
            end
        end
        window:Notify("Dumped to the console (F9)")
    end)

    task.spawn(function()
        local lastWalk = 0
        local lastSent = {}
        while collect.alive and not window.destroyed do
            restoreIdentity()
            if not collect.auto or (farm.pauseWhileHatching and HatchController.IsActive == true) then
                task.wait(0.2)
            else
                local ok, best, info = asGame(pickCollectible)
                if not ok then
                    local message = tostring(best)
                    if collect.lastError ~= message then
                        collect.lastError = message
                        warn("[AutoHatch] collectible scan failed: " .. message)
                    end
                    task.wait(1)
                else
                    collect.lastError = nil
                    collect.available = info.available
                    collect.foundNow = info.found
                    collect.noPositions = info.noPositions
                    collect.foundStart = collect.foundStart or info.found
                    local root = getRootPart()
                    if best and root then
                        collect.target = ("%s %s  %d studs"):format(tostring(best.tier or "?"), tostring(best.id), math.floor(best.distance))
                        local now = os.clock()
                        if best.distance <= pickupRadius then
                            if collect.fire and now - (lastSent[best.id] or 0) >= 4 then
                                lastSent[best.id] = now
                                if pcall(function() collectEvents.CollectCollectible:FireServer(best.id) end) then
                                    collect.sent += 1
                                end
                            end
                            task.wait(0.25)
                        elseif collect.teleport then
                            root.CFrame = CFrame.new(best.position + Vector3.new(0, 3, 0))
                            task.wait(0.4)
                        else
                            if now - lastWalk > 0.5 then
                                lastWalk = now
                                local character = player.Character
                                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                                if humanoid then
                                    humanoid:MoveTo(best.position)
                                end
                            end
                            task.wait(0.15)
                        end
                    else
                        collect.target = nil
                        task.wait(0.5)
                    end
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Taps (TapsController)
--   TapsController:RequestTap(opts) does everything one tap does (reward popup, combo, crit roll, and it queues the tap;
--   the queue is flushed to the server as Taps:FireServer(count, batchId) every 0.1s). The game's own Auto Tap just calls
--   it on a timer and has to be unlocked as an upgrade first.
--------------------------------------------------------------------------------

restoreIdentity()

local tapReady = type(TapsController) == "table" and type(TapsController.RequestTap) == "function"

local tap = {
    alive = true,
    auto = false,
    cps = 10,
    minimal = true,
    sent = 0,
    perTap = nil,
    lastError = nil,
}

local TAP_UNITS = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function abbreviate(value)
    local unit = 1
    while value >= 1000 and unit < #TAP_UNITS do
        value /= 1000
        unit += 1
    end
    return string.format(unit == 1 and "%.0f%s" or "%.2f%s", value, TAP_UNITS[unit])
end

local tapTab = window:AddTab("Tap")
local tapStatus = tapTab:AddLabel("")

local function updateTapLabel()
    if not tapReady then
        return
    end
    local lines = {
        tap.auto and "Fast auto tap: on" or "Fast auto tap: off",
        ("Taps sent by this panel: %d"):format(tap.sent),
        ("Per tap: %s"):format(tap.perTap and abbreviate(tap.perTap) or "-"),
        ("Game Auto Tap: %s"):format(TapsController.AutoTapEnabled == true and "on" or "off"),
    }
    if tap.lastError then
        table.insert(lines, "Error: " .. tap.lastError)
    end
    tapStatus:SetText(table.concat(lines, "\n"))
end

if not tapReady then
    tapStatus:SetText("Tap unavailable - TapsController (or its RequestTap) wasn't found")
    tapStatus:SetColor(Theme.Warn)
else
    tapTab:AddSection("Fast auto tap")
    tapTab:AddToggle("Auto tap (calls the game's RequestTap)", false, function(value)
        tap.auto = value
        tap.lastError = nil
    end)
    tapTab:AddSlider("Taps per second", 1, 20, tap.cps, 1, function(value)
        tap.cps = value
    end)
    tapTab:AddToggle("Minimal effects (no sound / particles / ripple)", tap.minimal, function(value)
        tap.minimal = value
    end)
    tapTab:AddLabel("20 per second is the fastest the game lets you tap by hand (one tap per 0.05s). The server still decides what counts.")

    tapTab:AddSection("Game auto tap")
    local gameToggle
    gameToggle = tapTab:AddToggle("Game's own Auto Tap (needs the upgrade)", TapsController.AutoTapEnabled == true, function(value)
        local ok, err = asGame(function()
            TapsController:SetAutoTapEnabled(value)
        end)
        if not ok then
            tap.lastError = tostring(err)
        end
        if value and TapsController.AutoTapEnabled ~= true then
            gameToggle:Set(false, true)
            window:Notify("Auto Tap isn't unlocked yet - unlock it in Upgrades", 5)
        end
    end)

    task.spawn(function()
        local lastInfo = 0
        while tap.alive and not window.destroyed do
            restoreIdentity()
            if tap.auto then
                local options = tap.minimal
                    and { playRipple = false, playSound = false, playVfx = false, bounceButtons = false, source = "Auto" }
                    or { playRipple = true, playSound = false, bounceButtons = false, source = "Auto" }
                -- run at a normal game identity: the reward maths in RequestTap calls configs that require() lazily
                local ok, err = asGame(function()
                    TapsController:RequestTap(options)
                end)
                if ok then
                    tap.sent += 1
                    tap.lastError = nil
                else
                    local message = tostring(err)
                    if tap.lastError ~= message then
                        tap.lastError = message
                        warn("[AutoHatch] RequestTap failed: " .. message)
                    end
                    task.wait(1)
                end
                task.wait(1 / tap.cps)
            else
                task.wait(0.2)
            end
            if os.clock() - lastInfo > 2 then
                lastInfo = os.clock()
                local ok, value = asGame(function()
                    return TapsController:GetTapValue()
                end)
                if ok and type(value) == "number" then
                    tap.perTap = value
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Anti AFK
--   Roblox kicks an idle player after 20 minutes; Player.Idled fires shortly before that. The usual answer is to fake a
--   bit of input through VirtualUser when it does. A periodic pulse covers games that have their own idle timer.
--------------------------------------------------------------------------------

restoreIdentity()

local antiAfk = {
    alive = true,
    on = true,
    pulse = true,
    handled = 0,
    lastAt = nil,
    lastResult = nil,
    disabled = {}, -- game connections to Player.Idled that were switched off (switched back on at unload)
}

local PULSE_SECONDS = 60

-- Two kinds of input: VirtualUser resets Roblox's own idle timer; a 1px mouse nudge through VirtualInputManager arrives as
-- real input, so it also resets anything the game itself watches through UserInputService.
local function simulateActivity()
    antiAfk.handled += 1
    antiAfk.lastAt = os.clock()
    local userOk, userErr = pcall(function()
        local virtualUser = game:GetService("VirtualUser")
        virtualUser:CaptureController()
        virtualUser:ClickButton2(Vector2.new(0, 0))
    end)
    local inputOk, inputErr = pcall(function()
        local virtualInput = game:GetService("VirtualInputManager")
        local position = UserInputService:GetMouseLocation()
        virtualInput:SendMouseMoveEvent(position.X + 1, position.Y, game)
        task.wait(0.05)
        virtualInput:SendMouseMoveEvent(position.X, position.Y, game)
    end)
    antiAfk.lastResult = ("VirtualUser %s, mouse nudge %s"):format(
        userOk and "ok" or ("failed: " .. tostring(userErr)), inputOk and "ok" or ("failed: " .. tostring(inputErr)))
end

-- Anything in the game hooked on Player.Idled (usually the thing that kicks) is switched off; ours is connected afterwards.
if type(getconnections) == "function" then
    pcall(function()
        for _, connection in ipairs(getconnections(player.Idled)) do
            if pcall(function() connection:Disable() end) then
                table.insert(antiAfk.disabled, connection)
            end
        end
    end)
end

local miscTab = window:AddTab("Misc")
local miscStatus = miscTab:AddLabel("")

miscTab:AddSection("Anti AFK")
miscTab:AddToggle("Anti AFK", antiAfk.on, function(value)
    antiAfk.on = value
end)
miscTab:AddToggle("Also pulse every minute", antiAfk.pulse, function(value)
    antiAfk.pulse = value
end)
miscTab:AddButton("Test now (send activity once)", function()
    simulateActivity()
    window:Notify(antiAfk.lastResult or "Sent", 6)
end)
miscTab:AddLabel("When Roblox reports you idle it fakes input (VirtualUser plus a 1px mouse nudge); the pulse does the same every minute for games with their own idle check. Game scripts hooked on the idle event are switched off while this runs.")

pcall(function()
    window:Connect(player.Idled, function()
        if antiAfk.on then
            simulateActivity()
        end
    end)
end)

task.spawn(function()
    local last = os.clock()
    while antiAfk.alive and not window.destroyed do
        restoreIdentity()
        task.wait(1)
        local now = os.clock()
        if antiAfk.on and antiAfk.pulse and now - last >= PULSE_SECONDS then
            last = now
            simulateActivity()
        end
    end
end)

local function updateMiscLabel()
    local lines = { antiAfk.on and "Anti AFK: on" or "Anti AFK: off" }
    if antiAfk.lastAt then
        table.insert(lines, ("Last activity sent %ds ago (%d total)"):format(math.floor(os.clock() - antiAfk.lastAt), antiAfk.handled))
        if antiAfk.lastResult then
            table.insert(lines, antiAfk.lastResult)
        end
    else
        table.insert(lines, "No activity sent yet (the first pulse goes out within a minute)")
    end
    table.insert(lines, ("Game idle handlers switched off: %d%s"):format(
        #antiAfk.disabled, type(getconnections) == "function" and "" or " (executor has no getconnections)"))
    miscStatus:SetText(table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- Event egg (EventEggController)
--   Claiming is _events.ClaimEventEgg:FireServer(). The game's own button only lets it through once
--   client:get({ "EventEgg" }).ProgressSeconds >= EventEggConfig.GetClaimDurationSeconds(); the same check is used here.
--------------------------------------------------------------------------------

restoreIdentity()

local EventEggController = tryRequire(controllersFolder and controllersFolder:FindFirstChild("EventEggController"))
local EventEggConfig = tryRequire(configsFolder and configsFolder:FindFirstChild("EventEggConfig"))
local eventEvents = (EventEggController and EventEggController._events) or collectEvents or farmEvents or chestEvents
local eventReady = type(EventEggConfig) == "table" and dataClient ~= nil
    and type(eventEvents) == "table" and eventEvents.ClaimEventEgg ~= nil

local eventEgg = {
    alive = true,
    auto = false,
    claims = 0,
    duration = nil,
    progress = nil,
    ready = false,
    lastClaim = 0,
    strikes = 0, -- claims in a row that left it still ready (the server refused)
    blockedUntil = 0,
    lastError = nil,
}

local function formatClock(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

miscTab:AddSection("Event egg")
local eventStatus = miscTab:AddLabel("")

local function updateEventLabel()
    if not eventReady then
        return
    end
    local lines = {}
    if eventEgg.duration and eventEgg.progress then
        if eventEgg.ready then
            table.insert(lines, "Event egg: ready to claim")
        else
            table.insert(lines, "Event egg: " .. formatClock(eventEgg.duration - eventEgg.progress) .. " until it can be claimed")
        end
    else
        table.insert(lines, "Event egg: waiting for data")
    end
    table.insert(lines, ("Auto claim: %s   Claims sent: %d"):format(eventEgg.auto and "on" or "off", eventEgg.claims))
    if eventEgg.blockedUntil > os.clock() then
        table.insert(lines, ("Server keeps refusing - paused for %ds"):format(math.ceil(eventEgg.blockedUntil - os.clock())))
    end
    if eventEgg.lastError then
        table.insert(lines, "Error: " .. eventEgg.lastError)
    end
    eventStatus:SetText(table.concat(lines, "\n"))
end

if not eventReady then
    local missing = {}
    if type(EventEggConfig) ~= "table" then
        table.insert(missing, "EventEggConfig")
    end
    if not dataClient then
        table.insert(missing, "dataservice")
    end
    if type(eventEvents) ~= "table" or not eventEvents.ClaimEventEgg then
        table.insert(missing, "the ClaimEventEgg event")
    end
    eventStatus:SetText("Event egg unavailable - missing: " .. table.concat(missing, ", "))
    eventStatus:SetColor(Theme.Warn)
else
    miscTab:AddToggle("Auto claim event egg", false, function(value)
        eventEgg.auto = value
        eventEgg.strikes = 0
        eventEgg.blockedUntil = 0
        eventEgg.lastError = nil
    end)

    task.spawn(function()
        while eventEgg.alive and not window.destroyed do
            restoreIdentity()
            -- config functions can require() lazily, so read them at a normal game identity
            local ok, duration, progress = asGame(function()
                local data = dataClient:get({ "EventEgg" })
                local seconds = 0
                if type(data) == "table" then
                    seconds = math.max(0, math.floor(tonumber(data.ProgressSeconds) or 0))
                end
                return EventEggConfig.GetClaimDurationSeconds(), seconds
            end)
            if ok and type(duration) == "number" then
                eventEgg.duration, eventEgg.progress = duration, progress
                eventEgg.ready = progress >= duration
                eventEgg.lastError = nil
                if not eventEgg.ready then
                    eventEgg.strikes = 0
                elseif eventEgg.auto then
                    local now = os.clock()
                    if now >= eventEgg.blockedUntil and now - eventEgg.lastClaim >= 3 then
                        eventEgg.lastClaim = now
                        if pcall(function() eventEvents.ClaimEventEgg:FireServer() end) then
                            eventEgg.claims += 1
                            eventEgg.strikes += 1
                            if eventEgg.strikes >= 4 then
                                eventEgg.blockedUntil = now + 30 -- still ready after 4 claims: stop hammering the server
                                eventEgg.strikes = 0
                            end
                        end
                    end
                end
            elseif not ok then
                local message = tostring(duration)
                if eventEgg.lastError ~= message then
                    eventEgg.lastError = message
                    warn("[AutoHatch] event egg check failed: " .. message)
                end
            end
            task.wait(1)
        end
    end)
end

--------------------------------------------------------------------------------
-- Live labels + IsActive edge detection
--------------------------------------------------------------------------------

restoreIdentity()

local lastActive = false
local labelClock = 0
local eggClock = 5 -- refresh the egg list right away
window:Loop(function(dt)
    local active = HatchController.IsActive == true
    if active and not lastActive then
        state.activeEdges += 1
        tryLearn()
    end
    lastActive = active

    if state.pendingNotice then
        window:Notify(state.pendingNotice, 6)
        state.pendingNotice = nil
    end

    labelClock += dt
    if labelClock < 0.25 then
        return
    end
    labelClock = 0
    updateFarmLabel()
    updateChestLabel()
    updateCollectLabel()
    updateTapLabel()
    updateMiscLabel()
    updateEventLabel()

    -- keep the egg picker in step with the eggs that are actually loaded in the world
    if nativeReady then
        eggClock += 0.25
        if eggClock >= 5 then
            eggClock = 0
            local okEggs, eggs = asGame(findWorldEggs)
            if okEggs and type(eggs) == "table" then
                local names, seen = {}, {}
                for _, egg in ipairs(eggs) do
                    if not seen[egg.name] then
                        seen[egg.name] = true
                        table.insert(names, egg.name)
                    end
                end
                table.sort(names)
                local key = table.concat(names, "|")
                if key ~= state.eggOptionsKey then
                    state.eggOptionsKey = key
                    table.insert(names, 1, "Nearest")
                    eggCycle:SetOptions(names, true)
                    state.eggChoice = eggCycle.Get() or "Nearest"
                end
            end
        end
    end

    -- the captured call changed: work out where its egg amount sits
    if state.candidatesFor ~= state.captured then
        state.candidatesFor = state.captured
        local found = state.captured and findAmountCandidates(state.captured.args, state.learnedCount) or {}
        if state.learnedCount then
            -- no picker any more: only trust an argument that matches how many pets the learned hatch produced
            local confirmed = {}
            for _, candidate in ipairs(found) do
                if candidate.value == state.learnedCount then
                    table.insert(confirmed, candidate)
                end
            end
            found = confirmed
        end
        state.amountCandidates = found
        state.amountIndex = 1
        state.currentAmount = state.maxEggs
        local labels = {}
        for _, candidate in ipairs(state.amountCandidates) do
            table.insert(labels, candidate.label)
        end
        if #labels == 0 then
            labels = { state.captured and "(none found)" or "(learn first)" }
        end
        amountCycle:SetOptions(labels)
    end

    local statusText
    if state.learning then
        statusText = "Learning - open one egg by hand now"
        statusLabel:SetColor(Theme.Warn)
    elseif state.running then
        statusText = ("Running - %d hatches"):format(state.runCount)
        statusLabel:SetColor(Theme.Accent)
    else
        statusText = state.status
        statusLabel:SetColor(Theme.SubText)
    end
    local hookText = state.hatchSeq > 0
        and ("HatchEggs hook: active (%d seen)"):format(state.hatchSeq)
        or "HatchEggs hook: not triggered yet"
    if not hookReady then
        hookText = hookText .. " | no remote hook (executor lacks hookmetamethod)"
    end
    if nativeReady then
        if state.nativeNote then
            hookText = hookText .. "\n" .. state.nativeNote
        elseif state.running and state.nativeEgg then
            hookText = hookText .. ("\nHatching %s eggs: x%d (the most you can afford)"):format(state.nativeEgg, state.nativeAmount or 0)
        end
    else
        hookText = hookText .. "\n" .. (state.captured and ("Learned call: " .. describeCall(state.captured)) or "No call learned yet")
    end
    if state.hatchMax and state.captured and not nativeReady then
        if #state.amountCandidates == 0 then
            hookText = hookText .. "\nHatch max off: can't tell which argument is the egg amount (learn with a multi-egg hatch)"
        else
            hookText = hookText .. ("\nHatch max: asking for %d (up to %d)"):format(
                state.currentAmount or state.maxEggs, state.maxEggs)
        end
    end
    statusLabel:SetText(statusText .. "\n" .. hookText)

    if state.captured then
        local line = describeCall(state.captured)
        if state.lastInvoke then
            line = line .. "\nLast reply: " .. state.lastInvoke
        end
        remoteLabel:SetText(line)
    else
        remoteLabel:SetText("none captured")
    end

    if state.totalPets == 0 then
        statsLabel:SetText("No hatches seen yet")
    else
        local lines = {
            ("Hatch calls seen: %d   Pets: %d"):format(state.hatchSeq, state.totalPets),
            state.best and ("Best: %s (%s)"):format(state.best.name, state.best.rarity) or "Best: -",
            "",
        }
        local rarities = {}
        for rarity in pairs(state.counts) do
            table.insert(rarities, rarity)
        end
        table.sort(rarities, function(a, b)
            return rarityRank(a) > rarityRank(b)
        end)
        for _, rarity in ipairs(rarities) do
            table.insert(lines, ("%s: %d"):format(rarity, state.counts[rarity]))
        end
        statsLabel:SetText(table.concat(lines, "\n"))
    end
end)

--------------------------------------------------------------------------------
-- Unload
--------------------------------------------------------------------------------

window.onDestroy = function()
    farm.alive = false
    farm.autoBreak = false
    chestState.alive = false
    chestState.auto = false
    collect.alive = false
    collect.auto = false
    tap.alive = false
    tap.auto = false
    antiAfk.alive = false
    for _, connection in ipairs(antiAfk.disabled) do
        pcall(function()
            connection:Enable()
        end)
    end
    eventEgg.alive = false
    eventEgg.auto = false
    state.running = false
    state.learning = false
    state.runToken += 1
    if HatchController.HatchEggs == hatchWrapper then
        HatchController.HatchEggs = originalHatchEggs
    end
    local shared = env.AutoHatchRemoteHook
    if shared and shared.record == record then
        shared.record = nil
    end
    env.AutoHatchGuiUnload = nil
end
env.AutoHatchGuiUnload = function()
    window:Destroy()
end

window:Notify(hookReady and "Loaded. Press Learn, then open one egg by hand." or "Loaded, but no hookmetamethod: the egg remote can't be learned", 6)
