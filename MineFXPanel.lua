--[[
	MineFX Panel

	Standalone LocalScript (StarterPlayer > StarterPlayerScripts, or run it client-side).
	Builds its own ScreenGui at runtime and does not modify the MineFX script.

	Tabs
	  Stats     live counters fed by the ReplicatedStorage.Remotes.MineFX RemoteEvent
	  Log       scrolling event feed with per-type filters
	  Bag       what the game's sell screen would list; pick rows and sell (fires MineSellItems)
	  Settings  toggles for the LagFix_* attributes the MineFX script reads from ReplicatedStorage,
	            plus a panel scale slider

	RightShift hides / shows the panel.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "MineFXPanel"
local TOGGLE_KEY = Enum.KeyCode.RightShift
local MAX_LOG_LINES = 60
local MAX_QUEUE = 200
local TITLE_H = 36
local TAB_H = 34

local C = {
	Bg = Color3.fromRGB(22, 24, 30),
	Panel = Color3.fromRGB(30, 33, 41),
	Row = Color3.fromRGB(40, 44, 55),
	Line = Color3.fromRGB(58, 63, 78),
	Text = Color3.fromRGB(235, 238, 245),
	Sub = Color3.fromRGB(150, 157, 172),
	Accent = Color3.fromRGB(255, 190, 60),
	Off = Color3.fromRGB(78, 84, 100),
	Good = Color3.fromRGB(90, 205, 125),
	Bad = Color3.fromRGB(235, 90, 90),
	Sell = Color3.fromRGB(38, 148, 84),
	PickedBg = Color3.fromRGB(38, 62, 50),
	Blue = Color3.fromRGB(110, 170, 255),
	Pink = Color3.fromRGB(235, 130, 235),
}

-- Replace a previous copy of the panel cleanly.
local previous = PlayerGui:FindFirstChild(GUI_NAME)
if previous then
	previous:Destroy()
end

local connections = {}
local function track(connection)
	connections[#connections + 1] = connection
	return connection
end

---------------------------------------------------------------------------
-- Small UI helpers
---------------------------------------------------------------------------

local function create(className, props, children)
	local inst = Instance.new(className)
	local parent = props.Parent
	for key, value in pairs(props) do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color, thickness)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function padding(amount)
	local p = UDim.new(0, amount)
	return create("UIPadding", { PaddingTop = p, PaddingBottom = p, PaddingLeft = p, PaddingRight = p })
end

local function list(gap)
	return create("UIListLayout", {
		Padding = UDim.new(0, gap or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

local function label(props)
	local merged = {
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextColor3 = C.Text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for key, value in pairs(props) do
		merged[key] = value
	end
	return create("TextLabel", merged)
end

local function counter()
	local n = 0
	return function()
		n += 1
		return n
	end
end

local SWITCH_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function makeSwitch(parent, initial, onChanged)
	local value = initial
	local track_ = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(40, 22),
		BackgroundColor3 = initial and C.Accent or C.Off,
		BorderSizePixel = 0,
		Parent = parent,
	}, { corner(11) })
	local knob = create("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = initial and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = track_,
	}, { corner(8) })

	-- silent = true updates the visuals without firing onChanged (used to mirror outside changes)
	local function set(newValue, silent)
		value = newValue
		TweenService:Create(track_, SWITCH_TWEEN, { BackgroundColor3 = value and C.Accent or C.Off }):Play()
		TweenService:Create(knob, SWITCH_TWEEN, {
			Position = value and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8),
		}):Play()
		if not silent then
			onChanged(value)
		end
	end

	track_.Activated:Connect(function()
		set(not value)
	end)
	return track_, set
end

local function makeToggleRow(parent, title, desc, initial, onChanged, order)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Row,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	}, { corner(8), padding(10) })
	local text = create("Frame", {
		Size = UDim2.new(1, -56, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = row,
	}, { list(2) })
	label({
		Text = title,
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
		Parent = text,
	})
	label({
		Text = desc,
		TextSize = 11,
		TextColor3 = C.Sub,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = text,
	})
	local switch, set = makeSwitch(row, initial, onChanged)
	switch.AnchorPoint = Vector2.new(1, 0.5)
	switch.Position = UDim2.new(1, 0, 0.5, 0)
	return set
end

local function makeButton(parent, text, order, onClick)
	local button = create("TextButton", {
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = C.Text,
		BackgroundColor3 = C.Row,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = order,
		Parent = parent,
	}, { corner(8), stroke(C.Line) })
	button.Activated:Connect(onClick)
	return button
end

-- momentary = true makes it a plain button: it never latches on, it just calls onChanged()
local function makeChip(parent, text, width, initial, onChanged, order, momentary)
	local on = initial
	local chip = create("TextButton", {
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		AutoButtonColor = false,
		Size = UDim2.fromOffset(width, 22),
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	}, { corner(11) })
	local function paint()
		chip.BackgroundColor3 = on and C.Accent or C.Row
		chip.TextColor3 = on and C.Bg or C.Sub
	end
	paint()
	chip.Activated:Connect(function()
		if momentary then
			onChanged()
			return
		end
		on = not on
		paint()
		onChanged(on)
	end)
	return chip
end

local function makeSlider(parent, title, min, max, initial, format, onChanged, order)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 58),
		BackgroundColor3 = C.Row,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	}, { corner(8), padding(10) })
	label({
		Text = title,
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(0.6, 0, 0, 16),
		Parent = row,
	})
	local valueLabel = label({
		Font = Enum.Font.GothamBold,
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0.4, 0, 0, 16),
		Position = UDim2.new(0.6, 0, 0, 0),
		Parent = row,
	})
	local hit = create("TextButton", {
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0, 0, 1, -22),
		Parent = row,
	})
	local bar = create("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 0.5, -3),
		BackgroundColor3 = C.Off,
		BorderSizePixel = 0,
		Parent = hit,
	}, { corner(3) })
	local fill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Parent = bar,
	}, { corner(3) })
	local knob = create("Frame", {
		Size = UDim2.fromOffset(14, 14),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = bar,
	}, { corner(7) })

	local function setAlpha(alpha)
		alpha = math.clamp(alpha, 0, 1)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		local value = min + (max - min) * alpha
		valueLabel.Text = format(value)
		onChanged(value)
	end
	local function fromInput(input)
		setAlpha((input.Position.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1))
	end

	local dragging = false
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			fromInput(input)
		end
	end)
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			fromInput(input)
		end
	end))

	setAlpha((initial - min) / (max - min))
end

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function abbr(n)
	n = tonumber(n) or 0
	if n ~= n or n == math.huge then
		return tostring(n)
	end
	if math.abs(n) < 1000 then
		return tostring(math.floor(n + 0.5))
	end
	local index = math.min(math.floor(math.log10(math.abs(n)) / 3), #SUFFIXES - 1)
	local scaled = n / 10 ^ (index * 3)
	if math.abs(scaled) >= 999.95 and index < #SUFFIXES - 1 then
		scaled /= 1000
		index += 1
	end
	return (string.format("%.1f", scaled):gsub("%.0$", "")) .. SUFFIXES[index + 1]
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local startClock = os.clock()
local state = {
	mineOnly = true,
	paused = false,
	filters = { hit = false, ["break"] = true, found = true, sold = true, other = true },
}
local stats
local statsDirty = true

local function resetStats()
	stats = {
		hits = 0, crits = 0, damage = 0, best = 0,
		breaks = 0, ore = 0, finds = 0, colossi = 0, sales = 0,
		lastFind = "-", lastSale = "-",
	}
	statsDirty = true
end
resetStats()

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
local WIDTH = math.min(460, viewport.X - 20)
local HEIGHT = math.min(400, viewport.Y - 40)

local gui = create("ScreenGui", {
	Name = GUI_NAME,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 100,
	IgnoreGuiInset = true,
})

local window = create("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(WIDTH, HEIGHT),
	Position = UDim2.new(0.5, -math.floor(WIDTH / 2), 0.5, -math.floor(HEIGHT / 2)),
	BackgroundColor3 = C.Bg,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Parent = gui,
}, { corner(10), stroke(C.Line) })
local uiScale = create("UIScale", { Scale = 1, Parent = window })

local titleBar = create("Frame", {
	Name = "TitleBar",
	Size = UDim2.new(1, 0, 0, TITLE_H),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	Parent = window,
}, { corner(10) })
create("Frame", { -- squares off the bottom corners of the rounded title bar
	Size = UDim2.new(1, 0, 0, 10),
	Position = UDim2.new(0, 0, 1, -10),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	Parent = titleBar,
})
label({
	Text = "MineFX Panel",
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(0, 130, 1, 0),
	Parent = titleBar,
})
local status = label({
	Text = "● connecting",
	TextSize = 11,
	TextColor3 = C.Sub,
	TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.new(1, -208, 0, 0),
	Size = UDim2.new(0, 136, 1, 0),
	Parent = titleBar,
})

local function titleButton(text, offsetX)
	return create("TextButton", {
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = C.Sub,
		BackgroundColor3 = C.Row,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(26, 24),
		Position = UDim2.new(1, offsetX, 0.5, -12),
		Parent = titleBar,
	}, { corner(6) })
end
local minimizeButton = titleButton("–", -64)
local closeButton = titleButton("×", -34)

local body = create("Frame", {
	Name = "Body",
	Size = UDim2.new(1, 0, 1, -TITLE_H),
	Position = UDim2.fromOffset(0, TITLE_H),
	BackgroundTransparency = 1,
	Parent = window,
})
local tabBar = create("Frame", {
	Size = UDim2.new(1, 0, 0, TAB_H),
	BackgroundTransparency = 1,
	Parent = body,
})
local tabHolder = create("Frame", {
	Size = UDim2.new(1, -130, 1, 0),
	BackgroundTransparency = 1,
	Parent = tabBar,
}, {
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
	create("UIPadding", { PaddingLeft = UDim.new(0, 10) }),
})
local pagesHolder = create("Frame", {
	Size = UDim2.new(1, 0, 1, -TAB_H),
	Position = UDim2.fromOffset(0, TAB_H),
	BackgroundTransparency = 1,
	Parent = body,
})

local pages, tabButtons = {}, {}

local function selectTab(name)
	for pageName, page in pairs(pages) do
		page.Visible = pageName == name
	end
	for buttonName, button in pairs(tabButtons) do
		local active = buttonName == name
		button.BackgroundColor3 = active and C.Accent or C.Row
		button.TextColor3 = active and C.Bg or C.Sub
	end
end

local function addTab(name, order)
	local button = create("TextButton", {
		Text = name,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		AutoButtonColor = false,
		Size = UDim2.fromOffset(56, 26),
		BackgroundColor3 = C.Row,
		TextColor3 = C.Sub,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = tabHolder,
	}, { corner(6) })
	tabButtons[name] = button
	button.Activated:Connect(function()
		selectTab(name)
	end)
end

local function makeScrollPage(name)
	local page = create("ScrollingFrame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Accent,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = pagesHolder,
	}, { padding(10), list(8) })
	pages[name] = page
	return page
end

local function makeHeader(parent, text, order)
	return label({
		Text = string.upper(text),
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = C.Sub,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = order,
		Parent = parent,
	})
end

-- "Mine only" switch pinned to the right of the tab bar
do
	local holder = create("Frame", {
		Size = UDim2.fromOffset(112, TAB_H),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		BackgroundTransparency = 1,
		Parent = tabBar,
	})
	label({
		Text = "Mine only",
		TextSize = 11,
		TextColor3 = C.Sub,
		Size = UDim2.new(1, -46, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = holder,
	})
	local switch = makeSwitch(holder, state.mineOnly, function(value)
		state.mineOnly = value
	end)
	switch.AnchorPoint = Vector2.new(1, 0.5)
	switch.Position = UDim2.new(1, 0, 0.5, 0)
end

---------------------------------------------------------------------------
-- Stats page
---------------------------------------------------------------------------

addTab("Stats", 1)
addTab("Log", 2)
addTab("Bag", 3)
addTab("Settings", 4)

local statsPage = makeScrollPage("Stats")
local statsOrder = counter()
makeHeader(statsPage, "Session", statsOrder())

local CARD_DEFS = {
	{ "hits", "Hits" }, { "crits", "Crits" }, { "critRate", "Crit rate" },
	{ "damage", "Total damage" }, { "best", "Best hit" }, { "breaks", "Nodes broken" },
	{ "ore", "Ore dropped" }, { "finds", "Finds" }, { "colossi", "Colossus kills" },
	{ "sales", "Sales" }, { "lastFind", "Last find" }, { "lastSale", "Last sale" },
}
local cardValues = {}

local grid = create("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = statsOrder(),
	Parent = statsPage,
}, {
	create("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -6, 0, 54),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})
for index, def in ipairs(CARD_DEFS) do
	local card = create("Frame", {
		BackgroundColor3 = C.Row,
		BorderSizePixel = 0,
		LayoutOrder = index,
		Parent = grid,
	}, { corner(8) })
	label({
		Text = def[2],
		TextSize = 11,
		TextColor3 = C.Sub,
		Position = UDim2.fromOffset(10, 7),
		Size = UDim2.new(1, -20, 0, 14),
		Parent = card,
	})
	cardValues[def[1]] = label({
		Text = "0",
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(10, 24),
		Size = UDim2.new(1, -20, 0, 22),
		Parent = card,
	})
end

local function refreshStats()
	local s = stats
	local view = {
		hits = abbr(s.hits),
		crits = abbr(s.crits),
		critRate = s.hits > 0 and string.format("%.1f%%", s.crits / s.hits * 100) or "-",
		damage = abbr(s.damage),
		best = abbr(s.best),
		breaks = abbr(s.breaks),
		ore = abbr(s.ore),
		finds = abbr(s.finds),
		colossi = abbr(s.colossi),
		sales = abbr(s.sales),
		lastFind = s.lastFind,
		lastSale = s.lastSale,
	}
	for key, text in pairs(view) do
		cardValues[key].Text = text
	end
end

makeButton(statsPage, "Reset stats", statsOrder(), function()
	resetStats()
end)

---------------------------------------------------------------------------
-- Log page
---------------------------------------------------------------------------

local logPage = create("Frame", {
	Name = "Log",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = pagesHolder,
})
pages["Log"] = logPage

local toolbar = create("Frame", {
	Size = UDim2.new(1, 0, 0, 26),
	BackgroundTransparency = 1,
	Parent = logPage,
}, {
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
	create("UIPadding", { PaddingLeft = UDim.new(0, 10) }),
})
local logScroll = create("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -36),
	Position = UDim2.fromOffset(10, 30),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = C.Accent,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = logPage,
}, {
	corner(8),
	create("UIPadding", {
		PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	}),
	list(1),
})

local logQueue, logLabels = {}, {}
local logSeq = 0
local stickBottom = false

local function pushLog(text, color)
	if #logQueue >= MAX_QUEUE then
		table.remove(logQueue, 1)
	end
	logQueue[#logQueue + 1] = {
		text = string.format("%7.1fs  %s", os.clock() - startClock, text),
		color = color,
	}
end

local function flushLog()
	if stickBottom then
		stickBottom = false
		logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
	end
	if #logQueue == 0 then
		return
	end
	local atBottom = logScroll.CanvasPosition.Y + logScroll.AbsoluteWindowSize.Y >= logScroll.AbsoluteCanvasSize.Y - 30
	for _, entry in ipairs(logQueue) do
		logSeq += 1
		logLabels[#logLabels + 1] = label({
			Text = entry.text,
			Font = Enum.Font.Code,
			TextSize = 12,
			TextColor3 = entry.color,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 16),
			LayoutOrder = logSeq,
			Parent = logScroll,
		})
	end
	table.clear(logQueue)
	while #logLabels > MAX_LOG_LINES do
		table.remove(logLabels, 1):Destroy()
	end
	stickBottom = atBottom
end

local chipOrder = counter()
for _, def in ipairs({
	{ "hit", "Hit", 38 }, { "break", "Break", 46 }, { "found", "Found", 46 },
	{ "sold", "Sold", 40 }, { "other", "Other", 44 },
}) do
	makeChip(toolbar, def[2], def[3], state.filters[def[1]], function(on)
		state.filters[def[1]] = on
	end, chipOrder())
end
makeChip(toolbar, "Pause", 48, false, function(on)
	state.paused = on
end, chipOrder())
makeChip(toolbar, "Clear", 44, false, function()
	table.clear(logQueue)
	for _, entry in ipairs(logLabels) do
		entry:Destroy()
	end
	table.clear(logLabels)
end, chipOrder(), true)

pushLog("Listening for MineFX events (hits are off by default)", C.Sub)

---------------------------------------------------------------------------
-- Bag page (lists what the game's sell screen lists, with select + sell)
---------------------------------------------------------------------------

local bagPage = makeScrollPage("Bag")
local bagOrder = counter()
makeHeader(bagPage, "Sellable items", bagOrder())

local summaryRow = create("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = C.Row,
	BorderSizePixel = 0,
	LayoutOrder = bagOrder(),
	Parent = bagPage,
}, { corner(8), padding(10) })
local bagSummary = label({
	Text = "Open this tab to load your bag.",
	Font = Enum.Font.GothamBold,
	TextWrapped = true,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = summaryRow,
})
local actionRow = create("Frame", {
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundTransparency = 1,
	LayoutOrder = bagOrder(),
	Parent = bagPage,
})
local function actionButton(text, xScale, xOffset)
	return create("TextButton", {
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = C.Text,
		BackgroundColor3 = C.Row,
		BorderSizePixel = 0,
		Size = UDim2.new(0.5, -4, 1, 0),
		Position = UDim2.new(xScale, xOffset, 0, 0),
		Parent = actionRow,
	}, { corner(8) })
end
local selectButton = actionButton("Select All", 0, 0)
local sellButton = actionButton("Sell", 0.5, 4)
sellButton.BackgroundColor3 = C.Off

local bagList = create("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = bagOrder(),
	Parent = bagPage,
}, { list(4) })
label({
	Text = "Tap rows to pick them. Select All picks ores only, like the game's sell screen.",
	TextWrapped = true,
	AutomaticSize = Enum.AutomaticSize.Y,
	TextSize = 11,
	TextColor3 = C.Sub,
	Size = UDim2.new(1, 0, 0, 0),
	LayoutOrder = bagOrder(),
	Parent = bagPage,
})

local MAX_BAG_ROWS = 150
local bagElapsed = 1 -- seconds since the last refresh; >= 1 means "refresh on the next tick"
local bagModules = nil -- nil = not tried yet, false = failed to load
local lastBagSignature = nil

local function loadBagModules()
	if bagModules ~= nil then
		return bagModules
	end
	local ok, result = pcall(function()
		local folder = ReplicatedStorage.Modules
		return {
			GameState = require(folder.GameState),
			MineInventory = require(folder.MineInventory),
			String = require(folder.String),
		}
	end)
	bagModules = ok and result or false
	return bagModules
end

local function formatMoney(modules, n)
	local ok, text = pcall(function()
		return modules.String:ToMoney(n)
	end)
	if ok and text then
		return text
	end
	return "$" .. abbr(n)
end

local bagPicked = {} -- [entry key] = true
local bagRows = {} -- rows currently shown: { key, kind, worth, button, bar }

local function paintRow(row)
	local picked = bagPicked[row.key] == true
	row.button.BackgroundColor3 = picked and C.PickedBg or C.Panel
	row.bar.Visible = picked
end

-- Same rule as the game's sell screen: if any ore exists, "deselect" mode means every ore is picked;
-- with no ore, it means anything is picked.
local function wantsDeselect()
	local oreTotal, orePicked, anyPicked = 0, 0, false
	for _, row in ipairs(bagRows) do
		local picked = bagPicked[row.key] == true
		anyPicked = anyPicked or picked
		if row.kind == "Ore" then
			oreTotal += 1
			if picked then
				orePicked += 1
			end
		end
	end
	if oreTotal > 0 then
		return orePicked == oreTotal
	end
	return anyPicked
end

local function refreshActions()
	local count, worth = 0, 0
	for _, row in ipairs(bagRows) do
		if bagPicked[row.key] then
			count += 1
			worth += row.worth
		end
	end
	selectButton.Text = wantsDeselect() and "Deselect All" or "Select All"
	sellButton.Text = (count > 0 and bagModules) and ("Sell for " .. formatMoney(bagModules, worth)) or "Sell"
	sellButton.BackgroundColor3 = count > 0 and C.Sell or C.Off
end

local function refreshBag()
	local modules = loadBagModules()
	if not modules then
		bagSummary.Text = "Couldn't load the game's inventory modules."
		return
	end

	local ok, entries = pcall(function()
		local data = modules.GameState.GetData2()
		local mine = data and data.MineGame
		if not mine then
			return nil
		end
		return modules.MineInventory.Collect(mine, "All", modules.MineInventory.KindOrder.OreFirst)
	end)
	if not ok then
		bagSummary.Text = "Couldn't read the inventory."
		return
	end
	if not entries then
		bagSummary.Text = "Waiting for your save data..."
		return
	end

	local rows, parts, total = {}, {}, 0
	for _, entry in ipairs(entries) do
		local count = entry.SellCount or entry.Count or 0
		local worth = entry.Worth or 0
		if count > 0 and worth > 0 and entry.Key ~= nil then
			local name = tostring(entry.Display or entry.Name)
			rows[#rows + 1] = { key = entry.Key, kind = entry.Kind, name = name, count = count, worth = worth }
			parts[#parts + 1] = tostring(entry.Key) .. ":" .. count .. ":" .. worth
			total += worth
		end
	end

	local signature = table.concat(parts, "|")
	if signature == lastBagSignature then
		return -- nothing changed since the last refresh, keep the existing rows
	end
	lastBagSignature = signature

	bagSummary.Text = #rows == 0 and "Nothing sellable right now."
		or string.format("%d stacks  ·  total %s", #rows, formatMoney(modules, total))

	for _, child in ipairs(bagList:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(bagRows)
	local shown = {}
	for index = 1, math.min(#rows, MAX_BAG_ROWS) do
		local row = rows[index]
		local frame = create("TextButton", {
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = bagList,
		}, { corner(6) })
		row.button = frame
		row.bar = create("Frame", {
			Size = UDim2.new(0, 3, 1, -8),
			Position = UDim2.new(0, 3, 0, 4),
			BackgroundColor3 = C.Accent,
			BorderSizePixel = 0,
			Visible = false,
			Parent = frame,
		}, { corner(2) })
		bagRows[#bagRows + 1] = row
		shown[row.key] = true
		paintRow(row)
		frame.Activated:Connect(function()
			bagPicked[row.key] = not bagPicked[row.key] and true or nil
			paintRow(row)
			refreshActions()
		end)
		label({
			Text = row.name,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -168, 1, 0),
			Parent = frame,
		})
		label({
			Text = "x" .. abbr(row.count),
			TextSize = 12,
			TextColor3 = C.Sub,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(1, -160, 0, 0),
			Size = UDim2.fromOffset(60, 24),
			Parent = frame,
		})
		label({
			Text = formatMoney(modules, row.worth),
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = C.Good,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(1, -96, 0, 0),
			Size = UDim2.fromOffset(88, 24),
			Parent = frame,
		})
	end

	-- drop picks for stacks that are no longer shown (sold, or past the row cap)
	for key in pairs(bagPicked) do
		if not shown[key] then
			bagPicked[key] = nil
		end
	end
	refreshActions()
end

selectButton.Activated:Connect(function()
	if wantsDeselect() then
		for _, row in ipairs(bagRows) do
			bagPicked[row.key] = nil
		end
	else
		for _, row in ipairs(bagRows) do
			if row.kind == "Ore" then
				bagPicked[row.key] = true
			end
		end
	end
	for _, row in ipairs(bagRows) do
		paintRow(row)
	end
	refreshActions()
end)

sellButton.Activated:Connect(function()
	local modules = loadBagModules()
	if not modules then
		return
	end
	local keys = {}
	for _, row in ipairs(bagRows) do
		if bagPicked[row.key] then
			keys[#keys + 1] = row.key
		end
	end
	if #keys == 0 then
		return
	end
	-- same call the game's own SellFrame makes
	local ok, err = pcall(modules.GameState.SendEvent, "MineSellItems", keys)
	if not ok then
		warn("[MineFXPanel] sell failed: " .. tostring(err))
		return
	end
	table.clear(bagPicked)
	for _, row in ipairs(bagRows) do
		paintRow(row)
	end
	refreshActions()
	lastBagSignature = nil -- force a rebuild on the next tick, once the server has applied the sale
	bagElapsed = 1
end)

tabButtons["Bag"].Activated:Connect(function()
	bagElapsed = 1
end)

---------------------------------------------------------------------------
-- Settings page
---------------------------------------------------------------------------

local settingsPage = makeScrollPage("Settings")
local settingsOrder = counter()

local FLAGS = {
	{
		attr = "LagFix_RevealWrites",
		title = "Skip redundant reveal updates",
		desc = "Reveal labels and sunbursts only rewrite size, position and transparency when the value actually changed.",
	},
	{
		attr = "LagFix_RevealFan",
		title = "Sunburst fan image",
		desc = "Draw the reveal sunburst with the preloaded fan image. Off falls back to the ray frames.",
	},
	{
		attr = "LagFix_OreWeld",
		title = "Welded ore flight rigs",
		desc = "Fly ore drops as one welded rig that moves a single root part. Off clones and pivots the whole model.",
	},
	{
		attr = "LagFix_OreSize",
		title = "Per-part ore sizing",
		desc = "Resize welded ore parts directly instead of calling ScaleTo on the model. Needs welded rigs.",
	},
}

makeHeader(settingsPage, "Effect performance flags (this client only)", settingsOrder())
local flagSetters = {}
for _, flag in ipairs(FLAGS) do
	local set = makeToggleRow(settingsPage, flag.title, flag.desc, ReplicatedStorage:GetAttribute(flag.attr) ~= false, function(value)
		ReplicatedStorage:SetAttribute(flag.attr, value)
	end, settingsOrder())
	flagSetters[flag.attr] = set
	-- keep the switch in step if something else flips the attribute
	track(ReplicatedStorage:GetAttributeChangedSignal(flag.attr):Connect(function()
		set(ReplicatedStorage:GetAttribute(flag.attr) ~= false, true)
	end))
end
makeButton(settingsPage, "Restore flag defaults (all on)", settingsOrder(), function()
	for _, flag in ipairs(FLAGS) do
		ReplicatedStorage:SetAttribute(flag.attr, true)
		flagSetters[flag.attr](true, true)
	end
end)

makeHeader(settingsPage, "Panel", settingsOrder())
makeSlider(settingsPage, "Panel scale", 0.7, 1.2, 1, function(value)
	return string.format("%d%%", math.floor(value * 100 + 0.5))
end, function(value)
	uiScale.Scale = value
end, settingsOrder())
label({
	Text = "RightShift hides or shows the panel.",
	TextSize = 11,
	TextColor3 = C.Sub,
	Size = UDim2.new(1, 0, 0, 16),
	LayoutOrder = settingsOrder(),
	Parent = settingsPage,
})

---------------------------------------------------------------------------
-- MineFX events
---------------------------------------------------------------------------

local function isMine(p)
	local t = p.t
	if t == "sold" or t == "sfx" then
		return true
	end
	if p.owner ~= nil then
		return p.owner == LocalPlayer.UserId
	end
	if p.tap == LocalPlayer.UserId then
		return true
	end
	if p.plot ~= nil then
		local world = workspace:FindFirstChild("MineWorld")
		local plots = world and world:FindFirstChild("Plots")
		local plot = plots and plots:FindFirstChild("MinePlot" .. tostring(p.plot))
		return plot ~= nil and plot:GetAttribute("OwnerUserId") == LocalPlayer.UserId
	end
	return false
end

-- returns filter category, log text, log color
local function describe(p)
	local t = p.t
	if t == "hit" then
		return "hit", string.format("HIT    -%s%s", abbr(p.dmg), p.crit and "!" or ""), p.crit and C.Accent or C.Text
	elseif t == "break" then
		return "break", string.format("BREAK  %s x%s%s", tostring(p.ore or "?"), abbr(p.amount), p.kill and "  (kill)" or ""), C.Blue
	elseif t == "found" then
		local rarity = type(p.rarity) == "string" and ("  [" .. p.rarity .. "]") or ""
		return "found", "FOUND  " .. tostring(p.name or "?") .. rarity, C.Pink
	elseif t == "sold" then
		return "sold", "SOLD   +" .. tostring(p.value), C.Good
	elseif t == "colossuskill" then
		return "other", "COLOSSUS shattered", C.Bad
	end
	return "other", string.upper(tostring(t)) .. (p.n and ("  " .. tostring(p.n)) or ""), C.Sub
end

local function handleEvent(p)
	if type(p) ~= "table" then
		return
	end
	if state.mineOnly and not isMine(p) then
		return
	end

	local t = p.t
	if t == "hit" then
		local damage = tonumber(p.dmg) or 0
		stats.hits += 1
		stats.damage += damage
		stats.best = math.max(stats.best, damage)
		if p.crit then
			stats.crits += 1
		end
	elseif t == "break" then
		stats.breaks += 1
		stats.ore += tonumber(p.amount) or 0
	elseif t == "found" then
		stats.finds += 1
		stats.lastFind = tostring(p.name or "?")
	elseif t == "sold" then
		stats.sales += 1
		stats.lastSale = "+" .. tostring(p.value)
	elseif t == "colossuskill" then
		stats.colossi += 1
	end
	statsDirty = true

	if not state.paused then
		local category, text, color = describe(p)
		if state.filters[category] then
			pushLog(text, color)
		end
	end
end

local function connectRemote()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	local mineFX = remotes and remotes:WaitForChild("MineFX", 15)
	if not gui.Parent then
		return
	end
	if not (mineFX and mineFX:IsA("RemoteEvent")) then
		status.Text = "● MineFX not found"
		status.TextColor3 = C.Bad
		pushLog("ReplicatedStorage.Remotes.MineFX was not found", C.Bad)
		return
	end
	track(mineFX.OnClientEvent:Connect(function(p)
		local ok, err = pcall(handleEvent, p)
		if not ok then
			warn("[MineFXPanel] " .. tostring(err))
		end
	end))
	status.Text = "● live"
	status.TextColor3 = C.Good
end

---------------------------------------------------------------------------
-- Window behaviour
---------------------------------------------------------------------------

do -- drag by the title bar
	local dragging, dragStart, startPosition = false, nil, nil
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = window.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(
				startPosition.X.Scale, startPosition.X.Offset + delta.X,
				startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
			)
		end
	end))
end

local minimized = false
minimizeButton.Activated:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	window.Size = minimized and UDim2.fromOffset(WIDTH, TITLE_H) or UDim2.fromOffset(WIDTH, HEIGHT)
end)
closeButton.Activated:Connect(function()
	window.Visible = false
end)
track(UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == TOGGLE_KEY then
		window.Visible = not window.Visible
	end
end))

gui.Destroying:Connect(function()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end)

selectTab("Stats")
gui.Parent = PlayerGui
task.spawn(connectRemote) -- after parenting: connectRemote bails out if the gui is already gone

-- UI refresh runs at ~7 Hz so a burst of crew hits doesn't rebuild labels per event
task.spawn(function()
	while gui.Parent do
		if statsDirty then
			statsDirty = false
			refreshStats()
		end
		flushLog()
		bagElapsed += 0.15
		if bagElapsed >= 1 and pages["Bag"].Visible and window.Visible then
			bagElapsed = 0
			local ok, err = pcall(refreshBag)
			if not ok then
				warn("[MineFXPanel] bag refresh failed: " .. tostring(err))
			end
		end
		task.wait(0.15)
	end
end)
