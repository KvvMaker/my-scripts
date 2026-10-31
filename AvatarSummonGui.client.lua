--[[
	AvatarSummonGui  (LocalScript)
	Put in: StarterPlayer > StarterPlayerScripts

	Builds a summon window from ReplicatedStorage.Framework.SharedModules.AvatarSummon:
	  * banner tabs               (AvatarSummon.Banners)
	  * current lineup + odds     (SelectLineup -> ApplyLuck -> ApplySecretBoost)
	  * "lineup changes in" timer (TimeLeft / CurrentCounter)
	  * luck / secret-boost boxes (preview odds with a multiplier)
	  * summon buttons + costs    (Banner.Costs / ResolveCost)

	The only thing the module can't tell us is how the game actually performs a
	summon, so the buttons call requestSummon() below -- hook your remote in there.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SharedModules = ReplicatedStorage:WaitForChild("Framework"):WaitForChild("SharedModules")
local Enums = require(SharedModules:WaitForChild("Constants"):WaitForChild("Enums"))
local Avatars = require(SharedModules:WaitForChild("Avatars"))
local SummonLogic = require(SharedModules:WaitForChild("AvatarSummon"))
local SummonConfig = Enums.AvatarSummon

---------------------------------------------------------------------------
-- Hook this up to your summon remote
---------------------------------------------------------------------------
local function requestSummon(bannerName: string, amount)
	-- e.g. ReplicatedStorage.Remotes.Summon:InvokeServer(bannerName, amount)
	warn(("[AvatarSummonGui] Summon requested: banner=%s amount=%s (no remote connected)"):format(bannerName, tostring(amount)))
end

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------
local THEME = {
	Window = Color3.fromRGB(22, 22, 30),
	Panel = Color3.fromRGB(34, 34, 46),
	Row = Color3.fromRGB(44, 44, 60),
	Accent = Color3.fromRGB(88, 130, 255),
	Text = Color3.fromRGB(240, 240, 248),
	Muted = Color3.fromRGB(150, 150, 170),
}

local RARITY_COLORS = {
	Common = Color3.fromRGB(190, 190, 200),
	Uncommon = Color3.fromRGB(110, 210, 120),
	Rare = Color3.fromRGB(80, 160, 255),
	Epic = Color3.fromRGB(180, 100, 255),
	Legendary = Color3.fromRGB(255, 190, 60),
	Mythic = Color3.fromRGB(255, 90, 110),
	Secret = Color3.fromRGB(255, 60, 220),
}

local function rarityColor(rarity: string): Color3
	local known = RARITY_COLORS[rarity]
	if known then
		return known
	end
	local order = Enums.RarityOrder and Enums.RarityOrder[rarity] or 0
	return Color3.fromHSV((order * 0.13) % 1, 0.55, 0.95)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function make(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil
	for key, value in props do
		inst[key] = value
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function corner(radius: number): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function padding(all: number): UIPadding
	local p = UDim.new(0, all)
	return make("UIPadding", { PaddingTop = p, PaddingBottom = p, PaddingLeft = p, PaddingRight = p })
end

local function label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextColor3 = THEME.Text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextLabel", base)
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%02d:%02d", m, s)
end

local function avatarDisplayName(name: string): string
	local ok, def = pcall(function()
		return Avatars.Definitions[name]
	end)
	if ok and type(def) == "table" then
		return tostring(def.DisplayName or def.Name or name)
	end
	return name
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local selectedBanner: string? = nil
local luckValue = 1
local secretValue = 1
local lastCounter = nil
local tabButtons: { [string]: TextButton } = {}

---------------------------------------------------------------------------
-- GUI skeleton
---------------------------------------------------------------------------
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local old = playerGui:FindFirstChild("AvatarSummonGui")
if old then
	old:Destroy()
end

local screenGui = make("ScreenGui", {
	Name = "AvatarSummonGui",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local window = make("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0, 460, 0, 580),
	BackgroundColor3 = THEME.Window,
	Visible = false,
	Parent = screenGui,
}, {
	corner(14),
	make("UIStroke", { Color = THEME.Accent, Thickness = 1.5, Transparency = 0.4 }),
	make("UISizeConstraint", { MaxSize = Vector2.new(460, 580), MinSize = Vector2.new(280, 360) }),
})
local windowScale = make("UIScale", { Scale = 1, Parent = window })

-- Header
local header = make("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 52),
	BackgroundTransparency = 1,
	Parent = window,
}, { padding(12) })

label({
	Name = "Title",
	Size = UDim2.new(1, -44, 1, 0),
	Text = "Avatar Summon",
	Font = Enum.Font.GothamBold,
	TextSize = 22,
	Parent = header,
})

local closeButton = make("TextButton", {
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, 0, 0.5, 0),
	Size = UDim2.fromOffset(32, 32),
	BackgroundColor3 = THEME.Row,
	Text = "X",
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = THEME.Text,
	AutoButtonColor = true,
	Parent = header,
}, { corner(8) })

-- Banner tabs
local tabBar = make("ScrollingFrame", {
	Name = "Tabs",
	Position = UDim2.fromOffset(12, 54),
	Size = UDim2.new(1, -24, 0, 38),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 0,
	ScrollingDirection = Enum.ScrollingDirection.X,
	AutomaticCanvasSize = Enum.AutomaticSize.X,
	CanvasSize = UDim2.new(),
	Parent = window,
}, {
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

-- Info strip: banner subtitle + timer
local infoStrip = make("Frame", {
	Name = "Info",
	Position = UDim2.fromOffset(12, 98),
	Size = UDim2.new(1, -24, 0, 34),
	BackgroundColor3 = THEME.Panel,
	Parent = window,
}, { corner(8), make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })

local bannerLabel = label({
	Name = "Banner",
	Size = UDim2.new(0.5, 0, 1, 0),
	Text = "",
	Font = Enum.Font.GothamBold,
	Parent = infoStrip,
})

local timerLabel = label({
	Name = "Timer",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromScale(1, 0),
	Size = UDim2.new(0.5, 0, 1, 0),
	Text = "",
	TextColor3 = THEME.Muted,
	TextXAlignment = Enum.TextXAlignment.Right,
	Parent = infoStrip,
})

-- Lineup list
local lineupList = make("ScrollingFrame", {
	Name = "Lineup",
	Position = UDim2.fromOffset(12, 140),
	Size = UDim2.new(1, -24, 1, -140 - 12 - 62 - 8 - 44 - 8),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = window,
}, {
	corner(10),
	padding(8),
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
})

-- Luck row
local luckRow = make("Frame", {
	Name = "LuckRow",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, -12 - 62 - 8),
	Size = UDim2.new(1, -24, 0, 44),
	BackgroundColor3 = THEME.Panel,
	Parent = window,
}, {
	corner(10),
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }),
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local function inputBox(order: number, caption: string, onChange: (number) -> ()): TextBox
	label({
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = caption,
		TextColor3 = THEME.Muted,
		LayoutOrder = order,
		Parent = luckRow,
	})
	local box = make("TextBox", {
		Size = UDim2.new(0, 64, 1, 0),
		BackgroundColor3 = THEME.Row,
		Text = "1",
		PlaceholderText = "1",
		ClearTextOnFocus = false,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = THEME.Text,
		LayoutOrder = order + 1,
		Parent = luckRow,
	}, { corner(6) })
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text) or 1
		n = math.max(1, n)
		box.Text = tostring(n)
		onChange(n)
	end)
	return box
end

-- Footer (summon buttons)
local footer = make("Frame", {
	Name = "Footer",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, -12),
	Size = UDim2.new(1, -24, 0, 62),
	BackgroundTransparency = 1,
	Parent = window,
}, {
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

-- Open button
local openButton = make("TextButton", {
	Name = "OpenButton",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 12, 0.5, 0),
	Size = UDim2.fromOffset(96, 40),
	BackgroundColor3 = THEME.Accent,
	Text = "Summon",
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = Color3.new(1, 1, 1),
	Parent = screenGui,
}, { corner(10) })

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------
local function clearChildren(parent: Instance, className: string)
	for _, child in parent:GetChildren() do
		if child:IsA(className) then
			child:Destroy()
		end
	end
end

local function buildLineupRow(entry, bannerName: string, order: number)
	local color = rarityColor(entry.Rarity)
	local row = make("Frame", {
		Name = entry.Name,
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = THEME.Row,
		LayoutOrder = order,
		Parent = lineupList,
	}, { corner(8) })

	make("Frame", {
		Name = "Stripe",
		Size = UDim2.new(0, 4, 1, -12),
		Position = UDim2.fromOffset(6, 6),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = row,
	}, { corner(2) })

	label({
		Name = "AvatarName",
		Position = UDim2.fromOffset(18, 5),
		Size = UDim2.new(1, -110, 0, 20),
		Text = avatarDisplayName(entry.Name),
		Font = Enum.Font.GothamBold,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})

	label({
		Name = "Rarity",
		Position = UDim2.fromOffset(18, 24),
		Size = UDim2.new(1, -110, 0, 16),
		Text = entry.Rarity,
		TextSize = 12,
		TextColor3 = color,
		Parent = row,
	})

	local oddsText
	if SummonLogic.HidesOdds(bannerName, entry.Rarity) then
		oddsText = "???"
	else
		oddsText = SummonLogic.FormatPercent(bannerName, entry.Percentage)
	end

	label({
		Name = "Odds",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(90, 24),
		Text = tostring(oddsText),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})
end

local function rebuildLineup()
	clearChildren(lineupList, "GuiObject")
	if not selectedBanner then
		return
	end

	local counter = SummonLogic.CurrentCounter()
	lastCounter = counter

	local lineup = SummonLogic.SelectLineup(counter, selectedBanner)
	local total = 0
	for _, entry in ipairs(lineup) do
		total += entry.Percentage
	end
	lineup, total = SummonLogic.ApplyLuck(lineup, luckValue, selectedBanner)
	lineup, total = SummonLogic.ApplySecretBoost(lineup, total, secretValue)

	if #lineup == 0 then
		label({
			Size = UDim2.new(1, 0, 0, 40),
			Text = "No avatars available on this banner.",
			TextColor3 = THEME.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = lineupList,
		})
		return
	end

	for i, entry in ipairs(lineup) do
		buildLineupRow(entry, selectedBanner, i)
	end
end

local function sortedCostKeys(costs): { any }
	local keys = {}
	for key in pairs(costs) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then
			return na < nb
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function rebuildFooter()
	clearChildren(footer, "GuiObject")
	if not selectedBanner then
		return
	end
	local banner = SummonLogic.GetBanner(selectedBanner)
	if not banner or not banner.Costs then
		return
	end

	local keys = sortedCostKeys(banner.Costs)
	local count = math.max(#keys, 1)
	for i, key in ipairs(keys) do
		local _, costName, costAmount = SummonLogic.ResolveCost(selectedBanner, key)
		local button = make("TextButton", {
			Name = "Summon_" .. tostring(key),
			Size = UDim2.new(1 / count, -(8 * (count - 1)) / count, 1, 0),
			BackgroundColor3 = THEME.Accent,
			RichText = true,
			Text = ('<b>Summon x%s</b>\n<font size="12">%s %s</font>'):format(
				tostring(key),
				tostring(costAmount or "?"),
				tostring(costName or "")
			),
			Font = Enum.Font.Gotham,
			TextSize = 16,
			TextColor3 = Color3.new(1, 1, 1),
			LayoutOrder = i,
			Parent = footer,
		}, { corner(10) })

		local bannerName = selectedBanner
		button.Activated:Connect(function()
			requestSummon(bannerName, key)
		end)
	end
end

local function selectBanner(name: string)
	selectedBanner = name
	for bannerName, button in tabButtons do
		local active = bannerName == name
		button.BackgroundColor3 = active and THEME.Accent or THEME.Panel
		button.TextColor3 = active and Color3.new(1, 1, 1) or THEME.Muted
	end

	local banner = SummonLogic.GetBanner(name)
	bannerLabel.Text = tostring(banner and (banner.DisplayName or banner.Name) or name)

	rebuildLineup()
	rebuildFooter()
end

local function buildTabs()
	clearChildren(tabBar, "GuiObject")
	table.clear(tabButtons)
	for i, banner in ipairs(SummonConfig.Banners) do
		local name = banner.Name
		local info = SummonLogic.GetBanner(name)
		local button = make("TextButton", {
			Name = name,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = THEME.Panel,
			Text = tostring(info and (info.DisplayName or info.Name) or name),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = THEME.Muted,
			LayoutOrder = i,
			Parent = tabBar,
		}, {
			corner(8),
			make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }),
		})
		tabButtons[name] = button
		button.Activated:Connect(function()
			selectBanner(name)
		end)
	end
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
inputBox(1, "Luck x", function(n)
	luckValue = n
	rebuildLineup()
end)
inputBox(3, "Secret x", function(n)
	secretValue = n
	rebuildLineup()
end)

local function setOpen(open: boolean)
	if open then
		window.Visible = true
		windowScale.Scale = 0.9
		TweenService:Create(windowScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		rebuildLineup()
	else
		window.Visible = false
	end
end

openButton.Activated:Connect(function()
	setOpen(not window.Visible)
end)
closeButton.Activated:Connect(function()
	setOpen(false)
end)

buildTabs()
local firstBanner = SummonConfig.Banners[1]
if firstBanner then
	selectBanner(firstBanner.Name)
end

-- Timer + auto-refresh when the rotation ticks over
task.spawn(function()
	while screenGui.Parent do
		local timeLeft = SummonLogic.TimeLeft()
		if timeLeft then
			timerLabel.Text = "Lineup changes in " .. formatTime(timeLeft)
			if window.Visible and SummonLogic.CurrentCounter() ~= lastCounter then
				rebuildLineup()
			end
		else
			timerLabel.Text = "Permanent lineup"
		end
		task.wait(0.25)
	end
end)
