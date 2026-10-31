--[[
    Hatch UI builder  (Roblox Studio command bar / execute_luau, Edit mode)

    Builds the two pieces of UI that HatchController expects:

      StarterGui.Hatching                      (ScreenGui -> PlayerGui.Hatching at runtime)
        Container   Frame      full screen, holds the per-pet label frames
        Cover       Frame      full screen white overlay used for the reveal flash (starts invisible)
        Info        TextLabel  optional status text, hidden by the controller

      ReplicatedStorage.Assets.UI.PetHatch     (template the controller clones from an InstancePool)
        UIScale
        PetName     Frame      holds the TextLabel(s) the controller writes the pet name into
          Shadow    TextLabel
          Text      TextLabel
        Rarity      TextLabel  controller writes the "1 in N" odds (or rarity name) and applies the rarity gradient
        AutoDeleted Frame      badge, the controller toggles .Visible

    Why these settings
      * Hatching.IgnoreGuiInset = true      pet label positions come from Camera:WorldToViewportPoint, which is
                                            measured from the top-left of the real screen, not below the topbar.
      * Hatching.Enabled = false            the controller turns it on for a hatch and off afterwards.
      * Hatching.ResetOnSpawn = false       the hatch can outlive a respawn.
      * PetHatch is anchored at its centre  the controller puts that centre on the pet; the labels sit below it.
        Tune the Y offsets of PetName / Rarity / AutoDeleted if your pets are bigger or smaller on screen.

    Safe to re-run: anything that already exists is left alone unless REPLACE is true.
]]

local REPLACE = false

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local FONT = Enum.Font.FredokaOne
local log = {}

local function note(message)
	table.insert(log, message)
end

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for key, value in pairs(props) do
		if key == "Parent" then
			parent = value
		else
			inst[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function stroke(thickness, color)
	return new("UIStroke", {
		Thickness = thickness,
		Color = color or Color3.new(0, 0, 0),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

local function folder(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	note("created " .. parent:GetFullName() .. "." .. name .. " (was missing)")
	return new("Folder", { Name = name, Parent = parent })
end

-- Returns true when `name` may be (re)created under `parent`.
local function claim(parent, name)
	local existing = parent:FindFirstChild(name)
	if not existing then
		return true
	end
	if REPLACE then
		existing:Destroy()
		note("replaced " .. parent:GetFullName() .. "." .. name)
		return true
	end
	note("skipped " .. parent:GetFullName() .. "." .. name .. " (already exists, set REPLACE = true to rebuild)")
	return false
end

ChangeHistoryService:SetWaypoint("Before hatch UI")

--------------------------------------------------------------------------------
-- Hatching ScreenGui
--------------------------------------------------------------------------------
if claim(StarterGui, "Hatching") then
	local gui = new("ScreenGui", {
		Name = "Hatching",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Enabled = false,
		DisplayOrder = 1100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = StarterGui,
	})

	new("Frame", {
		Name = "Container",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 2,
		Parent = gui,
	})

	new("Frame", {
		Name = "Cover",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 10,
		Parent = gui,
	})

	new("TextLabel", {
		Name = "Info",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -36),
		Size = UDim2.fromOffset(420, 32),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "",
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	}, { stroke(2) })

	note("built StarterGui.Hatching")
end

--------------------------------------------------------------------------------
-- PetHatch template
--------------------------------------------------------------------------------
local assets = folder(ReplicatedStorage, "Assets")
local ui = folder(assets, "UI")

if claim(ui, "PetHatch") then
	-- The frame's centre is placed on the pet; everything else hangs below it.
	local frame = new("Frame", {
		Name = "PetHatch",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(380, 460),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		Visible = false,
	})

	new("UIScale", { Scale = 1, Parent = frame })

	-- PetName: a Frame; the controller sets Text on every TextLabel child (shadow + main).
	local petName = new("Frame", {
		Name = "PetName",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 130),
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	new("TextLabel", {
		Name = "Shadow",
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "Pet Name",
		TextScaled = true,
		TextColor3 = Color3.new(0, 0, 0),
		TextTransparency = 0.55,
		ZIndex = 1,
		Parent = petName,
	}, { new("UITextSizeConstraint", { MaxTextSize = 42, MinTextSize = 12 }) })
	new("TextLabel", {
		Name = "Text",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "Pet Name",
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = petName,
	}, { new("UITextSizeConstraint", { MaxTextSize = 42, MinTextSize = 12 }), stroke(3) })

	-- Rarity: the controller writes the odds / rarity text here and applies the rarity gradient (white base text).
	new("TextLabel", {
		Name = "Rarity",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 180),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "Common",
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = frame,
	}, { new("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 10 }), stroke(2.5) })

	-- AutoDeleted: badge, hidden unless the pet is auto-deleted.
	local badge = new("Frame", {
		Name = "AutoDeleted",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 218),
		Size = UDim2.fromOffset(170, 26),
		BackgroundColor3 = Color3.fromRGB(205, 55, 55),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 2,
		Parent = frame,
	}, {
		new("UICorner", { CornerRadius = UDim.new(0, 13) }),
		stroke(2, Color3.fromRGB(90, 15, 15)),
	})
	new("TextLabel", {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "AUTO-DELETED",
		TextSize = 16,
		TextColor3 = Color3.new(1, 1, 1),
		ZIndex = 3,
		Parent = badge,
	})

	frame.Parent = ui
	note("built ReplicatedStorage.Assets.UI.PetHatch")
end

ChangeHistoryService:SetWaypoint("After hatch UI")

return table.concat(log, "\n")
