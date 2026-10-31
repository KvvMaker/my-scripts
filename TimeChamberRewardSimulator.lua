--[[
	Time Chamber Reward Simulator (Studio only)

	Dev tool for the game's own Studio place. Put it in a LocalScript under
	StarterPlayer > StarterPlayerScripts and press Play. It does nothing outside
	Studio and never touches the server's reward logic: it rolls the pool from
	ReplicatedStorage.Shared.TimeChamber locally so you can sanity-check the odds,
	the Limit caps and how long a full run lasts for a given IntervalSeconds.

	To actually shorten the real interval while testing, edit Rewards.IntervalSeconds
	in the TimeChamber module in your own place (the server reads the same module).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local TimeChamber = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimeChamber"))
local Rewards = TimeChamber.Rewards
local pool = TimeChamber:GetRewardPool()

local MAX_ROLLS = 200000
local MAX_REROLL_ATTEMPTS = 50

local entries, totalWeight = {}, 0
for _, reward in pool do
	totalWeight += reward.Weight
	table.insert(entries, {
		Key = reward.Type .. ":" .. reward.Name,
		Display = reward.DisplayName or reward.Name,
		Data = reward,
		Chance = 0,
	})
end
for _, entry in entries do
	entry.Chance = entry.Data.Weight / totalWeight
end

---------------------------------------------------------------------
-- Simulation state
---------------------------------------------------------------------

local rng = Random.new()
local owned, stats = {}, {}
local rollsDone = 0
local lastGrant = "-"
local rerollOnCap = false

local function resetState(seed)
	rng = seed and Random.new(seed) or Random.new()
	owned, stats = {}, {}
	rollsDone = 0
	lastGrant = "-"
	for _, entry in entries do
		stats[entry.Key] = { Hits = 0, Qty = 0, Capped = 0 }
	end
end

local function pickEntry()
	local target = rng:NextNumber() * totalWeight
	local acc = 0
	for _, entry in entries do
		acc += entry.Data.Weight
		if target < acc then
			return entry
		end
	end
	return entries[#entries]
end

-- One interval's roll. Limit is treated as a cap on total amount received.
local function rollOnce()
	rollsDone += 1
	for _ = 1, rerollOnCap and MAX_REROLL_ATTEMPTS or 1 do
		local entry = pickEntry()
		local reward = entry.Data
		local stat = stats[entry.Key]

		if reward.Limit and (owned[entry.Key] or 0) >= reward.Limit then
			stat.Capped += 1
		else
			local amount = rng:NextInteger(reward.MinAmount, reward.MaxAmount)
			owned[entry.Key] = (owned[entry.Key] or 0) + amount
			stat.Hits += 1
			stat.Qty += amount
			lastGrant = string.format("%s x%d", entry.Display, amount)
			return
		end
	end
	lastGrant = "(capped, nothing granted)"
end

---------------------------------------------------------------------
-- UI
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

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function text(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.Gotham
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or Color3.fromRGB(236, 238, 245)
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props)
end

local function button(props)
	props.BorderSizePixel = 0
	props.Font = Enum.Font.GothamMedium
	props.TextSize = 13
	props.TextColor3 = Color3.fromRGB(236, 238, 245)
	props.BackgroundColor3 = props.BackgroundColor3 or Color3.fromRGB(52, 56, 70)
	return new("TextButton", props, { corner(6) })
end

local function box(props)
	props.BackgroundColor3 = Color3.fromRGB(40, 43, 54)
	props.BorderSizePixel = 0
	props.Font = Enum.Font.Gotham
	props.TextSize = 13
	props.TextColor3 = Color3.fromRGB(236, 238, 245)
	props.PlaceholderColor3 = Color3.fromRGB(150, 156, 172)
	props.ClearTextOnFocus = false
	return new("TextBox", props, { corner(6) })
end

local function fmtDuration(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%dd %02dh %02dm %02ds", seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60, seconds % 60)
end

local gui = new("ScreenGui", {
	Name = "TimeChamberRewardSimulator",
	ResetOnSpawn = false,
	Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
})

local main = new("Frame", {
	Parent = gui,
	Position = UDim2.fromOffset(20, 20),
	Size = UDim2.fromOffset(520, 440),
	BackgroundColor3 = Color3.fromRGB(22, 23, 29),
	BorderSizePixel = 0,
}, { corner(10) })

text({
	Parent = main,
	Text = "Reward Simulator (Studio only)",
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	Position = UDim2.fromOffset(14, 10),
	Size = UDim2.new(1, -28, 0, 22),
})

text({ Parent = main, Text = "Rolls", Position = UDim2.fromOffset(14, 44), Size = UDim2.fromOffset(40, 28) })
local rollsBox = box({
	Parent = main,
	Text = tostring((Rewards.TotalRewards or 1) * (Rewards.RollsPerInterval or 1)),
	Position = UDim2.fromOffset(56, 44),
	Size = UDim2.fromOffset(80, 28),
})

text({ Parent = main, Text = "Seed", Position = UDim2.fromOffset(150, 44), Size = UDim2.fromOffset(36, 28) })
local seedBox = box({
	Parent = main,
	Text = "",
	PlaceholderText = "random",
	Position = UDim2.fromOffset(190, 44),
	Size = UDim2.fromOffset(80, 28),
})

local simulateBtn = button({
	Parent = main,
	Text = "Simulate run",
	BackgroundColor3 = Color3.fromRGB(96, 165, 250),
	Position = UDim2.fromOffset(284, 44),
	Size = UDim2.fromOffset(110, 28),
})
simulateBtn.TextColor3 = Color3.fromRGB(22, 23, 29)

local stepBtn = button({ Parent = main, Text = "+1 roll", Position = UDim2.fromOffset(402, 44), Size = UDim2.fromOffset(104, 28) })

local capBtn = button({ Parent = main, Text = "On limit: skip", Position = UDim2.fromOffset(14, 80), Size = UDim2.fromOffset(130, 28) })
local resetBtn = button({ Parent = main, Text = "Reset", Position = UDim2.fromOffset(152, 80), Size = UDim2.fromOffset(70, 28) })

text({ Parent = main, Text = "Interval (s)", Position = UDim2.fromOffset(244, 80), Size = UDim2.fromOffset(74, 28) })
local intervalBox = box({
	Parent = main,
	Text = tostring(Rewards.IntervalSeconds or 300),
	Position = UDim2.fromOffset(320, 80),
	Size = UDim2.fromOffset(60, 28),
})
local runLengthLabel = text({
	Parent = main,
	TextSize = 11,
	TextColor3 = Color3.fromRGB(150, 156, 172),
	Position = UDim2.fromOffset(388, 80),
	Size = UDim2.new(1, -396, 0, 28),
	TextWrapped = true,
	Text = "",
})

local output = new("ScrollingFrame", {
	Parent = main,
	Position = UDim2.fromOffset(14, 118),
	Size = UDim2.new(1, -28, 1, -132),
	BackgroundColor3 = Color3.fromRGB(32, 34, 43),
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, { corner(6), new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 6) }) })

local outputLabel = text({
	Parent = output,
	Font = Enum.Font.Code,
	TextSize = 12,
	TextYAlignment = Enum.TextYAlignment.Top,
	AutomaticSize = Enum.AutomaticSize.Y,
	Size = UDim2.new(1, -8, 0, 0),
	Text = "",
})

local function render()
	local sorted = table.clone(entries)
	table.sort(sorted, function(a, b)
		local hitsA, hitsB = stats[a.Key].Hits, stats[b.Key].Hits
		if hitsA == hitsB then
			return a.Chance > b.Chance
		end
		return hitsA > hitsB
	end)

	local lines = {
		string.format("Rolls: %d   Last: %s", rollsDone, lastGrant),
		string.format("On limit: %s", rerollOnCap and "reroll (max 50 tries)" or "skip (nothing granted)"),
		"",
		string.format("%-20s %6s %7s %8s %6s", "Reward", "Hits", "Qty", "Expect", "Capped"),
	}
	for _, entry in sorted do
		local stat = stats[entry.Key]
		table.insert(lines, string.format(
			"%-20s %6d %7d %8.2f %6d",
			string.sub(entry.Display, 1, 20), stat.Hits, stat.Qty, entry.Chance * rollsDone, stat.Capped
		))
	end
	outputLabel.Text = table.concat(lines, "\n")
end

local function updateRunLength()
	local interval = tonumber(intervalBox.Text)
	if interval and interval > 0 then
		runLengthLabel.Text = "Full run: " .. fmtDuration(interval * (Rewards.TotalRewards or 0))
	else
		runLengthLabel.Text = "Enter a number"
	end
end

simulateBtn.MouseButton1Click:Connect(function()
	resetState(tonumber(seedBox.Text))
	local count = math.clamp(math.floor(tonumber(rollsBox.Text) or 0), 0, MAX_ROLLS)
	rollsBox.Text = tostring(count)
	for _ = 1, count do
		rollOnce()
	end
	render()
end)

stepBtn.MouseButton1Click:Connect(function()
	rollOnce()
	render()
end)

resetBtn.MouseButton1Click:Connect(function()
	resetState(tonumber(seedBox.Text))
	render()
end)

capBtn.MouseButton1Click:Connect(function()
	rerollOnCap = not rerollOnCap
	capBtn.Text = rerollOnCap and "On limit: reroll" or "On limit: skip"
	render()
end)

intervalBox:GetPropertyChangedSignal("Text"):Connect(updateRunLength)

resetState()
updateRunLength()
render()
