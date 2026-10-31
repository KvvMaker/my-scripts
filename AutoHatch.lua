-- Auto Hatch GUI
--
-- Drives the game's own auto-hatch (ReplicatedStorage.Controllers.Pets.EggController) instead of
-- replaying remotes, so pity, secrets, storage and coin checks all stay handled by the game.
--   * Pick an egg (or "Nearest egg"), stand next to it, switch it on.
--   * The game stops auto-hatch when you leave the egg, run out of coins, fill your storage, or the
--     server hiccups. While the switch is ON this script restarts it once the problem is gone.
--   * Hatch size (x1 / x3 / x8) is chosen by the game: the biggest you own and can afford.
--   * Skip animation / Hatch delay hook HatchRenderer.Play. The game waits for the hatch animation to
--     report "done" before it sends the next hatch, so: skipping = report done right away, and the
--     delay = how long to wait before reporting done. Secret-pet reveals are left alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local env = getgenv and getgenv() or _G

if env.AutoHatch and env.AutoHatch.shutdown then
	pcall(env.AutoHatch.shutdown)
end
local saved = env.AutoHatchSettings or {}

-- false: the window lives in PlayerGui, which any thread can update. true: gethui()/CoreGui, which is
-- harder for the game to see but is protected, and on some executors only the thread that created
-- it may touch it ("The current thread cannot access 'Instance' (lacking capability Plugin)").
local USE_HIDDEN_UI = false

-- Executors can hand callbacks and resumed threads a lower security identity; raise it again.
local function elevate()
	local set = setthreadidentity or set_thread_identity or setidentity or (syn and syn.set_thread_identity)
	if set then
		pcall(set, 8)
	end
end

-- Runs a UI update without letting a failure kill the caller; warns once per distinct error.
local lastUiError
local function ui(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and err ~= lastUiError then
		lastUiError = err
		warn("[AutoHatch] UI update failed: " .. tostring(err))
	end
end

local function uiParent()
	if not USE_HIDDEN_UI then
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
		if pg then
			return pg
		end
	end
	return (gethui and gethui()) or CoreGui
end

local REACH = 10 -- the game's "near an egg" radius (EggController.nearestEgg)
local ATTR = "TS2AutoOpen" -- workspace attribute the game sets to the egg being auto-hatched
local MAX_DELAY = 10 -- seconds, top of the delay slider

-- Game modules --------------------------------------------------------------------------

local EggController, LaunchEggConfig, DataController, EggPricing

local function fetch(...)
	local path = { ... }
	local inst = ReplicatedStorage
	for _, name in path do
		inst = inst and inst:WaitForChild(name, 15)
	end
	if not inst then
		return nil, "missing " .. table.concat(path, ".")
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		return nil, tostring(mod)
	end
	return mod
end

-- Formatting ----------------------------------------------------------------------------

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function abbr(n)
	if type(n) ~= "number" or n ~= n then
		return "-"
	end
	if n == math.huge then
		return "inf"
	end
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIXES do
		n /= 1000
		i += 1
	end
	local s
	if n >= 100 then
		s = ("%d"):format(math.floor(n))
	elseif n >= 10 then
		s = ("%.1f"):format(n)
	else
		s = ("%.2f"):format(n)
	end
	if s:find(".", 1, true) then
		s = s:gsub("0+$", "")
		s = s:gsub("%.$", "")
	end
	return s .. SUFFIXES[i]
end

local function fmtTime(sec)
	sec = math.floor(sec)
	local h, m, s = sec // 3600, sec % 3600 // 60, sec % 60
	if h > 0 then
		return ("%d:%02d:%02d"):format(h, m, s)
	end
	return ("%02d:%02d"):format(m, s)
end

-- Theme ---------------------------------------------------------------------------------

local C = {
	BG = Color3.fromRGB(20, 20, 27),
	PANEL = Color3.fromRGB(31, 31, 41),
	PANEL2 = Color3.fromRGB(40, 40, 52),
	HOVER = Color3.fromRGB(52, 52, 68),
	STROKE = Color3.fromRGB(58, 58, 76),
	TEXT = Color3.fromRGB(236, 236, 242),
	MUTED = Color3.fromRGB(140, 140, 158),
	ACCENT = Color3.fromRGB(96, 108, 255),
	ACCENT2 = Color3.fromRGB(160, 92, 255),
	GREEN = Color3.fromRGB(72, 208, 128),
	YELLOW = Color3.fromRGB(244, 196, 72),
	RED = Color3.fromRGB(240, 92, 92),
}
local KIND_COLOR = { ok = C.GREEN, wait = C.YELLOW, error = C.RED, idle = C.MUTED }

local function make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in props do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function round(inst, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, inst)
end

local function outline(inst, color)
	make("UIStroke", { Color = color or C.STROKE, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, inst)
end

local function label(props, parent)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.Gotham
	props.TextColor3 = props.TextColor3 or C.TEXT
	props.TextSize = props.TextSize or 12
	return make("TextLabel", props, parent)
end

local function tween(inst, props, time)
	TweenService:Create(inst, TweenInfo.new(time or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local function hover(btn, base, over)
	btn.MouseEnter:Connect(function()
		tween(btn, { BackgroundColor3 = over }, 0.1)
	end)
	btn.MouseLeave:Connect(function()
		tween(btn, { BackgroundColor3 = base }, 0.1)
	end)
end

-- Builds a sliding on/off pill; returns a function that sets it on or off.
local function makeSwitch(parent, position, w, h)
	local pill = make("Frame", {
		Position = position,
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = C.PANEL2,
		BorderSizePixel = 0,
	}, parent)
	round(pill, h / 2)
	local pad = 3
	local d = h - pad * 2
	local knob = make("Frame", {
		Position = UDim2.fromOffset(pad, pad),
		Size = UDim2.fromOffset(d, d),
		BackgroundColor3 = C.TEXT,
		BorderSizePixel = 0,
	}, pill)
	round(knob, d / 2)
	return function(on)
		tween(pill, { BackgroundColor3 = on and C.GREEN or C.PANEL2 }, 0.18)
		tween(knob, { Position = UDim2.fromOffset(on and (w - d - pad) or pad, pad) }, 0.18)
	end
end

-- Window --------------------------------------------------------------------------------

local WIDTH, MIN_H = 300, 36
local HATCH_H, TOT_H = 450, 354 -- window height on the Hatch / Trick or Treat tab

local gui = make("ScreenGui", {
	Name = "AutoHatchGui",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 100,
}, uiParent())

local main = make("Frame", {
	Size = UDim2.fromOffset(WIDTH, HATCH_H),
	Position = UDim2.new(0, 40, 0.5, -HATCH_H / 2),
	BackgroundColor3 = C.BG,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, gui)
round(main, 10)
outline(main)

-- Title bar
local titleBar = make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = C.PANEL, BorderSizePixel = 0 }, main)
round(titleBar, 10)
make("Frame", {
	Position = UDim2.fromOffset(0, 18),
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundColor3 = C.PANEL,
	BorderSizePixel = 0,
}, titleBar)
local accentLine = make("Frame", {
	Position = UDim2.fromOffset(0, 34),
	Size = UDim2.new(1, 0, 0, 2),
	BackgroundColor3 = C.TEXT,
	BorderSizePixel = 0,
}, titleBar)
make("UIGradient", { Color = ColorSequence.new(C.ACCENT, C.ACCENT2) }, accentLine)

local logo = make("Frame", {
	Position = UDim2.fromOffset(12, 11),
	Size = UDim2.fromOffset(14, 14),
	BackgroundColor3 = C.TEXT,
	BorderSizePixel = 0,
}, titleBar)
round(logo, 7)
make("UIGradient", { Color = ColorSequence.new(C.ACCENT, C.ACCENT2), Rotation = 45 }, logo)
label({
	Position = UDim2.fromOffset(34, 0),
	Size = UDim2.new(1, -110, 0, 34),
	Text = "Auto Hatch",
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, titleBar)

local function titleButton(text, xFromRight)
	local b = make("TextButton", {
		Position = UDim2.new(1, xFromRight, 0, 4),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = C.PANEL,
		AutoButtonColor = false,
		Text = text,
		TextColor3 = C.MUTED,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
	}, titleBar)
	round(b, 6)
	hover(b, C.PANEL, C.HOVER)
	return b
end
local minBtn = titleButton("–", -62)
local closeBtn = titleButton("×", -32)

-- Tabs + pages (page contents are positioned as if the page started 30 px higher, under the tab strip)
local tabStrip = make("Frame", { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, main)
local function makeTab(text, index)
	return make("TextButton", {
		Position = UDim2.fromScale((index - 1) * 0.5, 0),
		Size = UDim2.fromScale(0.5, 1),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = index == 1 and C.TEXT or C.MUTED,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
	}, tabStrip)
end
local hatchTab = makeTab("Hatch", 1)
local totTab = makeTab("Trick or Treat", 2)
local tabLine = make("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, 0),
	Size = UDim2.new(0.5, -24, 0, 2),
	BackgroundColor3 = C.ACCENT,
	BorderSizePixel = 0,
}, tabStrip)
round(tabLine, 1)

local function makePage(visible)
	return make("Frame", {
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 1, -30),
		BackgroundTransparency = 1,
		Visible = visible,
	}, main)
end
local hatchPage = makePage(true)
local totPage = makePage(false)

-- Status card
local statusCard = make("Frame", {
	Position = UDim2.fromOffset(12, 46),
	Size = UDim2.new(1, -24, 0, 62),
	BackgroundColor3 = C.PANEL,
	BorderSizePixel = 0,
}, hatchPage)
round(statusCard)
outline(statusCard)
local dot = make("Frame", {
	Position = UDim2.fromOffset(14, 15),
	Size = UDim2.fromOffset(10, 10),
	BackgroundColor3 = C.MUTED,
	BorderSizePixel = 0,
}, statusCard)
round(dot, 5)
local headLabel = label({
	Position = UDim2.fromOffset(34, 8),
	Size = UDim2.new(1, -44, 0, 18),
	Text = "Loading",
	TextColor3 = C.YELLOW,
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, statusCard)
local detailLabel = label({
	Position = UDim2.fromOffset(34, 28),
	Size = UDim2.new(1, -44, 0, 30),
	Text = "Hooking into the game's egg modules...",
	TextColor3 = C.MUTED,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, statusCard)

-- Egg selector
label({
	Position = UDim2.fromOffset(14, 116),
	Size = UDim2.fromOffset(100, 12),
	Text = "EGG",
	TextColor3 = C.MUTED,
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	TextXAlignment = Enum.TextXAlignment.Left,
}, hatchPage)
local selector = make("TextButton", {
	Position = UDim2.fromOffset(12, 130),
	Size = UDim2.new(1, -24, 0, 34),
	BackgroundColor3 = C.PANEL,
	AutoButtonColor = false,
	Text = "",
}, hatchPage)
round(selector)
outline(selector)
hover(selector, C.PANEL, C.HOVER)
local selName = label({
	Position = UDim2.fromOffset(12, 0),
	Size = UDim2.new(1, -44, 1, 0),
	Text = "Nearest egg",
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, selector)
local chevron = label({
	Position = UDim2.new(1, -30, 0, 0),
	Size = UDim2.fromOffset(20, 34),
	Text = "▼",
	TextColor3 = C.MUTED,
	TextSize = 9,
}, selector)

-- Stat cards
local statsRow = make("Frame", {
	Position = UDim2.fromOffset(12, 174),
	Size = UDim2.new(1, -24, 0, 50),
	BackgroundTransparency = 1,
}, hatchPage)
make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 9),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, statsRow)

local function statCard(order, title)
	local card = make("Frame", {
		Size = UDim2.new(0, 86, 1, 0),
		BackgroundColor3 = C.PANEL,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, statsRow)
	round(card)
	outline(card)
	label({
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.new(1, -20, 0, 12),
		Text = title,
		TextColor3 = C.MUTED,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)
	return label({
		Position = UDim2.fromOffset(10, 24),
		Size = UDim2.new(1, -20, 0, 20),
		Text = "-",
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, card)
end
local costValue = statCard(1, "COST")
local coinsValue = statCard(2, "COINS")
local hatchedValue = statCard(3, "HATCHED")

-- Options card: skip animation + hatch delay
local optionsCard = make("Frame", {
	Position = UDim2.fromOffset(12, 234),
	Size = UDim2.new(1, -24, 0, 90),
	BackgroundColor3 = C.PANEL,
	BorderSizePixel = 0,
}, hatchPage)
round(optionsCard)
outline(optionsCard)

local skipRow = make("TextButton", {
	Size = UDim2.new(1, 0, 0, 42),
	BackgroundTransparency = 1,
	Text = "",
}, optionsCard)
label({
	Position = UDim2.fromOffset(14, 6),
	Size = UDim2.new(1, -80, 0, 16),
	Text = "Skip animation",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
}, skipRow)
local skipSub = label({
	Position = UDim2.fromOffset(14, 23),
	Size = UDim2.new(1, -80, 0, 14),
	Text = "Hatch results appear instantly",
	TextColor3 = C.MUTED,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, skipRow)
local setSkipSwitch = makeSwitch(skipRow, UDim2.new(1, -54, 0, 10), 40, 22)

make("Frame", {
	Position = UDim2.fromOffset(14, 43),
	Size = UDim2.new(1, -28, 0, 1),
	BackgroundColor3 = C.STROKE,
	BorderSizePixel = 0,
}, optionsCard)

label({
	Position = UDim2.fromOffset(14, 50),
	Size = UDim2.new(1, -100, 0, 16),
	Text = "Hatch delay",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
}, optionsCard)
local delayValue = label({
	Position = UDim2.new(1, -90, 0, 50),
	Size = UDim2.fromOffset(76, 16),
	Text = "0.5 s",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Right,
}, optionsCard)
local track = make("Frame", {
	Position = UDim2.fromOffset(14, 75),
	Size = UDim2.new(1, -28, 0, 6),
	BackgroundColor3 = C.PANEL2,
	BorderSizePixel = 0,
}, optionsCard)
round(track, 3)
local fill = make("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = C.ACCENT,
	BorderSizePixel = 0,
}, track)
round(fill, 3)
local sliderKnob = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0, 0.5),
	Size = UDim2.fromOffset(14, 14),
	BackgroundColor3 = C.TEXT,
	BorderSizePixel = 0,
}, track)
round(sliderKnob, 7)
local sliderHit = make("TextButton", {
	Position = UDim2.fromOffset(8, 64),
	Size = UDim2.new(1, -16, 0, 26),
	BackgroundTransparency = 1,
	Text = "",
}, optionsCard)

-- Main switch
local toggleRow = make("TextButton", {
	Position = UDim2.fromOffset(12, 332),
	Size = UDim2.new(1, -24, 0, 54),
	BackgroundColor3 = C.PANEL,
	AutoButtonColor = false,
	Text = "",
}, hatchPage)
round(toggleRow)
outline(toggleRow)
hover(toggleRow, C.PANEL, C.HOVER)
label({
	Position = UDim2.fromOffset(14, 9),
	Size = UDim2.new(1, -90, 0, 18),
	Text = "Auto Hatch",
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, toggleRow)
local toggleSub = label({
	Position = UDim2.fromOffset(14, 29),
	Size = UDim2.new(1, -90, 0, 16),
	Text = "",
	TextColor3 = C.MUTED,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, toggleRow)
local setMainSwitch = makeSwitch(toggleRow, UDim2.new(1, -64, 0.5, -13), 50, 26)

local footer = label({
	Position = UDim2.fromOffset(12, 394),
	Size = UDim2.new(1, -24, 0, 16),
	Text = "",
	TextColor3 = C.MUTED,
	TextSize = 10,
}, hatchPage)

-- Egg dropdown (drawn above everything else; the catcher closes it on an outside click)
local catcher = make("TextButton", {
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 1, -36),
	BackgroundTransparency = 1,
	Text = "",
	Visible = false,
	ZIndex = 5,
}, hatchPage)
local dropdown = make("ScrollingFrame", {
	Position = UDim2.fromOffset(12, 168),
	Size = UDim2.new(1, -24, 0, 0),
	BackgroundColor3 = C.PANEL2,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.MUTED,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ClipsDescendants = true,
	Visible = false,
	ZIndex = 10,
}, hatchPage)
round(dropdown)
outline(dropdown)
make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, dropdown)
make("UIPadding", {
	PaddingTop = UDim.new(0, 4),
	PaddingBottom = UDim.new(0, 4),
	PaddingLeft = UDim.new(0, 4),
	PaddingRight = UDim.new(0, 4),
}, dropdown)

-- State ---------------------------------------------------------------------------------

local S = {
	enabled = false,
	enabledAt = nil,
	choiceName = nil, -- nil = nearest egg
	starts = 0,
	hatched = 0, -- pets shown through HatchRenderer.Play since the script started
	skipAnim = saved.skipAnim == true,
	delay = math.clamp(tonumber(saved.delay) or 0.5, 0, MAX_DELAY),
	runningSince = nil,
	quickStops = 0,
	backoffUntil = 0,
	note = nil,
}

-- Trick or Treat tab state (the tab itself is built further down)
local T = {
	enabled = false,
	enabledAt = nil,
	teleport = not (env.AutoHatchTot and env.AutoHatchTot.teleport == false),
	knocked = 0, -- houses whose cooldown restarted while the script was running
	last = {}, -- houseId -> ready-at server time seen last tick
	skipUntil = {}, -- houseId -> os.clock() until which a house that never answered is ignored
	lastMove = 0,
	zoneSince = nil,
	visitSince = nil,
}
local renderTotToggle

local alive = true
local connections = {}
local dropOpen = false
local minimized = false
local hookReady, hookError = false, nil

local function eggPosition(model)
	local egg = model:FindFirstChild("Egg")
	local part
	if egg then
		if egg:IsA("BasePart") then
			part = egg
		elseif egg:IsA("Model") then
			part = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart", true)
		end
	end
	part = part or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	return part and part.Position
end

local function eggPrice(name)
	return tonumber(LaunchEggConfig[name].Price) or 0
end

local function listEggs()
	local eggs = {}
	local folder = workspace:FindFirstChild("Eggs")
	if folder and LaunchEggConfig then
		for _, m in folder:GetChildren() do
			if m:IsA("Model") and LaunchEggConfig[m.Name] then
				table.insert(eggs, m)
			end
		end
	end
	table.sort(eggs, function(a, b)
		return eggPrice(a.Name) < eggPrice(b.Name)
	end)
	return eggs
end

local function nearestEgg()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local best, bestDist = nil, REACH
	for _, m in listEggs() do
		local pos = eggPosition(m)
		if pos then
			local d = (pos - hrp.Position).Magnitude
			if d < bestDist then
				best, bestDist = m, d
			end
		end
	end
	return best
end

local function getData()
	if not DataController then
		return nil
	end
	local ok, data = pcall(function()
		return DataController:GetReplica().Data
	end)
	return ok and data or nil
end

local function unitPrice(data, eggName)
	if not (data and EggPricing and eggName and LaunchEggConfig[eggName]) then
		return nil
	end
	local ok, price = pcall(EggPricing.GetUnitPrice, data, eggName, LaunchEggConfig[eggName].Price)
	return ok and price or nil
end

-- Returns true, "coins" or "storage"
local function affordability(eggName)
	local data = getData()
	local price = unitPrice(data, eggName)
	if not price then
		return true
	end
	if (data.Currencies.Coins or 0) < price then
		return "coins"
	end
	local ok, full = pcall(function()
		local owned = 0
		for _ in data.Pets.Owned do
			owned += 1
		end
		return owned >= data.Pets.StorageLimit
	end)
	if ok and full then
		return "storage"
	end
	return true
end

-- ToggleAutoHatch starts auto-hatch, or stops it when it is already running.
local function toggleGame(eggName)
	return pcall(EggController.ToggleAutoHatch, EggController, eggName)
end

local function stopGame()
	local running = workspace:GetAttribute(ATTR)
	if running ~= nil and EggController then
		toggleGame(running)
	end
end

-- HatchRenderer hook (skip animation / hatch delay) -------------------------------------

local HatchRenderer, originalPlay, hadOwnPlay, hookFn

local function installHook()
	local mod, err = fetch("Modules", "Client", "Pets", "HatchRenderer")
	if not mod then
		return false, err
	end
	local original = mod.Play
	if type(original) ~= "function" then
		return false, "HatchRenderer.Play not found"
	end

	-- Called as HatchRenderer:Play(eggModel, result, onDone, receipt) by EggController.
	local function hook(self, egg, result, onDone, ...)
		if not alive or type(onDone) ~= "function" or (type(result) == "table" and result.Forced == true) then
			return original(self, egg, result, onDone, ...)
		end
		local pets = type(result) == "table" and type(result.Pets) == "table" and #result.Pets or 1
		S.hatched += math.max(pets, 1)

		local delay = S.delay
		if S.skipAnim then
			task.delay(delay, onDone) -- the game sends the next hatch once onDone has run
			return
		end
		if delay > 0 then
			return original(self, egg, result, function()
				task.delay(delay, onDone)
			end, ...)
		end
		return original(self, egg, result, onDone, ...)
	end

	local hadOwn = rawget(mod, "Play") ~= nil
	local ok, setErr = pcall(function()
		if setreadonly and isreadonly and isreadonly(mod) then
			setreadonly(mod, false)
		end
		rawset(mod, "Play", hook)
	end)
	if not ok then
		return false, tostring(setErr)
	end
	HatchRenderer, originalPlay, hadOwnPlay, hookFn = mod, original, hadOwn, hook
	return true
end

local function removeHook()
	if HatchRenderer and rawget(HatchRenderer, "Play") == hookFn then
		pcall(rawset, HatchRenderer, "Play", hadOwnPlay and originalPlay or nil)
	end
end

-- Display -------------------------------------------------------------------------------

local currentKind, pulse

local function setState(kind, headline, detail)
	headLabel.Text = headline
	detailLabel.Text = detail or ""
	if kind == currentKind then
		return
	end
	currentKind = kind
	if pulse then
		pulse:Cancel()
		pulse = nil
	end
	dot.BackgroundTransparency = 0
	local color = KIND_COLOR[kind] or C.MUTED
	tween(dot, { BackgroundColor3 = color }, 0.2)
	tween(headLabel, { TextColor3 = color }, 0.2)
	if kind == "ok" then
		pulse = TweenService:Create(
			dot,
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.65 }
		)
		pulse:Play()
	end
end

local function renderToggle()
	setMainSwitch(S.enabled)
	toggleSub.Text = S.enabled and "On - restarts itself if it stops" or "Off - stand by an egg, then switch on"
end

local function renderSelector()
	selName.Text = S.choiceName and (S.choiceName .. " Egg") or "Nearest egg"
end

local function renderSkip()
	setSkipSwitch(S.skipAnim and not hookError)
	if hookError then
		skipSub.Text = "Unavailable: " .. hookError
		skipSub.TextColor3 = C.RED
	else
		skipSub.Text = "Hatch results appear instantly"
		skipSub.TextColor3 = C.MUTED
	end
end

local function renderDelay()
	local frac = S.delay / MAX_DELAY
	fill.Size = UDim2.fromScale(frac, 1)
	sliderKnob.Position = UDim2.fromScale(frac, 0.5)
	if hookError then
		delayValue.Text = "n/a"
	else
		delayValue.Text = S.delay <= 0 and "none" or ("%.1f s"):format(S.delay)
	end
end

local function saveSettings()
	env.AutoHatchSettings = { skipAnim = S.skipAnim, delay = S.delay }
end

local function updateStats()
	local near = nearestEgg()
	local target = S.choiceName or (near and near.Name)
	local data = getData()
	local coins = data and data.Currencies and data.Currencies.Coins
	local price = unitPrice(data, target)

	costValue.Text = price and abbr(price) or "-"
	costValue.TextColor3 = (price and coins) and (coins >= price and C.GREEN or C.RED) or C.TEXT
	coinsValue.Text = coins and abbr(coins) or "-"
	hatchedValue.Text = hookReady and abbr(S.hatched) or "-"

	local session = S.enabledAt and fmtTime(os.clock() - S.enabledAt) or "--:--"
	footer.Text = ("Starts %d   ·   Session %s   ·   RightShift hides"):format(S.starts, session)
end

-- Watchdog ------------------------------------------------------------------------------

-- One tick while the switch is ON. Returns kind ("ok"/"wait"/"error"), headline, detail.
local function step()
	local now = os.clock()
	local running = workspace:GetAttribute(ATTR)

	if running ~= nil then
		S.runningSince = S.runningSince or now
		if now - S.runningSince > 20 then
			S.quickStops = 0
		end
		if S.choiceName and running ~= S.choiceName then
			toggleGame(running) -- switching eggs: stop now, start the chosen one next tick
			S.runningSince = nil
			return "wait", "Switching eggs", "Moving over to the " .. S.choiceName .. " egg"
		end
		local mode = (hookReady and S.skipAnim) and "instant" or "animated"
		return "ok", "Hatching", ("%s egg · %s"):format(running, mode)
	end

	if S.runningSince then -- it was running last tick and has stopped on its own
		if now - S.runningSince < 20 then
			S.quickStops += 1
			S.backoffUntil = now + math.min(S.quickStops * 5, 30)
		end
		S.runningSince = nil
	end

	if S.quickStops >= 6 then
		S.enabled = false
		S.note = "Auto-hatch kept stopping right after starting. Check the game's messages (coins, storage, locked island)."
		return "error", "Turned off", S.note
	end

	local near = nearestEgg()
	local target = S.choiceName or (near and near.Name)
	if not target then
		return "wait", "No egg nearby", "Walk within " .. REACH .. " studs of an egg."
	end
	if not near or near.Name ~= target then
		return "wait", "Move closer", "Stand next to the " .. target .. " egg."
	end

	local afford = affordability(target)
	if afford == "coins" then
		return "wait", "Waiting for coins", "Not enough for one " .. target .. " egg yet."
	elseif afford == "storage" then
		return "error", "Storage full", "Free up some pet space to keep hatching."
	end
	if now < S.backoffUntil then
		return "wait", "Retrying", ("in %d s"):format(math.ceil(S.backoffUntil - now))
	end

	local ok, err = toggleGame(target)
	if not ok then
		S.quickStops += 1
		S.backoffUntil = now + 5
		return "error", "Start failed", tostring(err)
	end
	if workspace:GetAttribute(ATTR) == target then
		S.starts += 1
		S.runningSince = now
		return "ok", "Starting", target .. " egg"
	end
	S.quickStops += 1 -- the game declined (recap playing, not enough coins, ...)
	S.backoffUntil = now + 3
	return "wait", "Retrying", "The game declined to start."
end

-- Dropdown ------------------------------------------------------------------------------

local function addRow(index, name, priceText, selected, onPick)
	local base = selected and C.HOVER or C.PANEL2
	local row = make("TextButton", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = base,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = index,
	}, dropdown)
	round(row, 6)
	label({
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -78, 1, 0),
		Text = name,
		Font = selected and Enum.Font.GothamBold or Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, row)
	label({
		Position = UDim2.new(1, -68, 0, 0),
		Size = UDim2.fromOffset(60, 28),
		Text = priceText,
		TextColor3 = C.MUTED,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	hover(row, base, C.HOVER)
	row.Activated:Connect(onPick)
end

local setDropdown
setDropdown = function(open)
	if open == dropOpen then
		return
	end
	dropOpen = open
	catcher.Visible = open

	if not open then
		tween(dropdown, { Size = UDim2.new(1, -24, 0, 0) }, 0.12)
		tween(chevron, { Rotation = 0 }, 0.12)
		task.delay(0.13, function()
			if alive and not dropOpen then
				dropdown.Visible = false
			end
		end)
		return
	end

	for _, child in dropdown:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local function pick(name)
		S.choiceName = name
		renderSelector()
		setDropdown(false)
	end
	addRow(0, "Nearest egg", "auto", S.choiceName == nil, function()
		pick(nil)
	end)
	local eggs = listEggs()
	for i, m in eggs do
		local name = m.Name
		addRow(i, name .. " Egg", abbr(eggPrice(name)), S.choiceName == name, function()
			pick(name)
		end)
	end

	local height = math.min((#eggs + 1) * 30 + 8, 148)
	dropdown.Size = UDim2.new(1, -24, 0, 0)
	dropdown.Visible = true
	tween(dropdown, { Size = UDim2.new(1, -24, 0, height) }, 0.15)
	tween(chevron, { Rotation = 180 }, 0.15)
end

-- Controls ------------------------------------------------------------------------------

table.insert(
	connections,
	selector.Activated:Connect(function()
		if LaunchEggConfig then
			setDropdown(not dropOpen)
		end
	end)
)
table.insert(
	connections,
	catcher.Activated:Connect(function()
		setDropdown(false)
	end)
)

table.insert(
	connections,
	toggleRow.Activated:Connect(function()
		elevate()
		if not (EggController and LaunchEggConfig) then
			return
		end
		S.enabled = not S.enabled
		S.enabledAt = S.enabled and os.clock() or nil
		S.quickStops, S.backoffUntil, S.runningSince, S.note = 0, 0, nil, nil
		if not S.enabled then
			stopGame()
		end
		if S.enabled and T.enabled then -- hatching needs you at the egg, so it can't run with Trick or Treat
			T.enabled, T.enabledAt = false, nil
			if renderTotToggle then
				ui(renderTotToggle)
			end
		end
		ui(renderToggle)
	end)
)

table.insert(
	connections,
	skipRow.Activated:Connect(function()
		elevate()
		if hookError then
			return
		end
		S.skipAnim = not S.skipAnim
		saveSettings()
		ui(renderSkip)
	end)
)

-- Delay slider
local sliding = false

local function setDelayFromX(x)
	local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
	S.delay = math.floor(rel * MAX_DELAY * 10 + 0.5) / 10
	saveSettings()
	renderDelay()
end

local function isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

table.insert(
	connections,
	sliderHit.InputBegan:Connect(function(input)
		if isPointer(input) then
			sliding = true
			setDelayFromX(input.Position.X)
		end
	end)
)
table.insert(
	connections,
	UserInputService.InputChanged:Connect(function(input)
		if
			sliding
			and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch)
		then
			setDelayFromX(input.Position.X)
		end
	end)
)
table.insert(
	connections,
	UserInputService.InputEnded:Connect(function(input)
		if sliding and isPointer(input) then
			sliding = false
		end
	end)
)

local currentTab = "hatch"

local function pageHeight()
	return currentTab == "tot" and TOT_H or HATCH_H
end

local function setTab(name)
	currentTab = name
	setDropdown(false)
	hatchPage.Visible = name == "hatch"
	totPage.Visible = name == "tot"
	hatchTab.TextColor3 = name == "hatch" and C.TEXT or C.MUTED
	totTab.TextColor3 = name == "tot" and C.TEXT or C.MUTED
	tween(tabLine, { Position = UDim2.new(name == "hatch" and 0 or 0.5, 12, 1, 0) }, 0.18)
	if not minimized then
		tween(main, { Size = UDim2.fromOffset(WIDTH, pageHeight()) }, 0.2)
	end
end

table.insert(
	connections,
	hatchTab.Activated:Connect(function()
		setTab("hatch")
	end)
)
table.insert(
	connections,
	totTab.Activated:Connect(function()
		setTab("tot")
	end)
)

table.insert(
	connections,
	minBtn.Activated:Connect(function()
		minimized = not minimized
		setDropdown(false)
		minBtn.Text = minimized and "+" or "–"
		tween(main, { Size = UDim2.fromOffset(WIDTH, minimized and MIN_H or pageHeight()) }, 0.2)
	end)
)

-- Dragging + hotkey ---------------------------------------------------------------------

local dragging, dragStart, startPos

table.insert(
	connections,
	titleBar.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging, dragStart, startPos = true, input.Position, main.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
)
table.insert(
	connections,
	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch)
		then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
)
table.insert(
	connections,
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.RightShift then
			main.Visible = not main.Visible
		end
	end)
)

-- Trick or Treat tab --------------------------------------------------------------------
-- The game's TrickOrTreatController knocks by itself when your character stands inside a ready house's
-- zone. This tab moves you into the nearest ready zone, then waits for the visit to finish.
-- Cooldowns come from Data.TrickOrTreat[houseId] (server time when that house is ready again).

local TOTConfig, EventCurrencyConfig

local function makeStatusCard(parent, y)
	local card = make("Frame", {
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, 62),
		BackgroundColor3 = C.PANEL,
		BorderSizePixel = 0,
	}, parent)
	round(card)
	outline(card)
	local d = make("Frame", {
		Position = UDim2.fromOffset(14, 15),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = C.MUTED,
		BorderSizePixel = 0,
	}, card)
	round(d, 5)
	local head = label({
		Position = UDim2.fromOffset(34, 8),
		Size = UDim2.new(1, -44, 0, 18),
		Text = "Loading",
		TextColor3 = C.YELLOW,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)
	local detail = label({
		Position = UDim2.fromOffset(34, 28),
		Size = UDim2.new(1, -44, 0, 30),
		Text = "",
		TextColor3 = C.MUTED,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, card)

	local kind, pulseTween
	local function set(newKind, headline, text)
		head.Text = headline
		detail.Text = text or ""
		if newKind == kind then
			return
		end
		kind = newKind
		if pulseTween then
			pulseTween:Cancel()
			pulseTween = nil
		end
		d.BackgroundTransparency = 0
		local color = KIND_COLOR[newKind] or C.MUTED
		tween(d, { BackgroundColor3 = color }, 0.2)
		tween(head, { TextColor3 = color }, 0.2)
		if newKind == "ok" then
			pulseTween = TweenService:Create(
				d,
				TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ BackgroundTransparency = 0.65 }
			)
			pulseTween:Play()
		end
	end
	local function stop()
		if pulseTween then
			pulseTween:Cancel()
		end
	end
	return set, stop
end

local function makeStats(parent, y, titles)
	local row = make("Frame", {
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, 50),
		BackgroundTransparency = 1,
	}, parent)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 9),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local values = {}
	for i, title in titles do
		local card = make("Frame", {
			Size = UDim2.new(0, 86, 1, 0),
			BackgroundColor3 = C.PANEL,
			BorderSizePixel = 0,
			LayoutOrder = i,
		}, row)
		round(card)
		outline(card)
		label({
			Position = UDim2.fromOffset(10, 8),
			Size = UDim2.new(1, -20, 0, 12),
			Text = title,
			TextColor3 = C.MUTED,
			Font = Enum.Font.GothamBold,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, card)
		values[i] = label({
			Position = UDim2.fromOffset(10, 24),
			Size = UDim2.new(1, -20, 0, 20),
			Text = "-",
			Font = Enum.Font.GothamBold,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, card)
	end
	return values
end

local setTotStatus, stopTotPulse = makeStatusCard(totPage, 46)
local totStats = makeStats(totPage, 118, { "READY", "NEXT", "KNOCKED" })

local totOptions = make("Frame", {
	Position = UDim2.fromOffset(12, 178),
	Size = UDim2.new(1, -24, 0, 46),
	BackgroundColor3 = C.PANEL,
	BorderSizePixel = 0,
}, totPage)
round(totOptions)
outline(totOptions)
local teleRow = make("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "" }, totOptions)
label({
	Position = UDim2.fromOffset(14, 6),
	Size = UDim2.new(1, -80, 0, 16),
	Text = "Teleport to houses",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
}, teleRow)
label({
	Position = UDim2.fromOffset(14, 23),
	Size = UDim2.new(1, -80, 0, 14),
	Text = "Off = walk there (slower)",
	TextColor3 = C.MUTED,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
}, teleRow)
local setTeleSwitch = makeSwitch(teleRow, UDim2.new(1, -54, 0, 12), 40, 22)

local totToggleRow = make("TextButton", {
	Position = UDim2.fromOffset(12, 234),
	Size = UDim2.new(1, -24, 0, 54),
	BackgroundColor3 = C.PANEL,
	AutoButtonColor = false,
	Text = "",
}, totPage)
round(totToggleRow)
outline(totToggleRow)
hover(totToggleRow, C.PANEL, C.HOVER)
label({
	Position = UDim2.fromOffset(14, 9),
	Size = UDim2.new(1, -90, 0, 18),
	Text = "Auto Trick or Treat",
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, totToggleRow)
local totToggleSub = label({
	Position = UDim2.fromOffset(14, 29),
	Size = UDim2.new(1, -90, 0, 16),
	Text = "",
	TextColor3 = C.MUTED,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, totToggleRow)
local setTotSwitch = makeSwitch(totToggleRow, UDim2.new(1, -64, 0.5, -13), 50, 26)
local totFooter = label({
	Position = UDim2.fromOffset(12, 296),
	Size = UDim2.new(1, -24, 0, 16),
	Text = "",
	TextColor3 = C.MUTED,
	TextSize = 10,
}, totPage)

renderTotToggle = function()
	setTotSwitch(T.enabled)
	totToggleSub.Text = T.enabled and "On - visits every ready house" or "Off - knocks on each house for you"
end

local function renderTele()
	setTeleSwitch(T.teleport)
end

-- Logic
local function playerRoot()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp, char:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

-- Same test the game uses to decide you are standing at a door.
local function insideZone(zone, pos)
	local l = zone.CFrame:PointToObjectSpace(pos)
	local h = zone.Size * 0.5
	return math.abs(l.X) <= h.X and math.abs(l.Y) <= h.Y + 3 and math.abs(l.Z) <= h.Z
end

-- The game turns a house sign off while it is knocking / playing the visit, and back on when done.
local function visitInProgress()
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local signs = pg and pg:FindFirstChild("TrickOrTreatSigns")
	if signs then
		for _, sign in signs:GetChildren() do
			if sign:IsA("BillboardGui") and not sign.Enabled then
				return true
			end
		end
	end
	return false
end

local function totScan()
	local cfg = TOTConfig
	local pads = {}
	local folder = workspace:FindFirstChild(cfg.Folder)
	local data = getData()
	local now = workspace:GetServerTimeNow()
	if folder and data then
		local cooldowns = type(data.TrickOrTreat) == "table" and data.TrickOrTreat or {}
		for _, m in folder:GetChildren() do
			if m.Name == cfg.PadName and m:IsA("Model") then
				local id = m:GetAttribute(cfg.HouseAttribute)
				local zone = m:FindFirstChild(cfg.ZoneName)
				if type(id) == "string" and zone and zone:IsA("BasePart") then
					local readyAt = tonumber(cooldowns[id]) or 0
					table.insert(pads, { id = id, zone = zone, readyAt = readyAt, remaining = readyAt - now })
				end
			end
		end
	end
	return pads, folder ~= nil
end

-- One tick while the switch is ON. Returns kind, headline, detail.
local function totStep(pads, hasFolder)
	if EventCurrencyConfig then
		local ok, disabled = pcall(EventCurrencyConfig.IsDisabled, TOTConfig.Currency)
		if ok and disabled then
			return "idle", "Event closed", "Trick or Treat isn't running right now."
		end
	end
	if not hasFolder or #pads == 0 then
		return "wait", "No houses found", "Go to the Trick or Treat area so the houses load."
	end
	local hrp, hum = playerRoot()
	if not hrp then
		return "wait", "Waiting for your character", ""
	end

	local now = os.clock()
	if visitInProgress() then
		T.visitSince = T.visitSince or now
		T.zoneSince = nil
		if now - T.visitSince > 60 then
			return "wait", "Visit is taking long", "Waiting for the game to finish it..."
		end
		return "ok", "Visiting a house", "Collecting the treats..."
	end
	T.visitSince = nil

	local best, bestDist, soonest
	for _, p in pads do
		if p.remaining <= 0 then
			if (T.skipUntil[p.id] or 0) <= now then
				local dist = (p.zone.Position - hrp.Position).Magnitude
				if not bestDist or dist < bestDist then
					best, bestDist = p, dist
				end
			end
		elseif not soonest or p.remaining < soonest then
			soonest = p.remaining
		end
	end
	if not best then
		T.zoneSince = nil
		if soonest then
			return "wait", "Waiting for cooldowns", "Next house is ready in " .. fmtTime(math.ceil(soonest))
		end
		return "wait", "Houses on hold", "Retrying the ones that didn't answer soon."
	end

	if insideZone(best.zone, hrp.Position) then
		T.zoneSince = T.zoneSince or now
		if now - T.zoneSince > 10 then
			T.skipUntil[best.id] = now + 30
			T.zoneSince = nil
			return "wait", "Skipping a house", best.id .. " didn't answer"
		end
		return "ok", "Knocking", best.id
	end
	T.zoneSince = nil

	if T.teleport then
		if now - T.lastMove >= 1.5 then
			T.lastMove = now
			local target = best.zone.CFrame:PointToWorldSpace(Vector3.new(0, best.zone.Size.Y / 2 + 2.5, 0))
			hrp.CFrame = CFrame.new(target) * hrp.CFrame.Rotation
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
		return "ok", "Teleporting", best.id
	end
	if hum then
		hum:MoveTo(best.zone.Position)
	end
	return "ok", "Walking", best.id
end

local function totTick()
	local pads, hasFolder = totScan()
	local ready, soonest = 0, nil
	for _, p in pads do
		if p.remaining <= 0 then
			ready += 1
		elseif not soonest or p.remaining < soonest then
			soonest = p.remaining
		end
		local prev = T.last[p.id]
		if prev and p.readyAt > prev + 1 then
			T.knocked += 1
		end
		T.last[p.id] = p.readyAt
	end

	local kind, headline, detail
	if T.enabled then
		local ok, k, h, d = pcall(totStep, pads, hasFolder)
		if ok then
			kind, headline, detail = k, h, d
		else
			kind, headline, detail = "error", "Error", tostring(k)
		end
	else
		kind, headline = "idle", "Off"
		detail = #pads > 0 and ("%d of %d houses ready"):format(ready, #pads) or "Go to the Trick or Treat area."
	end
	ui(setTotStatus, kind, headline, detail)
	ui(function()
		totStats[1].Text = #pads > 0 and ("%d/%d"):format(ready, #pads) or "-"
		totStats[2].Text = ready > 0 and "now" or (soonest and fmtTime(math.ceil(soonest)) or "-")
		totStats[3].Text = tostring(T.knocked)
		local session = T.enabledAt and fmtTime(os.clock() - T.enabledAt) or "--:--"
		totFooter.Text = ("Session %s   ·   RightShift hides"):format(session)
	end)
end

table.insert(
	connections,
	totToggleRow.Activated:Connect(function()
		elevate()
		if not TOTConfig then
			return
		end
		T.enabled = not T.enabled
		T.enabledAt = T.enabled and os.clock() or nil
		T.zoneSince, T.visitSince, T.skipUntil = nil, nil, {}
		if T.enabled and S.enabled then -- the hatcher would keep pulling you back to the egg
			S.enabled, S.enabledAt = false, nil
			stopGame()
			ui(renderToggle)
		end
		ui(renderTotToggle)
	end)
)
table.insert(
	connections,
	teleRow.Activated:Connect(function()
		elevate()
		T.teleport = not T.teleport
		env.AutoHatchTot = { teleport = T.teleport }
		ui(renderTele)
	end)
)

local function totRun()
	local err
	TOTConfig, err = fetch("Shared", "Game", "TrickOrTreatConfig")
	EventCurrencyConfig = fetch("Shared", "Core", "EventCurrencyConfig")
	if not alive then
		return
	end
	if not TOTConfig then
		ui(setTotStatus, "error", "Unavailable", "Couldn't load the Trick or Treat config: " .. tostring(err))
		return
	end
	local lastErr
	while alive do
		elevate()
		local ok, e = pcall(totTick)
		if not ok and e ~= lastErr then
			lastErr = e
			warn("[AutoHatch] trick or treat loop error: " .. tostring(e))
		end
		task.wait(0.4)
	end
end

renderTotToggle()
renderTele()
setTotStatus("wait", "Loading", "Reading the event config...")

-- Shutdown ------------------------------------------------------------------------------

local function shutdown()
	if not alive then
		return
	end
	alive = false
	if S.enabled then
		stopGame()
	end
	S.enabled = false
	removeHook()
	if pulse then
		pulse:Cancel()
	end
	stopTotPulse()
	for _, c in connections do
		c:Disconnect()
	end
	gui:Destroy()
end

table.insert(connections, closeBtn.Activated:Connect(shutdown))
env.AutoHatch = { shutdown = shutdown }

-- Start up ------------------------------------------------------------------------------

renderToggle()
renderSelector()
renderSkip()
renderDelay()
setState("wait", "Loading", "Hooking into the game's egg modules...")
task.spawn(totRun)

task.spawn(function()
	local err1, err2, err3, err4
	EggController, err1 = fetch("Controllers", "Pets", "EggController")
	LaunchEggConfig, err2 = fetch("Shared", "Pets", "LaunchEggConfig")
	DataController, err3 = fetch("Controllers", "Core", "DataController")
	EggPricing, err4 = fetch("Shared", "Pets", "EggPricing")

	if not alive then
		return
	end
	if not (EggController and LaunchEggConfig) then
		setState("error", "Couldn't load", "The game's egg modules failed: " .. tostring(err1 or err2))
		return
	end
	if not (DataController and EggPricing) then
		warn("[AutoHatch] coin/storage checks disabled: " .. tostring(err3 or err4))
	end

	local hooked, hookErr = installHook()
	hookReady = hooked
	if not hooked then
		hookError = tostring(hookErr)
		warn("[AutoHatch] skip animation / delay unavailable: " .. hookError)
		renderSkip()
		renderDelay()
	end

	local function tick()
		local kind, headline, detail
		if S.enabled then
			local ok, k, h, d = pcall(step)
			if ok then
				kind, headline, detail = k, h, d
			else
				kind, headline, detail = "error", "Error", tostring(k)
			end
			if not S.enabled then -- step() switched itself off
				S.enabledAt = nil
				ui(renderToggle)
			end
		else
			local running = workspace:GetAttribute(ATTR)
			if S.note then
				kind, headline, detail = "error", "Turned off", S.note
			elseif running ~= nil then
				kind, headline, detail = "wait", "Game auto-hatch is on", running .. " egg - this switch is off"
			else
				kind, headline, detail = "idle", "Off", "Pick an egg, stand next to it, then switch on."
			end
		end
		ui(setState, kind, headline, detail)
		ui(updateStats)
	end

	while alive do
		elevate()
		local ok, err = pcall(tick)
		if not ok and err ~= lastUiError then
			lastUiError = err
			warn("[AutoHatch] update loop error: " .. tostring(err))
		end
		task.wait(0.5)
	end
end)
