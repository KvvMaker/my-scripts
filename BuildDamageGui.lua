-- BuildDamageGui.lua
-- Paste into the Studio command bar (or run as a plugin) while editing your place.
-- Creates the two UI objects the damage-direction controller looks up:
--   StarterGui.GameUI.HUD.DamageDirectionArrow   (ImageLabel, template, hidden)
--   StarterGui.SharedUI.DamageVignette           (ImageLabel, hidden)
--
-- 1. Upload DamageArrow.png and DamageVignette.png as Images (Creator Hub > Assets).
-- 2. Paste the asset ids below, then run this once.

local ARROW_IMAGE = "rbxassetid://0"     -- DamageArrow.png
local VIGNETTE_IMAGE = "rbxassetid://0"  -- DamageVignette.png

local StarterGui = game:GetService("StarterGui")

local function replace(parent, name)
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
end

local function screenGui(name, displayOrder)
	replace(StarterGui, name)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = StarterGui
	return gui
end

-- GameUI > HUD > DamageDirectionArrow
local gameUI = screenGui("GameUI", 1)

local hud = Instance.new("Frame")
hud.Name = "HUD"
hud.BackgroundTransparency = 1
hud.BorderSizePixel = 0
hud.Size = UDim2.fromScale(1, 1)
hud.Parent = gameUI

-- The controller offsets this from the centre (radius 130px) and rotates it,
-- so keep the anchor centred and the artwork pointing UP at Rotation 0.
local arrow = Instance.new("ImageLabel")
arrow.Name = "DamageDirectionArrow"
arrow.AnchorPoint = Vector2.new(0.5, 0.5)
arrow.Position = UDim2.fromScale(0.5, 0.5)
arrow.Size = UDim2.fromOffset(56, 56)
arrow.BackgroundTransparency = 1
arrow.BorderSizePixel = 0
arrow.Image = ARROW_IMAGE
arrow.ImageColor3 = Color3.fromRGB(255, 30, 30)
arrow.ImageTransparency = 0
arrow.ScaleType = Enum.ScaleType.Fit
arrow.Visible = false
arrow.ZIndex = 5
arrow.Parent = hud

-- SharedUI > DamageVignette
local sharedUI = screenGui("SharedUI", 10)

local vignette = Instance.new("ImageLabel")
vignette.Name = "DamageVignette"
vignette.AnchorPoint = Vector2.new(0.5, 0.5)
vignette.Position = UDim2.fromScale(0.5, 0.5)
vignette.Size = UDim2.fromScale(1, 1)
vignette.BackgroundTransparency = 1
vignette.BorderSizePixel = 0
vignette.Image = VIGNETTE_IMAGE
vignette.ImageColor3 = Color3.fromRGB(255, 0, 0)
vignette.ImageTransparency = 1
vignette.ScaleType = Enum.ScaleType.Stretch
vignette.Visible = false
vignette.Active = false
vignette.Parent = sharedUI

print("Damage GUI built in StarterGui (GameUI.HUD.DamageDirectionArrow, SharedUI.DamageVignette)")
