--[[
	Time Chamber Viewer
	Read-only GUI for ReplicatedStorage.Shared.TimeChamber.

	Tabs:
	  Release - live countdown, early-access check, release times
	  Rewards - searchable / filterable reward pool with computed odds
	  Info    - places, badge, data, teleport and reward config

	Works as a LocalScript or from an executor.
	Drag the title bar to move. RightShift hides / shows the window.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local WIDTH, HEIGHT = 470, 430
local TITLE_H = 36

local THEME = {
	Bg = Color3.fromRGB(22, 23, 29),
	Panel = Color3.fromRGB(32, 34, 43),
	Card = Color3.fromRGB(40, 43, 54),
	Stroke = Color3.fromRGB(58, 61, 76),
	Accent = Color3.fromRGB(96, 165, 250),
	Text = Color3.fromRGB(236, 238, 245),
	Muted = Color3.fromRGB(150, 156, 172),
	Good = Color3.fromRGB(74, 222, 128),
	Warn = Color3.fromRGB(250, 204, 21),
	Bad = Color3.fromRGB(248, 113, 113),
}

local RARITY = {
	Common = { Color = Color3.fromRGB(170, 176, 190) },
	Rare = { Color = Color3.fromRGB(96, 165, 250) },
	Epic = { Color = Color3.fromRGB(192, 132, 252) },
	Legendary = { Color = Color3.fromRGB(251, 146, 60) },
	Mythical = { Color = Color3.fromRGB(244, 114, 182) },
}
local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary", "Mythical" }

---------------------------------------------------------------------
-- Load the module
---------------------------------------------------------------------

local loaded, TimeChamber = pcall(function()
	local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
	local moduleScript = sharedFolder and sharedFolder:WaitForChild("TimeChamber", 10)
	return require(moduleScript)
end)

if not loaded or type(TimeChamber) ~= "table" then
	warn("[TimeChamberViewer] Could not load ReplicatedStorage.Shared.TimeChamber: " .. tostring(TimeChamber))
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Time Chamber Viewer",
			Text = "Could not load the TimeChamber module.",
			Duration = 6,
		})
	end)
	return
end

local Release = TimeChamber.Release or {}
local RewardsCfg = TimeChamber.Rewards or {}
local Places = TimeChamber.Places or {}
local Badges = TimeChamber.Badges or {}
local DataCfg = TimeChamber.Data or {}
local TeleportCfg = TimeChamber.Teleport or {}

local okPool, poolResult = pcall(TimeChamber.GetRewardPool, TimeChamber)
local pool = (okPool and poolResult) or RewardsCfg.Pool or {}

local totalWeight = 0
for _, reward in pool do
	totalWeight += reward.Weight
end

local totalRolls = (RewardsCfg.TotalRewards or 0) * (RewardsCfg.RollsPerInterval or 1)

local entries = {}
for _, reward in pool do
	local chance = totalWeight > 0 and reward.Weight / totalWeight or 0
	table.insert(entries, {
		Data = reward,
		Display = reward.DisplayName or reward.Name,
		Rarity = RARITY[reward.Rarity] and reward.Rarity or "Common",
		Chance = chance,
		Expected = chance * totalRolls,
	})
end

---------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------

local function str(value)
	return value ~= nil and tostring(value) or "n/a"
end

local function fmtDuration(seconds)
	seconds = math.max(0, math.floor(seconds))
	local d = seconds // 86400
	local h = seconds % 86400 // 3600
	local m = seconds % 3600 // 60
	local s = seconds % 60
	if d > 0 then
		return string.format("%dd %02dh %02dm %02ds", d, h, m, s)
	end
	return string.format("%02dh %02dm %02ds", h, m, s)
end

local function fmtShort(seconds)
	if not seconds then
		return "n/a"
	end
	if seconds >= 3600 and seconds % 3600 == 0 then
		return string.format("%dh", seconds // 3600)
	elseif seconds >= 60 and seconds % 60 == 0 then
		return string.format("%dm", seconds // 60)
	end
	return string.format("%gs", seconds)
end

local function fmtDate(timestamp, utc)
	return os.date((utc and "!" or "") .. "%Y-%m-%d %H:%M:%S", timestamp)
end

local function fmtAmount(reward)
	if reward.MinAmount == reward.MaxAmount then
		return "x" .. reward.MinAmount
	end
	return "x" .. reward.MinAmount .. "-" .. reward.MaxAmount
end

local function copyToClipboard(text)
	if typeof(setclipboard) == "function" then
		return pcall(setclipboard, tostring(text))
	end
	return false
end

---------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for key, value in props do
		if key == "Parent" then
			parent = value
		else
			inst[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function round(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.Gotham
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or THEME.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props)
end

local function button(props)
	props.BorderSizePixel = 0
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or THEME.Text
	props.BackgroundColor3 = props.BackgroundColor3 or THEME.Card
	return new("TextButton", props, { round(6) })
end

local function nextOrder(container)
	return #container:GetChildren()
end

local function scroller(parent, props)
	props.Parent = parent
	props.BackgroundTransparency = 1
	props.BorderSizePixel = 0
	props.ScrollBarThickness = 4
	props.CanvasSize = UDim2.new()
	props.AutomaticCanvasSize = Enum.AutomaticSize.Y
	props.ScrollingDirection = Enum.ScrollingDirection.Y
	return new("ScrollingFrame", props, {
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", { PaddingRight = UDim.new(0, 8) }),
	})
end

local function addHeader(page, text)
	return label({
		Parent = page,
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = THEME.Accent,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = nextOrder(page),
	})
end

local function addRow(page, key, text, copyValue)
	local row = new("Frame", {
		Parent = page,
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = THEME.Card,
		BorderSizePixel = 0,
		LayoutOrder = nextOrder(page),
	}, { round(6) })

	label({
		Parent = row,
		Text = key,
		TextColor3 = THEME.Muted,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.36, 0, 1, 0),
	})

	local value = label({
		Parent = row,
		Text = text,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.new(0.36, 0, 0, 0),
		Size = UDim2.new(0.64, copyValue and -64 or -12, 1, 0),
	})

	if copyValue ~= nil then
		local copyBtn = button({
			Parent = row,
			Text = "Copy",
			TextSize = 11,
			BackgroundColor3 = THEME.Panel,
			Position = UDim2.new(1, -52, 0.5, -10),
			Size = UDim2.fromOffset(44, 20),
		})
		copyBtn.MouseButton1Click:Connect(function()
			copyBtn.Text = copyToClipboard(copyValue) and "Copied" or "N/A"
			task.delay(1, function()
				if copyBtn.Parent then
					copyBtn.Text = "Copy"
				end
			end)
		end)
	end

	return value
end

---------------------------------------------------------------------
-- Window
---------------------------------------------------------------------

local function getContainer()
	if typeof(gethui) == "function" then
		local ok, hui = pcall(gethui)
		if ok and typeof(hui) == "Instance" then
			return hui
		end
	end

	local probe = Instance.new("Folder")
	local coreGui = game:GetService("CoreGui")
	local ok = pcall(function()
		probe.Parent = coreGui
	end)
	local usable = ok and probe.Parent == coreGui
	probe:Destroy()
	if usable then
		return coreGui
	end

	return LocalPlayer:WaitForChild("PlayerGui")
end

local container = getContainer()
local old = container:FindFirstChild("TimeChamberViewer")
if old then
	old:Destroy()
end

local gui = new("ScreenGui", {
	Name = "TimeChamberViewer",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
})

local main = new("Frame", {
	Parent = gui,
	Size = UDim2.fromOffset(WIDTH, HEIGHT),
	Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2),
	BackgroundColor3 = THEME.Bg,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, {
	round(10),
	new("UIStroke", { Color = THEME.Stroke, Thickness = 1 }),
})

local titleBar = new("Frame", {
	Parent = main,
	Size = UDim2.new(1, 0, 0, TITLE_H),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
}, { round(10) })

-- squares off the bottom corners of the rounded title bar
new("Frame", {
	Parent = titleBar,
	Position = UDim2.fromScale(0, 0.5),
	Size = UDim2.fromScale(1, 0.5),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
})

label({
	Parent = titleBar,
	Text = "Time Chamber",
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -90, 1, 0),
})

local minimizeBtn = button({
	Parent = titleBar,
	Text = "-",
	TextSize = 16,
	BackgroundColor3 = THEME.Card,
	Position = UDim2.new(1, -66, 0.5, -11),
	Size = UDim2.fromOffset(26, 22),
})

local closeBtn = button({
	Parent = titleBar,
	Text = "x",
	TextSize = 14,
	BackgroundColor3 = THEME.Bad,
	Position = UDim2.new(1, -34, 0.5, -11),
	Size = UDim2.fromOffset(26, 22),
})

local body = new("Frame", {
	Parent = main,
	Position = UDim2.fromOffset(0, TITLE_H),
	Size = UDim2.new(1, 0, 1, -TITLE_H),
	BackgroundTransparency = 1,
})

local tabBar = new("Frame", {
	Parent = body,
	Position = UDim2.fromOffset(12, 8),
	Size = UDim2.new(1, -24, 0, 28),
	BackgroundTransparency = 1,
}, {
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local content = new("Frame", {
	Parent = body,
	Position = UDim2.fromOffset(12, 44),
	Size = UDim2.new(1, -24, 1, -52),
	BackgroundTransparency = 1,
})

local TAB_NAMES = { "Release", "Rewards", "Info" }
local tabButtons, pages = {}, {}

local function selectTab(name)
	for tabName, page in pages do
		page.Visible = tabName == name
		tabButtons[tabName].BackgroundColor3 = tabName == name and THEME.Accent or THEME.Card
		tabButtons[tabName].TextColor3 = tabName == name and THEME.Bg or THEME.Text
	end
end

for index, name in ipairs(TAB_NAMES) do
	tabButtons[name] = button({
		Parent = tabBar,
		Text = name,
		Size = UDim2.new(1 / #TAB_NAMES, -4, 1, 0),
		LayoutOrder = index,
	})
	pages[name] = new("Frame", {
		Parent = content,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	})
	tabButtons[name].MouseButton1Click:Connect(function()
		selectTab(name)
	end)
end

-- dragging
local dragging, dragStart, startPos
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, main.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

local moveConn = UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

local toggleConn = UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

local minimized = false
minimizeBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	main.Size = UDim2.fromOffset(WIDTH, minimized and TITLE_H or HEIGHT)
end)

closeBtn.MouseButton1Click:Connect(function()
	moveConn:Disconnect()
	toggleConn:Disconnect()
	gui:Destroy()
end)

---------------------------------------------------------------------
-- Release tab
---------------------------------------------------------------------

local releasePage = scroller(pages.Release, { Size = UDim2.fromScale(1, 1) })

local hero = new("Frame", {
	Parent = releasePage,
	Size = UDim2.new(1, 0, 0, 104),
	BackgroundColor3 = THEME.Card,
	BorderSizePixel = 0,
	LayoutOrder = nextOrder(releasePage),
}, { round(8) })

local statusLabel = label({
	Parent = hero,
	Text = "",
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = THEME.Muted,
	TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(14, 10),
	Size = UDim2.new(1, -28, 0, 16),
})

local countdownLabel = label({
	Parent = hero,
	Text = "--",
	Font = Enum.Font.GothamBold,
	TextSize = 30,
	TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(14, 28),
	Size = UDim2.new(1, -28, 0, 44),
})

local subLabel = label({
	Parent = hero,
	Text = "",
	TextSize = 12,
	TextColor3 = THEME.Muted,
	TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(14, 78),
	Size = UDim2.new(1, -28, 0, 18),
})

local gateRow = addRow(releasePage, "Release gate active", str(TimeChamber.TIMECHAMBER_ACTIVE))
local configRow = addRow(releasePage, "Configured time", "n/a")
local utcRow = addRow(releasePage, "Public release (UTC)", "n/a")
local localRow = addRow(releasePage, "Public release (local)", "n/a")
local earlyRow = addRow(releasePage, "Early access (you)", "Checking...")
local yoursRow = addRow(releasePage, "Your release (local)", "n/a")
addRow(releasePage, "Early access lead", fmtShort(Release.EarlyAccessSeconds))
addRow(
	releasePage,
	"Early access group",
	string.format("%s (rank %s+)", str(Release.EarlyAccessGroupId), str(Release.EarlyAccessMinimumRank)),
	Release.EarlyAccessGroupId
)

local refreshBtn = button({
	Parent = releasePage,
	Text = "Re-check early access",
	Size = UDim2.new(1, 0, 0, 30),
	LayoutOrder = nextOrder(releasePage),
})

local state = { Checked = false, BaseAt = nil, ReleaseAt = nil, EarlyAccess = false }

local function refreshState()
	local okBase, base = pcall(TimeChamber.GetReleaseTimestamp, TimeChamber)
	state.BaseAt = okBase and base or nil
	if not state.Checked then
		-- show the public countdown right away; the early-access lookup below yields
		state.ReleaseAt = state.BaseAt
	end

	local okEarly, early = pcall(TimeChamber.IsEarlyAccess, TimeChamber, LocalPlayer)
	state.EarlyAccess = okEarly and early == true
	state.ReleaseAt = state.BaseAt
	if state.BaseAt and state.EarlyAccess then
		state.ReleaseAt = state.BaseAt - (Release.EarlyAccessSeconds or 0)
	end
	state.Checked = true
end

local function renderRelease()
	configRow.Text = string.format(
		"%04d-%02d-%02d %02d:%02d (UTC%+g)",
		Release.Year or 0, Release.Month or 0, Release.Day or 0,
		Release.Hour or 0, Release.Minute or 0, Release.UTCOffsetHours or 0
	)

	if state.BaseAt then
		utcRow.Text = fmtDate(state.BaseAt, true)
		localRow.Text = fmtDate(state.BaseAt, false)
	else
		utcRow.Text, localRow.Text = "not scheduled", "not scheduled"
	end

	if not state.Checked then
		earlyRow.Text = "Checking..."
		earlyRow.TextColor3 = THEME.Muted
	elseif state.EarlyAccess then
		earlyRow.Text = "Yes"
		earlyRow.TextColor3 = THEME.Good
	else
		earlyRow.Text = "No"
		earlyRow.TextColor3 = THEME.Text
	end

	yoursRow.Text = state.ReleaseAt and fmtDate(state.ReleaseAt, false) or "n/a"

	gateRow.Text = str(TimeChamber.TIMECHAMBER_ACTIVE)
	gateRow.TextColor3 = TimeChamber.TIMECHAMBER_ACTIVE and THEME.Warn or THEME.Good
end

local function updateCountdown()
	if not TimeChamber.TIMECHAMBER_ACTIVE then
		statusLabel.Text, statusLabel.TextColor3 = "GATE DISABLED", THEME.Good
		countdownLabel.Text = "Open"
		subLabel.Text = "TIMECHAMBER_ACTIVE is false"
	elseif not state.ReleaseAt then
		statusLabel.Text, statusLabel.TextColor3 = "NOT SCHEDULED", THEME.Muted
		countdownLabel.Text = "--"
		subLabel.Text = state.Checked and "No valid release time in config" or "Checking..."
	else
		local remaining = state.ReleaseAt - Workspace:GetServerTimeNow()
		if remaining <= 0 then
			statusLabel.Text, statusLabel.TextColor3 = "RELEASED", THEME.Good
			countdownLabel.Text = "Open now"
			subLabel.Text = "Opened " .. fmtDate(state.ReleaseAt, false) .. " (your time)"
		else
			statusLabel.Text = state.EarlyAccess and "COUNTDOWN (EARLY ACCESS)" or "COUNTDOWN"
			statusLabel.TextColor3 = THEME.Warn
			countdownLabel.Text = fmtDuration(remaining)
			subLabel.Text = "Opens " .. fmtDate(state.ReleaseAt, false) .. " (your time)"
		end
	end
end

local refreshing = false
refreshBtn.MouseButton1Click:Connect(function()
	if refreshing then
		return
	end
	refreshing = true
	refreshBtn.Text = "Checking..."
	task.spawn(function()
		refreshState()
		renderRelease()
		refreshBtn.Text = "Re-check early access"
		refreshing = false
	end)
end)

---------------------------------------------------------------------
-- Rewards tab
---------------------------------------------------------------------

local rewardsPage = pages.Rewards
local filter = "All"
local rarestFirst = true

local searchBox = new("TextBox", {
	Parent = rewardsPage,
	Size = UDim2.fromOffset(190, 28),
	BackgroundColor3 = THEME.Card,
	BorderSizePixel = 0,
	PlaceholderText = "Search rewards...",
	PlaceholderColor3 = THEME.Muted,
	Text = "",
	TextColor3 = THEME.Text,
	TextSize = 13,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	ClearTextOnFocus = false,
}, {
	round(6),
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
})

local sortBtn = button({
	Parent = rewardsPage,
	Text = "Rarest first",
	Position = UDim2.fromOffset(198, 0),
	Size = UDim2.fromOffset(120, 28),
})

local countLabel = label({
	Parent = rewardsPage,
	Text = "",
	TextSize = 12,
	TextColor3 = THEME.Muted,
	TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(326, 0),
	Size = UDim2.new(1, -326, 0, 28),
})

local chipBar = new("Frame", {
	Parent = rewardsPage,
	Position = UDim2.fromOffset(0, 34),
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
}, {
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local runSeconds = (RewardsCfg.IntervalSeconds or 0) * (RewardsCfg.TotalRewards or 0)
label({
	Parent = rewardsPage,
	Text = string.format(
		"%s rewards, one every %s (%s roll%s each) over %s. Odds are weight / total weight (%.4g).",
		str(RewardsCfg.TotalRewards), fmtShort(RewardsCfg.IntervalSeconds),
		str(RewardsCfg.RollsPerInterval), (RewardsCfg.RollsPerInterval or 1) == 1 and "" or "s",
		fmtDuration(runSeconds), totalWeight
	),
	TextSize = 11,
	TextColor3 = THEME.Muted,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	Position = UDim2.fromOffset(0, 62),
	Size = UDim2.new(1, 0, 0, 30),
})

local rewardList = scroller(rewardsPage, {
	Position = UDim2.fromOffset(0, 96),
	Size = UDim2.new(1, 0, 1, -96),
})

local function buildCard(entry, order)
	local reward = entry.Data
	local rarityColor = RARITY[entry.Rarity].Color

	local card = new("Frame", {
		Parent = rewardList,
		Size = UDim2.new(1, 0, 0, 58),
		BackgroundColor3 = THEME.Card,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = order,
	}, { round(6) })

	new("Frame", {
		Parent = card,
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = rarityColor,
		BorderSizePixel = 0,
	})

	local textX = 14
	if reward.Icon then
		new("ImageLabel", {
			Parent = card,
			Image = reward.Icon,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(14, 13),
			Size = UDim2.fromOffset(32, 32),
		})
		textX = 54
	end

	local textSize = UDim2.new(1, -(textX + 100), 0, 16)

	label({
		Parent = card,
		Text = entry.Display,
		Font = Enum.Font.GothamBold,
		TextColor3 = rarityColor,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(textX, 6),
		Size = textSize,
	})

	local detail = string.format("%s | %s | %s", reward.Type, entry.Rarity, fmtAmount(reward))
	if reward.Limit then
		detail ..= " | Limit " .. reward.Limit
	end
	label({
		Parent = card,
		Text = detail,
		TextSize = 11,
		TextColor3 = THEME.Muted,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(textX, 23),
		Size = textSize,
	})

	label({
		Parent = card,
		Text = string.format("~%.3g expected per run", entry.Expected),
		TextSize = 11,
		TextColor3 = THEME.Muted,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(textX, 38),
		Size = textSize,
	})

	label({
		Parent = card,
		Text = string.format("%.3g%%", entry.Chance * 100),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -96, 0, 8),
		Size = UDim2.fromOffset(86, 20),
	})

	label({
		Parent = card,
		Text = reward.ChanceText and ("listed " .. reward.ChanceText) or "",
		TextSize = 11,
		TextColor3 = THEME.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -96, 0, 30),
		Size = UDim2.fromOffset(86, 16),
	})
end

local function renderRewards()
	for _, child in rewardList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local query = string.lower(searchBox.Text)
	local shown = {}
	for _, entry in entries do
		local haystack = string.lower(entry.Display .. " " .. entry.Data.Name .. " " .. entry.Data.Type)
		local matchesRarity = filter == "All" or entry.Rarity == filter
		if matchesRarity and (query == "" or string.find(haystack, query, 1, true)) then
			table.insert(shown, entry)
		end
	end

	table.sort(shown, function(a, b)
		if a.Chance == b.Chance then
			return a.Display < b.Display
		end
		if rarestFirst then
			return a.Chance < b.Chance
		end
		return a.Chance > b.Chance
	end)

	countLabel.Text = string.format("%d / %d", #shown, #entries)

	for index, entry in shown do
		buildCard(entry, index)
	end

	if #shown == 0 then
		label({
			Parent = rewardList,
			Text = "No rewards match.",
			TextColor3 = THEME.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 40),
		})
	end
end

local chips = {}
local function setFilter(name)
	filter = name
	for chipName, chip in chips do
		local color = chipName == "All" and THEME.Accent or RARITY[chipName].Color
		chip.BackgroundColor3 = chipName == name and color or THEME.Card
		chip.TextColor3 = chipName == name and THEME.Bg or color
	end
	renderRewards()
end

for index, name in ipairs({ "All", table.unpack(RARITY_ORDER) }) do
	local chip = button({
		Parent = chipBar,
		Text = name,
		TextSize = 11,
		Size = UDim2.new(1 / 6, -4, 1, 0),
		LayoutOrder = index,
	})
	chips[name] = chip
	chip.MouseButton1Click:Connect(function()
		setFilter(name)
	end)
end

sortBtn.MouseButton1Click:Connect(function()
	rarestFirst = not rarestFirst
	sortBtn.Text = rarestFirst and "Rarest first" or "Most common first"
	renderRewards()
end)

searchBox:GetPropertyChangedSignal("Text"):Connect(renderRewards)

---------------------------------------------------------------------
-- Info tab
---------------------------------------------------------------------

local infoPage = scroller(pages.Info, { Size = UDim2.fromScale(1, 1) })

addHeader(infoPage, "PLACES")
addRow(infoPage, "Original place", str(Places.Original), Places.Original)
addRow(infoPage, "Time Chamber place", str(Places.TimeChamber), Places.TimeChamber)

addHeader(infoPage, "BADGES")
addRow(infoPage, "Welcome badge", str(Badges.Welcome), Badges.Welcome)

addHeader(infoPage, "DATA")
addRow(infoPage, "Store name", str(DataCfg.StoreName))
addRow(infoPage, "Version", str(DataCfg.Version))
addRow(infoPage, "Mock data in Studio", str(DataCfg.UseMockInStudio))

addHeader(infoPage, "TELEPORT")
addRow(infoPage, "Retry", fmtShort(TeleportCfg.RetrySeconds))
addRow(infoPage, "Max retry", fmtShort(TeleportCfg.MaxRetrySeconds))
addRow(infoPage, "Attempt timeout", fmtShort(TeleportCfg.AttemptTimeoutSeconds))
addRow(infoPage, "Check interval", fmtShort(TeleportCfg.CheckSeconds))

addHeader(infoPage, "REWARDS")
addRow(infoPage, "Enabled", str(RewardsCfg.Enabled))
addRow(infoPage, "Interval", fmtShort(RewardsCfg.IntervalSeconds))
addRow(infoPage, "Total rewards", str(RewardsCfg.TotalRewards))
addRow(infoPage, "Rolls per interval", str(RewardsCfg.RollsPerInterval))
addRow(infoPage, "Run length", fmtDuration(runSeconds))
addRow(infoPage, "Pool entries", tostring(#entries))
addRow(infoPage, "Total weight", string.format("%.6g", totalWeight))

---------------------------------------------------------------------
-- Start
---------------------------------------------------------------------

-- runs up to the early-access lookup immediately, so the countdown has a time to show
task.spawn(function()
	refreshState()
	renderRelease()
end)

gui.Parent = container
setFilter("All")
selectTab("Release")
renderRelease()
updateCountdown()

task.spawn(function()
	while gui.Parent do
		updateCountdown()
		task.wait(0.25)
	end
end)
