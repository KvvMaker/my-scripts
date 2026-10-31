--// Dig Auto Farm GUI
--// Teleports you to drops, hits them through the game's own click handler (or its built-in
--// Auto-Dig), then lingers so the orbs get picked up. Everything goes through the game's own
--// client code, so drops/orbs/currency are processed exactly like a normal click.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local env = (getgenv and getgenv()) or _G
if env.__DigAutoFarm then
	pcall(env.__DigAutoFarm) -- re-execute = clean reload
end

local LocalPlayer = Players.LocalPlayer
local Scripted = workspace:WaitForChild("Scripted")
local DropsFolder = Scripted:WaitForChild("Drops")
local Active = DropsFolder:WaitForChild("Active")
local BossActive = DropsFolder:WaitForChild("BossActive")
local Orbs = Scripted:WaitForChild("Orbs")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DeleteDrops = Remotes:WaitForChild("Events"):WaitForChild("DeleteDrops")
local GetMultis = Remotes:WaitForChild("Funcs"):WaitForChild("GetMultis")

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local settings = {
	farm = false,        -- master switch
	teleport = true,     -- move to the nearest drop / orbs
	clickDrops = true,   -- fire the drop's ClickDetector (same path as a real click)
	gameAutoDig = false, -- also turn on the game's own Auto-Dig
	bosses = true,       -- include boss drops
	antiAfk = true,
	orbSweep = true,     -- hop to settled orbs instead of standing around waiting for them
	clickDelay = 0.26,   -- seconds between clicks (overwritten from the game's own click speed below)
	hoverHeight = 2,
	stayRange = 12,      -- only re-teleport if we're further than this from the target
	minAge = 0,          -- 1.6 = wait for drops to finish rising before hitting them
	magnetRange = 14,    -- game base orb pickup range is 15 (upgrades add to it)
	orbMinAge = 1.4,     -- orbs need ~1.25s (jump + delay) before they can be picked up
}

local alive = true
local conns = {}
local current = nil      -- { model, part, boss, dist, ready }
local autoDigOn = false
local stats = { farmed = 0 }
local seen = setmetatable({}, { __mode = "k" })
local gui, statusLabel

local function connect(signal, fn)
	local c = signal:Connect(fn)
	conns[#conns + 1] = c
	return c
end

local function setStatus(text)
	if statusLabel and statusLabel.Text ~= text then
		statusLabel.Text = text
	end
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- The game's auto-dig waits autoClickSpeed * 2 between hits, so a real click is allowed twice as
-- often. Start at autoClickSpeed (+ a hair for network jitter); lower it in the GUI to test limits.
pcall(function()
	local m = GetMultis:InvokeServer("Clicks")
	if m and m.autoClickSpeed then
		settings.clickDelay = math.max(0.05, m.autoClickSpeed + 0.01)
	end
end)

--------------------------------------------------------------------------------
-- Drop / orb helpers
--------------------------------------------------------------------------------
for _, folder in { Active, BossActive } do
	for _, m in folder:GetChildren() do
		seen[m] = os.clock() - 10
	end
	connect(folder.ChildAdded, function(m)
		seen[m] = os.clock()
	end)
end

local orbSeen = setmetatable({}, { __mode = "k" })
local orbHops = setmetatable({}, { __mode = "k" })
for _, orb in Orbs:GetChildren() do
	orbSeen[orb] = os.clock() - 10
end
connect(Orbs.ChildAdded, function(orb)
	orbSeen[orb] = os.clock()
end)

local function dropPart(model)
	local hb = model:FindFirstChild("HitBox")
	if hb and hb:IsA("BasePart") then
		return hb
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function collectDrops()
	local list = {}
	local root = getRoot()
	if not root then
		return list
	end
	local function scan(folder, isBoss)
		for _, m in folder:GetChildren() do
			if m:IsA("Model") then
				local p = dropPart(m)
				if p then
					list[#list + 1] = {
						model = m,
						part = p,
						boss = isBoss,
						dist = (p.Position - root.Position).Magnitude,
						ready = os.clock() - (seen[m] or 0) >= settings.minAge,
					}
				end
			end
		end
	end
	scan(Active, false)
	if settings.bosses then
		scan(BossActive, true)
	end
	return list
end

local function pickTarget()
	local list = collectDrops()
	if #list == 0 then
		return nil
	end
	table.sort(list, function(a, b)
		if a.ready ~= b.ready then
			return a.ready
		end
		return a.dist < b.dist
	end)
	return list[1]
end

local function goTo(part)
	local root = getRoot()
	if not root then
		return
	end
	local up = math.min(part.Size.Y / 2, 3) + settings.hoverHeight
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(part.Position + Vector3.new(0, up, 0))
end

local function clickDrop(model)
	local hb = model:FindFirstChild("HitBox")
	local cd = hb and hb:FindFirstChildWhichIsA("ClickDetector")
	if not cd then
		return
	end
	if fireclickdetector then
		pcall(fireclickdetector, cd, 0)
	elseif firesignal then
		pcall(firesignal, cd.MouseClick, LocalPlayer)
	end
end

-- Orbs are only collectable once they've landed and settled (~1.25s after a kill). Instead of
-- standing around waiting, we keep hitting the next drop and only hop over to orbs that are
-- settled and out of pickup range. The game flags orbs it is already pulling in by anchoring them,
-- so anchored orbs are skipped. Once an orb starts flying to us we can leave straight away.
local function sweepOrbs(root)
	if not (settings.orbSweep and settings.teleport) then
		return
	end
	local now = os.clock()
	local floorY = workspace.FallenPartsDestroyHeight + 20
	local best, bestDist
	for _, orb in Orbs:GetChildren() do
		if orb:IsA("BasePart") and not orb.Anchored and orb.Position.Y > floorY
			and now - (orbSeen[orb] or 0) >= settings.orbMinAge
			and (orbHops[orb] or 0) < 2 then
			local d = (orb.Position - root.Position).Magnitude
			if d > settings.magnetRange and (not bestDist or d < bestDist) then
				best, bestDist = orb, d
			end
		end
	end
	if not best then
		return
	end

	orbHops[best] = (orbHops[best] or 0) + 1
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(best.Position + Vector3.new(0, 3, 0))

	-- brief hold until nearby settled orbs have been grabbed (they anchor when magnetised)
	local t0 = os.clock()
	while alive and os.clock() - t0 < 0.5 do
		task.wait()
		local r = getRoot()
		if not r then
			return
		end
		local waiting = false
		for _, orb in Orbs:GetChildren() do
			if orb:IsA("BasePart") and not orb.Anchored
				and os.clock() - (orbSeen[orb] or 0) >= settings.orbMinAge
				and (orb.Position - r.Position).Magnitude <= settings.magnetRange then
				waiting = true
				break
			end
		end
		if not waiting then
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Game Auto-Dig (the game's own feature, exposed through `shared`)
--------------------------------------------------------------------------------
local function applyAutoDig()
	local want = settings.farm and settings.gameAutoDig
	if want == autoDigOn then
		return
	end
	autoDigOn = want
	task.spawn(function()
		if want then
			if shared.startAutoDig then
				pcall(shared.startAutoDig)
			else
				setStatus("shared.startAutoDig not found")
			end
		elseif shared.stopAutoDig then
			pcall(shared.stopAutoDig)
		end
	end)
end

-- world change / DeleteDrops makes the game stop auto-dig; bring it back afterwards
connect(DeleteDrops.OnClientEvent, function()
	current = nil
	if autoDigOn then
		task.delay(2, function()
			if alive and autoDigOn and shared.startAutoDig then
				pcall(shared.startAutoDig)
			end
		end)
	end
end)

connect(LocalPlayer.Idled, function()
	if settings.antiAfk then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end)

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
task.spawn(function()
	local lastClick = 0
	while alive do
		if not settings.farm then
			current = nil
			task.wait(0.25)
		else
			local root = getRoot()
			if not root then
				setStatus("Waiting for character...")
				task.wait(0.5)
			else
				sweepOrbs(root)

				if current and not current.model.Parent then
					stats.farmed += 1
					current = nil
				end

				-- next target is picked in the same frame the last one dies
				if not current then
					current = pickTarget()
				end

				if not current then
					setStatus(("No drops - waiting  |  Farmed: %d"):format(stats.farmed))
					task.wait(0.1)
				else
					-- game auto-dig only works within 16 studs of the drop's base, so stay tighter
					local range = settings.gameAutoDig and 8 or settings.stayRange
					if settings.teleport and (root.Position - current.part.Position).Magnitude > range then
						goTo(current.part)
					end
					if settings.clickDrops and os.clock() - lastClick >= settings.clickDelay then
						lastClick = os.clock()
						clickDrop(current.model)
					end
					setStatus(("%s  |  Farmed: %d"):format(current.boss and "Hitting boss" or "Hitting drop", stats.farmed))
					task.wait() -- one frame
				end
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------
local COLOR_BG = Color3.fromRGB(24, 24, 31)
local COLOR_BAR = Color3.fromRGB(34, 34, 44)
local COLOR_ON = Color3.fromRGB(60, 160, 100)
local COLOR_OFF = Color3.fromRGB(52, 52, 64)

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = inst
end

gui = Instance.new("ScreenGui")
gui.Name = "DigAutoFarm"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
if not pcall(function() gui.Parent = guiParent end) then
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(250, 0)
main.AutomaticSize = Enum.AutomaticSize.Y
main.Position = UDim2.fromOffset(20, 120)
main.BackgroundColor3 = COLOR_BG
main.BorderSizePixel = 0
main.Parent = gui
corner(main, 8)

local mainLayout = Instance.new("UIListLayout")
mainLayout.SortOrder = Enum.SortOrder.LayoutOrder
mainLayout.Parent = main

local title = Instance.new("Frame")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = COLOR_BAR
title.BorderSizePixel = 0
title.LayoutOrder = 0
title.Parent = main
corner(title, 8)

local titleText = Instance.new("TextLabel")
titleText.Size = UDim2.new(1, -70, 1, 0)
titleText.Position = UDim2.fromOffset(10, 0)
titleText.BackgroundTransparency = 1
titleText.Text = "Dig Auto Farm"
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.TextColor3 = Color3.new(1, 1, 1)
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 14
titleText.Parent = title

local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 0, 0)
content.AutomaticSize = Enum.AutomaticSize.Y
content.BackgroundTransparency = 1
content.LayoutOrder = 1
content.Parent = main

local pad = Instance.new("UIPadding")
pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
pad.Parent = content

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 6)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = content

local function titleButton(text, xOffset, color, onClick)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(24, 20)
	b.Position = UDim2.new(1, xOffset, 0, 5)
	b.BackgroundColor3 = color
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.AutoButtonColor = true
	b.Parent = title
	corner(b, 4)
	b.MouseButton1Click:Connect(onClick)
	return b
end

local function cleanup()
	alive = false
	settings.farm = false
	for _, c in conns do
		pcall(function() c:Disconnect() end)
	end
	if autoDigOn and shared.stopAutoDig then
		task.spawn(pcall, shared.stopAutoDig)
	end
	autoDigOn = false
	if gui then
		gui:Destroy()
	end
	env.__DigAutoFarm = nil
end
env.__DigAutoFarm = cleanup

titleButton("-", -56, COLOR_OFF, function()
	content.Visible = not content.Visible
end)
titleButton("X", -28, Color3.fromRGB(170, 60, 60), cleanup)

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function makeToggle(label, key, onChange)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 28)
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = 13
	btn.AutoButtonColor = false
	btn.LayoutOrder = nextOrder()
	btn.Parent = content
	corner(btn)
	local function refresh()
		local on = settings[key]
		btn.Text = label .. ": " .. (on and "ON" or "OFF")
		btn.BackgroundColor3 = on and COLOR_ON or COLOR_OFF
	end
	refresh()
	btn.MouseButton1Click:Connect(function()
		settings[key] = not settings[key]
		refresh()
		if onChange then
			onChange(settings[key])
		end
	end)
end

local function makeInput(label, key, min, max)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 26)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = content

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -70, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = Color3.fromRGB(210, 210, 220)
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.Parent = row

	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(62, 26)
	box.Position = UDim2.new(1, -62, 0, 0)
	box.BackgroundColor3 = COLOR_BAR
	box.TextColor3 = Color3.new(1, 1, 1)
	box.Font = Enum.Font.Gotham
	box.TextSize = 13
	box.ClearTextOnFocus = false
	box.Text = tostring(math.floor(settings[key] * 100 + 0.5) / 100)
	box.Parent = row
	corner(box, 4)

	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			settings[key] = math.clamp(n, min, max)
		end
		box.Text = tostring(math.floor(settings[key] * 100 + 0.5) / 100)
	end)
end

makeToggle("Auto Farm", "farm", function(on)
	if not on then
		current = nil
	end
	applyAutoDig()
end)
makeToggle("Teleport to drops", "teleport")
makeToggle("Click drops", "clickDrops")
makeToggle("Game Auto-Dig", "gameAutoDig", applyAutoDig)
makeToggle("Include bosses", "bosses")
makeToggle("Anti-AFK", "antiAfk")
makeToggle("Fast orb sweep", "orbSweep")
makeInput("Click delay (s)", "clickDelay", 0.02, 5)

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 32)
statusLabel.BackgroundTransparency = 1
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.TextColor3 = Color3.fromRGB(160, 170, 190)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.Text = "Idle  |  RightShift = hide GUI"
statusLabel.LayoutOrder = nextOrder()
statusLabel.Parent = content

-- drag by title bar
local dragging, dragStart, startPos
connect(title.InputBegan, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, main.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)
connect(UserInputService.InputChanged, function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)
connect(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)
