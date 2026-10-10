-- Shard Grid's pieces in the window styles. Styles.lua does the choosing and the drawing
-- (Blizzard, Dark, or EllesmereUI's look); this file says what Shard Grid has to restyle.

local ADDON, ns = ...
local Styles = ns.Styles
local Try, OutOfCombat = Styles.Try, Styles.OutOfCombat
local FLAT = "Interface\\Buttons\\WHITE8X8"

local function S() return Styles.S end

local function Fonts(...)
	for i = 1, select("#", ...) do
		local fs = select(i, ...)
		if type(fs) == "table" and fs.GetFont then S().Font(fs) end
	end
end

local function SkinButton(button)
	if not button then return end
	S().Button(button)
	S().WhiteButtonLabel(button)
	if button.GetFontString then Fonts(button:GetFontString()) end
end

-- A bag slot's art gives way to a dark square.
local function DarkSlot(tex)
	if not tex then return end
	tex:SetTexCoord(0, 1, 0, 1)
	tex:SetColorTexture(0, 0, 0, 0.45)
end

-- The window backdrop and border. EllesmereUI lays its border over the whole window as a frame
-- of its own; those frames are returned so the summon window can hide them while it is only a
-- title strip, which that border art cannot shrink to. Dark draws on the window itself and
-- returns none.
local function SkinWindow(win, ...)
	if not win then return {} end
	local before = {}
	for _, child in ipairs({ win:GetChildren() }) do before[child] = true end
	S().Shell(win)
	local added = {}
	for _, child in ipairs({ win:GetChildren() }) do
		if not before[child] then added[#added + 1] = child end
	end
	local close = type(win.sgClose) == "table" and win.sgClose or nil
	if win.sgTitle then Fonts(win.sgTitle) end
	if close then S().CloseButton(close) end
	-- A border frame sits above everything in the window; put the title bar buttons back on top.
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

-- ---- pieces built later, as they are needed -----------------------------------------------------

function ns.SkinCell(cell)
	if not S() then return end
	Try("grid slot", function()
		DarkSlot(cell.bg)
		S().SquareIcon(cell.icon, cell)
		Fonts(cell.count)
	end)
end

function ns.SkinSummonRow(row)
	if not S() then return end
	Try("summon row", function()
		SkinButton(row.invite)
		if row.remove then S().CloseButton(row.remove) end
		Fonts(row.nameText, row.classText, row.ageText)
	end)
end

-- Runs after the bar art is applied, every time it is, so a grabbed bar does not undo it.
function ns.SkinStoneRow(row)
	if not S() then return end
	Try("soulstone bar", function()
		-- A square icon cannot be cropped through the round mask, so the mask goes first.
		if row.iconMask and row.icon.RemoveMaskTexture then
			pcall(row.icon.RemoveMaskTexture, row.icon, row.iconMask)
		end
		row.iconShadow:Hide()
		row.iconOverlay:Hide()
		S().SquareIcon(row.icon, row.iconFrame)

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
	if not S() then return end
	OutOfCombat("healthstone button", function() SkinButton(button) end)
end

-- ---- everything that exists when a style is applied ---------------------------------------------

local function SkinAll(_, style)
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
			if style == "dark" and type(mini.title) == "table" then mini.title:SetTextColor(1, 1, 1) end
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
		S().SquareIcon(alert.icon, alert)
		Fonts(alert.count, alert.label)
	end)

	OutOfCombat("summon button", function()
		local button = ShardGridSummonAction
		if not button then return end
		if button.slot then button.slot:SetAlpha(0) end
		S().SquareIcon(button.icon, button)
		Fonts(button.label, button.count)
	end)

	-- Anything already built.
	for _, cell in pairs(ns.cells or {}) do ns.SkinCell(cell) end
	for _, row in pairs(ns.stoneRows or {}) do ns.SkinStoneRow(row) end
	for i = 1, 40 do
		local row = _G["ShardGridSummonRow" .. i]
		if not row then break end
		ns.SkinSummonRow(row)
	end
	if ShardGridMakeHealthstone then ns.SkinMakeButton(ShardGridMakeHealthstone) end
end

-- The names the options page and slash commands already use.
ns.StyleName, ns.StyleNote, ns.CycleStyle, ns.SetStyle = Styles.Name, Styles.Note, Styles.Cycle, Styles.Set
ns.SetDarkAlpha, ns.StyleChanged, ns.ReloadPrompt = Styles.SetDarkAlpha, Styles.Changed, Styles.ReloadPrompt

Styles.Setup({
	addon = ADDON,
	title = "Shard Grid",
	db = function() return ns.DB and ns.DB() end,
	report = ns.report,
	accent = { 0.58, 0.26, 0.9 }, -- the soulstone bar purple
	skin = SkinAll,
})
