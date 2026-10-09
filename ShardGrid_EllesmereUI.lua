-- Optional EllesmereUI look.
-- When EllesmereUI's Blizzard Skins+ module is running, Shard Grid registers with its public
-- skinning API (SKINNING_API.md in EllesmereUI) and the windows, buttons, slots and bars are
-- painted in the player's EllesmereUI theme. Without EllesmereUI nothing here runs and the
-- Blizzard look is untouched. Players switch it off in EllesmereUI's own options, under
-- Blizzard Skins+ > Window Skins > Third-Party Addons; that takes a reload.

local ADDON, ns = ...
local report = ns.report or {}

if not (EllesmereUI and EllesmereUI.RegisterSkin) then
	report["skin"] = "Blizzard (EllesmereUI is not loaded)"
	return
end

-- Registering always works, but only the Blizzard Skins+ module ever calls back. Until it
-- does, say why the look has not changed.
report["skin"] = "Blizzard (waiting for EllesmereUI)"
local check = CreateFrame("Frame")
check:RegisterEvent("PLAYER_ENTERING_WORLD")
check:SetScript("OnEvent", function(self)
	self:UnregisterAllEvents()
	if report["skin"] ~= "Blizzard (waiting for EllesmereUI)" then return end
	if type(EllesmereUI._DispatchSkinRegistration) ~= "function" then
		report["skin"] = "Blizzard (EllesmereUI's Blizzard Skins+ module is off)"
	else
		report["skin"] = "Blizzard (switched off for Shard Grid in EllesmereUI's options)"
	end
end)

local S -- EllesmereUI's skinning functions, once it hands them over
local FLAT = "Interface\\Buttons\\WHITE8X8"

-- One piece failing must not leave the rest unskinned. Failures show in /shards debug.
local function Try(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then report["skin error: " .. what] = tostring(err) end
end

-- The floating summon button is a secure button, which the game locks in combat. Anything
-- reaching it then waits for combat to end.
local waiting = {}
local waiter = CreateFrame("Frame")
waiter:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	local list = waiting
	waiting = {}
	for _, job in ipairs(list) do Try(job[1], job[2]) end
end)
local function OutOfCombat(what, fn)
	if InCombatLockdown() then
		waiting[#waiting + 1] = { what, fn }
		waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
	else
		Try(what, fn)
	end
end

local function Fonts(...)
	for i = 1, select("#", ...) do
		local fs = select(i, ...)
		if type(fs) == "table" and fs.GetFont then S.Font(fs) end
	end
end

local function SkinButton(button)
	if not button then return end
	S.Button(button)
	S.WhiteButtonLabel(button)
	if button.GetFontString then Fonts(button:GetFontString()) end
end

-- A bag slot's art gives way to a dark square, the way EllesmereUI draws its own slots.
local function DarkSlot(tex)
	if not tex then return end
	tex:SetTexCoord(0, 1, 0, 1)
	tex:SetColorTexture(0, 0, 0, 0.45)
end

-- The window backdrop and border. The border is a frame EllesmereUI lays over the whole
-- window; those frames are returned so the summon window can hide them while it is only a
-- title strip, which the border art cannot shrink to.
local function SkinWindow(win, ...)
	if not win then return {} end
	local before = {}
	for _, child in ipairs({ win:GetChildren() }) do before[child] = true end
	S.Shell(win)
	local added = {}
	for _, child in ipairs({ win:GetChildren() }) do
		if not before[child] then added[#added + 1] = child end
	end
	local close = type(win.sgClose) == "table" and win.sgClose or nil
	if win.sgTitle then Fonts(win.sgTitle) end
	if close then S.CloseButton(close) end
	-- The border sits above everything in the window; put the title bar buttons back on top.
	local raise = { close, ... }
	for i = 1, select("#", ...) + 1 do
		local button = raise[i]
		if type(button) == "table" and ns.RaiseWithinParent then ns.RaiseWithinParent(button, win) end
	end
	return added
end

local summonBorders = {}
function ns.SkinMinimized(min)
	for _, f in ipairs(summonBorders) do f:SetAlpha(min and 0 or 1) end
end

-- ---- pieces built later, as they are needed -----------------------------------------------

function ns.SkinCell(cell)
	if not S then return end
	Try("grid slot", function()
		DarkSlot(cell.bg)
		S.SquareIcon(cell.icon, cell)
		Fonts(cell.count)
	end)
end

function ns.SkinSummonRow(row)
	if not S then return end
	Try("summon row", function()
		SkinButton(row.invite)
		if row.remove then S.CloseButton(row.remove) end
		Fonts(row.nameText, row.classText, row.ageText)
	end)
end

-- Runs after the bar art is applied, every time it is, so a grabbed bar does not undo it.
function ns.SkinStoneRow(row)
	if not S then return end
	Try("soulstone bar", function()
		-- EllesmereUI's square icon cannot crop a masked texture, so the round mask goes first.
		if row.iconMask and row.icon.RemoveMaskTexture then
			pcall(row.icon.RemoveMaskTexture, row.icon, row.iconMask)
		end
		row.iconShadow:Hide()
		row.iconOverlay:Hide()
		S.SquareIcon(row.icon, row.iconFrame)

		-- A flat fill on a dark track with a 1px edge. The purple, and the red in the last
		-- minute, are still set by the countdown.
		row.fill:SetStatusBarTexture(FLAT)
		row.bg:ClearAllPoints()
		row.bg:SetPoint("TOPLEFT", row.fill, "TOPLEFT", -1, 1)
		row.bg:SetPoint("BOTTOMRIGHT", row.fill, "BOTTOMRIGHT", 1, -1)
		row.bg:SetTexCoord(0, 1, 0, 1)
		row.bg:SetColorTexture(0, 0, 0, 0.6)
		row.bg:Show()
		row.spark:SetAlpha(0) -- the countdown shows and hides it; it stays invisible
		local border = rawget(row.fill, "borderFrame")
		if type(border) == "table" and border.Hide then border:Hide() end
		Fonts(row.nameText, row.timeText, row.casterText)
	end)
end

function ns.SkinMakeButton(button)
	if not S then return end
	OutOfCombat("healthstone button", function() SkinButton(button) end)
end

-- ---- everything that exists at login --------------------------------------------------------

EllesmereUI.RegisterSkin(ADDON, function(skin)
	S = skin
	local style = S.GetStyle and S.GetStyle()
	report["skin"] = "EllesmereUI" .. (style and (" (" .. tostring(style) .. " style)") or "")

	Try("grid window", function()
		SkinWindow(ShardGridFrame, ns.cog, ns.grip)
		Fonts(ns.gridEmpty)
	end)

	Try("summon window", function()
		summonBorders = SkinWindow(ShardGridSummons, ns.sumMinBtn)
		local mini = ns.sumMini
		if mini then
			if mini.SetBackdrop then mini:SetBackdrop(nil) end
			Fonts(mini.title)
		end
		SkinButton(ns.sumMinBtn)
		SkinButton(ns.sumClear)
		Fonts(ns.sumFooter, ns.sumEmpty)
		ns.SkinMinimized(ns.summonMinimized)
	end)

	Try("soulstone window", function()
		local win = ShardGridStones
		SkinWindow(win, win and win.reportBtn)
		local reportButton = win and win.reportBtn
		if reportButton then
			for _, region in ipairs({ reportButton:GetRegions() }) do
				if region.GetDrawLayer and region:GetDrawLayer() == "BACKGROUND" then DarkSlot(region) end
			end
		end
	end)

	Try("alert icon", function()
		local alert = ShardGridAlert
		if not alert then return end
		DarkSlot(alert.bg)
		S.SquareIcon(alert.icon, alert)
		Fonts(alert.count, alert.label)
	end)

	OutOfCombat("summon button", function()
		local button = ShardGridSummonAction
		if not button then return end
		if button.slot then button.slot:SetAlpha(0) end
		S.SquareIcon(button.icon, button)
		Fonts(button.label, button.count)
	end)

	-- Anything already built before EllesmereUI called back.
	for _, cell in pairs(ns.cells or {}) do ns.SkinCell(cell) end
	for _, row in pairs(ns.stoneRows or {}) do ns.SkinStoneRow(row) end
	for i = 1, 40 do
		local row = _G["ShardGridSummonRow" .. i]
		if not row then break end
		ns.SkinSummonRow(row)
	end
	if ShardGridMakeHealthstone then ns.SkinMakeButton(ShardGridMakeHealthstone) end
end)
