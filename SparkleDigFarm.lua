--// Sparkle Dig Farm: digs the sparkle spots, picks the treasure up, stows it on your ship and fights off enemies (executor LocalScript)
--// Digs through the game's own DigController, stows with the same Treasure_Store call the G key makes and swings through
--// the game's own WeaponController, so everything still goes through the normal server checks.
--// RightShift hides/shows the window. Re-executing replaces the previous copy.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local SPOT_TAG = "SparkleSpot" -- DigController hints and hides the spots by this tag
local DIG_COOLDOWN = 1.5 -- DigController.Dig refuses a second dig for this long
local DIG_REACH = 3 -- Dig() puts the hole this many studs in front of the character
local SETTLE = 0.35 -- the server gets this long to see us at the spot before the dig goes out
local RESULT_WAIT = 2.5 -- how long to wait for Dig_Result before a dig counts as unanswered
local MAX_TRIES = 2 -- digs at a spot that is still there afterwards, before it is left alone for a while
local SPOT_REST = 20 -- seconds a spot is left alone after that
local PICKUP_RADIUS = 40 -- a treasure this close to the spot we just dug counts as ours
local PICKUP_APPEAR = 6 -- seconds to wait for that treasure to show up
local BOARD_WAIT = 4 -- seconds to wait for the game to say we're aboard
local STORE_DELAY = 1.3 -- CarryController only unlocks Store 0.9s after boarding
local STORE_TRIES = 3
local SHIP_REST = 30 -- seconds a ship that refused the treasure is left alone
local ENEMY_TAGS = { "Damageable", "Enemy", "Boss" } -- WeaponController's aim assist treats things with these tags as targets
local MELEE_SLACK = 2 -- studs past a melee weapon's Range an enemy may stand and still be swung at (the game's own assist allows 4)
local SWING_MARGIN = 0.02 -- seconds added to the weapon's cooldown, so the server never sees a swing early
local NO_HIT_LIMIT = 6 -- seconds of swinging without one confirmed hit before an enemy is given up on
local ENGAGE_LIMIT = 25 -- the same when the game's hit confirmations can't be seen
local ENGAGE_CAP = 120 -- seconds on one enemy, hits or not (a training dummy never dies)
local CHASE_LIMIT = 15 -- seconds to get within reach of an enemy being chased
local ENEMY_REST = 45 -- seconds an enemy we gave up on is left alone
local WEAPON_WAIT = 1.5 -- seconds for a drawn weapon to become usable
local FIGHT_PAUSE = 8 -- seconds without fighting after a weapon couldn't be drawn
local CHASE_GAP = 0.6 -- a chased enemy is approached to this fraction of the weapon's range

--// environment -----------------------------------------------------------------

local env = (getgenv and getgenv()) or _G
if env.__DigFarmUnload then
	pcall(env.__DigFarmUnload)
end

-- require()-ing a game module can drop this thread's identity, after which it can't touch the window
-- ("lacking capability Plugin"). Remember the starting identity and put it back after game calls.
local getIdentity = getthreadidentity or getidentity or get_thread_identity
local setIdentity = setthreadidentity or setidentity or set_thread_identity
local startIdentity = getIdentity and getIdentity()
local function restoreIdentity()
	if setIdentity and startIdentity then
		pcall(setIdentity, startIdentity)
	end
end

local alive = true
local connections = {}

local function connect(signal, fn)
	local connection = signal:Connect(function(...)
		restoreIdentity()
		return fn(...)
	end)
	table.insert(connections, connection)
	return connection
end

local function round(n)
	return math.floor(n + 0.5)
end

--// state -----------------------------------------------------------------------
-- Plain values only. The farm thread writes them, the window loop reads them.

local State = {
	enabled = false,
	dig = true,
	carry = true,
	attack = true,
	ability = true,
	chase = false,
	chaseRadius = 50, -- studs; while chasing, enemies further away than this are left alone
	weaponSlot = "Melee", -- the slot drawn first when a fight starts: "Melee" or "Ranged"
	antiAfk = true,
	smooth = true,
	speed = 80, -- studs per second while gliding
	status = "Idle",
	statusKind = "idle",
	request = nil, -- "goto" (nearest spot) or "ship" from the window; the farm thread does the moving
	spotCount = 0,
	readyCount = 0,
	nearest = nil,
	shovel = "?",
	carrying = nil,
	site = nil, -- { pos, at }: where a treasure was just dug up, until it is in our hands
	shipId = nil, -- the N of Ship_N, saved with "Use the ship I'm on"
	shipText = "auto-detect",
	cargo = "-",
	weapon = "?",
	target = "none",
	digs = 0,
	treasure = 0,
	junk = 0,
	nothing = 0,
	warm = 0,
	invalid = 0,
	stored = 0,
	swings = 0,
	abilities = 0,
	hits = 0, -- hit confirmations the server sent back
	kills = 0,
	runTotal = 0,
	runStart = nil,
	log = {},
	logVersion = 0,
}

local function log(text, kind)
	table.insert(State.log, { text = text, kind = kind or "dim" })
	if #State.log > 40 then
		table.remove(State.log, 1)
	end
	State.logVersion += 1
end

local function setStatus(text, kind)
	State.status = text
	State.statusKind = kind or "idle"
end

--// game hooks ------------------------------------------------------------------
-- Whatever the game fires into us (Dig_Result) only writes plain values; the window is touched by our
-- own loops, because game threads can't reach it.

local DigController
do
	local ok, controller = pcall(function()
		local controllers = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client", 10):WaitForChild("Controllers", 10)
		return require(controllers:WaitForChild("DigController", 10))
	end)
	restoreIdentity()
	if ok and type(controller) == "table" and type(controller.Dig) == "function" then
		DigController = controller
	else
		log("DigController not found, falling back to the shovel's click", "warn")
	end
end

-- the game's own network wrapper; CarryController sends Treasure_Store through it when you press G
local Net
do
	local ok, module = pcall(function()
		local util = ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("Util", 10)
		return require(util:WaitForChild("Net", 10))
	end)
	restoreIdentity()
	if ok and type(module) == "table" and type(module.FireServer) == "function" then
		Net = module
	else
		log("Net module not found, will press G to stow instead", "warn")
	end
end

-- WeaponController draws the swings; the script calls its attack methods itself (see the combat section)
local Weapon
do
	local ok, controller = pcall(function()
		local controllers = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client", 10):WaitForChild("Controllers", 10)
		return require(controllers:WaitForChild("WeaponController", 10))
	end)
	restoreIdentity()
	if ok and type(controller) == "table" and type(controller._attack) == "function" then
		Weapon = controller
	else
		State.attack = false
		log("WeaponController not found, auto attack is off", "warn")
	end
end

local RESULT_FIELD = { Success = "treasure", Junk = "junk", Nothing = "nothing", Warm = "warm", Invalid = "invalid" }
local resultSeq, lastResult = 0, nil

local function onDigResult(data)
	if not alive then
		return
	end
	resultSeq += 1
	lastResult = tostring(data.Result)
	local field = RESULT_FIELD[lastResult]
	if field then
		State[field] += 1
	end
end

-- Dig_Result reaches the controller through `self:_onResult(...)`, so a wrapper on the table sees every result
local unhook
if DigController and type(DigController._onResult) == "function" then
	local original = DigController._onResult
	local function wrapped(self, data, ...)
		if type(data) == "table" then
			pcall(onDigResult, data)
		end
		return original(self, data, ...)
	end
	if pcall(function()
		DigController._onResult = wrapped
	end) then
		unhook = function()
			if DigController._onResult == wrapped then
				DigController._onResult = original
			end
		end
	else
		log("Couldn't hook the dig results, digs will be timed instead", "warn")
	end
end

-- Two WeaponController methods are wrapped, again only to read values: _aim, so a swing the script starts points at the
-- enemy instead of at the mouse, and _showHit, which every hit the server confirms ends up in
local aimOverride -- a unit Vector3 while the script swings: the next _aim returns it
local hitSeq = 0
local hitsHooked = false
local unhookWeapon
if Weapon then
	local originalAim, originalShowHit = Weapon._aim, Weapon._showHit
	local function wrappedAim(self, ...)
		local forced = aimOverride
		if forced then
			aimOverride = nil
			return forced
		end
		return originalAim(self, ...)
	end
	local function wrappedShowHit(self, pos, amount, crit, kind, show, killed, ...)
		if alive then
			hitSeq += 1
			State.hits += 1
		end
		return originalShowHit(self, pos, amount, crit, kind, show, killed, ...)
	end
	local aimHooked = type(originalAim) == "function" and pcall(function()
		Weapon._aim = wrappedAim
	end)
	hitsHooked = type(originalShowHit) == "function" and pcall(function()
		Weapon._showHit = wrappedShowHit
	end)
	if not aimHooked then
		log("Couldn't hook the weapon aim: swings will follow your mouse", "warn")
	end
	unhookWeapon = function()
		if aimHooked and Weapon._aim == wrappedAim then
			Weapon._aim = originalAim
		end
		if hitsHooked and Weapon._showHit == wrappedShowHit then
			Weapon._showHit = originalShowHit
		end
	end
end

--// character and spots ---------------------------------------------------------

local function getChar()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if root and hum and hum.Health > 0 then
		return char, root, hum
	end
	return nil
end

local function carryingName()
	local value = LocalPlayer:GetAttribute("Carrying")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function isShovel(tool)
	return tool:IsA("Tool") and (tool.Name == "Shovel" or tool:GetAttribute("TreasureTool") == "Shovel")
end

-- returns the shovel and whether the character is holding it
local function findShovel(char)
	for _, child in ipairs(char:GetChildren()) do
		if isShovel(child) then
			return child, true
		end
	end
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if isShovel(child) then
				return child, false
			end
		end
	end
	return nil
end

local function shovelState(char)
	if not char then
		return "?"
	end
	local shovel, held = findShovel(char)
	if not shovel then
		return "missing"
	end
	return held and "equipped" or "in backpack"
end

local function spotPart(spot)
	if spot:IsA("BasePart") then
		return spot
	end
	return (spot:IsA("Model") and spot.PrimaryPart) or spot:FindFirstChild("Base") or spot:FindFirstChildWhichIsA("BasePart", true)
end

local function spotAvailable(spot)
	if not spot:IsDescendantOf(Workspace) then
		return false
	end
	local owner = tonumber(spot:GetAttribute("OwnerUserId")) or 0
	return owner == 0 or owner == LocalPlayer.UserId
end

local memory = setmetatable({}, { __mode = "k" }) -- spot -> { tries, restUntil }

-- returns the nearest spot that isn't resting, and the nearest spot of any kind
local function scanSpots(origin)
	local now = os.clock()
	local total, ready = 0, 0
	local best, nearest
	for _, spot in ipairs(CollectionService:GetTagged(SPOT_TAG)) do
		local part = spotAvailable(spot) and spotPart(spot)
		if part then
			total += 1
			local mem = memory[spot]
			local entry = {
				spot = spot,
				pos = part.Position,
				dist = origin and (part.Position - origin).Magnitude or math.huge,
			}
			if not nearest or entry.dist < nearest.dist then
				nearest = entry
			end
			if not (mem and mem.restUntil > now) then
				ready += 1
				if not best or entry.dist < best.dist then
					best = entry
				end
			end
		end
	end
	State.spotCount, State.readyCount = total, ready
	State.nearest = nearest and nearest.dist ~= math.huge and nearest.dist or nil
	return best, nearest
end

--// movement --------------------------------------------------------------------
-- The character is pinned to `hold` every frame while it glides to a spot or stands at one, so physics can't
-- push it off the spot between the teleport and the dig. `hold` is a CFrame, or a function returning one
-- (a ship keeps moving under us).

local hold, holdRoot

local function releaseHold()
	hold, holdRoot = nil, nil
end

local function resolve(target)
	if type(target) == "function" then
		return target()
	end
	return target
end

local function applyHold()
	local root = holdRoot
	if hold and root then
		if not root.Parent then
			releaseHold()
			return
		end
		local cf = resolve(hold)
		if cf then
			root.CFrame = cf
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

-- waits on Heartbeat from our own thread (a Heartbeat callback runs with fewer permissions in some executors)
task.spawn(function()
	restoreIdentity()
	while alive do
		RunService.Heartbeat:Wait()
		restoreIdentity()
		pcall(applyHold)
	end
end)

-- how high the root part rides above the ground when the character stands
local function standLift(hum, root)
	if hum.RigType == Enum.HumanoidRigType.R6 then
		return 3
	end
	return hum.HipHeight + root.Size.Y / 2
end

-- Dig() drops its hole DIG_REACH studs in front of the character, so stand that far back from the spot, facing it
local function standCFrame(char, root, hum, spot, spotPos)
	local flat = Vector3.new(spotPos.X - root.Position.X, 0, spotPos.Z - root.Position.Z)
	if flat.Magnitude < 0.5 then
		local look = root.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
	end
	local dir = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, 1)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, spot }
	params.RespectCanCollide = true
	local hit = Workspace:Raycast(spotPos + Vector3.new(0, 10, 0), Vector3.new(0, -40, 0), params)
	local groundY = hit and hit.Position.Y or spotPos.Y
	local lift = standLift(hum, root)

	local pos = Vector3.new(spotPos.X - dir.X * DIG_REACH, groundY + lift, spotPos.Z - dir.Z * DIG_REACH)
	return CFrame.lookAt(pos, pos + dir)
end

-- `target` is a CFrame or a function returning one; returns false when the farm is switched off (unless
-- `always`), unloaded, or the character went away on the way
local function travelTo(root, target, always)
	holdRoot = root
	local goal = resolve(target)
	if not goal then
		return false
	end
	if State.smooth then
		local startCF = root.CFrame
		local duration = (goal.Position - startCF.Position).Magnitude / State.speed
		if duration > 0.05 then
			local started = os.clock()
			repeat
				goal = resolve(target) or goal
				hold = startCF:Lerp(goal, math.min((os.clock() - started) / duration, 1))
				pcall(applyHold)
				task.wait()
				if not alive or not (always or State.enabled) or not root.Parent then
					return false
				end
			until os.clock() - started >= duration
		end
	end
	hold = target
	pcall(applyHold) -- don't wait for the next Heartbeat: callers may release the hold right after
	task.wait()
	return alive and (always or State.enabled)
end

--// farming ---------------------------------------------------------------------

-- interruptible: returns false as soon as the farm is switched off or unloaded
local function sleep(seconds)
	local deadline = os.clock() + seconds
	while alive and State.enabled do
		if os.clock() >= deadline then
			return true
		end
		task.wait()
	end
	return false
end

local function waitUntil(predicate, timeout)
	local deadline = os.clock() + timeout
	while alive and State.enabled and os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait()
	end
	return predicate() and true or false
end

local function equipShovel(char, hum)
	local shovel, held = findShovel(char)
	if not shovel then
		return false, "No shovel in your backpack"
	end
	if held then
		return true
	end
	pcall(function()
		hum:EquipTool(shovel)
	end)
	restoreIdentity()
	waitUntil(function()
		return shovel.Parent == char and (not DigController or DigController:IsShovelEquipped())
	end, 1)
	if shovel.Parent ~= char then
		return false, "Couldn't equip the shovel"
	end
	return true
end

-- true when a dig went out; Dig() itself enforces the cooldown, the shovel and the hands-full checks
local function fireDig(char)
	if DigController then
		local ok, started = pcall(DigController.Dig, DigController)
		restoreIdentity()
		return ok and started == true
	end
	local shovel, held = findShovel(char)
	if shovel and held then
		pcall(function()
			shovel:Activate()
		end)
		return true
	end
	return false
end

local function waitForResult(before)
	if not unhook then
		sleep(1.8)
		return nil
	end
	waitUntil(function()
		return resultSeq > before
	end, RESULT_WAIT)
	if resultSeq > before then
		return lastResult
	end
	return nil
end

local RESULT_TEXT = {
	Success = "Found treasure!",
	Junk = "Dug up old coins",
	Nothing = "Nothing here",
	Warm = "Warm: treasure is close, but not here",
	Invalid = "Dig rejected as invalid",
}
local RESULT_KIND = { Success = "gold", Junk = "dim", Nothing = "dim", Warm = "warn", Invalid = "bad" }

local nextDigAt = 0
local refusals = 0
local current -- { spot, cf } of the spot we are standing at

local function digSpot(entry, char, root, hum)
	local spot = entry.spot
	local mem = memory[spot]
	if not mem then
		mem = { tries = 0, restUntil = 0 }
		memory[spot] = mem
	end

	local equipped, why = equipShovel(char, hum)
	if not equipped then
		releaseHold()
		current = nil
		setStatus(why, "bad")
		sleep(1)
		return
	end

	if not (current and current.spot == spot and (root.Position - current.cf.Position).Magnitude < 2) then
		local cf = standCFrame(char, root, hum, spot, entry.pos)
		setStatus(string.format("Heading to a sparkle spot (%d studs)", round(entry.dist)), "ok")
		if not travelTo(root, cf) then
			return
		end
		current = { spot = spot, cf = cf }
		if not sleep(SETTLE) or not spotAvailable(spot) then
			return -- switched off, or someone got there first: the loop looks again
		end
	end

	if not sleep(nextDigAt - os.clock()) then
		return
	end

	setStatus(string.format("Digging (try %d of %d)", mem.tries + 1, MAX_TRIES), "ok")
	local before = resultSeq
	if not fireDig(char) then
		refusals += 1
		if refusals >= 4 then
			refusals = 0
			log("The game refused the dig 4 times in a row", "bad")
			setStatus("The game keeps refusing the dig", "bad")
			sleep(3)
		else
			sleep(0.4)
		end
		return
	end
	refusals = 0
	State.digs += 1
	nextDigAt = os.clock() + DIG_COOLDOWN + 0.05 + math.random() * 0.12

	local result = waitForResult(before)
	if result then
		log(RESULT_TEXT[result] or result, RESULT_KIND[result] or "dim")
	elseif unhook then
		log("No answer from the server", "warn")
	end

	mem.tries += 1
	if result == "Success" or result == "Invalid" or mem.tries >= MAX_TRIES then
		mem.tries = 0
		mem.restUntil = os.clock() + SPOT_REST
	end
	if result == "Success" then
		if State.carry then
			State.site = { pos = entry.pos, at = os.clock() }
		end
		-- the server may put the treasure straight into our hands; otherwise it lies at the spot
		waitUntil(function()
			return carryingName() ~= nil
		end, 1.5)
	end
end

--// carrying --------------------------------------------------------------------
-- A found treasure ends up in our hands (the "Carrying" attribute) and digging stays blocked until it is stowed:
-- pick it up if it is lying at the spot, walk aboard the ship, wait for OnShip, then send Treasure_Store.

local function promptPosition(prompt)
	local parent = prompt.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
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
	restoreIdentity()
end

local pickupSkip = setmetatable({}, { __mode = "k" }) -- prompt -> time it is left alone until

local function treasureFolder()
	local world = Workspace:FindFirstChild("World")
	local dynamic = world and world:FindFirstChild("Dynamic")
	return dynamic and dynamic:FindFirstChild("Treasure")
end

-- the nearest prompt that picks a treasure up, around `near`; locked ones (marked with a padlock) are skipped
local function findTreasurePrompt(near)
	local folder = treasureFolder()
	if not folder then
		return nil
	end
	local now = os.clock()
	local best, bestDist
	for _, inst in ipairs(folder:GetDescendants()) do
		if
			inst:IsA("ProximityPrompt")
			and (inst.Name == "TreasurePrompt" or inst:GetAttribute("TreasureUid") ~= nil)
			and inst.Enabled
			and not string.find(inst.ObjectText, "\u{1F512}", 1, true)
			and not (pickupSkip[inst] and pickupSkip[inst] > now)
		then
			local pos = promptPosition(inst)
			local dist = pos and (pos - near).Magnitude
			if dist and dist <= PICKUP_RADIUS and (not bestDist or dist < bestDist) then
				best, bestDist = inst, dist
			end
		end
	end
	return best
end

-- returns true while it has something to do, false once there is nothing (more) to pick up
local function collectTreasure(root)
	local site = State.site
	local prompt = findTreasurePrompt(site.pos)
	if not prompt then
		if os.clock() - site.at > PICKUP_APPEAR then
			State.site = nil
			log("No treasure showed up at the spot", "dim")
			return false
		end
		releaseHold()
		current = nil
		setStatus("Waiting for the treasure to appear", "ok")
		task.wait(0.3)
		return true
	end

	local pos = promptPosition(prompt)
	if not pos then
		pickupSkip[prompt] = os.clock() + 20
		return true
	end
	setStatus("Picking up the treasure", "ok")
	current = nil
	if not travelTo(root, CFrame.new(pos + Vector3.new(0, 3, 0))) or not sleep(0.4) then
		return true
	end
	local deadline = os.clock() + 4
	local nextPress = 0
	while alive and State.enabled and os.clock() < deadline do
		if carryingName() then
			State.site = nil
			log("Picked the treasure up", "ok")
			return true
		end
		if os.clock() >= nextPress then
			press(prompt)
			nextPress = os.clock() + 1
		end
		task.wait(0.1)
	end
	if alive and State.enabled and not carryingName() then
		pickupSkip[prompt] = os.clock() + 20
		log("The treasure wouldn't be picked up", "warn")
	end
	return true
end

local function shipsFolder()
	local world = Workspace:FindFirstChild("World")
	local dynamic = world and world:FindFirstChild("Dynamic")
	return dynamic and dynamic:FindFirstChild("Ships")
end

local function shipPart(ship)
	local part = ship.PrimaryPart or ship:FindFirstChild("Root")
	if part and part:IsA("BasePart") then
		return part
	end
	return ship:FindFirstChildWhichIsA("BasePart", true)
end

-- the N of Ship_N we are standing on, as the game reports it
local function onShipId()
	local id = tonumber(LocalPlayer:GetAttribute("OnShip")) or 0
	return id ~= 0 and id or nil
end

local function cargoSpace(ship)
	local cap = tonumber(ship:GetAttribute("CargoCap"))
	if cap then
		return tonumber(ship:GetAttribute("CargoUsed")) or 0, cap
	end
	return nil
end

-- true when an owner-like attribute of the ship names us
local function ownedByMe(ship)
	for key, value in pairs(ship:GetAttributes()) do
		local lower = string.lower(key)
		if string.find(lower, "owner", 1, true) or string.find(lower, "captain", 1, true) then
			if value == LocalPlayer.UserId or value == LocalPlayer.Name or tonumber(value) == LocalPlayer.UserId then
				return true
			end
		end
	end
	return false
end

local shipRest = setmetatable({}, { __mode = "k" }) -- ship -> time it is left alone until

-- Which ship is ours isn't in the scripts we have, so: the one saved with the button, then one that names us as
-- owner, then Ship_<our user id>, then one a player attribute points at, then the one we stand on, then the nearest.
-- returns the ship and how it was found, or nil with "none" / "resting" and when the first resting ship is free again
local function chooseShip(origin)
	local folder = shipsFolder()
	if not folder then
		return nil, "none"
	end
	local now = os.clock()
	local ships, soonest = {}, nil
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and shipPart(child) then
			local rest = shipRest[child]
			if rest and rest > now then
				soonest = math.min(soonest or rest, rest)
			else
				table.insert(ships, child)
			end
		end
	end
	if #ships == 0 then
		return nil, soonest and "resting" or "none", soonest
	end

	local function named(id)
		for _, ship in ipairs(ships) do
			if ship.Name == "Ship_" .. tostring(id) then
				return ship
			end
		end
		return nil
	end

	local ship = State.shipId and named(State.shipId)
	if ship then
		return ship, "saved"
	end
	for _, candidate in ipairs(ships) do
		if ownedByMe(candidate) then
			return candidate, "owner"
		end
	end
	ship = named(LocalPlayer.UserId)
	if ship then
		return ship, "id"
	end
	for key, value in pairs(LocalPlayer:GetAttributes()) do
		if key ~= "OnShip" and string.find(string.lower(key), "ship", 1, true) then
			ship = named(value)
			if ship then
				return ship, "attribute"
			end
		end
	end
	local aboard = onShipId()
	ship = aboard and named(aboard)
	if ship then
		return ship, "aboard"
	end
	local best, bestDist
	if origin then
		for _, candidate in ipairs(ships) do
			local dist = (shipPart(candidate).Position - origin).Magnitude
			if not bestDist or dist < bestDist then
				best, bestDist = candidate, dist
			end
		end
	end
	if best then
		return best, "nearest"
	end
	return nil, "none"
end

-- a spot on the deck that keeps up with the ship
local function deckTarget(ship)
	return function()
		local part = shipPart(ship)
		if part and part.Parent then
			return part.CFrame * CFrame.new(0, (tonumber(ship:GetAttribute("DeckHeight")) or 2) + 3, 0)
		end
		return nil
	end
end

-- the middle of the whole model, for ships whose root part isn't over the deck
local function middleTarget(ship)
	return function()
		local cf, size = ship:GetBoundingBox()
		return cf * CFrame.new(0, size.Y / 2 + 3, 0)
	end
end

local function shipText(ship, how, reason)
	if ship then
		return how .. ": " .. ship.Name
	end
	return reason == "resting" and "resting" or "not found"
end

local nextShipScan = 0

local function scanShip(root)
	if os.clock() < nextShipScan then
		return
	end
	nextShipScan = os.clock() + 1.5
	local ship, how = chooseShip(root and root.Position)
	State.shipText = shipText(ship, how, how)
	local used, cap
	if ship then
		used, cap = cargoSpace(ship)
	end
	State.cargo = cap and string.format("%d/%d", round(used), round(cap)) or "-"
end

-- Treasure_Store is what pressing G sends; fall back to pressing the key if the game's Net module isn't reachable
local function fireStore()
	if Net then
		local ok = pcall(Net.FireServer, "Treasure_Store")
		restoreIdentity()
		if ok then
			return
		end
	end
	pcall(function()
		local input = game:GetService("VirtualInputManager")
		input:SendKeyEvent(true, Enum.KeyCode.G, false, game)
		task.wait(0.05)
		input:SendKeyEvent(false, Enum.KeyCode.G, false, game)
	end)
	restoreIdentity()
end

local function stowCarried(root)
	local ship, how, soonest = chooseShip(root.Position)
	if not ship then
		releaseHold()
		current = nil
		State.shipText = shipText(nil, how, how)
		if how == "resting" then
			setStatus(string.format("The ship wouldn't take the treasure, trying again in %ds", math.max(1, math.ceil(soonest - os.clock()))), "warn")
		else
			setStatus("Carrying a treasure but no ship found: stand on yours and press Use the ship I'm on", "warn")
		end
		sleep(1)
		return
	end
	State.shipText = shipText(ship, how)

	local used, cap = cargoSpace(ship)
	if cap and used + 1 > cap then
		releaseHold()
		current = nil
		setStatus(string.format("Cargo hold is full (%d/%d): empty it and the farm carries on", round(used), round(cap)), "warn")
		sleep(1.5)
		return
	end

	local function aboard()
		local id = onShipId()
		return id ~= nil and "Ship_" .. tostring(id) == ship.Name
	end

	current = nil
	setStatus("Taking the treasure to " .. ship.Name, "ok")
	if not travelTo(root, deckTarget(ship)) then
		return
	end
	local boarded = waitUntil(aboard, BOARD_WAIT)
	if not boarded then
		if not travelTo(root, middleTarget(ship)) then
			return
		end
		boarded = waitUntil(aboard, BOARD_WAIT)
	end
	if not boarded then
		if alive and State.enabled then
			log("Couldn't get aboard " .. ship.Name, "bad")
			shipRest[ship] = os.clock() + SHIP_REST
			releaseHold()
		end
		return
	end
	if not sleep(STORE_DELAY) then
		return
	end

	for attempt = 1, STORE_TRIES do
		setStatus(string.format("Storing the treasure (try %d of %d)", attempt, STORE_TRIES), "ok")
		fireStore()
		if waitUntil(function()
			return carryingName() == nil
		end, 2.5) then
			State.stored += 1
			local usedNow, capNow = cargoSpace(ship)
			log(string.format("Stowed the treasure on %s%s", ship.Name, capNow and string.format(" (%d/%d)", round(usedNow), round(capNow)) or ""), "ok")
			releaseHold()
			return
		end
		if not (alive and State.enabled) then
			return
		end
	end
	log(ship.Name .. " wouldn't take the treasure", "bad")
	shipRest[ship] = os.clock() + SHIP_REST
	releaseHold()
end

--// combat ----------------------------------------------------------------------
-- WeaponController decides what a swing looks like and what the server is told. The script picks the enemy, has the
-- controller aim at it (the _aim hook) and calls _attack / _useAbility once the weapon is ready, so the server gets the
-- same Weapon_Attack a click sends. Enemies are what the controller's own aim assist targets: things tagged Damageable /
-- Enemy / Boss that aren't Faction Player or Neutral. Other players are never swung at.

local fightEnemies, weaponText -- defined below, used by the farm thread

do
	local enemyRest = setmetatable({}, { __mode = "k" }) -- enemy -> time it is left alone until
	local slotEmpty = {} -- hotbar slot -> time it last had nothing to draw
	local shotThroughStates = { Active = true, Hold = true } -- BoardState of a ship that weapons go through
	local fallbackWeapon = { Type = "Melee", Range = 10, Speed = 1.5 } -- planned with when only a weapon tool is found
	local fightPause, nextEnemyScan = 0, 0
	local lastSwingError

	local function weaponDef()
		local ok, def = pcall(Weapon.GetEquippedWeapon, Weapon)
		return ok and type(def) == "table" and def or nil
	end

	-- a weapon is in the hands and the game lets it be used (nothing carried, no menu open, not at the helm)
	local function weaponOut()
		if not weaponDef() then
			return false
		end
		local ok, usable = pcall(Weapon.IsWeaponOut, Weapon)
		return ok and usable == true
	end

	function weaponText()
		if not Weapon then
			return "unavailable"
		end
		local def = weaponDef()
		if not def then
			return "not drawn"
		end
		return string.format("%s (%s)%s", tostring(def.Name or def.Id or "weapon"), tostring(def.Type or "?"), weaponOut() and "" or ", unusable")
	end

	local function weaponTool(char)
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		for _, holder in ipairs({ char, backpack }) do
			for _, child in ipairs(holder:GetChildren()) do
				if child:IsA("Tool") and child:GetAttribute("WeaponTool") == true then
					return child
				end
			end
		end
		return nil
	end

	-- the weapon about to be used: the one in the hands, else the loadout's pick for the chosen slot
	local function plannedWeapon(char)
		local held = weaponDef()
		if held then
			return held
		end
		local ok, loadout = pcall(Weapon.GetLoadout, Weapon)
		if ok and type(loadout) == "table" then
			local def = loadout[State.weaponSlot] or loadout[State.weaponSlot == "Melee" and "Ranged" or "Melee"]
			if type(def) == "table" then
				return def
			end
		end
		return weaponTool(char) and fallbackWeapon or nil
	end

	local function drawSlot(slot)
		if (slotEmpty[slot] or 0) > os.clock() then
			return false
		end
		local ok, drawn = pcall(Weapon.DrawSlot, Weapon, slot)
		restoreIdentity()
		if not (ok and drawn) then
			slotEmpty[slot] = os.clock() + 30
			return false
		end
		return waitUntil(weaponOut, WEAPON_WAIT)
	end

	-- true once a weapon is drawn and usable: the chosen slot first, then the other one, then any weapon tool by hand
	local function drawWeapon(char, hum)
		if weaponOut() then
			return true
		end
		if weaponDef() then
			return waitUntil(weaponOut, WEAPON_WAIT) -- in the hands already, the game just won't let it be used yet
		end
		if drawSlot(State.weaponSlot) or drawSlot(State.weaponSlot == "Melee" and "Ranged" or "Melee") then
			return true
		end
		local tool = weaponTool(char)
		if tool and tool.Parent ~= char then
			pcall(function()
				hum:EquipTool(tool)
			end)
			restoreIdentity()
			return waitUntil(weaponOut, WEAPON_WAIT)
		end
		return false
	end

	local function weaponStuck()
		fightPause = os.clock() + FIGHT_PAUSE
		log(string.format("Couldn't draw a weapon (is a menu open?), trying again in %ds", FIGHT_PAUSE), "warn")
	end

	--// enemies

	local function isDead(inst)
		local humanoid = inst:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then
			return true
		end
		local health = inst:GetAttribute("Health")
		return inst:GetAttribute("Dead") == true or (type(health) == "number" and health <= 0)
	end

	-- weapons go through ships that are being boarded and through anything marked WeaponPassThrough
	local function shotThrough(inst)
		if inst:GetAttribute("WeaponPassThrough") == true then
			return true
		end
		return shotThroughStates[inst:GetAttribute("BoardState")] == true
			and (CollectionService:HasTag(inst, "Ship") or CollectionService:HasTag(inst, "NPCShip"))
	end

	-- where a swing at the enemy points: the part its AimPart attribute names, else the middle of the model
	local function aimPoint(inst)
		local path = tostring(inst:GetAttribute("AimPart") or "")
		if #path > 0 and #path <= 64 then
			local node = inst
			for name in string.gmatch(path, "[^/]+") do
				node = node and node:FindFirstChild(name)
			end
			if node and node ~= inst and node:IsA("BasePart") then
				return node.Position
			end
		end
		local rootPart = inst:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			return rootPart.Position
		end
		if inst:IsA("BasePart") then
			return inst.Position
		end
		if inst:IsA("Model") then
			if inst.PrimaryPart then
				return inst.PrimaryPart.Position
			end
			local ok, pivot = pcall(inst.GetPivot, inst)
			if ok and pivot then
				return pivot.Position
			end
		end
		return nil
	end

	local function distanceTo(from, to, flat)
		if flat then
			return Vector3.new(to.X - from.X, 0, to.Z - from.Z).Magnitude
		end
		return (to - from).Magnitude
	end

	-- how far away an enemy may be and still get a swing; melee measures along the ground like the game's aim assist
	local function reachOf(def)
		local range = tonumber(def.Range) or 8
		if def.Type == "Melee" then
			return range + MELEE_SLACK
		end
		return math.max(range - 3, 5)
	end

	local function enemyName(inst)
		local name = inst:GetAttribute("DisplayName")
		return tostring(type(name) == "string" and name ~= "" and name or inst.Name)
	end

	local function gone(inst)
		return not inst:IsDescendantOf(Workspace) or isDead(inst)
	end

	-- every enemy the weapon could be swung at, nearest first: { inst, point, dist }
	local function scanEnemies(char, root, def)
		local flat = def.Type == "Melee"
		local origin = root.Position
		local now = os.clock()
		local list, seen = {}, {}
		for _, tag in ipairs(ENEMY_TAGS) do
			for _, inst in ipairs(CollectionService:GetTagged(tag)) do
				if not seen[inst] then
					seen[inst] = true
					local rest = enemyRest[inst]
					local faction = inst:GetAttribute("Faction")
					if
						not (rest and rest > now)
						and faction ~= "Player"
						and faction ~= "Neutral"
						and inst ~= char
						and inst:IsDescendantOf(Workspace)
						and not inst:IsDescendantOf(char)
						and not Players:GetPlayerFromCharacter(inst)
						and not shotThrough(inst)
						and not isDead(inst)
					then
						local point = aimPoint(inst)
						if point then
							table.insert(list, { inst = inst, point = point, dist = distanceTo(origin, point, flat) })
						end
					end
				end
			end
		end
		table.sort(list, function(a, b)
			return a.dist < b.dist
		end)
		return list
	end

	-- the enemy to fight: `keep` while it is still in range, else the nearest one in reach (or in chase range)
	local function chooseEnemy(list, def, keep)
		local limit = reachOf(def)
		if State.chase then
			limit = math.max(limit, State.chaseRadius)
		end
		local best
		for _, entry in ipairs(list) do
			if entry.dist > limit then
				break -- nearest first, the rest is further
			end
			if entry.inst == keep then
				return entry
			end
			best = best or entry
		end
		return best
	end

	--// swinging

	-- a melee swing points along the ground like the game's own aim; anything else points from the head at the enemy
	local function swingDirection(def, char, root, point)
		if def.Type == "Melee" then
			local flat = Vector3.new(point.X - root.Position.X, 0, point.Z - root.Position.Z)
			if flat.Magnitude < 0.05 then
				local look = root.CFrame.LookVector
				flat = Vector3.new(look.X, 0, look.Z)
			end
			return flat.Magnitude > 0.001 and flat.Unit or Vector3.new(0, 0, -1)
		end
		local head = char:FindFirstChild("Head")
		local offset = point - (head and head:IsA("BasePart") and head or root).Position
		return offset.Magnitude > 0.001 and offset.Unit or root.CFrame.LookVector
	end

	-- one swing: the ability when it is ready, else a light attack; returns true when something went out
	local function swing(def, char, root, point)
		local dir = swingDirection(def, char, root, point)
		if State.ability then
			local before = Weapon._lastAbilityAt
			aimOverride = dir
			pcall(Weapon._useAbility, Weapon)
			aimOverride = nil
			restoreIdentity()
			if Weapon._lastAbilityAt ~= before then
				State.abilities += 1
				return true
			end
		end
		local before = Weapon._lastAttackAt
		aimOverride = dir
		local ok, err = pcall(Weapon._attack, Weapon, "Light")
		aimOverride = nil
		restoreIdentity()
		if not ok and tostring(err) ~= lastSwingError then
			lastSwingError = tostring(err)
			log("The weapon swing failed: " .. lastSwingError, "warn")
		end
		if Weapon._lastAttackAt ~= before then
			State.swings += 1
			return true
		end
		return false
	end

	-- when the controller will let the next swing go (draw time, cooldown and ability recovery included)
	local function weaponReadyAt()
		local ok, at = pcall(Weapon._readyAt, Weapon)
		if ok and type(at) == "number" then
			return at
		end
		return nil
	end

	--// moving while fighting

	-- the follower returns a CFrame a little way from the enemy, on the side we came from, with the ground checked
	-- each time, so the character keeps up with an enemy that walks; nil when it would have to stand on water
	local function chaseTarget(char, root, hum, def, inst)
		local fromPos = root.Position
		local gap = math.clamp((tonumber(def.Range) or 8) * CHASE_GAP, 3, def.Type == "Melee" and 14 or 40)
		local lift = standLift(hum, root)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char, inst }
		params.IgnoreWater = false
		local ground = { x = math.huge, z = math.huge, y = 0, at = 0, water = false }
		return function()
			local point = aimPoint(inst)
			if not point then
				return nil
			end
			local away = Vector3.new(fromPos.X - point.X, 0, fromPos.Z - point.Z)
			local dir = away.Magnitude > 0.5 and away.Unit or Vector3.new(0, 0, 1)
			local x, z = point.X + dir.X * gap, point.Z + dir.Z * gap
			if os.clock() - ground.at > 0.5 or math.abs(x - ground.x) + math.abs(z - ground.z) > 2 then
				local hit = Workspace:Raycast(Vector3.new(x, point.Y + 25, z), Vector3.new(0, -80, 0), params)
				ground = {
					x = x,
					z = z,
					y = hit and hit.Position.Y or point.Y - lift,
					at = os.clock(),
					water = hit ~= nil and hit.Material == Enum.Material.Water,
				}
			end
			if ground.water then
				return nil
			end
			local pos = Vector3.new(x, ground.y + lift, z)
			return CFrame.lookAt(pos, Vector3.new(point.X, pos.Y, point.Z))
		end
	end

	-- keeps the character where it stands, turned toward the enemy: knockback can't move it, and the game's own turn
	-- toward the swing agrees with it
	local function pinFacing(root, getPoint)
		local pos = root.Position
		holdRoot = root
		hold = function()
			local point = getPoint()
			local flat = point and Vector3.new(point.X - pos.X, 0, point.Z - pos.Z)
			if flat and flat.Magnitude > 0.05 then
				return CFrame.lookAt(pos, pos + flat.Unit)
			end
			return nil
		end
	end

	--// the fight

	-- an enemy that isn't taking damage (or that takes forever) is left alone for a while
	local function giveUp(rec, now)
		if rec.swings == 0 then
			return now - rec.since > CHASE_LIMIT
		end
		if now - rec.since > ENGAGE_CAP then
			return true
		end
		if hitsHooked and State.hits > 0 then
			return now - rec.clock > NO_HIT_LIMIT
		end
		return now - rec.since > ENGAGE_LIMIT
	end

	-- the enemy we were fighting is gone: count it when we really hurt it
	local function finishEnemy(target, rec)
		if rec.swings > 0 and (hitSeq > rec.hitSeq0 or not (hitsHooked and State.hits > 0)) then
			State.kills += 1
			log("Defeated " .. enemyName(target.inst), "gold")
		end
	end

	-- keeps fighting while an enemy is in reach (or in chase range); true if it did anything
	local function fightLoop()
		local engaged = false
		local target, rec, aim
		local following = false
		local list, nextScan, nextSwing = {}, 0, 0
		current = nil -- the stand at the spot is no good once we've turned or moved

		while alive and State.enabled and State.attack do
			local char, root, hum = getChar()
			if not root or carryingName() then
				break
			end

			local def = weaponDef()
			if not (def and weaponOut()) then
				if not drawWeapon(char, hum) then
					weaponStuck()
					break
				end
				def = weaponDef()
				if not def then
					break
				end
			end
			local now = os.clock()
			State.weapon, State.shovel = weaponText(), shovelState(char) -- step() isn't running while we fight

			if target and gone(target.inst) then
				finishEnemy(target, rec)
				target, rec, following = nil, nil, false
				nextScan = 0
			end
			if now >= nextScan then
				list = scanEnemies(char, root, def)
				nextScan = now + 0.1
			end
			local entry = chooseEnemy(list, def, target and target.inst)
			if not entry then
				break
			end
			-- the list may be a few frames old: measure the one picked again
			local point = aimPoint(entry.inst)
			if point then
				entry.point, entry.dist = point, distanceTo(root.Position, point, def.Type == "Melee")
			end

			if not (target and target.inst == entry.inst) then
				rec = { since = now, swings = 0, hitSeq = hitSeq, hitSeq0 = hitSeq }
				following = false
				if onShipId() then
					releaseHold() -- the ship moves under us, a pin in the world would leave it behind
				else
					pinFacing(root, function()
						return aim
					end)
				end
			end
			target = entry
			aim = entry.point
			engaged = true
			if hitSeq ~= rec.hitSeq then
				rec.hitSeq = hitSeq
				rec.clock = now
			end

			local name = enemyName(entry.inst)
			local reach = reachOf(def)
			State.target = string.format("%s, %d studs", name, round(entry.dist))
			if giveUp(rec, now) then
				enemyRest[entry.inst] = now + ENEMY_REST
				log(string.format("Gave up on %s, it isn't taking damage", name), "warn")
				target, rec, following = nil, nil, false
				nextScan = 0
			elseif entry.dist > reach then
				if State.chase and not following then
					following = true
					setStatus(string.format("Chasing %s (%d studs)", name, round(entry.dist)), "ok")
					if not travelTo(root, chaseTarget(char, root, hum, def, entry.inst)) then
						if not (alive and State.enabled and getChar()) then
							break -- switched off, or died on the way
						end
						enemyRest[entry.inst] = os.clock() + ENEMY_REST
						log("Can't get to " .. name .. " from here", "warn")
						target, rec, following = nil, nil, false
						nextScan = 0
					end
				end
			else
				setStatus("Fighting " .. name, "ok")
				if now >= (weaponReadyAt() or nextSwing) + SWING_MARGIN and swing(def, char, root, entry.point) then
					rec.swings += 1
					rec.clock = rec.clock or now
					nextSwing = os.clock() + 1 / math.max(tonumber(def.Speed) or 1, 0.1)
				end
			end
			task.wait()
		end

		releaseHold()
		current = nil
		State.target = "none"
		return engaged
	end

	-- looks for something to fight, draws the weapon when there is, and fights; false when there was nothing to do
	function fightEnemies(char, root, hum)
		local now = os.clock()
		if not Weapon or now < fightPause or now < nextEnemyScan then
			return false
		end
		local planned = plannedWeapon(char)
		if not planned then
			State.target = "no weapon"
			nextEnemyScan = now + 1
			return false
		end
		if not chooseEnemy(scanEnemies(char, root, planned), planned) then
			State.target = "none"
			nextEnemyScan = now + 0.15
			return false
		end
		if not drawWeapon(char, hum) then
			weaponStuck()
			return false
		end
		return fightLoop()
	end
end

--// farm thread -----------------------------------------------------------------

local function step()
	local char, root, hum = getChar()
	State.carrying = carryingName()
	State.shovel = shovelState(char)
	State.weapon = weaponText()
	local best, nearest = scanSpots(root and root.Position)
	scanShip(root)

	local request = State.request
	if request then
		State.request = nil
		if State.enabled then
			log("Stop the farm before moving by hand", "warn")
		elseif not root then
			log("Waiting for your character first", "warn")
		elseif request == "goto" then
			if nearest then
				setStatus("Going to the nearest sparkle spot", "ok")
				travelTo(root, standCFrame(char, root, hum, nearest.spot, nearest.pos), true)
				releaseHold()
			else
				log("No sparkle spot to go to", "warn")
			end
		elseif request == "ship" then
			local ship, how = chooseShip(root.Position)
			if ship then
				setStatus("Going to " .. ship.Name, "ok")
				travelTo(root, deckTarget(ship), true)
				releaseHold()
			else
				log("No ship to go to (" .. how .. ")", "warn")
			end
		end
		return
	end

	if not State.enabled then
		releaseHold()
		current = nil
		setStatus("Idle", "idle")
		task.wait(0.25)
		return
	end

	if not root then
		releaseHold()
		current = nil
		setStatus("Waiting for your character", "warn")
		task.wait(0.5)
		return
	end

	if carryingName() then
		State.site = nil
		if State.carry then
			stowCarried(root)
		else
			releaseHold()
			current = nil
			setStatus("Carrying a treasure: stow it yourself (carry is off)", "warn")
			task.wait(0.5)
		end
		return
	end

	if State.attack and fightEnemies(char, root, hum) then
		return
	end

	if not State.dig then
		releaseHold()
		current = nil
		if State.attack then
			setStatus("Waiting for enemies", "idle")
		else
			setStatus("Nothing to do: switch on digging or auto attack", "warn")
		end
		task.wait(0.25)
		return
	end

	if State.site then
		if not State.carry then
			State.site = nil
		elseif collectTreasure(root) then
			return
		end
	end

	if not best then
		releaseHold()
		current = nil
		setStatus(State.spotCount == 0 and "No sparkle spots around, waiting for some to appear" or "Every spot is resting, waiting", "warn")
		task.wait(0.4)
		return
	end

	digSpot(best, char, root, hum)
end

task.spawn(function()
	restoreIdentity()
	local failures = 0
	while alive do
		local ok, err = pcall(step)
		restoreIdentity()
		if ok then
			failures = 0
		else
			failures += 1
			log("Error: " .. tostring(err), "bad")
			warn("[Sparkle Dig Farm] " .. tostring(err))
			if failures >= 5 then
				failures = 0
				State.enabled = false
				releaseHold()
				setStatus("Stopped after repeated errors, see the log", "bad")
			end
			task.wait(1)
		end
		task.wait() -- always give the frame back, whatever step() did
	end
end)

-- Roblox fires Idled after ~20 minutes without input; a fake right-click resets the timer
connect(LocalPlayer.Idled, function()
	if not State.antiAfk then
		return
	end
	pcall(function()
		local virtualUser = game:GetService("VirtualUser")
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new())
	end)
end)

local function setEnabled(on)
	if State.enabled == on then
		return
	end
	State.enabled = on
	if on then
		State.runStart = os.clock()
		log("Farm started", "ok")
		local aboard = onShipId()
		if not State.shipId and aboard then
			State.shipId = tostring(aboard)
			log("Using the ship you're standing on: Ship_" .. State.shipId, "dim")
		end
	else
		State.runTotal += os.clock() - (State.runStart or os.clock())
		State.runStart = nil
		log("Farm stopped", "dim")
	end
end

local function saveShip()
	local aboard = onShipId()
	if not aboard then
		log("Stand on your ship first, the game has to say you're aboard", "warn")
		return
	end
	State.shipId = tostring(aboard)
	nextShipScan = 0
	log("Ship saved: Ship_" .. State.shipId, "ok")
end

--// window ----------------------------------------------------------------------

local C = {
	Bg = Color3.fromRGB(14, 16, 22),
	Panel = Color3.fromRGB(20, 23, 31),
	Card = Color3.fromRGB(30, 34, 45),
	Input = Color3.fromRGB(24, 27, 36),
	Border = Color3.fromRGB(48, 54, 70),
	Text = Color3.fromRGB(232, 235, 242),
	Muted = Color3.fromRGB(150, 157, 175),
	Faint = Color3.fromRGB(105, 112, 130),
	Accent = Color3.fromRGB(88, 101, 242),
	Up = Color3.fromRGB(52, 211, 153),
	Down = Color3.fromRGB(248, 113, 113),
	Warn = Color3.fromRGB(251, 191, 36),
	Gold = Color3.fromRGB(250, 204, 21),
}
local KIND_COLOR = { idle = C.Faint, ok = C.Up, warn = C.Warn, bad = C.Down, dim = C.Muted, gold = C.Gold }
local FONT = Enum.Font.Gotham
local FONT_B = Enum.Font.GothamBold
local FONT_M = Enum.Font.RobotoMono

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function merge(base, extra)
	for k, v in pairs(extra or {}) do
		base[k] = v
	end
	return base
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function pad(v, h)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, v),
		PaddingBottom = UDim.new(0, v),
		PaddingLeft = UDim.new(0, h),
		PaddingRight = UDim.new(0, h),
	})
end

local function stroke(color, thickness, transparency)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function list(direction, gap)
	return new("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

local function label(props)
	return new("TextLabel", merge({
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 13,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, 16),
	}, props))
end

local function button(props, children)
	return new("TextButton", merge({
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Font = FONT_B,
		TextSize = 13,
		TextColor3 = C.Text,
		BackgroundColor3 = C.Card,
	}, props), children)
end

local function section(parent, order, text)
	return label({
		Text = text,
		TextSize = 11,
		Font = FONT_B,
		TextColor3 = C.Faint,
		LayoutOrder = order,
		Parent = parent,
	})
end

local function esc(s)
	return (tostring(s):gsub("[<>&]", ""))
end

local gui = new("ScreenGui", {
	Name = "SparkleDigFarm",
	ResetOnSpawn = false,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
do
	local parented = false
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h then
			parented = pcall(function()
				gui.Parent = h
			end)
		end
	end
	if not parented then
		parented = pcall(function()
			gui.Parent = game:GetService("CoreGui")
		end)
	end
	if not parented then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
end

local WIDTH = 340
local camera = Workspace.CurrentCamera
local height = math.clamp((camera and camera.ViewportSize.Y or 720) - 80, 320, 560)

local main = new("Frame", {
	BackgroundColor3 = C.Panel,
	Position = UDim2.new(0, 24, 0.5, -height / 2),
	Size = UDim2.fromOffset(WIDTH, height),
	Parent = gui,
}, { corner(12), stroke(C.Border) })

local titleBar = new("Frame", {
	BackgroundColor3 = C.Bg,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 36),
	Parent = main,
}, { corner(12) })
-- square off the bottom corners of the rounded title bar
local titleCover = new("Frame", {
	BackgroundColor3 = C.Bg,
	BorderSizePixel = 0,
	Position = UDim2.new(0, 0, 1, -12),
	Size = UDim2.new(1, 0, 0, 12),
	Parent = titleBar,
})
label({
	Text = "Sparkle Dig Farm",
	Font = FONT_B,
	TextSize = 15,
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -190, 1, 0),
	Parent = titleBar,
})
label({
	Text = "RightShift hides",
	TextSize = 11,
	TextColor3 = C.Faint,
	TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.new(1, -176, 0, 0),
	Size = UDim2.fromOffset(110, 36),
	Parent = titleBar,
})
local closeBtn = button({
	Text = "✕",
	BackgroundTransparency = 1,
	TextColor3 = C.Muted,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -6, 0.5, 0),
	Size = UDim2.fromOffset(28, 28),
	Parent = titleBar,
})
local minBtn = button({
	Text = "–",
	BackgroundTransparency = 1,
	TextColor3 = C.Muted,
	TextSize = 16,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -36, 0.5, 0),
	Size = UDim2.fromOffset(28, 28),
	Parent = titleBar,
})

-- dragging
do
	local dragging, dragStart, startPos
	connect(titleBar.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end)
	connect(UIS.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	connect(UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

local body = new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 1, -36),
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = C.Border,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Parent = main,
}, { list(Enum.FillDirection.Vertical, 8), pad(12, 12) })

local order = 0
local function nextOrder()
	order += 1
	return order
end

--// window: widgets

local function toggleRow(text, initial, onChange)
	local value = initial
	local row = button({
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = nextOrder(),
		Parent = body,
	}, { corner(8) })
	label({ Text = text, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -64, 1, 0), Parent = row })
	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(36, 20),
		Parent = row,
	}, { corner(10) })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Text,
		Size = UDim2.fromOffset(16, 16),
		Parent = track,
	}, { corner(8) })
	local function render()
		track.BackgroundColor3 = value and C.Accent or C.Border
		knob.Position = value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
	end
	render()
	connect(row.Activated, function()
		value = not value
		render()
		onChange(value)
	end)
end

local function segmentedRow(title, options, selected, onChange)
	local holder = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
		LayoutOrder = nextOrder(),
		Parent = body,
	})
	label({ Text = title, TextSize = 12, TextColor3 = C.Muted, Parent = holder })
	local row = new("Frame", {
		BackgroundColor3 = C.Input,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = holder,
	}, { corner(8), pad(3, 3), list(Enum.FillDirection.Horizontal, 4) })
	local buttons = {}
	local function render()
		for i, b in ipairs(buttons) do
			b.BackgroundColor3 = i == selected and C.Accent or C.Input
			b.TextColor3 = i == selected and C.Text or C.Muted
		end
	end
	for i, name in ipairs(options) do
		buttons[i] = button({
			Text = name,
			TextSize = 12,
			AutoButtonColor = false,
			BackgroundColor3 = C.Input,
			Size = UDim2.new(1 / #options, -3, 1, 0),
			LayoutOrder = i,
			Parent = row,
		}, { corner(6) })
		connect(buttons[i].Activated, function()
			selected = i
			render()
			onChange(i)
		end)
	end
	render()
end

local function sliderRow(title, min, max, initial, unit, onChange)
	local holder = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = nextOrder(),
		Parent = body,
	})
	label({ Text = title, TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(0.6, 0, 0, 16), Parent = holder })
	local valueLabel = label({
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.6, 0),
		Size = UDim2.new(0.4, 0, 0, 16),
		Parent = holder,
	})
	local track = new("Frame", {
		BackgroundColor3 = C.Input,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = holder,
	}, { corner(4) })
	local fill = new("Frame", { BackgroundColor3 = C.Accent, Size = UDim2.fromScale(0, 1), Parent = track }, { corner(4) })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = C.Text,
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		Parent = track,
	}, { corner(7) })
	local hit = new("TextButton", {
		Text = "",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 24),
		Parent = holder,
	})

	local function set(value)
		value = math.clamp(math.floor(value + 0.5), min, max)
		local alpha = (value - min) / (max - min)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = value .. unit
		return value
	end
	local current = set(initial)
	local function fromInput(input)
		local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local value = set(min + alpha * (max - min))
		if value ~= current then
			current = value
			onChange(value)
		end
	end
	local dragging = false
	connect(hit.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			fromInput(input)
		end
	end)
	connect(UIS.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			fromInput(input)
		end
	end)
	connect(UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	return holder
end

--// window: layout

local statusCard = new("Frame", {
	BackgroundColor3 = C.Card,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(10), pad(10, 12) })
local statusDot = new("Frame", {
	BackgroundColor3 = C.Faint,
	Position = UDim2.fromOffset(0, 3),
	Size = UDim2.fromOffset(10, 10),
	Parent = statusCard,
}, { corner(5) })
local statusText = label({
	Text = State.status,
	Font = FONT_B,
	TextWrapped = true,
	Position = UDim2.fromOffset(18, 0),
	Size = UDim2.new(1, -18, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = statusCard,
})

local startBtn = button({
	Text = "Start farming",
	TextSize = 14,
	TextColor3 = C.Bg,
	BackgroundColor3 = C.Up,
	Size = UDim2.new(1, 0, 0, 40),
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(10) })
connect(startBtn.Activated, function()
	setEnabled(not State.enabled)
end)

section(body, nextOrder(), "OPTIONS")
toggleRow("Dig sparkle spots", State.dig, function(value)
	State.dig = value
end)
toggleRow("Carry treasure to my ship", State.carry, function(value)
	State.carry = value
end)
toggleRow("Anti-AFK", State.antiAfk, function(value)
	State.antiAfk = value
end)
segmentedRow("Travel (spots, ship, enemies)", { "Smooth glide", "Instant teleport" }, State.smooth and 1 or 2, function(index)
	State.smooth = index == 1
end)
local speedRow = sliderRow("Glide speed", 30, 250, State.speed, " studs/s", function(value)
	State.speed = value
end)

section(body, nextOrder(), "COMBAT")
toggleRow("Auto attack enemies", State.attack, function(value)
	State.attack = value
end)
toggleRow("Use weapon ability", State.ability, function(value)
	State.ability = value
end)
toggleRow("Chase enemies", State.chase, function(value)
	State.chase = value
end)
local chaseRow = sliderRow("Chase radius", 20, 150, State.chaseRadius, " studs", function(value)
	State.chaseRadius = value
end)
segmentedRow("Draw first", { "Melee", "Ranged" }, State.weaponSlot == "Melee" and 1 or 2, function(index)
	State.weaponSlot = index == 1 and "Melee" or "Ranged"
end)

section(body, nextOrder(), "STATUS")
local infoCard = new("Frame", {
	BackgroundColor3 = C.Card,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(10), pad(10, 12), list(Enum.FillDirection.Vertical, 5) })

local function infoRow(caption, rowOrder)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = rowOrder, Parent = infoCard })
	label({ Text = caption, TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(0.22, 0, 1, 0), Parent = row })
	return label({
		Text = "-",
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.22, 0),
		Size = UDim2.fromScale(0.78, 1),
		Parent = row,
	})
end
local spotsInfo = infoRow("Spots", 1)
local shovelInfo = infoRow("Shovel", 2)
local carryInfo = infoRow("Carrying", 3)
local shipInfo = infoRow("Ship", 4)
local cargoInfo = infoRow("Cargo", 5)
local weaponInfo = infoRow("Weapon", 6)
local targetInfo = infoRow("Target", 7)

section(body, nextOrder(), "SESSION")
local statsGrid = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = nextOrder(),
	Parent = body,
}, {
	new("UIGridLayout", {
		CellSize = UDim2.new(0.25, -5, 0, 44),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local function statCard(caption, color, cardOrder)
	local card = new("Frame", { BackgroundColor3 = C.Card, LayoutOrder = cardOrder, Parent = statsGrid }, { corner(8) })
	label({
		Text = caption,
		TextSize = 10,
		Font = FONT_B,
		TextColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 12),
		Parent = card,
	})
	return label({
		Text = "0",
		TextSize = 16,
		Font = FONT_B,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = card,
	})
end
local digsStat = statCard("DIGS", C.Text, 1)
local treasureStat = statCard("TREASURE", C.Gold, 2)
local junkStat = statCard("OLD COINS", C.Text, 3)
local nothingStat = statCard("NOTHING", C.Muted, 4)
local warmStat = statCard("WARM", C.Warn, 5)
local invalidStat = statCard("INVALID", C.Down, 6)
local storedStat = statCard("STOWED", C.Up, 7)
local killsStat = statCard("KILLS", C.Gold, 8)
local swingsStat = statCard("SWINGS", C.Text, 9)
local abilitiesStat = statCard("ABILITY", C.Text, 10)
local hitsStat = statCard("HITS", C.Up, 11)
local timeStat = statCard("TIME", C.Text, 12)

section(body, nextOrder(), "TOOLS")
local goRow = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 32),
	LayoutOrder = nextOrder(),
	Parent = body,
}, { list(Enum.FillDirection.Horizontal, 6) })
local gotoBtn = button({
	Text = "Go to nearest spot",
	Size = UDim2.new(0.5, -3, 1, 0),
	LayoutOrder = 1,
	Parent = goRow,
}, { corner(8) })
local shipBtn = button({
	Text = "Go to my ship",
	Size = UDim2.new(0.5, -3, 1, 0),
	LayoutOrder = 2,
	Parent = goRow,
}, { corner(8) })
local function requestMove(kind)
	if State.enabled then
		log("Stop the farm before moving by hand", "warn")
	else
		State.request = kind
	end
end
connect(gotoBtn.Activated, function()
	requestMove("goto")
end)
connect(shipBtn.Activated, function()
	requestMove("ship")
end)

local shipRow = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 32),
	LayoutOrder = nextOrder(),
	Parent = body,
}, { list(Enum.FillDirection.Horizontal, 6) })
local saveShipBtn = button({
	Text = "Use the ship I'm on",
	Size = UDim2.new(0.62, -3, 1, 0),
	LayoutOrder = 1,
	Parent = shipRow,
}, { corner(8) })
local clearShipBtn = button({
	Text = "Clear",
	Size = UDim2.new(0.38, -3, 1, 0),
	LayoutOrder = 2,
	Parent = shipRow,
}, { corner(8) })
connect(saveShipBtn.Activated, saveShip)
connect(clearShipBtn.Activated, function()
	State.shipId = nil
	nextShipScan = 0
	log("Ship cleared, back to auto-detect", "dim")
end)

section(body, nextOrder(), "LOG")
local logCard = new("Frame", {
	BackgroundColor3 = C.Input,
	ClipsDescendants = true,
	Size = UDim2.new(1, 0, 0, 104),
	LayoutOrder = nextOrder(),
	Parent = body,
}, { corner(8), stroke(C.Border) })
local logText = label({
	Text = "",
	RichText = true,
	Font = FONT_M,
	TextSize = 11,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Bottom,
	Position = UDim2.fromOffset(8, 4),
	Size = UDim2.new(1, -16, 1, -8),
	Parent = logCard,
})

--// window: behaviour

local minimized = false
local fullSize = main.Size
connect(minBtn.Activated, function()
	minimized = not minimized
	body.Visible = not minimized
	titleCover.Visible = not minimized
	main.Size = minimized and UDim2.fromOffset(WIDTH, 36) or fullSize
	minBtn.Text = minimized and "+" or "–"
end)

local function destroy()
	if not alive then
		return
	end
	alive = false
	State.enabled = false
	releaseHold()
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	if unhook then
		pcall(unhook)
	end
	if unhookWeapon then
		pcall(unhookWeapon)
	end
	pcall(function()
		gui:Destroy()
	end)
	if env.__DigFarmUnload == destroy then
		env.__DigFarmUnload = nil
	end
end
env.__DigFarmUnload = destroy
connect(closeBtn.Activated, destroy)

connect(UIS.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

local function clock(seconds)
	seconds = math.floor(seconds)
	return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

local lastLogVersion = -1

local function refresh()
	statusText.Text = State.status
	statusDot.BackgroundColor3 = KIND_COLOR[State.statusKind] or C.Faint
	startBtn.Text = State.enabled and "Stop farming" or "Start farming"
	startBtn.BackgroundColor3 = State.enabled and C.Down or C.Up
	speedRow.Visible = State.smooth
	chaseRow.Visible = State.chase

	if State.spotCount == 0 then
		spotsInfo.Text = "none visible"
	else
		spotsInfo.Text = string.format(
			"%d visible, %d ready%s",
			State.spotCount,
			State.readyCount,
			State.nearest and string.format(", nearest %d studs", round(State.nearest)) or ""
		)
	end
	shovelInfo.Text = State.shovel
	shovelInfo.TextColor3 = State.shovel == "missing" and C.Down or C.Text
	carryInfo.Text = State.carrying and "a treasure" or "nothing"
	shipInfo.Text = State.shipText
	cargoInfo.Text = State.cargo
	weaponInfo.Text = State.weapon
	weaponInfo.TextColor3 = State.weapon == "unavailable" and C.Down or C.Text
	targetInfo.Text = State.attack and State.target or "auto attack is off"

	digsStat.Text = tostring(State.digs)
	treasureStat.Text = tostring(State.treasure)
	junkStat.Text = tostring(State.junk)
	nothingStat.Text = tostring(State.nothing)
	warmStat.Text = tostring(State.warm)
	invalidStat.Text = tostring(State.invalid)
	storedStat.Text = tostring(State.stored)
	killsStat.Text = tostring(State.kills)
	swingsStat.Text = tostring(State.swings)
	abilitiesStat.Text = tostring(State.abilities)
	hitsStat.Text = tostring(State.hits)
	timeStat.Text = clock(State.runTotal + (State.runStart and os.clock() - State.runStart or 0))

	if State.logVersion ~= lastLogVersion then
		lastLogVersion = State.logVersion
		local lines = {}
		for i = math.max(1, #State.log - 7), #State.log do
			local entry = State.log[i]
			table.insert(lines, string.format('<font color="#%s">%s</font>', (KIND_COLOR[entry.kind] or C.Muted):ToHex(), esc(entry.text)))
		end
		logText.Text = table.concat(lines, "\n")
	end
end

task.spawn(function()
	restoreIdentity()
	local lastError
	while alive do
		restoreIdentity()
		local ok, err = pcall(refresh)
		if not ok and tostring(err) ~= lastError then
			lastError = tostring(err)
			warn("[Sparkle Dig Farm] window: " .. lastError)
		end
		task.wait(0.2)
	end
end)

log(DigController and "Ready. Stand near a sparkle spot or just press Start." or "Ready (running without DigController).", "dim")
