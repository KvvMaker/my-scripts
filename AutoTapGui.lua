-- AutoTapGui: executor script with two tabs, each with its own delay slider. RightShift hides/shows it.
--   Tap tab:   auto taps.
--     Direct mode fires the game's "Tap" remote itself, so the speed is only limited by the slider.
--     Button mode fires the on-screen Tap button (normal effects/sounds), but the game's own
--     tap-speed cooldown drops taps that come in faster than it allows.
--   Hatch tab: auto hatches eggs. "Nearest" hatches whichever egg pad you are standing at; a picked
--     egg is hatched from wherever you are (unless the server objects).
--     Skip anim: calls the "OpenEgg" remote and acks the reveal itself, so there is no hatch animation
--                (the same two calls EggOpeningController makes). Also lets the script see what you got.
--     Amount:    max eggs per hatch, or 1.
--     Stop on:   stops auto hatching once a hatch contains that rarity or better (needs Skip anim).
--     Running out of currency just waits and retries, so the Tap tab can keep earning meanwhile.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "AutoTapGui"
local MAX_IN_FLIGHT = 8 -- unanswered Tap invokes allowed at once, so a slow server can't pile them up
local STAND_RANGE = 15 -- studs from an egg pad that counts as "standing at" it (same as the game's auto open)
local HATCH_TIMEOUT = 30 -- seconds to wait for one hatch animation before moving on
local HATCH_MAX_FAILURES = 5
-- Open errors the game itself treats as "stop auto opening".
local FATAL_HATCH_ERRORS = { InvalidEgg = true, InvalidCount = true, AreaLocked = true }
local ERROR_TEXT = {
	InsufficientFunds = "Not enough currency - waiting",
	AreaLocked = "Area not unlocked yet",
	InvalidEgg = "Invalid egg",
	InvalidCount = "Invalid amount",
}
-- Rarities the game has special effects for; higher number = rarer.
local RARITY_RANK = { Legendary = 1, Mythical = 2, Secret = 3 }
local STOP_CHOICES = { "Never", "Legendary", "Mythical", "Secret" }

local PANEL_COLOR = Color3.fromRGB(45, 45, 56)
local ON_COLOR = Color3.fromRGB(60, 200, 110)
local OFF_COLOR = Color3.fromRGB(200, 70, 70)
local ACCENT = Color3.fromRGB(88, 130, 255)

-- Re-running the script replaces the previous copy (stops its loops, drops its connections).
local env = (typeof(getgenv) == "function" and getgenv()) or _G
if env.AutoTapGuiCleanup then
	pcall(env.AutoTapGuiCleanup)
end

local function getGuiParent()
	if typeof(gethui) == "function" then
		local ok, ui = pcall(gethui)
		if ok and ui then
			return ui
		end
	end
	local ok = pcall(function()
		return CoreGui:GetChildren()
	end)
	return ok and CoreGui or PlayerGui
end

-- Calling game code can leave a thread with reduced permissions, so threads that do that put the
-- executor identity back afterwards.
local function restoreIdentity()
	local setter = setthreadidentity or setidentity or (syn and syn.set_thread_identity)
	if typeof(setter) == "function" then
		pcall(setter, 8)
	end
end

-- Waits up to `seconds` (at least one frame), returning early once `current()` is false.
local function waitWhile(seconds, current)
	local deadline = os.clock() + seconds
	repeat
		task.wait(math.clamp(deadline - os.clock(), 0, 0.1))
	until not current() or os.clock() >= deadline
end

-- Game hooks -----------------------------------------------------------------------------------
local function try(getter)
	local ok, value = pcall(getter)
	return ok and value or nil
end

local framework = try(function()
	return require(ReplicatedStorage:WaitForChild("ClientFramework", 10))
end)

local Network = framework and try(function()
	return framework.Client.Network
end)
local EggOpeningController = framework and try(function()
	return framework.Client.EggOpeningController
end)
local GameMultipliers = framework and try(function()
	return framework.Calculations.GameMultipliers
end)
-- Same modules the game's own egg code requires, by path.
local RunesConfig = try(function()
	return require(ReplicatedStorage.ClientFramework.Configs.Runes)
end)
local Variables = try(function()
	return require(ReplicatedStorage.ClientFramework.Configs.Variables)
end)

local TapButton
pcall(function()
	TapButton = PlayerGui:WaitForChild("ScreenGui", 10):WaitForChild("HUD"):WaitForChild("Bottom"):WaitForChild("Tap")
end)

local mode = Network and "Direct" or "Button"
local inFlight = 0

-- Returns true if a tap was actually sent.
local function doTap()
	if mode == "Direct" then
		if not Network or inFlight >= MAX_IN_FLIGHT then
			return false
		end
		inFlight += 1
		task.spawn(function()
			pcall(Network.Invoke, "Tap")
			inFlight -= 1
		end)
		return true
	end

	if not TapButton then
		return false
	end
	if typeof(firesignal) == "function" then
		firesignal(TapButton.Activated)
	elseif typeof(getconnections) == "function" then
		for _, conn in ipairs(getconnections(TapButton.Activated)) do
			conn:Fire()
		end
	else
		return false
	end
	return true
end

local function getStandPosition(pad)
	local ok, cf = pcall(function()
		return pad:GetBoundingBox()
	end)
	if ok then
		return cf.Position
	end
	return pad:IsA("BasePart") and pad.Position or nil
end

-- Egg names of every pad in the world, sorted.
local function listEggs()
	local seen, names = {}, {}
	for _, pad in ipairs(CollectionService:GetTagged("EggPad")) do
		local name = pad:GetAttribute("EggName")
		if name and not seen[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- Egg of the pad the character is standing at, if any.
local function nearestEgg()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local best, bestDist = nil, STAND_RANGE
	for _, pad in ipairs(CollectionService:GetTagged("EggPad")) do
		local name = pad:GetAttribute("EggName")
		local pos = name and getStandPosition(pad)
		if pos then
			local d = (root.Position - pos).Magnitude
			if d <= bestDist then
				best, bestDist = name, d
			end
		end
	end
	return best
end

local function maxOpens()
	local n = GameMultipliers and try(function()
		return GameMultipliers.GetMaxEggOpens(LocalPlayer)
	end)
	return typeof(n) == "number" and math.clamp(n, 1, 99) or 1
end

-- Rune config, falling back to the base rune for golden/rainbow variants.
local function runeInfo(name)
	if not RunesConfig then
		return nil
	end
	local info = RunesConfig[name]
	if not info and Variables then
		local base = try(function()
			return Variables.GetBaseName(name)
		end)
		info = base and RunesConfig[base]
	end
	return info
end

-- GUI helpers ----------------------------------------------------------------------------------
local function new(class, props)
	local inst = Instance.new(class)
	local parent = props.Parent
	props.Parent = nil
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function corner(inst, radius)
	new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = inst })
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function newButton(parent, props)
	props.BackgroundColor3 = props.BackgroundColor3 or PANEL_COLOR
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextSize = props.TextSize or 13
	props.TextColor3 = Color3.fromRGB(230, 230, 240)
	props.Parent = parent
	local button = new("TextButton", props)
	corner(button, 8)
	return button
end

local function newToggleButton(parent, y)
	local button = newButton(parent, {
		Size = UDim2.new(1, -24, 0, 36),
		Position = UDim2.fromOffset(12, y),
		BackgroundColor3 = OFF_COLOR,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor3 = Color3.new(1, 1, 1),
	})
	button.TextColor3 = Color3.new(1, 1, 1)
	return button
end

local function newStatusLabel(parent, y)
	return new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 20),
		Position = UDim2.fromOffset(12, y),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(170, 170, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		Parent = parent,
	})
end

local alive = true -- false once the window is closed; every loop checks it
local activeSlider -- the slider currently being dragged

-- Label at y, slider below it, min/max captions under that (about 64px tall in total).
-- The track uses a squared mapping so the low end, where small steps matter most, gets more room.
local function makeSlider(parent, y, minV, maxV, step, startV, labelFor, minText, maxText)
	local slider = { value = startV }

	local label = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.fromOffset(12, y),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(230, 230, 240),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = parent,
	})
	-- The hit area is taller than the track so the slider is easy to grab.
	local hit = new("TextButton", {
		Size = UDim2.new(1, -24, 0, 28),
		Position = UDim2.fromOffset(12, y + 20),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	})
	local track = new("Frame", {
		Size = UDim2.new(1, 0, 0, 8),
		Position = UDim2.new(0, 0, 0.5, -4),
		BackgroundColor3 = Color3.fromRGB(50, 50, 62),
		BorderSizePixel = 0,
		Parent = hit,
	})
	corner(track, 4)
	local fill = new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
		Parent = track,
	})
	corner(fill, 4)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = track,
	})
	corner(knob, 9)

	for _, caption in ipairs({
		{ minText, Enum.TextXAlignment.Left },
		{ maxText, Enum.TextXAlignment.Right },
	}) do
		new("TextLabel", {
			Size = UDim2.new(1, -24, 0, 14),
			Position = UDim2.fromOffset(12, y + 50),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = Color3.fromRGB(140, 140, 155),
			TextXAlignment = caption[2],
			Text = caption[1],
			Parent = parent,
		})
	end

	local function render()
		local a = math.sqrt((slider.value - minV) / (maxV - minV))
		fill.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.fromScale(a, 0.5)
		label.Text = labelFor(slider.value)
	end

	function slider.setFromX(x)
		local a = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		local raw = minV + (maxV - minV) * a * a
		slider.value = math.clamp(math.round(raw / step) * step, minV, maxV)
		render()
	end

	hit.InputBegan:Connect(function(input)
		if isPress(input) then
			activeSlider = slider
			slider.setFromX(input.Position.X)
		end
	end)

	render()
	return slider
end

-- Window and tabs ------------------------------------------------------------------------------
local TAP_PAGE_HEIGHT, HATCH_PAGE_HEIGHT = 186, 266
local PAGE_TOP = 70

local gui = new("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, Parent = getGuiParent() })

local frame = new("Frame", {
	Size = UDim2.fromOffset(280, PAGE_TOP + TAP_PAGE_HEIGHT),
	Position = UDim2.new(0.5, -140, 0.5, -128),
	BackgroundColor3 = Color3.fromRGB(28, 28, 34),
	BorderSizePixel = 0,
	Active = true,
	Parent = gui,
})
corner(frame, 10)
new("UIStroke", { Color = Color3.fromRGB(70, 70, 85), Parent = frame })

local titleBar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	Parent = frame,
})
new("TextLabel", {
	Size = UDim2.new(1, -40, 1, 0),
	Position = UDim2.fromOffset(14, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = Color3.new(1, 1, 1),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Auto Tapper",
	Parent = titleBar,
})
local closeButton = newButton(titleBar, {
	Size = UDim2.fromOffset(26, 26),
	Position = UDim2.new(1, -32, 0, 4),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	Text = "X",
})

local tabBar = new("Frame", {
	Size = UDim2.new(1, -24, 0, 26),
	Position = UDim2.fromOffset(12, 38),
	BackgroundTransparency = 1,
	Parent = frame,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	Parent = tabBar,
})

local pages, tabButtons, pageHeights = {}, {}, {}

-- The window grows/shrinks to fit the page.
local function selectTab(name)
	for tabName, page in pairs(pages) do
		page.Visible = tabName == name
		TweenService:Create(tabButtons[tabName], TweenInfo.new(0.15), {
			BackgroundColor3 = tabName == name and ACCENT or PANEL_COLOR,
		}):Play()
	end
	TweenService:Create(frame, TweenInfo.new(0.15), {
		Size = UDim2.fromOffset(280, PAGE_TOP + pageHeights[name]),
	}):Play()
end

local function addTab(name, order, height)
	local button = newButton(tabBar, {
		Size = UDim2.new(0.5, -3, 1, 0),
		LayoutOrder = order,
		Font = Enum.Font.GothamBold,
		Text = name,
	})
	button.TextColor3 = Color3.new(1, 1, 1)
	local page = new("Frame", {
		Size = UDim2.new(1, 0, 1, -PAGE_TOP),
		Position = UDim2.fromOffset(0, PAGE_TOP),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = frame,
	})
	pages[name], tabButtons[name], pageHeights[name] = page, button, height
	button.Activated:Connect(function()
		selectTab(name)
	end)
	return page
end

local tapPage = addTab("Tap", 1, TAP_PAGE_HEIGHT)
local hatchPage = addTab("Hatch", 2, HATCH_PAGE_HEIGHT)

-- Tap tab --------------------------------------------------------------------------------------
local tapToggle = newToggleButton(tapPage, 6)
local tapDelay = makeSlider(tapPage, 54, 0.01, 2, 0.01, 0.1, function(v)
	return ("Delay: %.2fs  (%.1f taps/s)"):format(v, 1 / v)
end, "0.01s (fast)", "2s (slow)")

local modeButton = newButton(tapPage, {
	Size = UDim2.new(1, -24, 0, 28),
	Position = UDim2.fromOffset(12, 126),
})
local tapStatus = newStatusLabel(tapPage, 160)

local tapping = false
local tapCount = 0

local function renderTap()
	tapToggle.Text = tapping and "Auto Tap: ON" or "Auto Tap: OFF"
	TweenService:Create(tapToggle, TweenInfo.new(0.15), { BackgroundColor3 = tapping and ON_COLOR or OFF_COLOR }):Play()
	modeButton.Text = mode == "Direct" and "Mode: Direct (remote)" or "Mode: Button (game tap)"
	if not tapping then
		tapStatus.Text = (Network or TapButton) and "Idle" or "No tap hook found - wrong game?"
	end
end

tapToggle.Activated:Connect(function()
	if not (Network or TapButton) then
		renderTap()
		return
	end
	tapping = not tapping
	renderTap()
end)

modeButton.Activated:Connect(function()
	if mode == "Direct" and TapButton then
		mode = "Button"
	elseif mode == "Button" and Network then
		mode = "Direct"
	end
	renderTap()
end)

-- Hatch tab ------------------------------------------------------------------------------------
local hatchToggle = newToggleButton(hatchPage, 6)

local eggRow = new("Frame", {
	Size = UDim2.new(1, -24, 0, 28),
	Position = UDim2.fromOffset(12, 48),
	BackgroundTransparency = 1,
	Parent = hatchPage,
})
local prevEgg = newButton(eggRow, { Size = UDim2.fromOffset(32, 28), Font = Enum.Font.GothamBold, TextSize = 14, Text = "<" })
local nextEgg = newButton(eggRow, {
	Size = UDim2.fromOffset(32, 28),
	Position = UDim2.new(1, -32, 0, 0),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	Text = ">",
})
local eggLabel = new("TextLabel", {
	Size = UDim2.new(1, -76, 1, 0),
	Position = UDim2.fromOffset(38, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	TextColor3 = Color3.fromRGB(230, 230, 240),
	TextTruncate = Enum.TextTruncate.AtEnd,
	Text = "",
	Parent = eggRow,
})

local hatchDelay = makeSlider(hatchPage, 84, 0, 5, 0.05, 0.2, function(v)
	return ("Pause between hatches: %.2fs"):format(v)
end, "0s", "5s")

local optionRow = new("Frame", {
	Size = UDim2.new(1, -24, 0, 28),
	Position = UDim2.fromOffset(12, 154),
	BackgroundTransparency = 1,
	Parent = hatchPage,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	Parent = optionRow,
})
local skipButton = newButton(optionRow, { Size = UDim2.new(0.5, -3, 1, 0), LayoutOrder = 1, TextSize = 12 })
local amountButton = newButton(optionRow, { Size = UDim2.new(0.5, -3, 1, 0), LayoutOrder = 2, TextSize = 12 })
local stopButton = newButton(hatchPage, {
	Size = UDim2.new(1, -24, 0, 28),
	Position = UDim2.fromOffset(12, 188),
	TextSize = 12,
})

local hatchStatus = newStatusLabel(hatchPage, 222)
local hatchResults = newStatusLabel(hatchPage, 242)

local eggChoice = "Nearest" -- "Nearest" = whichever egg pad you are standing at
local hatching = false
local hatchRun = 0 -- bumped on every start/stop so an old loop can tell it was replaced
local skipAnimation = false
local amountMax = true
local stopChoice = "Never"
local eggsOpened = 0
local rarityCounts = { Legendary = 0, Mythical = 0, Secret = 0 }

-- The hatch thread calls game code, so it never touches the GUI itself: it writes these and the
-- UI loop at the bottom copies them into the labels.
local hatchStatusText, hatchResultsText = "", ""
local function setHatchStatus(text)
	hatchStatusText = text
end

local function renderEgg()
	eggLabel.Text = "Egg: " .. eggChoice
end

local function renderResults()
	hatchResultsText = skipAnimation
			and ("Legendary %d | Mythical %d | Secret %d"):format(rarityCounts.Legendary, rarityCounts.Mythical, rarityCounts.Secret)
		or "Results are only tracked with Skip anim"
end

local function renderOptions()
	skipButton.Text = "Skip anim: " .. (skipAnimation and "ON" or "OFF")
	skipButton.BackgroundColor3 = skipAnimation and ACCENT or PANEL_COLOR
	amountButton.Text = "Amount: " .. (amountMax and "Max" or "1")
	stopButton.Text = "Stop on: " .. (stopChoice == "Never" and "Never" or stopChoice .. " or rarer")
	renderResults()
end

local function renderHatch()
	hatchToggle.Text = hatching and "Auto Hatch: ON" or "Auto Hatch: OFF"
	TweenService:Create(hatchToggle, TweenInfo.new(0.15), { BackgroundColor3 = hatching and ON_COLOR or OFF_COLOR }):Play()
end

local function setHatching(on)
	hatching = on
	hatchRun += 1
	renderHatch()
end

-- For the hatch thread: no GUI access, the UI loop redraws the toggle.
local function stopHatching()
	hatching = false
	hatchRun += 1
end

local function cycleEgg(step)
	local choices = { "Nearest" }
	for _, name in ipairs(listEggs()) do
		table.insert(choices, name)
	end
	local index = table.find(choices, eggChoice) or 1
	eggChoice = choices[(index - 1 + step) % #choices + 1]
	renderEgg()
end

-- Counts a hatch's runes; returns a description of the first one at or above stopRank, if any.
local function recordRunes(runes, stopRank)
	local hit
	for _, name in ipairs(runes) do
		local info = runeInfo(name)
		local rarity = info and info.Rarity
		if rarity and rarityCounts[rarity] then
			rarityCounts[rarity] += 1
		end
		local rank = rarity and RARITY_RANK[rarity]
		if stopRank and rank and rank >= stopRank and not hit then
			hit = ("%s (%s)"):format(info.Name or name, rarity)
		end
	end
	return hit
end

-- Opens `count` eggs once. Returns ok, err, runes (runes only when the animation is skipped).
local function openEggs(egg, count, current)
	if skipAnimation and Network then
		local called, ok, err, runes, token = pcall(Network.Invoke, "OpenEgg", egg, count)
		if not called then
			return false, ok
		end
		if ok and token then
			-- The game's own session cleanup sends this once the reveal animation is over.
			pcall(Network.Fire, "EggHatchRevealed", token)
		end
		return ok, err, runes
	end

	local done = false
	local called, ok, err = pcall(EggOpeningController.Open, egg, count, function()
		done = true
	end, true)
	if not called then
		return false, ok
	end
	if ok then
		local deadline = os.clock() + HATCH_TIMEOUT
		while not done and current() and os.clock() < deadline do
			task.wait()
		end
	end
	return ok, err
end

local function hatchLoop(run)
	local failures = 0
	local function current()
		return alive and hatching and hatchRun == run
	end

	while current() do
		restoreIdentity()
		local egg = eggChoice == "Nearest" and nearestEgg() or eggChoice
		if not egg then
			setHatchStatus("Stand next to an egg, or pick one")
			waitWhile(0.5, current)
			continue
		end

		local count = amountMax and maxOpens() or 1
		setHatchStatus(("Opening %d x %s..."):format(count, egg))
		local ok, err, runes = openEggs(egg, count, current)
		restoreIdentity() -- the game's code just ran on this thread

		if ok then
			failures = 0
			eggsOpened += count
			setHatchStatus(("Hatched %d x %s (%d total)"):format(count, egg, eggsOpened))
			local hit = typeof(runes) == "table" and recordRunes(runes, RARITY_RANK[stopChoice])
			renderResults()
			if hit then
				setHatchStatus("Stopped: got " .. hit)
				break
			end
			waitWhile(hatchDelay.value, current)
		else
			setHatchStatus(ERROR_TEXT[err] or ("Can't hatch: " .. tostring(err)))
			if err == "InsufficientFunds" then
				-- Keep waiting; the Tap tab may be earning the currency in the meantime.
				waitWhile(2, current)
			else
				failures += 1
				if FATAL_HATCH_ERRORS[err] or failures >= HATCH_MAX_FAILURES then
					break
				end
				waitWhile(1.5, current)
			end
		end
	end

	-- Stopped on its own (error or stop-on rarity) rather than by the toggle: flip the button back off.
	if hatchRun == run and alive then
		stopHatching()
	end
end

-- The toggle only flips state; the worker loop at the bottom runs hatchLoop.
hatchToggle.Activated:Connect(function()
	if not EggOpeningController then
		setHatchStatus("Egg controller not found - wrong game?")
		return
	end
	if hatching then
		setHatching(false)
		setHatchStatus("Idle")
		return
	end
	setHatching(true)
end)

prevEgg.Activated:Connect(function()
	cycleEgg(-1)
end)
nextEgg.Activated:Connect(function()
	cycleEgg(1)
end)

skipButton.Activated:Connect(function()
	if not Network then
		setHatchStatus("Network module not found")
		return
	end
	skipAnimation = not skipAnimation
	if not skipAnimation then
		stopChoice = "Never" -- can't see the results without skipping
	end
	renderOptions()
end)

amountButton.Activated:Connect(function()
	amountMax = not amountMax
	renderOptions()
end)

stopButton.Activated:Connect(function()
	if not Network then
		setHatchStatus("Network module not found")
		return
	end
	stopChoice = STOP_CHOICES[(table.find(STOP_CHOICES, stopChoice) or 1) % #STOP_CHOICES + 1]
	if stopChoice ~= "Never" then
		skipAnimation = true -- the results are only visible when skipping
	end
	renderOptions()
end)

-- Dragging the window and the sliders ---------------------------------------------------------
local draggingWindow = false
local dragStart, startPos

titleBar.InputBegan:Connect(function(input)
	if isPress(input) then
		draggingWindow = true
		dragStart = input.Position
		startPos = frame.Position
	end
end)

local connections = {}

table.insert(connections, UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	if draggingWindow then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	elseif activeSlider then
		activeSlider.setFromX(input.Position.X)
	end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input)
	if isPress(input) then
		draggingWindow, activeSlider = false, nil
	end
end))

table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end))

-- Cleanup --------------------------------------------------------------------------------------
local function cleanup()
	alive = false
	tapping = false
	hatching = false
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	gui:Destroy()
	if env.AutoTapGuiCleanup == cleanup then
		env.AutoTapGuiCleanup = nil
	end
end
env.AutoTapGuiCleanup = cleanup
closeButton.Activated:Connect(cleanup)

-- Tap loop -------------------------------------------------------------------------------------
task.spawn(function()
	local lastStatus = 0
	while alive do
		if tapping then
			if doTap() then
				tapCount += 1
			end
			local now = os.clock()
			if now - lastStatus > 0.25 then
				lastStatus = now
				tapStatus.Text = ("Tapping... %d sent"):format(tapCount)
			end
			task.wait(tapDelay.value)
		else
			task.wait(0.1)
		end
	end
end)

-- Hatch loop: started from this thread (like the tap loop) rather than from a button callback.
-- A failure shows up in the output with a traceback instead of silently killing the thread.
task.spawn(function()
	restoreIdentity()
	while alive do
		if hatching then
			local run = hatchRun
			local ok, err = xpcall(hatchLoop, function(e)
				return debug.traceback(tostring(e), 2)
			end, run)
			if not ok then
				warn("AutoTapGui hatch error:\n" .. tostring(err))
				setHatchStatus("Error: " .. tostring(err):match("[^\n]*"))
				if hatchRun == run then
					stopHatching()
				end
			end
		else
			task.wait(0.1)
		end
	end
end)

-- UI loop: the only place the hatch tab's status labels and toggle get redrawn from the hatch side.
task.spawn(function()
	local shownHatching = hatching
	while alive do
		if hatchStatus.Text ~= hatchStatusText then
			hatchStatus.Text = hatchStatusText
		end
		if hatchResults.Text ~= hatchResultsText then
			hatchResults.Text = hatchResultsText
		end
		if shownHatching ~= hatching then
			shownHatching = hatching
			renderHatch()
		end
		task.wait(0.1)
	end
end)

renderTap()
renderEgg()
renderHatch()
renderOptions()
setHatchStatus(EggOpeningController and "Idle" or "Egg controller not found - wrong game?")
selectTab("Tap")
