-- BuildQuestsUI.lua
-- Paste into the Studio command bar (or run as a plugin) while editing your place.
-- Builds StarterGui.QuestsUI with the exact hierarchy the quests LocalScript looks up:
--
--   QuestsUI (ScreenGui)
--     Main
--       Top              title + "Claim All" (the script clones ClaimQuest in here)
--       Close            close button
--       Main
--         Main           clips the sliding pages
--           QuestGroups
--             Buttons    one tab per group (each has Shadow + Notification badge)
--           Content      slides left/right to show a page
--             <group>    one page per group, each holding a "Scroll" ScrollingFrame
--             Configuration   hidden templates: QuestFrame (a row) and Empty
--
-- The tabs/pages come from ReplicatedStorage.QuestData.GROUPS when that module exists,
-- otherwise from FALLBACK_GROUPS below. Put the LocalScript in StarterPlayerScripts (or
-- anywhere that runs on the client) - this only builds the UI.

local REPLACE_EXISTING = false -- true = delete and rebuild StarterGui.QuestsUI if it already exists
local PREVIEW_ROW = true       -- adds a fake quest to the first tab so you can see the layout (the script wipes it on its first refresh)

local FALLBACK_GROUPS = { "daily", "weekly", "infinite", "story", "event" }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local existing = StarterGui:FindFirstChild("QuestsUI")
if existing then
	if not REPLACE_EXISTING then
		warn("StarterGui.QuestsUI already exists - set REPLACE_EXISTING = true to rebuild it")
		return
	end
	existing:Destroy()
end

local GROUPS = FALLBACK_GROUPS
local questData = ReplicatedStorage:FindFirstChild("QuestData")
if questData and questData:IsA("ModuleScript") then
	local ok, data = pcall(require, questData)
	if ok and type(data) == "table" and type(data.GROUPS) == "table" and #data.GROUPS > 0 then
		GROUPS = data.GROUPS
	end
end

local C = {
	frame = Color3.fromRGB(16, 18, 28),
	panel = Color3.fromRGB(27, 30, 44),
	row = Color3.fromRGB(39, 43, 62),
	rowEdge = Color3.fromRGB(58, 64, 92),
	track = Color3.fromRGB(18, 20, 30),
	accent = Color3.fromRGB(88, 140, 255),
	good = Color3.fromRGB(56, 192, 108),
	danger = Color3.fromRGB(232, 66, 78),
	locked = Color3.fromRGB(66, 72, 98),
	gold = Color3.fromRGB(255, 220, 80),
	text = Color3.new(1, 1, 1),
	sub = Color3.fromRGB(170, 176, 198),
}

local ROW_HEIGHT = 92 -- pixels; rows can't use Y scale because the script sizes the canvas from their height

-- helpers ---------------------------------------------------------------------------

local function new(class, props, parent)
	local inst = Instance.new(class)
	for key, value in pairs(props) do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function corner(parent, scale, offset)
	return new("UICorner", { CornerRadius = UDim.new(scale, offset) }, parent)
end

local function stroke(parent, color, thickness, transparency)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function padding(parent, left, top, right, bottom)
	return new("UIPadding", {
		PaddingLeft = UDim.new(left, 0),
		PaddingTop = UDim.new(top, 0),
		PaddingRight = UDim.new(right, 0),
		PaddingBottom = UDim.new(bottom, 0),
	}, parent)
end

-- TextLabel with scaled text capped by UITextSizeConstraint ("max" is ours, not a property)
local function label(props, parent)
	local p = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextColor3 = C.text,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for key, value in pairs(props) do
		if key ~= "max" then
			p[key] = value
		end
	end
	local inst = new("TextLabel", p, parent)
	new("UITextSizeConstraint", { MaxTextSize = props.max or 18, MinTextSize = 6 }, inst)
	return inst
end

local function capitalize(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

-- window ----------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "QuestsUI",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 5,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = true, -- the script switches it off on start; leave on so you can see it while editing
}, nil)

local main = new("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.5, 0.74),
	BackgroundColor3 = Color3.new(1, 1, 1), -- UIGradient multiplies this, so keep it white
	BorderSizePixel = 0,
	Active = true,
}, gui)
corner(main, 0, 14)
stroke(main, C.accent, 2, 0.35)
new("UIAspectRatioConstraint", { AspectRatio = 1.5 }, main)
new("UIScale", { Scale = 1 }, main)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(34, 38, 58), Color3.fromRGB(14, 16, 24)),
	Rotation = 90,
}, main)

-- title bar (the script parents the cloned "Claim All" button here)
local top = new("Frame", {
	Name = "Top",
	Size = UDim2.fromScale(1, 0.12),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, main)

label({
	Name = "Title",
	Text = "QUESTS",
	Position = UDim2.fromScale(0.03, 0.15),
	Size = UDim2.fromScale(0.3, 0.7),
	max = 30,
}, top)

local close = new("TextButton", {
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.fromScale(0.985, 0.06),
	Size = UDim2.fromScale(0.07, 0.07),
	SizeConstraint = Enum.SizeConstraint.RelativeYY,
	BackgroundColor3 = C.danger,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBlack,
	Text = "X",
	TextColor3 = C.text,
	TextScaled = true,
	ZIndex = 5,
}, main)
corner(close, 0, 8)
padding(close, 0.24, 0.24, 0.24, 0.24)
new("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 6 }, close)

-- body: Main > Main > Main
local panel = new("Frame", {
	Name = "Main",
	Position = UDim2.fromScale(0.02, 0.12),
	Size = UDim2.fromScale(0.96, 0.86),
	BackgroundColor3 = C.panel,
	BorderSizePixel = 0,
}, main)
corner(panel, 0, 10)
padding(panel, 0.012, 0.02, 0.012, 0.02)

local body = new("Frame", {
	Name = "Main",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, panel)

-- tabs --------------------------------------------------------------------------------

local groupsBar = new("Frame", {
	Name = "QuestGroups",
	Size = UDim2.fromScale(1, 0.11),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, body)

local buttons = new("Frame", {
	Name = "Buttons",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, groupsBar)

local TAB_GAP = 0.012
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Left,
	VerticalAlignment = Enum.VerticalAlignment.Bottom, -- unselected tabs are 90% tall and sit on the bottom edge
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(TAB_GAP, 0),
}, buttons)

local tabWidth = (1 - (#GROUPS - 1) * TAB_GAP) / #GROUPS

for i, group in ipairs(GROUPS) do
	local selected = i == 1

	local tab = new("TextButton", {
		Name = group,
		LayoutOrder = i,
		Size = UDim2.fromScale(tabWidth, selected and 1 or 0.9),
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = capitalize(group),
		TextColor3 = C.text,
		TextScaled = true,
	}, buttons)
	corner(tab, 0, 8)
	new("UITextSizeConstraint", { MaxTextSize = 20, MinTextSize = 6 }, tab)

	-- darkens the tab when it isn't the selected one
	local shadow = new("Frame", {
		Name = "Shadow",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Visible = not selected,
		ZIndex = 2,
	}, tab)
	corner(shadow, 0, 8)

	-- "+N claimable" badge
	local badge = new("Frame", {
		Name = "Notification",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.98, 0.08),
		Size = UDim2.fromScale(0.34, 0.44),
		BackgroundColor3 = C.danger,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 4,
	}, tab)
	corner(badge, 1, 0)
	stroke(badge, C.text, 1, 0.3)
	label({
		Name = "Notification",
		Text = "+0",
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 5,
		max = 14,
	}, badge)
end

-- pages -------------------------------------------------------------------------------

-- Content is moved by whole multiples of the body width, so each page is 1 body-width wide
-- and sits at X scale (index - 1). Y scale/offset of Content is preserved by the script.
local content = new("Frame", {
	Name = "Content",
	Position = UDim2.fromScale(0, 0.13),
	Size = UDim2.fromScale(1, 0.87),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, body)

for i, group in ipairs(GROUPS) do
	local page = new("Frame", {
		Name = group,
		Position = UDim2.fromScale(i - 1, 0),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, content)

	-- the script rewrites page.TextLabel.TextLabel on the daily and infinite pages
	local hasHeader = group == "daily" or group == "infinite"
	if hasHeader then
		local banner = new("Frame", {
			Name = "TextLabel",
			Size = UDim2.fromScale(1, 0.1),
			BackgroundColor3 = C.row,
			BorderSizePixel = 0,
		}, page)
		corner(banner, 0, 8)

		label({
			Name = "TextLabel",
			Text = group == "daily"
					and 'Quests refresh in: <font color="rgb(255,220,80)">00:00:00</font>'
				or "Infinite quests start over every time you claim them",
			RichText = true,
			Font = Enum.Font.GothamMedium,
			Position = UDim2.fromScale(0.03, 0.12),
			Size = UDim2.fromScale(0.94, 0.76),
			TextXAlignment = Enum.TextXAlignment.Center,
			max = 16,
		}, banner)
	end

	local scroll = new("ScrollingFrame", {
		Name = "Scroll",
		Position = hasHeader and UDim2.fromScale(0, 0.12) or UDim2.new(),
		Size = hasHeader and UDim2.fromScale(1, 0.88) or UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.accent,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, page)
	new("UIListLayout", {
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
	}, scroll)
	new("UIPadding", { PaddingTop = UDim.new(0, 6) }, scroll)
end

-- templates (cloned by the script; Configuration isn't a GuiObject so they never render) --

local configuration = new("Configuration", { Name = "Configuration" }, content)

local function questTemplate(parent)
	local row = new("Frame", {
		Name = "QuestFrame",
		Size = UDim2.new(0.96, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = C.row,
		BorderSizePixel = 0,
		Visible = false,
	}, parent)
	corner(row, 0, 10)
	stroke(row, C.rowEdge, 1, 0)

	label({
		Name = "QuestName",
		Text = "Quest name",
		Position = UDim2.fromScale(0.025, 0.07),
		Size = UDim2.fromScale(0.62, 0.27),
		max = 20,
	}, row)

	label({
		Name = "QuestDescription",
		Text = "Quest description",
		Font = Enum.Font.Gotham,
		TextColor3 = C.sub,
		Position = UDim2.fromScale(0.025, 0.35),
		Size = UDim2.fromScale(0.62, 0.2),
		max = 14,
	}, row)

	-- reward chips are added here; the script resizes/repositions this to 62% wide on the left
	local reward = new("ScrollingFrame", {
		Name = "Reward",
		Position = UDim2.fromScale(0.02, 0.62),
		Size = UDim2.fromScale(0.62, 0.3),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
	}, row)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}, reward)

	local info = new("Frame", {
		Name = "Info",
		Position = UDim2.fromScale(0.66, 0.06),
		Size = UDim2.fromScale(0.325, 0.37),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, row)

	label({
		Name = "CompletionProgress",
		Text = "Progress: 0/1",
		Font = Enum.Font.GothamMedium,
		Size = UDim2.fromScale(1, 0.55),
		TextXAlignment = Enum.TextXAlignment.Right,
		max = 14,
	}, info)

	label({
		Name = "Expiry",
		Text = "00:00:00 left",
		Font = Enum.Font.GothamMedium,
		TextColor3 = C.gold,
		Position = UDim2.fromScale(0, 0.55),
		Size = UDim2.fromScale(1, 0.45),
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		max = 12,
	}, info)

	local track = new("Frame", {
		Name = "Progress",
		Position = UDim2.fromScale(0.66, 0.47),
		Size = UDim2.fromScale(0.325, 0.1),
		BackgroundColor3 = C.track,
		BorderSizePixel = 0,
	}, row)
	corner(track, 1, 0)

	local bar = new("Frame", {
		Name = "Bar",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
	}, track)
	corner(bar, 1, 0)

	local claim = new("TextButton", {
		Name = "ClaimQuest",
		Position = UDim2.fromScale(0.66, 0.62),
		Size = UDim2.fromScale(0.325, 0.3),
		BackgroundColor3 = C.good,
		BorderSizePixel = 0,
		Text = "",
		Visible = false,
	}, row)
	corner(claim, 0, 8)
	stroke(claim, Color3.fromRGB(150, 245, 190), 1, 0.5)
	label({
		Name = "Text",
		Text = "Claim",
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		max = 16,
	}, claim)

	local incomplete = new("Frame", {
		Name = "Incomplete",
		Position = UDim2.fromScale(0.66, 0.62),
		Size = UDim2.fromScale(0.325, 0.3),
		BackgroundColor3 = C.locked,
		BorderSizePixel = 0,
	}, row)
	corner(incomplete, 0, 8)
	label({
		Name = "Text",
		Text = "Incomplete",
		TextColor3 = C.sub,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		max = 16,
	}, incomplete)

	return row
end

local template = questTemplate(configuration)

local empty = new("Frame", {
	Name = "Empty",
	Size = UDim2.new(0.96, 0, 0, 140),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Visible = false,
}, configuration)
label({
	Name = "Label1",
	Text = "You do not have any quests!",
	Font = Enum.Font.GothamMedium,
	TextColor3 = C.sub,
	Size = UDim2.fromScale(1, 1),
	TextXAlignment = Enum.TextXAlignment.Center,
	max = 20,
}, empty)

-- preview ---------------------------------------------------------------------------

if PREVIEW_ROW then
	local scroll = content:FindFirstChild(GROUPS[1]):FindFirstChild("Scroll")
	local sample = template:Clone()
	sample.Name = "PreviewSample"
	sample.Visible = true
	sample.QuestName.Text = "Defeat 25 enemies"
	sample.QuestDescription.Text = "Win battles to earn rewards"
	sample.Info.CompletionProgress.Text = "Progress: 10/25"
	sample.Info.Expiry.Text = "05:32:10 left"
	sample.Info.Expiry.Visible = true
	sample.Progress.Bar.Size = UDim2.fromScale(0.4, 1)

	for order, amount in ipairs({ "+250", "+5000" }) do
		local chip = new("Frame", {
			Name = "RewardChip",
			BackgroundColor3 = Color3.fromRGB(24, 24, 28),
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = order,
		}, sample.Reward)
		corner(chip, 0, 6)
		new("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }, chip)
		new("TextLabel", {
			Name = "Amount",
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextColor3 = C.text,
			Text = amount,
			TextSize = 14,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
		}, chip)
	end

	sample.Parent = scroll
end

gui.Parent = StarterGui
pcall(function()
	ChangeHistoryService:SetWaypoint("Build QuestsUI")
end)

print(("QuestsUI built in StarterGui with tabs: %s"):format(table.concat(GROUPS, ", ")))
