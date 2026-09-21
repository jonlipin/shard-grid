-- ShardGrid: a bag-window style grid of Soul Shards.
--   * With a soul bag equipped, every soul bag slot is a cell: filled = shard, dim = free slot.
--   * Shards sitting in normal bags are appended as "overflow" cells in a different color.
--   * Grid width (columns) is set with the drag grip, the config window or "/shards width N".
--   * Optional auto-delete of overflow shards beyond a configurable allowance.
-- Anything that can't be verified offline is pcall-guarded and reported by "/shards debug".

local ADDON, ns = ...

local SHARD_ID = 6265
local SHARD_ICON = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02"
local SOUL_BAG_FAMILY = 4 -- bag family bit for Soul Bags
local MAX_BAG = NUM_BAG_SLOTS or 4
local MIN_COLS, MAX_COLS = 1, 24
local KEEP_MAX = 40 -- top of the "extra shards to keep" slider

local GAP = 2
-- The metal border is built from fixed-size corner pieces; below this size they overlap and
-- the frame "breaks". Small grids shrink the whole panel (fit < 1) and size the cells up to
-- compensate, so slots stay the size you asked for while the border stays intact.
local MIN_W, MIN_H, MIN_FIT = 156, 110, 0.5
-- Content insets inside the panel art (title bar on top).
local INSET = { left = 10, right = 8, top = 27, bottom = 9 }

local COLOR = {
	shard    = { 0.72, 0.35, 1.00 }, -- shard inside a soul bag
	overflow = { 1.00, 0.38, 0.10 }, -- shard outside the soul bag
}

local DEFAULTS = {
	cols = 7,
	size = 30,
	scale = 1,
	locked = false,
	shown = true,
	autoDelete = false,
	keepExtra = KEEP_MAX, -- overflow shards allowed beyond soul bag capacity (see SetAutoDelete)
	onlyWithBag = false, -- pause auto-delete while no soul bag is equipped
	announce = true,
	alertEnabled = true,
	alertThreshold = 5, -- alert while total shards < this
	alertSize = 48,
	alertSound = true,
	alertSoundChoice = 1,
	minimapShown = true,
	minimapAngle = 215, -- degrees around the minimap
}

-- Alert sounds: looked up by SOUNDKIT name first, numeric id as fallback. Picked in the config.
local SOUND_CHOICES = {
	{ "Mystic chime",   "TUTORIAL_POPUP",         7355 },
	{ "Gem clink",      "PUT_DOWN_GEMS",          1221 },
	{ "Soft bells",     "ALARM_CLOCK_WARNING_3",  12889 },
	{ "Whisper toast",  "UI_BNET_TOAST",          18019 },
	{ "Quest chime",    "IG_QUEST_LIST_COMPLETE", 878 },
	{ "Auction gong",   "AUCTION_WINDOW_OPEN",    5274 },
	{ "Map ping",       "MAP_PING",               3175 },
	{ "Raid warning",   "RAID_WARNING",           8959 },
}

local db
local report = {}
local lastStats
local Refresh -- forward

local atan2 = math.atan2 or math.atan
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffb45cffShardGrid|r: " .. tostring(msg))
end

-- ------------------------------------------------------------------
-- Bag API (C_Container on this client, globals as fallback)
-- ------------------------------------------------------------------
local CC = C_Container or {}
local GetNumSlots = CC.GetContainerNumSlots or GetContainerNumSlots
local GetNumFreeSlots = CC.GetContainerNumFreeSlots or GetContainerNumFreeSlots
local GetSlotItemID = CC.GetContainerItemID or GetContainerItemID
local PickupSlot = CC.PickupContainerItem or PickupContainerItem
local BagToInventoryID = CC.ContainerIDToInventoryID or ContainerIDToInventoryID
local ItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

-- Returns stackCount, isLocked
local function GetSlotInfo(bag, slot)
	if CC.GetContainerItemInfo then
		local info = CC.GetContainerItemInfo(bag, slot)
		if info then return info.stackCount or 1, info.isLocked end
	elseif GetContainerItemInfo then
		local _, count, locked = GetContainerItemInfo(bag, slot)
		return count or 1, locked
	end
	return 1, false
end

local function IsSoulBag(bag)
	if bag == 0 then return false end
	local _, family = GetNumFreeSlots(bag)
	if family and family > 0 and bit.band(family, SOUL_BAG_FAMILY) ~= 0 then
		return true
	end
	-- Fallback: Container class (1), Soul Bag subclass (1).
	if BagToInventoryID and ItemInfoInstant then
		local ok, invID = pcall(BagToInventoryID, bag)
		local itemID = ok and invID and GetInventoryItemID("player", invID)
		if itemID then
			local _, _, _, _, _, classID, subID = ItemInfoInstant(itemID)
			return classID == 1 and subID == 1
		end
	end
	return false
end

-- Returns a list of cells { kind = "shard"|"empty"|"overflow", count = n } plus totals.
local function Scan()
	local cells, overflow = {}, {}
	local stats = { soulSlots = 0, inSoul = 0, outside = 0, free = 0, hasSoulBag = false }
	for bag = 0, MAX_BAG do
		local slots = GetNumSlots(bag) or 0
		if slots > 0 then
			local soul = IsSoulBag(bag)
			if soul then
				stats.hasSoulBag = true
				stats.soulSlots = stats.soulSlots + slots
			end
			for slot = 1, slots do
				local id = GetSlotItemID(bag, slot)
				if soul then
					if id then
						local n = GetSlotInfo(bag, slot)
						stats.inSoul = stats.inSoul + n
						cells[#cells + 1] = { kind = "shard", count = n }
					else
						stats.free = stats.free + 1
						cells[#cells + 1] = { kind = "empty" }
					end
				elseif id == SHARD_ID then
					local n = GetSlotInfo(bag, slot)
					stats.outside = stats.outside + n
					overflow[#overflow + 1] = { kind = "overflow", count = n }
				end
			end
		end
	end
	-- Without a soul bag nothing is "overflow": loose shards are just shards.
	for _, c in ipairs(overflow) do
		if not stats.hasSoulBag then c.kind = "shard" end
		cells[#cells + 1] = c
	end
	return cells, stats
end
ns.Scan = Scan

-- ------------------------------------------------------------------
-- Auto-delete
-- ------------------------------------------------------------------
-- DeleteCursorItem() only works while the game is handling a real key press or mouse click
-- (verified in-game: deletes fired from bag events are blocked, deletes fired from a click
-- work). So bag events only *queue* the work; the delete itself runs on the player's next
-- key press (a pass-through keyboard listener) or click on the grid / alert / delete button.
local deleteBlocked = false -- the client refused even a key-press driven delete
local manualRun = false     -- "Delete extras now" was clicked
local lastAttemptTotal, stalledAttempts = nil, 0 -- (kept for the options code that resets them)
local pendingExcess = 0     -- shards queued for deletion on the next hardware event
local awaitingUpdate = false -- deletes were issued; wait for the bags to catch up before more
local inHardwarePass = false
local announceFrom          -- shard total before the last delete pass

-- While auto-delete is off the allowance is parked at its maximum, so ticking the box can
-- never wipe your shards: you turn it on first, then bring the slider down on purpose.
local function SetAutoDelete(on)
	db.autoDelete = on and true or false
	deleteBlocked, stalledAttempts, lastAttemptTotal = false, 0, nil
	if on then
		local outside = lastStats and lastStats.outside or 0
		db.keepExtra = math.max(db.keepExtra or KEEP_MAX, math.min(outside, KEEP_MAX))
	else
		db.keepExtra = KEEP_MAX
		pendingExcess = 0
	end
	-- keep the game's options page in step with the value we just changed
	local st = ns.native and ns.native.keepExtra
	if st and st.SetValue then pcall(st.SetValue, st, db.keepExtra) end
	Refresh()
	if ns.SyncConfig then ns.SyncConfig() end
end

-- How many shards are over the allowance (only ever counts shards outside the soul bag).
local function Excess(stats)
	if db.onlyWithBag and not stats.hasSoulBag then return 0 end
	local total = stats.inSoul + stats.outside
	local excess = total - (stats.soulSlots + db.keepExtra)
	return math.max(0, math.min(excess, stats.outside))
end
ns.Excess = Excess

-- Deletes up to "excess" overflow shards (last bag slot first). Returns how many were issued.
local function DeleteShards(excess)
	local issued = 0
	for bag = MAX_BAG, 0, -1 do
		local slots = GetNumSlots(bag) or 0
		if slots > 0 and not IsSoulBag(bag) then
			for slot = slots, 1, -1 do
				if issued >= excess then return issued end
				if GetSlotItemID(bag, slot) == SHARD_ID then
					local count, locked = GetSlotInfo(bag, slot)
					if not locked and count <= excess - issued then
						if GetCursorInfo() then return issued end -- never touch what the player is holding
						PickupSlot(bag, slot)
						local kind, id = GetCursorInfo()
						if kind == "item" and id == SHARD_ID then
							DeleteCursorItem()
							if GetCursorInfo() then -- refused: put it back and stop
								ClearCursor()
								return issued
							end
							issued = issued + count
						else
							ClearCursor()
							return issued
						end
					end
				end
			end
		end
	end
	return issued
end

-- Bag events land here: work out what is owed, announce what actually went.
local function RunAutoDelete(stats)
	local total = stats.inSoul + stats.outside
	if announceFrom then
		if total < announceFrom then
			if db.announce then
				local n = announceFrom - total
				Print(("Deleted %d extra Soul Shard%s (limit %d)."):format(n, n == 1 and "" or "s", stats.soulSlots + db.keepExtra))
			end
			announceFrom = nil
		end
	end
	if (db.autoDelete or manualRun) and not deleteBlocked then
		pendingExcess = Excess(stats)
	else
		pendingExcess = 0
	end
	if pendingExcess == 0 then manualRun = false end
end

-- Call ONLY from a hardware event handler (OnKeyDown / OnClick / OnMouseUp).
function ns.HardwareDeletePass()
	if pendingExcess <= 0 or awaitingUpdate or deleteBlocked or not lastStats then return end
	-- Re-check against a fresh scan so a stale queue can never over-delete.
	local _, stats = Scan()
	local excess = Excess(stats)
	if excess <= 0 then pendingExcess = 0 return end

	inHardwarePass = true
	local ok, issued = pcall(DeleteShards, excess)
	inHardwarePass = false
	report["delete"] = ok and (issued .. " issued on hardware event") or ("error: " .. tostring(issued))
	if ok and issued > 0 then
		announceFrom = announceFrom or (stats.inSoul + stats.outside)
		awaitingUpdate = true
		pendingExcess = 0
		-- Normally BAG_UPDATE_DELAYED clears this; the timer covers a lost event.
		if C_Timer and C_Timer.After then
			C_Timer.After(1.5, function()
				if awaitingUpdate then awaitingUpdate = false Refresh() end
			end)
		end
	end
end

-- Pass-through keyboard listener: sees every key press without consuming it.
report["key listener"] = pcall(function()
	local keys = CreateFrame("Frame", "ShardGridKeyListener", UIParent)
	keys:SetSize(1, 1)
	keys:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	keys:EnableKeyboard(true)
	keys:SetPropagateKeyboardInput(true)
	keys:SetScript("OnKeyDown", function() if pendingExcess > 0 then ns.HardwareDeletePass() end end)
end) and "ok" or "unavailable (deletes happen when you click the grid)"

-- ------------------------------------------------------------------
-- Panel construction (bag-window look)
-- ------------------------------------------------------------------
local function HasAtlas(atlas)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
end

local PANEL_TEMPLATES = {
	{ "DefaultPanelFlatTemplate", function(f) return f.NineSlice ~= nil end },
	{ "DefaultPanelTemplate", function(f) return f.NineSlice ~= nil end },
	{ "ButtonFrameTemplate", function(f) return f.NineSlice ~= nil or f.Inset ~= nil end },
	{ "BasicFrameTemplate" },
}

-- Creates a titled panel using the same art as the bag window, falling back gracefully.
local function CreatePanel(name, wantClose)
	local f, used
	for _, c in ipairs(PANEL_TEMPLATES) do
		local ok, made = pcall(CreateFrame, "Frame", name, UIParent, c[1])
		if ok and made and (not c[2] or c[2](made)) then
			f, used = made, c[1]
			break
		end
		if ok and made then made:Hide() end
	end
	if not f then
		local ok, made = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
		f = (ok and made) or CreateFrame("Frame", name, UIParent)
		used = "backdrop"
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 14,
				insets = { left = 3, right = 3, top = 3, bottom = 3 },
			})
			f:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
		end
	end
	report["panel:" .. name] = used

	if used == "ButtonFrameTemplate" then
		if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
		if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
		if f.Inset then f.Inset:Hide() end
	end

	-- Title
	local title = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
	if not title then
		title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -6)
	end
	f.sgTitle = title

	-- Close button: keep / add one only where wanted.
	local close = f.CloseButton
	if wantClose and not close then
		local ok, b = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
		if ok and b then
			b:SetPoint("TOPRIGHT", 1, 1)
			close = b
		end
	elseif not wantClose and close then
		close:Hide()
	end

	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	return f
end

-- ------------------------------------------------------------------
-- Main frame
-- ------------------------------------------------------------------
local frame = CreatePanel("ShardGridFrame", false)
frame:SetFrameStrata("MEDIUM")
frame:Hide()

local emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
emptyText:SetPoint("TOPLEFT", INSET.left, -INSET.top - 4)
emptyText:SetText("No shards")

local fit = 1 -- extra shrink applied on top of db.scale, see MIN_W

-- Position is stored in UIParent units so it survives scale / fit changes.
local function SavePosition()
	local left, top = frame:GetLeft(), frame:GetTop()
	if left and top then
		local sc = frame:GetScale() or 1
		db.x, db.y = left * sc, top * sc
	end
end

local function RestorePosition()
	frame:ClearAllPoints()
	if db.x and db.y then
		-- TOPLEFT anchor so changing the width grows the grid to the right / downward.
		local sc = frame:GetScale() or 1
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", db.x / sc, db.y / sc)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
	end
end

-- The top-left corner stays put: position is scale independent, Refresh re-applies it.
local function SetGridScale(scale)
	db.scale = math.max(0.5, math.min(2, scale))
end

local moving = false

frame:SetScript("OnDragStart", function(self)
	if not db.locked then moving = true self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	moving = false
	SavePosition()
	RestorePosition()
end)

-- ------------------------------------------------------------------
-- Low-shard alert: a separate movable icon that pulses while total shards < threshold.
-- ------------------------------------------------------------------
local alert = CreateFrame("Frame", "ShardGridAlert", UIParent)
alert:SetFrameStrata("MEDIUM")
alert:SetMovable(true)
alert:SetClampedToScreen(true)
alert:EnableMouse(true)
alert:RegisterForDrag("LeftButton")
alert:Hide()

alert.bg = alert:CreateTexture(nil, "BACKGROUND")
alert.bg:SetAllPoints()
alert.bg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")

alert.icon = alert:CreateTexture(nil, "ARTWORK")
alert.icon:SetPoint("TOPLEFT", 2, -2)
alert.icon:SetPoint("BOTTOMRIGHT", -2, 2)
alert.icon:SetTexture(SHARD_ICON)
alert.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
alert.icon:SetDesaturated(true)
alert.icon:SetVertexColor(1, 0.35, 0.35)

alert.ring = alert:CreateTexture(nil, "OVERLAY")
alert.ring:SetAllPoints()
alert.ring:SetTexture("Interface\\Common\\WhiteIconFrame")
alert.ring:SetVertexColor(1, 0.1, 0.1)

alert.glow = alert:CreateTexture(nil, "OVERLAY", nil, 1)
alert.glow:SetPoint("CENTER")
alert.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
alert.glow:SetBlendMode("ADD")
alert.glow:SetVertexColor(1, 0.1, 0.1)

alert.count = alert:CreateFontString(nil, "OVERLAY", "NumberFontNormalHuge")
alert.count:SetPoint("CENTER", 0, 0)
alert.count:SetTextColor(1, 1, 1)

alert.label = alert:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
alert.label:SetPoint("TOP", alert, "BOTTOM", 0, -2)
alert.label:SetTextColor(1, 0.25, 0.25)
alert.label:SetText("Low shards")

-- Pulse the glow; if the animation API differs here the icon simply stays lit.
report["alert pulse"] = pcall(function()
	local ag = alert.glow:CreateAnimationGroup()
	ag:SetLooping("BOUNCE")
	local a = ag:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.25)
	a:SetDuration(0.6)
	alert.pulse = ag
end) and "ok" or "unavailable"

local function RestoreAlertPosition()
	alert:ClearAllPoints()
	if db.alertX and db.alertY then
		alert:SetPoint("CENTER", UIParent, "BOTTOMLEFT", db.alertX, db.alertY)
	else
		alert:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	end
end

alert:SetScript("OnDragStart", function(self)
	if not db.locked then self:StartMoving() end
end)
alert:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local x, y = self:GetCenter()
	if x and y then db.alertX, db.alertY = x, y end
	RestoreAlertPosition()
end)
alert:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Low on Soul Shards", 1, 0.25, 0.25)
	GameTooltip:AddLine(("Alerting below %d. Drag to move; /shards for options."):format(db.alertThreshold), 0.7, 0.7, 0.7, true)
	GameTooltip:Show()
end)
alert:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Returns the display name and whether the client said it would play.
function ns.PlayAlertSound()
	local id, name = db.alertSoundCustom, "Custom"
	if not id then
		local c = SOUND_CHOICES[db.alertSoundChoice] or SOUND_CHOICES[1]
		id, name = (SOUNDKIT and SOUNDKIT[c[2]]) or c[3], c[1]
	end
	local ok, willPlay = pcall(PlaySound, id, "SFX")
	report["alert sound"] = ("%s (kit %s) -> %s"):format(name, tostring(id), tostring(ok and willPlay))
	return name, ok and willPlay
end

local alertPreview = false -- config "show for positioning"
local wasLow = false

local function UpdateAlert(stats)
	local total = stats.inSoul + stats.outside
	if total > 0 then db.seenShards = true end
	local _, class = UnitClass("player")
	local relevant = class == "WARLOCK" or stats.hasSoulBag or db.seenShards
	local low = db.alertEnabled and relevant and total < db.alertThreshold

	if low and not wasLow and db.alertSound then
		ns.PlayAlertSound()
	end
	wasLow = low and true or false

	if not (low or alertPreview) then
		if alert.pulse then alert.pulse:Stop() end
		alert:Hide()
		return
	end
	local size = db.alertSize
	alert:SetSize(size, size)
	alert.glow:SetSize(size * 1.75, size * 1.75)
	alert.count:SetText(total)
	alert.label:SetText(low and "Low shards" or "Alert preview")
	alert:Show()
	if alert.pulse and not alert.pulse:IsPlaying() then alert.pulse:Play() end
end

-- ------------------------------------------------------------------
-- Cells
-- ------------------------------------------------------------------
local cells = {}
local slotAtlas -- resolved once

local function StyleSlotBackground(tex)
	if slotAtlas == nil then
		slotAtlas = false
		for _, atlas in ipairs({ "bags-item-slot64", "bags-item-slot" }) do
			if HasAtlas(atlas) then slotAtlas = atlas break end
		end
		report["slot atlas"] = slotAtlas or "none (using UI-Backpack-EmptySlot)"
	end
	if slotAtlas then
		tex:SetAtlas(slotAtlas)
	else
		tex:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
	end
end

local function GetCell(i)
	local cell = cells[i]
	if cell then return cell end
	cell = CreateFrame("Frame", nil, frame)

	cell.bg = cell:CreateTexture(nil, "BACKGROUND")
	cell.bg:SetAllPoints()
	StyleSlotBackground(cell.bg)

	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", 1, -1)
	cell.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	cell.icon:SetTexture(SHARD_ICON)
	cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- Same colored ring the bags use for item quality.
	cell.border = cell:CreateTexture(nil, "OVERLAY")
	cell.border:SetAllPoints()
	cell.border:SetTexture("Interface\\Common\\WhiteIconFrame")

	cell.count = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	cell.count:SetPoint("BOTTOMRIGHT", -1, 2)

	cells[i] = cell
	return cell
end

local function PaintCell(cell, data)
	if data.kind == "empty" then
		cell.icon:Hide()
		cell.border:Hide()
		cell.count:Hide()
		return
	end
	local c = COLOR[data.kind]
	cell.icon:Show()
	if data.kind == "overflow" then
		cell.icon:SetDesaturated(true)
		cell.icon:SetVertexColor(c[1], c[2], c[3])
		cell.border:SetVertexColor(c[1], c[2], c[3])
		cell.border:Show()
	else
		cell.icon:SetDesaturated(false)
		cell.icon:SetVertexColor(1, 1, 1)
		cell.border:Hide() -- plain, exactly like the bag window
	end
	if data.count and data.count > 1 then
		cell.count:SetText(data.count)
		cell.count:Show()
	else
		cell.count:Hide()
	end
end

-- ------------------------------------------------------------------
-- Layout / refresh
-- ------------------------------------------------------------------

local function ShouldShow(stats, n)
	if not db.shown then return false end
	local _, class = UnitClass("player")
	return class == "WARLOCK" or stats.hasSoulBag or n > 0
end

local titleFont -- { file, size, flags } captured once

function Refresh()
	if not db then return end
	local data, stats = Scan()
	lastStats = stats
	local n = #data

	RunAutoDelete(stats)
	UpdateAlert(stats)

	if not ShouldShow(stats, n) then
		frame:Hide()
		return
	end

	local cols = db.cols
	local rows = math.max(1, math.ceil(n / cols))
	local insetW, insetH = INSET.left + INSET.right, INSET.top + INSET.bottom
	local gridW = cols * db.size + (cols - 1) * GAP
	local gridH = rows * db.size + (rows - 1) * GAP

	-- Shrink the panel (not the slots) until the border art has the room it needs.
	fit = math.min(1, gridW / (MIN_W - insetW), gridH / (MIN_H - insetH))
	fit = math.max(MIN_FIT, fit)
	local size, gap = db.size / fit, GAP / fit

	for i = 1, n do
		local cell = GetCell(i)
		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)
		cell:SetSize(size, size)
		cell:ClearAllPoints()
		cell:SetPoint("TOPLEFT", frame, "TOPLEFT", INSET.left + col * (size + gap), -(INSET.top + row * (size + gap)))
		PaintCell(cell, data[i])
		cell:Show()
	end
	for i = n + 1, #cells do cells[i]:Hide() end
	emptyText:SetShown(n == 0)

	local width = math.max(MIN_W, insetW + gridW / fit)
	local height = math.max(MIN_H, insetH + gridH / fit)
	frame:SetSize(width, height)
	frame:SetScale(db.scale * fit)
	if not moving then RestorePosition() end

	-- Keep the title bar widgets a readable size when the panel is shrunk.
	local title = frame.sgTitle
	if title.GetFont and title.SetFont then
		if not titleFont then titleFont = { title:GetFont() } end
		if titleFont[1] and titleFont[2] then
			title:SetFont(titleFont[1], math.min(titleFont[2] / fit, titleFont[2] * 1.5), titleFont[3])
		end
	end
	if frame.sgCog then frame.sgCog:SetSize(math.min(16 / fit, 22), math.min(16 / fit, 22)) end
	if frame.sgGrip then frame.sgGrip:SetSize(math.min(14 / fit, 20), math.min(14 / fit, 20)) end

	local counts
	if stats.hasSoulBag then
		counts = stats.inSoul .. "/" .. stats.soulSlots
		if stats.outside > 0 then
			counts = counts .. " |cffff6119+" .. stats.outside .. "|r"
		end
	else
		counts = tostring(stats.outside)
	end
	title:SetText(width * fit >= 170 and ("Soul Shards  |cffffffff" .. counts .. "|r") or ("|cffffffff" .. counts .. "|r"))

	frame:Show()
end
ns.Refresh = Refresh

-- ------------------------------------------------------------------
-- Tooltip
-- ------------------------------------------------------------------
frame:SetScript("OnEnter", function(self)
	if not lastStats then return end
	local s = lastStats
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	GameTooltip:SetText("Soul Shards", 1, 1, 1)
	if s.hasSoulBag then
		GameTooltip:AddDoubleLine("In soul bag", s.inSoul .. " / " .. s.soulSlots, 0.72, 0.35, 1, 1, 1, 1)
		GameTooltip:AddDoubleLine("Free soul bag slots", s.free, 0.7, 0.7, 0.7, 1, 1, 1)
		GameTooltip:AddDoubleLine("Overflow (other bags)", s.outside, 1, 0.38, 0.1, 1, 1, 1)
	else
		GameTooltip:AddDoubleLine("In bags", s.outside, 0.72, 0.35, 1, 1, 1, 1)
		GameTooltip:AddLine("No soul bag equipped.", 0.7, 0.7, 0.7)
	end
	GameTooltip:AddDoubleLine("Total", s.inSoul + s.outside, 1, 0.82, 0, 1, 1, 1)
	if db.autoDelete then
		if db.onlyWithBag and not s.hasSoulBag then
			GameTooltip:AddLine("Auto-delete paused: no soul bag equipped.", 0.7, 0.7, 0.7)
		else
			GameTooltip:AddLine(("Auto-delete on: limit %d (bag %d + %d extra)."):format(s.soulSlots + db.keepExtra, s.soulSlots, db.keepExtra), 1, 0.38, 0.1)
			if pendingExcess > 0 then
				GameTooltip:AddLine(("%d over the limit - goes on your next key press or click here."):format(pendingExcess), 1, 0.82, 0)
			end
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Right-click or use the cog for options.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end)
frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ------------------------------------------------------------------
-- Width grip: drag the bottom-right corner, columns snap to the cursor.
-- ------------------------------------------------------------------
local grip = CreateFrame("Button", nil, frame)
grip:SetSize(14, 14)
grip:SetPoint("BOTTOMRIGHT", -3, 3)
frame.sgGrip = grip
grip:SetFrameLevel(frame:GetFrameLevel() + 10)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

local function SetCols(cols)
	cols = math.max(MIN_COLS, math.min(MAX_COLS, math.floor(cols + 0.5)))
	if cols ~= db.cols then
		db.cols = cols
		Refresh()
		if ns.SyncConfig then ns.SyncConfig() end
	end
end

local function GripOnUpdate()
	local left = frame:GetLeft()
	if not left then return end
	-- Work in db.scale units (the panel itself may be shrunk further by fit).
	local x = GetCursorPosition() / (UIParent:GetEffectiveScale() * db.scale)
	SetCols((x - left * fit - (INSET.left + INSET.right) * fit + GAP) / (db.size + GAP))
end

grip:SetScript("OnMouseDown", function(self)
	-- Pin the top-left corner so the grid grows away from it.
	SavePosition()
	RestorePosition()
	self:SetScript("OnUpdate", GripOnUpdate)
end)
grip:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
grip:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Drag to change grid width")
	GameTooltip:Show()
end)
grip:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function ApplyLock()
	grip:SetShown(not db.locked)
end

-- ------------------------------------------------------------------
-- Config window
-- ------------------------------------------------------------------
local config
local syncers = {}

function ns.SyncConfig()
	if not config or not config:IsShown() then return end
	for _, fn in ipairs(syncers) do fn() end
end

local function AddHeader(parent, y, text)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", 16, y)
	fs:SetText(text)
	return fs
end

-- label ................ value
-- [=========o==============]
local SLIDER_TEMPLATES = { "MinimalSliderTemplate", "UISliderTemplate", "OptionsSliderTemplate" }

local function CreateSlider(parent)
	for _, tmpl in ipairs(SLIDER_TEMPLATES) do
		local ok, sl = pcall(CreateFrame, "Slider", nil, parent, tmpl)
		if ok and sl and sl.SetMinMaxValues then
			report["slider"] = tmpl
			-- OptionsSliderTemplate carries its own captions; we draw ours.
			for _, key in ipairs({ "Low", "High", "Text" }) do
				if type(sl[key]) == "table" and sl[key].SetText then sl[key]:SetText("") end
			end
			return sl
		end
	end
	-- Bare slider with classic art.
	report["slider"] = "bare"
	local sl = CreateFrame("Slider", nil, parent)
	sl:SetOrientation("HORIZONTAL")
	local bar = sl:CreateTexture(nil, "BACKGROUND")
	bar:SetPoint("LEFT")
	bar:SetPoint("RIGHT")
	bar:SetHeight(6)
	bar:SetColorTexture(0, 0, 0, 0.6)
	sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	return sl
end

local function AddSlider(parent, y, label, opts)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("TOPLEFT", 22, y)
	fs:SetText(label)

	local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	value:SetPoint("TOPRIGHT", -20, y)

	local sl = CreateSlider(parent)
	sl:SetPoint("TOPLEFT", 24, y - 16)
	sl:SetPoint("TOPRIGHT", -22, y - 16)
	sl:SetHeight(16)
	sl:SetMinMaxValues(opts.min, opts.max)
	sl:SetValueStep(opts.step)
	if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end

	local syncing = false
	local function Show(v) value:SetText(opts.format and opts.format(v) or tostring(v)) end
	local function Sync()
		syncing = true
		sl:SetValue(opts.get())
		syncing = false
		Show(opts.get())
	end
	sl:SetScript("OnValueChanged", function(_, v)
		if syncing then return end
		v = math.floor(v / opts.step + 0.5) * opts.step
		v = math.max(opts.min, math.min(opts.max, v))
		if v ~= opts.get() then opts.set(v) end
		Show(v)
	end)
	-- Mouse wheel nudges by one step.
	sl:EnableMouseWheel(true)
	sl:SetScript("OnMouseWheel", function(self, delta)
		self:SetValue(math.max(opts.min, math.min(opts.max, opts.get() + delta * opts.step)))
	end)
	syncers[#syncers + 1] = Sync
	return sl
end

local function AddCheck(parent, y, label, get, set, tip)
	local cb
	for _, tmpl in ipairs({ "UICheckButtonTemplate", "ChatConfigCheckButtonTemplate" }) do
		local ok, made = pcall(CreateFrame, "CheckButton", nil, parent, tmpl)
		if ok and made then cb = made break end
	end
	if not cb then
		cb = CreateFrame("CheckButton", nil, parent)
		cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
		cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	end
	cb:SetSize(24, 24)
	cb:SetPoint("TOPLEFT", 18, y)
	-- Own label: the templates disagree about where theirs lives.
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	if tip then
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			GameTooltip:AddLine(tip, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	syncers[#syncers + 1] = function() cb:SetChecked(get()) end
	return cb
end

local function BuildConfig()
	config = CreatePanel("ShardGridConfig", true)
	config:SetSize(320, 694)
	config:SetPoint("CENTER")
	config:SetFrameStrata("DIALOG")
	config.sgTitle:SetText("Shard Grid")
	config:SetScript("OnDragStart", config.StartMoving)
	config:SetScript("OnDragStop", config.StopMovingOrSizing)
	config:SetScript("OnShow", function() ns.SyncConfig() end)
	config:SetScript("OnHide", function()
		if alertPreview then alertPreview = false Refresh() end
	end)
	config:Hide()
	tinsert(UISpecialFrames, "ShardGridConfig")

	local y = -34
	AddHeader(config, y, "Display")
	y = y - 22
	AddSlider(config, y, "Grid width (columns)", {
		min = MIN_COLS, max = MAX_COLS, step = 1,
		get = function() return db.cols end,
		set = function(v) db.cols = v Refresh() end,
	})
	y = y - 40
	AddSlider(config, y, "Slot size", {
		min = 12, max = 64, step = 2,
		get = function() return db.size end,
		set = function(v) db.size = v Refresh() end,
	})
	y = y - 40
	AddSlider(config, y, "Scale", {
		min = 50, max = 200, step = 5,
		get = function() return math.floor(db.scale * 100 + 0.5) end,
		set = function(v) SetGridScale(v / 100) Refresh() end,
		format = function(v) return v .. "%" end,
	})
	y = y - 40
	AddCheck(config, y, "Lock position",
		function() return db.locked end,
		function(v) db.locked = v ApplyLock() end,
		"Stops the grid from being dragged and hides the width grip.")
	y = y - 26
	AddCheck(config, y, "Show grid",
		function() return db.shown end,
		function(v) db.shown = v Refresh() end)

	y = y - 26
	AddCheck(config, y, "Show minimap button",
		function() return db.minimapShown end,
		function(v) db.minimapShown = v ns.UpdateMinimapButton() end)

	y = y - 36
	AddHeader(config, y, "Overflow shards")
	y = y - 22
	AddCheck(config, y, "Auto-delete extra shards",
		function() return db.autoDelete end,
		function(v) SetAutoDelete(v) end,
		"Destroys Soul Shards sitting in your normal bags once you hold more than your soul bag capacity plus the allowance below. Shards inside the soul bag are never touched.")
	y = y - 28
	AddSlider(config, y, "Extra shards to keep", {
		min = 0, max = KEEP_MAX, step = 1,
		get = function() return db.keepExtra end,
		set = function(v) db.keepExtra = v Refresh() end,
	})
	y = y - 40
	AddCheck(config, y, "Pause while no soul bag is equipped",
		function() return db.onlyWithBag end,
		function(v) db.onlyWithBag = v Refresh() end,
		"With no soul bag your capacity is 0, so \"extra shards to keep\" becomes your total shard limit. Tick this if you'd rather nothing is deleted while you have no soul bag (e.g. while swapping bags).")
	y = y - 26
	AddCheck(config, y, "Announce deletions in chat",
		function() return db.announce end,
		function(v) db.announce = v end)

	y = y - 36
	AddHeader(config, y, "Low shard alert")
	y = y - 22
	AddCheck(config, y, "Show alert icon when low",
		function() return db.alertEnabled end,
		function(v) db.alertEnabled = v Refresh() end,
		"A separate, movable icon that pulses while your total Soul Shards (soul bag + other bags) are below the threshold.")
	y = y - 28
	AddSlider(config, y, "Alert when below", {
		min = 1, max = 40, step = 1,
		get = function() return db.alertThreshold end,
		set = function(v) db.alertThreshold = v Refresh() end,
	})
	y = y - 40
	AddSlider(config, y, "Alert icon size", {
		min = 24, max = 128, step = 4,
		get = function() return db.alertSize end,
		set = function(v) db.alertSize = v Refresh() end,
	})
	y = y - 40
	AddCheck(config, y, "Play a sound when shards run low",
		function() return db.alertSound end,
		function(v) db.alertSound = v end)
	y = y - 28
	local soundBtn = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
	soundBtn:SetSize(200, 22)
	soundBtn:SetPoint("TOPLEFT", 46, y)
	local function SoundLabel()
		local c = SOUND_CHOICES[db.alertSoundChoice] or SOUND_CHOICES[1]
		soundBtn:SetText("Sound: " .. (db.alertSoundCustom and ("custom " .. db.alertSoundCustom) or c[1]))
	end
	soundBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	soundBtn:SetScript("OnClick", function(_, button)
		if button ~= "RightButton" then -- left: next sound, right: replay current
			db.alertSoundCustom = nil
			db.alertSoundChoice = (db.alertSoundChoice or 1) % #SOUND_CHOICES + 1
		end
		SoundLabel()
		local name, played = ns.PlayAlertSound()
		if not played then Print(name .. " isn't available on this client (or sound effects are muted) - click again for the next one.") end
	end)
	soundBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Alert sound", 1, 1, 1)
		GameTooltip:AddLine("Left-click: try the next sound. Right-click: replay. Any sound kit id also works: /shards sound 12345", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	soundBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	syncers[#syncers + 1] = SoundLabel
	y = y - 26
	AddCheck(config, y, "Show alert now (to position it)",
		function() return alertPreview end,
		function(v) alertPreview = v Refresh() end,
		"Keeps the alert icon visible so you can drag it where you want. Turns itself off when this window closes.")

	local status = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", 22, 44)
	status:SetPoint("BOTTOMRIGHT", -18, 44)
	status:SetJustifyH("LEFT")
	syncers[#syncers + 1] = function()
		local s = lastStats
		if not s then status:SetText("") return end
		local cap = s.soulSlots + db.keepExtra
		local txt = ("Limit: %d (bag %d + %d extra). Over limit now: %d."):format(cap, s.soulSlots, db.keepExtra, Excess(s))
		if db.onlyWithBag and not s.hasSoulBag then txt = "Paused: no soul bag equipped - nothing will be deleted." end
		if deleteBlocked then txt = "|cffff4040Automatic deletion is blocked by the client.|r" end
		status:SetText(txt)
	end

	local now = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
	now:SetSize(150, 22)
	now:SetPoint("BOTTOMLEFT", 18, 14)
	now:SetText("Delete extras now")
	now:SetScript("OnClick", function()
		if not lastStats or Excess(lastStats) <= 0 then
			Print("Nothing over the limit.")
			return
		end
		deleteBlocked, stalledAttempts, lastAttemptTotal = false, 0, nil
		manualRun = true
		Refresh()
		ns.HardwareDeletePass()
	end)
end

-- ------------------------------------------------------------------
-- Native options: a real page in the game's Options > AddOns list, built from Blizzard's own
-- settings controls. The hand-built window above stays as the fallback ("/shards oldmenu").
-- ------------------------------------------------------------------
local nativeCategory

local function BuildNativeSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
		and Settings.RegisterAddOnCategory and Settings.CreateSliderOptions) then
		error("Settings API not available")
	end
	local category, layout = Settings.RegisterVerticalLayoutCategory("Shard Grid")
	local VT = Settings.VarType or {}
	local T_BOOL, T_NUM = VT.Boolean or "boolean", VT.Number or "number"
	local CreateCheckbox = Settings.CreateCheckbox or Settings.CreateCheckBox
	local CreateDropdown = Settings.CreateDropdown or Settings.CreateDropDown

	ns.native = ns.native or {}
	local function RegisterProxy(key, vtype, name, default, get, set)
		local var = "ShardGrid_" .. key
		-- 11.x signature
		local ok, setting = pcall(Settings.RegisterProxySetting, category, var, vtype, name, default, get, set)
		if ok and type(setting) == "table" and setting.GetValue then
			local ok2, v = pcall(setting.GetValue, setting)
			if ok2 and v == get() then return setting end
		end
		-- 10.x signature carried a variable table before the type
		ok, setting = pcall(Settings.RegisterProxySetting, category, var .. "_", {}, vtype, name, default, get, set)
		if ok and type(setting) == "table" then
			report["settings signature"] = "10.x"
			return setting
		end
		error("RegisterProxySetting failed for " .. key .. ": " .. tostring(setting))
	end

	local function Proxy(key, ...)
		local setting = RegisterProxy(key, ...)
		ns.native[key] = setting
		return setting
	end

	local function Header(text)
		if CreateSettingsListSectionHeaderInitializer then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
		end
	end
	local function Check(key, name, tip, get, set)
		CreateCheckbox(category, Proxy(key, T_BOOL, name, DEFAULTS[key] or false, get, set), tip)
	end
	local function Slider(key, name, tip, min, max, step, get, set, fmt)
		local opts = Settings.CreateSliderOptions(min, max, step)
		if opts.SetLabelFormatter and MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
			opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, fmt)
		end
		Settings.CreateSlider(category, Proxy(key, T_NUM, name, DEFAULTS[key] or min, get, set), opts, tip)
	end
	local function Button(name, text, tip, onClick)
		if CreateSettingsButtonInitializer then
			layout:AddInitializer(CreateSettingsButtonInitializer(name, text, onClick, tip, true))
		end
	end

	Header("Display")
	Slider("cols", "Grid width (columns)", "How many slots wide the shard grid is. You can also drag the grip in the grid's corner.",
		MIN_COLS, MAX_COLS, 1,
		function() return db.cols end,
		function(v) db.cols = v Refresh() end)
	Slider("size", "Slot size", "Size of each shard slot.",
		12, 64, 2,
		function() return db.size end,
		function(v) db.size = v Refresh() end)
	Slider("scalePct", "Scale", "Scales the whole shard grid.",
		50, 200, 5,
		function() return math.floor(db.scale * 100 + 0.5) end,
		function(v) SetGridScale(v / 100) Refresh() end,
		function(v) return math.floor(v + 0.5) .. "%" end)
	Check("shown", "Show grid", "Show the shard grid window.",
		function() return db.shown end,
		function(v) db.shown = v Refresh() end)
	Check("locked", "Lock position", "Stops the grid and the alert icon from being dragged, and hides the width grip.",
		function() return db.locked end,
		function(v) db.locked = v ApplyLock() end)
	Check("minimapShown", "Show minimap button", "Left-click opens these options, right-click shows or hides the grid.",
		function() return db.minimapShown end,
		function(v) db.minimapShown = v ns.UpdateMinimapButton() end)

	Header("Overflow shards")
	Check("autoDelete", "Auto-delete extra shards",
		"Destroys Soul Shards sitting in your normal bags once you hold more than your soul bag capacity plus the allowance below. Shards inside the soul bag are never touched.",
		function() return db.autoDelete end,
		function(v) SetAutoDelete(v) end)
	Slider("keepExtra", "Extra shards to keep", "How many shards you may hold beyond your soul bag capacity before extras are deleted. With no soul bag this is your total shard limit. Resets to the maximum whenever auto-delete is turned off.",
		0, KEEP_MAX, 1,
		function() return db.keepExtra end,
		function(v) db.keepExtra = v Refresh() end)
	Check("onlyWithBag", "Pause while no soul bag is equipped", "Tick this if you'd rather nothing is deleted while you have no soul bag (e.g. while swapping bags).",
		function() return db.onlyWithBag end,
		function(v) db.onlyWithBag = v Refresh() end)
	Check("announce", "Announce deletions in chat", "Print a line in chat each time a shard is deleted.",
		function() return db.announce end,
		function(v) db.announce = v end)
	Button("Over the limit right now", "Delete extras now", "Deletes shards over your limit once, even if auto-delete is off.", function()
		if not lastStats or Excess(lastStats) <= 0 then
			Print("Nothing over the limit.")
			return
		end
		deleteBlocked, stalledAttempts, lastAttemptTotal = false, 0, nil
		manualRun = true
		Refresh()
		ns.HardwareDeletePass()
	end)

	Header("Low shard alert")
	Check("alertEnabled", "Show alert icon when low", "A separate, movable icon that pulses while your total Soul Shards are below the threshold.",
		function() return db.alertEnabled end,
		function(v) db.alertEnabled = v Refresh() end)
	Slider("alertThreshold", "Alert when below", "The alert shows while you have fewer shards than this.",
		1, 40, 1,
		function() return db.alertThreshold end,
		function(v) db.alertThreshold = v Refresh() end)
	Slider("alertSize", "Alert icon size", "Size of the alert icon.",
		24, 128, 4,
		function() return db.alertSize end,
		function(v) db.alertSize = v Refresh() end)
	Check("alertSound", "Play a sound when shards run low", "Plays once each time you drop below the threshold.",
		function() return db.alertSound end,
		function(v) db.alertSound = v end)
	if CreateDropdown and Settings.CreateControlTextContainer then
		local soundSetting = Proxy("alertSoundChoice", T_NUM, "Alert sound", 1,
			function() return db.alertSoundChoice or 1 end,
			function(v)
				db.alertSoundChoice, db.alertSoundCustom = v, nil
				ns.PlayAlertSound()
			end)
		CreateDropdown(category, soundSetting, function()
			local container = Settings.CreateControlTextContainer()
			for i, c in ipairs(SOUND_CHOICES) do container:Add(i, c[1]) end
			return container:GetData()
		end, "Picking a sound plays it. Any sound kit id also works: /shards sound 12345")
	end
	Button("Alert sound", "Test sound", "Play the current alert sound.", function()
		local name, played = ns.PlayAlertSound()
		if not played then Print(name .. " isn't available on this client (or sound effects are muted).") end
	end)
	Check("alertPreview", "Show alert now (to position it)", "Keeps the alert icon visible so you can drag it where you want. Turns itself off when the options close.",
		function() return alertPreview end,
		function(v) alertPreview = v Refresh() end)

	Settings.RegisterAddOnCategory(category)
	if SettingsPanel and SettingsPanel.HookScript then
		SettingsPanel:HookScript("OnHide", function()
			if alertPreview then alertPreview = false Refresh() end
		end)
	end
	nativeCategory = category
end

function ns.SetupNativeSettings()
	if nativeCategory or report["native settings"] then return end
	local ok, err = pcall(BuildNativeSettings)
	report["native settings"] = ok and "ok" or ("failed: " .. tostring(err))
end

local function ToggleConfig()
	if nativeCategory and not db.oldMenu then
		if SettingsPanel and SettingsPanel:IsShown() then
			if HideUIPanel then HideUIPanel(SettingsPanel) else SettingsPanel:Hide() end
			return
		end
		local id = nativeCategory.GetID and nativeCategory:GetID() or nativeCategory.ID
		if pcall(Settings.OpenToCategory, id) and SettingsPanel and SettingsPanel:IsShown() then return end
		report["native open"] = "failed, using old menu"
	end
	if not config then BuildConfig() end
	config:SetShown(not config:IsShown())
end

-- Cog in the title bar + right-click on the grid.
local cog = CreateFrame("Button", nil, frame)
cog:SetSize(16, 16)
cog:SetPoint("TOPRIGHT", -5, -3)
frame.sgCog = cog
cog:SetFrameLevel(frame:GetFrameLevel() + 10)
cog:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
cog:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton", "ADD")
cog:SetScript("OnClick", ToggleConfig)
cog:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Shard Grid options")
	GameTooltip:Show()
end)
cog:SetScript("OnLeave", function() GameTooltip:Hide() end)

frame:SetScript("OnMouseUp", function(_, button)
	if button == "RightButton" then ToggleConfig() else ns.HardwareDeletePass() end
end)
alert:SetScript("OnMouseUp", function() ns.HardwareDeletePass() end)

-- ------------------------------------------------------------------
-- Minimap button: left-click options, right-click show/hide grid, drag to move around the rim.
-- ------------------------------------------------------------------
local mmButton

local function PlaceMinimapButton()
	if not mmButton then return end
	local angle = math.rad(db.minimapAngle or 215)
	local radius = (Minimap:GetWidth() or 140) / 2 + 6
	mmButton:ClearAllPoints()
	mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function ns.UpdateMinimapButton()
	if not Minimap then return end
	if not mmButton then
		if not db.minimapShown then return end
		mmButton = CreateFrame("Button", "ShardGridMinimapButton", Minimap)
		mmButton:SetSize(31, 31)
		mmButton:SetFrameStrata("MEDIUM")
		mmButton:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
		mmButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		mmButton:RegisterForDrag("LeftButton")
		mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

		local bg = mmButton:CreateTexture(nil, "BACKGROUND")
		bg:SetSize(20, 20)
		bg:SetPoint("TOPLEFT", 7, -5)
		bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

		local icon = mmButton:CreateTexture(nil, "ARTWORK")
		icon:SetSize(18, 18)
		icon:SetPoint("TOPLEFT", 7, -6)
		icon:SetTexture(SHARD_ICON)
		icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

		local border = mmButton:CreateTexture(nil, "OVERLAY")
		border:SetSize(53, 53)
		border:SetPoint("TOPLEFT")
		border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

		mmButton:SetScript("OnClick", function(_, button)
			if button == "RightButton" then
				db.shown = not db.shown
				Refresh()
				ns.SyncConfig()
			else
				ToggleConfig()
			end
		end)
		mmButton:SetScript("OnDragStart", function(self)
			self:SetScript("OnUpdate", function()
				local mx, my = Minimap:GetCenter()
				local scale = Minimap:GetEffectiveScale()
				local cx, cy = GetCursorPosition()
				if not (mx and my and cx and cy) then return end
				db.minimapAngle = math.deg(atan2(cy / scale - my, cx / scale - mx)) % 360
				PlaceMinimapButton()
			end)
		end)
		mmButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
		mmButton:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText("Shard Grid", 1, 1, 1)
			if lastStats then
				GameTooltip:AddLine(("Soul Shards: %d"):format(lastStats.inSoul + lastStats.outside), 0.72, 0.35, 1)
			end
			GameTooltip:AddLine("Left-click: options", 0.7, 0.7, 0.7)
			GameTooltip:AddLine("Right-click: show / hide the grid", 0.7, 0.7, 0.7)
			GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	mmButton:SetShown(db.minimapShown)
	PlaceMinimapButton()
end

-- ------------------------------------------------------------------
-- Events
-- ------------------------------------------------------------------
function ns.InitDB()
	local fresh = type(ShardGridDB) ~= "table"
	if fresh then ShardGridDB = {} end
	db = ShardGridDB
	report["saved vars"] = report["saved vars"] or (fresh and "none found (new settings)" or "loaded at ADDON_LOADED")
	-- 1.1: positions moved to UIParent units; "only with soul bag" became an opt-in pause.
	if not fresh and not db.v11 then
		if db.x and db.y then db.x, db.y = db.x * (db.scale or 1), db.y * (db.scale or 1) end
		db.onlyWithBag = false
	end
	db.v11 = true
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	if not db.autoDelete then db.keepExtra = KEEP_MAX end
end

local events = CreateFrame("Frame")
local function SafeRegister(event)
	local ok = pcall(events.RegisterEvent, events, event)
	report["event:" .. event] = ok and "ok" or "missing"
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		ns.InitDB()
		ns.SetupNativeSettings()
		self:UnregisterEvent("ADDON_LOADED")
		SafeRegister("PLAYER_LOGIN")
		SafeRegister("PLAYER_ENTERING_WORLD")
		SafeRegister("BAG_UPDATE_DELAYED")
		SafeRegister("BAG_UPDATE")
		SafeRegister("BAG_CONTAINER_UPDATE")
		SafeRegister("PLAYER_EQUIPMENT_CHANGED")
		SafeRegister("ADDON_ACTION_FORBIDDEN")
		SafeRegister("ADDON_ACTION_BLOCKED")
		RestoreAlertPosition()
		ApplyLock()
		ns.UpdateMinimapButton()
		return
	end
	-- Saved variables can arrive after ADDON_LOADED on this client (see LoadSavedVariablesFirst
	-- in the TOC). If the global was swapped for the real saved table, adopt it.
	if (event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD") and ShardGridDB ~= db and type(ShardGridDB) == "table" then
		ns.InitDB()
		report["saved vars"] = "arrived late, adopted at " .. event
		RestoreAlertPosition()
		ApplyLock()
		ns.UpdateMinimapButton()
	end
	if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
		if arg1 == ADDON then
			if GetCursorInfo() then ClearCursor() end
			if inHardwarePass then
				deleteBlocked, manualRun, pendingExcess = true, false, 0
				Print("|cffff4040this client refuses shard deletion from addons, even on a key press.|r Auto-delete is off until you toggle it again.")
				ns.SyncConfig()
			end
		end
		return
	end
	if event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE" then awaitingUpdate = false end
	if event == "BAG_UPDATE" and report["event:BAG_UPDATE_DELAYED"] == "ok" then
		return -- the delayed event covers it in one pass
	end
	Refresh()
	ns.SyncConfig()
end)

-- ------------------------------------------------------------------
-- Slash commands
-- ------------------------------------------------------------------
local function Help()
	Print("/shards opens the options window. Also:")
	Print("  /shards width N | size N | scale N (0.5-2)")
	Print("  /shards alert N (threshold) | alert on | alert off")
	Print("  /shards sound ID | minimap (toggle button) | oldmenu (standalone options window)")
	Print("  /shards lock | unlock | show | hide | reset | debug")
end

local function Debug()
	Print("debug:")
	for bag = 0, MAX_BAG do
		local slots = GetNumSlots(bag) or 0
		local free, family = GetNumFreeSlots(bag)
		Print(("  bag %d: slots=%d free=%s family=%s soul=%s"):format(
			bag, slots, tostring(free), tostring(family), tostring(slots > 0 and IsSoulBag(bag))))
	end
	local _, s = Scan()
	Print(("  inSoul=%d soulSlots=%d free=%d outside=%d excess=%d"):format(s.inSoul, s.soulSlots, s.free, s.outside, Excess(s)))
	Print(("  autoDelete=%s keepExtra=%d onlyWithBag=%s blocked=%s queued=%d waiting=%s"):format(
		tostring(db.autoDelete), db.keepExtra, tostring(db.onlyWithBag), tostring(deleteBlocked), pendingExcess, tostring(awaitingUpdate)))
	for k, v in pairs(report) do Print("  " .. k .. ": " .. v) end
end

SLASH_SHARDGRID1 = "/shards"
SLASH_SHARDGRID2 = "/shardgrid"
SlashCmdList["SHARDGRID"] = function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	local num = tonumber(arg)
	if cmd == "" or cmd == "config" or cmd == "options" then
		ToggleConfig()
		return
	elseif (cmd == "width" or cmd == "cols" or cmd == "w") and num then
		SetCols(num)
		Print("Width: " .. db.cols .. " columns.")
	elseif cmd == "size" and num then
		db.size = math.max(12, math.min(64, math.floor(num)))
		Print("Slot size: " .. db.size)
	elseif cmd == "scale" and num then
		SetGridScale(num > 4 and num / 100 or num)
		Print("Scale: " .. db.scale)
	elseif cmd == "alert" and (num or arg == "on" or arg == "off") then
		if num then
			db.alertThreshold = math.max(1, math.min(100, math.floor(num)))
			db.alertEnabled = true
		else
			db.alertEnabled = (arg == "on")
		end
		Print(db.alertEnabled and ("Alerting below " .. db.alertThreshold .. " shards.") or "Low shard alert off.")
	elseif cmd == "sound" and num then
		db.alertSoundCustom = math.floor(num)
		local _, played = ns.PlayAlertSound()
		Print("Alert sound kit " .. db.alertSoundCustom .. (played and "." or " - the client didn't play it."))
	elseif cmd == "oldmenu" then
		db.oldMenu = not db.oldMenu
		Print(db.oldMenu and "Using the standalone options window." or "Using the game's Options > AddOns page.")
		return
	elseif cmd == "minimap" then
		db.minimapShown = not db.minimapShown
		ns.UpdateMinimapButton()
		Print("Minimap button " .. (db.minimapShown and "shown." or "hidden."))
	elseif cmd == "lock" then
		db.locked = true
		Print("Locked.")
	elseif cmd == "unlock" then
		db.locked = false
		Print("Unlocked. Drag to move, drag the corner grip to change width.")
	elseif cmd == "show" then
		db.shown = true
	elseif cmd == "hide" then
		db.shown = false
		Print("Hidden. /shards show brings it back.")
	elseif cmd == "reset" then
		for k, v in pairs(DEFAULTS) do db[k] = v end
		db.x, db.y, db.alertX, db.alertY, db.alertSoundCustom = nil, nil, nil, nil, nil
		db.v11 = true
		RestoreAlertPosition()
		Print("Reset.")
	elseif cmd == "debug" then
		Debug()
		return
	else
		Help()
		return
	end
	ApplyLock()
	Refresh()
	ns.SyncConfig()
end
