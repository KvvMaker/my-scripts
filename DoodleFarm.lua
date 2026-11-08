--// ============================================================================
--//  Doodle Farm  -  full auto for Doodle World (PlaceId 5116869569).  Potassium GUI.
--//  RightShift hides / shows the window.
--//
--//  Built from the game dump (Modules.txt / Remotes.txt / RemoteSpy.txt).  What the client code showed:
--//   * Every game system sits in one table: require(LocalPlayer.Client)  (ClientRunner does
--//     require(script.Parent.Client), ClientRunner/Client are parented to the player).  It has
--//     Network:post/get, ClientDatabase:PDSFunc/PDSEvent, Battle.CurrentBattle, Controls:CanWalk(),
--//     BattleNo.Live()/Run, Steps:Encounter, Utilities:IsInGrass ...
--//   * Server calls go through two dispatchers in LocalPlayer.Remotes: PlayerDataFunc(name, ...) and
--//     PlayerDataEvent(name, ...)  (spy: "GetParty", "ToggleBusy", ...).  Used here: GetParty, Heal,
--//     GetFarm, ShooFarm, GroupPlantFarm(plot, LastPlant), ClaimGift(i), plus the plain remotes
--//     ClaimBP(isPremium, tier), GetMail, ClaimMail(id).
--//   * Battles are server side and driven from the game's own battle buttons
--//     (MainGui.MainBattle.BottomBar: Actions.Fight, Moves.Move1-4, SelectTarget.Front1-4, Next; hotkeys
--//     Q / 1-4).  So auto battle presses those buttons instead of guessing the BattleAction payload.
--//   * Wild encounters come from walking on parts named Grass / WildGrass / CoveGrass / IceGrass /
--//     DesertGrass (Utilities.IsInGrass), so Roam walks around on grass.
--//
--//  UNVERIFIED in-game: the faint-switch screen (PartyUI), the exact move-button text (PP / effectiveness),
--//  that the server accepts a remote "Heal" away from a healing station, GetMail's shape, and whether the
--//  Battlepass snapshot arrives without opening it.  Use  Misc > Debug info  and the Log tab if stuck.
--// ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LP = Players.LocalPlayer
if not LP then
	return
end

--// ---------------------------------------------------------------- unload / helpers
local ENV = (getgenv and getgenv()) or _G
if ENV.__DoodleFarmUnload then
	pcall(ENV.__DoodleFarmUnload)
end

local alive = true
local conns, cleanups = {}, {}
local function track(c)
	conns[#conns + 1] = c
	return c
end
local function onUnload(fn)
	cleanups[#cleanups + 1] = fn
end

local Log = { lines = {}, dirty = true }
local function say(msg)
	Log.lines[#Log.lines + 1] = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
	if #Log.lines > 200 then
		table.remove(Log.lines, 1)
	end
	Log.dirty = true
end

local lastErr = {}
local function loop(name, interval, fn)
	task.spawn(function()
		while alive do
			local ok, err = pcall(fn)
			if not ok then
				local key = name .. tostring(err)
				if lastErr[name] ~= key then
					lastErr[name] = key
					say(name .. " error: " .. tostring(err))
				end
			end
			task.wait(interval)
		end
	end)
end

--// ---------------------------------------------------------------- settings
local SETTINGS_FILE = "DoodleFarm_settings.json"
local S = {
	-- battle
	battle = false,
	moveMode = "Smart", -- Smart | Slot 1..4 | Random
	noSwitch = true, -- answer "No" to the "switch Doodle?" prompt
	dismiss = true, -- press Next / OK / Continue style buttons inside the battle screen
	rareAction = "Pause", -- Pause | Notify only | Ignore
	rareList = "",
	speed = 0, -- 0 = leave the game's battle speed
	-- roam
	walk = false,
	walkRadius = 14,
	grassOnly = true,
	-- heal
	heal = true,
	healBelow = 45,
	-- farm plots
	farm = false,
	farmAction = "Notify only", -- Notify only | Shoo | Battle (experimental)
	farmReplant = true,
	farmEvery = 30,
	-- claim
	claimGifts = true,
	claimMail = false,
	claimBP = false,
	-- misc
	antiAfk = true,
	noRender = false,
}
local NOT_SAVED = { battle = true, walk = true, farm = true, noRender = true }
local settingsDirty = false

do
	local DEFAULT_TYPES = {}
	for k, v in pairs(S) do
		DEFAULT_TYPES[k] = type(v)
	end
	if readfile and isfile then
		pcall(function()
			if isfile(SETTINGS_FILE) then
				local data = HttpService:JSONDecode(readfile(SETTINGS_FILE))
				if type(data) == "table" then
					for k, v in pairs(data) do
						if DEFAULT_TYPES[k] == type(v) and not NOT_SAVED[k] then
							S[k] = v
						end
					end
				end
			end
		end)
	end
end

local function saveSoon()
	settingsDirty = true
end
local function saveNow()
	if not writefile then
		return
	end
	local out = {}
	for k, v in pairs(S) do
		if not NOT_SAVED[k] then
			out[k] = v
		end
	end
	pcall(function()
		writefile(SETTINGS_FILE, HttpService:JSONEncode(out))
	end)
end

local STAT = { battles = 0, gifts = 0, mail = 0, bp = 0, heals = 0, replants = 0, shoos = 0, rares = 0, fights = 0, start = os.clock() }

--// ---------------------------------------------------------------- small utils
local U = {}
function U.me()
	local c = LP.Character
	if not c then
		return nil
	end
	return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end
function U.lc(s)
	return (tostring(s or ""):gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
end
function U.csv(s)
	local out = {}
	for part in string.gmatch(tostring(s or ""), "[^,;]+") do
		local t = U.lc(part)
		if t ~= "" then
			out[#out + 1] = t
		end
	end
	return out
end
function U.desc(v, depth)
	depth = depth or 0
	if type(v) ~= "table" then
		return tostring(v)
	end
	if depth >= 2 then
		return "{...}"
	end
	local parts, n = {}, 0
	for k, x in pairs(v) do
		n += 1
		if n > 8 then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = tostring(k) .. "=" .. U.desc(x, depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end
function U.notify(title, text)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", { Title = title, Text = text, Duration = 8 })
	end)
end

--// ---------------------------------------------------------------- game binding
local G = { client = nil, nextTry = 0 }

-- the game's whole client API (see header).  Lazy, retried until ClientRunner has filled it.
function G.getClient()
	if G.client then
		return G.client
	end
	local now = os.clock()
	if now < G.nextTry then
		return nil
	end
	G.nextTry = now + 5
	local m = LP:FindFirstChild("Client")
	if not m then
		return nil
	end
	local old
	if getthreadidentity then
		pcall(function()
			old = getthreadidentity()
		end)
	end
	local ok, res = pcall(require, m)
	if old and setthreadidentity then
		pcall(setthreadidentity, old)
	end
	if ok and type(res) == "table" and type(res.Network) == "table" then
		G.client = res
		say("game client API found")
	end
	return G.client
end

function G.rem(name)
	local r = G.remotes
	if not r or not r.Parent then
		r = LP:FindFirstChild("Remotes")
		G.remotes = r
	end
	return r and r:FindFirstChild(name)
end

-- InvokeServer with a timeout.  Returns ok, results...
function G.invoke(remote, ...)
	if not remote then
		return false, "remote missing"
	end
	local args = table.pack(...)
	local done, res = false, nil
	task.spawn(function()
		res = table.pack(pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end))
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < 12 do
		task.wait(0.05)
	end
	if not done then
		return false, "timeout"
	end
	if not res[1] then
		return false, res[2]
	end
	return true, table.unpack(res, 2, res.n)
end
function G.pds(name, ...)
	return G.invoke(G.rem("PlayerDataFunc"), name, ...)
end
function G.pdsEvent(name, ...)
	local r = G.rem("PlayerDataEvent")
	if not r then
		return false
	end
	local ok = pcall(function(...)
		r:FireServer(name, ...)
	end, ...)
	return ok
end

function G.main()
	local pg = LP:FindFirstChild("PlayerGui")
	return pg and pg:FindFirstChild("MainGui")
end
function G.bbar()
	local m = G.main()
	local mb = m and m:FindFirstChild("MainBattle")
	return mb, mb and mb:FindFirstChild("BottomBar")
end

-- same test the game uses (ShownOnScreen): every GuiObject up the chain visible, ScreenGui enabled
function G.shown(o)
	if typeof(o) ~= "Instance" then
		return false
	end
	local cur = o
	while cur do
		if cur:IsA("GuiObject") then
			if not cur.Visible then
				return false
			end
		elseif cur:IsA("LayerCollector") then
			return cur.Enabled ~= false
		end
		cur = cur.Parent
	end
	return false
end

-- a shown button inside BottomBar.<group>
function G.btn(group, name)
	local _, bar = G.bbar()
	local g = bar and bar:FindFirstChild(group)
	local b = g and g:FindFirstChild(name)
	if b and G.shown(b) then
		return b
	end
end

-- lower-case text of an object and its shown text descendants (rich text tags stripped)
function G.texts(o)
	local t = {}
	if o:IsA("TextLabel") or o:IsA("TextButton") then
		t[#t + 1] = o.Text
	end
	for _, d in ipairs(o:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and G.shown(d) then
			t[#t + 1] = d.Text
		end
	end
	return U.lc(table.concat(t, " "))
end
function G.ownText(o)
	if (o:IsA("TextButton") or o:IsA("TextLabel")) and o.Text ~= "" then
		return U.lc(o.Text)
	end
	for _, d in ipairs(o:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
			return U.lc(d.Text)
		end
	end
	return ""
end

function G.currentBattle()
	local c = G.client
	local b = c and c.Battle
	return type(b) == "table" and b.CurrentBattle or nil
end
function G.inBattle()
	local c = G.client
	if c and c.Spectating then
		return false
	end
	if G.currentBattle() then
		return true
	end
	local mb = G.bbar()
	return mb ~= nil and mb.Visible == true
end
function G.canWalk()
	local c = G.client
	if not c then
		return true
	end
	if c.Controls and c.Controls.CanWalk and c.Controls:CanWalk() ~= true then
		return false
	end
	if c.Talky and c.Talky.Visible then
		return false
	end
	if c.Menu and c.Menu.Active then
		return false
	end
	return true
end

function G.hp(d)
	local cur = tonumber(d.currenthp)
	local max = type(d.Stats) == "table" and tonumber(d.Stats.hp) or nil
	if cur and max and max > 0 then
		return cur / max, cur <= 0
	end
end

-- party summary: count, alive, lowest hp ratio
function G.partyInfo()
	local ok, party = G.pds("GetParty")
	if not ok or type(party) ~= "table" then
		return nil
	end
	local info = { n = 0, alive = 0, fainted = 0, low = 1, unknown = 0 }
	for _, d in pairs(party) do
		if type(d) == "table" and d.Name then
			info.n += 1
			local ratio, dead = G.hp(d)
			if ratio then
				if dead then
					info.fainted += 1
				else
					info.alive += 1
				end
				if ratio < info.low then
					info.low = ratio
				end
			else
				info.unknown += 1
			end
		end
	end
	return info
end

--// ---------------------------------------------------------------- pressing GUI buttons
-- Four ways to "click" a game button; falls through to the next method when the button stays on screen.
local A = { idx = 1, fails = 0, order = {}, lastBtn = nil, firstAt = 0 }
do
	if getconnections then
		A.order[#A.order + 1] = "conn"
	end
	if firesignal then
		A.order[#A.order + 1] = "signal"
	end
	A.order[#A.order + 1] = "key"
	A.order[#A.order + 1] = "mouse"
end
function A.viaConn(btn)
	if not getconnections then
		return false
	end
	local ok, list = pcall(getconnections, btn.MouseButton1Click)
	if not ok or type(list) ~= "table" then
		return false
	end
	local fired = false
	for _, c in ipairs(list) do
		local done = pcall(function()
			if c.Fire then
				c:Fire()
			elseif c.Function then
				c.Function()
			else
				error("no handler")
			end
		end)
		fired = fired or done
	end
	return fired
end
function A.viaSignal(btn)
	if not firesignal then
		return false
	end
	return (pcall(firesignal, btn.MouseButton1Click))
end
function A.viaKey(code)
	local ok = pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendKeyEvent(true, code, false, game)
		task.wait(0.05)
		vim:SendKeyEvent(false, code, false, game)
	end)
	return ok
end
function A.viaMouse(btn)
	local ok = pcall(function()
		local vim = game:GetService("VirtualInputManager")
		local inset = game:GetService("GuiService"):GetGuiInset()
		local p, s = btn.AbsolutePosition, btn.AbsoluteSize
		local x, y = p.X + s.X / 2 + inset.X, p.Y + s.Y / 2 + inset.Y
		vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
		task.wait(0.05)
		vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
	end)
	return ok
end
function A.press(btn, key)
	if not btn then
		return false
	end
	local m = A.order[A.idx]
	local ok = false
	if m == "conn" then
		ok = A.viaConn(btn)
	elseif m == "signal" then
		ok = A.viaSignal(btn)
	elseif m == "key" then
		-- hotkey where the game has one, a real mouse click for the rest (Next, party slots, ...)
		if key then
			ok = A.viaKey(key)
		else
			ok = A.viaMouse(btn)
		end
	else
		ok = A.viaMouse(btn)
	end
	if not ok then
		ok = A.viaConn(btn) or A.viaSignal(btn) or A.viaMouse(btn)
	end
	local now = os.clock()
	if A.lastBtn ~= btn then
		A.firstAt = now -- same button pressed again = the earlier press did nothing yet
	end
	A.lastBtn = btn
	return ok
end
-- a slot may be a frame with a button inside: press the button, else click the frame itself
function A.pressAny(o)
	if o:IsA("GuiButton") then
		return A.press(o)
	end
	local inner = o:FindFirstChildWhichIsA("GuiButton", true)
	if inner then
		return A.press(inner)
	end
	return A.viaMouse(o)
end
-- called every battle tick: did the last pressed button actually do something?
function A.check()
	local b = A.lastBtn
	if not b then
		return
	end
	if not G.shown(b) then
		A.fails, A.lastBtn = 0, nil
		return
	end
	if os.clock() - (A.firstAt or 0) >= 1.6 then
		A.firstAt = os.clock()
		A.fails += 1
		if A.fails >= 2 and #A.order > 1 then
			A.fails = 0
			A.idx = A.idx % #A.order + 1
			say("button press method -> " .. A.order[A.idx])
		end
	end
end

--// ---------------------------------------------------------------- auto battle
local B = {
	wasIn = false,
	cool = {},
	bad = {},
	state = "idle",
	hold = nil,
	skip = false,
	scanned = false,
	lastAct = 0,
	lastDiag = 0,
	partyBad = {},
	startedAt = 0,
}

function B.can(name, gap)
	local now = os.clock()
	if now - (B.cool[name] or -9) < (gap or 0.7) then
		return false
	end
	B.cool[name] = now
	return true
end

-- misprint (Shiny / Sc), legendary / mythic, or a name on the watch list
function B.rareTag(bd)
	if type(bd) ~= "table" or bd.BattleType ~= "Wild" then
		return nil
	end
	local c = G.client
	local watch = U.csv(S.rareList)
	local function check(d)
		if type(d) ~= "table" or not (d.Name or d.RealName) then
			return nil
		end
		local name = d.RealName or d.Name
		local lname = U.lc(name)
		if d.Shiny or d.Sc then
			return name, "misprint"
		end
		for _, w in ipairs(watch) do
			if w == lname then
				return name, "watch list"
			end
		end
		if c then
			local leg = false
			pcall(function()
				if c.Utilities and c.Utilities.IsLegendary and c.Utilities:IsLegendary(name) then
					leg = true
				end
				local info = c.DoodleInfo and c.DoodleInfo[name]
				if info and info.Roulette == "Legendary" then
					leg = true
				end
			end)
			if leg then
				return name, "legendary"
			end
		end
		return nil
	end
	for _, d in pairs(bd.Out2 or {}) do
		local n, tag = check(d)
		if n then
			return n, tag
		end
	end
	for _, d in pairs(bd.Player2Party or {}) do
		local n, tag = check(d)
		if n then
			return n, tag
		end
	end
	return nil
end

function B.moveScore(m)
	local txt = G.texts(m.b)
	local cur = txt:match("(%d+)%s*/%s*%d+")
	if cur and tonumber(cur) == 0 then
		return -1000
	end
	local s = 0
	local eff = m.b:FindFirstChild("Effective")
	if eff and G.shown(eff) then
		local et = G.texts(eff)
		local mult = tonumber(et:match("(%d*%.?%d+)%s*x")) or tonumber(et:match("x%s*(%d*%.?%d+)"))
		if mult then
			if mult == 0 then
				s -= 6
			elseif mult < 1 then
				s -= 2
			elseif mult >= 2 then
				s += 3
			end
		elseif et:find("super") or et:find("double") then
			s += 3
		elseif et:find("no effect") or et:find("immune") then
			s -= 6
		elseif et:find("not very") or et:find("resist") or et:find("half") then
			s -= 2
		end
	end
	return s
end

function B.pickMove(list)
	local now = os.clock()
	local pool = {}
	for _, m in ipairs(list) do
		if not (B.bad[m.i] and now - B.bad[m.i] < 12) then
			pool[#pool + 1] = m
		end
	end
	if #pool == 0 then
		B.bad = {}
		pool = list
	end
	local mode = S.moveMode
	local slot = tonumber(string.match(mode, "^Slot (%d)$"))
	if slot then
		for _, m in ipairs(pool) do
			if m.i == slot then
				return m
			end
		end
	end
	if mode == "Random" then
		return pool[math.random(#pool)]
	end
	local best, bs
	for _, m in ipairs(pool) do
		local sc = B.moveScore(m)
		if not bs or sc > bs then
			best, bs = m, sc
		end
	end
	return best
end

local KEYS = { Fight = Enum.KeyCode.Q, Move1 = Enum.KeyCode.One, Move2 = Enum.KeyCode.Two, Move3 = Enum.KeyCode.Three, Move4 = Enum.KeyCode.Four }

local DISMISS_BATTLE = { ["ok"] = true, ["okay"] = true, ["continue"] = true, ["next"] = true, ["close"] = true, ["done"] = true, ["skip"] = true, ["no"] = true, ["don't learn"] = true, ["do not learn"] = true, ["keep"] = true }
local DISMISS_PARTY = { ["switch"] = true, ["send out"] = true, ["send"] = true, ["confirm"] = true, ["yes"] = true, ["ok"] = true }
local ACTION_PARENTS = { Actions = true, Moves = true, SelectTarget = true }

-- press whitelisted buttons (by their text) under root; returns true if something was pressed
function B.dismiss(root, words)
	if not root then
		return false
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiButton") and G.shown(d) then
			local p = d.Parent
			local skip = false
			while p and p ~= root do
				if ACTION_PARENTS[p.Name] then
					skip = true
					break
				end
				p = p.Parent
			end
			if not skip then
				local t = G.ownText(d)
				if t ~= "" and words[t] and B.can("dis_" .. d.Name .. t, 1.2) then
					A.press(d)
					say("battle: pressed '" .. t .. "'")
					return true
				end
			end
		end
	end
	return false
end

function B.diag()
	local mb, bar = G.bbar()
	local shown = {}
	local function scan(root, tag)
		if not root then
			return
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("GuiButton") and G.shown(d) and #shown < 24 then
				shown[#shown + 1] = tag .. ":" .. d.Name .. "='" .. G.ownText(d):sub(1, 18) .. "'"
			end
		end
	end
	scan(bar, "bar")
	local m = G.main()
	scan(m and m:FindFirstChild("PartyUI"), "party")
	say("battle seems stuck (state " .. B.state .. "). Shown buttons: " .. (#shown > 0 and table.concat(shown, ", ") or "none"))
	if mb then
		local say2 = bar and bar:FindFirstChild("Say")
		if say2 and say2:IsA("TextLabel") then
			say(" battle text: " .. U.lc(say2.Text):sub(1, 90))
		end
	end
end

function B.onStart()
	B.wasIn = true
	B.hold, B.skip, B.scanned = nil, false, false
	B.bad, B.partyBad, B.cool = {}, {}, {}
	B.lastAct = os.clock()
	B.startedAt = os.clock()
	B.state = "battle starting"
end
function B.onEnd()
	B.wasIn = false
	B.hold, B.skip = nil, false
	STAT.battles += 1
	B.state = "idle"
	local c = G.client
	if c and B.origSpeed ~= nil then
		pcall(function()
			c.BattleTimeScale = B.origSpeed
		end)
		B.origSpeed = nil
	end
end

function B.step()
	A.check()
	G.getClient() -- fills G.client when ready; everything below also works GUI-only
	local inb = G.inBattle()
	if not inb then
		if B.wasIn then
			B.onEnd()
		end
		return
	end
	if not B.wasIn then
		B.onStart()
	end
	local c = G.client
	local bd = G.currentBattle()
	if bd and not B.scanned then
		B.scanned = true
		if bd.BattleType == "PvP" then
			B.skip = true
			say("PvP battle - auto battle stays out of it")
		end
		local name, tag = B.rareTag(bd)
		if name then
			STAT.rares += 1
			say(string.format("RARE wild Doodle: %s (%s)", name, tag))
			U.notify("Doodle Farm", string.format("Rare: %s (%s)", name, tag))
			if S.rareAction == "Pause" then
				B.hold = string.format("%s (%s)", name, tag)
				say("auto battle paused for this fight - catch it yourself (Resume on the Auto tab continues)")
			end
		end
	end
	-- the rare scan needs the battle data: do not press anything until it is there (max 4 s)
	if c and not bd and os.clock() - B.startedAt < 4 then
		B.state = "battle starting"
		return
	end
	if S.speed > 0 and c then
		pcall(function()
			if B.origSpeed == nil then
				B.origSpeed = c.BattleTimeScale or 1
			end
			c.BattleTimeScale = S.speed
		end)
	end
	if not S.battle then
		B.state = "battle (manual)"
		return
	end
	if B.skip then
		B.state = "PvP (manual)"
		return
	end
	if B.hold then
		B.state = "PAUSED: " .. B.hold
		return
	end

	local mb, bar = G.bbar()
	if not bar then
		B.state = "battle: no UI"
		return
	end

	-- "switch Doodle?" yes/no
	if S.noSwitch and c and c.BattleNo then
		local live, btn = false, nil
		pcall(function()
			live = c.BattleNo.Live()
			btn = c.BattleNo.Button
		end)
		if live and btn and G.shown(btn) and B.can("battleno", 1.5) then
			B.state = "answering No"
			B.lastAct = os.clock()
			task.spawn(function()
				pcall(c.BattleNo.Run)
			end)
			return
		end
	end

	-- doubles: pick a target
	local st = bar:FindFirstChild("SelectTarget")
	if st and G.shown(st) then
		for i = 1, 4 do
			local f = st:FindFirstChild("Front" .. i)
			if f and G.shown(f) and B.can("target", 0.8) then
				B.state = "picking target " .. i
				B.lastAct = os.clock()
				A.pressAny(f)
				return
			end
		end
	end

	-- moves
	local list = {}
	for i = 1, 4 do
		local b = G.btn("Moves", "Move" .. i)
		if b then
			list[#list + 1] = { i = i, b = b }
		end
	end
	if #list > 0 then
		local m = B.pickMove(list)
		if m and B.can("move", 0.8) then
			if A.lastBtn == m.b then
				B.bad[m.i] = os.clock()
			end
			B.state = "move " .. m.i
			B.lastAct = os.clock()
			STAT.fights += 1
			A.press(m.b, KEYS["Move" .. m.i])
		end
		return
	end

	-- fight menu
	local fight = G.btn("Actions", "Fight")
	if fight then
		if B.can("fight", 0.8) then
			B.state = "fight menu"
			B.lastAct = os.clock()
			A.press(fight, KEYS.Fight)
		end
		return
	end

	-- forced switch (a Doodle fainted): party screen is up
	local main = G.main()
	local party = main and main:FindFirstChild("PartyUI")
	if party and G.shown(party) then
		B.state = "party screen"
		B.lastAct = os.clock()
		if B.dismiss(party, DISMISS_PARTY) then
			return
		end
		local holder = party:FindFirstChild("Holder")
		if holder and B.can("partypick", 1.4) then
			for _, slot in ipairs(holder:GetChildren()) do
				if slot.Name:find("Party") and slot:IsA("GuiObject") and G.shown(slot) and not B.partyBad[slot.Name] then
					local txt = G.texts(slot)
					local cur = txt:match("(%d+)%s*/%s*%d+")
					if not txt:find("faint") and not (cur and tonumber(cur) == 0) then
						B.partyBad[slot.Name] = true
						say("battle: sending out " .. slot.Name)
						A.pressAny(slot)
						return
					end
				end
			end
			-- everything tried once: let them retry (the click may have been swallowed)
			B.partyBad = {}
		end
		return
	end

	-- dialogue / continue buttons
	local nxt = bar:FindFirstChild("Next")
	if nxt and G.shown(nxt) and B.can("next", 0.6) then
		B.state = "next"
		B.lastAct = os.clock()
		if nxt:IsA("GuiButton") then
			A.press(nxt)
		else
			A.viaMouse(nxt) -- an arrow indicator rather than a button: click on it
		end
		return
	end
	if S.dismiss and B.can("dismissscan", 1.0) then
		if B.dismiss(mb, DISMISS_BATTLE) then
			B.lastAct = os.clock()
			return
		end
	end
	B.state = "battle: waiting"
	local now = os.clock()
	if now - B.lastAct > 12 and now - B.lastDiag > 25 then
		B.lastDiag = now
		B.diag()
	end
end
loop("battle", 0.25, B.step)

--// ---------------------------------------------------------------- roam (walk on grass for encounters)
local W = {
	anchor = nil,
	target = nil,
	expire = 0,
	lastPos = nil,
	lastT = 0,
	stuck = 0,
	miss = 0,
	note = "off",
	nextFind = 0,
	grass = { Grass = true, WildGrass = true, CoveGrass = true, IceGrass = true, DesertGrass = true, WaterGrass = true },
}

function W.ground(pos, char)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = { char, Workspace.Terrain }
	return Workspace:Raycast(Vector3.new(pos.X, pos.Y + 14, pos.Z), Vector3.new(0, -60, 0), p)
end

function W.pick(char, hrp)
	local base = W.anchor or hrp.Position
	for _ = 1, 14 do
		local a, r = math.random() * math.pi * 2, math.sqrt(math.random()) * S.walkRadius
		local p = Vector3.new(base.X + math.cos(a) * r, base.Y, base.Z + math.sin(a) * r)
		local hit = W.ground(p, char)
		if hit and math.abs(hit.Position.Y - base.Y) < 7 and (not S.grassOnly or W.grass[hit.Instance.Name]) then
			W.target = hit.Position
			W.expire = os.clock() + 7
			W.miss = 0
			return true
		end
	end
	W.miss += 1
	return false
end

function W.findGrass(hrp)
	local now = os.clock()
	if now < W.nextFind then
		return false
	end
	W.nextFind = now + 8
	local c = G.client
	local root = (c and typeof(c.CurrentChunk) == "Instance" and c.CurrentChunk) or Workspace
	local best, bd
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and W.grass[d.Name] then
			local dist = (d.Position - hrp.Position).Magnitude
			if not bd or dist < bd then
				best, bd = d, dist
			end
		end
	end
	if not best then
		W.note = "no grass found nearby"
		return false
	end
	W.anchor = best.Position + Vector3.new(0, best.Size.Y / 2, 0)
	W.miss = 0
	say(string.format("roam: no grass around the anchor, heading to the nearest grass part (%d studs)", bd))
	return true
end

function W.stop(hum)
	if hum then
		pcall(function()
			hum:Move(Vector3.zero, false)
		end)
	end
	W.target = nil
end

function W.setAnchor()
	local _, hrp = U.me()
	if hrp then
		W.anchor = hrp.Position
		W.target = nil
		say("roam anchor set to your position")
	end
end

track(RunService.Heartbeat:Connect(function()
	if not alive then
		return
	end
	local char, hrp, hum = U.me()
	if not (S.walk and char and hrp and hum) then
		if W.target then
			W.stop(hum)
		end
		W.note = S.walk and "no character" or "off"
		return
	end
	if hum.Health <= 0 then
		return
	end
	if not G.canWalk() or G.inBattle() then
		if W.target then
			W.stop(hum)
		end
		W.note = "paused (battle / menu / cutscene)"
		return
	end
	local now = os.clock()
	if not W.anchor then
		W.anchor = hrp.Position
	end
	local flat = Vector3.new(hrp.Position.X - W.anchor.X, 0, hrp.Position.Z - W.anchor.Z).Magnitude
	if not W.target or now > W.expire or flat > S.walkRadius + 40 then
		if flat > S.walkRadius + 40 then
			W.target = Vector3.new(W.anchor.X, hrp.Position.Y, W.anchor.Z)
			W.expire = now + 10
		elseif not W.pick(char, hrp) then
			if S.grassOnly and W.miss >= 3 then
				W.findGrass(hrp)
			end
			W.note = "looking for grass..."
			return
		end
	end
	local d = Vector3.new(W.target.X - hrp.Position.X, 0, W.target.Z - hrp.Position.Z)
	if d.Magnitude < 3 then
		W.target = nil
		return
	end
	W.note = "walking"
	pcall(function()
		hum:Move(d.Unit, false)
	end)
	if now - W.lastT > 1.0 then
		if W.lastPos and (hrp.Position - W.lastPos).Magnitude < 1.0 then
			hum.Jump = true
			W.stuck += 1
			if W.stuck >= 2 then
				W.target, W.stuck = nil, 0
			end
		else
			W.stuck = 0
		end
		W.lastPos, W.lastT = hrp.Position, now
	end
end))

--// ---------------------------------------------------------------- heal
local H = { last = nil, fail = 0, nextTry = 0, off = false, note = "-", infoAt = 0 }

loop("party", 4, function()
	if G.inBattle() then
		return
	end
	local info = G.partyInfo()
	if info then
		H.last = info
		H.infoAt = os.clock()
	end
end)

loop("heal", 3, function()
	local c = G.client
	if not S.heal or H.off or G.inBattle() or _G.InDungeon or not (c and c.Loaded) then
		return -- (not loaded yet = still on the title screen / intro: a Heal there would only count as a failure)
	end
	local info = H.last
	if not info or os.clock() - H.infoAt > 12 or info.n == 0 then
		return
	end
	local needs = info.fainted > 0 or info.low * 100 < S.healBelow
	if not needs or os.clock() < H.nextTry then
		return
	end
	H.nextTry = os.clock() + 25
	local before = info
	say(string.format("heal: party low (%d%%, %d fainted) - sending Heal", math.floor(info.low * 100), info.fainted))
	G.pdsEvent("Heal")
	task.wait(2)
	local after = G.partyInfo()
	if after then
		H.last, H.infoAt = after, os.clock()
		if after.fainted < before.fainted or after.low > before.low + 0.05 then
			STAT.heals += 1
			H.fail = 0
			H.note = "healed"
			say("heal worked")
			return
		end
	end
	H.fail += 1
	H.note = "heal had no effect (" .. H.fail .. ")"
	if H.fail >= 3 then
		H.off = true
		say("heal: the server ignores a remote Heal here. Use a healing station / let a whiteout heal you; auto heal is off until you press Re-enable.")
	end
end)

--// ---------------------------------------------------------------- farm plots
local FM = { fighting = false, note = "-", lastInfo = "-", notified = {} }

function FM.plantEmpty(info)
	local plant = info.Plant
	if type(plant) ~= "table" then
		return true
	end
	for _, v in pairs(plant) do
		if type(v) == "table" and v.Name then
			return false
		end
	end
	return true
end

function FM.replant(id, info)
	if not S.farmReplant or type(info.LastPlant) ~= "table" then
		return
	end
	local ok, farm, msg = G.pds("GroupPlantFarm", id, info.LastPlant)
	if ok and farm then
		STAT.replants += 1
		say(string.format("farm plot %d replanted%s", id, type(msg) == "string" and (" - " .. msg:sub(1, 60)) or ""))
	else
		say(string.format("farm plot %d replant failed: %s", id, tostring(farm)))
	end
end

function FM.fight(id)
	local c = G.getClient()
	if not (c and c.Steps and c.Steps.Encounter) then
		return false, "Steps module not reachable"
	end
	if FM.fighting then
		return false, "already fighting"
	end
	FM.fighting = true
	task.spawn(function()
		local ok, sig = pcall(function()
			return c.Steps:Encounter("Sweetsville", "FarmPlotFight" .. id, function() end)
		end)
		if not ok then
			say("farm fight error: " .. tostring(sig))
		end
		local t0 = os.clock()
		while alive and os.clock() - t0 < 20 and not G.inBattle() do
			task.wait(0.3)
		end
		while alive and os.clock() - t0 < 600 and G.inBattle() do
			task.wait(0.5)
		end
		task.wait(1.5)
		FM.fighting = false
	end)
	return true
end

function FM.tick()
	if G.inBattle() or FM.fighting then
		return
	end
	local ok, farm = G.pds("GetFarm", true)
	if not ok or type(farm) ~= "table" then
		FM.note = "GetFarm failed: " .. tostring(farm)
		return
	end
	local parts = {}
	for key, plot in pairs(farm) do
		local id = tonumber(string.match(tostring(key), "^Plot(%d+)$"))
		local info = id and type(plot) == "table" and plot.PlotInfo
		if info then
			if not info.Unlocked then
				parts[#parts + 1] = id .. ":locked"
			elseif info.DoodlePresent then
				parts[#parts + 1] = id .. ":DOODLE"
				if S.farm and S.farmAction == "Notify only" then
					if not FM.notified[id] then
						FM.notified[id] = true
						local d = info.DoodlePresent
						local nm = type(d) == "table" and (d.RealName or d.Name) or "a Doodle"
						say(string.format("farm plot %d: wild %s appeared (left alone - Notify only)", id, tostring(nm)))
						U.notify("Doodle Farm", string.format("Plot %d: %s appeared", id, tostring(nm)))
					end
				elseif S.farm then
					if S.farmAction == "Battle" and G.canWalk() then
						local started, why = FM.fight(id)
						if started then
							say("farm plot " .. id .. ": fighting the wild Doodle")
						else
							say("farm plot " .. id .. ": cannot fight (" .. tostring(why) .. ")")
						end
						return
					end
					local okS = G.pds("ShooFarm", id)
					if okS then
						STAT.shoos += 1
						say("farm plot " .. id .. ": shooed the wild Doodle")
						FM.replant(id, info)
					end
				end
			elseif FM.plantEmpty(info) then
				FM.notified[id] = nil
				parts[#parts + 1] = id .. ":empty"
				if S.farm and info.LastPlant then
					FM.replant(id, info)
				end
			else
				FM.notified[id] = nil
				parts[#parts + 1] = id .. ":growing"
			end
		end
	end
	table.sort(parts)
	FM.lastInfo = #parts > 0 and table.concat(parts, "  ") or "no plots"
	FM.note = "ok"
end

-- after a farm fight the plants are used up: replant the next tick (the loop does it via "empty")
loop("farm", 5, function()
	FM.due = FM.due or 0
	if not S.farm or os.clock() < FM.due then
		return
	end
	FM.due = os.clock() + math.max(S.farmEvery, 10)
	FM.tick()
end)

--// ---------------------------------------------------------------- claims
local CL = { bp = nil, bpTried = {}, mailBad = {}, note = "-", mailNote = "-", gDue = 0, mDue = 0, bDue = 0 }

do
	-- Battlepass snapshot: the game's own UpdateBP handler gets the same table
	local ev = G.rem("UpdateBP")
	if ev and ev:IsA("RemoteEvent") then
		track(ev.OnClientEvent:Connect(function(bp)
			if type(bp) == "table" then
				CL.bp = bp
				CL.bpTried = {}
			end
		end))
	end
end

function CL.gifts()
	local m = G.main()
	local dfg = m and m:FindFirstChild("DailyFreeGifts")
	local holder = dfg and dfg:FindFirstChild("Holder")
	local claimed = 0
	if holder then
		for _, child in ipairs(holder:GetChildren()) do
			local i = tonumber(child.Name)
			local claim = i and child:FindFirstChild("Claim")
			if claim and claim.Visible then
				G.pdsEvent("ClaimGift", i)
				STAT.gifts += 1
				claimed += 1
				say("free gift " .. i .. " claimed")
				task.wait(1.2)
			end
		end
	end
	CL.note = claimed > 0 and ("claimed " .. claimed) or "nothing ready"
end

function CL.mail()
	local ok, mails = G.invoke(G.rem("GetMail"))
	if not ok then
		CL.mailNote = "GetMail failed: " .. tostring(mails)
		return
	end
	if type(mails) ~= "table" then
		CL.mailNote = "GetMail returned " .. typeof(mails)
		return
	end
	if not CL.mailLogged then
		CL.mailLogged = true
		say("GetMail shape: " .. U.desc(mails))
	end
	local done, seen = 0, 0
	for k, m in pairs(mails) do
		seen += 1
		local id
		if type(m) == "table" then
			id = m.Id or m.ID or m.id or m.MailId or m.Key
			if id == nil and type(k) == "string" then
				id = k
			end
			if m.Claimed or m.claimed or (type(m.Content) == "table" and m.Content.GuildInvite) then
				id = nil
			end
		elseif type(m) == "string" or type(m) == "number" then
			id = m
		end
		if id ~= nil and not CL.mailBad[tostring(id)] and done < 8 then
			local okC, success = G.invoke(G.rem("ClaimMail"), id)
			CL.mailBad[tostring(id)] = true -- one try per mail
			if okC and success then
				done += 1
				STAT.mail += 1
				say("mail " .. tostring(id) .. " claimed")
			end
			task.wait(0.8)
		end
	end
	CL.mailNote = string.format("%d mails, claimed %d", seen, done)
end

function CL.battlepass()
	local bp = CL.bp
	if not bp or type(bp.CT) ~= "number" then
		CL.note = "no Battlepass snapshot yet (open the Battlepass once / gain XP)"
		return
	end
	local cr = type(bp.CR) == "table" and bp.CR or {}
	local n = 0
	for tier = 1, bp.CT do
		for _, track2 in ipairs({ "f", "p" }) do
			local premium = track2 == "p"
			local key = track2 .. tier
			if n < 6 and (not premium or bp.P) and not table.find(cr, key) and not CL.bpTried[key] then
				CL.bpTried[key] = true
				local ok, success = G.invoke(G.rem("ClaimBP"), premium, tier)
				if ok and success then
					n += 1
					STAT.bp += 1
					say("battlepass " .. (premium and "premium" or "free") .. " tier " .. tier .. " claimed")
				end
				task.wait(0.8)
			end
		end
	end
	CL.note = n > 0 and ("claimed " .. n .. " BP rewards") or "BP up to date"
end

loop("claims", 5, function()
	local now = os.clock()
	if S.claimGifts and now >= CL.gDue then
		CL.gDue = now + 25
		CL.gifts()
	end
	if S.claimMail and now >= CL.mDue then
		CL.mDue = now + 120
		CL.mail()
	end
	if S.claimBP and now >= CL.bDue then
		CL.bDue = now + 60
		CL.battlepass()
	end
end)

--// ---------------------------------------------------------------- misc: anti afk, render, debug
local M = {}

do
	local VU
	pcall(function()
		VU = game:GetService("VirtualUser")
	end)
	track(LP.Idled:Connect(function()
		if S.antiAfk and VU then
			pcall(function()
				VU:CaptureController()
				VU:ClickButton2(Vector2.new())
			end)
		end
	end))
end

function M.render()
	pcall(function()
		RunService:Set3dRenderingEnabled(not S.noRender)
	end)
end

function M.debug()
	local c = G.getClient()
	say("---- debug ----")
	say("place " .. tostring(game.PlaceId) .. " | client API: " .. (c and "yes" or "NO") .. " | Remotes folder: " .. (G.rem("PlayerDataFunc") and "yes" or "NO"))
	if c then
		local have = {}
		for _, k in ipairs({ "Battle", "BattleNo", "ClientDatabase", "Controls", "Steps", "Utilities", "Menu", "CurrentChunk", "Loaded" }) do
			have[#have + 1] = k .. "=" .. (c[k] ~= nil and "y" or "n")
		end
		say("client: " .. table.concat(have, " "))
		local cw = "?"
		pcall(function()
			cw = tostring(c.Controls:CanWalk())
		end)
		say("CanWalk " .. cw .. " | InDungeon " .. tostring(_G.InDungeon))
	end
	say("in battle: " .. tostring(G.inBattle()) .. " | state: " .. B.state .. " | press method: " .. tostring(A.order[A.idx]))
	local _, bar = G.bbar()
	if bar then
		local shown = {}
		for _, d in ipairs(bar:GetDescendants()) do
			if d:IsA("GuiButton") and G.shown(d) then
				shown[#shown + 1] = d.Name
			end
		end
		say("battle buttons shown: " .. (#shown > 0 and table.concat(shown, ", ") or "none"))
	end
	local info = G.partyInfo()
	if info then
		say(string.format("party: %d Doodles, %d alive, %d fainted, lowest HP %d%% (unknown HP: %d)", info.n, info.alive, info.fainted, math.floor(info.low * 100), info.unknown))
	else
		say("party: GetParty failed")
	end
	say("farm: " .. FM.lastInfo .. " | " .. FM.note)
	say("claims: gifts " .. CL.note .. " | mail " .. CL.mailNote .. " | BP snapshot " .. (CL.bp and ("tier " .. tostring(CL.bp.CT)) or "none"))
	say("roam: " .. W.note .. " | heal: " .. H.note .. (H.off and " (OFF)" or ""))
end

--// ---------------------------------------------------------------- unload
local unloaded = false
local function doUnload()
	if unloaded then
		return
	end
	unloaded = true
	saveNow()
	alive = false
	S.battle, S.walk, S.farm = false, false, false
	pcall(function()
		local _, _, hum = U.me()
		W.stop(hum)
	end)
	pcall(function()
		RunService:Set3dRenderingEnabled(true)
	end)
	pcall(function()
		local c = G.client
		if c and B.origSpeed ~= nil then
			c.BattleTimeScale = B.origSpeed
		end
	end)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	for _, f in ipairs(cleanups) do
		pcall(f)
	end
end
ENV.__DoodleFarmUnload = doUnload

--// ---------------------------------------------------------------- GUI
local parent
pcall(function()
	parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
parent = parent or LP:WaitForChild("PlayerGui")
local oldGui = parent:FindFirstChild("DoodleFarmGui")
if oldGui then
	oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "DoodleFarmGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if syn and syn.protect_gui then
	pcall(syn.protect_gui, gui)
end
gui.Parent = parent
onUnload(function()
	gui:Destroy()
end)

local Col = {
	bg = Color3.fromRGB(22, 24, 32),
	bar = Color3.fromRGB(32, 36, 50),
	card = Color3.fromRGB(38, 42, 58),
	acc = Color3.fromRGB(70, 150, 255),
	on = Color3.fromRGB(60, 185, 110),
	off = Color3.fromRGB(78, 82, 100),
	txt = Color3.fromRGB(235, 237, 246),
	dim = Color3.fromRGB(160, 165, 185),
	red = Color3.fromRGB(190, 60, 70),
}

local UI = {}
local painters = {}
function UI.mk(class, props, par)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = par
	return o
end
function UI.corner(o, r)
	UI.mk("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o)
end

local main = UI.mk("Frame", {
	Name = "Main",
	Size = UDim2.fromOffset(440, 590),
	Position = UDim2.new(0, 30, 0.5, -295),
	BackgroundColor3 = Col.bg,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, gui)
UI.corner(main, 10)

local bar = UI.mk("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = Col.bar, BorderSizePixel = 0 }, main)
UI.mk("TextLabel", {
	Size = UDim2.new(1, -90, 1, 0),
	Position = UDim2.fromOffset(12, 0),
	BackgroundTransparency = 1,
	Text = "Doodle Farm  -  battle / roam / farm / claims",
	TextColor3 = Col.txt,
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, bar)
local btnMin = UI.mk("TextButton", { Size = UDim2.fromOffset(26, 22), Position = UDim2.new(1, -62, 0, 5), BackgroundColor3 = Col.off, Text = "-", TextColor3 = Col.txt, Font = Enum.Font.GothamBold, TextSize = 14 }, bar)
local btnClose = UI.mk("TextButton", { Size = UDim2.fromOffset(26, 22), Position = UDim2.new(1, -32, 0, 5), BackgroundColor3 = Col.red, Text = "X", TextColor3 = Col.txt, Font = Enum.Font.GothamBold, TextSize = 12 }, bar)
UI.corner(btnMin, 5)
UI.corner(btnClose, 5)

do -- dragging
	local dragging, start, startPos
	track(bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, start, startPos = true, i.Position, main.Position
		end
	end))
	track(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - start
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	track(UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

local statusBox = UI.mk("Frame", { Size = UDim2.new(1, -16, 0, 78), Position = UDim2.fromOffset(8, 38), BackgroundColor3 = Col.card, BorderSizePixel = 0 }, main)
UI.corner(statusBox, 6)
local stLines = {}
for i = 1, 4 do
	stLines[i] = UI.mk("TextLabel", {
		Size = UDim2.new(1, -14, 0, 18),
		Position = UDim2.fromOffset(8, 3 + (i - 1) * 18.5),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = i == 1 and Col.txt or Col.dim,
		Font = i == 1 and Enum.Font.GothamBold or Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, statusBox)
end

local tabBar = UI.mk("Frame", { Size = UDim2.new(1, -16, 0, 26), Position = UDim2.fromOffset(8, 122), BackgroundTransparency = 1 }, main)
UI.mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)
local body = UI.mk("Frame", { Size = UDim2.new(1, -16, 1, -160), Position = UDim2.fromOffset(8, 152), BackgroundTransparency = 1 }, main)

local pages, tabBtns = {}, {}
local function showTab(name)
	for n, p in pairs(pages) do
		p.Visible = n == name
		tabBtns[n].BackgroundColor3 = n == name and Col.acc or Col.off
	end
end
function UI.page(name, order)
	local sf = UI.mk("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
	}, body)
	UI.mk("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	UI.mk("UIPadding", { PaddingRight = UDim.new(0, 6) }, sf)
	pages[name] = sf
	local b = UI.mk("TextButton", {
		Size = UDim2.new(1 / 6, -4, 1, 0),
		BackgroundColor3 = Col.off,
		Text = name,
		TextColor3 = Col.txt,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		LayoutOrder = order,
	}, tabBar)
	UI.corner(b, 5)
	tabBtns[name] = b
	b.MouseButton1Click:Connect(function()
		showTab(name)
	end)
	return sf
end

local rowOrder = 0
function UI.row(page, h)
	rowOrder += 1
	local r = UI.mk("Frame", { Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = Col.card, BorderSizePixel = 0, LayoutOrder = rowOrder }, page)
	UI.corner(r, 6)
	return r
end
function UI.section(page, text)
	rowOrder += 1
	UI.mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Text = string.upper(text),
		TextColor3 = Col.acc,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = rowOrder,
	}, page)
end
function UI.note(page, text, h)
	local r = UI.row(page, h or 34)
	return UI.mk("TextLabel", {
		Size = UDim2.new(1, -14, 1, -4),
		Position = UDim2.fromOffset(8, 2),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = Col.dim,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, r)
end
function UI.toggle(page, text, key, cb)
	local r = UI.row(page, 30)
	UI.mk("TextLabel", { Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = text, TextColor3 = Col.txt, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, r)
	local b = UI.mk("TextButton", { Size = UDim2.fromOffset(52, 20), Position = UDim2.new(1, -60, 0.5, -10), Text = "", AutoButtonColor = false }, r)
	UI.corner(b, 10)
	local knob = UI.mk("Frame", { Size = UDim2.fromOffset(16, 16), BackgroundColor3 = Col.txt, BorderSizePixel = 0 }, b)
	UI.corner(knob, 8)
	local function paint()
		local on = S[key] == true
		b.BackgroundColor3 = on and Col.on or Col.off
		knob.Position = on and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
	end
	paint()
	painters[key] = paint
	b.MouseButton1Click:Connect(function()
		S[key] = not S[key]
		paint()
		saveSoon()
		if cb then
			cb(S[key])
		end
	end)
	return paint
end
function UI.button(page, text, fn, color)
	local r = UI.row(page, 30)
	local b = UI.mk("TextButton", { Size = UDim2.new(1, -12, 1, -6), Position = UDim2.fromOffset(6, 3), BackgroundColor3 = color or Col.acc, Text = text, TextColor3 = Col.txt, Font = Enum.Font.GothamBold, TextSize = 12 }, r)
	UI.corner(b, 5)
	b.MouseButton1Click:Connect(function()
		task.spawn(function()
			local ok, err = pcall(fn, b)
			if not ok then
				say("button error: " .. tostring(err))
			end
		end)
	end)
	return b
end
function UI.slider(page, text, key, lo, hi, step, cb)
	local r = UI.row(page, 44)
	local lab = UI.mk("TextLabel", { Size = UDim2.new(1, -16, 0, 18), Position = UDim2.fromOffset(10, 3), BackgroundTransparency = 1, Text = "", TextColor3 = Col.txt, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, r)
	local trk = UI.mk("Frame", { Size = UDim2.new(1, -24, 0, 8), Position = UDim2.fromOffset(12, 28), BackgroundColor3 = Col.off, BorderSizePixel = 0 }, r)
	UI.corner(trk, 4)
	local fill = UI.mk("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Col.acc, BorderSizePixel = 0 }, trk)
	UI.corner(fill, 4)
	local function paint()
		local v = S[key]
		lab.Text = string.format("%s: %s", text, tostring(math.floor(v * 1000 + 0.5) / 1000))
		fill.Size = UDim2.fromScale(math.clamp((v - lo) / (hi - lo), 0, 1), 1)
	end
	paint()
	local dragging = false
	local function setFrom(x)
		local rel = math.clamp((x - trk.AbsolutePosition.X) / math.max(trk.AbsoluteSize.X, 1), 0, 1)
		local v = lo + (hi - lo) * rel
		v = math.clamp(math.floor(v / step + 0.5) * step, lo, hi)
		S[key] = v
		paint()
		saveSoon()
		if cb then
			cb(v)
		end
	end
	track(trk.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFrom(i.Position.X)
		end
	end))
	track(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			setFrom(i.Position.X)
		end
	end))
	track(UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end
function UI.textbox(page, text, key, placeholder, cb)
	local r = UI.row(page, 30)
	UI.mk("TextLabel", { Size = UDim2.new(0.4, -10, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = text, TextColor3 = Col.txt, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, r)
	local tb = UI.mk("TextBox", { Size = UDim2.new(0.6, -14, 0, 22), Position = UDim2.new(0.4, 4, 0.5, -11), BackgroundColor3 = Col.off, Text = key and tostring(S[key]) or "", PlaceholderText = placeholder or "", PlaceholderColor3 = Col.dim, TextColor3 = Col.txt, Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false }, r)
	UI.corner(tb, 5)
	tb.FocusLost:Connect(function()
		if key then
			S[key] = tb.Text
			saveSoon()
		end
		if cb then
			cb(tb.Text, tb)
		end
	end)
	return tb
end

-- popup picker over the whole window
local popup = UI.mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, Visible = false, ZIndex = 50, Active = true }, main)
local popupBox = UI.mk("Frame", { Size = UDim2.new(1, -60, 1, -90), Position = UDim2.fromOffset(30, 45), BackgroundColor3 = Col.bg, ZIndex = 51 }, popup)
UI.corner(popupBox, 8)
local popupTitle = UI.mk("TextLabel", { Size = UDim2.new(1, -40, 0, 26), Position = UDim2.fromOffset(10, 2), BackgroundTransparency = 1, Text = "", TextColor3 = Col.txt, Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 52 }, popupBox)
local popupX = UI.mk("TextButton", { Size = UDim2.fromOffset(24, 20), Position = UDim2.new(1, -30, 0, 4), BackgroundColor3 = Col.red, Text = "X", TextColor3 = Col.txt, Font = Enum.Font.GothamBold, TextSize = 12, ZIndex = 52 }, popupBox)
UI.corner(popupX, 5)
local popupList = UI.mk("ScrollingFrame", { Size = UDim2.new(1, -16, 1, -36), Position = UDim2.fromOffset(8, 30), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 52 }, popupBox)
UI.mk("UIListLayout", { Padding = UDim.new(0, 3) }, popupList)
popupX.MouseButton1Click:Connect(function()
	popup.Visible = false
end)
function UI.popup(title, options, cb)
	for _, c in ipairs(popupList:GetChildren()) do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	popupTitle.Text = title
	for _, opt in ipairs(options) do
		local b = UI.mk("TextButton", { Size = UDim2.new(1, -4, 0, 26), BackgroundColor3 = Col.card, Text = tostring(opt), TextColor3 = Col.txt, Font = Enum.Font.Gotham, TextSize = 12, ZIndex = 53 }, popupList)
		UI.corner(b, 5)
		b.MouseButton1Click:Connect(function()
			popup.Visible = false
			cb(opt)
		end)
	end
	popupList.CanvasPosition = Vector2.zero
	popup.Visible = true
end
function UI.choice(page, text, key, getOptions, cb)
	local r = UI.row(page, 30)
	UI.mk("TextLabel", { Size = UDim2.new(0.5, -10, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = text, TextColor3 = Col.txt, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, r)
	local b = UI.mk("TextButton", { Size = UDim2.new(0.5, -14, 0, 22), Position = UDim2.new(0.5, 4, 0.5, -11), BackgroundColor3 = Col.off, Text = tostring(S[key]), TextColor3 = Col.txt, Font = Enum.Font.GothamBold, TextSize = 11, TextTruncate = Enum.TextTruncate.AtEnd }, r)
	UI.corner(b, 5)
	b.MouseButton1Click:Connect(function()
		local opts = type(getOptions) == "function" and getOptions() or getOptions
		UI.popup(text, opts, function(v)
			S[key] = v
			b.Text = tostring(v)
			saveSoon()
			if cb then
				cb(v)
			end
		end)
	end)
	return b
end

--// ---- pages
local pAuto = UI.page("Auto", 1)
local pRoam = UI.page("Roam", 2)
local pFarm = UI.page("Farm", 3)
local pClaim = UI.page("Claim", 4)
local pMisc = UI.page("Misc", 5)
local pLog = UI.page("Log", 6)

-- Auto
UI.section(pAuto, "Full auto")
UI.note(pAuto, "One switch for the whole loop: Roam walks on grass to trigger wild encounters, Auto Battle fights them (and trainer / dungeon / raid battles), Auto Heal tops the party up, Farm plots get replanted, free gifts are claimed.", 62)
local fullOn = false
UI.button(pAuto, "FULL AUTO: toggle everything", function(b)
	fullOn = not fullOn
	for _, k in ipairs({ "battle", "walk", "heal", "farm", "claimGifts" }) do
		if k ~= "claimGifts" or fullOn then
			S[k] = fullOn
		end
		if painters[k] then
			painters[k]()
		end
	end
	if fullOn then
		W.setAnchor()
		H.off, H.fail = false, 0
	end
	b.Text = fullOn and "FULL AUTO is ON  (click to stop)" or "FULL AUTO: toggle everything"
	b.BackgroundColor3 = fullOn and Col.on or Col.acc
	saveSoon()
	say(fullOn and "FULL AUTO on" or "FULL AUTO off")
end)
UI.section(pAuto, "Auto battle")
UI.toggle(pAuto, "Auto Battle", "battle", function(on)
	say(on and "auto battle ON" or "auto battle OFF")
end)
UI.choice(pAuto, "Move choice", "moveMode", { "Smart", "Slot 1", "Slot 2", "Slot 3", "Slot 4", "Random" })
UI.toggle(pAuto, "Answer No to 'switch Doodle?'", "noSwitch")
UI.toggle(pAuto, "Press Next / OK / Continue prompts", "dismiss")
UI.choice(pAuto, "Rare wild Doodle", "rareAction", { "Pause", "Notify only", "Ignore" })
UI.textbox(pAuto, "Also treat as rare", "rareList", "name1, name2")
UI.button(pAuto, "Resume auto battle (after a rare pause)", function()
	B.hold = nil
	say("resumed")
end, Col.off)
UI.slider(pAuto, "Battle speed (0 = game setting)", "speed", 0, 3, 0.5)
UI.section(pAuto, "Auto heal")
UI.toggle(pAuto, "Auto Heal (remote Heal when party is low)", "heal")
UI.slider(pAuto, "Heal when lowest HP below %", "healBelow", 10, 90, 5)
UI.button(pAuto, "Re-enable heal after it gave up", function()
	H.off, H.fail, H.nextTry = false, 0, 0
	say("heal re-enabled")
end, Col.off)

-- Roam
UI.section(pRoam, "Walk for encounters")
UI.note(pRoam, "Wild fights start while you walk on grass. Stand on a grass patch, turn it on: the spot becomes the anchor and the character paces around it (it pauses in battles, menus and cutscenes).", 62)
UI.toggle(pRoam, "Roam", "walk", function(on)
	if on then
		W.setAnchor()
	end
	say(on and "roam ON" or "roam OFF")
end)
UI.slider(pRoam, "Roam radius (studs)", "walkRadius", 5, 60, 1)
UI.toggle(pRoam, "Only step on grass", "grassOnly")
UI.button(pRoam, "Set anchor to my position", function()
	W.setAnchor()
end, Col.off)

-- Farm
UI.section(pFarm, "Farm plots (Sweetsville farm)")
UI.note(pFarm, "Plant seeds once by hand. A wild Doodle on a plot is left alone (Notify only), shooed, or fought by auto battle (names on the rare list pause it so you can catch them); empty plots get the same seeds again via GroupPlantFarm, the call the farmer NPC uses.", 74)
UI.toggle(pFarm, "Auto farm plots", "farm", function(on)
	if on then
		FM.due = 0
	end
	say(on and "farm plots ON" or "farm plots OFF")
end)
UI.choice(pFarm, "Wild Doodle on plot", "farmAction", { "Notify only", "Shoo", "Battle" })
UI.toggle(pFarm, "Replant the last seeds", "farmReplant")
UI.slider(pFarm, "Check every (s)", "farmEvery", 10, 300, 5)
UI.button(pFarm, "Check plots now", function()
	FM.tick()
	say("plots: " .. FM.lastInfo)
end, Col.off)
local farmInfo = UI.note(pFarm, "", 34)

-- Claim
UI.section(pClaim, "Claim")
UI.toggle(pClaim, "Free gifts (play-time gifts)", "claimGifts")
UI.toggle(pClaim, "Mailbox rewards", "claimMail")
UI.toggle(pClaim, "Battlepass tiers", "claimBP")
UI.button(pClaim, "Claim everything now", function()
	CL.gDue, CL.mDue, CL.bDue = 0, 0, 0
	CL.gifts()
	CL.mail()
	CL.battlepass()
end, Col.off)
local claimInfo = UI.note(pClaim, "", 46)

-- Misc
UI.section(pMisc, "Misc")
UI.toggle(pMisc, "Anti AFK", "antiAfk")
UI.toggle(pMisc, "Turn 3D rendering off (saves CPU / GPU)", "noRender", function()
	M.render()
end)
UI.button(pMisc, "Debug info -> log", M.debug, Col.off)
UI.button(pMisc, "Copy log to clipboard", function()
	if setclipboard then
		setclipboard(table.concat(Log.lines, "\n"))
		say("log copied")
	end
end, Col.off)
UI.button(pMisc, "Unload script", doUnload, Col.red)

-- Log
local logBox = UI.mk("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Col.card,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, pLog)
local logLabel = UI.mk("TextLabel", {
	Size = UDim2.new(1, -10, 0, 0),
	Position = UDim2.fromOffset(6, 4),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = Col.dim,
	Font = Enum.Font.Code,
	TextSize = 11,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, logBox)
pLog.Size = UDim2.fromScale(1, 1)

showTab("Auto")

--// ---------------------------------------------------------------- window buttons / status loop
btnClose.MouseButton1Click:Connect(doUnload)
local minimized = false
btnMin.MouseButton1Click:Connect(function()
	minimized = not minimized
	main.Size = minimized and UDim2.fromOffset(440, 32) or UDim2.fromOffset(440, 590)
end)
track(UIS.InputBegan:Connect(function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.RightShift then
		main.Visible = not main.Visible
	end
end))

loop("ui", 0.5, function()
	local mins = math.max((os.clock() - STAT.start) / 60, 0.01)
	stLines[1].Text = string.format("%s  |  roam: %s", B.state, W.note)
	local pi = H.last
	if pi then
		stLines[2].Text = string.format("Party: %d Doodles, %d alive, lowest HP %d%%  |  heal: %s", pi.n, pi.alive, math.floor(pi.low * 100), H.off and "gave up" or H.note)
	else
		stLines[2].Text = "Party: reading..."
	end
	stLines[3].Text = string.format("Battles %d (%.1f/min)  rares %d  gifts %d  mail %d  BP %d  replants %d", STAT.battles, STAT.battles / mins, STAT.rares, STAT.gifts, STAT.mail, STAT.bp, STAT.replants)
	stLines[4].Text = G.client and ("Press method: " .. tostring(A.order[A.idx]) .. "  |  client API ok") or "client API not found yet (GUI-only mode) - wait for the game to load"
	farmInfo.Text = "Plots: " .. FM.lastInfo .. "\nLast check: " .. FM.note
	claimInfo.Text = "Gifts: " .. CL.note .. "\nMail: " .. CL.mailNote .. "\nBattlepass snapshot: " .. (CL.bp and ("tier " .. tostring(CL.bp.CT)) or "none yet")
	if Log.dirty then
		Log.dirty = false
		logLabel.Text = table.concat(Log.lines, "\n")
		logBox.CanvasPosition = Vector2.new(0, 1e6)
	end
	if settingsDirty then
		settingsDirty = false
		saveNow()
	end
end)

loop("client", 3, function()
	G.getClient()
end)

if game.PlaceId ~= 5116869569 then
	say("PlaceId is " .. tostring(game.PlaceId) .. " - this script was built for 5116869569 (Doodle World)")
end
M.render()
say("Doodle Farm loaded - RightShift hides the window")
