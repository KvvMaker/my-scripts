--// Limited Roller: auto roll, sell, upgrade, claim and rebirth for the classic-limiteds roll game (executor LocalScript)
--// Everything goes through the same remotes the game's own controllers call (RequestRoll, SellAll, BuySkill, ClaimQuest, ...),
--// so every action is still checked by the server. RightShift hides/shows the window. Re-executing replaces the previous copy.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local SETTINGS_FILE = "LimitedRoller_settings.json"
local SYNC_EVERY = 40 -- seconds between full GetInventory reads while running; roll and shop replies keep the mirror current in between
local HUD_SYNC_EVERY = 15 -- seconds between asking the game's own UI to refresh itself (it never sees rolls made from here)
local SHOP_ATTEMPTS = 3 -- purchase tries per category per pass, successes not counted
local REBIRTH_RETRY = 60 -- seconds before auto rebirth tries again after the server said no

--// environment -----------------------------------------------------------------

local env = (getgenv and getgenv()) or _G
if env.__LimitedRollerUnload then
	pcall(env.__LimitedRollerUnload)
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

--// helpers ---------------------------------------------------------------------

local function round(n)
	return math.floor(n + 0.5)
end

local function now()
	return os.clock()
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function abbr(n)
	n = tonumber(n) or 0
	if n ~= n then
		return "?"
	end
	local sign = n < 0 and "-" or ""
	n = math.abs(n)
	if n < 1000 then
		return sign .. (n == math.floor(n) and string.format("%d", n) or string.format("%.1f", n))
	end
	local i = 0
	while n >= 1000 and i < #SUFFIX - 1 do
		n /= 1000
		i += 1
	end
	local text = string.format(n >= 100 and "%.0f" or n >= 10 and "%.1f" or "%.2f", n)
	if text:find(".", 1, true) then
		text = text:gsub("0+$", ""):gsub("%.$", "")
	end
	return sign .. text .. SUFFIX[i + 1]
end

local function esc(s)
	return (tostring(s):gsub("[<>&]", ""))
end

local function clock(seconds)
	seconds = math.floor(seconds)
	return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

-- pcall that gives back the first two results, or nil when the call failed or fn isn't a function
local function safe(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, a, b = pcall(fn, ...)
	if ok then
		return a, b
	end
	return nil
end

local function dump(value, depth, seen)
	if type(value) == "string" then
		return string.format("%q", value:sub(1, 60))
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	depth = depth or 0
	seen = seen or {}
	if seen[value] then
		return "<cycle>"
	end
	if depth >= 3 then
		return "{...}"
	end
	seen[value] = true
	local parts, n = {}, 0
	for k, v in pairs(value) do
		n += 1
		if n > 14 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, tostring(k) .. "=" .. dump(v, depth + 1, seen))
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ", ") .. "}"
end

--// settings --------------------------------------------------------------------

local Cfg = {
	-- rolling
	roll = true,
	rollDelay = 0.2, -- seconds between rolls
	maxOpen = true, -- open as many cases per roll as the rebirths allow
	caseMode = "fixed", -- "fixed": the case picked in the window / in the game, "best": the best case the coins can pay for
	caseId = nil,
	fallback = true, -- roll the free case while the picked one can't be paid for
	bestZone = false, -- stand in the zone with the most luck
	-- selling (the same options as the game's Sell window)
	sellAuto = false,
	sellEvery = 45,
	sellKeep = true, -- never sell mutated items
	sellAll = false, -- sell every copy instead of the extras; never saved, like auto rebirth
	sellRarities = nil, -- set of rarity names to sell; saved as text
	-- shopping
	buySkills = true,
	buyGemUpgrades = true,
	buyMastery = true,
	buyCases = true,
	buySlots = false,
	superPotion = false,
	-- claiming
	claimDaily = true,
	claimGifts = true,
	claimCollection = true,
	claimGoals = true,
	claimQuests = true,
	-- misc
	equipBest = false,
	collectVault = false,
	autoRebirth = false, -- never saved: it has to be switched on again every time
	hudSync = true,
	antiAfk = true,
}

-- what gets written to disk, with the type each value must have when it is read back
local SAVED = {
	roll = "boolean",
	rollDelay = "number",
	maxOpen = "boolean",
	caseMode = "string",
	caseId = "string",
	fallback = "boolean",
	bestZone = "boolean",
	sellAuto = "boolean",
	sellEvery = "number",
	sellKeep = "boolean",
	buySkills = "boolean",
	buyGemUpgrades = "boolean",
	buyMastery = "boolean",
	buyCases = "boolean",
	buySlots = "boolean",
	superPotion = "boolean",
	claimDaily = "boolean",
	claimGifts = "boolean",
	claimCollection = "boolean",
	claimGoals = "boolean",
	claimQuests = "boolean",
	equipBest = "boolean",
	collectVault = "boolean",
	hudSync = "boolean",
	antiAfk = "boolean",
}

local Persist = { dirty = false, at = 0 }

function Persist.touch()
	Persist.dirty = true
	Persist.at = now()
end

function Persist.load()
	if not (isfile and readfile) then
		return
	end
	local ok, raw = pcall(function()
		if isfile(SETTINGS_FILE) then
			return readfile(SETTINGS_FILE)
		end
		return nil
	end)
	if not ok or type(raw) ~= "string" or raw == "" then
		return
	end
	local decoded, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not decoded or type(data) ~= "table" then
		return
	end
	for key, kind in pairs(SAVED) do
		if type(data[key]) == kind then
			Cfg[key] = data[key]
		end
	end
	if type(data.sellRarities) == "string" then
		Cfg.sellRarities = {}
		for name in data.sellRarities:gmatch("[^,]+") do
			Cfg.sellRarities[name] = true
		end
	end
	Cfg.rollDelay = math.clamp(Cfg.rollDelay, 0.05, 3)
	Cfg.sellEvery = math.clamp(Cfg.sellEvery, 10, 600)
	if Cfg.caseMode ~= "best" then
		Cfg.caseMode = "fixed"
	end
end

function Persist.flush()
	if not (writefile and Persist.dirty) then
		return
	end
	Persist.dirty = false
	local snapshot = {}
	for key in pairs(SAVED) do
		snapshot[key] = Cfg[key]
	end
	if Cfg.sellRarities then
		local names = {}
		for name, on in pairs(Cfg.sellRarities) do
			if on then
				table.insert(names, name)
			end
		end
		table.sort(names)
		snapshot.sellRarities = table.concat(names, ",")
	end
	pcall(function()
		writefile(SETTINGS_FILE, HttpService:JSONEncode(snapshot))
	end)
end

Persist.load()

--// state -----------------------------------------------------------------------
-- Plain values only. The engine thread writes them, the window loop reads them.

-- session numbers and the log
local S = {
	enabled = false,
	activity = "Idle",
	activityKind = "idle",
	rolls = 0,
	items = 0,
	found = 0,
	sold = 0,
	soldFor = 0,
	fees = 0,
	bought = 0,
	claims = 0,
	rebirths = 0,
	vault = 0,
	best = nil, -- rarest item id rolled this session
	byRarity = {},
	rarityRep = {}, -- one item of each rarity seen, to put the rarities in order
	runTotal = 0,
	runStart = nil,
	log = {},
	logVersion = 0,
}

-- mirror of the game's own client state (`u2` in its ClientController): same field names, so the game's helpers accept it
local Game = {
	ready = false,
	Items = {},
	Discovered = {},
	Recent = {},
	Worn = {},
	Locked = {},
	Skills = {},
	Achievements = {},
	GoalsReady = {},
	GemUpgrades = {},
	Mastery = {},
	Perks = {},
	Collection = {},
	Settings = {},
	Areas = { Rolls = {}, Attuned = {} },
	Stats = {},
	Coins = 0,
	Gems = 0,
	TotalRolls = 0,
	TotalSold = 0,
	Rebirths = 0,
	CaseLevel = 1,
	PotionUntil = 0,
	SuperPotionUntil = 0,
	InventoryValue = 0,
	RebirthValue = 0,
	BaseBank = 0,
	VaultCap = 0,
	BankFull = false,
	DisplayRate = 0,
	GemRate = 0,
	DisplaySlots = 0,
	LockSlots = 0,
}

-- small mutable bits of the rolling / selling / claiming logic
local Roll = { fails = 0, fellBack = false, home = nil, caseBlockedUntil = 0, openRetryAt = 0, collected = false, lastTeleport = -1e9 }
local Sell = {}
local Claims = { goalStyle = nil, data = nil }
local Busy = {}

-- numbers worked out from the mirror, refreshed by the window loop (see "derived values")
local Derived = {
	dirty = true, -- the inventory changed: value and rebirth value need counting again
	rankName = "-",
	rankColor = nil,
	zone = "Hub",
	luck = 1,
	bestZone = nil,
	bestLuck = 1,
	rebirthNeed = 0,
}

local function log(text, kind)
	table.insert(S.log, { text = text, kind = kind or "dim" })
	if #S.log > 60 then
		table.remove(S.log, 1)
	end
	S.logVersion += 1
end

local logGate = {}
local function logOnce(key, text, kind, every)
	local t = now()
	if (logGate[key] or -1e9) + (every or 30) <= t then
		logGate[key] = t
		log(text, kind)
	end
end

local function setActivity(text, kind)
	S.activity = text
	S.activityKind = kind or "ok"
end

-- runs fn unless the same named job is already running; the flag is always cleared, even when fn errors
local function guard(name, fn, ...)
	if Busy[name] then
		return nil
	end
	Busy[name] = true
	local ok, result = pcall(fn, ...)
	Busy[name] = nil
	if not ok then
		error(result, 0)
	end
	return result
end

--// game hooks ------------------------------------------------------------------

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
local Shared = ReplicatedStorage:WaitForChild("Shared", 20)
if not (Remotes and Shared and Remotes:FindFirstChild("RequestRoll")) then
	warn("[Limited Roller] the game's Remotes/Shared folders were not found: is this the right game?")
	return
end

local R = setmetatable({}, {
	__index = function(t, name)
		local obj = Remotes:FindFirstChild(name)
		if obj then
			rawset(t, name, obj)
		end
		return obj
	end,
})

-- the game's own modules: item values, rarity, configs, and a few controllers whose pure helpers know what is affordable
local Mod = {}
do
	local scripts = LocalPlayer:WaitForChild("PlayerScripts")
	local function load(parent, name)
		local inst = parent:FindFirstChild(name) or parent:WaitForChild(name, 4)
		if not inst then
			return nil
		end
		local ok, module = pcall(require, inst)
		restoreIdentity()
		if ok and type(module) == "table" then
			return module
		end
		return nil
	end
	Mod.Odds = load(Shared, "OddsCalculator")
	Mod.Values = load(Shared, "ItemValues")
	Mod.Rarity = load(Shared, "RarityConfig")
	Mod.Skill = load(Shared, "SkillConfig")
	Mod.Prog = load(Shared, "ProgressionConfig")
	Mod.Case = load(Shared, "CaseConfig")
	Mod.Gem = load(Shared, "GemConfig")
	Mod.Coin = load(Shared, "CoinShopConfig")
	Mod.Equip = load(Shared, "EquipConfig")
	Mod.Rewards = load(Shared, "RewardsConfig")
	Mod.Upgrades = load(scripts, "UpgradesController")
	Mod.CasesUI = load(scripts, "CasesController")
	Mod.GemsUI = load(scripts, "GemsController")
	Mod.RewardsUI = load(scripts, "RewardsController")
	Mod.World = load(scripts, "WorldController")
end

function Mod.item(id)
	return safe(Mod.Odds and Mod.Odds.GetItem, id)
end

function Mod.isGem(id)
	return safe(Mod.Odds and Mod.Odds.IsGemItem, id) == true
end

function Mod.variant(id)
	return safe(Mod.Odds and Mod.Odds.GetVariant, id)
end

function Mod.rarer(a, b)
	return safe(Mod.Odds and Mod.Odds.IsRarer, a, b) == true
end

function Mod.value(id)
	local value = safe(Mod.Values and Mod.Values.Get, id)
	return type(value) == "number" and value or 0
end

function Mod.name(id)
	local item = Mod.item(id)
	return item and item.Name and tostring(item.Name) or tostring(id)
end

function Mod.rarityName(id)
	local item = Mod.item(id)
	return item and item.Rarity ~= nil and tostring(item.Rarity) or "?"
end

-- rarity names in the game's order, lowest first (the Sell window lists them like this)
function Mod.rarities()
	return Mod.Rarity and type(Mod.Rarity.Order) == "table" and Mod.Rarity.Order or {}
end

-- how far an item is mutated, 0 for a plain one (the game's own `tierOf`)
function Mod.tier(id)
	local variant = Mod.variant(id)
	return type(variant) == "table" and tonumber(variant.Tier) or 0
end

-- coins one copy sells for, priced the way the Backpack does it
function Mod.sellPrice(item)
	local price = tonumber(safe(Mod.Rarity and Mod.Rarity.GetItemSellPrice, item))
	return price and math.floor(price) or 0
end

-- worn by the player: the game's own check when it can be asked, else a look at the mirror
function Mod.isWorn(id)
	local worn = safe(Mod.Equip and Mod.Equip.IsWorn, Game, id)
	if worn ~= nil then
		return worn == true
	end
	if Game.Equipped == id then
		return true
	end
	for _, wornId in ipairs(Game.Worn or {}) do
		if wornId == id then
			return true
		end
	end
	return false
end

function Mod.cases()
	return Mod.Case and type(Mod.Case.Cases) == "table" and Mod.Case.Cases or {}
end

function Mod.caseIndex(id)
	for i, case in ipairs(Mod.cases()) do
		if case.Id == id then
			return i
		end
	end
	return nil
end

-- coins one roll of this case costs, the same call the game's HUD makes
function Mod.caseFee(case)
	if not case then
		return 0
	end
	local fee = safe(Mod.Case and Mod.Case.GetOpenFee, case.Id, Game.Stats and Game.Stats.FeeMultiplier)
	return tonumber(fee) or tonumber(case.OpenFee) or 0
end

function Mod.zoneName(id)
	local zone = safe(Mod.Prog and Mod.Prog.GetZone, id)
	return type(zone) == "table" and zone.Name and tostring(zone.Name) or tostring(id)
end

-- result of a pure helper in a game module (true / false), or nil when it isn't there or errored
function Mod.gate(module, name, ...)
	local m = Mod[module]
	local fn = m and m[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	restoreIdentity()
	if not ok then
		return nil
	end
	return result and true or false
end

local ID_KEYS = { "Id", "id", "ID", "Key" }

local function entryId(entry)
	for _, key in ipairs(ID_KEYS) do
		if type(entry[key]) == "string" then
			return entry[key]
		end
	end
	return nil
end

-- The config modules keep their entries in a table somewhere under a name I haven't seen: a list of { Id = ... } or a
-- dictionary keyed by id. Take the table whose entries the module's own getter (GetNode / GetUpgrade / GetMastery)
-- recognises, keep only those, and hand them back as a list in the config's order, every entry with an `Id`.
function Mod.nodes(cfg, getterName)
	if type(cfg) ~= "table" then
		return {}
	end
	local getter = type(cfg[getterName]) == "function" and cfg[getterName] or nil
	local best, bestCount
	for _, value in pairs(cfg) do
		if type(value) == "table" then
			local found, ok = {}, true
			for key, entry in pairs(value) do
				local own = type(entry) == "table" and entryId(entry) or nil
				if type(entry) ~= "table" or not (own or (getter and type(key) == "string")) then
					ok = false
					break
				end
				-- the entry's own id, or (for a dictionary) its key, whichever the module's getter knows
				local id
				if not getter then
					id = own
				elseif own and safe(getter, own) ~= nil then
					id = own
				elseif type(key) == "string" and safe(getter, key) ~= nil then
					id = key
				end
				if id then
					table.insert(found, { key = key, id = id, entry = entry })
				end
			end
			if ok and #found > 0 and #found > (bestCount or 0) then
				best, bestCount = found, #found
			end
		end
	end
	local list = {}
	if not best then
		return list
	end
	table.sort(best, function(a, b)
		if type(a.key) == "number" and type(b.key) == "number" then
			return a.key < b.key
		end
		local ao, bo = tonumber(a.entry.Order or a.entry.Index or a.entry.Tier) or 0, tonumber(b.entry.Order or b.entry.Index or b.entry.Tier) or 0
		if ao ~= bo then
			return ao < bo
		end
		return a.id < b.id
	end)
	for _, item in ipairs(best) do
		local node = item.entry
		if node.Id ~= item.id then
			node = table.clone(node)
			node.Id = item.id
		end
		table.insert(list, node)
	end
	return list
end

local Net = { needSync = false, syncedAt = 0, hudAt = -1e9, keys = "" }

-- RemoteFunction call the way the game's own `invoke` does it. Returns the reply table when the server said Ok;
-- otherwise nil, the reason, and the raw reply (nil when there was no usable reply at all).
function Net.call(name, ...)
	local obj = R[name]
	if not obj then
		return nil, "missing remote " .. name
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return obj:InvokeServer(table.unpack(args, 1, args.n))
	end)
	restoreIdentity()
	if not ok then
		return nil, "no reply"
	end
	if type(result) ~= "table" then
		return nil, "unreadable reply"
	end
	if result.Ok then
		return result
	end
	return nil, tostring(result.Reason or "refused"), result
end

-- the same read the game does at load and on Resync
function Net.sync()
	local obj = R.GetInventory
	if not obj then
		return false
	end
	local result
	for attempt = 1, 4 do
		local ok, reply = pcall(function()
			return obj:InvokeServer()
		end)
		restoreIdentity()
		if ok and type(reply) == "table" and type(reply.Items) == "table" then
			result = reply
			break
		end
		if not alive then
			return false
		end
		task.wait(math.min(attempt * 0.5, 2))
	end
	if not result then
		return false
	end
	local keys = {}
	for key, value in pairs(result) do
		table.insert(keys, tostring(key))
		if key == "QuestInfo" then
			Game.Quests = value
		else
			Game[key] = value
		end
	end
	table.sort(keys)
	Net.keys = table.concat(keys, ", ")
	Game.Items = Game.Items or {}
	Game.Discovered = Game.Discovered or {}
	Game.Recent = Game.Recent or {}
	Game.Worn = Game.Worn or (Game.Equipped and { Game.Equipped }) or {}
	Game.Locked = Game.Locked or {}
	Game.Skills = Game.Skills or {}
	Game.GoalsReady = Game.GoalsReady or {}
	Game.GemUpgrades = Game.GemUpgrades or {}
	Game.Mastery = Game.Mastery or {}
	Game.Settings = Game.Settings or {}
	Game.Areas = Game.Areas or { Rolls = {}, Attuned = {} }
	Game.Coins = Game.Coins or 0
	Game.Gems = Game.Gems or 0
	Game.Rebirths = Game.Rebirths or 0
	Game.CaseLevel = Game.CaseLevel or 1
	if type(Game.Stats) ~= "table" then
		Game.Stats = safe(Mod.Skill and Mod.Skill.GetStats, Game.Skills, Game.GemUpgrades, Game.Mastery, Game.Perks, Game.Collection) or {}
	end
	Game.ready = true
	Net.syncedAt = now()
	Net.needSync = false
	Derived.dirty = true
	return true
end

-- Rolls made from here never reach the game's own HUD. Firing its Resync handler makes it read the inventory again.
function Net.refreshHud()
	local event = R.Resync
	if event and firesignal then
		Net.hudAt = now() -- our own Resync listener must not answer this one with a second read
		pcall(firesignal, event.OnClientEvent)
		restoreIdentity()
	end
end

--// derived values --------------------------------------------------------------

-- the game's inventoryValue(): everything but gem items, and what a rebirth may take leaves out the locked ones
function Derived.recalc()
	local total, locked = 0, 0
	local lockedSet = Game.Locked or {}
	for id, count in pairs(Game.Items) do
		if type(count) == "number" and count > 0 and Mod.item(id) and not Mod.isGem(id) then
			local value = Mod.value(id) * count
			total += value
			if lockedSet[id] then
				locked += value
			end
		end
	end
	Game.InventoryValue = total
	Game.RebirthValue = total - locked
end

function Derived.boosts()
	return safe(Mod.Prog and Mod.Prog.GetBoosts, Game.PotionUntil, Game.SuperPotionUntil, LocalPlayer)
end

function Derived.luckIn(zoneId, boosts)
	local result = safe(Mod.Prog and Mod.Prog.GetLuck, Game.Stats, Game.InventoryValue, Game.Rebirths, zoneId, boosts, Game.Areas and Game.Areas.Attuned)
	return type(result) == "table" and tonumber(result.Total) or 1
end

-- the zone the character stands in, counted only when it is unlocked (as the game's own luck label does)
function Derived.zoneAt()
	local P = Mod.Prog
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (P and root) then
		return "Hub"
	end
	local zone = safe(P.GetZoneAt, root.Position)
	if type(zone) == "table" and zone.Id and safe(P.IsZoneUnlocked, zone.Id, Game.InventoryValue, Game.Rebirths) then
		return zone.Id
	end
	return "Hub"
end

function Derived.update()
	if Derived.dirty then
		Derived.dirty = false
		Derived.recalc()
	end
	local P = Mod.Prog
	if not P then
		return
	end
	local rank = safe(P.GetRank, Game.InventoryValue)
	if type(rank) == "table" then
		Derived.rankName, Derived.rankColor = tostring(rank.Name), rank.Color
	end
	local boosts = Derived.boosts()
	Derived.zone = Derived.zoneAt()
	Derived.luck = Derived.luckIn(Derived.zone, boosts)
	local bestId, bestLuck = Derived.zone, Derived.luck
	for _, zone in ipairs(P.Zones or {}) do
		if safe(P.IsZoneUnlocked, zone.Id, Game.InventoryValue, Game.Rebirths) then
			local luck = Derived.luckIn(zone.Id, boosts)
			if luck > bestLuck * 1.0001 then
				bestId, bestLuck = zone.Id, luck
			end
		end
	end
	Derived.bestZone, Derived.bestLuck = bestId, bestLuck
	Derived.rebirthNeed = tonumber(safe(P.GetRebirthRequirement, Game.Rebirths or 0)) or 0
end

--// actions ---------------------------------------------------------------------

local Act = {}

function Act.achievements(list)
	if type(list) ~= "table" then
		return
	end
	for _, goal in ipairs(list) do
		if type(goal) == "table" and goal.Id ~= nil then
			Game.GoalsReady[goal.Id] = true
			log("Goal complete: " .. tostring(goal.Name or goal.Id), "gold")
		end
	end
end

--// actions: rolling

function Act.noteItem(id, quantity, isNew)
	if id == nil then
		return
	end
	if type(quantity) == "number" then
		Game.Items[id] = quantity
	end
	S.items += 1
	local rarity = Mod.rarityName(id)
	S.byRarity[rarity] = (S.byRarity[rarity] or 0) + 1
	S.rarityRep[rarity] = S.rarityRep[rarity] or id
	if isNew then
		Game.Discovered[id] = Game.TotalRolls
		S.found += 1
		log("New: " .. Mod.name(id) .. " (" .. rarity .. ")", "gold")
	end
	local variant = Mod.variant(id)
	if variant and variant.Name then
		log("Mutation: " .. Mod.name(id), "gold")
	end
	if S.best == nil or Mod.rarer(id, S.best) then
		S.best = id
	end
	if Game.RarestItemId == nil or Mod.rarer(id, Game.RarestItemId) then
		Game.RarestItemId = id
	end
	table.insert(Game.Recent, 1, id)
	if #Game.Recent > 30 then
		table.remove(Game.Recent)
	end
end

function Act.applyRoll(reply)
	S.rolls += 1
	Game.TotalRolls = tonumber(reply.TotalRolls) or (Game.TotalRolls + 1)
	Game.Coins = reply.Coins or Game.Coins
	Game.Gems = reply.Gems or Game.Gems
	if (reply.OpenCost or 0) > 0 then
		S.fees += reply.OpenCost
	end
	Act.noteItem(reply.ItemId, reply.Quantity, reply.IsNew)
	for _, extra in ipairs(reply.Extras or {}) do
		if type(extra) == "table" then
			Act.noteItem(extra.ItemId, extra.Quantity, extra.IsNew)
		end
	end
	Game.Areas = reply.Areas or Game.Areas
	if reply.Attuned then
		log("Attuned to " .. Mod.zoneName(reply.Attuned) .. ": its luck now works everywhere", "gold")
	end
	if type(reply.FeeMultiplier) == "number" and type(Game.Stats) == "table" then
		Game.Stats.FeeMultiplier = reply.FeeMultiplier
	end
	if type(reply.Ranks) == "table" then
		for _, rank in ipairs(reply.Ranks) do
			if type(rank) == "table" then
				log("Rank up: " .. tostring(rank.Name), "gold")
			end
		end
	end
	Act.achievements(reply.Achievements)
	Derived.dirty = true
end

-- Which case the next roll should use. "fixed" keeps the picked case and drops to the free one while it can't be paid for
-- (back again once ten rolls' worth of coins are there); "best" takes the best unlocked case the coins can carry.
function Act.wantedCase()
	local cases = Mod.cases()
	if #cases == 0 then
		return nil
	end
	local unlocked = math.clamp(tonumber(Game.CaseLevel) or 1, 1, #cases)
	local coins = Game.Coins or 0
	local current = Mod.caseIndex(Game.SelectedCase) or 1
	if Cfg.caseMode == "best" then
		for i = unlocked, 2, -1 do
			if coins >= Mod.caseFee(cases[i]) * (i == current and 3 or 25) then
				return cases[i]
			end
		end
		return cases[1]
	end
	local home
	if Cfg.caseId and Mod.caseIndex(Cfg.caseId) then
		home = Mod.caseIndex(Cfg.caseId)
	elseif Roll.fellBack and Roll.home then
		home = Roll.home
	else
		home = current
	end
	home = math.min(home, unlocked)
	Roll.home = home
	if home <= 1 or not Cfg.fallback then
		return cases[home]
	end
	local fee = Mod.caseFee(cases[home])
	if Roll.fellBack then
		if coins >= fee * 10 then
			Roll.fellBack = false
			return cases[home]
		end
		return cases[1]
	end
	if coins < fee then
		Roll.fellBack = true
		return cases[1]
	end
	return cases[home]
end

function Act.ensureCase(case)
	if not case or case.Id == Game.SelectedCase or now() < Roll.caseBlockedUntil then
		return
	end
	local reply, reason = Net.call("SelectCase", case.Id)
	if reply then
		Game.SelectedCase = reply.SelectedCase or case.Id
		Game.CaseLevel = reply.CaseLevel or Game.CaseLevel
	else
		Roll.caseBlockedUntil = now() + 20
		logOnce("selectcase", "Couldn't switch to " .. tostring(case.Name or case.Id) .. ": " .. tostring(reason), "warn", 20)
	end
end

-- the game lets the player open several cases per roll once rebirths unlock it; this keeps that at the maximum
function Act.ensureOpenAmount()
	local C = Mod.Coin
	if not (Cfg.maxOpen and C) or now() < Roll.openRetryAt then
		return
	end
	local amounts = safe(C.GetUnlockedAmounts, Game.Rebirths or 0)
	local top = type(amounts) == "table" and amounts[#amounts]
	if type(top) ~= "number" then
		return
	end
	local current = safe(C.ClampAmount, Game.Settings.OpenAmount or 1, Game.Rebirths or 0) or Game.Settings.OpenAmount or 1
	if current >= top then
		return
	end
	local reply, reason = Net.call("SetSetting", "OpenAmount", top)
	if reply then
		Game.Settings.OpenAmount = top
		log("Opening " .. top .. " cases per roll", "ok")
	else
		Roll.openRetryAt = now() + 30
		logOnce("openamount", "Couldn't raise the open amount: " .. tostring(reason), "warn", 60)
	end
end

-- One roll. Returns how long to wait before the next one.
function Act.rollOnce()
	local case = Act.wantedCase()
	Act.ensureCase(case)
	Act.ensureOpenAmount()
	-- the game sends Auto = true only while its AUTO button is on, which needs the autoroll upgrade; the server then
	-- also falls back to the free case by itself
	local auto = type(Game.Stats) == "table" and Game.Stats.AutoRoll == true
	local selected = Mod.caseIndex(Game.SelectedCase)
	local caseName = selected and Mod.cases()[selected].Name or "case"
	setActivity("Rolling: " .. tostring(caseName) .. (Roll.fellBack and " (out of coins)" or ""), Roll.fellBack and "warn" or "ok")
	local reply, reason, raw = Net.call("RequestRoll", { Auto = auto })
	if reply then
		Roll.fails = 0
		Act.applyRoll(reply)
		return Cfg.rollDelay
	end
	if raw == nil then
		Roll.fails += 1
		setActivity("No reply from the server (" .. Roll.fails .. ")", "warn")
		logOnce("noreply", "Roll got no reply: " .. tostring(reason), "warn", 15)
		return math.min(0.5 * Roll.fails, 5)
	end
	if raw.NeedCoins then
		local fee = Mod.caseFee(selected and Mod.cases()[selected])
		if selected and selected > 1 and (Cfg.fallback or Cfg.caseMode == "best") then
			-- the balance we had was stale or the fee is higher than we think: believe the server and drop to a cheaper case
			Roll.fellBack = Cfg.caseMode ~= "best"
			Game.Coins = math.min(Game.Coins, math.max(fee - 1, 0))
			return 0.3
		end
		setActivity("Out of coins: waiting for income", "warn")
		logOnce("needcoins", "Out of coins for the " .. tostring(caseName), "warn", 60)
		if now() - Net.syncedAt > 10 then
			Net.sync()
		end
		return 2
	end
	setActivity("Server: " .. tostring(reason), "warn")
	logOnce("rollrefused", "Roll refused: " .. tostring(reason), "warn", 20)
	return math.clamp(tonumber(raw.RetryIn) or 0.5, 0.2, 3)
end

function Act.unlockAuto()
	local reply, reason = Net.call("BuySkill", "autoroll")
	if not reply then
		log("Auto Roll: " .. tostring(reason), "warn")
		return
	end
	Game.Skills[reply.Skill or "autoroll"] = true
	Game.Coins = reply.Coins or Game.Coins
	Game.Gems = reply.Gems or Game.Gems
	Game.Stats = reply.Stats or Game.Stats
	log("Auto Roll unlocked", "ok")
end

--// actions: selling

-- The game's own Sell window (BackpackController) sends `SellAll(lastRarity, { Mode, KeepMutations, Rarities })`. This does the
-- same with the rarities ticked on the Sell tab, and counts what a sale would take the way that window does.

-- rarities to sell, as a set; until the player ticks something it is the three lowest
function Sell.set()
	if not Cfg.sellRarities then
		Cfg.sellRarities = {}
		for i, rarity in ipairs(Mod.rarities()) do
			if i <= 3 then
				Cfg.sellRarities[rarity] = true
			end
		end
	end
	return Cfg.sellRarities
end

-- items, coins and stacks a sale would take: ticked rarities only, never locked or gem items, mutated ones left alone while
-- they're protected, one copy of each kept in "extras" mode, and one copy of anything worn kept in both modes
function Sell.plan()
	local set = Sell.set()
	local items, coins, stacks = 0, 0, 0
	for id, count in pairs(Game.Items) do
		local item = type(count) == "number" and count > 0 and Mod.item(id) or nil
		if item and Game.Locked[id] ~= true and not Mod.isGem(id) and set[item.Rarity] == true and not (Cfg.sellKeep and Mod.tier(id) > 0) then
			local n = Cfg.sellAll and count or count - 1
			if Mod.isWorn(id) then
				n = math.min(n, count - 1)
			end
			if n > 0 then
				items += n
				coins += n * Mod.sellPrice(item)
				stacks += 1
			end
		end
	end
	return items, coins, stacks
end

function Act.applySale(reply)
	if type(reply.Items) == "table" then
		Game.Items = reply.Items
	end
	Game.Coins = reply.Coins or Game.Coins
	local sold, earned = tonumber(reply.Sold) or 0, tonumber(reply.Earned) or 0
	Game.TotalSold = (Game.TotalSold or 0) + sold
	S.sold += sold
	S.soldFor += earned
	Act.achievements(reply.Achievements)
	Derived.dirty = true
	return sold, earned
end

-- `verbose`: a button press, which should hear back even when there is nothing to sell
function Act.sell(verbose)
	return guard("sell", function()
		local ticked, last = {}, nil
		local set = Sell.set()
		for _, rarity in ipairs(Mod.rarities()) do
			if set[rarity] then
				table.insert(ticked, rarity)
				last = rarity
			end
		end
		if not last then
			logOnce("norarity", "Tick at least one rarity to sell (Sell tab)", "warn", 60)
			return
		end
		if Sell.plan() <= 0 then
			if verbose then
				log("Nothing to sell with these settings", "dim")
			end
			return
		end
		setActivity("Selling...")
		local reply, reason = Net.call("SellAll", last, { Mode = Cfg.sellAll and "all" or "extras", KeepMutations = Cfg.sellKeep, Rarities = ticked })
		if not reply then
			logOnce("sellall", "Sell: " .. tostring(reason), "warn", 30)
			return
		end
		local sold, earned = Act.applySale(reply)
		if sold > 0 then
			log(string.format("Sold %s item%s for %s coins", abbr(sold), sold == 1 and "" or "s", abbr(earned)), "ok")
		end
	end)
end

function Act.lockBest()
	local reply, reason = Net.call("LockBest")
	if not reply then
		log("Lock best: " .. tostring(reason), "warn")
		return
	end
	Game.Locked = reply.Locked or Game.Locked
	Game.LockSlots = reply.LockSlots or Game.LockSlots
	Derived.dirty = true
	log(string.format("Locked your best items (%d/%d slots)", reply.Used or 0, Game.LockSlots or 0), "ok")
end

function Act.equipBest()
	local reply, reason = Net.call("EquipBest")
	if not reply then
		logOnce("equipbest", "Wear best: " .. tostring(reason), "warn", 60)
		return
	end
	Game.Equipped = reply.Equipped
	Game.Worn = reply.Worn or Game.Worn
	if reply.Changed then
		log("Now wearing your best items", "ok")
	end
end

--// actions: shopping
-- Categories share one routine: walk the candidates (cheapest first when the price is known), try a few, and leave the ones
-- the server refused alone for a while (longer after every refusal, or sooner once there are clearly more of the currency than
-- at the refusal). `currency` says what a category is paid in, so nothing is asked for that can't be afforded.

local Shop = { cats = {}, order = { "skills", "gems", "mastery", "cases", "slots", "potion" }, lastReason = nil }

local COST_KEYS = { "Cost", "Price", "GemCost", "Gems", "CoinCost", "Coins" }

function Shop.nodeCost(node)
	for _, key in ipairs(COST_KEYS) do
		if type(node[key]) == "number" then
			return node[key]
		end
	end
	return nil
end

-- what a node is paid in: the one it names itself, else the category's
function Shop.currencyOf(cat, node)
	local own = type(node.Currency) == "string" and node.Currency:lower() or nil
	if own == "coins" then
		return "Coins"
	elseif own == "gems" then
		return "Gems"
	end
	return cat.currency
end

-- coins/gems after a purchase reply, the way the game applies them
local function applyFunds(reply)
	Game.Coins = reply.Coins or Game.Coins
	Game.Gems = reply.Gems or Game.Gems
	Game.Stats = reply.Stats or Game.Stats
	Game.DisplayRate = reply.DisplayRate or Game.DisplayRate
	Game.GemRate = reply.GemRate or Game.GemRate
	Act.achievements(reply.Achievements)
	Derived.dirty = true
end

Shop.cats.skills = {
	label = "upgrades",
	cfgKey = "buySkills",
	currency = "Gems", -- "Upgrades now cost gems and are kept forever" (ClientController)
	state = {},
	list = {},
	candidates = function(self)
		return self.list
	end,
	owned = function(_, node)
		return Game.Skills[node.Id] ~= nil and Game.Skills[node.Id] ~= false
	end,
	gate = function()
		return Mod.gate("Upgrades", "HasAffordable", Game)
	end,
	buy = function(_, node)
		local reply, reason = Net.call("BuySkill", node.Id)
		if not reply then
			return false, reason
		end
		Game.Skills[reply.Skill or node.Id] = true
		applyFunds(reply)
		return true, tostring(node.Name or node.Id)
	end,
}

-- GemConfig.GetUpgradeCost(id, level) is the price of the next level, nil once the upgrade is maxed (the game's own shop card
-- reads it that way); `known` tells "maxed" apart from "can't ask"
local function gemCost(node)
	local fn = Mod.Gem and Mod.Gem.GetUpgradeCost
	if type(fn) ~= "function" then
		return nil, false
	end
	local ok, cost = pcall(fn, node.Id, Game.GemUpgrades[node.Id] or 0)
	if not ok then
		return nil, false
	end
	return tonumber(cost), true
end

Shop.cats.gems = {
	label = "gem upgrades",
	cfgKey = "buyGemUpgrades",
	currency = "Gems",
	state = {},
	list = {},
	candidates = function(self)
		return self.list
	end,
	owned = function(_, node)
		local cost, known = gemCost(node)
		if known then
			return cost == nil
		end
		local max = tonumber(node.MaxLevel or node.Max or node.MaxLvl)
		return max ~= nil and (Game.GemUpgrades[node.Id] or 0) >= max
	end,
	cost = function(node)
		return (gemCost(node))
	end,
	buy = function(_, node)
		local reply, reason = Net.call("BuyGemUpgrade", node.Id)
		if not reply then
			return false, reason
		end
		Game.GemUpgrades = reply.GemUpgrades or Game.GemUpgrades
		applyFunds(reply)
		return true, tostring(node.Name or node.Id) .. " " .. tostring(reply.Level or "")
	end,
}

Shop.cats.mastery = {
	label = "mastery",
	cfgKey = "buyMastery",
	currency = "Coins",
	state = {},
	list = {},
	candidates = function(self)
		return self.list
	end,
	owned = function(_, node)
		local max = tonumber(node.MaxLevel or node.Max or node.MaxLvl)
		return max ~= nil and (Game.Mastery[node.Id] or 0) >= max
	end,
	buy = function(_, node)
		local reply, reason = Net.call("BuyMastery", node.Id)
		if not reply then
			return false, reason
		end
		Game.Mastery = reply.Mastery or Game.Mastery
		applyFunds(reply)
		return true, tostring(node.Name or node.Id) .. " " .. tostring(reply.Level or "")
	end,
}

Shop.cats.cases = {
	label = "case",
	cfgKey = "buyCases",
	currency = "Coins",
	state = {},
	candidates = function()
		local cases = Mod.cases()
		local nextCase = cases[(tonumber(Game.CaseLevel) or 1) + 1]
		return nextCase and { nextCase } or {}
	end,
	owned = function()
		return false
	end,
	gate = function()
		return Mod.gate("CasesUI", "HasAffordable", Game)
	end,
	buy = function(_, node)
		local reply, reason = Net.call("BuyCase", node.Id)
		if not reply then
			return false, reason
		end
		Game.CaseLevel = reply.CaseLevel or Game.CaseLevel
		Game.SelectedCase = reply.SelectedCase or Game.SelectedCase
		Game.Coins = reply.Coins or Game.Coins
		Act.achievements(reply.Achievements)
		return true, "the " .. tostring(node.Name or node.Id)
	end,
}

local SLOT_NODE = { Id = "slot", Name = "display slot" }
Shop.cats.slots = {
	label = "display slot",
	cfgKey = "buySlots",
	currency = "Gems",
	state = {},
	candidates = function()
		return { SLOT_NODE }
	end,
	owned = function()
		return false
	end,
	buy = function()
		local reply, reason = Net.call("BuyDisplaySlot")
		if not reply then
			return false, reason
		end
		Game.DisplaySlots = reply.DisplaySlots or Game.DisplaySlots
		applyFunds(reply)
		return true, "a display slot"
	end,
}

-- The Super Luck potion stacks up to GemConfig.SuperPotion.MaxDuration, so it is topped up once under half a minute is left
-- and only when the extra time still fits under the cap.
local POTION_NODE = { Id = "potion", Name = "Super Luck potion" }
Shop.cats.potion = {
	label = "potion",
	cfgKey = "superPotion",
	currency = "Gems",
	state = {},
	candidates = function()
		return { POTION_NODE }
	end,
	owned = function()
		local boosts = Derived.boosts()
		local active = type(boosts) == "table" and (tonumber(boosts.Super) or 1) > 1
		local left = active and tonumber(boosts.SuperLeft) or 0
		local potion = Mod.Gem and Mod.Gem.SuperPotion
		local duration = potion and tonumber(potion.Duration) or 0
		local cap = potion and tonumber(potion.MaxDuration) or math.huge
		return not (left < 30 and left + duration <= cap)
	end,
	cost = function()
		local potion = Mod.Gem and Mod.Gem.SuperPotion
		return potion and tonumber(potion.Cost) or nil
	end,
	buy = function()
		local reply, reason = Net.call("BuySuperPotion")
		if not reply then
			return false, reason
		end
		Game.SuperPotionUntil = reply.SuperPotionUntil or Game.SuperPotionUntil
		Game.Gems = reply.Gems or Game.Gems
		Derived.dirty = true
		return true, "a Super Luck potion"
	end,
}

function Shop.build()
	Shop.cats.skills.list = Mod.nodes(Mod.Skill, "GetNode")
	Shop.cats.gems.list = Mod.nodes(Mod.Gem, "GetUpgrade")
	Shop.cats.mastery.list = Mod.nodes(Mod.Coin, "GetMastery")
end

-- one pass over a category; `manual` ignores the waiting times
function Shop.run(name, manual)
	local cat = Shop.cats[name]
	local nodes = cat:candidates()
	if #nodes == 0 then
		return 0
	end
	if cat.gate and not manual and cat.gate() == false then
		-- the game's own "something to buy" badge says no. Look anyway now and then, in case the badge isn't the whole story.
		if now() - (cat.blindAt or -1e9) < 90 then
			return 0
		end
		cat.blindAt = now()
	end
	-- cheapest first; whatever has no known price keeps the config's order, after the priced ones
	local costOf = cat.cost or Shop.nodeCost
	local order = {}
	for i, node in ipairs(nodes) do
		order[i] = { node = node, cost = costOf(node), index = i }
	end
	table.sort(order, function(a, b)
		local ac, bc = a.cost or math.huge, b.cost or math.huge
		if ac ~= bc then
			return ac < bc
		end
		return a.index < b.index
	end)
	local attempts, bought = 0, 0
	for _, entry in ipairs(order) do
		if attempts >= SHOP_ATTEMPTS or bought >= 8 or not alive then
			break
		end
		local node = entry.node
		if not cat:owned(node) then
			local st = cat.state[node.Id]
			if not st then
				st = { fails = 0, nextTry = 0, funds = 0 }
				cat.state[node.Id] = st
			end
			local currency = Shop.currencyOf(cat, node)
			local funds = currency and (Game[currency] or 0) or math.max(Game.Coins or 0, Game.Gems or 0)
			if st.nextTry > 0 and funds >= st.funds * 1.5 + 1 then
				st.nextTry = 0
			end
			if funds > 0 and not (entry.cost and entry.cost > funds) and (manual or now() >= st.nextTry) then
				attempts += 1
				setActivity("Buying " .. cat.label .. "...")
				local ok, info = cat:buy(node)
				if ok then
					bought += 1
					S.bought += 1
					st.fails, st.nextTry = 0, 0
					log("Bought " .. tostring(info), "ok")
				else
					st.fails += 1
					st.funds = funds
					st.nextTry = now() + math.min(8 * 2 ^ (st.fails - 1), 120)
					Shop.lastReason = cat.label .. ": " .. tostring(info)
				end
			end
		end
	end
	return bought
end

function Shop.runEnabled(manual)
	for _, name in ipairs(Shop.order) do
		if alive and (manual or Cfg[Shop.cats[name].cfgKey]) then
			guard("shop:" .. name, Shop.run, name, manual)
		end
	end
end

--// actions: claiming
-- Daily, gifts, the collection rewards and quests follow what RewardsController and GemsController send. Goals are the one thing
-- here still guessed (AchievementsController hasn't been seen): the claim-all form is tried first, then one call per goal.

-- the whole rewards state: { Ok, Gifts = { { Claimed, ReadyIn } }, Daily = { CanClaim, ... }, Tiers = { [rarity] = { Found,
-- Total, Claimed } }, Collection = { [milestoneId] = true }, Discovered }
function Claims.fetchRewards()
	local obj = R.RewardsGetState
	if not obj then
		return nil
	end
	local ok, data = pcall(function()
		return obj:InvokeServer()
	end)
	restoreIdentity()
	if ok and type(data) == "table" and data.Ok then
		Claims.data = data
		return data
	end
	logOnce("rewardsstate", "Couldn't read the rewards state", "warn", 120)
	return nil
end

-- a rewards claim answers { Ok, Given = "text", ...the new rewards state }
local function claimed(reply, what)
	S.claims += 1
	Claims.data = reply
	Net.needSync = true -- the coins/gems it paid out show up in the next read
	log(what .. ": " .. tostring(reply.Given or "claimed"), "ok")
end

function Claims.daily(data)
	local daily = data.Daily
	if type(daily) ~= "table" or daily.CanClaim ~= true then
		return
	end
	local reply, reason = Net.call("ClaimDaily")
	if reply then
		claimed(reply, "Daily reward")
	else
		logOnce("daily", "Daily reward: " .. tostring(reason), "warn", 120)
	end
end

function Claims.gifts(data)
	for index, gift in ipairs(type(data.Gifts) == "table" and data.Gifts or {}) do
		if not alive then
			return
		end
		-- ReadyIn counts down from the moment the state was read, which was just now
		if type(gift) == "table" and not gift.Claimed and (tonumber(gift.ReadyIn) or math.huge) <= 0 then
			local reply, reason = Net.call("ClaimGift", index)
			if reply then
				claimed(reply, "Gift " .. index)
			else
				logOnce("gift" .. index, "Gift " .. index .. ": " .. tostring(reason), "warn", 120)
			end
		end
	end
end

-- "All <rarity> items" rewards (claimed by rarity name) and "Find N items" milestones (claimed by milestone id)
function Claims.collection(data)
	local keys = {}
	local tiers = type(data.Tiers) == "table" and data.Tiers or {}
	local names = {}
	for rarity in pairs(tiers) do
		table.insert(names, tostring(rarity))
	end
	table.sort(names)
	for _, rarity in ipairs(names) do
		local tier = tiers[rarity]
		if type(tier) == "table" and not tier.Claimed and (tonumber(tier.Total) or 0) > 0 and (tonumber(tier.Found) or 0) >= tier.Total then
			table.insert(keys, rarity)
		end
	end
	local done = type(data.Collection) == "table" and data.Collection or {}
	for _, milestone in ipairs(Mod.Rewards and type(Mod.Rewards.Milestones) == "table" and Mod.Rewards.Milestones or {}) do
		if not done[milestone.Id] and (tonumber(data.Discovered) or 0) >= (tonumber(milestone.Count) or math.huge) then
			table.insert(keys, milestone.Id)
		end
	end
	for _, key in ipairs(keys) do
		if not alive then
			return
		end
		local reply, reason = Net.call("ClaimCollection", key)
		if reply then
			claimed(reply, "Collection " .. tostring(key))
		else
			logOnce("collection" .. tostring(key), "Collection " .. tostring(key) .. ": " .. tostring(reason), "warn", 120)
		end
	end
end

local function goalReply(reply, id)
	if id ~= nil then
		Game.GoalsReady[id] = nil
	end
	Game.Coins = reply.Coins or Game.Coins
	Game.Achievements = reply.Achievements or Game.Achievements
	if type(reply.GoalsReady) == "table" then
		Game.GoalsReady = reply.GoalsReady
	end
	local n = type(reply.Claimed) == "table" and #reply.Claimed or 1
	S.claims += n
	log(string.format("Claimed %d goal%s (+%s coins)", n, n == 1 and "" or "s", abbr(reply.Paid or 0)), "ok")
end

function Claims.goals()
	if type(Game.GoalsReady) ~= "table" or next(Game.GoalsReady) == nil then
		return
	end
	if Claims.goalStyle ~= "each" then
		local reply, _, raw = Net.call("ClaimGoal")
		if reply then
			Claims.goalStyle = "all"
			goalReply(reply)
			return
		end
		if raw == nil or Claims.goalStyle == "all" then
			return
		end
	end
	for _ = 1, 10 do
		local id = next(Game.GoalsReady)
		if id == nil or not alive then
			break
		end
		local reply, reason = Net.call("ClaimGoal", id)
		if not reply then
			logOnce("goal" .. tostring(id), "Goal " .. tostring(id) .. ": " .. tostring(reason), "warn", 120)
			Game.GoalsReady[id] = nil -- not ready after all; the next sync puts it back if it is
			break
		end
		Claims.goalStyle = "each"
		goalReply(reply, id)
	end
end

-- Game.Quests = { Daily = { { Text, Progress, Target, Reward, Claimed } }, Weekly = { ... }, Level, RewardX, ... }. A quest is
-- ready once it isn't claimed and Progress has reached Target. The CLAIM ALL button sends ("All"), a single card (kind, index).
function Claims.quests()
	local quests = Game.Quests
	if type(quests) ~= "table" then
		return
	end
	local ready = {}
	for _, kind in ipairs({ "Daily", "Weekly" }) do
		for index, quest in ipairs(type(quests[kind]) == "table" and quests[kind] or {}) do
			if type(quest) == "table" and not quest.Claimed and (tonumber(quest.Progress) or 0) >= (tonumber(quest.Target) or math.huge) then
				table.insert(ready, { kind = kind, index = index })
			end
		end
	end
	if #ready == 0 then
		return
	end
	local function done(reply)
		Game.Gems = reply.Gems or Game.Gems
		if reply.Quests then
			Game.Quests = reply.Quests
		end
		local n = tonumber(reply.Count) or 1
		S.claims += n
		log(string.format("Claimed %d quest%s (+%s gems)", n, n == 1 and "" or "s", abbr(reply.Reward or 0)), "ok")
	end
	if #ready > 1 then
		local reply, _, raw = Net.call("ClaimQuest", "All")
		if reply then
			done(reply)
			return
		end
		if raw == nil then
			return
		end
	end
	for i, quest in ipairs(ready) do
		if i > 8 or not alive then
			break
		end
		local reply, reason = Net.call("ClaimQuest", quest.kind, quest.index)
		if reply then
			done(reply)
		else
			logOnce("quest" .. quest.kind .. quest.index, "Quest " .. quest.kind .. " " .. quest.index .. ": " .. tostring(reason), "warn", 120)
		end
	end
end

function Claims.run(manual)
	return guard("claim", function()
		setActivity("Claiming rewards...")
		if manual or Cfg.claimDaily or Cfg.claimGifts or Cfg.claimCollection then
			local data = Claims.fetchRewards()
			if data then
				if manual or Cfg.claimDaily then
					Claims.daily(data)
				end
				if manual or Cfg.claimGifts then
					Claims.gifts(data)
				end
				if manual or Cfg.claimCollection then
					Claims.collection(data)
				end
			end
		end
		if manual or Cfg.claimGoals then
			Claims.goals()
		end
		if manual or Cfg.claimQuests then
			Claims.quests()
		end
	end)
end

--// actions: base, rebirth, travel

function Act.collectVault()
	return guard("vault", function()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local map = Workspace:FindFirstChild("Map")
		local plots = map and map:FindFirstChild("Plots")
		local pad
		for _, plot in ipairs(plots and plots:GetChildren() or {}) do
			if plot:GetAttribute("Owner") == LocalPlayer.UserId then
				local pile = plot:FindFirstChild("CoinPile")
				pad = pile and pile:FindFirstChild("CollectPad")
			end
		end
		if not (root and pad) then
			logOnce("vaultpad", "Can't find your vault pad", "warn", 120)
			return false
		end
		setActivity("Collecting the vault...")
		local padPos = pad:IsA("BasePart") and pad.Position or pad:GetPivot().Position
		local home = root.CFrame
		Roll.collected = false
		root.CFrame = CFrame.new(padPos + Vector3.new(0, 3, 0))
		local waited = 0
		while waited < 3 and not Roll.collected and alive do
			waited += task.wait(0.1)
		end
		task.wait(0.25)
		root.CFrame = home
		if not Roll.collected then
			logOnce("vaultmiss", "Stood on the vault pad but nothing was collected", "warn", 120)
		end
		return Roll.collected
	end)
end

-- The Rebirth button's own test (RanksController): enough value, the mutations this rebirth asks for, not at the maximum, and
-- no perk waiting to be picked. The second result says which part is missing.
function Act.rebirthStatus()
	local P = Mod.Prog
	local rebirths = Game.Rebirths or 0
	local need = Derived.rebirthNeed
	local valueOk = need > 0 and (Game.RebirthValue or 0) >= need
	local mutationsOk, mutationNeed = true, nil
	local check = P and P.CheckRebirthMutations
	if type(check) == "function" then
		local ok, passed, needed = pcall(check, rebirths, Game.Items, Game.Carried)
		if ok then
			mutationsOk, mutationNeed = passed ~= false, needed
		end
	end
	local max = P and type(P.Rebirth) == "table" and tonumber(P.Rebirth.MaxRebirths) or math.huge
	local maxed = rebirths >= max
	local perk = Game.PerkChoice ~= nil
	return valueOk and mutationsOk and not maxed and not perk, {
		valueOk = valueOk,
		mutationsOk = mutationsOk,
		mutationNeed = mutationNeed,
		maxed = maxed,
		perk = perk,
	}
end

function Act.rebirthReady()
	return (Act.rebirthStatus())
end

function Act.rebirth()
	return guard("rebirth", function()
		setActivity("Rebirthing...", "warn")
		local reply, reason = Net.call("Rebirth", {})
		if not reply then
			logOnce("rebirth", "Rebirth refused: " .. tostring(reason), "warn", 30)
			return false
		end
		S.rebirths += 1
		Game.Rebirths = tonumber(reply.Rebirths) or ((Game.Rebirths or 0) + 1)
		Game.Gems = reply.Gems or Game.Gems
		Game.PerkChoice = reply.PerkChoice
		Roll.fellBack = false
		log(string.format("Rebirth #%d done (+%s gems)", Game.Rebirths, abbr(reply.GemsEarned or 0)), "gold")
		if Game.PerkChoice ~= nil then
			log("A perk is waiting for you: pick it in the game", "gold")
		end
		Net.sync() -- nearly everything was reset: read it all again
		return true
	end)
end

function Act.goBestZone()
	local id = Derived.bestZone
	if not id or id == Derived.zone then
		return false
	end
	local world = Mod.World
	if not (world and type(world.Teleport) == "function") then
		logOnce("noteleport", "The game's teleport isn't available", "warn", 120)
		return false
	end
	Roll.lastTeleport = now()
	-- the Ranks window sends ("Hub") for the hub and ("Zone", id) for everything else
	local ok, err
	if id == "Hub" then
		ok, err = pcall(world.Teleport, "Hub")
	else
		ok, err = pcall(world.Teleport, "Zone", id)
	end
	restoreIdentity()
	if not ok then
		logOnce("teleport", "Teleport failed: " .. tostring(err), "warn", 60)
		return false
	end
	log("Moving to " .. Mod.zoneName(id) .. " (luck x" .. abbr(Derived.bestLuck) .. ")", "ok")
	return true
end

function Act.goBase()
	local world = Mod.World
	if world and type(world.Teleport) == "function" then
		pcall(world.Teleport, "Plot")
		restoreIdentity()
	else
		log("The game's teleport isn't available", "warn")
	end
end

--// jobs and engine -------------------------------------------------------------
-- One thread does everything in turn: due jobs first, then a roll. The game answers one call at a time anyway, and a
-- single order keeps the mirror consistent.

local Jobs = {}

-- `first`: seconds until the first run; a job with no `first` is due as soon as it is enabled and the engine runs
local function job(name, every, when, run, first)
	table.insert(Jobs, { name = name, every = every, when = when, run = run, nextAt = now() + (first or 0) })
end

job("Sync", SYNC_EVERY, function()
	return true
end, function()
	Net.sync()
end, SYNC_EVERY)

job("Game HUD", HUD_SYNC_EVERY, function()
	return Cfg.hudSync
end, Net.refreshHud, HUD_SYNC_EVERY)

job("Sell", function()
	return Cfg.sellEvery
end, function()
	return Cfg.sellAuto
end, function()
	Act.sell()
end)

job("Shop", 4, function()
	for _, name in ipairs(Shop.order) do
		if Cfg[Shop.cats[name].cfgKey] then
			return true
		end
	end
	return false
end, function()
	Shop.runEnabled(false)
end)

job("Claim", 45, function()
	return Cfg.claimDaily or Cfg.claimGifts or Cfg.claimCollection or Cfg.claimGoals or Cfg.claimQuests
end, function()
	Claims.run(false)
end)

job("Wear best", 120, function()
	return Cfg.equipBest
end, Act.equipBest)

job("Vault", 8, function()
	return Cfg.collectVault and LocalPlayer:GetAttribute("Pass_AutoCollect") ~= true and (Game.VaultCap or 0) > 0
		and (Game.BankFull or (Game.BaseBank or 0) >= Game.VaultCap * 0.9)
end, Act.collectVault)

job("Zone", 20, function()
	return Cfg.bestZone and now() - Roll.lastTeleport > 30
end, Act.goBestZone)

job("Rebirth", 5, function()
	return Cfg.autoRebirth and Act.rebirthReady() and now() >= (Roll.rebirthRetryAt or 0)
end, function()
	if not Act.rebirth() then
		Roll.rebirthRetryAt = now() + REBIRTH_RETRY
	end
end)

local function runJobs()
	for _, j in ipairs(Jobs) do
		if not (alive and S.enabled) then
			return
		end
		local t = now()
		if t >= j.nextAt and j.when() then
			j.nextAt = t + (type(j.every) == "function" and j.every() or j.every)
			local ok, err = pcall(j.run)
			restoreIdentity()
			if not ok then
				logOnce("job:" .. j.name, j.name .. ": " .. tostring(err), "bad", 30)
			end
		end
	end
end

local function engineStep()
	if Net.needSync and now() - Net.syncedAt > 3 then
		Net.needSync = false
		Net.sync()
	end
	if not Game.ready then
		setActivity("Reading your data...", "warn")
		if not Net.sync() then
			logOnce("sync", "Couldn't read your data from the server, retrying", "warn", 20)
			return 3
		end
	end
	runJobs()
	if Cfg.roll and S.enabled then
		return Act.rollOnce()
	end
	setActivity("Running (auto roll is off)", "idle")
	return 0.25
end

task.spawn(function()
	restoreIdentity()
	local failures = 0
	while alive do
		local delay = 0.25
		if S.enabled then
			local ok, result = pcall(engineStep)
			restoreIdentity()
			if ok then
				failures = 0
				delay = tonumber(result) or 0.25
			else
				failures += 1
				log("Error: " .. tostring(result), "bad")
				warn("[Limited Roller] " .. tostring(result))
				if failures >= 5 then
					failures = 0
					S.enabled = false
					setActivity("Stopped after repeated errors, see the log", "bad")
				end
				delay = 1
			end
		else
			-- stopped: the Sell/Shop buttons still read the mirror, so keep it from going stale
			local age = now() - Net.syncedAt
			if Game.ready and age > 3 and (Net.needSync or age > 60) then
				Net.needSync = false
				pcall(Net.sync)
				restoreIdentity()
			end
		end
		task.wait(math.max(delay, 0.03))
	end
end)

-- Roblox fires Idled after ~20 minutes without input; a fake right-click resets the timer
connect(LocalPlayer.Idled, function()
	if not Cfg.antiAfk then
		return
	end
	pcall(function()
		local virtualUser = game:GetService("VirtualUser")
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new())
	end)
end)

local function setEnabled(on)
	if S.enabled == on then
		return
	end
	S.enabled = on
	if on then
		S.runStart = now()
		log("Started", "ok")
	else
		S.runTotal += now() - (S.runStart or now())
		S.runStart = nil
		setActivity("Idle", "idle")
		log("Stopped", "dim")
	end
end

-- a button press: run fn on its own thread once the data is there
local function manual(name, fn)
	if not Game.ready then
		log("Still reading your data from the server", "warn")
		return
	end
	if Busy["manual:" .. name] then
		return
	end
	Busy["manual:" .. name] = true
	task.spawn(function()
		restoreIdentity()
		if now() - Net.syncedAt > 10 then
			pcall(Net.sync)
			restoreIdentity()
		end
		local ok, err = pcall(fn)
		restoreIdentity()
		Busy["manual:" .. name] = nil
		if not ok then
			log(name .. ": " .. tostring(err), "bad")
		end
	end)
end

--// server events ---------------------------------------------------------------
-- Our own connections to the same events the game listens to: they only keep the mirror current.

do
	local function listen(name, handler)
		local event = R[name]
		if event and event:IsA("RemoteEvent") then
			connect(event.OnClientEvent, handler)
		end
	end

	listen("DisplayIncome", function(p)
		if type(p) ~= "table" then
			return
		end
		Game.Coins = p.Coins or Game.Coins
		Game.Gems = p.Gems or Game.Gems
		Game.DisplayRate = p.Rate or Game.DisplayRate
		Game.GemRate = p.GemRate or Game.GemRate
		Game.BaseBank = p.Bank or Game.BaseBank
		Game.BankFull = p.BankFull == true
		Game.VaultCap = p.Cap or Game.VaultCap
	end)

	listen("BaseCollected", function(p)
		if type(p) ~= "table" then
			return
		end
		Game.Coins = p.Coins or Game.Coins
		Game.BaseBank = 0
		Game.BankFull = false
		if (p.Amount or 0) > 0 then
			S.vault += p.Amount
			Roll.collected = true
			if not p.Auto then
				log("Collected " .. abbr(p.Amount) .. " coins from the vault", "ok")
			end
		end
	end)

	listen("HomeEvent", function(p)
		if type(p) ~= "table" then
			return
		end
		Game.Coins = p.NewCoins or Game.Coins
		Game.Gems = p.NewGems or Game.Gems
	end)

	listen("QuestUpdate", function(p)
		if type(p) ~= "table" then
			return
		end
		Game.Quests = p
		Game.Gems = p.Gems or Game.Gems
	end)

	listen("Resync", function()
		if now() - Net.hudAt > 3 then
			Net.needSync = true
		end
	end)

	listen("Announcement", function(p)
		if type(p) == "table" and not p.Rebirth and p.UserId == LocalPlayer.UserId then
			log(string.format("Rare pull: %s (%s)", Mod.name(p.ItemId), tostring(p.Odds)), "gold")
		end
	end)
end

Shop.build()

task.spawn(function()
	restoreIdentity()
	Net.sync()
end)

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

local gui = new("ScreenGui", {
	Name = "LimitedRoller",
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

local WIDTH = 360
local INNER = WIDTH - 24
local camera = Workspace.CurrentCamera
local height = math.clamp((camera and camera.ViewportSize.Y or 720) - 60, 400, 660)
local LOG_H = 74
local PAGE_Y = 180 -- where the tab pages start, below the tab bar (inside `content`)

local main = new("Frame", {
	BackgroundColor3 = C.Panel,
	Position = UDim2.new(0, 24, 0.5, -height / 2),
	Size = UDim2.fromOffset(WIDTH, height),
	Parent = gui,
}, { corner(12), stroke(C.Border) })

local titleBar = new("Frame", {
	BackgroundColor3 = C.Bg,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 34),
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
	Text = "Limited Roller",
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
	Size = UDim2.fromOffset(110, 34),
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

-- everything under the title bar lives in `content`, so minimising only has to hide one frame
local content = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 34),
	Size = UDim2.new(1, 0, 1, -34),
	Parent = main,
})

-- status line, Start button, headline numbers
local statusCard = new("Frame", {
	BackgroundColor3 = C.Card,
	Position = UDim2.fromOffset(12, 8),
	Size = UDim2.fromOffset(INNER, 40),
	Parent = content,
}, { corner(10) })
local statusDot = new("Frame", {
	BackgroundColor3 = C.Faint,
	Position = UDim2.fromOffset(12, 15),
	Size = UDim2.fromOffset(10, 10),
	Parent = statusCard,
}, { corner(5) })
local statusText = label({
	Text = S.activity,
	Font = FONT_B,
	TextSize = 12,
	TextWrapped = true,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(30, 0),
	Size = UDim2.new(1, -40, 1, 0),
	Parent = statusCard,
})

local startBtn = button({
	Text = "Start",
	TextSize = 14,
	TextColor3 = C.Bg,
	BackgroundColor3 = C.Up,
	Position = UDim2.fromOffset(12, 54),
	Size = UDim2.fromOffset(INNER, 36),
	Parent = content,
}, { corner(10) })
connect(startBtn.Activated, function()
	setEnabled(not S.enabled)
end)

local statCards = {}
do
	local names = { "COINS", "GEMS", "ROLLS", "LUCK" }
	local colors = { C.Gold, Color3.fromRGB(125, 211, 252), C.Text, C.Up }
	local gap = 6
	local width = (INNER - gap * 3) / 4
	for i, name in ipairs(names) do
		local card = new("Frame", {
			BackgroundColor3 = C.Card,
			Position = UDim2.fromOffset(12 + (i - 1) * (width + gap), 96),
			Size = UDim2.fromOffset(width, 44),
			Parent = content,
		}, { corner(8) })
		label({
			Text = name,
			TextSize = 10,
			Font = FONT_B,
			TextColor3 = C.Faint,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, 6),
			Size = UDim2.new(1, 0, 0, 12),
			Parent = card,
		})
		statCards[name] = label({
			Text = "-",
			TextSize = 14,
			Font = FONT_B,
			TextColor3 = colors[i],
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, 21),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = card,
		})
	end
end

--// window: widgets

local renderers = {} -- run on every refresh so toggles etc. follow the settings, whoever changed them
local orders = {}

local function nextOrder(parent)
	orders[parent] = (orders[parent] or 0) + 1
	return orders[parent]
end

local function render(fn)
	table.insert(renderers, fn)
	fn()
end

local function section(parent, text)
	return label({
		Text = text,
		TextSize = 11,
		Font = FONT_B,
		TextColor3 = C.Faint,
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	})
end

local confirmUntil = {}
-- true on the second press within four seconds
local function confirmed(key)
	local t = now()
	if (confirmUntil[key] or 0) > t then
		confirmUntil[key] = nil
		return true
	end
	confirmUntil[key] = t + 4
	return false
end

-- opts.confirm: the switch only turns on at a second press; opts.onChange(value)
local function toggleRow(parent, text, key, opts)
	opts = opts or {}
	local row = button({
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	}, { corner(8) })
	local caption = label({
		Text = text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -64, 1, 0),
		Parent = row,
	})
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
	render(function()
		local value = Cfg[key] == true
		track.BackgroundColor3 = value and C.Accent or C.Border
		knob.Position = value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
		if opts.confirm then
			local armed = (confirmUntil[key] or 0) > now()
			caption.Text = armed and "Click again to switch on" or text
			caption.TextColor3 = armed and C.Warn or C.Text
		end
	end)
	connect(row.Activated, function()
		local value = not Cfg[key]
		if value and opts.confirm and not confirmed(key) then
			return
		end
		Cfg[key] = value
		Persist.touch()
		if opts.onChange then
			opts.onChange(value)
		end
	end)
	return row
end

local function segmentedRow(parent, title, options, get, set)
	local holder = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	})
	label({ Text = title, TextSize = 12, TextColor3 = C.Muted, Parent = holder })
	local row = new("Frame", {
		BackgroundColor3 = C.Input,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = holder,
	}, { corner(8), pad(3, 3), list(Enum.FillDirection.Horizontal, 4) })
	local buttons = {}
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
			set(i)
			Persist.touch()
		end)
	end
	render(function()
		local selected = get()
		for i, b in ipairs(buttons) do
			b.BackgroundColor3 = i == selected and C.Accent or C.Input
			b.TextColor3 = i == selected and C.Text or C.Muted
		end
	end)
	return holder
end

-- get() / set(n) work in the slider's own whole-number units
local function sliderRow(parent, title, min, max, unit, get, set)
	local holder = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = nextOrder(parent),
		Parent = parent,
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
	local function show(value)
		local alpha = (value - min) / (max - min)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = value .. unit
	end
	render(function()
		show(math.clamp(get(), min, max))
	end)
	local function fromInput(input)
		local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local value = math.clamp(round(min + alpha * (max - min)), min, max)
		if value ~= get() then
			set(value)
			Persist.touch()
		end
		show(value)
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

-- a grid of tick chips, one per name. isOn(name) says whether it is ticked, toggle(name) flips it, colorOf(name) is the
-- colour a ticked chip takes (the accent when left out)
local function chipGrid(parent, names, isOn, toggle, colorOf)
	local holder = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	}, {
		new("UIGridLayout", {
			CellSize = UDim2.new(0.25, -5, 0, 28),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local chips = {}
	for i, name in ipairs(names) do
		chips[i] = button({
			Text = name,
			TextSize = 12,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = holder,
		}, { corner(8) })
		connect(chips[i].Activated, function()
			toggle(name)
			Persist.touch()
		end)
	end
	render(function()
		for i, chip in ipairs(chips) do
			local on = isOn(names[i])
			chip.BackgroundColor3 = on and (colorOf and colorOf(names[i]) or C.Accent) or C.Input
			chip.TextColor3 = on and C.Bg or C.Muted
			chip.Text = (on and "✓ " or "") .. names[i]
		end
	end)
	return holder
end

local function cyclerRow(parent, getText, onStep)
	local row = new("Frame", {
		BackgroundColor3 = C.Card,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	}, { corner(8) })
	local prev = button({ Text = "<", BackgroundTransparency = 1, Size = UDim2.fromOffset(34, 34), Parent = row })
	local nextBtn = button({
		Text = ">",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(34, 34),
		Parent = row,
	})
	local caption = label({
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(34, 0),
		Size = UDim2.new(1, -68, 1, 0),
		Parent = row,
	})
	connect(prev.Activated, function()
		onStep(-1)
	end)
	connect(nextBtn.Activated, function()
		onStep(1)
	end)
	render(function()
		caption.Text = getText()
	end)
	return row
end

-- defs: { { text, handler }, ... }
local function buttonRow(parent, defs)
	local row = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	}, { list(Enum.FillDirection.Horizontal, 6) })
	local out = {}
	for i, def in ipairs(defs) do
		out[i] = button({
			Text = def[1],
			TextSize = 12,
			Size = UDim2.new(1 / #defs, -(6 * (#defs - 1) / #defs), 1, 0),
			LayoutOrder = i,
			Parent = row,
		}, { corner(8) })
		connect(out[i].Activated, def[2])
	end
	return out, row
end

-- a card of "caption ... value" rows; returns a function that adds a row and hands back its value label
local function infoCard(parent)
	local card = new("Frame", {
		BackgroundColor3 = C.Card,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(parent),
		Parent = parent,
	}, { corner(10), pad(8, 12), list(Enum.FillDirection.Vertical, 4) })
	local rows = 0
	return function(caption)
		rows += 1
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = rows, Parent = card })
		label({ Text = caption, TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(0.34, 0, 1, 0), Parent = row })
		return label({
			Text = "-",
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(0.34, 0),
			Size = UDim2.fromScale(0.66, 1),
			Parent = row,
		})
	end
end

--// window: pages

local pageHolder = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(12, PAGE_Y),
	Size = UDim2.new(0, INNER, 1, -(PAGE_Y + LOG_H + 14)),
	Parent = content,
})

local pages = {}
local tabButtons = {}

local function newPage(name)
	local page = new("ScrollingFrame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
		Parent = pageHolder,
	}, {
		list(Enum.FillDirection.Vertical, 6),
		new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 6), PaddingRight = UDim.new(0, 8) }),
	})
	pages[name] = page
	return page
end

local function showPage(name)
	for pageName, page in pairs(pages) do
		page.Visible = pageName == name
	end
	for tabName, b in pairs(tabButtons) do
		b.BackgroundColor3 = tabName == name and C.Accent or C.Card
		b.TextColor3 = tabName == name and C.Text or C.Muted
	end
end

do
	local names = { "Roll", "Sell", "Shop", "Claim", "Misc" }
	local tabBar = new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 146),
		Size = UDim2.fromOffset(INNER, 28),
		Parent = content,
	}, { list(Enum.FillDirection.Horizontal, 4) })
	for i, name in ipairs(names) do
		tabButtons[name] = button({
			Text = name,
			TextSize = 12,
			AutoButtonColor = false,
			Size = UDim2.new(1 / #names, -(4 * (#names - 1) / #names), 1, 0),
			LayoutOrder = i,
			Parent = tabBar,
		}, { corner(8) })
		connect(tabButtons[name].Activated, function()
			showPage(name)
		end)
		newPage(name)
	end
end

local ui = { info = {} }

-- Roll
do
	local page = pages.Roll
	section(page, "AUTO ROLL")
	toggleRow(page, "Auto roll", "roll")
	sliderRow(page, "Delay between rolls", 50, 1500, " ms", function()
		return round(Cfg.rollDelay * 1000)
	end, function(value)
		Cfg.rollDelay = value / 1000
	end)
	toggleRow(page, "Open the most cases per roll", "maxOpen")
	section(page, "CASE")
	segmentedRow(page, "Which case to roll", { "The one I pick", "Best I can afford" }, function()
		return Cfg.caseMode == "best" and 2 or 1
	end, function(index)
		Cfg.caseMode = index == 2 and "best" or "fixed"
	end)
	ui.caseCycler = cyclerRow(page, function()
		local cases = Mod.cases()
		local idx = (Cfg.caseId and Mod.caseIndex(Cfg.caseId)) or Mod.caseIndex(Game.SelectedCase) or 1
		local case = cases[idx]
		if not case then
			return "no cases found"
		end
		local fee = Mod.caseFee(case)
		return tostring(case.Name or case.Id) .. (fee > 0 and ("  -  " .. abbr(fee) .. " per roll") or "  -  free")
	end, function(step)
		local cases = Mod.cases()
		local unlocked = math.clamp(tonumber(Game.CaseLevel) or 1, 1, math.max(#cases, 1))
		local idx = (Cfg.caseId and Mod.caseIndex(Cfg.caseId)) or Mod.caseIndex(Game.SelectedCase) or 1
		idx = ((idx - 1 + step) % unlocked) + 1
		if cases[idx] then
			Cfg.caseId = cases[idx].Id
			Roll.fellBack = false
			Persist.touch()
		end
	end)
	toggleRow(page, "Free case when out of coins", "fallback")
	section(page, "LUCK")
	toggleRow(page, "Roll from the best luck zone", "bestZone")
	local zoneButtons = buttonRow(page, {
		{
			"Go to best zone",
			function()
				manual("zone", Act.goBestZone)
			end,
		},
		{
			"Unlock Auto Roll",
			function()
				if Game.Stats.AutoRoll ~= true then
					manual("autoroll", Act.unlockAuto)
				end
			end,
		},
	})
	ui.autoButton = zoneButtons[2]
	section(page, "THIS SESSION")
	local add = infoCard(page)
	ui.info.time = add("Running for")
	ui.info.case = add("Case")
	ui.info.auto = add("Auto roll")
	ui.info.zone = add("Zone")
	ui.info.rolls = add("Rolls (all time)")
	ui.info.items = add("Items / new")
	ui.info.best = add("Best pull")
	ui.info.rarities = add("Rarest pulled")
	ui.info.rank = add("Rank")
	ui.info.value = add("Inventory value")
	ui.info.fees = add("Roll fees paid")
end

-- Sell
do
	local page = pages.Sell
	section(page, "AUTO SELL")
	toggleRow(page, "Sell automatically", "sellAuto")
	sliderRow(page, "Sell every", 10, 300, " s", function()
		return round(Cfg.sellEvery)
	end, function(value)
		Cfg.sellEvery = value
	end)
	toggleRow(page, "Never sell mutated items", "sellKeep")
	toggleRow(page, "Every copy, not just extras", "sellAll", { confirm = true })
	section(page, "RARITIES TO SELL")
	local rarities = Mod.rarities()
	if #rarities > 0 then
		chipGrid(page, rarities, function(name)
			return Sell.set()[name] == true
		end, function(name)
			local set = Sell.set()
			set[name] = not set[name] or nil
		end, function(name)
			return safe(Mod.Rarity and Mod.Rarity.GetColor, name)
		end)
	else
		label({ Text = "The game's rarity list wasn't found", TextColor3 = C.Warn, LayoutOrder = nextOrder(page), Parent = page })
	end
	label({
		Text = "Extras = every copy but one of each. Worn and locked items are always kept.",
		TextSize = 11,
		TextColor3 = C.Faint,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = nextOrder(page),
		Parent = page,
	})
	section(page, "NOW")
	local sellButtons = buttonRow(page, {
		{
			"Sell now",
			function()
				if Cfg.sellAll and not confirmed("sellNow") then
					return
				end
				manual("sell", function()
					Act.sell(true)
				end)
			end,
		},
		{
			"Wear best items",
			function()
				manual("equipbest", Act.equipBest)
			end,
		},
	})
	ui.sellNowButton = sellButtons[1]
	buttonRow(page, {
		{
			"Lock my best items",
			function()
				manual("lockbest", Act.lockBest)
			end,
		},
	})
	toggleRow(page, "Keep wearing my best items", "equipBest")
	section(page, "PREVIEW")
	local add = infoCard(page)
	ui.info.sellPlan = add("Would sell")
	ui.info.sellCoins = add("Worth")
	ui.info.sold = add("Sold this session")
end

-- Shop
do
	local page = pages.Shop
	section(page, "AUTO BUY")
	toggleRow(page, "Upgrades (skill tree)", "buySkills")
	toggleRow(page, "Gem upgrades", "buyGemUpgrades")
	toggleRow(page, "Coin mastery", "buyMastery")
	toggleRow(page, "Unlock the next case", "buyCases")
	toggleRow(page, "Display slots (gems)", "buySlots")
	toggleRow(page, "Keep Super Luck potion on (gems)", "superPotion")
	buttonRow(page, {
		{
			"Buy what I can now",
			function()
				manual("shop", function()
					Shop.runEnabled(true)
				end)
			end,
		},
	})
	section(page, "STATE")
	local add = infoCard(page)
	ui.info.shopSkills = add("Upgrades")
	ui.info.shopGems = add("Gem upgrades")
	ui.info.shopMastery = add("Mastery")
	ui.info.shopCase = add("Next case")
	ui.info.shopLast = add("Last refusal")
	ui.info.shopBought = add("Bought this session")
end

-- Claim
do
	local page = pages.Claim
	section(page, "AUTO CLAIM")
	toggleRow(page, "Daily reward", "claimDaily")
	toggleRow(page, "Gifts", "claimGifts")
	toggleRow(page, "Collection rewards", "claimCollection")
	toggleRow(page, "Quests", "claimQuests")
	toggleRow(page, "Goals (best effort)", "claimGoals")
	buttonRow(page, {
		{
			"Claim everything now",
			function()
				manual("claim", function()
					Claims.run(true)
				end)
			end,
		},
	})
	section(page, "STATE")
	local add = infoCard(page)
	ui.info.claimDaily = add("Daily reward")
	ui.info.claimGifts = add("Next gift")
	ui.info.claimQuests = add("Quests ready")
	ui.info.claimGoals = add("Goals ready")
	ui.info.claimDone = add("Claimed this session")
end

-- Misc
do
	local page = pages.Misc
	section(page, "BASE")
	toggleRow(page, "Collect the vault when it's full", "collectVault")
	local add = infoCard(page)
	ui.info.vault = add("Vault")
	ui.info.income = add("Base income")
	section(page, "REBIRTH")
	local addRebirth = infoCard(page)
	ui.info.rebirthCount = addRebirth("Rebirths")
	ui.info.rebirthNeed = addRebirth("Value needed")
	ui.info.rebirthState = addRebirth("Status")
	toggleRow(page, "Rebirth automatically when ready", "autoRebirth", { confirm = true })
	local rebirthButtons = buttonRow(page, {
		{
			"Rebirth now",
			function()
				if not confirmed("rebirthNow") then
					return
				end
				manual("rebirth", Act.rebirth)
			end,
		},
	})
	ui.rebirthButton = rebirthButtons[1]
	section(page, "GAME")
	toggleRow(page, "Keep the game's own HUD in sync", "hudSync")
	toggleRow(page, "Anti-AFK", "antiAfk")
	buttonRow(page, {
		{
			"Go to my base",
			function()
				manual("base", Act.goBase)
			end,
		},
		{
			"Refresh data",
			function()
				manual("sync", Net.sync)
			end,
		},
	})
	buttonRow(page, {
		{
			"Copy debug info",
			function()
				ui.copyDebug()
			end,
		},
	})
end

--// window: log

local logCard = new("Frame", {
	BackgroundColor3 = C.Input,
	ClipsDescendants = true,
	Position = UDim2.new(0, 12, 1, -(LOG_H + 8)),
	Size = UDim2.fromOffset(INNER, LOG_H),
	Parent = content,
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

--// window: debug dump
-- The shapes of what the game sends and the pieces still guessed (goals, upgrade lists, rebirth), in one block you can paste back.

function ui.debugText()
	local lines = {}
	local function add(text)
		table.insert(lines, text)
	end
	add("Limited Roller debug (" .. os.date("%Y-%m-%d %H:%M:%S") .. ")")
	local loaded, missing = {}, {}
	for _, pair in ipairs({
		{ "OddsCalculator", "Odds" },
		{ "ItemValues", "Values" },
		{ "RarityConfig", "Rarity" },
		{ "SkillConfig", "Skill" },
		{ "ProgressionConfig", "Prog" },
		{ "CaseConfig", "Case" },
		{ "GemConfig", "Gem" },
		{ "CoinShopConfig", "Coin" },
		{ "EquipConfig", "Equip" },
		{ "RewardsConfig", "Rewards" },
		{ "UpgradesController", "Upgrades" },
		{ "CasesController", "CasesUI" },
		{ "GemsController", "GemsUI" },
		{ "RewardsController", "RewardsUI" },
		{ "WorldController", "World" },
	}) do
		table.insert(Mod[pair[2]] and loaded or missing, pair[1])
	end
	add("modules found: " .. table.concat(loaded, ", "))
	add("modules missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
	add("GetInventory keys: " .. Net.keys)
	for _, name in ipairs(Shop.order) do
		local cat = Shop.cats[name]
		if cat.list then
			local first = cat.list[1]
			add(string.format("%s: %d nodes, first %s", name, #cat.list, first and dump(first) or "-"))
		end
	end
	add("goal claim form: " .. tostring(Claims.goalStyle))
	add("sell: rarities " .. dump(Cfg.sellRarities) .. ", all copies " .. tostring(Cfg.sellAll) .. ", keep mutated " .. tostring(Cfg.sellKeep))
	add("rebirth: " .. dump(select(2, Act.rebirthStatus())) .. ", needs " .. tostring(Derived.rebirthNeed))
	add("Stats: " .. dump(Game.Stats))
	add("Quests: " .. dump(Game.Quests))
	add("GoalsReady: " .. dump(Game.GoalsReady))
	add("Rewards: " .. dump(Claims.data))
	add("PerkChoice: " .. dump(Game.PerkChoice))
	add("Log:")
	for i = math.max(1, #S.log - 15), #S.log do
		add("  " .. S.log[i].text)
	end
	return table.concat(lines, "\n")
end

function ui.copyDebug()
	manual("debug", function()
		Claims.fetchRewards()
		local text = ui.debugText()
		if setclipboard then
			local ok = pcall(setclipboard, text)
			log(ok and "Debug info copied to the clipboard" or "Couldn't reach the clipboard, printed to the console", ok and "ok" or "warn")
			if ok then
				return
			end
		else
			log("No clipboard here, printed to the console", "warn")
		end
		print(text)
	end)
end

--// window: behaviour

local minimized = false
local fullSize = main.Size
connect(minBtn.Activated, function()
	minimized = not minimized
	content.Visible = not minimized
	titleCover.Visible = not minimized
	main.Size = minimized and UDim2.fromOffset(WIDTH, 34) or fullSize
	minBtn.Text = minimized and "+" or "–"
end)

local function destroy()
	if not alive then
		return
	end
	alive = false
	S.enabled = false
	Persist.dirty = true
	Persist.flush()
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	pcall(function()
		gui:Destroy()
	end)
	if env.__LimitedRollerUnload == destroy then
		env.__LimitedRollerUnload = nil
	end
end
env.__LimitedRollerUnload = destroy
connect(closeBtn.Activated, destroy)

connect(UIS.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

local function luckText(value)
	return "x" .. abbr(value)
end

-- the three rarest rarities rolled so far, rarest first: "Legendary 1, Epic 3, Rare 12"
local function rarityText()
	local names = {}
	for rarity in pairs(S.byRarity) do
		table.insert(names, rarity)
	end
	table.sort(names, function(a, b)
		local ra, rb = S.rarityRep[a], S.rarityRep[b]
		if ra and rb then
			if Mod.rarer(ra, rb) then
				return true
			end
			if Mod.rarer(rb, ra) then
				return false
			end
		end
		return a < b
	end)
	local parts = {}
	for i = 1, math.min(#names, 3) do
		parts[i] = names[i] .. " " .. S.byRarity[names[i]]
	end
	return #parts > 0 and table.concat(parts, ", ") or "-"
end

local lastHeavy = -1e9

local function refresh()
	local t = now()
	statusText.Text = S.enabled and S.activity or "Idle: press Start"
	statusDot.BackgroundColor3 = S.enabled and (KIND_COLOR[S.activityKind] or C.Faint) or C.Faint
	startBtn.Text = S.enabled and "Stop" or "Start"
	startBtn.BackgroundColor3 = S.enabled and C.Down or C.Up

	statCards.COINS.Text = abbr(Game.Coins)
	statCards.GEMS.Text = abbr(Game.Gems)
	statCards.ROLLS.Text = abbr(S.rolls)
	statCards.LUCK.Text = luckText(Derived.luck)

	for _, fn in ipairs(renderers) do
		fn()
	end
	ui.caseCycler.Visible = Cfg.caseMode ~= "best"
	ui.rebirthButton.Text = (confirmUntil.rebirthNow or 0) > t and "Click again to rebirth" or "Rebirth now"
	ui.sellNowButton.Text = (confirmUntil.sellNow or 0) > t and "Click again: sell all" or "Sell now"

	-- the parts that walk the whole inventory or call the game's helpers don't need to run five times a second
	if t - lastHeavy > 1 then
		lastHeavy = t
		Derived.update()
		local info = ui.info
		info.time.Text = clock(S.runTotal + (S.runStart and t - S.runStart or 0))
		local cases = Mod.cases()
		local selected = Mod.caseIndex(Game.SelectedCase)
		info.case.Text = selected and tostring(cases[selected].Name or cases[selected].Id) or "?"
		local auto = type(Game.Stats) == "table" and Game.Stats.AutoRoll == true
		info.auto.Text = auto and "unlocked" or ((Game.TotalRolls or 0) >= 10 and "ready to unlock" or ("locked: " .. (Game.TotalRolls or 0) .. "/10 rolls"))
		ui.autoButton.Text = auto and "Auto Roll: unlocked" or "Unlock Auto Roll"
		info.zone.Text = Mod.zoneName(Derived.zone) .. " " .. luckText(Derived.luck)
			.. (Derived.bestZone and Derived.bestZone ~= Derived.zone and ("  (best: " .. Mod.zoneName(Derived.bestZone) .. " " .. luckText(Derived.bestLuck) .. ")") or "")
		info.rolls.Text = abbr(Game.TotalRolls)
		info.items.Text = abbr(S.items) .. " / " .. abbr(S.found)
		info.best.Text = S.best and Mod.name(S.best) or "-"
		info.rarities.Text = rarityText()
		info.rank.Text = Derived.rankName
		if Derived.rankColor then
			info.rank.TextColor3 = Derived.rankColor
		end
		info.value.Text = abbr(Game.InventoryValue)
		info.fees.Text = abbr(S.fees)

		if pages.Sell.Visible then -- this one walks the whole inventory, so only while somebody is looking at it
			local items, coins, stacks = Sell.plan()
			info.sellPlan.Text = items > 0 and (abbr(items) .. " items in " .. stacks .. " stack" .. (stacks == 1 and "" or "s")) or "nothing with these settings"
			info.sellCoins.Text = "+" .. abbr(coins) .. " coins"
		end
		info.sold.Text = abbr(S.sold) .. " items for " .. abbr(S.soldFor)

		local function owned(cat, key)
			local n = 0
			for _, node in ipairs(cat.list) do
				if cat:owned(node) or (Game[key] and Game[key][node.Id]) then
					n += 1
				end
			end
			return n .. " / " .. #cat.list
		end
		info.shopSkills.Text = #Shop.cats.skills.list > 0 and owned(Shop.cats.skills, "Skills") or "not found"
		info.shopGems.Text = #Shop.cats.gems.list > 0 and (#Shop.cats.gems.list .. " kinds") or "not found"
		info.shopMastery.Text = #Shop.cats.mastery.list > 0 and (#Shop.cats.mastery.list .. " kinds") or "not found"
		local nextCase = Shop.cats.cases:candidates()[1]
		info.shopCase.Text = nextCase and tostring(nextCase.Name or nextCase.Id) or "all unlocked"
		info.shopLast.Text = Shop.lastReason or "-"
		info.shopBought.Text = tostring(S.bought)

		local goals = 0
		for _ in pairs(Game.GoalsReady or {}) do
			goals += 1
		end
		info.claimGoals.Text = tostring(goals)
		local questsReady = 0
		for _, kind in ipairs({ "Daily", "Weekly" }) do
			for _, quest in ipairs(type(Game.Quests) == "table" and type(Game.Quests[kind]) == "table" and Game.Quests[kind] or {}) do
				if type(quest) == "table" and not quest.Claimed and (tonumber(quest.Progress) or 0) >= (tonumber(quest.Target) or math.huge) then
					questsReady += 1
				end
			end
		end
		info.claimQuests.Text = tostring(questsReady)
		local rewards = Claims.data
		local daily = rewards and rewards.Daily
		info.claimDaily.Text = type(daily) ~= "table" and "-" or (daily.CanClaim and "ready" or "claimed")
		-- the nearest gift that isn't opened yet, counted down from when the state was read
		local nextGift
		for _, gift in ipairs(rewards and type(rewards.Gifts) == "table" and rewards.Gifts or {}) do
			if type(gift) == "table" and not gift.Claimed and tonumber(gift.ReadyIn) then
				nextGift = math.min(nextGift or math.huge, gift.ReadyIn)
			end
		end
		info.claimGifts.Text = nextGift and (nextGift <= 0 and "ready" or clock(nextGift)) or "-"
		info.claimDone.Text = tostring(S.claims)

		info.vault.Text = (Game.VaultCap or 0) > 0 and (abbr(Game.BaseBank) .. " / " .. abbr(Game.VaultCap) .. (Game.BankFull and " (full)" or "")) or "-"
		info.income.Text = abbr(Game.DisplayRate) .. " coins/s, " .. abbr(Game.GemRate) .. " gems/s"
		local ready, why = Act.rebirthStatus()
		info.rebirthCount.Text = tostring(Game.Rebirths or 0)
		info.rebirthNeed.Text = abbr(Game.RebirthValue) .. " / " .. abbr(Derived.rebirthNeed)
		info.rebirthNeed.TextColor3 = why.valueOk and C.Up or C.Text
		local needText = why.mutationNeed ~= nil and safe(Mod.Prog and Mod.Prog.MutationNeedsText, why.mutationNeed) or nil
		if ready then
			info.rebirthState.Text = "READY"
		elseif why.maxed then
			info.rebirthState.Text = "max rebirths reached"
		elseif why.perk then
			info.rebirthState.Text = "pick your perk in the game first"
		elseif not why.valueOk then
			info.rebirthState.Text = "needs more value"
		else
			info.rebirthState.Text = needText and ("find " .. tostring(needText)) or "needs a mutation"
		end
		info.rebirthState.TextColor3 = ready and C.Up or C.Muted
	end

	if S.logVersion ~= ui.lastLogVersion then
		ui.lastLogVersion = S.logVersion
		local lines = {}
		for i = math.max(1, #S.log - 4), #S.log do
			local entry = S.log[i]
			table.insert(lines, string.format('<font color="#%s">%s</font>', (KIND_COLOR[entry.kind] or C.Muted):ToHex(), esc(entry.text)))
		end
		logText.Text = table.concat(lines, "\n")
	end

	if Persist.dirty and t - Persist.at > 1.5 then
		Persist.flush()
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
			warn("[Limited Roller] window: " .. lastError)
		end
		task.wait(0.2)
	end
end)

showPage("Roll")
log(Mod.Odds and "Ready. Press Start." or "Ready, but the game's item modules weren't found: values and rarities will be blank.", "dim")
