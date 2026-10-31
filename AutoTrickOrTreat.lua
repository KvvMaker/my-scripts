-- AutoTrickOrTreat: executor script (Potassium etc.). Run it while you are in the game with the
-- Halloween event active. Trick-or-treating needs the candy bag in your backpack; graveyards don't.
--
-- Three jobs, each with its own toggle (1 and 2 are mixed nearest-first):
--   1. Trick-or-treat houses
--   2. Graveyards: Workspace.Systems.Event.ActiveGraveyards, one ProximityPrompt each; the game
--      disables the prompt once it's searched, which is also how we know the search worked.
--   3. Repo (tow truck) job, off by default; when on it replaces 1 and 2. Accepts the contract,
--      gets into the rental truck, drives to each marker, fires the wrecker's Grab call at the
--      target car and releases it at the impound. If the grab doesn't take, that step is manual.
--   4. Highway cruise (off by default, takes over from the others): drives your car down the traffic
--      highway at speed, changing lane around traffic, so the game's own scoring pays out.
--
-- How trick-or-treating works (mirrors the game's own TrickOrTreat client module):
--   * The orange pumpkin markers the game draws in Workspace.Terrain are the houses you can still
--     knock on today, so those are used as the "to do" list (no state of our own to get out of sync).
--   * For each house we move to the doorstep and fire the door's "Knock or claim" ProximityPrompt.
--     That only opens a "Knock / Claim house" dialog, so we then click "Knock" (never "Claim house").
--     The server decides the reward and tells the client, which is what plays the knock animation.
--   * Optionally hooks TrickOrTreat.PlayVisit so the ~10s animation can be skipped and rewards logged.
--
-- Rare ("exclusive") drops: hooks ExclusiveDrop so graveyard rares are logged, the spirit cutscene
-- can be skipped, the main loop pauses while a reward scene owns your character, and the "Nice!"
-- popup is closed automatically. A rare found at a house still plays its full animation.
--
-- RightShift hides/shows the window. Re-running the script replaces the old window.

local env = (getgenv and getgenv()) or _G
if env.AutoTrickOrTreat then
	pcall(env.AutoTrickOrTreat.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local Teams = game:GetService("Teams")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------------------------
-- Settings / state
--------------------------------------------------------------------------------------------------

local Config = {
	Enabled = false,
	Houses = true, -- knock on trick-or-treat doors
	Graveyards = true, -- search the daily graveyards
	Repo = false, -- run the Repo (tow truck) job instead of the two above
	RepoTask = 1, -- which Repo contract to take (1 = first in the list)
	SkipAnimation = true, -- skip knock / graveyard cutscenes (needs the module hooks)
	AutoClose = true, -- click "Nice!" on the rare-item popup
	AutoYes = true, -- click "Yes" on the "complete another job for a bonus?" popup
	AntiAfk = true, -- stop Roblox's 20-minute idle kick (works whether or not the automation is started)
	Instant = false, -- teleport instead of gliding to each door
	Speed = 150, -- studs per second while gliding
	RepoSpeed = 80, -- studs per second the Repo truck is moved at (the server may reject arrivals if too fast)
	RepoHeight = 150, -- studs above the map the truck cruises at before dropping onto the marker (0 = straight line)
	Cruise = false, -- highway autopilot: drive the traffic highway for the game's own speed/near-miss points
	CruiseSpeed = 150, -- studs per second it aims for (the scoring starts at 100, the steady "high speed" rate at 130)
	CruiseStyle = "balanced", -- careful / balanced / bold: how much room it leaves, and whether it weaves close for near misses
	AutoFuel = true, -- refuel the car you're sitting in when its tank runs low (only while started)
	FuelBelow = 10, -- refuel when the tank is at or under this many percent
	CarGoal = "balanced", -- what "best parts" means: balanced / power / speed / accel / gears
	CarCategories = {}, -- part category id -> false to leave that category alone (missing = included)
	CarValue = true, -- rank moves by gain per capacity/cash used (off = biggest gain first, whatever it costs)
	CarAllowUnreliable = false, -- let "fastest parts" pick parts that push the car into the unreliable band
	CarMaxSpend = 0, -- cash limit for "fastest parts" (0 = all your cash)
	CarSkip = "", -- comma-separated names/ids of parts "best parts" must never pick
	Delay = 0.5, -- seconds between houses
}

local State = {
	Running = true,
	Houses = 0,
	Graveyards = 0,
	Currency = 0,
	Exclusives = 0,
	HookAt = 0, -- os.clock() of the last PlayVisit call
	Visiting = false, -- true while the game's own knock animation is playing
	Scene = 0, -- number of ExclusiveDrop reward scenes currently playing
	Failed = {}, -- stop key -> os.clock() until which we leave it alone after a failure
	Searched = {}, -- graveyard key -> os.clock() until which we assume it is already searched
	Repos = 0, -- Repo jobs finished this session
	RepoPending = 0, -- os.clock() until which we wait for an accepted task to show up
}

local MARKER_NAME = "TrickOrTreatMarker"
local MARKER_OFFSET = Vector3.new(0, 11, 0) -- the game draws the pumpkin 11 studs above the door
local STAND_OFFSET = Vector3.new(0.7, 3.2, 2.5) -- doorstep, in the door CFrame's space (house is -Z)
local RETRY_COOLDOWN = 45
local PRESS_PARENTS = { DOOR = true, PartDoor = true, GLASS = true }
local CLAIM_PARENT = "SmartHomeClaimPrompt"
local KNOCK_ACTION = "Knock or claim" -- ActionText the game gives the door prompts of knockable houses

--------------------------------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------------------------------

local THEME = {
	Window = Color3.fromRGB(24, 19, 31),
	Panel = Color3.fromRGB(36, 29, 46),
	Field = Color3.fromRGB(52, 43, 66),
	Stroke = Color3.fromRGB(78, 62, 98),
	Accent = Color3.fromRGB(255, 138, 31),
	Text = Color3.fromRGB(242, 236, 248),
	Dim = Color3.fromRGB(156, 146, 172),
	Good = Color3.fromRGB(104, 214, 128),
	Bad = Color3.fromRGB(238, 88, 88),
	Warn = Color3.fromRGB(255, 202, 74),
}

local connections = {}

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(connections, connection)
	return connection
end

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for key, value in pairs(props) do
		if key == "Parent" then
			parent = value
		else
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
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color)
	return new("UIStroke", { Color = color, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function label(props, children)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.Gotham
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or THEME.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props, children)
end

local layoutCounter = 0
local function nextOrder()
	layoutCounter += 1
	return layoutCounter
end

local function guiParent()
	if gethui then
		local ok, result = pcall(gethui)
		if ok and result then
			return result
		end
	end
	local ok, coreGui = pcall(function()
		return game:GetService("CoreGui")
	end)
	if ok and coreGui then
		local writable = pcall(function()
			local probe = Instance.new("Folder")
			probe.Parent = coreGui
			probe:Destroy()
		end)
		if writable then
			return coreGui
		end
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

-- After running game code a thread can end up with less access than the one it started with. Where
-- the executor supports it, put the thread back to full identity (harmless where it doesn't).
local function restoreIdentity()
	local setter = setthreadidentity or setidentity or setthreadcontext
	if setter then
		pcall(setter, 8)
	end
end

local function formatNumber(n)
	local digits = tostring(math.floor(n))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (grouped:gsub("^,", ""))
end

--------------------------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "AutoTrickOrTreat",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 100,
	Parent = guiParent(),
})

local window = new("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(400, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 24, 0.5, 0),
	BackgroundColor3 = THEME.Window,
	BorderSizePixel = 0,
	Active = true,
	Parent = gui,
}, {
	corner(12),
	stroke(THEME.Stroke),
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
})

local titleBar = new("Frame", {
	Name = "TitleBar",
	Size = UDim2.new(1, 0, 0, 38),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	LayoutOrder = 1,
	Parent = window,
}, { corner(12) })

-- squares off the title bar's bottom corners while the body is showing
local titleCover = new("Frame", {
	Size = UDim2.new(1, 0, 0, 12),
	Position = UDim2.new(0, 0, 1, -12),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	Parent = titleBar,
})

label({
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -90, 1, 0),
	Text = "🎃  Auto Halloween",
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	Parent = titleBar,
})

local function iconButton(text, offsetX)
	return new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, offsetX, 0.5, 0),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = THEME.Field,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = THEME.Text,
		Parent = titleBar,
	}, { corner(7) })
end

local minimizeButton = iconButton("–", -42)
local closeButton = iconButton("✕", -10)

local body = new("Frame", {
	Name = "Body",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = 2,
	Parent = window,
}, {
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	new("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}),
})

-- status line
local statusCard = new("Frame", {
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(8) })

local statusDot = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 12, 0.5, 0),
	Size = UDim2.fromOffset(10, 10),
	BackgroundColor3 = THEME.Dim,
	BorderSizePixel = 0,
	Parent = statusCard,
}, { corner(10) })

local statusText = label({
	Position = UDim2.fromOffset(30, 0),
	Size = UDim2.new(1, -40, 1, 0),
	Text = "Idle",
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = statusCard,
})

-- Threads that have been through game code (our hooks, the car-parts work) can lose access to our
-- GUI ("lacking capability Plugin"), so setStatus only records the text; applyStatus, called from
-- the UI loop, puts it on screen.
local pendingStatus -- { text, color }

local function setStatus(text, color)
	pendingStatus = { text, color or THEME.Dim }
end

local function applyStatus()
	local item = pendingStatus
	if not item then
		return
	end
	pendingStatus = nil
	if statusText.Text ~= item[1] then
		statusText.Text = item[1]
	end
	statusDot.BackgroundColor3 = item[2]
end

-- start / stop
local startButton = new("TextButton", {
	Size = UDim2.new(1, 0, 0, 40),
	BorderSizePixel = 0,
	AutoButtonColor = true,
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(9) })

local function renderStartButton()
	if Config.Enabled then
		startButton.Text = "■  Stop"
		startButton.BackgroundColor3 = THEME.Bad
		startButton.TextColor3 = Color3.new(1, 1, 1)
	else
		startButton.Text = "▶  Start"
		startButton.BackgroundColor3 = THEME.Accent
		startButton.TextColor3 = Color3.fromRGB(34, 20, 6)
	end
end
renderStartButton()

-- stats
local statsCard = new("Frame", {
	Size = UDim2.new(1, 0, 0, 52),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(8) })

local function statCell(index, caption)
	local cell = new("Frame", {
		Size = UDim2.new(1 / 4, 0, 1, 0),
		Position = UDim2.new((index - 1) / 4, 0, 0, 0),
		BackgroundTransparency = 1,
		Parent = statsCard,
	})
	local value = label({
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "0",
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = cell,
	})
	local captionLabel = label({
		Position = UDim2.fromOffset(0, 31),
		Size = UDim2.new(1, 0, 0, 14),
		Text = caption,
		TextSize = 11,
		TextColor3 = THEME.Dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = cell,
	})
	return value, captionLabel
end

local housesValue = statCell(1, "Houses")
local gravesValue = statCell(2, "Graves")
local currencyValue, currencyCaption = statCell(3, "Candy")
local exclusivesValue = statCell(4, "Rares")

local hookInstalled = false

local statsDirty = true

-- same reason as setStatus: only flag it, the UI loop redraws
local function refreshStats()
	statsDirty = true
end

local function drawStats()
	housesValue.Text = formatNumber(State.Houses)
	gravesValue.Text = formatNumber(State.Graveyards)
	currencyValue.Text = hookInstalled and formatNumber(State.Currency) or "—"
	exclusivesValue.Text = formatNumber(State.Exclusives)
end

-- tabs: a segmented bar over one card that shows a single page at a time
local tabs = {}

local tabBar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	LayoutOrder = nextOrder(),
	Parent = body,
}, {
	corner(8),
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
	new("UIPadding", {
		PaddingTop = UDim.new(0, 3),
		PaddingBottom = UDim.new(0, 3),
		PaddingLeft = UDim.new(0, 3),
		PaddingRight = UDim.new(0, 3),
	}),
})

-- fixed height, so the window is the same size on every tab; a long page scrolls inside it
local pageHolder = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 230),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = THEME.Stroke,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(8) })

local function selectTab(name)
	for key, tab in pairs(tabs) do
		local selected = key == name
		tab.Page.Visible = selected
		tab.Button.BackgroundTransparency = selected and 0 or 1
		tab.Button.TextColor3 = selected and Color3.fromRGB(34, 20, 6) or THEME.Dim
	end
end

local function makeTab(name, order)
	local button = new("TextButton", {
		Size = UDim2.new(1 / 4, -3, 1, 0),
		BackgroundColor3 = THEME.Accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = name,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = THEME.Dim,
		LayoutOrder = order,
		Parent = tabBar,
	}, { corner(6) })
	local page = new("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		Parent = pageHolder,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
	})
	tabs[name] = { Button = button, Page = page }
	connect(button.Activated, function()
		selectTab(name)
	end)
	return page
end

local jobsPage = makeTab("Jobs", 1)
local repoPage = makeTab("Repo", 2)
local carPage = makeTab("Car", 3)
local settingsPage = makeTab("Settings", 4)
selectTab("Jobs")

-- small dim heading and a wrapped hint line inside a page
local UI = {} -- GUI builders live in one table: the chunk is close to Luau's 200-locals limit

function UI.makeSection(parent, text)
	return label({
		Size = UDim2.new(1, 0, 0, 20),
		Text = string.upper(text),
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = THEME.Dim,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
end

function UI.makeNote(parent, text)
	return label({
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = text,
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = THEME.Dim,
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
end

function UI.makeButton(parent, text, onClick)
	local button = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = THEME.Accent,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(34, 20, 6),
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, { corner(8) })
	connect(button.Activated, onClick)
	return button
end

-- a labelled text box on its own line (the box is too wide for the side-by-side layout of makeInput)
function UI.makeText(parent, text, initial, placeholder, onChange)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
	label({ Size = UDim2.new(1, 0, 0, 18), Text = text, Parent = row })
	local box = new("TextBox", {
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = THEME.Field,
		BorderSizePixel = 0,
		Text = initial,
		PlaceholderText = placeholder,
		PlaceholderColor3 = THEME.Dim,
		ClearTextOnFocus = false,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	}, { corner(6), new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })
	connect(box.FocusLost, function()
		onChange(box.Text)
	end)
end

-- compact grids of small buttons ("chips"), for short lists that would otherwise be long columns
function UI.makeGrid(parent, columns)
	return new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = parent,
	}, {
		new("UIGridLayout", {
			CellSize = UDim2.new(1 / columns, -4, 0, 26),
			CellPadding = UDim2.fromOffset(6, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

function UI.styleChip(chip, on)
	chip.BackgroundColor3 = on and THEME.Accent or THEME.Field
	chip.TextColor3 = on and Color3.fromRGB(34, 20, 6) or THEME.Dim
end

function UI.makeChip(grid, text, on)
	local chip = new("TextButton", {
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = text,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = nextOrder(),
		Parent = grid,
	}, { corner(6) })
	UI.styleChip(chip, on)
	return chip
end

-- exclusive options, the chosen one highlighted
function UI.makeChoice(parent, options, selectedId, onChange)
	local grid = UI.makeGrid(parent, 2)
	local chips = {}
	for _, option in ipairs(options) do
		local chip = UI.makeChip(grid, option.Name, option.Id == selectedId)
		chips[option.Id] = chip
		connect(chip.Activated, function()
			for id, other in pairs(chips) do
				UI.styleChip(other, id == option.Id)
			end
			onChange(option.Id)
		end)
	end
end

-- an on/off chip; onChange gets the new state
function UI.makeChipToggle(grid, text, initial, onChange)
	local on = initial
	local chip = UI.makeChip(grid, text, on)
	connect(chip.Activated, function()
		on = not on
		UI.styleChip(chip, on)
		onChange(on)
	end)
end

function UI.makeToggle(parent, text, initial, onChange, locked)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
	local rowLabel = label({
		Size = UDim2.new(1, -52, 1, 0),
		Text = text,
		TextColor3 = locked and THEME.Dim or THEME.Text,
		Parent = row,
	})
	local track = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(40, 20),
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Parent = row,
	}, { corner(10) })
	local knob = new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = track,
	}, { corner(8) })

	local state = initial and not locked
	local function render()
		track.BackgroundColor3 = state and THEME.Accent or THEME.Field
		knob.Position = state and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
	end
	render()

	connect(track.Activated, function()
		if locked then
			return
		end
		state = not state
		render()
		onChange(state)
	end)
	return rowLabel
end

function UI.makeInput(parent, text, initial, min, max, onChange)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
	label({ Size = UDim2.new(1, -72, 1, 0), Text = text, Parent = row })
	local box = new("TextBox", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(64, 22),
		BackgroundColor3 = THEME.Field,
		BorderSizePixel = 0,
		Text = tostring(initial),
		ClearTextOnFocus = false,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = THEME.Text,
		Parent = row,
	}, { corner(6) })

	local current = initial
	connect(box.FocusLost, function()
		local number = tonumber(box.Text)
		if number then
			current = math.clamp(number, min, max)
			onChange(current)
		end
		box.Text = tostring(current)
	end)
end

-- log
local logScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 96),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = THEME.Stroke,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	LayoutOrder = nextOrder(),
	Parent = body,
}, {
	corner(8),
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
	new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	}),
})

label({
	Size = UDim2.new(1, 0, 0, 14),
	Text = "RightShift: hide / show",
	TextSize = 11,
	TextColor3 = THEME.Dim,
	TextXAlignment = Enum.TextXAlignment.Center,
	LayoutOrder = nextOrder(),
	Parent = body,
})

local logQueue, logId = {}, 0 -- the label instances currently shown
local pendingLogs = {} -- messages waiting for the UI loop to draw them

-- log() can be called from anywhere, including threads the game owns (our hooks run inside the
-- game's own threads) and button-click threads, and some of those aren't allowed to create
-- Instances ("lacking capability Plugin"). So it only queues; flushLogs draws, from our own loop.
local function log(text, color)
	table.insert(pendingLogs, { Text = text, Color = color, Time = os.date("%H:%M:%S") })
end

local function flushLogs()
	if #pendingLogs == 0 then
		return
	end
	while #pendingLogs > 0 do
		local item = table.remove(pendingLogs, 1)
		logId += 1
		local entry = label({
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = item.Time .. "  " .. item.Text,
			TextSize = 11,
			TextWrapped = true,
			TextColor3 = item.Color or THEME.Dim,
			LayoutOrder = logId,
			Parent = logScroll,
		})
		table.insert(logQueue, entry)
		if #logQueue > 60 then
			table.remove(logQueue, 1):Destroy()
		end
	end
	task.delay(0.05, function()
		if logScroll.Parent then
			logScroll.CanvasPosition = Vector2.new(0, math.max(0, logScroll.AbsoluteCanvasSize.Y - logScroll.AbsoluteSize.Y))
		end
	end)
end

--------------------------------------------------------------------------------------------------
-- Game bindings
--------------------------------------------------------------------------------------------------

local function tryRequire(moduleScript)
	if not moduleScript then
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	return ok and result or nil
end

local storage = ReplicatedStorage:WaitForChild("Storage", 5)
local sharedModules = storage and storage:FindFirstChild("Shared")
local SeasonalEvent = tryRequire(sharedModules and sharedModules:FindFirstChild("SeasonalEvent"))
local TrickOrTreat = SeasonalEvent and SeasonalEvent.TrickOrTreat
local BAG_NAME = TrickOrTreat and TrickOrTreat.BagName

local currencyName = "Candy"
if SeasonalEvent and SeasonalEvent.CurrencyName then
	local ok, name = pcall(SeasonalEvent.CurrencyName, 2)
	if ok and type(name) == "string" and name ~= "" then
		currencyName = name
	end
end
currencyCaption.Text = currencyName

local function active()
	return State.Running and Config.Enabled
end

local function getCharacter()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return char, hum, hrp
	end
	return nil
end

local function isBag(tool)
	if not tool:IsA("Tool") then
		return false
	end
	if BAG_NAME then
		return tool.Name == BAG_NAME
	end
	local name = tool.Name:lower()
	return name:find("trick", 1, true) ~= nil or name:find("treat", 1, true) ~= nil or name:find("pail", 1, true) ~= nil
end

local function findBag()
	for _, container in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChildOfClass("Backpack") }) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if isBag(child) then
					return child
				end
			end
		end
	end
	return nil
end

-- lot id -> door position, from the same attribute the game's client module reads
local function readDoors()
	local doors = {}
	local systems = Workspace:FindFirstChild("Systems")
	local event = systems and systems:FindFirstChild("Event")
	local raw = event and event:GetAttribute("TrickOrTreatDoors")
	if type(raw) ~= "string" then
		return doors
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if ok and type(decoded) == "table" then
		for lot, position in pairs(decoded) do
			if type(position) == "table" and #position == 3 then
				doors[lot] = Vector3.new(position[1], position[2], position[3])
			end
		end
	end
	return doors
end

-- door positions of every pumpkin marker currently shown
local function getMarkers()
	local positions = {}
	for _, inst in ipairs(Workspace.Terrain:GetChildren()) do
		if inst.Name == MARKER_NAME and inst:IsA("Attachment") then
			table.insert(positions, inst.WorldPosition - MARKER_OFFSET)
		end
	end
	return positions
end

local function getTargets()
	local doors = readDoors()
	local targets = {}
	for _, markerPos in ipairs(getMarkers()) do
		local bestLot, bestDistance = nil, 2
		for lot, doorPos in pairs(doors) do
			local distance = (doorPos - markerPos).Magnitude
			if distance < bestDistance then
				bestLot, bestDistance = lot, distance
			end
		end
		if bestLot then
			table.insert(targets, { Lot = bestLot, Pos = doors[bestLot] })
		end
	end
	return targets
end

local function markerGone(target)
	for _, markerPos in ipairs(getMarkers()) do
		if (markerPos - target.Pos).Magnitude < 2 then
			return false
		end
	end
	return true
end

local function findHome(lot)
	for _, home in ipairs(CollectionService:GetTagged("Home")) do
		if home:GetAttribute("TrickOrTreatLot") == lot
			and home:GetAttribute("OwnerId") == nil
			and home:IsDescendantOf(Workspace)
		then
			return home
		end
	end
	return nil
end

-- door prompts first, the smart-home claim prompt only as a fallback
local function getPrompts(home)
	local function collect(root)
		local doorPrompts, claimPrompts = {}, {}
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("ProximityPrompt") and inst.Parent then
				local parentName = inst.Parent.Name
				if parentName == CLAIM_PARENT then
					table.insert(claimPrompts, inst)
				elseif PRESS_PARENTS[parentName] or inst.ActionText == KNOCK_ACTION then
					table.insert(doorPrompts, inst)
				end
			end
		end
		return doorPrompts, claimPrompts
	end

	local homeModel = home:FindFirstChild("Home")
	local door = homeModel and homeModel:FindFirstChild("Door")
	local doorPrompts, claimPrompts = collect(door or home)
	if #doorPrompts + #claimPrompts == 0 and door then
		doorPrompts, claimPrompts = collect(home)
	end
	for _, prompt in ipairs(claimPrompts) do
		table.insert(doorPrompts, prompt)
	end

	-- the game relabels the prompts that start a visit; once that has happened use only those
	local relabelled = {}
	for _, prompt in ipairs(doorPrompts) do
		if prompt.ActionText == KNOCK_ACTION then
			table.insert(relabelled, prompt)
		end
	end
	return #relabelled > 0 and relabelled or doorPrompts
end

local function press(prompt)
	pcall(function()
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 20)
	end)
	if fireproximityprompt then
		pcall(fireproximityprompt, prompt)
	else
		pcall(function()
			prompt:InputHoldBegin()
			task.wait(0.05)
			prompt:InputHoldEnd()
		end)
	end
end

-- Firing the prompt only opens a "Knock / Claim house" dialog. Find its "Knock" button by text;
-- "Claim house" never matches because the text has to be exactly "Knock".
local function isShown(obj)
	local current = obj
	while current and current ~= game do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		if current:IsA("ScreenGui") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	if obj.AbsoluteSize.X <= 0 or obj.AbsoluteSize.Y <= 0 then
		return false
	end
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		if obj.TextTransparency >= 0.95 then
			return false
		end
	end
	-- the game keeps its dialogs around and slides them on/off screen, so Visible alone isn't enough
	local camera = Workspace.CurrentCamera
	if camera then
		local center = obj.AbsolutePosition + obj.AbsoluteSize / 2
		local viewport = camera.ViewportSize
		if center.X < 0 or center.Y < 0 or center.X > viewport.X or center.Y > viewport.Y then
			return false
		end
	end
	return true
end

-- The dialog lives in PlayerGui.BigNotification (Frame.Content.Buttons.Button_N.ButtonText); other
-- GUIs mention "knock" too (quest list, the prompt's "Knock or claim"), so only exact "Knock" counts.
local function findKnockButton()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local root = playerGui:FindFirstChild("BigNotification") or playerGui
	for _, inst in ipairs(root:GetDescendants()) do
		if (inst:IsA("TextButton") or inst:IsA("TextLabel")) and not inst:IsDescendantOf(gui) then
			local text = inst.Text:gsub("<[^>]+>", ""):lower():match("^%s*(.-)%s*$")
			if text:match("^knock%W*$") and isShown(inst) then
				return inst
			end
		end
	end
	return nil
end

local function fireConnections(button)
	if not (getconnections and button) then
		return false
	end
	for _, signalName in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down", "MouseButton1Up" }) do
		local ok, list = pcall(getconnections, button[signalName])
		if ok and type(list) == "table" and #list > 0 then
			for _, connection in ipairs(list) do
				pcall(function()
					connection:Fire()
				end)
			end
			return true
		end
	end
	return false
end

local function fireSignals(button)
	if not (firesignal and button) then
		return false
	end
	pcall(firesignal, button.MouseButton1Click)
	pcall(firesignal, button.Activated)
	return true
end

local function clickWithMouse(obj)
	local ok, vim = pcall(game.GetService, game, "VirtualInputManager")
	if not (ok and vim) then
		return false
	end
	local screenGui = obj:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = (screenGui and screenGui.IgnoreGuiInset) and Vector2.zero or GuiService:GetGuiInset()
	local center = obj.AbsolutePosition + obj.AbsoluteSize / 2 + inset
	return pcall(function()
		vim:SendMouseMoveEvent(center.X, center.Y, game)
		task.wait(0.05)
		vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
		task.wait(0.05)
		vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
	end)
end

-- Ways to press the Knock button, most precise first. Each returns true if it did something; the
-- caller checks whether the knock actually registered before trying the next one.
local function clickMethods(knockObj)
	local button = knockObj
	while button and not button:IsA("GuiButton") do
		button = button.Parent
	end
	if button == game then
		button = nil
	end
	return {
		function()
			return fireConnections(button)
		end,
		function()
			return fireSignals(button)
		end,
		function()
			return clickWithMouse(button or knockObj)
		end,
	}
end

local function waitFor(check, timeout)
	local deadline = os.clock() + timeout
	while State.Running do
		local value = check()
		if value then
			return value
		end
		if os.clock() >= deadline then
			break
		end
		task.wait(0.1)
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Hooks into the game's own client modules (PlayerScripts.Modules.*). Their methods are looked up
-- through the class table at call time, so replacing a method on the class affects the live instance.
--   TrickOrTreat.PlayVisit      -> record rewards, optionally skip the knock cutscene
--   ExclusiveDrop.OnDrop        -> record graveyard rares, know when a reward scene is playing
--   ExclusiveDrop.PlayGraveyard -> optionally skip the spirit cutscene (the rare reveal still shows)
--------------------------------------------------------------------------------------------------

local hooks = {} -- { Class, Method, Original, Wrapper }

-- loadModule("ExclusiveDrop") or loadModule("GUIManager", "Jobs_Repo"): a path under PlayerScripts.Modules
local function loadModule(...)
	local node = LocalPlayer:FindFirstChild("PlayerScripts")
	node = node and node:FindFirstChild("Modules")
	for _, name in ipairs({ ... }) do
		node = node and node:FindFirstChild(name)
	end
	local moduleScript = node
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		return nil
	end
	local class = tryRequire(moduleScript)
	return type(class) == "table" and class or nil
end

local function wrapMethod(class, method, build)
	local original = rawget(class, method)
	if type(original) ~= "function" then
		return false
	end
	local wrapper = build(original)
	if not pcall(function()
		class[method] = wrapper
	end) then
		return false
	end
	table.insert(hooks, { Class = class, Method = method, Original = original, Wrapper = wrapper })
	return true
end

local function removeHooks()
	for _, entry in ipairs(hooks) do
		if rawget(entry.Class, entry.Method) == entry.Wrapper then
			pcall(function()
				entry.Class[entry.Method] = entry.Original
			end)
		end
	end
	table.clear(hooks)
end

local RARE_KINDS = { Wheels = "wheels", Horns = "horn", Materials = "texture", Bodykits = "bodykit", Vehicle = "car" }
local lastRare = { Name = nil, At = 0 }

-- an "exclusive" is the game's name for a limited item drop
local function recordRare(name, kind, graveyardId)
	if lastRare.Name == name and os.clock() - lastRare.At < 5 then
		return -- the same drop can be reported by more than one path
	end
	lastRare.Name, lastRare.At = name, os.clock()
	State.Exclusives += 1
	local text = "⭐ " .. name
	if RARE_KINDS[kind] then
		text ..= " (" .. RARE_KINDS[kind] .. ")"
	end
	if graveyardId then
		text ..= " from graveyard " .. graveyardId
	end
	log(text, THEME.Warn)
	refreshStats()
end

-- a rare that is new to you (a duplicate pays out a "Backup" amount instead)
local function isRareResult(result)
	return type(result) == "table" and type(result.Exclusive) == "string" and not tonumber(result.Backup)
end

local function onVisitResult(home, result)
	if type(result) ~= "table" then
		return
	end
	local lot = home and home:GetAttribute("TrickOrTreatLot")
	local amount = tonumber(result.Amount) or 0
	State.Currency += amount
	local text = "House " .. tostring(lot) .. ": +" .. formatNumber(amount) .. " " .. currencyName
	local backup = tonumber(result.Backup)
	if backup then
		State.Currency += backup
		text ..= " (duplicate " .. tostring(result.Exclusive) .. " → +" .. formatNumber(backup) .. ")"
	end
	log(text, THEME.Good)
	if isRareResult(result) then
		recordRare(result.Exclusive, result.ExclusiveType, nil)
	end
	refreshStats()
end

local function installVisitHook()
	local class = loadModule("TrickOrTreat")
	if not class then
		return false
	end
	return wrapMethod(class, "PlayVisit", function(original)
		return function(self, home, doorCF, result)
			State.HookAt = os.clock()
			pcall(onVisitResult, home, result)
			-- common visits skip the cutscene; a rare always plays it so you see what you got
			if Config.SkipAnimation and not isRareResult(result) then
				return
			end
			State.Visiting = true
			local ok, err = pcall(original, self, home, doorCF, result)
			State.Visiting = false
			if not ok then
				error(err, 0)
			end
		end
	end)
end

local function installExclusiveHook()
	local class = loadModule("ExclusiveDrop")
	if not class then
		return false
	end
	local dropHooked = wrapMethod(class, "OnDrop", function(original)
		return function(self, drop)
			if type(drop) == "table" and type(drop.Name) == "string" then
				pcall(recordRare, drop.Name, drop.Type, drop.Source == "Graveyard" and drop.Graveyard or nil)
			end
			State.Scene += 1
			local ok, err = pcall(original, self, drop)
			State.Scene -= 1
			if not ok then
				error(err, 0)
			end
		end
	end)
	wrapMethod(class, "PlayGraveyard", function(original)
		return function(self, drop)
			if Config.SkipAnimation then
				-- what the game itself does when you're too far from the grave: straight to the reveal
				return self:Reveal(drop)
			end
			return original(self, drop)
		end
	end)
	return dropHooked
end

-- true while one of the game's reward scenes owns the camera and your character
local function sceneBusy()
	if State.Scene > 0 then
		return true
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	return playerGui ~= nil and playerGui:FindFirstChild("ExclusiveDrop") ~= nil
end

-- The rare-item popup ("Nice!" button) closes itself after 12s; this closes it as soon as the
-- game accepts a click (it ignores clicks for the first 0.8s).
local function closeRevealOnce()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local screen = playerGui and playerGui:FindFirstChild("ExclusiveDrop")
	if not screen then
		return
	end
	local button
	for _, inst in ipairs(screen:GetDescendants()) do
		if inst.Name == "ContinueButton" and inst:IsA("TextButton") then
			button = inst
			break
		end
	end
	if not button or button.TextTransparency > 0.5 then
		return -- not faded in yet
	end
	for _, method in ipairs(clickMethods(button)) do
		if method() then
			task.wait(0.8)
			if not screen.Parent then
				return
			end
		end
	end
end

-- The job-complete popup ("You've completed the job! ... Would you like to complete another for a
-- bonus 10%?" with Yes / No) is shown in the same PlayerGui.BigNotification as the Knock dialog.
-- Only messages containing one of these fragments get an automatic Yes, and anything that looks like
-- a payment never does.
local AUTO_YES_PHRASES = { "complete another" }
local NEVER_YES_WORDS = { "buy", "purchase", "robux", "spend", "trade", "sell", "delete" }
local lastYesAt = 0

local function plainText(inst)
	return (inst.Text:gsub("<[^>]+>", ""))
end

-- returns the visible "Yes" element and the message text, or nil
local function findYesPopup()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local root = playerGui and playerGui:FindFirstChild("BigNotification")
	if not root then
		return nil
	end
	local yes, message
	for _, inst in ipairs(root:GetDescendants()) do
		if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and isShown(inst) then
			local text = plainText(inst):lower()
			if text:match("^%s*yes%s*$") then
				yes = yes or inst
			elseif not message then
				for _, phrase in ipairs(AUTO_YES_PHRASES) do
					if text:find(phrase, 1, true) then
						message = text
						break
					end
				end
			end
		end
	end
	if not (yes and message) then
		return nil
	end
	for _, word in ipairs(NEVER_YES_WORDS) do
		if message:find(word, 1, true) then
			return nil
		end
	end
	return yes, message
end

local function autoYesOnce()
	if os.clock() - lastYesAt < 3 then
		return
	end
	local yes = findYesPopup()
	if not yes then
		return
	end
	task.wait(0.4) -- let the popup finish sliding in
	yes = findYesPopup()
	if not yes then
		return
	end
	lastYesAt = os.clock()
	log("Said Yes to the \"complete another job\" popup", THEME.Dim)
	for _, method in ipairs(clickMethods(yes)) do
		if method() then
			task.wait(0.6)
			if not findYesPopup() then
				break
			end
		end
	end
	-- the game starts the next job itself, so don't also accept one by hand for a moment
	State.RepoPending = os.clock() + 12
end

local function dismissLoop()
	while State.Running do
		restoreIdentity()
		pcall(flushLogs)
		pcall(applyStatus)
		if statsDirty then
			statsDirty = false
			pcall(drawStats)
		end
		if Config.Enabled and Config.AutoClose then
			pcall(closeRevealOnce)
		end
		if Config.Enabled and Config.AutoYes then
			pcall(autoYesOnce)
		end
		task.wait(0.25)
	end
end

--------------------------------------------------------------------------------------------------
-- Movement and the visit itself
--------------------------------------------------------------------------------------------------

local function travelTo(cf)
	local _, _, hrp = getCharacter()
	if not hrp then
		return false
	end
	if Config.Instant then
		hrp.CFrame = cf
		hrp.AssemblyLinearVelocity = Vector3.zero
		return true
	end

	local from = hrp.CFrame
	local duration = (cf.Position - from.Position).Magnitude / math.max(Config.Speed, 1)
	if duration <= 0.03 then
		hrp.CFrame = cf
		return true
	end
	local started = os.clock()
	while true do
		-- a reward scene is taking over the character: stop fighting it, the main loop re-plans
		if not active() or not hrp.Parent or State.Scene > 0 then
			return false
		end
		local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
		hrp.CFrame = from:Lerp(cf, alpha)
		hrp.AssemblyLinearVelocity = Vector3.zero
		if alpha >= 1 then
			return true
		end
		RunService.Heartbeat:Wait()
	end
end

-- The game's module hides every marker while its animation runs and redraws the rest afterwards,
-- so "markers are back" (and no Resident model left) means we are free to move on.
local function waitVisitEnd()
	local deadline = os.clock() + 25
	task.wait(0.2)
	while active() and os.clock() < deadline do
		if not State.Visiting and not Workspace:FindFirstChild("Resident") and #getMarkers() > 0 then
			return
		end
		task.wait(0.1)
	end
end

-- true = knocked, false = house didn't respond, nil = aborted/skipped (don't penalise the house)
local function visit(target)
	local char, hum, hrp = getCharacter()
	if not hrp then
		return nil
	end

	local bag = findBag()
	if bag and bag.Parent ~= char then
		pcall(hum.EquipTool, hum, bag)
	end

	-- the house model only exists on the client once it has streamed in
	local home = findHome(target.Lot)
	if not home then
		setStatus("Loading house " .. target.Lot, THEME.Warn)
		pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, target.Pos, 3)
		home = waitFor(function()
			return findHome(target.Lot)
		end, 2.5)
	end
	if not home then
		if not travelTo(CFrame.new(target.Pos + Vector3.new(0, 5, 0))) then
			return nil
		end
		home = waitFor(function()
			return findHome(target.Lot)
		end, 4)
	end
	if not home then
		log("House " .. target.Lot .. " never loaded, skipping", THEME.Bad)
		return false
	end

	local doorCF = home:GetAttribute("TrickOrTreatDoor")
	local standCF
	if typeof(doorCF) == "CFrame" then
		local look = Vector3.new(doorCF.LookVector.X, 0, doorCF.LookVector.Z)
		if look.Magnitude < 0.01 then
			look = Vector3.new(0, 0, -1)
		end
		local stand = doorCF:PointToWorldSpace(STAND_OFFSET)
		standCF = CFrame.lookAt(stand, stand + look)
	else
		standCF = CFrame.new(target.Pos + Vector3.new(0, 3.2, 0))
	end

	setStatus("Walking to house " .. target.Lot, THEME.Accent)
	if not travelTo(standCF) then
		return nil
	end
	task.wait(0.15)

	if markerGone(target) then
		return nil -- knocked elsewhere / claimed / new day while we were travelling
	end

	-- wait for the game to relabel the door prompts to "Knock or claim" (it does that within 60 studs)
	local prompts = {}
	waitFor(function()
		prompts = getPrompts(home)
		return prompts[1] and prompts[1].ActionText == KNOCK_ACTION
	end, 2)
	if #prompts == 0 then
		return false, "no door prompt"
	end

	local hookBefore = State.HookAt
	local function knocked()
		return State.HookAt > hookBefore or markerGone(target)
	end

	local sawDialog = false
	setStatus("Knocking at house " .. target.Lot, THEME.Accent)
	for _, prompt in ipairs(prompts) do
		if not active() then
			return nil
		end
		press(prompt)

		-- either the visit starts right away, or the Knock/Claim dialog opens
		local outcome = waitFor(function()
			return knocked() or findKnockButton()
		end, 2)

		if outcome and outcome ~= true then
			sawDialog = true
			task.wait(0.35) -- let the dialog finish sliding in so the click lands on the button
			outcome = findKnockButton() or outcome
			for _, method in ipairs(clickMethods(outcome)) do
				if method() and waitFor(knocked, 1.5) then
					outcome = true
					break
				end
			end
		end

		if outcome == true then
			setStatus("Collecting from house " .. target.Lot, THEME.Good)
			waitVisitEnd()
			return true
		end
	end
	return false, sawDialog and "clicked Knock but nothing happened" or "Knock dialog never appeared"
end

--------------------------------------------------------------------------------------------------
-- Graveyards
--------------------------------------------------------------------------------------------------
-- Workspace.Systems.Event.ActiveGraveyards holds today's graveyards. The game's Graveyards module
-- turns a graveyard's ProximityPrompt off once it has been searched (checked every 5s and whenever
-- your data updates), so "prompt enabled" = still searchable and "prompt disabled" = done.

local function graveyardPrompts(model)
	local prompts = {}
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("ProximityPrompt") then
			table.insert(prompts, inst)
		end
	end
	return prompts
end

local function promptPosition(prompt)
	local parent = prompt.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	return nil
end

local function getGraveyards()
	local systems = Workspace:FindFirstChild("Systems")
	local event = systems and systems:FindFirstChild("Event")
	local folder = event and event:FindFirstChild("ActiveGraveyards")
	local stops = {}
	if not folder then
		return stops
	end
	local now = os.clock()
	for _, model in ipairs(folder:GetChildren()) do
		local id = model:GetAttribute("GraveyardId")
		if type(id) == "string" and model:IsA("PVInstance") and (State.Searched[id] or 0) <= now then
			-- no prompts yet means the model hasn't streamed in, so we can't tell; go and look
			local prompts = graveyardPrompts(model)
			local open = #prompts == 0
			for _, prompt in ipairs(prompts) do
				if prompt.Enabled then
					open = true
					break
				end
			end
			if open then
				table.insert(stops, {
					Kind = "graveyard",
					Key = "G:" .. id,
					Id = id,
					Model = model,
					Pos = model:GetPivot().Position,
				})
			end
		end
	end
	return stops
end

-- a spot just beside the prompt, on the side we're coming from, a little above the ground
local function standNear(pos)
	local _, _, hrp = getCharacter()
	local from = hrp and hrp.Position or pos
	local away = Vector3.new(from.X - pos.X, 0, from.Z - pos.Z)
	if away.Magnitude < 0.1 then
		away = Vector3.new(0, 0, 1)
	end
	local stand = pos + away.Unit * 3 + Vector3.new(0, 3, 0)
	return CFrame.lookAt(stand, Vector3.new(pos.X, stand.Y, pos.Z))
end

-- true = searched, false = prompt didn't respond, nil = aborted / already searched
local function searchGraveyard(target)
	local _, _, hrp = getCharacter()
	if not hrp or not target.Model.Parent then
		return nil
	end
	local model = target.Model

	local prompts = graveyardPrompts(model)
	if #prompts == 0 then
		setStatus("Loading graveyard " .. target.Id, THEME.Warn)
		pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, target.Pos, 3)
		waitFor(function()
			prompts = graveyardPrompts(model)
			return #prompts > 0
		end, 2.5)
		if #prompts == 0 then
			if not travelTo(CFrame.new(target.Pos + Vector3.new(0, 5, 0))) then
				return nil
			end
			waitFor(function()
				prompts = graveyardPrompts(model)
				return #prompts > 0
			end, 4)
		end
	end
	if #prompts == 0 then
		return false, "graveyard never loaded"
	end

	local open = {}
	for _, prompt in ipairs(prompts) do
		if prompt.Enabled then
			table.insert(open, prompt)
		end
	end
	if #open == 0 then
		State.Searched[target.Id] = os.clock() + 600 -- already done today; don't come back for a while
		return nil
	end

	for _, prompt in ipairs(open) do
		local pos = promptPosition(prompt) or target.Pos
		setStatus("Searching graveyard " .. target.Id, THEME.Accent)
		if not travelTo(standNear(pos)) then
			return nil
		end
		task.wait(0.15)
		press(prompt)
		local done = waitFor(function()
			return not prompt.Enabled or not prompt:IsDescendantOf(Workspace)
		end, 6)
		if done then
			State.Searched[target.Id] = os.clock() + 300
			return true
		end
	end
	return false, "prompt didn't respond"
end

--------------------------------------------------------------------------------------------------
-- Repo job (tow truck)
--------------------------------------------------------------------------------------------------
-- Flow of the game's Jobs_Repo module: join the Repo team -> accept a contract -> a rental truck
-- spawns ("Enter the rental truck!") -> drive to the marked pickup (progress 0) -> load the car with
-- the ramp / winch (progress 1-2) -> drive to the impound (progress 3). When you get near a marker
-- the game's own GPS reports it to the server, so the script only has to move the truck there.
-- The arm steps use the wrecker's own remote (see fireWrecker); lowering the arm has no call we know of.

local repoClass
local lastGcScan = 0

local function installRepoHook()
	repoClass = loadModule("GUIManager", "Jobs_Repo")
	if not repoClass then
		return false
	end
	-- the module's instance holds the live task (instance.stats.Temporary.Jobs.ActiveTask); grab it
	-- the next time the game updates it
	return wrapMethod(repoClass, "Update", function(original)
		return function(self, stats)
			State.Repo = self
			return original(self, stats)
		end
	end)
end

local function getRepo()
	if State.Repo then
		return State.Repo
	end
	if getgc and repoClass and os.clock() - lastGcScan > 5 then
		lastGcScan = os.clock()
		local ok, objects = pcall(getgc, true)
		if ok and type(objects) == "table" then
			for _, obj in ipairs(objects) do
				if type(obj) == "table" and getmetatable(obj) == repoClass then
					State.Repo = obj
					return obj
				end
			end
		end
	end
	return nil
end

local function activeJob(repo)
	local ok, job = pcall(function()
		return repo.stats.Temporary.Jobs.ActiveTask
	end)
	return ok and job or nil
end

local function destinationOf(job, index)
	local destination = job.Destinations and job.Destinations[index]
	if type(destination) == "table" and destination.X then
		return Vector3.new(destination.X, destination.Y, destination.Z)
	end
	return nil
end

-- the contract list is keyed the way the game's own menu passes it to AcceptTask
local function repoTaskKey(ordinal)
	local jobsFolder = sharedModules and sharedModules:FindFirstChild("Jobs")
	local data = tryRequire(jobsFolder and jobsFolder:FindFirstChild("Repo"))
	local tasks = data and data.Tasks
	if type(tasks) ~= "table" then
		return ordinal
	end
	if #tasks > 0 then
		return math.clamp(ordinal, 1, #tasks)
	end
	local keys = {}
	for key in pairs(tasks) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys[math.clamp(ordinal, 1, math.max(#keys, 1))] or ordinal
end

local function findContractsDesk()
	for _, prompt in ipairs(CollectionService:GetTagged("Jobs_ProximityPrompt")) do
		if prompt.Name == "Repo_Contracts" and prompt:IsA("ProximityPrompt") then
			return promptPosition(prompt)
		end
	end
	return nil
end

local function acceptRepoTask()
	local events = ReplicatedStorage:FindFirstChild("Events")
	local jobsEvents = events and events:FindFirstChild("Jobs")
	local joinTeam = jobsEvents and jobsEvents:FindFirstChild("JoinTeam")
	local acceptTask = jobsEvents and jobsEvents:FindFirstChild("AcceptTask")
	if not (joinTeam and acceptTask) then
		setStatus("Repo remotes not found (ReplicatedStorage.Events.Jobs)", THEME.Bad)
		task.wait(2)
		return
	end

	-- the game opens its contract menu at the desk, so be standing there like a player would
	local _, _, hrp = getCharacter()
	local desk = findContractsDesk()
	if hrp and desk and (desk - hrp.Position).Magnitude > 25 then
		setStatus("Going to the Repo contracts desk…", THEME.Accent)
		if not travelTo(standNear(desk)) then
			return
		end
	end

	local repoTeam = Teams:FindFirstChild("Repo")
	if repoTeam and LocalPlayer.Team ~= repoTeam then
		setStatus("Joining the Repo team…", THEME.Accent)
		joinTeam:FireServer("Repo")
		waitFor(function()
			return LocalPlayer.Team == repoTeam
		end, 4)
	end

	local key = repoTaskKey(Config.RepoTask)
	setStatus("Accepting Repo contract " .. tostring(key) .. "…", THEME.Accent)
	acceptTask:FireServer("Repo", key, nil) -- nil = rent the company truck, same as the menu's default
	State.RepoPending = os.clock() + 10
	log("Accepted Repo contract " .. tostring(key), THEME.Dim)
end

-- A truck counts as spawned only once it is fully built (seat and wheels present). The game's own HUD
-- script reads vehicle.Wheels and errors ("Wheels is not a valid member of Model") on a model that is
-- still being assembled or torn down, and we shouldn't sit in or move one in that state either.
local function truckBuilt(vehicle)
	return vehicle:FindFirstChild("DriveSeat") ~= nil and vehicle:FindFirstChild("Wheels") ~= nil
end

local function findRepoTruck(repo, job)
	local truck = repo.TowTruck
	if typeof(truck) == "Instance" and truck:IsDescendantOf(Workspace) and truckBuilt(truck) then
		return truck
	end
	local systems = Workspace:FindFirstChild("Systems")
	local vehicles = systems and systems:FindFirstChild("Vehicles")
	for _, vehicle in ipairs(vehicles and vehicles:GetChildren() or {}) do
		if vehicle.Name == LocalPlayer.Name
			and vehicle:GetAttribute("JobVehicle")
			and (not job.VehicleName or vehicle:GetAttribute("Name") == job.VehicleName)
			and truckBuilt(vehicle)
		then
			return vehicle
		end
	end
	return nil
end

local function sitIn(truck)
	local _, hum, hrp = getCharacter()
	local seat = truck:FindFirstChild("DriveSeat")
	if not (hum and hrp and seat) then
		return false
	end
	if seat.Occupant == hum then
		return true
	end

	-- the game seats you through the "Sit Drive Seat" prompt on the seat itself
	local prompt = seat:FindFirstChild("SeatPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		if (seat.Position - hrp.Position).Magnitude > 8 then
			if not travelTo(standNear(seat.Position)) then
				return false
			end
			task.wait(0.15)
		end
		press(prompt)
	else
		pcall(function()
			seat:Sit(hum)
		end)
		hrp.CFrame = seat.CFrame * CFrame.new(0, 1.5, 0) -- fall back to sitting by touch
	end
	return waitFor(function()
		return seat.Occupant == hum
	end, 3) ~= nil
end

-- glide the whole truck (you're welded to it) to a spot just above the marker
local function driveTruck(truck, destination)
	local _, hum = getCharacter()
	local seat = truck:FindFirstChild("DriveSeat")
	if not (hum and seat) then
		return false
	end
	local target = destination + Vector3.new(0, 5, 0)
	local startCF = truck:GetPivot()
	local startPos = startCF.Position
	if (target - startPos).Magnitude < 15 then
		return true
	end

	-- straight up to the cruise height, level across the map, then straight down onto the marker
	local waypoints = { startPos }
	local flatDistance = Vector3.new(target.X - startPos.X, 0, target.Z - startPos.Z).Magnitude
	if Config.RepoHeight > 0 and flatDistance > 60 then
		local cruise = math.max(startPos.Y, target.Y) + Config.RepoHeight
		table.insert(waypoints, Vector3.new(startPos.X, cruise, startPos.Z))
		table.insert(waypoints, Vector3.new(target.X, cruise, target.Z))
	end
	table.insert(waypoints, target)

	local total = 0
	for i = 2, #waypoints do
		total += (waypoints[i] - waypoints[i - 1]).Magnitude
	end
	-- the server decides whether an arrival counts, so speed is its own setting (raise it step by step)
	local duration = total / math.max(Config.RepoSpeed, 1)
	local started = os.clock()
	while true do
		if not active() or not truck:IsDescendantOf(Workspace) or seat.Occupant ~= hum then
			return false
		end
		local travelled = math.clamp((os.clock() - started) / duration, 0, 1) * total

		local position = target
		local remaining = travelled
		for i = 2, #waypoints do
			local length = (waypoints[i] - waypoints[i - 1]).Magnitude
			if remaining <= length or i == #waypoints then
				position = waypoints[i - 1]:Lerp(waypoints[i], length > 0 and math.min(remaining / length, 1) or 1)
				break
			end
			remaining -= length
		end

		truck:PivotTo(CFrame.new(position) * startCF.Rotation)
		seat.AssemblyLinearVelocity = Vector3.zero
		seat.AssemblyAngularVelocity = Vector3.zero
		if travelled >= total then
			return true
		end
		RunService.Heartbeat:Wait()
	end
end

-- ReplicatedStorage.Events.Vehicles.Wrecker, as captured from a real run:
--   Wrecker:FireServer("Grab", truck, targetCar, groundPointNearTheWheel)  (the game repeats it ~2/s)
--   Wrecker:FireServer("DetachCar", truck)
local function fireWrecker(...)
	local events = ReplicatedStorage:FindFirstChild("Events")
	local vehicles = events and events:FindFirstChild("Vehicles")
	local remote = vehicles and vehicles:FindFirstChild("Wrecker")
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(...)
		return true
	end
	return false
end

-- the car you have to tow, spawned for you under Systems.Jobs.Repo.SpawnedVehicles
local function targetCar()
	local systems = Workspace:FindFirstChild("Systems")
	local jobsFolder = systems and systems:FindFirstChild("Jobs")
	local repoFolder = jobsFolder and jobsFolder:FindFirstChild("Repo")
	local spawned = repoFolder and repoFolder:FindFirstChild("SpawnedVehicles")
	return spawned and spawned:FindFirstChild(LocalPlayer.Name)
end

-- where the arm could take hold: each wheel (nearest to `from` first), or the car itself
local function grabPoints(car, from)
	local points = {}
	local wheels = car:FindFirstChild("Wheels")
	for _, wheel in ipairs(wheels and wheels:GetChildren() or {}) do
		if wheel:IsA("BasePart") then
			table.insert(points, wheel.Position)
		elseif wheel:IsA("Model") then
			table.insert(points, wheel:GetPivot().Position)
		end
	end
	if #points == 0 then
		table.insert(points, car:GetPivot().Position)
	end
	table.sort(points, function(a, b)
		return (a - from).Magnitude < (b - from).Magnitude
	end)
	return points
end

local function parkBeside(truck, car)
	local carPos = car:GetPivot().Position
	local truckPos = truck:GetPivot().Position
	local away = Vector3.new(truckPos.X - carPos.X, 0, truckPos.Z - carPos.Z)
	if away.Magnitude < 1 then
		away = Vector3.new(0, 0, 1)
	end
	local spot = carPos + away.Unit * 20 + Vector3.new(0, 3, 0)
	truck:PivotTo(CFrame.lookAt(spot, Vector3.new(carPos.X, spot.Y, carPos.Z)))
	local seat = truck:FindFirstChild("DriveSeat")
	if seat then
		seat.AssemblyLinearVelocity = Vector3.zero
		seat.AssemblyAngularVelocity = Vector3.zero
	end
end

-- Fire the game's own Grab call the way it does (about twice a second) until the task moves on.
-- true = progress changed, false = nothing happened within 20s.
local function grabCar(repo, truck, car, guid, progress)
	if (truck:GetPivot().Position - car:GetPivot().Position).Magnitude > 35 then
		parkBeside(truck, car)
		task.wait(0.3)
	end
	local points = grabPoints(car, truck:GetPivot().Position)
	local deadline = os.clock() + 20
	local index = 0
	while active() and os.clock() < deadline do
		local current = activeJob(repo)
		if not current or current.GUID ~= guid or current.Progress ~= progress then
			return true
		end
		index = index % #points + 1
		fireWrecker("Grab", truck, car, points[index])
		task.wait(0.5)
	end
	return false
end

local MAX_TRUCK_RESPAWNS = 2 -- per arm step, before leaving it to you

-- The menu's "respawn your rental tow truck" button (after its Yes/No) just fires this remote; the
-- game says the truck respawns next to you and no progress is lost.
local function respawnRepoTruck(repo, job, oldTruck)
	local events = ReplicatedStorage:FindFirstChild("Events")
	local jobsEvents = events and events:FindFirstChild("Jobs")
	local remote = jobsEvents and jobsEvents:FindFirstChild("RespawnVehicle")
	if not (remote and remote:IsA("RemoteEvent")) then
		log("RespawnVehicle remote not found", THEME.Bad)
		return false
	end
	setStatus("Respawning the rental truck…", THEME.Accent)
	remote:FireServer()
	-- the old model goes away and a new one appears; wait until we can see a different truck
	local replaced = waitFor(function()
		local current = findRepoTruck(repo, job)
		return current and current ~= oldTruck and current:IsDescendantOf(Workspace) or nil
	end, 12)
	if replaced then
		task.wait(1) -- let the new truck finish loading before anything sits in it or moves it
	end
	return replaced ~= nil
end

local repoRespawns = {} -- "guid:progress" -> how many times we've respawned the truck at that step
local repoGrabTried -- "guid:progress" of a stage where the automatic grab didn't advance the task
local repoDetached -- GUID of the job whose car we already released at the impound
local repoLastSeen -- { Progress, Goal } of the job on the previous tick

local function repoTick()
	local _, hum, hrp = getCharacter()
	if not hrp then
		setStatus("Waiting for your character…", THEME.Warn)
		task.wait(0.5)
		return
	end

	local repo = getRepo()
	local job = repo and activeJob(repo)

	if job and job.JobName ~= "Repo" then
		setStatus("Another job is running (" .. tostring(job.JobName) .. ")", THEME.Warn)
		task.wait(1)
		return
	end

	if not job then
		if repoLastSeen then
			local last = repoLastSeen
			repoLastSeen = nil
			if last.Progress >= last.Goal - 1 then
				State.Repos += 1
				log("Repo job finished (" .. State.Repos .. " this session)", THEME.Good)
			else
				log("Repo job ended early", THEME.Warn)
			end
		end
		if Config.AutoYes and findYesPopup() then
			setStatus("Answering the job-complete popup…", THEME.Dim)
			task.wait(0.5)
			return
		end
		if os.clock() < State.RepoPending then
			setStatus("Waiting for the contract to start…", THEME.Dim)
			task.wait(0.5)
			return
		end
		if not repo and State.RepoPending > 0 then
			-- we accepted a contract but never got to read the job state
			setStatus("Can't read the job state yet (waiting for the game to update it)", THEME.Warn)
			task.wait(1)
			return
		end
		acceptRepoTask()
		return
	end

	local guid, progress, goal = job.GUID, job.Progress or 0, job.Goal or 4
	repoLastSeen = { Progress = progress, Goal = goal }

	local truck = findRepoTruck(repo, job)
	if not truck then
		setStatus("Waiting for the rental truck to spawn…", THEME.Dim)
		task.wait(0.5)
		return
	end
	if not sitIn(truck) then
		setStatus("Couldn't get into the truck", THEME.Warn)
		task.wait(1)
		return
	end

	-- the arm steps: fire the game's Grab call at the target car
	if progress >= 1 and progress < 3 then
		local stage = tostring(guid) .. ":" .. progress
		if repoGrabTried == stage then
			setStatus("Do the arm steps by hand (the automatic grab didn't work)", THEME.Warn)
			task.wait(0.5)
			return
		end
		local car = targetCar()
		if not car then
			setStatus("Waiting for the target car…", THEME.Dim)
			task.wait(0.5)
			return
		end
		setStatus("Grabbing the car with the arm…", THEME.Accent)
		if not grabCar(repo, truck, car, guid, progress) and active() then
			local respawns = repoRespawns[stage] or 0
			if job.VehicleName and respawns < MAX_TRUCK_RESPAWNS then
				-- a fresh truck usually clears a stuck arm; progress is kept
				repoRespawns[stage] = respawns + 1
				log(
					string.format(
						"Grab didn't take at step %d, respawning the rental truck (%d/%d)",
						progress,
						respawns + 1,
						MAX_TRUCK_RESPAWNS
					),
					THEME.Warn
				)
				if not respawnRepoTruck(repo, job, truck) then
					log("No replacement truck showed up", THEME.Warn)
				end
			else
				repoGrabTried = stage
				log(
					"Fired Grab for 20s but the task stayed at step " .. progress .. "; the arm may need lowering first. Do it by hand",
					THEME.Warn
				)
			end
		end
		return
	end

	local destination = destinationOf(job, progress == 0 and 1 or 2)
	if not destination then
		setStatus("Waiting for the destination…", THEME.Dim)
		task.wait(0.5)
		return
	end

	setStatus(progress == 0 and "Driving to the pickup…" or "Driving to the impound…", THEME.Accent)
	if not driveTruck(truck, destination) then
		return
	end

	-- at the impound the car has to be let go: the game's own call, captured from a real run
	if progress >= 3 and repoDetached ~= guid then
		repoDetached = guid
		setStatus("Releasing the car at the impound…", THEME.Accent)
		if fireWrecker("DetachCar", truck) then
			log("Released the car at the impound", THEME.Dim)
		end
		task.wait(1)
	end

	-- the game's GPS should now notice we're there and tell the server; wait for progress to move
	setStatus("Waiting for the game to register arrival…", THEME.Dim)
	local moved = waitFor(function()
		local current = activeJob(repo)
		return not current or current.GUID ~= guid or current.Progress ~= progress or nil
	end, 12)
	if not moved then
		-- The game's GPS finishes a route when your character is within 75 studs of its goal, then asks
		-- the server to advance the task; if the server says no, the module just restarts the GPS.
		-- Report what the client sees so we can tell which side is failing.
		local gps = select(2, pcall(function()
			return repo.GUIManager.Client.Modules.Client.GPS
		end))
		local goal = type(gps) == "table" and gps.Goal
		local goalPos = typeof(goal) == "Vector3" and goal or (typeof(goal) == "Instance" and goal.Position) or nil
		local _, _, nowHrp = getCharacter()
		log(
			string.format(
				"Arrived but the task didn't advance. GPS %s, %s studs from its goal, seated: %s",
				(type(gps) == "table" and gps.Code) and "running" or "NOT running",
				(goalPos and nowHrp) and tostring(math.floor((nowHrp.Position - goalPos).Magnitude)) or "?",
				tostring(truck:FindFirstChild("DriveSeat") and truck.DriveSeat.Occupant == hum)
			),
			THEME.Warn
		)
		truck:PivotTo(CFrame.new(destination + Vector3.new(0, 5, 0)) * truck:GetPivot().Rotation)
	end
end

--------------------------------------------------------------------------------------------------
-- Auto refuel
--------------------------------------------------------------------------------------------------
-- From the game's Fueling module: a car's tank is Values.CurrentFuel (0-100), a full refill costs
-- (100 - fuel) * 10 cash, and refuelling is Events.Vehicles.RefuelVehicle:FireServer(carName) with the
-- car's "Name" attribute. The game opens its fuel menu at prompts tagged "FuelingPrompt"; a prompt whose
-- parent is called "Charging" is an EV charger, the others are pumps (the menu refuses the wrong kind).
-- So: stand at the right kind of station, send the same call, and fall back to the menu's Fill button.

local fuelTick -- returns true when it spent this loop iteration refuelling
do
	local fuelRetryAt = 0

	-- the car you are sitting in (the game's own rule: SeatPart's parent is a model named after you)
	local function seatedVehicle()
		local _, hum = getCharacter()
		local seat = hum and hum.SeatPart
		local vehicle = seat and seat.Parent
		if vehicle and vehicle:IsA("Model") and vehicle.Name == LocalPlayer.Name and not vehicle:GetAttribute("Trailer") then
			return vehicle
		end
		return nil
	end

	local function fuelOf(vehicle)
		local values = vehicle:FindFirstChild("Values")
		local fuel = values and values:FindFirstChild("CurrentFuel")
		if fuel and fuel:IsA("NumberValue") then
			return fuel.Value
		end
		return nil
	end

	local function nearestStation(electric, from)
		local best, bestDistance
		for _, prompt in ipairs(CollectionService:GetTagged("FuelingPrompt")) do
			if prompt:IsA("ProximityPrompt") and prompt:IsDescendantOf(Workspace) then
				local isCharger = prompt.Parent ~= nil and prompt.Parent.Name == "Charging"
				local position = promptPosition(prompt)
				if isCharger == electric and position then
					local distance = (position - from).Magnitude
					if not bestDistance or distance < bestDistance then
						best, bestDistance = { Prompt = prompt, Pos = position }, distance
					end
				end
			end
		end
		return best
	end

	-- the menu's Fill button (PlayerGui.Fueling.Frame.FuelPanel.FuelBar.FillButton), once it is showing
	local function fillButton()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local node = playerGui
		for _, name in ipairs({ "Fueling", "Frame", "FuelPanel", "FuelBar", "FillButton" }) do
			node = node and node:FindFirstChild(name)
		end
		if node and isShown(node) then
			return node
		end
		return nil
	end

	local function refuelVehicle(vehicle)
		local electric = vehicle:GetAttribute("Electric") == true
		local _, _, hrp = getCharacter()
		if not hrp then
			return false
		end
		local station = nearestStation(electric, hrp.Position)
		if not station then
			log("Fuel: no " .. (electric and "charging station" or "fuel station") .. " is loaded near you; get closer to one", THEME.Warn)
			return false
		end

		setStatus(electric and "Going to a charger…" or "Going to a fuel station…", THEME.Accent)
		local arrived
		if seatedVehicle() == vehicle then
			arrived = driveTruck(vehicle, station.Pos) -- carries you along, you're seated in it
		else
			arrived = travelTo(standNear(station.Pos))
		end
		if not arrived then
			return false
		end
		task.wait(0.3)

		local events = ReplicatedStorage:FindFirstChild("Events")
		local vehicleEvents = events and events:FindFirstChild("Vehicles")
		local remote = vehicleEvents and vehicleEvents:FindFirstChild("RefuelVehicle")
		if not (remote and remote:IsA("RemoteEvent")) then
			log("Fuel: the RefuelVehicle remote wasn't found", THEME.Bad)
			return false
		end

		local before = fuelOf(vehicle) or 0
		setStatus(electric and "Charging…" or "Refuelling…", THEME.Accent)
		remote:FireServer(vehicle:GetAttribute("Name"))
		local filled = waitFor(function()
			return (fuelOf(vehicle) or 0) > before + 1 or nil
		end, 4)

		if not filled then
			-- same as a player: use the station's prompt to open the menu, then press Fill
			press(station.Prompt)
			local button = waitFor(fillButton, 3)
			if button then
				task.wait(0.3)
				for _, method in ipairs(clickMethods(button)) do
					if method() and waitFor(function()
						return (fuelOf(vehicle) or 0) > before + 1 or nil
					end, 3) then
						break
					end
				end
			end
		end

		local after = fuelOf(vehicle) or before
		if after > before + 1 then
			log(string.format("Fuel: %d%% -> %d%%", math.round(before), math.round(after)), THEME.Good)
			return true
		end
		log("Fuel: the tank didn't fill (not enough cash, or you weren't close enough to the station)", THEME.Warn)
		return false
	end

	function fuelTick()
		if not Config.AutoFuel or os.clock() < fuelRetryAt then
			return false
		end
		local vehicle = seatedVehicle()
		local fuel = vehicle and fuelOf(vehicle)
		if not (vehicle and fuel) or fuel > Config.FuelBelow then
			return false
		end
		log(string.format("Fuel: tank at %d%%, refuelling", math.round(fuel)), THEME.Warn)
		State.CruisePause = true -- the highway autopilot steps aside while we move the car to a station
		local called, refuelled = pcall(refuelVehicle, vehicle)
		State.CruisePause = false
		if not called then
			log("Fuel error: " .. tostring(refuelled), THEME.Bad)
		end
		if not (called and refuelled) then
			fuelRetryAt = os.clock() + 30 -- don't keep trying every loop if it can't work right now
		end
		return true
	end
end

--------------------------------------------------------------------------------------------------
-- Car parts (garage parts shop)
--------------------------------------------------------------------------------------------------
-- Uses the same Tuning module and shop instance as GUIManager.Customization.PartsShop. The shop
-- instance is picked up when the game builds it (or found with getgc); its Api is the one the shop's
-- own Buy button uses, and Api:InstallBought puts a part in your cart and fits it. Nothing is paid
-- for until you check out in the garage.

-- Everything below lives in its own block so its locals don't count against the 200-locals limit of
-- this chunk; only these five names are used by the rest of the script.
local Tuning, CAR_GOALS, carGoal, installShopHook, carLoop
do
local modulesShared = ReplicatedStorage:FindFirstChild("Modules")
modulesShared = modulesShared and modulesShared:FindFirstChild("Shared")
local customizationShared = modulesShared and modulesShared:FindFirstChild("Customization")
local featuresFolder = customizationShared and customizationShared:FindFirstChild("Features")
Tuning = tryRequire(featuresFolder and featuresFolder:FindFirstChild("Tuning"))
local TuningUtil = tryRequire(customizationShared and customizationShared:FindFirstChild("Util"))

local shopClass
local lastShopScan = 0

function installShopHook()
	shopClass = loadModule("GUIManager", "Customization", "PartsShop")
	if not shopClass then
		return false
	end
	return wrapMethod(shopClass, "new", function(original)
		return function(frame, api)
			local shop = original(frame, api)
			State.Shop = shop
			return shop
		end
	end)
end

local function shopUsable(shop)
	return type(shop) == "table" and shop.Api ~= nil and shop.Frame ~= nil and shop.Frame.Parent ~= nil
end

local function getShop()
	if shopUsable(State.Shop) then
		return State.Shop
	end
	State.Shop = nil
	if getgc and shopClass and os.clock() - lastShopScan > 3 then
		lastShopScan = os.clock()
		local ok, objects = pcall(getgc, true)
		if ok and type(objects) == "table" then
			local fallback
			for _, obj in ipairs(objects) do
				if type(obj) == "table" and getmetatable(obj) == shopClass and shopUsable(obj) then
					if obj.Frame.Visible then
						State.Shop = obj
						return obj
					end
					fallback = fallback or obj
				end
			end
			State.Shop = fallback
		end
	end
	return State.Shop
end

-- What "best" means. Each weight is points per 1% change in that stat versus the car as it was when
-- you pressed the button (for the lower-is-better stats, shift/flywheel/weight, a 1% cut counts as
-- a 1% gain); "gears" is points per extra gear. A part is only taken if it raises the total.
CAR_GOALS = {
	{
		Id = "balanced",
		Name = "Balanced",
		Desc = "Balanced: top speed and peak power count equally.",
		Weights = { top = 100, hp = 100 },
	},
	{
		Id = "power",
		Name = "Max horsepower",
		Desc = "Max horsepower: peak power first, with a little weight on torque.",
		Weights = { hp = 100, torque = 30 },
	},
	{
		Id = "speed",
		Name = "Top speed",
		Desc = "Top speed: the highest top speed; power only breaks ties.",
		Weights = { top = 100, hp = 10 },
	},
	{
		Id = "accel",
		Name = "Acceleration",
		Desc = "Acceleration: torque and power, quicker shifts, faster revs and less weight.",
		Weights = { torque = 60, hp = 40, shift = 40, flywheel = 30, weight = 40 },
	},
	{
		Id = "gears",
		Name = "Quick gears",
		Desc = "Quick gears: shorter shift times, more gears and faster rev response.",
		Weights = { shift = 100, gears = 10, flywheel = 30 },
	},
}

function carGoal(id)
	for _, goal in ipairs(CAR_GOALS) do
		if goal.Id == id then
			return goal
		end
	end
	return CAR_GOALS[1]
end

-- the stats a goal is scored on, for the car with `value` fitted
local function carMetrics(shop, value)
	local aggregate = Tuning.aggregate(value, shop.Fit)
	local metrics = { aggregate = aggregate }

	local okTop, top = pcall(Tuning.topSpeedMult, shop.FactoryTopSpeed, aggregate, shop.Tune)
	metrics.top = (okTop and type(top) == "number") and top or 1

	local okPeak, hp, torque = pcall(shop.Peaks, shop, value)
	if okPeak and type(hp) == "number" then
		metrics.hp = hp
		metrics.torque = type(torque) == "number" and torque or nil
	else
		metrics.hp = math.max(shop.BaseHP or 1, 1)
			+ (aggregate.Horsepower or 0)
			+ (aggregate.Turbo or 0)
			+ (aggregate.Supercharger or 0)
	end

	metrics.shift = aggregate.ShiftTimeMult or 1
	metrics.flywheel = aggregate.FlywheelMult or 1

	local okGears, gears = pcall(function()
		local factory = TuningUtil.factoryGears(shop.Tune)
		return factory and Tuning.gearCount(factory, aggregate.GearDelta)
	end)
	metrics.gears = (okGears and type(gears) == "number") and gears or nil

	local okWeight, weight = pcall(TuningUtil.weightPounds, shop.Tune, aggregate, shop.BaseHP)
	metrics.weight = (okWeight and type(weight) == "number") and weight or nil
	return metrics
end

local function goalScore(goal, metrics, base)
	local weights = goal.Weights
	local score = 0
	for _, key in ipairs({ "top", "hp", "torque" }) do -- higher is better
		if weights[key] and metrics[key] and base[key] and base[key] ~= 0 then
			score += weights[key] * (metrics[key] / base[key] - 1)
		end
	end
	for _, key in ipairs({ "shift", "flywheel", "weight" }) do -- lower is better
		if weights[key] and metrics[key] and base[key] and metrics[key] ~= 0 then
			score += weights[key] * (base[key] / metrics[key] - 1)
		end
	end
	if weights.gears and metrics.gears and base.gears then
		score += weights.gears * (metrics.gears - base.gears)
	end
	return score
end

-- The shop's own filters (partsForSlot / InstallProblem) are what the game shows you, but the server
-- can still refuse a part at checkout ("not available on this vehicle"). The server's check is
-- Tuning.Validate(previous, new, ctx), whose "not available on this vehicle" case is Tuning.partFits:
-- the part, its slot AND its category must all fit the car (partsForSlot only looks at the part).

local function partFitsCar(part, fit)
	local ok, result = pcall(Tuning.partFits, part, fit)
	if ok then
		return result == true
	end
	local okFits, fits = pcall(Tuning.fits, part, fit)
	return not (okFits and fits == false)
end

-- Ask the same function the server will run on checkout. It also covers exclusive slots,
-- "requires a ...", capacity and level. true = fine (or we couldn't ask); false, reason = refused.
local function serverVerdict(baseline, trial, validateCtx)
	local ok, valid, reason = pcall(Tuning.Validate, baseline, trial, validateCtx)
	if not ok then
		return true
	end
	return valid == true, reason
end

-- names or ids you typed into the "Skip parts" box on the Car tab (comma separated, any part of it)
local function skippedByUser(partId, part)
	local skip = string.lower(Config.CarSkip or "")
	if skip == "" then
		return false
	end
	local id = string.lower(tostring(partId))
	local okLabel, name = pcall(Tuning.label, part)
	name = string.lower(okLabel and tostring(name) or "")
	for fragment in string.gmatch(skip, "[^,]+") do
		local trimmed = fragment:match("^%s*(.-)%s*$")
		if trimmed ~= "" and (id:find(trimmed, 1, true) or name:find(trimmed, 1, true)) then
			return true
		end
	end
	return false
end

-- Picks the parts for your goal. Each round it tries every part that could still go on (and, for a
-- part that needs another part first, that part together with it), checks the result with the
-- server's own rules (Tuning.Validate), prices it with the server's own pricing (Tuning.purchasePlan),
-- and takes the move with the best gain for what it uses up (capacity and cash). So when capacity or
-- cash is limited it goes where it earns most, instead of to whichever slot happens to come first.
-- It repeats until nothing improves. apply = false only reports the plan.
local function runTuner(apply)
	if not (Tuning and TuningUtil) then
		log("Car parts: the Tuning modules weren't found", THEME.Bad)
		return
	end
	local shop = getShop()
	if not shop then
		log("Car parts: open the car's parts shop in the garage first, then press the button", THEME.Warn)
		return
	end
	if not shop:IsOpen() then
		log("Car parts: the parts shop isn't open", THEME.Warn)
		return
	end

	-- if something throws, the error report names the last step reached
	local function mark(name)
		State.CarStep = name
	end

	mark("api")
	local api = shop.Api
	local ctx = api:Ctx()
	local fit = shop.Fit
	mark("player data")
	local data = api:PlayerData()
	local cash = data.Cash or 0
	local budget = Config.CarMaxSpend > 0 and math.min(cash, Config.CarMaxSpend) or cash
	mark("capacity")
	local factoryOutput = Tuning.factoryOutputOf(ctx)
	local capacity = Tuning.capacityOf(ctx)
	-- what Tuning.Validate needs: the saved tuning to compare against, and a ctx that carries your data
	mark("validate context")
	local validateCtx = table.clone(ctx)
	validateCtx.playerData = validateCtx.playerData or data
	local baseline = api:GetBaseline("Tuning")
	local goal = carGoal(Config.CarGoal)

	mark("current tuning value")
	local live = api:Get("Tuning")
	live.Parts = live.Parts or {}
	live.FineTune = live.FineTune or {}
	local sim = TuningUtil.deepCopy(live) -- the car as the plan builds it up, nothing is installed yet

	-- what the whole cart would cost, by the server's own pricing (parts you already own are free)
	local function priceOf(value)
		local _, total = Tuning.purchasePlan(data, baseline, value)
		return total or 0
	end

	mark("starting stats")
	local baseMetrics = carMetrics(shop, sim)
	local startPrice = priceOf(sim)
	local startUsed = Tuning.usedCapacity(sim, factoryOutput)
	local simScore, simPrice, simUsed = 0, startPrice, startUsed
	log(
		string.format(
			"Car: planning for %s (capacity %d/%d, budget %s)",
			goal.Name:lower(),
			startUsed,
			capacity,
			formatNumber(budget)
		),
		THEME.Dim
	)
	setStatus("Planning parts: " .. goal.Name:lower() .. "…", THEME.Accent)

	local rejected = {} -- part id -> why the server's rules turn it down (counted once)

	-- try a move (a list of { Slot, Id } installed in order); nil if it isn't allowed or doesn't help
	local function consider(steps)
		local trial = TuningUtil.deepCopy(sim)
		for _, step in ipairs(steps) do
			Tuning.install(trial, step.Slot, step.Id)
		end
		local valid, why = serverVerdict(baseline, trial, validateCtx)
		if not valid then
			return nil, tostring(why or "refused")
		end
		local used = Tuning.usedCapacity(trial, factoryOutput)
		if used > capacity then
			return nil, "over capacity"
		end
		local metrics = carMetrics(shop, trial)
		if not Config.CarAllowUnreliable and Tuning.unreliabilityBand(Tuning.unreliability(metrics.aggregate)).Warn then
			return nil, "hurts reliability"
		end
		local price = priceOf(trial)
		if price > budget then
			return nil, "over budget"
		end
		local gain = goalScore(goal, metrics, baseMetrics) - simScore
		if gain <= 0.05 then
			return nil, "no gain"
		end
		-- what it costs us: the larger of the share of the remaining capacity and of the remaining cash
		local capacityShare = math.max(used - simUsed, 0) / math.max(capacity - simUsed, 1)
		local priceShare = math.max(price - simPrice, 0) / math.max(budget - simPrice, 1)
		local cost = Config.CarValue and math.max(capacityShare, priceShare, 0.05) or 1
		return {
			Steps = steps,
			Trial = trial,
			Metrics = metrics,
			Price = price,
			Used = used,
			Gain = gain,
			Rank = gain / cost,
		}
	end

	local plan, evaluated = {}, 0
	local started = os.clock()
	for round = 1, 40 do
		if os.clock() - started > 60 then
			log("Car: stopped planning after a minute, using what it has", THEME.Warn)
			break
		end
		mark("planning round " .. round)
		local best

		for _, category in pairs(Tuning.catalog().Categories) do
			-- categories you switched off on the Car tab, or that don't apply to this car, are left alone
			if Tuning.fits(category, fit) and Config.CarCategories[category.Id or category.Name] ~= false then
				for _, slot in pairs(Tuning.slotsFor(category, fit)) do
					for _, partId in pairs(Tuning.partsForSlot(slot.Id, fit)) do
						local part = Tuning.part(partId)
						if
							part
							and sim.Parts[part.Slot] ~= partId
							and partFitsCar(part, fit)
							and not skippedByUser(partId, part)
							and not Tuning.redundantConversion(sim, ctx, part)
						then
							evaluated += 1
							if evaluated % 20 == 0 then
								task.wait() -- keep the game responsive while this works through the list
							end
							local move, why = consider({ { Slot = part.Slot, Id = partId } })
							if move then
								if not best or move.Rank > best.Rank then
									best = move
								end
							elseif why ~= "no gain" then
								rejected[partId] = why
							end

							-- a part that needs another part first: try it together with each one that would do
							if not move and why and why:find("requires a", 1, true) and part.RequiresSlot then
								for _, parentId in pairs(Tuning.partsForSlot(part.RequiresSlot, fit)) do
									local parent = Tuning.part(parentId)
									if
										parent
										and sim.Parts[parent.Slot] ~= parentId
										and partFitsCar(parent, fit)
										and not skippedByUser(parentId, parent)
									then
										evaluated += 1
										local pair = consider({
											{ Slot = parent.Slot, Id = parentId },
											{ Slot = part.Slot, Id = partId },
										})
										if pair and (not best or pair.Rank > best.Rank) then
											best = pair
										end
									end
								end
							end
						end
					end
				end
			end
		end

		if not best then
			break
		end
		table.insert(plan, {
			Steps = best.Steps,
			Gain = best.Gain,
			Cost = best.Price - simPrice,
			Used = best.Used - simUsed,
		})
		sim, simPrice, simUsed = best.Trial, best.Price, best.Used
		simScore += best.Gain
	end

	-- what was left out because the server's own rules refuse it, grouped by reason
	local byReason = {}
	for _, reason in pairs(rejected) do
		byReason[reason] = (byReason[reason] or 0) + 1
	end
	local reasons = {}
	for reason, count in pairs(byReason) do
		table.insert(reasons, { Text = reason .. " x" .. count, Count = count })
	end
	table.sort(reasons, function(a, b)
		return a.Count > b.Count
	end)
	local reasonText = {}
	for i = 1, math.min(#reasons, 4) do
		table.insert(reasonText, reasons[i].Text)
	end
	if #reasonText > 0 then
		log("Car: left out (server rules / limits): " .. table.concat(reasonText, ", "), THEME.Dim)
	end

	if #plan == 0 then
		log("Car: nothing to add for this goal (already maxed, locked, or over budget/capacity)", THEME.Warn)
		setStatus("Idle", THEME.Dim)
		return
	end

	-- list the moves; in preview mode that's all we do
	for index, move in ipairs(plan) do
		local last = move.Steps[#move.Steps]
		local text = Tuning.label(Tuning.part(last.Id))
		if #move.Steps > 1 then
			text ..= " (with " .. Tuning.label(Tuning.part(move.Steps[1].Id)) .. ")"
		end
		if index <= 14 then
			log(
				string.format("%s %d: %s  +%.1f, %s cash, %d capacity", apply and "Car" or "Plan", index, text, move.Gain, formatNumber(math.max(move.Cost, 0)), math.max(move.Used, 0)),
				THEME.Dim
			)
		end
	end
	if #plan > 14 then
		log(string.format("… and %d more", #plan - 14), THEME.Dim)
	end

	local endMetrics
	local installed = 0
	if apply then
		for _, move in ipairs(plan) do
			for _, step in ipairs(move.Steps) do
				mark("install " .. tostring(step.Id))
				local problem = shop:InstallProblem(step.Id) -- the shop's own check against what's fitted right now
				if problem then
					log("Car: skipped " .. tostring(step.Id) .. " (" .. string.lower(tostring(problem)) .. ")", THEME.Warn)
					break
				end
				local ok, success, message = pcall(api.InstallBought, api, step.Id)
				if ok and success then
					installed += 1
				else
					log("Car: couldn't fit " .. tostring(step.Id) .. " (" .. tostring(ok and message or success) .. ")", THEME.Warn)
					break
				end
				task.wait(0.05)
			end
		end
		pcall(shop.Refresh, shop)
		local after = api:Get("Tuning")
		after.Parts = after.Parts or {}
		endMetrics = carMetrics(shop, after)
	else
		endMetrics = carMetrics(shop, sim)
		installed = #plan
	end

	log(
		string.format(
			"%s: %d parts for about %s cash (capacity %d/%d). Peak power %d -> %d hp, top speed x%.2f -> x%.2f.%s",
			apply and "Car" or "Plan",
			installed,
			formatNumber(math.max(simPrice - startPrice, 0)),
			simUsed,
			capacity,
			math.round(baseMetrics.hp),
			math.round(endMetrics.hp),
			baseMetrics.top,
			endMetrics.top,
			apply and " Check out in the garage to pay." or " Press \"Add best parts to cart\" to use it."
		),
		THEME.Good
	)
	setStatus("Idle", THEME.Dim)
end

local function installFastestParts()
	runTuner(true)
end

local function previewFastestParts()
	runTuner(false)
end

-- Which parts can this car really take? Counts per category go to the log, the full list (id, name,
-- status) is printed to the executor console. Statuses: fit, installed, locked (level), redundant,
-- blocked (the shop says it can't be fitted, it isn't for this car, or Tuning.Validate, the server's
-- own checkout check, refuses it).
local function checkFittingParts()
	if not (Tuning and TuningUtil) then
		log("Fit check: the Tuning modules weren't found", THEME.Bad)
		return
	end
	local shop = getShop()
	if not shop or not shop:IsOpen() then
		log("Fit check: open the car's parts shop in the garage first", THEME.Warn)
		return
	end

	local api = shop.Api
	local fit = shop.Fit
	local data = api:PlayerData()
	local level = data.Level or 0
	local currentValue = api:Get("Tuning")
	local fitted = currentValue.Parts or {}
	-- what the server will run on checkout, so the report shows its verdict too
	local validateCtx = table.clone(api:Ctx())
	validateCtx.playerData = validateCtx.playerData or data
	local baseline = api:GetBaseline("Tuning")
	local usable, skippedCategories = 0, 0

	for _, category in pairs(Tuning.catalog().Categories) do
		local counts = { fit = 0, installed = 0, locked = 0, redundant = 0, blocked = 0 }
		local reasons = {}
		local labelOk, categoryName = pcall(Tuning.label, category)
		categoryName = labelOk and tostring(categoryName) or tostring(category.Id or category.Name)

		-- the server rejects a part whose whole category doesn't apply to the car
		if not Tuning.fits(category, fit) then
			skippedCategories += 1
			print("[fit-check] " .. categoryName .. " | (whole category) | not for this car")
			continue
		end

		for _, slot in pairs(Tuning.slotsFor(category, fit)) do
			for _, partId in pairs(Tuning.partsForSlot(slot.Id, fit)) do
				local part = Tuning.part(partId)
				if part then
					local status, reason = "fit", nil
					if fitted[part.Slot] == partId then
						status = "installed"
					elseif not partFitsCar(part, fit) then
						status, reason = "blocked", "not for this car"
					else
						local problem = shop:InstallProblem(partId)
						if problem then
							status, reason = "blocked", string.lower(tostring(problem))
						elseif shop:IsRedundant(part) then
							status = "redundant"
						elseif shop:Covered(partId) <= 0 and (part.Level or 0) > level then
							status, reason = "locked", "needs level " .. tostring(part.Level)
						end
					end
					if status == "fit" then
						local trial = TuningUtil.deepCopy(currentValue)
						trial.Parts = trial.Parts or {}
						trial.Parts[part.Slot] = partId
						local valid, why = serverVerdict(baseline, trial, validateCtx)
						if not valid then
							status, reason = "blocked", tostring(why or "refused by the server's rules")
						end
					end
					counts[status] += 1
					if status == "fit" or status == "installed" then
						usable += 1
					end
					if reason and status == "blocked" then
						reasons[reason] = (reasons[reason] or 0) + 1
					end
					print(
						string.format(
							"[fit-check] %s | %s | %s | %s%s",
							categoryName,
							tostring(partId),
							tostring(Tuning.label(part)),
							status,
							reason and (" (" .. reason .. ")") or ""
						)
					)
				end
			end
		end

		local pieces = {}
		for _, status in ipairs({ "fit", "installed", "locked", "redundant", "blocked" }) do
			if counts[status] > 0 then
				table.insert(pieces, counts[status] .. " " .. status)
			end
		end
		if #pieces > 0 then
			local extra = {}
			for reason, count in pairs(reasons) do
				table.insert(extra, reason .. " x" .. count)
			end
			log(
				"Fit: " .. categoryName .. ": " .. table.concat(pieces, ", ") .. (#extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or ""),
				THEME.Dim
			)
		end
	end
	if skippedCategories > 0 then
		log(string.format("Fit: %d part categories don't apply to this car at all", skippedCategories), THEME.Dim)
	end
	log(string.format("Fit check done: %d parts can be fitted or are installed. Full list is in the console.", usable), THEME.Good)
end

-- The buttons only raise flags; this loop (a thread of ours, like the main loop) does the work.
local function runCarJob(name, job)
	State.CarBusy = true
	restoreIdentity()
	State.CarStep = "start"
	local ok, err = xpcall(job, function(message)
		-- keep the call chain: it shows whether the failure is in our code or a game module
		local trace = (string.gsub(debug.traceback("", 2), "%s*\n%s*", " < "))
		return tostring(message) .. " | " .. trace:sub(1, 420)
	end)
	if not ok then
		log(name .. " error at [" .. tostring(State.CarStep) .. "]: " .. tostring(err), THEME.Bad)
	end
	State.CarBusy = false
end

function carLoop()
	while State.Running do
		if State.CarRequested then
			State.CarRequested = false
			runCarJob("Car parts", installFastestParts)
		elseif State.CarPreviewRequested then
			State.CarPreviewRequested = false
			runCarJob("Car plan", previewFastestParts)
		elseif State.CarCheckRequested then
			State.CarCheckRequested = false
			runCarJob("Fit check", checkFittingParts)
		end
		task.wait(0.2)
	end
end
end

--------------------------------------------------------------------------------------------------
-- Highway cruise (autopilot for the traffic highway)
--------------------------------------------------------------------------------------------------
-- How points work there (Traffic.Scoring + Config.Scoring): at 130+ studs/s with a traffic car within
-- 120 studs you earn a steady "HIGH SPEED" rate, and passing a car close earns near misses and
-- overtakes. The server only banks a combo whose positions match where your car really was, so this
-- drives the car for real instead of inventing anything: it follows a lane of the game's own road
-- data (Shared.Traffic.Lanes) at a set speed, and changes lane around the cars the Traffic module is
-- drawing (their positions come from Traffic.Order). Sit in your car on the highway, facing the way
-- the traffic goes. A crash still costs you the combo, as it would if you drove.

do
	local trafficClass = loadModule("Traffic")
	local collisionModule = loadModule("Traffic", "Collision")

	local modulesFolder = ReplicatedStorage:FindFirstChild("Modules")
	local sharedFolder = modulesFolder and modulesFolder:FindFirstChild("Shared")
	local trafficFolder = sharedFolder and sharedFolder:FindFirstChild("Traffic")
	local trafficConfig = tryRequire(trafficFolder and trafficFolder:FindFirstChild("Config"))
	local TRAFFIC_SPEED = trafficConfig and trafficConfig.Speed or 95
	local ROAD_HEIGHT = trafficConfig and trafficConfig.RoadHeight or 12
	local MIN_SPEED = trafficConfig and trafficConfig.Scoring and trafficConfig.Scoring.MinimumSpeed or 100
	local BEHIND_CLEAR = 40 -- room wanted behind a lane before cutting into it when we're not clearly faster
	local CHANGE_SECONDS = 0.9 -- one lane change takes about this long

	-- Driving styles. Margin: extra clearance (studs) added to every car's box when checking lanes.
	-- Look: how early it starts moving over (1 = the base distance). WeaveGap: edge-to-edge gap it aims
	-- for when passing a car close, for the near-miss bonus (a near miss counts at 6 or less; false =
	-- never weave). Behind: room it wants behind a lane it is moving into when it is clearly faster.
	local STYLES = {
		careful = { Look = 1.4, Margin = 5, WeaveGap = false, Behind = 32 },
		balanced = { Look = 1.1, Margin = 3, WeaveGap = 4.5, Behind = 24 },
		bold = { Look = 0.95, Margin = 2, WeaveGap = 3.2, Behind = 20 },
	}

	local traffic -- the game's live Traffic instance, picked up when it refreshes (or with getgc)
	local lastScan = 0
	local nextTry = 0
	local lastError = 0
	local nextStatusAt = 0
	local cruise = {} -- empty until engaged

	if trafficClass then
		wrapMethod(trafficClass, "Refresh", function(original)
			return function(self, ...)
				traffic = self
				return original(self, ...)
			end
		end)
	end

	local function getTraffic()
		if traffic and traffic.Shared and traffic.Order then
			return traffic
		end
		if getgc and trafficClass and os.clock() - lastScan > 5 then
			lastScan = os.clock()
			local ok, objects = pcall(getgc, true)
			if ok and type(objects) == "table" then
				for _, obj in ipairs(objects) do
					if type(obj) == "table" and getmetatable(obj) == trafficClass and rawget(obj, "Shared") and rawget(obj, "Order") then
						traffic = obj
						return obj
					end
				end
			end
		end
		return nil
	end

	local function cruiseVehicle()
		local _, hum = getCharacter()
		local seat = hum and hum.SeatPart
		local vehicle = seat and seat.Parent
		if seat and seat.Name == "DriveSeat" and vehicle and vehicle:IsA("Model") and vehicle.Name == LocalPlayer.Name then
			return vehicle, seat, hum
		end
		return nil
	end

	local function release(reason)
		if cruise.Engaged then
			log("Cruise: stopped (" .. reason .. ")", THEME.Dim)
		end
		cruise = {}
	end

	-- half width and half length of your own car's box, as the scoring sees it
	local function ownHalfSize()
		local box = collisionModule and collisionModule.Hitbox
		if typeof(box) == "Instance" and box:IsA("BasePart") then
			return box.Size.X / 2, box.Size.Z / 2
		end
		return 3.5, 8
	end

	-- a point on the road between two lanes (laneF is a lane number, fractions are in between)
	local function laneCentre(Lanes, chain, laneF, along)
		local lower = math.clamp(math.floor(laneF), 1, #chain)
		local upper = math.clamp(math.ceil(laneF), 1, #chain)
		local a = Lanes:SampleAlong(chain[lower], along)
		if upper == lower then
			return a
		end
		local b = Lanes:SampleAlong(chain[upper], along)
		return a:Lerp(b, laneF - lower)
	end

	local function engage(vehicle, seat, hum, T)
		local set = T.Shared:Set(T.Density)
		if not set then
			return false, "traffic is off or still loading"
		end
		local Lanes = T.Shared.Lanes
		local seatPos = seat.Position
		local road, offFrac, vertical, heading = Lanes:NearestRoad(set, seatPos)
		if not road or offFrac > 0.6 or math.abs(vertical) > ROAD_HEIGHT then
			return false, "you're not on a highway lane"
		end
		if heading == nil or seat.CFrame.LookVector:Dot(heading) < 0.5 then
			return false, "face the way the traffic is going first"
		end

		local chain = road.Chain
		local along = Lanes:NearestDistance(road, seatPos)
		local _, tangent = Lanes:Sample(road, along)
		local flat = Vector3.new(tangent.X, 0, tangent.Z)
		if flat.Magnitude < 0.01 then
			return false, "the road is too steep here"
		end
		local rightFlat = flat.Unit:Cross(Vector3.yAxis)

		-- the lane whose centre line you are on, and which way lane numbers run across the road
		local bestIndex, bestDistance = 1, math.huge
		for index, lane in ipairs(chain) do
			local centre = Lanes:SampleAlong(lane, along)
			local distance = Vector3.new(centre.X - seatPos.X, 0, centre.Z - seatPos.Z).Magnitude
			if distance < bestDistance then
				bestIndex, bestDistance = index, distance
			end
		end
		local indexToRight, width = 1, road.Width or 15
		if #chain >= 2 then
			local a = Lanes:SampleAlong(chain[1], along)
			local b = Lanes:SampleAlong(chain[2], along)
			local step = (b - a):Dot(rightFlat)
			indexToRight = step >= 0 and 1 or -1
			width = math.max(math.abs(step), 6)
		end

		-- keep the car's own geometry: where its middle sits relative to the seat, and ride height
		local boxCFrame = vehicle:GetBoundingBox()
		local laneY = Lanes:SampleAlong(chain[bestIndex], along).Y
		cruise = {
			Engaged = true,
			Vehicle = vehicle,
			Seat = seat,
			Road = road,
			Chain = chain,
			Lanes = Lanes,
			Along = along,
			LaneF = bestIndex,
			LaneTarget = bestIndex,
			IndexToRight = indexToRight,
			Width = width,
			Lat = 0,
			Speed = seat.AssemblyLinearVelocity.Magnitude,
			ChangeAt = 0,
			CentreInSeat = seat.CFrame:PointToObjectSpace(boxCFrame.Position),
			SeatToPivot = seat.CFrame:ToObjectSpace(vehicle:GetPivot()),
			YOffset = boxCFrame.Position.Y - laneY,
		}
		log(string.format("Cruise: on (lane %d of %d, aiming for %d studs/s)", bestIndex, #chain, Config.CruiseSpeed), THEME.Good)
		return true
	end

	local function step(dt)
		if not (Config.Enabled and Config.Cruise) then
			if cruise.Engaged then
				release("switched off")
			end
			State.CruiseStatus = nil
			return
		end
		if State.CruisePause or sceneBusy() then
			if cruise.Engaged then
				release("paused for refuelling or a reward")
			end
			State.CruiseStatus = "Cruise paused…"
			return
		end

		local T = getTraffic()
		if not T then
			State.CruiseStatus = "Cruise: go to the highway map (traffic isn't loaded)"
			return
		end
		local vehicle, seat, hum = cruiseVehicle()
		if not vehicle then
			if cruise.Engaged then
				release("you left the car")
			end
			State.CruiseStatus = "Cruise: sit in your car on the highway"
			return
		end

		if not cruise.Engaged then
			if os.clock() < nextTry then
				return
			end
			nextTry = os.clock() + 0.5
			local ok, why = engage(vehicle, seat, hum, T)
			if not ok then
				State.CruiseStatus = "Cruise: " .. why
			end
			return
		end
		if cruise.Vehicle ~= vehicle or not vehicle:IsDescendantOf(Workspace) then
			release("the car changed")
			return
		end

		local set = T.Shared:Set(T.Density)
		if not set then
			release("traffic turned off")
			return
		end
		local Lanes, chain, road = cruise.Lanes, cruise.Chain, cruise.Road

		-- the road under us now
		local _, tangent = Lanes:Sample(road, cruise.Along)
		local flat = Vector3.new(tangent.X, 0, tangent.Z)
		if flat.Magnitude < 0.01 then
			release("the road is too steep here")
			return
		end
		flat = flat.Unit
		local rightFlat = flat:Cross(Vector3.yAxis)
		local centre = laneCentre(Lanes, chain, cruise.LaneF, cruise.Along)
		local halfWidth, halfLength = ownHalfSize()

		local style = STYLES[Config.CruiseStyle] or STYLES.balanced
		local margin = style.Margin

		-- traffic around us: lane number, distance ahead, sideways offset, and how fast it is moving
		-- sideways in the road's own terms (so a car pulling toward us can be allowed for)
		local now = os.clock()
		local track = cruise.Track
		if not track then
			track = {}
			cruise.Track = track
			cruise.TrackPruned = now
		end
		local near = {}
		for _, car in ipairs(T.Order) do
			local part = car.Hitbox or (car.Parts and car.Parts[car.HitboxIndex or 1])
			if part and part.Parent then
				local rel = part.Position - centre
				local long = rel:Dot(flat)
				if long > -80 and long < 280 then
					local lat = rel:Dot(rightFlat)
					local lane = cruise.LaneF + lat * cruise.IndexToRight / cruise.Width
					local key = (car.LaneId or 0) * 1000000000 + (car.K or 0)
					local roadLat = lane * cruise.Width * cruise.IndexToRight
					local seen = track[key]
					local velocity = 0
					if seen and now > seen.T and now - seen.T < 0.5 then
						velocity = seen.V * 0.6 + math.clamp((roadLat - seen.L) / (now - seen.T), -14, 14) * 0.4
					end
					track[key] = { L = roadLat, T = now, V = velocity }
					local size = car.HitboxSize
					table.insert(near, {
						Long = long,
						Lat = lat,
						Lane = lane,
						LatVel = velocity,
						Half = (size and size.X or 7) / 2,
						Length = size and size.Z or 18,
					})
				end
			end
		end
		if now - cruise.TrackPruned > 2 then
			cruise.TrackPruned = now
			for key, seen in pairs(track) do
				if now - seen.T > 1 then
					track[key] = nil
				end
			end
		end

		-- Traffic is slower than us, so a car behind the gap we want can't catch up while we change lane;
		-- we only need to clear its length. At matched speeds we need more, since it stays beside us.
		local behindClear = cruise.Speed > TRAFFIC_SPEED + 10 and style.Behind or BEHIND_CLEAR

		-- room ahead in a lane (0 if a car sits alongside) and whether a car is right behind it
		local function laneState(index)
			local ahead, behindClose = math.huge, false
			for _, car in ipairs(near) do
				if math.abs(car.Lane - index) < (car.Half + halfWidth + margin) / cruise.Width then
					local overlap = (car.Length + halfLength * 2) / 2 + margin
					if car.Long >= 0 then
						ahead = math.min(ahead, math.max(car.Long - overlap, 0))
					elseif -car.Long - overlap < behindClear then
						behindClose = true
					end
				end
			end
			return ahead, behindClose
		end

		local cruiseSpeed = Config.CruiseSpeed
		local cap = vehicle:GetAttribute("MaxSpeedStudsPerSecond") -- the server's own top speed for this car
		if type(cap) == "number" and cap > 0 then
			cruiseSpeed = math.min(cruiseSpeed, cap * 0.95)
		end
		local closing = math.max(cruise.Speed - TRAFFIC_SPEED, 12)
		local look = math.clamp(closing * 1.6 + 45, 60, 200) * style.Look

		-- lane choice: leave a lane when a car is ahead in it, for a free neighbouring lane
		local changing = math.abs(cruise.LaneF - cruise.LaneTarget) > 0.05
		local targetAhead, targetBehind = laneState(cruise.LaneTarget)
		if changing and (targetAhead < 25 + margin or targetBehind) then
			local back = math.floor(cruise.LaneF + 0.5) -- the lane we're nearest to: go back to it
			if back ~= cruise.LaneTarget then
				cruise.LaneTarget = back
				cruise.ChangeAt = os.clock() + 1
			end
		elseif targetAhead < look * 1.15 and os.clock() >= cruise.ChangeAt then
			-- Overtaking: a car is ahead in our lane. Look at every lane's room ahead and go for the one
			-- with clearly more, a lane at a time (so a platoon two lanes over can be skipped too). A lane
			-- doesn't need to be clear for the whole look-ahead, only for clearly more than we have now.
			local here = cruise.LaneTarget
			local room, safe = {}, {}
			for index = 1, #chain do
				local ahead, behindClose = laneState(index)
				room[index], safe[index] = ahead, not behindClose
			end
			local pick, pickRoom = nil, targetAhead + 40
			for index = 1, #chain do
				if index ~= here and room[index] > math.max(pickRoom, 60 + margin * 3) then
					local nextLane = here + (index > here and 1 or -1) -- the first step toward it
					if safe[nextLane] and room[nextLane] > 45 + margin * 2 then
						pick, pickRoom = nextLane, room[index]
					end
				end
			end
			if pick then
				cruise.LaneTarget = pick
				cruise.ChangeAt = os.clock() + 1.2
			end
		end

		-- speed: hold the target, ease off only when there's no way round a car close ahead
		-- (parentheses keep only laneState's first result; as the last argument it would pass both)
		local lowFree = math.min((laneState(math.floor(cruise.LaneF))), (laneState(math.ceil(cruise.LaneF))))
		local targetSpeed = cruiseSpeed
		if lowFree < closing * 0.45 + 24 + margin * 2 then
			-- No way round yet. Don't match the traffic's speed: then the cars in the next lanes stay
			-- beside us and no gap ever opens. Keep creeping up on the car ahead (so the lanes keep
			-- moving relative to us) and only back right off when it's nearly on us.
			targetSpeed = lowFree < 28 + margin * 2 and (TRAFFIC_SPEED - 6) or (TRAFFIC_SPEED + 14)
		end
		local rate = targetSpeed < cruise.Speed and 140 or 55
		cruise.Speed += math.clamp(targetSpeed - cruise.Speed, -rate * dt, rate * dt)

		-- weaving: slide toward a car in the next lane while passing it, for the near-miss bonus
		-- (the near-miss bonus is 42 points x speed bonus x closeness, ~150+ each at 200 studs/s, far
		-- more than the steady rate, so passing close is where the extra points are)
		local desiredLat = 0
		local weaveGap = style.WeaveGap
		if weaveGap and not changing and cruise.Speed >= MIN_SPEED + 10 then
			-- the next car we'll pass in a neighbouring lane
			local target
			for _, car in ipairs(near) do
				local sideways = math.abs(car.Lane - cruise.LaneF)
				if
					sideways > 0.6
					and sideways < 1.6
					and car.Long > -12
					and car.Long < (car.Length + halfLength * 2) / 2 + 26
					and (not target or car.Long < target.Long)
				then
					target = car
				end
			end
			if target then
				local sign = target.Lat >= 0 and 1 or -1
				-- don't squeeze toward one car if another is on our other side
				local boxed = false
				for _, car in ipairs(near) do
					if
						car ~= target
						and (car.Lat - cruise.Lat) * sign < 0
						and math.abs(car.Lat - cruise.Lat) < cruise.Width * 1.3
						and math.abs(car.Long) < (car.Length + halfLength * 2) / 2 + 30
					then
						boxed = true
						break
					end
				end
				-- how fast it is drifting toward us sideways (a lane change by that car): leave more room,
				-- and skip the weave entirely if it's cutting in hard
				local towards = -sign * target.LatVel
				if not boxed and towards < 4 then
					local ahead = math.max(target.Long - (target.Length + halfLength * 2) / 2, 0)
					local seconds = math.clamp(ahead / closing, 0, 1.2)
					local predicted = target.Lat + target.LatVel * seconds
					local gap = weaveGap + math.max(towards, 0) * 0.5
					desiredLat = math.clamp(predicted - sign * (target.Half + halfWidth + gap), -5, 5)
				end
			end
		end
		cruise.Lat += math.clamp(desiredLat - cruise.Lat, -14 * dt, 14 * dt)

		-- advance along the road and put the car there
		cruise.LaneF += math.clamp(cruise.LaneTarget - cruise.LaneF, -dt / CHANGE_SECONDS, dt / CHANGE_SECONDS)
		cruise.Along += cruise.Speed * dt
		if not road.Closed and cruise.Along > road.Length - 60 then
			release("end of the road")
			return
		end

		local _, tangentNow = Lanes:Sample(road, cruise.Along)
		local centreNow = laneCentre(Lanes, chain, cruise.LaneF, cruise.Along)
		local flatNow = Vector3.new(tangentNow.X, 0, tangentNow.Z).Unit
		local position = centreNow + flatNow:Cross(Vector3.yAxis) * cruise.Lat
		position = Vector3.new(position.X, centreNow.Y + cruise.YOffset, position.Z)
		local facing = CFrame.lookAt(position, position + tangentNow, Vector3.yAxis)
		local seatCFrame = facing * CFrame.new(-cruise.CentreInSeat)
		vehicle:PivotTo(seatCFrame * cruise.SeatToPivot)
		seat.AssemblyLinearVelocity = tangentNow * cruise.Speed
		seat.AssemblyAngularVelocity = Vector3.zero

		if os.clock() >= nextStatusAt then
			nextStatusAt = os.clock() + 0.3
			State.CruiseStatus = string.format(
				"Cruise: lane %d of %d, %d studs/s, %d cars near",
				math.floor(cruise.LaneF + 0.5),
				#chain,
				math.round(cruise.Speed),
				#near
			)
		end
	end

	connect(RunService.PreSimulation, function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			cruise = {}
			if os.clock() - lastError > 5 then
				lastError = os.clock()
				log("Cruise error: " .. tostring(err), THEME.Bad)
			end
		end
	end)
end

--------------------------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------------------------

local function mainLoop()
	while State.Running do
		if not Config.Enabled then
			setStatus("Idle", THEME.Dim)
			task.wait(0.25)
			continue
		end

		local _, _, hrp = getCharacter()
		if not hrp then
			setStatus("Waiting for your character…", THEME.Warn)
			task.wait(0.5)
			continue
		end
		if sceneBusy() then
			setStatus("Reward scene playing…", THEME.Good)
			task.wait(0.25)
			continue
		end

		-- a nearly empty tank comes first, then the job carries on from wherever the car ends up
		local fuelOk, fuelBusy = pcall(fuelTick)
		if not fuelOk then
			log("Fuel error: " .. tostring(fuelBusy), THEME.Bad)
			task.wait(2)
		elseif fuelBusy then
			task.wait(0.25)
			continue
		end

		-- the highway autopilot runs on its own every frame; here we just show what it's doing
		if Config.Cruise then
			setStatus(State.CruiseStatus or "Cruise: starting…", THEME.Accent)
			task.wait(0.25)
			continue
		end

		if Config.Repo then
			local ok, err = pcall(repoTick)
			if not ok then
				log("Repo error: " .. tostring(err), THEME.Bad)
				task.wait(2)
			end
			task.wait(0.25)
			continue
		end

		-- every stop we could make right now, houses and graveyards together
		local stops = {}
		local houseNote
		if Config.Houses then
			if TrickOrTreat and TrickOrTreat.Enabled == false then
				houseNote = "The trick-or-treat event isn't active"
			elseif not findBag() then
				houseNote = "No candy bag in your backpack"
			else
				for _, target in ipairs(getTargets()) do
					target.Kind = "house"
					target.Key = target.Lot
					table.insert(stops, target)
				end
			end
		end
		if Config.Graveyards then
			for _, stop in ipairs(getGraveyards()) do
				table.insert(stops, stop)
			end
		end

		local now = os.clock()
		local best, bestDistance
		for _, stop in ipairs(stops) do
			if (State.Failed[stop.Key] or 0) <= now then
				local distance = (stop.Pos - hrp.Position).Magnitude
				if not bestDistance or distance < bestDistance then
					best, bestDistance = stop, distance
				end
			end
		end

		if not best then
			if #stops > 0 then
				setStatus("Retrying skipped stops soon…", THEME.Dim)
			else
				setStatus(houseNote or "Nothing left to collect right now", houseNote and THEME.Warn or THEME.Dim)
			end
			task.wait(1)
			continue
		end

		local isHouse = best.Kind == "house"
		local name = isHouse and ("house " .. best.Lot) or ("graveyard " .. best.Id)
		local ok, result, reason
		if isHouse then
			ok, result, reason = pcall(visit, best)
		else
			ok, result, reason = pcall(searchGraveyard, best)
		end

		if not ok then
			log("Error at " .. name .. ": " .. tostring(result), THEME.Bad)
			State.Failed[best.Key] = os.clock() + RETRY_COOLDOWN
		elseif result == true then
			if isHouse then
				State.Houses += 1
				if not hookInstalled then
					log("Knocked on " .. name, THEME.Good)
				end
			else
				State.Graveyards += 1
				log("Searched " .. name, THEME.Good)
				task.wait(1.5) -- a rare drop's scene starts a moment after the search; let it claim the loop first
			end
			refreshStats()
		elseif result == false then
			log(name .. ": " .. (reason or "no response") .. " (retry later)", THEME.Warn)
			State.Failed[best.Key] = os.clock() + RETRY_COOLDOWN
		end
		task.wait(Config.Delay)
	end
end

--------------------------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------------------------

local function destroy()
	State.Running = false
	Config.Enabled = false
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(connections)
	removeHooks()
	pcall(function()
		gui:Destroy()
	end)
	if env.AutoTrickOrTreat and env.AutoTrickOrTreat.Destroy == destroy then
		env.AutoTrickOrTreat = nil
	end
end

env.AutoTrickOrTreat = { Destroy = destroy }

hookInstalled = installVisitHook()
local exclusiveHooked = installExclusiveHook()
local repoHooked = installRepoHook()
local shopHooked = installShopHook()

-- Jobs tab
UI.makeSection(jobsPage, "What to run")
UI.makeToggle(jobsPage, "Knock on houses", Config.Houses, function(value)
	Config.Houses = value
end)
UI.makeToggle(jobsPage, "Search graveyards", Config.Graveyards, function(value)
	Config.Graveyards = value
end)
UI.makeToggle(jobsPage, "Repo job (tow truck)", Config.Repo, function(value)
	Config.Repo = value
	if value then
		log("Repo mode: houses and graveyards are paused", THEME.Dim)
	end
end)
UI.makeNote(jobsPage, "While the Repo job is on it takes over: houses and graveyards pause.")

UI.makeSection(jobsPage, "Highway")
UI.makeToggle(jobsPage, "Highway cruise (autopilot)", Config.Cruise, function(value)
	Config.Cruise = value
	if value then
		log("Cruise: sit in your car on the highway, facing the way the traffic goes, then press Start", THEME.Dim)
	end
end)
UI.makeInput(jobsPage, "Cruise speed (studs/s)", Config.CruiseSpeed, 110, 400, function(value)
	Config.CruiseSpeed = value
end)
local cruiseStyleNote
UI.makeChoice(jobsPage, {
	{ Id = "careful", Name = "Careful" },
	{ Id = "balanced", Name = "Balanced" },
	{ Id = "bold", Name = "Bold" },
}, Config.CruiseStyle, function(id)
	Config.CruiseStyle = id
	cruiseStyleNote.Text = ({
		careful = "Careful: leaves lots of room, moves over early and never weaves. Fewest crashes, fewest points.",
		balanced = "Balanced: passes close (about 4.5 studs) for near misses and allows for cars drifting toward you.",
		bold = "Bold: passes very close (about 3 studs) for the biggest near-miss bonuses. Most points, most risk.",
	})[id]
end)
cruiseStyleNote = UI.makeNote(jobsPage, "Balanced: passes close (about 4.5 studs) for near misses and allows for cars drifting toward you.")
UI.makeNote(jobsPage, "Points per second grow with speed (about 21 at 150, 36 at 200, 63 at 290) and near misses pay far more, so a higher speed and a closer style earn more. A crash loses the combo. It takes over from the other jobs while on.")

-- Repo tab
UI.makeSection(repoPage, "Contract")
UI.makeInput(repoPage, "Contract # (1 = first)", Config.RepoTask, 1, 30, function(value)
	Config.RepoTask = math.floor(value)
end)
UI.makeToggle(repoPage, "Yes to \"another job\" bonus", Config.AutoYes, function(value)
	Config.AutoYes = value
end)
UI.makeSection(repoPage, "Truck")
UI.makeInput(repoPage, "Speed (studs/s)", Config.RepoSpeed, 20, 1000, function(value)
	Config.RepoSpeed = value
end)
UI.makeInput(repoPage, "Cruise height (0 = off)", Config.RepoHeight, 0, 1000, function(value)
	Config.RepoHeight = value
end)
UI.makeNote(repoPage, "The truck climbs, glides level at the cruise height, then drops onto the marker. If the task stops advancing after arriving, lower the speed.")

-- Car tab (in its own block so its locals don't count against the 200-locals limit of this chunk)
do
UI.makeSection(carPage, "Build for")
local goalOptions = {}
for _, goal in ipairs(CAR_GOALS) do
	table.insert(goalOptions, { Id = goal.Id, Name = goal.Name })
end
local goalNote
UI.makeChoice(carPage, goalOptions, carGoal(Config.CarGoal).Id, function(id)
	Config.CarGoal = id
	goalNote.Text = carGoal(id).Desc
end)
goalNote = UI.makeNote(carPage, carGoal(Config.CarGoal).Desc)

UI.makeSection(carPage, "Parts to consider")
local catalogOk, catalog = pcall(function()
	return Tuning.catalog()
end)
if catalogOk and type(catalog) == "table" and type(catalog.Categories) == "table" then
	local categoryGrid = UI.makeGrid(carPage, 3)
	for _, category in pairs(catalog.Categories) do
		local categoryId = category.Id or category.Name
		local labelOk, categoryName = pcall(Tuning.label, category)
		UI.makeChipToggle(categoryGrid, labelOk and tostring(categoryName) or tostring(categoryId), Config.CarCategories[categoryId] ~= false, function(value)
			Config.CarCategories[categoryId] = value
		end)
	end
else
	UI.makeNote(carPage, "Part categories couldn't be read, so every category is used.")
end

UI.makeSection(carPage, "Limits")
UI.makeToggle(carPage, "Pick for value (gain per capacity/cash)", Config.CarValue, function(value)
	Config.CarValue = value
end)
UI.makeToggle(carPage, "Allow reliability loss", Config.CarAllowUnreliable, function(value)
	Config.CarAllowUnreliable = value
end)
UI.makeInput(carPage, "Max spend (0 = all cash)", Config.CarMaxSpend, 0, 1000000000, function(value)
	Config.CarMaxSpend = math.floor(value)
end)
UI.makeText(carPage, "Skip parts (names or ids, comma separated)", Config.CarSkip, "e.g. weight reduction stage 3", function(value)
	Config.CarSkip = value
end)
local function carIdle()
	return not (State.CarBusy or State.CarRequested or State.CarCheckRequested or State.CarPreviewRequested)
end
UI.makeButton(carPage, "Check what fits this car", function()
	if not carIdle() then
		return
	end
	State.CarCheckRequested = true
	log("Fit check: working…", THEME.Dim)
end)
UI.makeButton(carPage, "Preview the best plan (installs nothing)", function()
	if not carIdle() then
		return
	end
	State.CarPreviewRequested = true
	log("Car plan: working…", THEME.Dim)
end)
UI.makeButton(carPage, "Add best parts to cart", function()
	if not carIdle() then
		return
	end
	State.CarRequested = true
	log("Car parts: working…", THEME.Dim)
end)
UI.makeNote(carPage, "Open the car's parts shop in the garage first. Parts go into your cart and you pay by checking out there. With limited capacity or cash it picks the parts that give the most for what they use, tries a part together with the one it needs, and leaves out anything locked or refused by the server's own rules.")
end

-- Settings tab
UI.makeSection(settingsPage, "Movement")
UI.makeToggle(settingsPage, "Teleport instead of gliding", Config.Instant, function(value)
	Config.Instant = value
end)
UI.makeInput(settingsPage, "Glide speed (studs/s)", Config.Speed, 20, 1000, function(value)
	Config.Speed = value
end)
UI.makeInput(settingsPage, "Delay between stops (s)", Config.Delay, 0, 10, function(value)
	Config.Delay = value
end)
UI.makeSection(settingsPage, "Rewards")
local skipAvailable = hookInstalled or exclusiveHooked
local skipLabel = UI.makeToggle(settingsPage, "Skip cutscenes", Config.SkipAnimation, function(value)
	Config.SkipAnimation = value
end, not skipAvailable)
if not skipAvailable then
	skipLabel.Text = "Skip cutscenes (unavailable)"
	Config.SkipAnimation = false
end
UI.makeToggle(settingsPage, "Close rare-item popup", Config.AutoClose, function(value)
	Config.AutoClose = value
end)
UI.makeSection(settingsPage, "Fuel")
UI.makeToggle(settingsPage, "Auto-refuel when low", Config.AutoFuel, function(value)
	Config.AutoFuel = value
end)
UI.makeInput(settingsPage, "Refuel at or below (%)", Config.FuelBelow, 1, 100, function(value)
	Config.FuelBelow = value
end)
UI.makeSection(settingsPage, "Misc")
UI.makeToggle(settingsPage, "Anti-AFK", Config.AntiAfk, function(value)
	Config.AntiAfk = value
end)

-- Roblox fires Idled after ~20 minutes without input; a fake right-click resets the timer
connect(LocalPlayer.Idled, function()
	if not Config.AntiAfk then
		return
	end
	pcall(function()
		local virtualUser = game:GetService("VirtualUser")
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new())
	end)
end)

connect(startButton.Activated, function()
	Config.Enabled = not Config.Enabled
	renderStartButton()
	log(Config.Enabled and "Started" or "Stopped", THEME.Dim)
end)

local minimized = false
connect(minimizeButton.Activated, function()
	minimized = not minimized
	body.Visible = not minimized
	titleCover.Visible = not minimized
	minimizeButton.Text = minimized and "+" or "–"
end)

connect(closeButton.Activated, destroy)

connect(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		window.Visible = not window.Visible
	end
end)

-- dragging (mouse and touch)
do
	local dragging, dragStart, startPosition
	connect(titleBar.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = window.Position
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if
			dragging
			and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch)
		then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(
				startPosition.X.Scale,
				startPosition.X.Offset + delta.X,
				startPosition.Y.Scale,
				startPosition.Y.Offset + delta.Y
			)
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

refreshStats()
if hookInstalled then
	log("Hooked the knock handler (rewards tracked)", THEME.Good)
else
	log("Couldn't hook the knock handler: house cutscene skip and candy totals are off", THEME.Warn)
end
if exclusiveHooked then
	log("Hooked the rare-drop handler (graveyard rares tracked)", THEME.Good)
else
	log("Couldn't hook the rare-drop handler: graveyard rares won't be logged", THEME.Warn)
end
if not shopHooked and not getgc then
	log("Car parts: can't reach the parts shop (no module hook, no getgc), the Car tab won't work", THEME.Warn)
end
if not repoHooked and not getgc then
	log("Repo job: can't read the job state (no module hook, no getgc), it won't run", THEME.Warn)
end
if not TrickOrTreat then
	log("SeasonalEvent module not found, guessing the bag by name", THEME.Warn)
end
log("Ready. Press Start.", THEME.Dim)

task.spawn(mainLoop)
task.spawn(dismissLoop)
task.spawn(carLoop)
