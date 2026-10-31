--// Coin Toolkit: market browser + coin launcher (executor LocalScript)
--// Reuses the game's own client modules, so every action still goes through the normal server checks.
--// RightShift hides/shows the window.

local PCT_SCALE = 100 -- change / topShare / creatorShare are treated as fractions (0.12 = 12%). Set to 1 if the game stores percents.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local Shared = RS:WaitForChild("Shared")
local Controllers = PlayerScripts:WaitForChild("Controllers")

local Config = require(Shared:WaitForChild("Config"))
local Networks = require(Shared:WaitForChild("Networks"))
local Format = require(Shared:WaitForChild("Format"))
local CoinCatalog = require(Shared:WaitForChild("CoinCatalog"))
local Curve = require(Shared:WaitForChild("Curve"))
local Market = require(Controllers:WaitForChild("MarketController"))
local Account = require(Controllers:WaitForChild("AccountController"))

--// palette / fonts ----------------------------------------------------------

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
}
local FONT = Enum.Font.Gotham
local FONT_B = Enum.Font.GothamBold
local FONT_M = Enum.Font.RobotoMono

--// instance helpers -----------------------------------------------------------

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

local function chipGrid(parent, order, w, h)
	return new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	}, {
		new("UIGridLayout", {
			CellSize = UDim2.fromOffset(w, h),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
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

local function field(parent, order, title, height, padV, props)
	local holder = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height + 20),
		LayoutOrder = order,
		Parent = parent,
	})
	label({ Text = title, TextSize = 11, Font = FONT_B, TextColor3 = C.Faint, Size = UDim2.new(1, 0, 0, 14), Parent = holder })
	return new("TextBox", merge({
		BorderSizePixel = 0,
		TextSize = 14,
		ClearTextOnFocus = false,
		Text = "",
		BackgroundColor3 = C.Input,
		Font = FONT,
		TextColor3 = C.Text,
		PlaceholderColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, height),
		Parent = holder,
	}, props), { corner(8), pad(padV, 10), stroke(C.Border) })
end

--// format helpers -----------------------------------------------------------

local function compact(n, prefix)
	local ok, s = pcall(Format.compact, n, prefix)
	return ok and s or string.format("%s%.2f", prefix or "", n or 0)
end

local function money(n)
	local ok, s = pcall(Format.money, n)
	return ok and s or string.format("$%.2f", n or 0)
end

local function pct(v)
	return (v or 0) * PCT_SCALE
end

local function signedPct(v)
	return string.format("%+.1f%%", pct(v))
end

local function esc(s)
	return (tostring(s):gsub("[<>&]", ""))
end

local MUTED_HEX = "#" .. C.Muted:ToHex()

--// window -------------------------------------------------------------------

local env = (getgenv and getgenv()) or _G
if env.__CoinToolkit then
	pcall(function()
		env.__CoinToolkit:Destroy()
	end)
end

local gui = new("ScreenGui", {
	Name = "CoinToolkit",
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
env.__CoinToolkit = gui

local main = new("Frame", {
	BackgroundColor3 = C.Panel,
	Position = UDim2.new(0.5, -220, 0.5, -280),
	Size = UDim2.fromOffset(440, 560),
	Parent = gui,
}, { corner(12), stroke(C.Border) })

local titleBar = new("Frame", {
	BackgroundColor3 = C.Bg,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 36),
	Parent = main,
}, { corner(12) })
-- square off the bottom corners of the rounded title bar
new("Frame", {
	BackgroundColor3 = C.Bg,
	BorderSizePixel = 0,
	Position = UDim2.new(0, 0, 1, -12),
	Size = UDim2.new(1, 0, 0, 12),
	Parent = titleBar,
})
label({
	Text = "Coin Toolkit",
	Font = FONT_B,
	TextSize = 15,
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -120, 1, 0),
	Parent = titleBar,
})
label({
	Text = "RightShift to hide",
	TextSize = 11,
	TextColor3 = C.Faint,
	TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.new(1, -150, 0, 0),
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

-- dragging
do
	local dragging, dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

local tabBar = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(12, 42),
	Size = UDim2.new(1, -24, 0, 30),
	Parent = main,
}, { list(Enum.FillDirection.Horizontal, 6) })

local body = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(12, 78),
	Size = UDim2.new(1, -24, 1, -90),
	Parent = main,
})

local pages = {}
local refreshMarket, refreshTrade, refreshAuto -- forward declarations

-- The Trade tab's coin is tracked here, not read back from the game.
-- Some of the game's Market functions (FreshPick, Select) leave the thread that ran them unable to touch this
-- window ("cannot access 'Instance'"). So GUI handlers never call them directly: they run in throwaway threads,
-- results come back through plain variables, and the polling loop at the bottom applies them to the window.
local selectedCoinId
local lastGameSelection
local pendingFresh -- nil: nothing waiting, false: no fresh coin was found, otherwise the coin's id

-- opens the coin in the game's own UI; call it last in a handler, after all window changes
local function openInGame(id)
	task.spawn(function()
		pcall(Market.Select, Market, id)
	end)
end

local function showTab(name)
	for n, p in pairs(pages) do
		p.page.Visible = n == name
		p.btn.BackgroundColor3 = n == name and C.Accent or C.Card
	end
	if name == "Market" and refreshMarket then
		refreshMarket()
	elseif name == "Trade" and refreshTrade then
		refreshTrade()
	elseif name == "Auto" and refreshAuto then
		refreshAuto()
	end
end

local function addTab(name, order)
	local btn = button({
		Text = name,
		Size = UDim2.fromOffset(96, 30),
		LayoutOrder = order,
		Parent = tabBar,
	}, { corner(8) })
	local page = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = body,
	})
	pages[name] = { btn = btn, page = page }
	btn.Activated:Connect(function()
		showTab(name)
	end)
	return page
end

local marketPage = addTab("Market", 1)
local tradePage = addTab("Trade", 2)
local autoPage = addTab("Auto", 3)
local launchPage = addTab("Launch", 4)

--// market tab ---------------------------------------------------------------------

local SORTS = { "trending", "newest", "mcap", "volume", "holders", "movers", "change", "shortMovers", "bounce" }
local SORT_NAMES = {
	trending = "Trending", newest = "Newest", mcap = "Market cap", volume = "Volume", holders = "Holders",
	movers = "Biggest movers", change = "Top gainers", shortMovers = "5m movers", bounce = "5m bounce",
}
local STATUSES = { "Live", "Launch", "Graduated", "Rugged" }
local PHASE_COLOR = { Launch = C.Accent, Graduated = C.Up, Rugged = C.Down }
local MAX_ROWS = 60

local sortIndex, statusIndex = 1, 1

local searchBox = new("TextBox", {
	BorderSizePixel = 0,
	TextSize = 13,
	ClearTextOnFocus = false,
	Text = "",
	PlaceholderText = "Search name, ticker or creator",
	BackgroundColor3 = C.Input,
	Font = FONT,
	TextColor3 = C.Text,
	PlaceholderColor3 = C.Faint,
	TextXAlignment = Enum.TextXAlignment.Left,
	Size = UDim2.new(1, 0, 0, 32),
	Parent = marketPage,
}, { corner(8), pad(0, 10), stroke(C.Border) })

local controls = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 38),
	Size = UDim2.new(1, 0, 0, 30),
	Parent = marketPage,
}, { list(Enum.FillDirection.Horizontal, 6) })

local sortBtn = button({ Size = UDim2.fromOffset(140, 30), LayoutOrder = 1, Parent = controls }, { corner(8) })
local statusBtn = button({ Size = UDim2.fromOffset(110, 30), LayoutOrder = 2, Parent = controls }, { corner(8) })
local freshBtn = button({
	Text = "🎯 Fresh pick",
	Size = UDim2.fromOffset(130, 30),
	BackgroundColor3 = C.Accent,
	LayoutOrder = 3,
	Parent = controls,
}, { corner(8) })

local countLabel = label({
	TextSize = 11,
	TextColor3 = C.Faint,
	Position = UDim2.fromOffset(0, 74),
	Size = UDim2.new(1, 0, 0, 16),
	Parent = marketPage,
})

local listFrame = new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Position = UDim2.fromOffset(0, 94),
	Size = UDim2.new(1, 0, 1, -94),
	Parent = marketPage,
}, { list(Enum.FillDirection.Vertical, 6), new("UIPadding", { PaddingRight = UDim.new(0, 6) }) })

local rows = {}

local function getRow(i)
	local row = rows[i]
	if row then
		return row
	end
	row = {}
	row.btn = button({
		Text = "",
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = i,
		Parent = listFrame,
	}, { corner(8) })
	row.title = label({
		RichText = true,
		Font = FONT_B,
		Position = UDim2.fromOffset(10, 5),
		Size = UDim2.new(1, -96, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row.btn,
	})
	row.change = label({
		Font = FONT_M,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 5),
		Size = UDim2.fromOffset(80, 18),
		Parent = row.btn,
	})
	row.sub = label({
		RichText = true,
		TextSize = 11,
		TextColor3 = C.Muted,
		Position = UDim2.fromOffset(10, 25),
		Size = UDim2.new(1, -20, 0, 16),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row.btn,
	})
	row.btn.Activated:Connect(function()
		if row.id then
			selectedCoinId = row.id
			showTab("Trade")
			openInGame(row.id)
		end
	end)
	rows[i] = row
	return row
end

local function paintRow(row, coin)
	row.id = coin.id
	row.btn.Visible = true
	row.title.Text = string.format('<b>$%s</b>  <font color="%s">%s</font>', esc(coin.ticker), MUTED_HEX, esc(coin.name))

	local ch = coin.change or 0
	row.change.Text = signedPct(ch)
	row.change.TextColor3 = ch >= 0 and C.Up or C.Down

	local phase = coin.phase or "Launch"
	local top = pct(coin.topShare)
	local topText = top > 25
		and string.format('  <font color="#%s">top holder %.0f%%</font>', C.Down:ToHex(), top)
		or string.format("  top holder %.0f%%", top)
	row.sub.Text = string.format(
		'%s  ·  5m %s  ·  %d holders  ·  <font color="#%s">%s</font>%s',
		compact(coin.mcap or 0, "$"),
		signedPct(coin.change5m),
		math.floor(coin.holders or 0),
		(PHASE_COLOR[phase] or C.Muted):ToHex(),
		phase,
		topText
	)
end

refreshMarket = function()
	local sortKey = SORTS[sortIndex]
	local status = STATUSES[statusIndex]
	sortBtn.Text = "Sort: " .. SORT_NAMES[sortKey]
	statusBtn.Text = status

	local coins = Market:List(sortKey, searchBox.Text, { status = status })
	local shown = math.min(#coins, MAX_ROWS)
	for i = 1, shown do
		paintRow(getRow(i), coins[i])
	end
	for i = shown + 1, #rows do
		rows[i].btn.Visible = false
		rows[i].id = nil
	end
	countLabel.Text = string.format("%d coins%s", #coins, #coins > shown and (" (showing top " .. shown .. ")") or "")
end

sortBtn.Activated:Connect(function()
	sortIndex = sortIndex % #SORTS + 1
	refreshMarket()
end)
statusBtn.Activated:Connect(function()
	statusIndex = statusIndex % #STATUSES + 1
	refreshMarket()
end)
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	refreshMarket()
end)
freshBtn.Activated:Connect(function()
	task.spawn(function()
		local ok, coin = pcall(Market.FreshPick, Market)
		pendingFresh = (ok and coin) and coin.id or false
	end)
end)

--// image import (PNG -> 32x32 logo) --------------------------------------------------
-- Executors can't create EditableImages, so PNGs are decoded in plain Luau: inflate, un-filter, then
-- box-average down to the logo's 32x32 RGBA. Non-interlaced PNGs only.

local ImageLoader = {}

local MAX_RAW_BYTES = 12 * 1024 * 1024 -- cap on the decompressed size (about 1700x1700 RGBA)

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CODE_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }
local PNG_CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

-- canonical Huffman table from code lengths (lengths is 1-based, symbols are 0-based)
local function construct(lengths, n)
	local count = {}
	for len = 0, 15 do
		count[len] = 0
	end
	for i = 1, n do
		count[lengths[i]] += 1
	end
	local offsets = { [1] = 0 }
	for len = 1, 14 do
		offsets[len + 1] = offsets[len] + count[len]
	end
	local symbol = {}
	for i = 1, n do
		local len = lengths[i]
		if len ~= 0 then
			symbol[offsets[len] + 1] = i - 1
			offsets[len] += 1
		end
	end
	return { count = count, symbol = symbol }
end

local fixedLit, fixedDist
local function fixedTables()
	if not fixedLit then
		local lit = {}
		for i = 1, 288 do
			lit[i] = i <= 144 and 8 or (i <= 256 and 9 or (i <= 280 and 7 or 8))
		end
		fixedLit = construct(lit, 288)
		local dist = {}
		for i = 1, 30 do
			dist[i] = 5
		end
		fixedDist = construct(dist, 30)
	end
	return fixedLit, fixedDist
end

local function be32(buf, offset)
	return buffer.readu8(buf, offset) * 16777216 + buffer.readu8(buf, offset + 1) * 65536
		+ buffer.readu8(buf, offset + 2) * 256 + buffer.readu8(buf, offset + 3)
end

local function be16(buf, offset)
	return buffer.readu8(buf, offset) * 256 + buffer.readu8(buf, offset + 1)
end

-- zlib/deflate decoder; `src` is a buffer holding the stream, which must inflate to exactly `expected` bytes
local function inflate(src, startPos, expected)
	local srcLen = buffer.len(src)
	local pos = startPos
	local bitBuf, bitCount = 0, 0
	local out = buffer.create(expected)
	local outPos = 0
	local work = 0

	local function bits(need)
		local val = bitBuf
		while bitCount < need do
			if pos >= srcLen then
				error("The PNG data is truncated.", 0)
			end
			val = bit32.bor(val, bit32.lshift(buffer.readu8(src, pos), bitCount))
			pos += 1
			bitCount += 8
		end
		bitBuf = bit32.rshift(val, need)
		bitCount -= need
		return bit32.band(val, bit32.lshift(1, need) - 1)
	end

	local function decode(h)
		local code, first, index = 0, 0, 0
		for len = 1, 15 do
			code += bits(1)
			local count = h.count[len]
			if code - count < first then
				local sym = h.symbol[index + (code - first) + 1]
				if sym == nil then
					error("The PNG data is corrupt.", 0)
				end
				return sym
			end
			index += count
			first += count
			first *= 2
			code *= 2
		end
		error("The PNG data is corrupt.", 0)
	end

	local function codes(lit, dist)
		while true do
			local sym = decode(lit)
			if sym < 256 then
				if outPos >= expected then
					error("The PNG data is larger than its header says.", 0)
				end
				buffer.writeu8(out, outPos, sym)
				outPos += 1
			elseif sym == 256 then
				return
			else
				sym -= 257
				if sym >= 29 then
					error("The PNG data is corrupt.", 0)
				end
				local len = LEN_BASE[sym + 1] + bits(LEN_EXTRA[sym + 1])
				local dsym = decode(dist)
				if dsym >= 30 then
					error("The PNG data is corrupt.", 0)
				end
				local d = DIST_BASE[dsym + 1] + bits(DIST_EXTRA[dsym + 1])
				if d > outPos or outPos + len > expected then
					error("The PNG data is corrupt.", 0)
				end
				if d >= len then
					buffer.copy(out, outPos, out, outPos - d, len)
				else
					for i = 0, len - 1 do
						buffer.writeu8(out, outPos + i, buffer.readu8(out, outPos + i - d))
					end
				end
				outPos += len
			end
			work += 1
			if work % 40000 == 0 then
				task.wait()
			end
		end
	end

	local function stored()
		bitBuf, bitCount = 0, 0
		if pos + 4 > srcLen then
			error("The PNG data is truncated.", 0)
		end
		local len = buffer.readu8(src, pos) + buffer.readu8(src, pos + 1) * 256
		local nlen = buffer.readu8(src, pos + 2) + buffer.readu8(src, pos + 3) * 256
		if bit32.bxor(len, nlen) ~= 0xFFFF then
			error("The PNG data is corrupt.", 0)
		end
		pos += 4
		if pos + len > srcLen or outPos + len > expected then
			error("The PNG data is corrupt.", 0)
		end
		buffer.copy(out, outPos, src, pos, len)
		pos += len
		outPos += len
	end

	local function dynamic()
		local nlen = bits(5) + 257
		local ndist = bits(5) + 1
		local ncode = bits(4) + 4
		if nlen > 286 or ndist > 30 then
			error("The PNG data is corrupt.", 0)
		end
		local lengths = {}
		for i = 1, 19 do
			lengths[i] = 0
		end
		for i = 1, ncode do
			lengths[CODE_ORDER[i] + 1] = bits(3)
		end
		local codeTable = construct(lengths, 19)

		local all = {}
		local index = 0
		while index < nlen + ndist do
			local sym = decode(codeTable)
			if sym < 16 then
				index += 1
				all[index] = sym
			else
				local previous, repeatCount = 0, 0
				if sym == 16 then
					if index == 0 then
						error("The PNG data is corrupt.", 0)
					end
					previous = all[index]
					repeatCount = 3 + bits(2)
				elseif sym == 17 then
					repeatCount = 3 + bits(3)
				else
					repeatCount = 11 + bits(7)
				end
				if index + repeatCount > nlen + ndist then
					error("The PNG data is corrupt.", 0)
				end
				for _ = 1, repeatCount do
					index += 1
					all[index] = previous
				end
			end
		end

		local litLengths, distLengths = {}, {}
		for i = 1, nlen do
			litLengths[i] = all[i]
		end
		for i = 1, ndist do
			distLengths[i] = all[nlen + i]
		end
		return construct(litLengths, nlen), construct(distLengths, ndist)
	end

	repeat
		local last = bits(1)
		local kind = bits(2)
		if kind == 0 then
			stored()
		elseif kind == 1 then
			codes(fixedTables())
		elseif kind == 2 then
			codes(dynamic())
		else
			error("The PNG data is corrupt.", 0)
		end
	until last == 1

	if outPos ~= expected then
		error("The PNG data is incomplete.", 0)
	end
	return out
end

-- returns width, height and pixel(x, y) -> r, g, b, a (0-255, x/y 0-based)
local function decodePng(data)
	local buf = buffer.fromstring(data)
	local total = buffer.len(buf)
	if total < 33 or buffer.readstring(buf, 0, 8) ~= "\137PNG\r\n\26\n" then
		error("That isn't a PNG file. Only PNG is supported, so re-save the image as .png.", 0)
	end

	local width, height, depth, colorType, interlace
	local palette, trnsAt, trnsSize
	local idat, idatTotal = {}, 0
	local pos = 8
	while pos + 8 <= total do
		local size = be32(buf, pos)
		local kind = buffer.readstring(buf, pos + 4, 4)
		local body = pos + 8
		if body + size > total then
			error("The PNG file is truncated.", 0)
		end
		if kind == "IHDR" then
			width, height = be32(buf, body), be32(buf, body + 4)
			depth, colorType = buffer.readu8(buf, body + 8), buffer.readu8(buf, body + 9)
			interlace = buffer.readu8(buf, body + 12)
		elseif kind == "PLTE" then
			palette = { r = {}, g = {}, b = {}, a = {} }
			for i = 0, size // 3 - 1 do
				palette.r[i + 1] = buffer.readu8(buf, body + i * 3)
				palette.g[i + 1] = buffer.readu8(buf, body + i * 3 + 1)
				palette.b[i + 1] = buffer.readu8(buf, body + i * 3 + 2)
				palette.a[i + 1] = 255
			end
		elseif kind == "tRNS" then
			trnsAt, trnsSize = body, size
		elseif kind == "IDAT" then
			table.insert(idat, { body, size })
			idatTotal += size
		elseif kind == "IEND" then
			break
		end
		pos = body + size + 4 -- skip the CRC
	end

	if not width or not height or width < 1 or height < 1 then
		error("The PNG header is missing or invalid.", 0)
	end
	if interlace ~= 0 then
		error("Interlaced PNGs aren't supported. Re-save it without interlacing.", 0)
	end
	local channels = PNG_CHANNELS[colorType]
	if not channels or not (depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16)
		or (colorType ~= 0 and colorType ~= 3 and depth < 8) or (colorType == 3 and depth > 8) then
		error("This kind of PNG isn't supported.", 0)
	end
	if colorType == 3 and not palette then
		error("The PNG is missing its palette.", 0)
	end
	if idatTotal == 0 then
		error("The PNG has no image data.", 0)
	end

	local bitsPerPixel = channels * depth
	local stride = (width * bitsPerPixel + 7) // 8
	local bpp = math.max(1, bitsPerPixel // 8)
	local expected = (stride + 1) * height
	if expected > MAX_RAW_BYTES then
		error("That image is too big (limit is about 1700x1700). Resize it first.", 0)
	end

	-- transparency info
	local keyGray, keyR, keyG, keyB
	if trnsAt then
		if colorType == 3 then
			for i = 1, math.min(trnsSize, #palette.a) do
				palette.a[i] = buffer.readu8(buf, trnsAt + i - 1)
			end
		elseif colorType == 0 and trnsSize >= 2 then
			keyGray = be16(buf, trnsAt)
			if depth == 16 then
				keyGray = keyGray // 256
			end
		elseif colorType == 2 and trnsSize >= 6 then
			keyR, keyG, keyB = be16(buf, trnsAt), be16(buf, trnsAt + 2), be16(buf, trnsAt + 4)
			if depth == 16 then
				keyR, keyG, keyB = keyR // 256, keyG // 256, keyB // 256
			end
		end
	end

	-- join the IDAT chunks into one zlib stream
	local stream = buffer.create(idatTotal)
	local at = 0
	for _, chunk in ipairs(idat) do
		buffer.copy(stream, at, buf, chunk[1], chunk[2])
		at += chunk[2]
	end
	local cmf, flg = buffer.readu8(stream, 0), buffer.readu8(stream, 1)
	if cmf % 16 ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or flg // 32 % 2 == 1 then
		error("The PNG data uses an unsupported compression.", 0)
	end
	local raw = inflate(stream, 2, expected)

	-- undo the per-row filters in place
	for y = 0, height - 1 do
		local rowStart = y * (stride + 1)
		local filter = buffer.readu8(raw, rowStart)
		local cur = rowStart + 1
		local prev = cur - (stride + 1)
		if filter == 1 then
			for i = bpp, stride - 1 do
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, cur + i - bpp)) % 256)
			end
		elseif filter == 2 then
			if y > 0 then
				for i = 0, stride - 1 do
					buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, prev + i)) % 256)
				end
			end
		elseif filter == 3 then
			for i = 0, stride - 1 do
				local left = i >= bpp and buffer.readu8(raw, cur + i - bpp) or 0
				local up = y > 0 and buffer.readu8(raw, prev + i) or 0
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + (left + up) // 2) % 256)
			end
		elseif filter == 4 then
			for i = 0, stride - 1 do
				local a = i >= bpp and buffer.readu8(raw, cur + i - bpp) or 0
				local b = y > 0 and buffer.readu8(raw, prev + i) or 0
				local c = (i >= bpp and y > 0) and buffer.readu8(raw, prev + i - bpp) or 0
				local p = a + b - c
				local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
				local predicted
				if pa <= pb and pa <= pc then
					predicted = a
				elseif pb <= pc then
					predicted = b
				else
					predicted = c
				end
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + predicted) % 256)
			end
		elseif filter ~= 0 then
			error("The PNG data is corrupt.", 0)
		end
		if y % 32 == 31 then
			task.wait()
		end
	end

	local maxSample = bit32.lshift(1, depth) - 1
	local function sample(row, x, channel)
		if depth == 8 then
			return buffer.readu8(raw, row + x * channels + channel)
		elseif depth == 16 then
			return buffer.readu8(raw, row + (x * channels + channel) * 2) -- high byte is enough for 8-bit output
		end
		local bitPos = x * depth
		local byte = buffer.readu8(raw, row + bitPos // 8)
		return bit32.band(bit32.rshift(byte, 8 - depth - bitPos % 8), maxSample)
	end

	local function pixel(x, y)
		local row = y * (stride + 1) + 1
		if colorType == 6 then
			return sample(row, x, 0), sample(row, x, 1), sample(row, x, 2), sample(row, x, 3)
		elseif colorType == 2 then
			local r, g, b = sample(row, x, 0), sample(row, x, 1), sample(row, x, 2)
			return r, g, b, (keyR and r == keyR and g == keyG and b == keyB) and 0 or 255
		elseif colorType == 4 then
			local v = sample(row, x, 0)
			return v, v, v, sample(row, x, 1)
		elseif colorType == 0 then
			local v = sample(row, x, 0)
			local a = (keyGray and v == keyGray) and 0 or 255
			if depth < 8 then
				v = math.floor(v * 255 / maxSample + 0.5)
			end
			return v, v, v, a
		end
		local i = sample(row, x, 0) + 1
		return palette.r[i] or 0, palette.g[i] or 0, palette.b[i] or 0, palette.a[i] or 255
	end

	return width or 0, height or 0, pixel
end

-- source: a file name in the executor's workspace folder, or an http(s) link; returns the file's bytes
function ImageLoader.fetch(source)
	source = source:match("^%s*(.-)%s*$")
	if source == "" then
		error("Type a PNG file name or a direct link first.", 0)
	end

	if source:lower():match("^https?://") then
		local send = request or http_request or (syn and syn.request)
		if send then
			local ok, res = pcall(send, { Url = source, Method = "GET" })
			if ok and type(res) == "table" and type(res.Body) == "string" and (res.StatusCode or 200) < 400 then
				return res.Body
			end
		end
		local ok, body = pcall(function()
			return game:HttpGet(source)
		end)
		if ok and type(body) == "string" then
			return body
		end
		error("Couldn't download that link.", 0)
	end

	if not (readfile and isfile) then
		error("This executor can't read files.", 0)
	end
	local path = source
	if not isfile(path) and isfile(path .. ".png") then
		path ..= ".png"
	end
	if not isfile(path) then
		error("Couldn't find \"" .. source .. "\" in the executor's workspace folder.", 0)
	end
	return readfile(path)
end

-- fit = true keeps the whole picture (transparent padding); false fills the square and crops the overflow
function ImageLoader.toLogo(data, fit)
	local width, height, pixel = decodePng(data)
	local side = fit and math.max(width, height) or math.min(width, height)
	local offsetX, offsetY = (width - side) / 2, (height - side) / 2
	local out = buffer.create(32 * 32 * 4)

	for ty = 0, 31 do
		local ya = math.floor(offsetY + ty * side / 32 + 0.5)
		local yb = math.max(ya + 1, math.floor(offsetY + (ty + 1) * side / 32 + 0.5))
		ya, yb = math.max(ya, 0), math.min(yb, height)
		for tx = 0, 31 do
			local xa = math.floor(offsetX + tx * side / 32 + 0.5)
			local xb = math.max(xa + 1, math.floor(offsetX + (tx + 1) * side / 32 + 0.5))
			xa, xb = math.max(xa, 0), math.min(xb, width)

			local sumA, sumR, sumG, sumB, n = 0, 0, 0, 0, 0
			for y = ya, yb - 1 do
				for x = xa, xb - 1 do
					local r, g, b, a = pixel(x, y)
					sumA += a
					sumR += r * a
					sumG += g * a
					sumB += b * a
					n += 1
				end
			end
			if n > 0 and sumA > 0 then
				local offset = (ty * 32 + tx) * 4
				buffer.writeu8(out, offset, math.floor(sumR / sumA + 0.5))
				buffer.writeu8(out, offset + 1, math.floor(sumG / sumA + 0.5))
				buffer.writeu8(out, offset + 2, math.floor(sumB / sumA + 0.5))
				buffer.writeu8(out, offset + 3, math.floor(sumA / n + 0.5))
			end
		end
		if ty % 4 == 3 then
			task.wait()
		end
	end
	return out
end

--// drawing pad ----------------------------------------------------------------------
-- 32x32 RGBA logo, byte-for-byte the buffer the game's own LogoPad exports. The game's pad draws into an
-- EditableImage, which executor threads can't create, so this one draws on a grid of Frames instead.

local DrawPad = {}
DrawPad.__index = DrawPad

local PAD_COLORS = {
	Color3.fromRGB(0, 0, 0), Color3.fromRGB(255, 255, 255), Color3.fromRGB(128, 128, 128), Color3.fromRGB(60, 60, 60),
	Color3.fromRGB(239, 68, 68), Color3.fromRGB(255, 106, 44), Color3.fromRGB(250, 204, 21), Color3.fromRGB(163, 230, 53),
	Color3.fromRGB(34, 197, 94), Color3.fromRGB(20, 184, 166), Color3.fromRGB(56, 189, 248), Color3.fromRGB(59, 130, 246),
	Color3.fromRGB(99, 102, 241), Color3.fromRGB(168, 85, 247), Color3.fromRGB(236, 72, 153), Color3.fromRGB(120, 72, 40),
	Color3.fromRGB(241, 194, 150), Color3.fromRGB(212, 175, 55),
}
local PAD_SIZES = { 1, 2, 3, 5, 8 }
local PAD_OPACITIES = { 0.25, 0.5, 0.75, 1 }
local PAD_DIM = 32 -- pixels per side
local PAD_CELL = 7 -- screen pixels per logo pixel

function DrawPad.new(parent, order, getColorIndex, setScrollLocked)
	local self = setmetatable({}, DrawPad)
	self.pixels = buffer.create(PAD_DIM * PAD_DIM * 4)
	self.undo = {}
	self.size = 2
	self.opacity = 1
	self.color = PAD_COLORS[1]
	self.erasing = false
	self.painted = 0
	self.connections = {}
	self.Changed = nil
	self.fitImage = true
	self.importing = false

	local logoConfig = Config.CoinLogo
	self.disabled = not (logoConfig and logoConfig.Enabled)
	self.minPainted = logoConfig and logoConfig.MinPaintedPixels or 1

	self.Frame = new("Frame", {
		BackgroundColor3 = C.Card,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	}, { corner(8), pad(12, 14), list(Enum.FillDirection.Vertical, 10) })

	label({
		Text = "Leave it empty to use the ticker letters. Keep it clean: inappropriate logos get reported and removed.",
		TextSize = 11,
		TextColor3 = C.Muted,
		TextWrapped = true,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self.Frame,
	})
	if self.disabled then
		label({
			Text = "Drawing logos isn't available right now.",
			TextSize = 12,
			TextColor3 = C.Down,
			LayoutOrder = 2,
			Parent = self.Frame,
		})
		return self
	end

	local holder = new("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, PAD_DIM * PAD_CELL),
		Parent = self.Frame,
	})
	self.Canvas = new("TextButton", {
		Name = "Canvas",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundColor3 = CoinCatalog.Colors[getColorIndex()] or C.Accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(PAD_DIM * PAD_CELL, PAD_DIM * PAD_CELL),
	}, { stroke(C.Border) })
	-- transparent cells sit over the canvas colour, so a pixel's alpha blends with the background like the game's image does
	self.cells = {}
	for index = 0, PAD_DIM * PAD_DIM - 1 do
		self.cells[index + 1] = new("Frame", {
			BorderSizePixel = 0,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset((index % PAD_DIM) * PAD_CELL, (index // PAD_DIM) * PAD_CELL),
			Size = UDim2.fromOffset(PAD_CELL, PAD_CELL),
			Parent = self.Canvas,
		})
	end
	self.Canvas.Parent = holder

	local function header(text, headerOrder)
		label({
			Text = text,
			TextSize = 10,
			Font = FONT_B,
			TextColor3 = C.Faint,
			LayoutOrder = headerOrder,
			Size = UDim2.new(1, 0, 0, 12),
			Parent = self.Frame,
		})
	end

	header("COLOR", 3)
	local swatchGrid = chipGrid(self.Frame, 4, 28, 28)
	self.swatches = {}
	for i, color in ipairs(PAD_COLORS) do
		local b = button({
			Text = "",
			BackgroundColor3 = color,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = swatchGrid,
		}, { corner(4) })
		local s = stroke(C.Accent, 2, 1)
		s.Parent = b
		self.swatches[i] = s
		b.Activated:Connect(function()
			self.color = color
			self.erasing = false
			self:Refresh()
		end)
	end

	header("BRUSH SIZE", 5)
	local sizeRow = new("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 6,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = self.Frame,
	}, { list(Enum.FillDirection.Horizontal, 5) })
	self.sizeButtons = {}
	for i, size in ipairs(PAD_SIZES) do
		local b = button({ Text = "", Size = UDim2.fromOffset(40, 28), LayoutOrder = i, Parent = sizeRow }, { corner(4) })
		local dot = new("Frame", {
			BackgroundColor3 = C.Text,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(2 + size * 2, 2 + size * 2),
			Parent = b,
		}, { corner(17) })
		self.sizeButtons[size] = { button = b, dot = dot }
		b.Activated:Connect(function()
			self.size = size
			self:Refresh()
		end)
	end

	header("OPACITY", 7)
	local opacityRow = new("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 8,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = self.Frame,
	}, { list(Enum.FillDirection.Horizontal, 5) })
	self.opacityButtons = {}
	for i, opacity in ipairs(PAD_OPACITIES) do
		local b = button({
			Text = string.format("%d%%", opacity * 100),
			TextSize = 12,
			Font = FONT_M,
			Size = UDim2.fromOffset(52, 28),
			LayoutOrder = i,
			Parent = opacityRow,
		}, { corner(4) })
		self.opacityButtons[opacity] = b
		b.Activated:Connect(function()
			self.opacity = opacity
			self:Refresh()
		end)
	end

	local tools = new("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 9,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = self.Frame,
	}, { list(Enum.FillDirection.Horizontal, 6) })
	local function tool(text, toolOrder)
		return button({
			Text = text,
			TextSize = 12,
			Size = UDim2.new(1 / 3, -4, 1, 0),
			LayoutOrder = toolOrder,
			Parent = tools,
		}, { corner(4) })
	end
	self.eraserButton = tool("Eraser", 1)
	local undoButton = tool("Undo", 2)
	local clearButton = tool("Clear", 3)
	self.eraserButton.Activated:Connect(function()
		self.erasing = not self.erasing
		self:Refresh()
	end)
	undoButton.Activated:Connect(function()
		self:Undo()
	end)
	clearButton.Activated:Connect(function()
		self:PushUndo()
		buffer.fill(self.pixels, 0, 0)
		self:Commit()
	end)

	header("IMPORT IMAGE (PNG)", 10)
	local importRow = new("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 11,
		Size = UDim2.new(1, 0, 0, 32),
		Parent = self.Frame,
	}, { list(Enum.FillDirection.Horizontal, 6) })
	local sourceBox = new("TextBox", {
		BorderSizePixel = 0,
		TextSize = 12,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Text = "",
		PlaceholderText = "file name in workspace folder, or https:// link",
		LayoutOrder = 1,
		BackgroundColor3 = C.Input,
		Font = FONT,
		TextColor3 = C.Text,
		PlaceholderColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -148, 0, 32),
		Parent = importRow,
	}, { corner(6), pad(0, 8), stroke(C.Border) })
	local fitButton = button({
		Text = "Fit",
		TextSize = 12,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(64, 32),
		Parent = importRow,
	}, { corner(6) })
	local loadButton = button({
		Text = "Load",
		BackgroundColor3 = C.Accent,
		LayoutOrder = 3,
		Size = UDim2.fromOffset(72, 32),
		Parent = importRow,
	}, { corner(6) })
	local importStatus = label({
		Text = "Fit keeps the whole picture, Crop fills the square. Transparent PNGs work. Loading replaces the canvas; Undo brings your drawing back.",
		TextSize = 11,
		TextColor3 = C.Muted,
		TextWrapped = true,
		LayoutOrder = 12,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self.Frame,
	})

	fitButton.Activated:Connect(function()
		self.fitImage = not self.fitImage
		fitButton.Text = self.fitImage and "Fit" or "Crop"
	end)
	loadButton.Activated:Connect(function()
		if self.importing then
			return
		end
		self.importing = true
		importStatus.Text = "Loading…"
		importStatus.TextColor3 = C.Muted
		task.spawn(function()
			local ok, result = pcall(function()
				return ImageLoader.toLogo(ImageLoader.fetch(sourceBox.Text), self.fitImage)
			end)
			self.importing = false
			if ok then
				self:LoadPixels(result)
				importStatus.Text = "Imported. You can keep drawing on top of it."
				importStatus.TextColor3 = C.Up
			else
				importStatus.Text = tostring(result)
				importStatus.TextColor3 = C.Down
			end
		end)
	end)

	self:BindInput(setScrollLocked)
	self:Refresh()
	return self
end

function DrawPad:Refresh()
	for i, s in ipairs(self.swatches) do
		s.Transparency = (self.erasing or PAD_COLORS[i] ~= self.color) and 1 or 0
	end
	for size, ref in pairs(self.sizeButtons) do
		local on = size == self.size
		ref.button.BackgroundColor3 = on and C.Accent or C.Card
		ref.dot.BackgroundColor3 = on and C.Bg or C.Text
	end
	for opacity, b in pairs(self.opacityButtons) do
		local on = opacity == self.opacity
		b.BackgroundColor3 = on and C.Accent or C.Card
		b.TextColor3 = on and C.Bg or C.Text
	end
	self.eraserButton.BackgroundColor3 = self.erasing and C.Accent or C.Card
	self.eraserButton.TextColor3 = self.erasing and C.Bg or C.Text
end

function DrawPad:SetBackground(colorIndex)
	if self.Canvas then
		self.Canvas.BackgroundColor3 = CoinCatalog.Colors[colorIndex] or C.Accent
	end
end

function DrawPad:RenderCell(index)
	local cell = self.cells[index + 1]
	local offset = index * 4
	local alpha = buffer.readu8(self.pixels, offset + 3)
	if alpha == 0 then
		cell.BackgroundTransparency = 1
		return
	end
	cell.BackgroundColor3 = Color3.fromRGB(
		buffer.readu8(self.pixels, offset),
		buffer.readu8(self.pixels, offset + 1),
		buffer.readu8(self.pixels, offset + 2)
	)
	cell.BackgroundTransparency = 1 - alpha / 255
end

function DrawPad:PushUndo()
	local copy = buffer.create(PAD_DIM * PAD_DIM * 4)
	buffer.copy(copy, 0, self.pixels, 0, PAD_DIM * PAD_DIM * 4)
	table.insert(self.undo, copy)
	if #self.undo > 20 then
		table.remove(self.undo, 1)
	end
end

function DrawPad:Undo()
	local previous = table.remove(self.undo)
	if previous then
		self.pixels = previous
		self:Commit()
	end
end

-- redraw everything, recount painted pixels and notify; called after a stroke ends or the buffer is replaced
function DrawPad:Commit()
	local count = 0
	for index = 0, PAD_DIM * PAD_DIM - 1 do
		self:RenderCell(index)
		if buffer.readu8(self.pixels, index * 4 + 3) > 0 then
			count += 1
		end
	end
	self.painted = count
	if self.Changed then
		self.Changed()
	end
end

function DrawPad:HasDrawing()
	return not self.disabled and self.painted >= self.minPainted
end

function DrawPad:Export()
	if not self:HasDrawing() then
		return nil
	end
	local copy = buffer.create(PAD_DIM * PAD_DIM * 4)
	buffer.copy(copy, 0, self.pixels, 0, PAD_DIM * PAD_DIM * 4)
	return copy
end

-- replaces the canvas with a 4096-byte RGBA buffer (undoable)
function DrawPad:LoadPixels(pixels)
	if self.disabled or buffer.len(pixels) ~= PAD_DIM * PAD_DIM * 4 then
		return
	end
	self:PushUndo()
	buffer.copy(self.pixels, 0, pixels, 0, PAD_DIM * PAD_DIM * 4)
	self:Commit()
end

function DrawPad:Reset()
	if self.disabled then
		return
	end
	buffer.fill(self.pixels, 0, 0)
	table.clear(self.undo)
	self:Commit()
end

-- blends one pixel against the stroke's starting state, so a single stroke never darkens itself
function DrawPad:Plot(x, y)
	if x < 0 or y < 0 or x >= PAD_DIM or y >= PAD_DIM then
		return
	end
	local index = y * PAD_DIM + x
	if self.mask[index] then
		return
	end
	self.mask[index] = true

	local offset = index * 4
	local base = self.strokeBase
	local opacity = self.opacity
	local baseAlpha = buffer.readu8(base, offset + 3) / 255

	if self.erasing then
		buffer.writeu8(self.pixels, offset + 3, math.floor(baseAlpha * (1 - opacity) * 255 + 0.5))
	else
		local outAlpha = opacity + baseAlpha * (1 - opacity)
		local rgb = { self.color.R, self.color.G, self.color.B }
		for channel = 1, 3 do
			local baseValue = buffer.readu8(base, offset + channel - 1)
			local mixed = (rgb[channel] * 255 * opacity + baseValue * baseAlpha * (1 - opacity)) / outAlpha
			buffer.writeu8(self.pixels, offset + channel - 1, math.clamp(math.floor(mixed + 0.5), 0, 255))
		end
		buffer.writeu8(self.pixels, offset + 3, math.floor(outAlpha * 255 + 0.5))
	end
	self:RenderCell(index)
end

function DrawPad:Stamp(cx, cy)
	local radius = math.max(self.size / 2, 0.5)
	for y = math.floor(cy - radius), math.ceil(cy + radius) do
		for x = math.floor(cx - radius), math.ceil(cx + radius) do
			local dx, dy = x + 0.5 - cx, y + 0.5 - cy
			if dx * dx + dy * dy <= radius * radius then
				self:Plot(x, y)
			end
		end
	end
end

function DrawPad:ToCanvas(position)
	local origin, extent = self.Canvas.AbsolutePosition, self.Canvas.AbsoluteSize
	local x = (position.X - origin.X) / extent.X * PAD_DIM
	local y = (position.Y - origin.Y) / extent.Y * PAD_DIM
	if self.size % 2 == 1 then
		return math.floor(x) + 0.5, math.floor(y) + 0.5
	end
	return math.floor(x + 0.5), math.floor(y + 0.5)
end

function DrawPad:BindInput(setScrollLocked)
	local drawing = false
	local lastX, lastY

	local function strokeTo(position)
		local x, y = self:ToCanvas(position)
		if lastX then
			local steps = math.max(1, math.ceil(math.sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2) / 0.4))
			for i = 1, steps do
				local t = i / steps
				self:Stamp(lastX + (x - lastX) * t, lastY + (y - lastY) * t)
			end
		else
			self:Stamp(x, y)
		end
		lastX, lastY = x, y
	end

	local function isPointer(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	table.insert(self.connections, self.Canvas.InputBegan:Connect(function(input)
		if not isPointer(input) then
			return
		end
		drawing = true
		setScrollLocked(true)
		self:PushUndo()
		self.strokeBase = buffer.create(PAD_DIM * PAD_DIM * 4)
		buffer.copy(self.strokeBase, 0, self.pixels, 0, PAD_DIM * PAD_DIM * 4)
		self.mask = {}
		lastX, lastY = nil, nil
		strokeTo(input.Position)
	end))
	table.insert(self.connections, UIS.InputChanged:Connect(function(input)
		if drawing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			strokeTo(input.Position)
		end
	end))
	table.insert(self.connections, UIS.InputEnded:Connect(function(input)
		if drawing and isPointer(input) then
			drawing = false
			setScrollLocked(false)
			self.strokeBase = nil
			self.mask = nil
			self:Commit()
		end
	end))

	self.Frame.Destroying:Connect(function()
		for _, connection in ipairs(self.connections) do
			connection:Disconnect()
		end
	end)
end

--// launch tab -----------------------------------------------------------------------

local form = {
	category = CoinCatalog.Categories[1].Id,
	icon = CoinCatalog.Categories[1].Icons[1],
	colorIndex = 1,
	network = Networks.Default,
	devBuy = 0,
	busy = false,
	logoBg = 0,
	refresh = function() end, -- replaced below, once the widgets exist
	rebuildIcons = function() end,
}

local scroll = new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Size = UDim2.new(1, 0, 1, -72),
	Parent = launchPage,
}, { list(Enum.FillDirection.Vertical, 10), new("UIPadding", { PaddingRight = UDim.new(0, 8) }) })

local preview = label({
	RichText = true,
	Font = FONT_B,
	TextSize = 14,
	TextTruncate = Enum.TextTruncate.AtEnd,
	BackgroundTransparency = 0,
	BackgroundColor3 = C.Card,
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 44),
	Parent = scroll,
})
corner(8).Parent = preview
pad(0, 12).Parent = preview

local nameBox = field(scroll, 2, "NAME", 36, 0, { PlaceholderText = "Moon Cat" })
local tickerBox = field(scroll, 3, "TICKER", 36, 0, { PlaceholderText = "MCAT", Font = FONT_M })
local descBox = field(scroll, 4, "DESCRIPTION (OPTIONAL)", 60, 8, {
	PlaceholderText = "What's the story?",
	MultiLine = true,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
})

section(scroll, 5, "CATEGORY")
local categoryGrid = chipGrid(scroll, 6, 84, 28)
local categoryButtons = {}
for i, cat in ipairs(CoinCatalog.Categories) do
	local b = button({ Text = cat.Id, TextSize = 12, LayoutOrder = i, Parent = categoryGrid }, { corner(6) })
	categoryButtons[cat.Id] = b
	b.Activated:Connect(function()
		form.category = cat.Id
		local icons = CoinCatalog.ById[cat.Id].Icons
		if not table.find(icons, form.icon) then
			form.icon = icons[1]
		end
		form.rebuildIcons()
	end)
end

section(scroll, 7, "ICON")
local iconGrid = chipGrid(scroll, 8, 38, 38)
local iconButtons = {}

section(scroll, 9, "NETWORK")
local networkGrid = chipGrid(scroll, 10, 128, 28)
local networkButtons = {}
local networkInfo = label({
	TextSize = 11,
	TextColor3 = C.Muted,
	TextWrapped = true,
	LayoutOrder = 11,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = scroll,
})
for i, net in ipairs(Networks.List) do
	local b = button({ Text = net.Name, TextSize = 12, LayoutOrder = i, Parent = networkGrid }, {
		corner(6),
		stroke(net.Color, 1.5),
	})
	networkButtons[net.Id] = b
	b.Activated:Connect(function()
		form.network = net.Id
		form.refresh()
	end)
end

section(scroll, 12, "COLOR")
local colorGrid = chipGrid(scroll, 13, 28, 28)
local colorStrokes = {}
for i, color in ipairs(CoinCatalog.Colors) do
	local b = button({
		Text = "",
		BackgroundColor3 = color,
		LayoutOrder = i,
		AutoButtonColor = false,
		Parent = colorGrid,
	}, { corner(14) })
	local s = stroke(C.Text, 2)
	s.Parent = b
	colorStrokes[i] = s
	b.Activated:Connect(function()
		form.colorIndex = i
		form.refresh()
	end)
end

section(scroll, 14, "LOGO (OPTIONAL)  ·  draw your own")
local padOk, logoPad = pcall(DrawPad.new, scroll, 15, function()
	return form.colorIndex
end, function(locked)
	scroll.ScrollingEnabled = not locked
end)
if padOk then
	logoPad.Changed = function()
		form.refresh()
	end
else
	warn("[CoinToolkit] drawing pad failed: " .. tostring(logoPad))
	logoPad = nil
end

local function hasDrawing()
	if not logoPad then
		return false
	end
	local ok, drawn = pcall(logoPad.HasDrawing, logoPad)
	return ok and drawn and true or false
end

section(scroll, 16, "DEV BUY (OPTIONAL)  ·  be the first buyer of your own coin")
local devRow = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 32),
	LayoutOrder = 17,
	Parent = scroll,
}, { list(Enum.FillDirection.Horizontal, 6) })
local devBox
local devChips = {}
for i, amount in ipairs({ 0, 100, 500, 1000, 5000 }) do
	local b = button({
		Text = amount == 0 and "None" or compact(amount, "$"),
		TextSize = 12,
		Size = UDim2.fromOffset(52, 32),
		LayoutOrder = i,
		Parent = devRow,
	}, { corner(6) })
	devChips[amount] = b
	b.Activated:Connect(function()
		devBox.Text = amount == 0 and "" or tostring(amount)
	end)
end
devBox = new("TextBox", {
	BorderSizePixel = 0,
	TextSize = 13,
	PlaceholderText = "Custom $",
	ClearTextOnFocus = false,
	Text = "",
	LayoutOrder = 10,
	BackgroundColor3 = C.Input,
	Font = FONT_M,
	TextColor3 = C.Text,
	PlaceholderColor3 = C.Faint,
	Size = UDim2.fromOffset(100, 32),
	Parent = devRow,
}, { corner(6), pad(0, 8), stroke(C.Border) })
local devInfo = label({
	RichText = true,
	TextSize = 11,
	TextColor3 = C.Muted,
	TextWrapped = true,
	LayoutOrder = 18,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = scroll,
})

-- footer
local footer = new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 66),
	Parent = launchPage,
})
local status = label({
	TextSize = 12,
	TextWrapped = true,
	Size = UDim2.new(1, 0, 0, 20),
	Parent = footer,
})
local randomBtn = button({
	Text = "🎲 Randomize",
	TextSize = 12,
	Position = UDim2.fromOffset(0, 24),
	Size = UDim2.fromOffset(112, 38),
	Parent = footer,
}, { corner(8) })
local launchBtn = button({
	Text = "Launch coin",
	BackgroundColor3 = C.Accent,
	Position = UDim2.fromOffset(120, 24),
	Size = UDim2.new(1, -120, 0, 38),
	Parent = footer,
}, { corner(8) })

local function setStatus(text, isError)
	status.Text = text
	status.TextColor3 = isError and C.Down or C.Up
end

local function parseAmount(text)
	local num, suffix = text:gsub("[%$,%s]", ""):lower():match("^([%d%.]+)([km]?)$")
	local value = tonumber(num) or 0
	local mult = suffix == "k" and 1000 or (suffix == "m" and 1000000 or 1)
	return math.max(0, math.floor(value * mult * 100) / 100)
end

local function refreshDevBuy()
	form.devBuy = parseAmount(devBox.Text)
	for amount, b in pairs(devChips) do
		local on = amount == form.devBuy or (amount == 0 and form.devBuy == 0)
		b.BackgroundColor3 = on and C.Accent or C.Card
	end
	if form.devBuy <= 0 then
		devInfo.Text = "No dev buy. Anyone can be the first buyer once trading opens."
		return
	end
	local ok, tokens = pcall(Curve.buy, Config.Coin.InitialVirtualCash, Config.Coin.TotalSupply, form.devBuy)
	if not ok then
		devInfo.Text = ""
		return
	end
	local share = tokens / Config.Coin.TotalSupply
	local fee = Networks.get(form.network).Fee
	devInfo.Text = string.format(
		"First buy: <b>%s</b> tokens, <b>%.1f%%</b> of supply, for %s (+%s fee).%s",
		Format.tokens(tokens),
		share * 100,
		money(form.devBuy),
		money(form.devBuy * fee),
		share > 0.25 and string.format('  <font color="#%s">Holding over 25%% of supply scares smart traders away.</font>', C.Down:ToHex()) or ""
	)
end

function form.rebuildIcons()
	for _, child in ipairs(iconGrid:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(iconButtons)
	for i, icon in ipairs(CoinCatalog.ById[form.category].Icons) do
		local b = button({ Text = icon, TextSize = 20, Font = FONT, LayoutOrder = i, Parent = iconGrid }, { corner(8) })
		iconButtons[icon] = b
		b.Activated:Connect(function()
			form.icon = icon
			form.refresh()
		end)
	end
	form.refresh()
end

function form.refresh()
	local name = nameBox.Text == "" and "Your coin" or nameBox.Text
	local ticker = tickerBox.Text == "" and "TICKER" or tickerBox.Text
	local net = Networks.get(form.network)

	preview.Text = string.format(
		'%s  <font color="%s">$%s  ·  %s  ·  %s%s</font>',
		esc(name), MUTED_HEX, ticker, net.Name, form.category, hasDrawing() and "  ·  custom logo" or ""
	)

	if logoPad and form.logoBg ~= form.colorIndex then
		form.logoBg = form.colorIndex
		pcall(logoPad.SetBackground, logoPad, form.colorIndex)
	end

	for id, b in pairs(categoryButtons) do
		b.BackgroundColor3 = id == form.category and C.Accent or C.Card
	end
	for icon, b in pairs(iconButtons) do
		b.BackgroundColor3 = icon == form.icon and C.Accent or C.Card
	end
	for id, b in pairs(networkButtons) do
		b.BackgroundColor3 = id == form.network and C.Accent or C.Card
	end
	for i, s in ipairs(colorStrokes) do
		s.Transparency = i == form.colorIndex and 0 or 1
	end
	networkInfo.Text = string.format(
		"%s: fee %g%%, dev share %g%%, launch cost %s. %s",
		net.Name, net.Fee * 100, net.DevShare * 100, money(net.LaunchCost), net.Blurb or ""
	)
	if not form.busy then
		launchBtn.Text = "Launch · " .. money(net.LaunchCost)
	end
	refreshDevBuy()
end

nameBox:GetPropertyChangedSignal("Text"):Connect(function()
	if #nameBox.Text > Config.Coin.NameMax then
		nameBox.Text = nameBox.Text:sub(1, Config.Coin.NameMax)
	end
	form.refresh()
end)
tickerBox:GetPropertyChangedSignal("Text"):Connect(function()
	local cleaned = tickerBox.Text:upper():gsub("[^A-Z0-9]", ""):sub(1, Config.Coin.TickerMax)
	if cleaned ~= tickerBox.Text then
		tickerBox.Text = cleaned
	end
	form.refresh()
end)
descBox:GetPropertyChangedSignal("Text"):Connect(function()
	if #descBox.Text > Config.Coin.DescriptionMax then
		descBox.Text = descBox.Text:sub(1, Config.Coin.DescriptionMax)
	end
end)
devBox:GetPropertyChangedSignal("Text"):Connect(refreshDevBuy)

-- same free-ticker picker the game's Randomize button uses
local function freeTemplate()
	local taken = {}
	for _, coin in pairs(Market.coins) do
		taken[coin.ticker] = true
	end
	local rng = Random.new()
	for _ = 1, 30 do
		local t = CoinCatalog.randomTemplate(rng)
		for _, candidate in ipairs(t.TickerCandidates) do
			if not taken[candidate] and #candidate >= Config.Coin.TickerMin then
				t.Ticker = candidate
				return t
			end
		end
	end
	local t = CoinCatalog.randomTemplate(rng)
	t.Ticker = t.TickerCandidates[1]:sub(1, 6) .. rng:NextInteger(10, 99)
	return t
end

randomBtn.Activated:Connect(function()
	local t = freeTemplate()
	nameBox.Text = t.Name
	tickerBox.Text = t.Ticker
	descBox.Text = t.Description
	form.colorIndex = t.ColorIndex
	form.category = t.Category
	form.icon = t.Icon
	form.rebuildIcons()
end)

local function launch()
	if form.busy then
		return
	end
	form.busy = true
	launchBtn.Text = "Launching…"
	setStatus("", false)

	task.spawn(function()
		local logo
		if logoPad then
			local okExport, exported = pcall(logoPad.Export, logoPad)
			logo = okExport and exported or nil
		end

		local data = {
			Name = nameBox.Text,
			Ticker = tickerBox.Text,
			Description = descBox.Text,
			Category = form.category,
			Icon = form.icon,
			ColorIndex = form.colorIndex,
			Network = form.network,
			DevBuy = form.devBuy > 0 and form.devBuy or nil,
			Logo = logo,
		}
		local ok, res = pcall(function()
			return Account:CreateCoin(data)
		end)
		form.busy = false
		form.refresh()

		if not ok then
			setStatus(tostring(res), true)
			return
		end
		if type(res) ~= "table" or not res.ok then
			setStatus((type(res) == "table" and res.error) or "Something went wrong.", true)
			return
		end

		nameBox.Text, tickerBox.Text, descBox.Text, devBox.Text = "", "", "", ""
		if logoPad then
			pcall(logoPad.Reset, logoPad)
		end
		if res.devError then
			setStatus("Launched, but the dev buy failed: " .. tostring(res.devError), true)
		else
			setStatus("Coin launched.", false)
		end

		if res.coinId then
			local started = os.clock()
			while not Market.coins[res.coinId] and os.clock() - started < 3 do
				task.wait(0.1)
			end
			selectedCoinId = res.coinId
			openInGame(res.coinId)
		end
	end)
end
launchBtn.Activated:Connect(launch)

--// trade tab ------------------------------------------------------------------------

local tradeScroll = new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Size = UDim2.fromScale(1, 1),
	Parent = tradePage,
}, { list(Enum.FillDirection.Vertical, 10), new("UIPadding", { PaddingRight = UDim.new(0, 8) }) })

local coinCard = new("Frame", {
	BackgroundColor3 = C.Card,
	Size = UDim2.new(1, 0, 0, 58),
	LayoutOrder = 1,
	Parent = tradeScroll,
}, { corner(8), pad(0, 12) })
local coinTitle = label({
	RichText = true,
	Font = FONT_B,
	TextSize = 15,
	Position = UDim2.fromOffset(0, 9),
	Size = UDim2.new(1, -90, 0, 20),
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = coinCard,
})
local coinChange = label({
	Font = FONT_M,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Right,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 9),
	Size = UDim2.fromOffset(84, 20),
	Parent = coinCard,
})
local coinSub = label({
	TextSize = 11,
	TextColor3 = C.Muted,
	Position = UDim2.fromOffset(0, 32),
	Size = UDim2.new(1, 0, 0, 16),
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = coinCard,
})

local holdingInfo = label({
	TextSize = 12,
	TextColor3 = C.Muted,
	TextWrapped = true,
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = tradeScroll,
})

local function amountRow(order, placeholder, actionText, actionColor)
	local row = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = order,
		Parent = tradeScroll,
	}, { list(Enum.FillDirection.Horizontal, 6) })
	local box = new("TextBox", {
		BorderSizePixel = 0,
		TextSize = 13,
		PlaceholderText = placeholder,
		ClearTextOnFocus = false,
		Text = "",
		LayoutOrder = 1,
		BackgroundColor3 = C.Input,
		Font = FONT_M,
		TextColor3 = C.Text,
		PlaceholderColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -126, 0, 36),
		Parent = row,
	}, { corner(6), pad(0, 10), stroke(C.Border) })
	local action = button({
		Text = actionText,
		BackgroundColor3 = actionColor,
		TextColor3 = C.Bg,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(120, 36),
		Parent = row,
	}, { corner(8) })
	return box, action
end

section(tradeScroll, 3, "BUY  ·  amount in market balance")
local buyChips = chipGrid(tradeScroll, 4, 64, 32)
local buyBox, buyBtn = amountRow(5, "Amount $", "Buy", C.Up)

section(tradeScroll, 6, "SELL  ·  percent of your position")
local sellChips = chipGrid(tradeScroll, 7, 64, 32)
local sellBox, sellBtn = amountRow(8, "Percent", "Sell", C.Down)

local tradeStatus = label({
	TextSize = 12,
	TextWrapped = true,
	LayoutOrder = 9,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = tradeScroll,
})

local function tradeSay(text, isError)
	tradeStatus.Text = text
	tradeStatus.TextColor3 = isError == nil and C.Muted or (isError and C.Down or C.Up)
end

-- quick-buy / quick-sell chips follow the presets saved in the game's account prefs
local presetSig
local function rebuildPresets()
	local buys, sells = Account:QuickPresets()
	local sig = table.concat(buys, ",") .. "|" .. table.concat(sells, ",")
	if sig == presetSig then
		return
	end
	presetSig = sig

	for _, grid in ipairs({ buyChips, sellChips }) do
		for _, child in ipairs(grid:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	for i, v in ipairs(buys) do
		local b = button({ Text = compact(v, "$"), TextSize = 12, LayoutOrder = i, Parent = buyChips }, { corner(6) })
		b.Activated:Connect(function()
			buyBox.Text = tostring(v)
		end)
	end
	for i, v in ipairs(sells) do
		local b = button({ Text = string.format("%g%%", v), TextSize = 12, LayoutOrder = i, Parent = sellChips }, { corner(6) })
		b.Activated:Connect(function()
			sellBox.Text = tostring(v)
		end)
	end
end

local function findBalance()
	local acct = Account.account
	if type(acct) ~= "table" then
		return nil
	end
	for k, v in pairs(acct) do
		if type(v) == "number" and type(k) == "string" then
			local lower = k:lower()
			if lower:find("balance") or lower:find("cash") then
				return k, v
			end
		end
	end
	return nil
end

-- the position table's layout isn't known, so list whatever numeric fields it has
local function holdingText(coin)
	local lines = {}
	local balKey, balance = findBalance()
	if balKey then
		table.insert(lines, string.format("%s: %s", balKey, money(balance)))
	end

	local pos = Account:Position(coin.id)
	if type(pos) == "table" then
		local keys = {}
		for k, v in pairs(pos) do
			if type(v) == "number" then
				table.insert(keys, k)
			end
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, k in ipairs(keys) do
			table.insert(parts, string.format("%s %s", tostring(k), compact(pos[k], "")))
		end
		table.insert(lines, "Position: " .. (#parts > 0 and table.concat(parts, "  ·  ") or "held"))
	else
		table.insert(lines, "No position in this coin.")
	end
	return table.concat(lines, "\n")
end

refreshTrade = function()
	rebuildPresets()

	-- a coin picked in the game's own UI becomes the Trade tab's coin too
	if Market.selectedId ~= lastGameSelection then
		lastGameSelection = Market.selectedId
		if lastGameSelection then
			selectedCoinId = lastGameSelection
		end
	end
	local coin = selectedCoinId and Market.coins[selectedCoinId]
	if not coin then
		coinTitle.Text = "No coin selected"
		coinChange.Text = ""
		coinSub.Text = "Pick one in the Market tab."
		holdingInfo.Text = ""
		return
	end

	coinTitle.Text = string.format('<b>$%s</b>  <font color="%s">%s</font>', esc(coin.ticker), MUTED_HEX, esc(coin.name))
	local ch = coin.change or 0
	coinChange.Text = signedPct(ch)
	coinChange.TextColor3 = ch >= 0 and C.Up or C.Down
	coinSub.Text = string.format(
		"%s mcap  ·  price $%.6g  ·  %s",
		compact(coin.mcap or 0, "$"), coin.price or 0, coin.phase or "Launch"
	)
	holdingInfo.Text = holdingText(coin)
end

local tradeBusy = false

local function trade(kind)
	if tradeBusy then
		return
	end
	local coin = selectedCoinId and Market.coins[selectedCoinId]
	if not coin then
		tradeSay("Select a coin in the Market tab first.", true)
		return
	end

	local amount, fraction
	if kind == "buy" then
		amount = parseAmount(buyBox.Text)
		if amount <= 0 then
			tradeSay("Enter an amount to buy.", true)
			return
		end
	else
		local percent = tonumber((sellBox.Text:gsub("[%%%s]", ""))) or 0
		fraction = math.clamp(percent / 100, 0, 1)
		if fraction <= 0 then
			tradeSay("Enter a percent to sell.", true)
			return
		end
	end

	tradeBusy = true
	tradeSay("Sending…", nil)

	task.spawn(function()
		-- the third argument is the price the client saw, which the server checks against slippage
		local ok, res = pcall(function()
			if kind == "buy" then
				return Account:Buy(coin.id, amount, coin.price)
			end
			return Account:Sell(coin.id, fraction, coin.price)
		end)
		tradeBusy = false

		if not ok then
			tradeSay(tostring(res), true)
			return
		end
		if type(res) ~= "table" or not res.ok then
			tradeSay((type(res) == "table" and res.error) or "Trade failed.", true)
			return
		end

		if kind == "buy" then
			tradeSay(string.format("Bought %s of $%s.", money(amount), coin.ticker), false)
		else
			tradeSay(string.format("Sold %g%% of $%s.", fraction * 100, coin.ticker), false)
		end
		refreshTrade()
	end)
end

buyBtn.Activated:Connect(function()
	trade("buy")
end)
sellBtn.Activated:Connect(function()
	trade("sell")
end)

-- The game fires Selected from its own threads, which can't touch this window (it lives in the executor's
-- hidden container), so the callback only sets a flag and the polling loop below does the redraw.
local selectionDirty = false
pcall(function()
	Market.Selected:Connect(function()
		selectionDirty = true
	end)
end)

--// auto trader (engine) -----------------------------------------------------------------
-- Rule-based momentum trader. It only talks to the game through `deps`, so it can be tested outside Roblox.
-- Paper mode (the default) runs the same logic but never calls the server.
-- Nothing here can promise a profit: fees are paid on every round trip and prices can turn at any time.

local AutoTrader = {}
AutoTrader.__index = AutoTrader

AutoTrader.defaults = {
	tradeSize = 100, -- $ per buy
	maxPositions = 3, -- coins held at once
	takeProfit = 10, -- sell everything once the gain (after fees) reaches this %
	stopLoss = 8, -- cut the position once the loss (after fees) reaches this %
	trailStart = 5, -- once the gain has reached this %, start protecting it...
	trailDrop = 3, -- ...and sell if it falls this many points below its peak
	maxHoldMinutes = 8,
	minHolders = 5,
	maxTopHolder = 30, -- skip coins where one wallet holds more than this % of supply
	maxCreatorShare = 20, -- skip coins where the creator still holds more than this % of supply
	minGain5m = 2, -- only buy coins already rising at least this % over 5 minutes...
	maxGain5m = 40, -- ...but not ones that have already pumped more than this
	maxPoolShare = 2, -- a buy may use at most this % of the coin's liquidity (keeps price impact small)
	lossLimit = 500, -- stop opening new trades once estimated losses reach this $
	onlyProfit = 1, -- 1 = never sell at a loss: hold until the position is in profit
}

-- label shown in the settings grid, in display order
AutoTrader.fields = {
	{ "tradeSize", "Trade size $" }, { "maxPositions", "Max coins at once" },
	{ "takeProfit", "Profit target %" }, { "stopLoss", "Stop loss %" },
	{ "trailStart", "Protect gains from %" }, { "trailDrop", "Sell if gain falls %" },
	{ "maxHoldMinutes", "Max hold (minutes)" }, { "minHolders", "Min holders" },
	{ "minGain5m", "Min 5m gain %" }, { "maxGain5m", "Max 5m gain %" },
	{ "maxTopHolder", "Max top holder %" }, { "maxCreatorShare", "Max creator share %" },
	{ "maxPoolShare", "Max % of pool per buy" }, { "lossLimit", "Stop after losing $" },
}

local AT_SETTLE_SECONDS = 4 -- ignore exits right after a buy, while the pool's numbers catch up
local AT_COOLDOWN_SECONDS = 6 -- minimum gap between buys
local AT_REBUY_SECONDS = 180 -- don't buy a coin again right after selling it
local AT_BLOCK_SECONDS = 60 -- skip a coin for a while after a failed buy
local AT_MIN_TRADE = 10
local AT_CRASH_5M = -15 -- sell at once if a held coin drops this much (%) over 5 minutes
local AT_MAX_ERRORS = 5 -- consecutive failures before the bot switches itself off
local AT_MIN_PROFIT = 0.5 -- in profit-only mode, no sale happens below this net gain (%)

function AutoTrader.new(deps)
	local self = setmetatable({}, AutoTrader)
	self.deps = deps
	self.running = false
	self.live = false
	self.busy = false
	self.windDown = false
	self.windDownReason = nil
	self.positions = {}
	self.recentlySold = {}
	self.blockedUntil = {}
	self.stats = { trades = 0, wins = 0, realized = 0 }
	self.errors = 0
	self.pauseUntil = 0
	self.lastBuyAt = -math.huge
	self.lastScan = nil
	self.lastScanLogAt = -math.huge
	self.note = nil
	return self
end

function AutoTrader:log(text, kind)
	self.deps.log(text, kind or "info")
end

function AutoTrader:Start(live)
	if self.running then
		return false
	end
	live = live and true or false
	if next(self.positions) and live ~= self.live then
		self:log("Close the open positions before switching between paper and live.", "warn")
		return false
	end
	self.live = live
	self.running = true
	self.windDown = false
	self.errors = 0
	self:log(live and "Started in LIVE mode: real trades." or "Started in PAPER mode: nothing is actually traded.", "warn")
	return true
end

function AutoTrader:Stop(reason)
	if not self.running then
		return
	end
	self.running = false
	self:log("Stopped" .. (reason and (": " .. reason) or "."), "warn")
end

function AutoTrader:NoteError()
	self.errors += 1
	if self.errors >= AT_MAX_ERRORS then
		self:Stop("too many errors in a row")
	end
end

function AutoTrader:CountPositions()
	local n = 0
	for _ in pairs(self.positions) do
		n += 1
	end
	return n
end

-- what the position would fetch right now, after the sell fee
function AutoTrader:ValueOf(pos, coin)
	local d = self.deps
	local fee = d.feeRate(coin)
	if pos.tokens then
		local ok, value = pcall(function()
			local cash, tokenReserve = d.market:ReservesFor(coin)
			if not self.live then
				-- a paper buy never moved the real pool, so add our own footprint to it
				cash += pos.amount
				tokenReserve -= pos.tokens
			end
			return d.curve.liquidationValue(cash, tokenReserve, pos.tokens, fee)
		end)
		if ok and type(value) == "number" and value == value and value >= 0 then
			return value
		end
	end
	return pos.cost * (coin.price / pos.entryPrice) * (1 - fee) / (1 + fee)
end

function AutoTrader:Finish(pos, value, reason)
	local pnl = value - pos.cost
	self.positions[pos.id] = nil
	self.recentlySold[pos.id] = self.deps.now()
	self.stats.trades += 1
	if pnl > 0 then
		self.stats.wins += 1
	end
	self.stats.realized += pnl
	self:log(
		string.format(
			"SELL $%s (%s): %+.1f%%, %s%s",
			pos.ticker, reason, (value / pos.cost - 1) * 100, pnl >= 0 and "+" or "-", self.deps.money(math.abs(pnl))
		),
		pnl >= 0 and "win" or "loss"
	)
end

function AutoTrader:Sell(pos, coin, value, reason)
	local d = self.deps
	if self.live then
		local ok, res = pcall(d.account.Sell, d.account, pos.id, 1, coin.price)
		if not ok or type(res) ~= "table" or not res.ok then
			pos.sellFails += 1
			local why = (ok and type(res) == "table" and res.error) or tostring(res)
			self:log(string.format("Sell of $%s failed (%d/3): %s", pos.ticker, pos.sellFails, tostring(why)), "warn")
			if pos.sellFails >= 3 then
				self.positions[pos.id] = nil
				self:log(string.format("Giving up on $%s: no longer tracking it. Check it by hand.", pos.ticker), "warn")
			end
			self:NoteError()
			return false
		end
		self.errors = 0
	end
	self:Finish(pos, value, reason)
	return true
end

function AutoTrader:ManagePositions(s, now)
	for id, pos in pairs(self.positions) do
		local coin = self.deps.market.coins[id]
		if not coin or coin.phase == "Rugged" then
			self:Finish(pos, 0, coin and "rugged, counted as a total loss" or "coin removed, counted as a total loss")
		elseif now - pos.openedAt >= AT_SETTLE_SECONDS then
			local value = self:ValueOf(pos, coin)
			local gain = (value / pos.cost - 1) * 100
			pos.peak = math.max(pos.peak, gain)
			local reason
			if gain >= s.takeProfit then
				reason = "take profit"
			elseif gain <= -s.stopLoss then
				reason = "stop loss"
			elseif pos.peak >= s.trailStart and gain <= pos.peak - s.trailDrop then
				reason = "trailing stop"
			elseif self.deps.pct(coin.change5m or 0) <= AT_CRASH_5M then
				reason = "price crashing"
			elseif now - pos.openedAt >= s.maxHoldMinutes * 60 then
				reason = "time limit"
			end
			-- profit-only: whatever the rule, never sell below a small net profit
			if reason and (s.onlyProfit or 0) ~= 0 and gain < AT_MIN_PROFIT then
				reason = nil
			end
			if reason then
				self:Sell(pos, coin, value, reason)
			end
		end
	end
end

-- the first filter a coin fails, or nil if it qualifies
function AutoTrader:RejectReason(coin, s, now)
	local d = self.deps
	if self.positions[coin.id]
		or (self.recentlySold[coin.id] or -math.huge) + AT_REBUY_SECONDS > now
		or (self.blockedUntil[coin.id] or -math.huge) > now
	then
		return "already held or cooling down"
	end
	if coin.phase ~= "Launch" then
		return "not in launch phase"
	end
	if (coin.price or 0) <= 0 or (coin.liquidity or 0) <= 0 then
		return "no price or liquidity"
	end
	if (coin.holders or 0) < s.minHolders then
		return "too few holders"
	end
	if (coin.progress or 0) > 0.9 then
		return "near graduation"
	end
	if d.pct(coin.topShare or 0) > s.maxTopHolder then
		return "top holder too big"
	end
	if d.pct(coin.creatorShare or 0) > s.maxCreatorShare then
		return "creator holds too much"
	end
	if (coin.creatorRep or 0.5) < 0.35 then
		return "low creator reputation"
	end
	if coin.price < 0.8 * (coin.ath or coin.price) then
		return "far below its high"
	end
	local gain = d.pct(coin.change5m or 0)
	if gain < s.minGain5m then
		return "5m momentum too low"
	end
	if gain > s.maxGain5m then
		return "already pumped"
	end
	return nil
end

-- best-trending coin that passes every filter, with the amount to spend on it.
-- Also records how many coins each filter rejected, so the GUI can explain a quiet bot.
function AutoTrader:PickCoin(s, now)
	local scan = { total = 0, qualified = 0, reasons = {} }
	local pick, pickAmount
	for _, coin in ipairs(self.deps.market:List("trending", "", { status = "Live" })) do
		scan.total += 1
		local reason = self:RejectReason(coin, s, now)
		local amount
		if not reason then
			amount = math.floor(math.min(s.tradeSize, coin.liquidity * s.maxPoolShare / 100) * 100) / 100
			if amount < AT_MIN_TRADE then
				reason = "pool too small for the trade size"
			end
		end
		if reason then
			scan.reasons[reason] = (scan.reasons[reason] or 0) + 1
		else
			scan.qualified += 1
			if not pick then
				pick, pickAmount = coin, amount
			end
		end
	end
	self.lastScan = scan
	return pick, pickAmount
end

-- looks for candidates without trading, so the GUI can show what the filters are doing
function AutoTrader:Scan()
	self:PickCoin(self.deps.getSettings(), self.deps.now())
end

function AutoTrader:ScanSummary()
	local scan = self.lastScan
	if not scan then
		return "No scan yet."
	end
	local parts = {}
	for reason, n in pairs(scan.reasons) do
		table.insert(parts, { reason, n })
	end
	table.sort(parts, function(a, b)
		if a[2] ~= b[2] then
			return a[2] > b[2]
		end
		return a[1] < b[1]
	end)
	local top = {}
	for i = 1, math.min(4, #parts) do
		table.insert(top, string.format("%s %d", parts[i][1], parts[i][2]))
	end
	return string.format(
		"Scanned %d coins, %d qualify.%s",
		scan.total, scan.qualified, #top > 0 and (" Skipped: " .. table.concat(top, " · ")) or ""
	)
end

function AutoTrader:Buy(coin, amount, now)
	local d = self.deps
	local fee = d.feeRate(coin)

	-- tokens we should get; only trusted if it roughly matches the spot price
	local tokens
	local okQuote, got = pcall(function()
		local cash, tokenReserve = d.market:ReservesFor(coin)
		return d.curve.buy(cash, tokenReserve, amount)
	end)
	if okQuote and type(got) == "number" and got > 0 and math.abs(got * coin.price / amount - 1) <= 0.35 then
		tokens = got
	end

	if self.live then
		local ok, res = pcall(d.account.Buy, d.account, coin.id, amount, coin.price)
		if not ok or type(res) ~= "table" or not res.ok then
			local why = tostring((ok and type(res) == "table" and res.error) or res)
			self:log(string.format("Buy of $%s failed: %s", coin.ticker, why), "warn")
			local lower = why:lower()
			if lower:find("balance") or lower:find("fund") or lower:find("afford") or lower:find("enough") then
				self.pauseUntil = now + 30
			else
				self.blockedUntil[coin.id] = now + AT_BLOCK_SECONDS
			end
			self:NoteError()
			return false
		end
	end

	self.errors = 0
	self.lastBuyAt = now
	self.positions[coin.id] = {
		id = coin.id,
		ticker = coin.ticker,
		amount = amount,
		cost = amount * (1 + fee),
		entryPrice = coin.price,
		tokens = tokens,
		openedAt = now,
		peak = -100,
		sellFails = 0,
	}
	self:log(
		string.format(
			"BUY $%s for %s (5m %+.1f%%, %d holders)",
			coin.ticker, d.money(amount), d.pct(coin.change5m or 0), math.floor(coin.holders or 0)
		),
		"buy"
	)
	return true
end

function AutoTrader:Tick()
	local d = self.deps
	local s = d.getSettings()
	local now = d.now()

	self:ManagePositions(s, now)

	if not self.windDown and -self.stats.realized >= s.lossLimit then
		self.windDown = true
		self.windDownReason = "loss limit reached"
		self:log("Loss limit reached: no new buys, closing what's open.", "warn")
	end
	if self.windDown then
		self.note = "closing positions, then stopping"
		if next(self.positions) == nil then
			self:Stop(self.windDownReason)
		end
		return
	end

	if now < self.pauseUntil then
		self.note = "paused after a balance error"
		return
	end
	if now - self.lastBuyAt < AT_COOLDOWN_SECONDS then
		self.note = "short pause between buys"
		return
	end
	if self:CountPositions() >= s.maxPositions then
		if (s.onlyProfit or 0) ~= 0 then
			self.note = string.format("holding %d coin(s), waiting for them to reach a profit", s.maxPositions)
		else
			self.note = string.format("holding the maximum of %d coin(s)", s.maxPositions)
		end
		return
	end
	local coin, amount = self:PickCoin(s, now)
	if coin then
		self.note = "buying"
		self:Buy(coin, amount, now)
	else
		self.note = "scanning, nothing qualifies yet"
		if now - self.lastScanLogAt >= 120 then
			self.lastScanLogAt = now
			self:log(self:ScanSummary(), "info")
		end
	end
end

-- one protected step; the GUI calls this about once a second
function AutoTrader:SafeTick()
	if not self.running or self.busy then
		return
	end
	self.busy = true
	local ok, err = pcall(self.Tick, self)
	self.busy = false
	if not ok then
		self:log("Internal error: " .. tostring(err), "warn")
		self:NoteError()
	end
end

-- sells everything the bot holds (also works while stopped)
function AutoTrader:SellAll(reason)
	while self.busy do
		task.wait(0.1)
	end
	self.busy = true
	local ok, err = pcall(function()
		local list = {}
		for _, pos in pairs(self.positions) do
			table.insert(list, pos)
		end
		for _, pos in ipairs(list) do
			local coin = self.deps.market.coins[pos.id]
			if not coin or coin.phase == "Rugged" then
				self:Finish(pos, 0, coin and "rugged, counted as a total loss" or "coin removed, counted as a total loss")
			else
				self:Sell(pos, coin, self:ValueOf(pos, coin), reason or "sold all")
			end
		end
	end)
	self.busy = false
	if not ok then
		self:log("Internal error: " .. tostring(err), "warn")
	end
end

-- rows for the GUI: one per open position
function AutoTrader:Snapshot()
	local rows = {}
	local now = self.deps.now()
	for id, pos in pairs(self.positions) do
		local coin = self.deps.market.coins[id]
		local value = coin and self:ValueOf(pos, coin) or 0
		table.insert(rows, {
			ticker = pos.ticker,
			cost = pos.cost,
			value = value,
			gain = (value / pos.cost - 1) * 100,
			peak = pos.peak,
			held = now - pos.openedAt,
		})
	end
	table.sort(rows, function(a, b)
		return a.held > b.held
	end)
	return rows
end

--// auto trader (tab) ---------------------------------------------------------------------

local autoScroll = new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Size = UDim2.fromScale(1, 1),
	Parent = autoPage,
}, { list(Enum.FillDirection.Vertical, 10), new("UIPadding", { PaddingRight = UDim.new(0, 8) }) })

local function autoText(order, props)
	return label(merge({
		RichText = true,
		TextWrapped = true,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = autoScroll,
	}, props))
end

local autoStatus = autoText(1, { Font = FONT_B, TextSize = 13 })
local autoProfit = autoText(2, { Font = FONT_B, TextSize = 20 })
local autoStats = autoText(3, { TextSize = 12, TextColor3 = C.Muted })

local autoButtons = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 36),
	LayoutOrder = 4,
	Parent = autoScroll,
}, { list(Enum.FillDirection.Horizontal, 6) })
local startBtn = button({
	Text = "Start",
	BackgroundColor3 = C.Up,
	TextColor3 = C.Bg,
	Size = UDim2.new(0.34, -4, 1, 0),
	LayoutOrder = 1,
	Parent = autoButtons,
}, { corner(8) })
local modeBtn = button({ Text = "Mode: PAPER", TextSize = 12, Size = UDim2.new(0.38, -4, 1, 0), LayoutOrder = 2, Parent = autoButtons }, { corner(8) })
local sellAllBtn = button({ Text = "Sell all", TextSize = 12, Size = UDim2.new(0.28, -4, 1, 0), LayoutOrder = 3, Parent = autoButtons }, { corner(8) })

autoText(5, {
	TextSize = 11,
	TextColor3 = C.Muted,
	Text = "PAPER mode only pretends to trade, so try it first. The bot buys trending new coins that are already rising and sells at your profit target. "
		.. "No rule predicts prices, and fees apply to every trade. Stopping the bot does not sell what it holds; use Sell all for that.",
})

section(autoScroll, 6, "SETTINGS  ·  applied on the next tick")
local function settingsGrid(order, visible)
	return new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Visible = visible,
		Parent = autoScroll,
	}, { new("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 0, 52), CellPadding = UDim2.fromOffset(8, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
end
local simpleGrid = settingsGrid(7, true)

local profitOnly = true
local profitOnlyBtn = button({ Text = "", TextSize = 13, LayoutOrder = 8, Size = UDim2.new(1, 0, 0, 36), Parent = autoScroll }, { corner(8) })
local profitHint = autoText(9, { TextSize = 11, TextColor3 = C.Muted })
local function applyProfitToggle()
	profitOnlyBtn.Text = "Only sell at a profit: " .. (profitOnly and "ON" or "OFF")
	profitOnlyBtn.BackgroundColor3 = profitOnly and C.Up or C.Card
	profitOnlyBtn.TextColor3 = profitOnly and C.Bg or C.Text
	profitHint.Text = profitOnly
		and "Never sells at a loss: each coin is held until it is in profit. A coin that never recovers ties up one of your slots, and if it gets rugged the money is lost anyway."
		or "Also cuts losses: sells at the stop loss, on a sharp drop, or when the time limit runs out, even at a loss. The Advanced settings control those limits."
end
profitOnlyBtn.Activated:Connect(function()
	profitOnly = not profitOnly
	applyProfitToggle()
end)
applyProfitToggle()

local advancedShown = false
local advancedBtn = button({ Text = "Show advanced settings", TextSize = 12, LayoutOrder = 10, Size = UDim2.new(1, 0, 0, 30), Parent = autoScroll }, { corner(8) })
local advancedGrid = settingsGrid(11, false)
advancedBtn.Activated:Connect(function()
	advancedShown = not advancedShown
	advancedGrid.Visible = advancedShown
	advancedBtn.Text = advancedShown and "Hide advanced settings" or "Show advanced settings"
end)

local SIMPLE_FIELDS = { tradeSize = true, takeProfit = true, maxPositions = true }
local settingBoxes = {}
for i, f in ipairs(AutoTrader.fields) do
	local cell = new("Frame", { BackgroundTransparency = 1, LayoutOrder = i, Parent = SIMPLE_FIELDS[f[1]] and simpleGrid or advancedGrid })
	label({ Text = f[2], TextSize = 11, Font = FONT_B, TextColor3 = C.Faint, Size = UDim2.new(1, 0, 0, 14), Parent = cell })
	settingBoxes[f[1]] = new("TextBox", {
		BorderSizePixel = 0,
		TextSize = 13,
		Text = tostring(AutoTrader.defaults[f[1]]),
		ClearTextOnFocus = false,
		BackgroundColor3 = C.Input,
		Font = FONT_M,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = cell,
	}, { corner(6), pad(0, 8), stroke(C.Border) })
end

section(autoScroll, 12, "OPEN POSITIONS")
local autoPositions = autoText(13, { Font = FONT_M, TextSize = 12 })
section(autoScroll, 14, "LOG  ·  newest first")
local autoLog = autoText(15, { TextSize = 11 })

local LOG_COLORS = {
	info = C.Muted,
	warn = Color3.fromRGB(251, 191, 36),
	win = C.Up,
	loss = C.Down,
	buy = Color3.fromRGB(143, 160, 255),
}
local logLines = {}
local function pushLog(text, kind)
	table.insert(logLines, 1, string.format('<font color="#%s">%s  %s</font>', (LOG_COLORS[kind] or C.Muted):ToHex(), os.date("%H:%M:%S"), esc(text)))
	while #logLines > 40 do
		table.remove(logLines)
	end
	autoLog.Text = table.concat(logLines, "\n")
end

local function readSettings()
	local s = {}
	for key, default in pairs(AutoTrader.defaults) do
		local box = settingBoxes[key]
		local n = box and tonumber((box.Text:gsub("[%%%$,%s]", "")))
		s[key] = (n and n >= 0) and n or default
	end
	s.onlyProfit = profitOnly and 1 or 0
	s.maxPositions = math.max(1, math.floor(tonumber(s.maxPositions) or 1))
	return s
end

local bot = AutoTrader.new({
	market = Market,
	account = Account,
	curve = Curve,
	now = os.clock,
	pct = pct,
	money = money,
	feeRate = function(coin)
		local ok, fee = pcall(Networks.feeRate, coin.network)
		if ok and type(fee) == "number" then
			return fee
		end
		local okNet, net = pcall(Networks.get, coin.network or Networks.Default)
		return okNet and net and net.Fee or 0.01
	end,
	getSettings = readSettings,
	log = pushLog,
})

local selectedLive = false
local liveArmedUntil = 0

local function fmtDuration(seconds)
	seconds = math.floor(seconds)
	return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

local function signedMoney(n)
	return (n >= 0 and "+" or "-") .. money(math.abs(n))
end

refreshAuto = function()
	local liveHex, paperHex = "#" .. C.Down:ToHex(), "#" .. C.Up:ToHex()
	if bot.running then
		if bot.windDown then
			autoStatus.Text = "● WINDING DOWN  ·  no new buys, closing positions, then stopping"
		elseif bot.live then
			autoStatus.Text = string.format('<font color="%s">● RUNNING  ·  LIVE: real trades</font>', liveHex)
		else
			autoStatus.Text = string.format('<font color="%s">● RUNNING  ·  PAPER: simulated</font>', paperHex)
		end
	else
		autoStatus.Text = string.format("○ STOPPED  ·  next start: %s", selectedLive and "LIVE (real trades)" or "PAPER (simulated)")
	end

	local stats = bot.stats
	local statsLine = string.format(
		"Closed trades %d (%d in profit)  ·  open %d",
		stats.trades, stats.wins, bot:CountPositions()
	)
	if not bot.running then
		pcall(bot.Scan, bot) -- keep the scan fresh while stopped, so the filters can be tuned before starting
	end
	autoStats.Text = statsLine .. (bot.running and ("\nNow: " .. (bot.note or "starting up")) or "") .. "\n" .. bot:ScanSummary()

	local rows = bot:Snapshot()
	-- the headline figure counts what's still open too, so held losers can't hide
	local openPnl = 0
	for _, r in ipairs(rows) do
		openPnl += r.value - r.cost
	end
	local totalPnl = stats.realized + openPnl
	autoProfit.Text = string.format(
		'Profit <font color="%s">%s</font>   <font size="12" color="%s">closed %s  ·  open %s  (estimates)</font>',
		totalPnl >= 0 and paperHex or liveHex, signedMoney(totalPnl), MUTED_HEX, signedMoney(stats.realized), signedMoney(openPnl)
	)
	if #rows == 0 then
		autoPositions.Text = "None."
	else
		local lines = {}
		for _, r in ipairs(rows) do
			table.insert(lines, string.format(
				'<b>$%s</b>  cost %s  <font color="%s">%+.1f%%</font>  peak %s  held %s',
				esc(r.ticker), money(r.cost), r.gain >= 0 and paperHex or liveHex, r.gain,
				r.peak > -99 and string.format("%+.1f%%", r.peak) or "--", fmtDuration(r.held)
			))
		end
		autoPositions.Text = table.concat(lines, "\n")
	end

	startBtn.Text = bot.running and "Stop" or "Start"
	startBtn.BackgroundColor3 = bot.running and C.Down or C.Up
	if selectedLive then
		modeBtn.Text = "Mode: LIVE"
		modeBtn.BackgroundColor3 = C.Down
		modeBtn.TextColor3 = C.Bg
	else
		modeBtn.Text = os.clock() < liveArmedUntil and "Confirm LIVE?" or "Mode: PAPER"
		modeBtn.BackgroundColor3 = C.Card
		modeBtn.TextColor3 = C.Text
	end
end

startBtn.Activated:Connect(function()
	if bot.running then
		bot:Stop("stopped by you")
		local open = bot:CountPositions()
		if open > 0 then
			pushLog(string.format("%d position(s) are still held and no longer managed. Use Sell all to close them.", open), "warn")
		end
	else
		bot:Start(selectedLive)
	end
	refreshAuto()
end)

modeBtn.Activated:Connect(function()
	if bot.running then
		pushLog("Stop the bot before changing mode.", "warn")
	elseif bot:CountPositions() > 0 then
		pushLog("Close the open positions first (Sell all).", "warn")
	elseif selectedLive then
		selectedLive = false
	elseif os.clock() < liveArmedUntil then
		selectedLive = true
		liveArmedUntil = 0
	else
		liveArmedUntil = os.clock() + 5
		pushLog("Click the mode button again within 5 seconds to confirm LIVE trading with your real market balance.", "warn")
	end
	refreshAuto()
end)

sellAllBtn.Activated:Connect(function()
	task.spawn(function()
		bot:SellAll("sold by you")
		refreshAuto()
	end)
end)

task.spawn(function()
	while gui.Parent do
		task.wait(1)
		bot:SafeTick()
		if main.Visible and autoPage.Visible then
			pcall(refreshAuto)
		end
	end
	bot.running = false
end)

--// wiring -------------------------------------------------------------------

closeBtn.Activated:Connect(function()
	gui:Destroy()
end)

UIS.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then
		main.Visible = not main.Visible
	end
end)

task.spawn(function()
	local ticks = 0
	while gui.Parent do
		task.wait(0.25)
		ticks += 1
		local everySecond = ticks % 4 == 0

		-- result of the Fresh pick button, which looked the coin up in a separate thread
		if pendingFresh ~= nil then
			local fresh = pendingFresh
			pendingFresh = nil
			if fresh then
				selectedCoinId = fresh
				showTab("Trade")
				openInGame(fresh)
			else
				countLabel.Text = "No fresh launches right now."
			end
		end

		if main.Visible then
			if marketPage.Visible then
				if everySecond then
					refreshMarket()
				end
			elseif tradePage.Visible and (selectionDirty or everySecond) then
				refreshTrade()
			end
		end
		selectionDirty = false
	end
end)

form.rebuildIcons()
showTab("Market")
