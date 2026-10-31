-- LoadingGui: animated loading screen for the client bootstrap.
--
-- Put this in ReplicatedFirst as a LocalScript. The bootstrap waits (up to 30s)
-- for a "LoadingGui" in PlayerGui to disappear before it starts the deferred
-- controllers, so this GUI is named "LoadingGui" and destroys itself once
-- ReplicatedFirst's "ClientReady" attribute is set and the game has loaded.
--
-- ModuleLoader exposes no progress signal, so the bar follows an estimated curve
-- that eases toward ~92% and snaps to 100% on ClientReady. To drive it with real
-- numbers instead, set these from the bootstrap:
--   ReplicatedFirst:SetAttribute("BootProgress", 0.4) -- 0..1
--   ReplicatedFirst:SetAttribute("BootStatus", "Loading Clans...")

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CONFIG = {
	Title = string.upper(game.Name),
	MinDisplayTime = 2.5, -- never flash by faster than this (seconds)
	GiveUpAfter = 75, -- dismiss even if ClientReady never fires (bootstrap forces it at 60s)
	SlowAfter = 40, -- show the "taking longer" message after this long
	ParticleCount = 30,
	Tips = {
		"Roll auras to hunt for the rare ones.",
		"Join a clan to earn bonus rewards with friends.",
		"Check the Index to track your collection.",
		"Playtime rewards add up - stay a while!",
		"Trade with other players to complete your set.",
		"Spend skill points wisely - every branch counts.",
	},
}

local COLORS = {
	BgTop = Color3.fromHex("0B1020"),
	BgBottom = Color3.fromHex("22093A"),
	Cyan = Color3.fromHex("22D3EE"),
	Violet = Color3.fromHex("8B5CF6"),
	Pink = Color3.fromHex("F472B6"),
	Track = Color3.fromHex("141B33"),
	TrackStroke = Color3.fromHex("2A3560"),
	TextDim = Color3.fromHex("8E9AC0"),
	TextOff = Color3.fromHex("4A5578"),
	White = Color3.new(1, 1, 1),
}

local ACCENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, COLORS.Cyan),
	ColorSequenceKeypoint.new(0.5, COLORS.Violet),
	ColorSequenceKeypoint.new(1, COLORS.Pink),
})

local STEPS = {
	{ "NETWORK", 0.04 },
	{ "SYSTEMS", 0.30 },
	{ "SYNC", 0.70 },
	{ "READY", 1 },
}

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Sets props first and parents last so nothing replicates half-built.
local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

---------------------------------------------------------------- build the GUI

local gui = new("ScreenGui", {
	Name = "LoadingGui",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 1000,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, nil)

-- CanvasGroup so the whole screen fades out as one piece.
local root = new("CanvasGroup", {
	Name = "Root",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	GroupTransparency = 0,
}, gui)

-- The gradient lives on its own frame: a UIGradient on a CanvasGroup would tint
-- everything inside it.
local backdrop = new("Frame", {
	Name = "Backdrop",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = COLORS.White,
	BorderSizePixel = 0,
	ZIndex = 1,
}, root)
local backdropGradient = new("UIGradient", {
	Color = ColorSequence.new(COLORS.BgTop, COLORS.BgBottom),
	Rotation = 45,
}, backdrop)

local particleLayer = new("Frame", {
	Name = "Particles",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	ZIndex = 2,
}, root)

local particles = {}
local particleColors = { COLORS.Cyan, COLORS.Violet, COLORS.Pink }
for i = 1, CONFIG.ParticleCount do
	local size = math.random(3, 10)
	local dot = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = particleColors[math.random(#particleColors)],
		BackgroundTransparency = 0.55 + math.random() * 0.35,
		BorderSizePixel = 0,
	}, particleLayer)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
	particles[i] = {
		dot = dot,
		x = math.random(),
		offset = math.random() * 1.2,
		speed = 0.015 + math.random() * 0.04,
		phase = math.random() * math.pi * 2,
		sway = 0.01 + math.random() * 0.02,
	}
end

local card = new("Frame", {
	Name = "Card",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.47),
	Size = UDim2.fromOffset(480, 246),
	BackgroundTransparency = 1,
	ZIndex = 3,
}, root)
local cardScale = new("UIScale", {}, card)

-- Spinner: dim full ring, a sweeping gradient stroke over it, a pulsing core.
local ringTrack = new("Frame", {
	Name = "RingTrack",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 0),
	Size = UDim2.fromOffset(84, 84),
	BackgroundTransparency = 1,
}, card)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, ringTrack)
new("UIStroke", { Thickness = 4, Color = COLORS.TrackStroke, Transparency = 0.4 }, ringTrack)

local ring = new("Frame", {
	Name = "Ring",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 0),
	Size = UDim2.fromOffset(84, 84),
	BackgroundTransparency = 1,
}, card)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
local ringStroke = new("UIStroke", { Thickness = 4, Color = COLORS.White }, ring)
local ringGradient = new("UIGradient", {
	Color = ACCENT,
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	}),
}, ringStroke)

local core = new("Frame", {
	Name = "Core",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.44, 0.44),
	BackgroundColor3 = COLORS.White,
	BorderSizePixel = 0,
}, ring)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, core)
new("UIGradient", { Color = ACCENT, Rotation = 45 }, core)
new("UIStroke", { Thickness = 3, Color = COLORS.Cyan, Transparency = 0.7 }, core)

local title = new("TextLabel", {
	Name = "Title",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 100),
	Size = UDim2.new(1, 0, 0, 46),
	Font = Enum.Font.GothamBlack,
	Text = CONFIG.Title,
	TextColor3 = COLORS.White,
	TextScaled = true,
}, card)
new("UITextSizeConstraint", { MaxTextSize = 40 }, title)
local titleGradient = new("UIGradient", { Color = ACCENT }, title)

local status = new("TextLabel", {
	Name = "Status",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 160),
	Size = UDim2.new(0.75, 0, 0, 20),
	Font = Enum.Font.GothamMedium,
	Text = "Starting up...",
	TextColor3 = COLORS.TextDim,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
}, card)

local percent = new("TextLabel", {
	Name = "Percent",
	AnchorPoint = Vector2.new(1, 0),
	BackgroundTransparency = 1,
	Position = UDim2.new(1, 0, 0, 160),
	Size = UDim2.new(0.25, 0, 0, 20),
	Font = Enum.Font.GothamBold,
	Text = "0%",
	TextColor3 = COLORS.White,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Right,
}, card)

local track = new("Frame", {
	Name = "Track",
	Position = UDim2.fromOffset(0, 188),
	Size = UDim2.new(1, 0, 0, 12),
	BackgroundColor3 = COLORS.Track,
	BorderSizePixel = 0,
}, card)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
new("UIStroke", { Thickness = 1, Color = COLORS.TrackStroke }, track)

local fill = new("Frame", {
	Name = "Fill",
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = COLORS.White,
	BorderSizePixel = 0,
}, track)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
local fillGradient = new("UIGradient", { Color = ACCENT }, fill)
new("UIStroke", { Thickness = 2, Color = COLORS.Cyan, Transparency = 0.6 }, fill)

local stepLabels = {}
for i, step in STEPS do
	stepLabels[i] = new("TextLabel", {
		Name = "Step" .. i,
		BackgroundTransparency = 1,
		Position = UDim2.new((i - 1) / #STEPS, 0, 0, 212),
		Size = UDim2.new(1 / #STEPS, 0, 0, 16),
		Font = Enum.Font.GothamBold,
		Text = step[1],
		TextColor3 = COLORS.TextOff,
		TextSize = 11,
	}, card)
end

local tip = new("TextLabel", {
	Name = "Tip",
	AnchorPoint = Vector2.new(0.5, 1),
	BackgroundTransparency = 1,
	Position = UDim2.new(0.5, 0, 1, -36),
	Size = UDim2.new(0.9, 0, 0, 20),
	Font = Enum.Font.GothamMedium,
	Text = "",
	TextColor3 = COLORS.TextDim,
	TextSize = 14,
	TextTransparency = 1,
	ZIndex = 3,
}, root)

-- Scale the card to fit small screens / phones.
local function updateScale()
	local size = root.AbsoluteSize
	if size.X > 0 and size.Y > 0 then
		cardScale.Scale = math.clamp(math.min(size.X / 640, size.Y / 480), 0.55, 1.3)
	end
end
root:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)

gui.Parent = playerGui
updateScale()

----------------------------------------------------------------------- logic

local ready = ReplicatedFirst:GetAttribute("ClientReady") == true
ReplicatedFirst:GetAttributeChangedSignal("ClientReady"):Connect(function()
	ready = ReplicatedFirst:GetAttribute("ClientReady") == true
end)

local startClock = os.clock()
local shown = 0
local finishing = false
local stepLit = {}
local lastStatus = ""

local function setStatus(text: string)
	if text ~= lastStatus then
		lastStatus = text
		status.Text = text
	end
end

local function statusFor(progress: number, elapsed: number): string
	local custom = ReplicatedFirst:GetAttribute("BootStatus")
	if type(custom) == "string" and custom ~= "" then
		return custom
	end
	if elapsed > CONFIG.SlowAfter then
		return "Taking longer than usual, hang tight..."
	elseif progress < 0.15 then
		return "Connecting to the server..."
	elseif progress < 0.5 then
		return "Loading game systems..."
	elseif progress < 0.85 then
		return "Syncing your data..."
	end
	return "Almost there..."
end

local heartbeat
local function finish()
	finishing = true
	setStatus("Ready!")
	percent.Text = "100%"
	task.spawn(function()
		task.wait(0.35)
		local tween = TweenService:Create(root, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			GroupTransparency = 1,
		})
		tween:Play()
		tween.Completed:Wait()
		gui:Destroy()
	end)
end

heartbeat = RunService.Heartbeat:Connect(function(dt)
	local elapsed = os.clock() - startClock

	-- Ambient animation keeps running through the fade-out.
	ringGradient.Rotation = (elapsed * 270) % 360
	core.Size = UDim2.fromScale(0.44 + 0.04 * math.sin(elapsed * 3), 0.44 + 0.04 * math.sin(elapsed * 3))
	titleGradient.Offset = Vector2.new(math.sin(elapsed * 0.9) * 0.3, 0)
	fillGradient.Offset = Vector2.new(math.sin(elapsed * 1.4) * 0.25, 0)
	backdropGradient.Rotation = 45 + math.sin(elapsed * 0.25) * 25
	for _, p in particles do
		local y = 1.1 - ((p.offset + p.speed * elapsed) % 1.2)
		local x = p.x + math.sin(elapsed * 0.8 + p.phase) * p.sway
		p.dot.Position = UDim2.fromScale(x, y)
	end

	if finishing then
		return
	end

	-- Progress: real value if the bootstrap provides one, else an eased estimate.
	local forced = ready or elapsed > CONFIG.GiveUpAfter
	local explicit = ReplicatedFirst:GetAttribute("BootProgress")
	local target
	if forced then
		target = 1
	elseif type(explicit) == "number" then
		target = math.clamp(explicit, 0, 0.98)
	else
		target = 0.92 * (1 - math.exp(-elapsed / 7))
	end
	if target > shown then
		shown += (target - shown) * (1 - math.exp(-dt * 5))
	end

	fill.Size = UDim2.fromScale(shown, 1)
	percent.Text = string.format("%d%%", math.floor(shown * 100 + 0.5))
	setStatus(statusFor(shown, elapsed))

	for i, step in STEPS do
		if not stepLit[i] and shown >= step[2] - 0.005 then
			stepLit[i] = true
			TweenService:Create(stepLabels[i], TweenInfo.new(0.3), { TextColor3 = COLORS.Cyan }):Play()
		end
	end

	if shown >= 0.995 and elapsed >= CONFIG.MinDisplayTime and game:IsLoaded() then
		finish()
	end
end)

gui.Destroying:Connect(function()
	heartbeat:Disconnect()
end)

-- Rotating tips.
task.spawn(function()
	local index = math.random(#CONFIG.Tips)
	while gui.Parent do
		tip.Text = "TIP  |  " .. CONFIG.Tips[index]
		TweenService:Create(tip, TweenInfo.new(0.4), { TextTransparency = 0.2 }):Play()
		task.wait(3.6)
		TweenService:Create(tip, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		task.wait(0.4)
		index = index % #CONFIG.Tips + 1
	end
end)
