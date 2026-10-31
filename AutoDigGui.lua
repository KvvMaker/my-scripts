-- AutoDigGui: LocalScript (e.g. StarterPlayerScripts). Needs the Digging script to be running,
-- since it provides shared.startAutoDig / shared.stopAutoDig.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

if PlayerGui:FindFirstChild("AutoDigGui") then
	PlayerGui.AutoDigGui:Destroy()
end

local ON_COLOR = Color3.fromRGB(60, 200, 110)
local OFF_COLOR = Color3.fromRGB(200, 70, 70)

local gui = Instance.new("ScreenGui")
gui.Name = "AutoDigGui"
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(200, 165)
frame.Position = UDim2.new(0, 20, 0.5, -82)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(70, 70, 85)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "Auto Dig"
title.Parent = frame

local button = Instance.new("TextButton")
button.Size = UDim2.new(1, -24, 0, 36)
button.Position = UDim2.fromOffset(12, 36)
button.BackgroundColor3 = OFF_COLOR
button.Font = Enum.Font.GothamBold
button.TextSize = 15
button.TextColor3 = Color3.new(1, 1, 1)
button.AutoButtonColor = true
button.Text = "Dig: OFF"
button.Parent = frame
Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)

local collectButton = button:Clone()
collectButton.Position = UDim2.fromOffset(12, 80)
collectButton.Text = "Collect: OFF"
collectButton.Parent = frame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 20)
status.Position = UDim2.fromOffset(12, 130)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextColor3 = Color3.fromRGB(170, 170, 180)
status.Text = "Idle"
status.Parent = frame

local enabled = false

local function render(on, msg)
	enabled = on
	button.Text = on and "Dig: ON" or "Dig: OFF"
	status.Text = msg or (on and "Digging nearby drops..." or "Idle")
	TweenService:Create(button, TweenInfo.new(0.15), { BackgroundColor3 = on and ON_COLOR or OFF_COLOR }):Play()
end

local function toggle()
	if enabled then
		if shared.stopAutoDig then
			shared.stopAutoDig()
		end
		render(false)
		return
	end

	if not shared.startAutoDig then
		render(false, "Dig script not loaded")
		return
	end
	local ok, started = pcall(shared.startAutoDig)
	if ok and started then
		render(true)
	else
		render(false, "Auto dig unavailable")
	end
end

button.Activated:Connect(toggle)

-- Auto collect: walks the character to the nearest loose orb. The game's own magnet
-- (Orbs script) then picks it up, so no remotes are fired from here.
local Orbs = workspace:WaitForChild("Scripted"):WaitForChild("Orbs")
local SEARCH_RADIUS = 80 -- studs
local collecting = false

local function nearestOrb(root)
	local best, bestDist = nil, SEARCH_RADIUS
	for _, orb in ipairs(Orbs:GetChildren()) do
		-- Anchored orbs are already flying to the player (magnify phase).
		if orb:IsA("BasePart") and not orb.Anchored then
			local d = (orb.Position - root.Position).Magnitude
			if d < bestDist then
				best, bestDist = orb, d
			end
		end
	end
	return best, bestDist
end

local function setCollecting(on)
	collecting = on
	collectButton.Text = on and "Collect: ON" or "Collect: OFF"
	TweenService:Create(collectButton, TweenInfo.new(0.15), { BackgroundColor3 = on and ON_COLOR or OFF_COLOR }):Play()
	if not on then
		return
	end
	task.spawn(function()
		while collecting and gui.Parent do
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if root and hum then
				local orb, dist = nearestOrb(root)
				if orb and dist > 6 then
					hum:MoveTo(orb.Position)
				end
			end
			task.wait(0.2)
		end
	end)
end

collectButton.Activated:Connect(function()
	setCollecting(not collecting)
end)

-- Keep the GUI in sync when the game stops auto dig itself (e.g. DeleteDrops on world change).
task.spawn(function()
	while gui.Parent do
		task.wait(0.5)
		-- stopAutoDig is wrapped below; this loop only guards against a missing wrapper.
	end
end)

local origStop = shared.stopAutoDig
if origStop then
	shared.stopAutoDig = function(...)
		local result = origStop(...)
		if enabled then
			render(false)
		end
		return result
	end
end

-- Dragging
local dragging, dragStart, startPos
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, frame.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)
