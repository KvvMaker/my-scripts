--[[
	CrazyBeat  -  16-step, 4-page beat sequencer (140 BPM)

	Setup (your own place, in Roblox Studio):
	  1. Put this in StarterPlayer > StarterPlayerScripts as a LocalScript.
	  2. Fill in the SAMPLES table below with audio you uploaded
	     (Creator Dashboard > Audio, or the Toolbox) as "rbxassetid://123456".
	     Tracks left empty are skipped with a warning.
	  3. Play. It starts on its own; press B to stop / restart.

	Pattern legend:  x = hit,  o = soft ghost hit,  . = empty   (steps 1..16)
	Bass notes are { step, semitones above F1 }; the 808 sample is pitched with
	PlaybackSpeed, so BASS_SAMPLE_SEMI should be the note your 808 sample is tuned to.
]]

local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

------------------------------------------------------------------ config
local BPM = 140
local LOOP = true
local MASTER_VOLUME = 0.8
local BARS_PER_PAGE = 2
local TOGGLE_KEY = Enum.KeyCode.B

local SAMPLES = {
	Kick = "",
	Snare = "",
	Clap = "",
	ClosedHat = "",
	OpenHat = "",
	Perc = "",
	Bass808 = "",
	Crash = "",
	Riser = "", -- ideally about one bar long (1.7 s at 140 BPM)
}

local BASS_SAMPLE_SEMI = 0 -- 0 = your 808 sample is tuned to F (F1). Change if it isn't.

local VOLUME = {
	Kick = 1.0,
	Snare = 0.8,
	Clap = 0.55,
	ClosedHat = 0.55,
	OpenHat = 0.45,
	Perc = 0.5,
	Bass808 = 0.6,
	Crash = 0.7,
	Riser = 0.55,
}

local DUCK_AMOUNT = 0.75 -- 808 dips by this much on every kick (fake sidechain)
local DUCK_TIME = 0.07

------------------------------------------------------------------ the beat
local PAGES = {
	{
		name = "GROOVE",
		crash = true,
		kick = "x..x..x...x..x..",
		snare = "........x.......",
		clap = "........x.......",
		hat = "x.o.x.o.x.o.x.o.",
		ohat = "......x.......x.",
		perc = "..........o...x.",
		bass = { { 1, 0 }, { 4, 0 }, { 7, 3 }, { 11, -2 }, { 14, 0 } },
	},
	{
		name = "BUILD",
		riser = true,
		kick = "x..x..x.x..x..x.",
		snare = "........x.x.xxxx",
		clap = "........x.......",
		hat = "xoxoxoxoxxxxxxxx",
		ohat = ".......x........",
		perc = "..x...x...x...x.",
		bass = { { 1, 0 }, { 3, 0 }, { 7, 5 }, { 9, 3 }, { 13, -2 } },
	},
	{
		name = "DROP",
		crash = true,
		kick = "x.x...x.x..x.x..",
		snare = "....x.......x..o",
		clap = "....x.......x...",
		hat = "xxoxxxoxxxoxxxxx",
		ohat = "..x.......x.....",
		perc = "x..x..x..x..x...",
		bass = { { 1, 0 }, { 2, 0 }, { 5, 3 }, { 8, 5 }, { 9, 7 }, { 11, 3 }, { 13, 0 }, { 15, -2 } },
	},
	{
		name = "GLITCH",
		kick = "x...x...x...x.xx",
		snare = "..x...x...x.xxxx",
		clap = "..x...x...x.xxxx",
		hat = "xxxxxxxxxxxxxxxx",
		ohat = "................",
		perc = "o.o.o.o.o.o.xxxx",
		bass = { { 1, 12 }, { 3, 12 }, { 5, 10 }, { 7, 8 }, { 9, 7 }, { 11, 3 }, { 13, 0 }, { 15, 0 } },
	},
}

-- pattern row -> sample name
local ROWS = {
	{ "kick", "Kick" },
	{ "snare", "Snare" },
	{ "clap", "Clap" },
	{ "hat", "ClosedHat" },
	{ "ohat", "OpenHat" },
	{ "perc", "Perc" },
}

local VELOCITY = { x = 1, o = 0.42 }

------------------------------------------------------------------ sample pools
local STEP_SECONDS = 60 / BPM / 4
local STEPS_PER_BAR = 16
local TOTAL_STEPS = #PAGES * BARS_PER_PAGE * STEPS_PER_BAR

local folder = Instance.new("Folder")
folder.Name = "CrazyBeat"
folder.Parent = SoundService

-- round-robin pool per sample so overlapping hits don't cut each other off
local pools = {}
local toPreload = {}

for name, id in SAMPLES do
	if id == "" then
		warn(`[CrazyBeat] no sample set for {name}; that track will be silent`)
	else
		local size = if name == "Bass808" then 1 else 4
		local pool = { sounds = {}, nextIndex = 1 }
		for i = 1, size do
			local s = Instance.new("Sound")
			s.Name = `{name}{i}`
			s.SoundId = id
			s.Parent = folder
			pool.sounds[i] = s
			table.insert(toPreload, s)
		end
		pools[name] = pool
	end
end

for _, page in PAGES do
	page.bassMap = {}
	for _, note in page.bass do
		page.bassMap[note[1]] = note[2]
	end
end

local function trigger(name: string, velocity: number, speed: number?)
	local pool = pools[name]
	if not pool then
		return
	end
	local s = pool.sounds[pool.nextIndex]
	pool.nextIndex = pool.nextIndex % #pool.sounds + 1
	s.PlaybackSpeed = speed or 1
	s.Volume = VOLUME[name] * velocity * MASTER_VOLUME
	s.TimePosition = 0
	s:Play()
end

------------------------------------------------------------------ sequencer
local playing = false
local connection: RBXScriptConnection? = nil
local nextStepTime = 0
local stepCounter = 0
local lastKickTime = -math.huge
local bassBaseVolume = VOLUME.Bass808 * MASTER_VOLUME

local function playStep(globalStep: number)
	local index = globalStep % TOTAL_STEPS
	local bar = index // STEPS_PER_BAR
	local step = index % STEPS_PER_BAR + 1
	local page = PAGES[bar // BARS_PER_PAGE + 1]
	local barInPage = bar % BARS_PER_PAGE

	for _, row in ROWS do
		local velocity = VELOCITY[string.sub(page[row[1]], step, step)]
		if velocity then
			trigger(row[2], velocity)
			if row[1] == "kick" then
				lastKickTime = os.clock()
			end
		end
	end

	local semi = page.bassMap[step]
	if semi then
		local pool = pools.Bass808
		if pool then
			pool.sounds[1]:Stop() -- 808 is monophonic: a new note cuts the old one
		end
		bassBaseVolume = VOLUME.Bass808 * MASTER_VOLUME
		trigger("Bass808", 1, 2 ^ ((semi - BASS_SAMPLE_SEMI) / 12))
	end

	if step == 1 then
		if page.crash and barInPage == 0 then
			trigger("Crash", 1)
		end
		if page.riser and barInPage == BARS_PER_PAGE - 1 then
			trigger("Riser", 1)
		end
	end
end

local function stop()
	playing = false
	if connection then
		connection:Disconnect()
		connection = nil
	end
	for _, s in folder:GetChildren() do
		(s :: Sound):Stop()
	end
end

local function start()
	if playing then
		return
	end
	playing = true
	stepCounter = 0
	nextStepTime = os.clock() + 0.1

	connection = RunService.Heartbeat:Connect(function()
		-- fire every step whose time has come; scheduling is absolute so it can't drift
		while playing and os.clock() >= nextStepTime do
			if not LOOP and stepCounter >= TOTAL_STEPS then
				stop()
				return
			end
			playStep(stepCounter)
			stepCounter += 1
			nextStepTime += STEP_SECONDS
		end

		if os.clock() - nextStepTime > 0.5 then
			nextStepTime = os.clock() -- we fell far behind (lag spike): resync instead of machine-gunning
		end

		-- fake sidechain: duck the 808 right after each kick
		local pool = pools.Bass808
		if pool and pool.sounds[1].IsPlaying then
			local since = os.clock() - lastKickTime
			pool.sounds[1].Volume = bassBaseVolume * (1 - DUCK_AMOUNT * math.exp(-since / DUCK_TIME))
		end
	end)
end

------------------------------------------------------------------ boot
task.spawn(function()
	if #toPreload > 0 then
		ContentProvider:PreloadAsync(toPreload)
	end
	start()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or input.KeyCode ~= TOGGLE_KEY then
		return
	end
	if playing then
		stop()
	else
		start()
	end
end)
