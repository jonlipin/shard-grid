-- ShardGrid: a bag-window style grid of Soul Shards.
--   * With a soul bag equipped, every soul bag slot is a cell: filled = shard, dim = free slot.
--   * Shards sitting in normal bags are appended as "overflow" cells in a different color.
--   * Grid width (columns) is set with the drag grip, the config window or "/shards width N".
--   * Optional auto-delete of overflow shards beyond a configurable allowance.
-- Anything that can't be verified offline is pcall-guarded and reported by "/shards debug".

local ADDON, ns = ...

local report = {}

local SHARD_ID = 6265
local SHARD_ICON = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02"
local SOUL_BAG_FAMILY = 4 -- bag family bit for Soul Bags
local MAX_BAG = NUM_BAG_SLOTS or 4
local MIN_COLS, MAX_COLS = 1, 24
local KEEP_MAX = 40 -- top of the "extra shards to keep" slider

local GAP = 2
local TITLE_BUTTON = 22 -- title bar buttons, sized to sit inside the bar rather than over it
-- The metal border is built from fixed-size corner pieces; below this size they overlap and
-- the frame "breaks". Small grids shrink the whole panel (fit < 1) and size the cells up to
-- compensate, so slots stay the size you asked for while the border stays intact.
local MIN_W, MIN_H, MIN_FIT = 156, 110, 0.5
-- Content insets inside the panel art (title bar on top).
local INSET = { left = 10, right = 8, top = 27, bottom = 9 }

local COLOR = {
	shard    = { 0.72, 0.35, 1.00 }, -- shard inside a soul bag
	overflow = { 1.00, 0.38, 0.10 }, -- shard outside the soul bag
	excess   = { 1.00, 0.16, 0.14 }, -- over your limit as well, and about to be deleted
}

local DEFAULTS = {
	cols = 7,
	showEmpty = true,  -- pad the grid with empty bag slots
	minRows = 2,       -- keep at least this many rows so the window never jumps
	reverse = false,   -- empty slots first
	animate = true,    -- toss shards into the grid, flash them out
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
	summonEnabled = true,   -- listen for summon requests
	summonPopup = true,     -- pop the window up when a request arrives
	summonAnnounce = true,  -- tell party / raid when you start a summon
	summonWhisper = true,   -- whisper the player being summoned
	summonSound = true,
	summonWhisperAny = true, -- accept whispers from players outside the group (they get an Invite button)
	summonMin = false,
	summonButton = false,     -- floating click-to-summon button
	summonButtonSize = 40,
	stoneEnabled = true,      -- soulstone tracker
	stonePopup = true,
	stoneSoloHide = true,     -- hide the tracker while not in a group
	stoneAnnounce = false,    -- tell the group when you soulstone somebody
	tradeHealthstone = false,
	tradeGroupOnly = true,
	tradeCreate = true,   -- offer a Create Healthstone button on the trade window
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
local lastStats
local Refresh -- forward

local atan2 = math.atan2 or math.atan
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffb45cffShardGrid|r: " .. tostring(msg))
end

-- Refusal log. Anything the client refuses to let this addon do is named here, once, with
-- how far through loading we were, and the client's own popup is dismissed.
ns.blockLog, ns.blockOrder = {}, {}
local loadStage = "loading"
local blockWatcher = CreateFrame("Frame")
pcall(blockWatcher.RegisterEvent, blockWatcher, "ADDON_ACTION_FORBIDDEN")
pcall(blockWatcher.RegisterEvent, blockWatcher, "ADDON_ACTION_BLOCKED")
blockWatcher:SetScript("OnEvent", function(_, event, who, fn)
	if who ~= ADDON then return end
	local what = (event == "ADDON_ACTION_FORBIDDEN") and "forbidden" or "blocked"
	fn = tostring(fn or "?")
	local key = what .. " " .. fn
	if not ns.blockLog[key] then
		ns.blockLog[key] = loadStage
		ns.blockOrder[#ns.blockOrder + 1] = key
		Print(("|cffff4040%s:|r %s |cff9d9d9d(during: %s)|r - please send me this line."):format(what, fn, loadStage))
	end
	report["last " .. what] = fn .. " @" .. loadStage
	-- A refusal during a stage we can switch off is remembered and that part stays off.
	if loadStage == "key listener" then
		ns.keyListenerRefused = true
		if db then db.noKeyListener = true end
	end
	if ns.OnAddonActionBlocked then ns.OnAddonActionBlocked(what) end
	if GetCursorInfo and GetCursorInfo() then ClearCursor() end
	if StaticPopup_Hide then
		pcall(StaticPopup_Hide, "ADDON_ACTION_FORBIDDEN")
		pcall(StaticPopup_Hide, "ADDON_ACTION_BLOCKED")
	end
end)

function ns.SetStage(stage) loadStage = stage end

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
local passBlocked = false   -- the client refused an action during the current pass
local blockedStrikes = 0    -- passes in a row that achieved nothing
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

-- Deletes ONE overflow shard stack (last bag slot first) and returns how many shards that was.
-- Verified in-game: the client allows a single protected item action per hardware event; a second
-- DeleteCursorItem in the same key press is refused ("Interface action failed because of an AddOn").
-- So each key press / click removes one stack, and the next press takes the next one.
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
							return issued + count
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

	inHardwarePass, passBlocked = true, false
	local ok, issued = pcall(DeleteShards, excess)
	inHardwarePass = false
	if ok and issued == 0 and passBlocked then
		blockedStrikes = blockedStrikes + 1
		if blockedStrikes >= 3 then
			deleteBlocked, pendingExcess = true, 0
			Print("|cffff4040this client refuses shard deletion from addons, even on a key press.|r Auto-delete is off until you toggle it again.")
			ns.SyncConfig()
		end
		return
	end
	if ok and issued > 0 then blockedStrikes = 0 end
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

-- Pass-through keyboard listener: sees every key press without consuming it, so a queued
-- delete can run on a real hardware event. Watching the keyboard this way is the only thing
-- this addon does at load that reaches into the client's own input handling, so it is staged
-- (the refusal log names it) and it switches itself off for good if the client objects.
local keyListener
local function BuildKeyListener()
	if keyListener then return end
	ns.SetStage("key listener")
	local ok = pcall(function()
		local keys = CreateFrame("Frame", "ShardGridKeyListener", UIParent)
		keys:SetSize(1, 1)
		keys:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
		keys:EnableKeyboard(true)
		keys:SetPropagateKeyboardInput(true)
		keys:SetScript("OnKeyDown", function() if pendingExcess > 0 then ns.HardwareDeletePass() end end)
		keyListener = keys
	end)
	ns.SetStage("loading")
	report["key listener"] = ok and "ok" or "unavailable (deletes happen when you click the grid)"
end

local function TeardownKeyListener()
	if not keyListener then return end
	keyListener:SetScript("OnKeyDown", nil)
	pcall(keyListener.EnableKeyboard, keyListener, false)
	keyListener:Hide()
	keyListener = nil
	report["key listener"] = "switched off (the client refused it)"
end

function ns.ApplyKeyListener()
	local wanted = not (db and db.noKeyListener) and not ns.keyListenerRefused
	if wanted then BuildKeyListener() else TeardownKeyListener() end
	if ns.keyListenerRefused and not ns.keyListenerToldYou then
		ns.keyListenerToldYou = true
		Print("This client won't let an addon watch for key presses, so extra shards are deleted when you |cffffffffclick the grid|r (or the alert icon, or the Delete extras now button) instead.")
	end
end

-- Saved variables are available before this file runs, so a client that refused this last
-- session never tries again.
if not (ShardGridDB and ShardGridDB.noKeyListener) then BuildKeyListener() end

ns.SetStage("panels")
-- ------------------------------------------------------------------
-- Panel construction (bag-window look)
-- ------------------------------------------------------------------
-- Put a button above every other child of its panel, but no higher: raising the strata
-- would float it over unrelated windows such as the bags.
local function RaiseWithinParent(button, parent, margin)
	local level = parent:GetFrameLevel() or 1
	for _, child in ipairs({ parent:GetChildren() }) do
		if child ~= button then level = math.max(level, child:GetFrameLevel() or 0) end
	end
	button:SetFrameLevel(level + (margin or 5))
end
ns.RaiseWithinParent = RaiseWithinParent

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
		if ok and b then close = b end
	elseif not wantClose and close then
		close:Hide()
	end
	if close and wantClose then
		close:SetSize(TITLE_BUTTON, TITLE_BUTTON)
		close:ClearAllPoints()
		close:SetPoint("TOPRIGHT", -4, -3)
	end
	f.sgClose = close

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

ns.SetStage("alert frame")
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

ns.SetStage("grid cells")
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
		cell.bg:SetAlpha(data.pad and 0.45 or 1)
		return
	end
	cell.bg:SetAlpha(1)
	local c = COLOR[data.kind]
	cell.icon:Show()
	if not cell.animIn then cell.icon:SetAlpha(1) end
	if data.kind == "overflow" or data.kind == "excess" then
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
-- Shards arriving and leaving
-- A new shard is tossed into its slot: it starts at nothing, arcs up and over, and grows to
-- size as it lands. A spent one flashes: it swells out of its slot and fades.
-- ------------------------------------------------------------------
local ANIM = { pool = {}, bursts = {}, trails = {}, running = {},
	driver = nil, layer = nil, IN = 1, OUT = 0.3, BURST = 0.45, TRAIL = 0.32 }

-- Flyers live on their own frame over the whole screen, not inside the grid, so a shard can
-- travel across the screen and still be drawn on top of what it passes.
function ANIM.GetFlyer()
	if not ANIM.layer then
		ANIM.layer = CreateFrame("Frame", nil, UIParent)
		ANIM.layer:SetAllPoints(UIParent)
		ANIM.layer:SetFrameStrata("HIGH")
	end
	for _, tex in ipairs(ANIM.pool) do
		if not tex.busy then return tex end
	end
	local tex = ANIM.layer:CreateTexture(nil, "OVERLAY")
	tex:SetTexture(SHARD_ICON)
	tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	tex:Hide()
	ANIM.SoftenEdges(tex)
	ANIM.pool[#ANIM.pool + 1] = tex
	return tex
end

-- Something bright and round for the burst. Atlases can be tested for, so those come first,
-- then a couple of textures, and a plain glow as a last resort.
function ANIM.BurstArt()
	if ANIM.burstArt == nil then
		-- The cooldown star is a cross of light, which is the shape wanted here. If this
		-- client has no such file, these atlases are the next best thing.
		ANIM.burstArt = { texture = "Interface\\Cooldown\\star4" }
		local probe = ANIM.layer and ANIM.layer:CreateTexture()
		if probe then
			probe:SetTexture(ANIM.burstArt.texture)
			if not probe:GetTexture() then
				ANIM.burstArt = nil
				for _, atlas in ipairs({ "Artifacts-StarBurst", "UI-Achievement-Shine",
					"loottoast-glow", "Azerite-PointGlow" }) do
					if HasAtlas(atlas) then ANIM.burstArt = { atlas = atlas } break end
				end
				ANIM.burstArt = ANIM.burstArt or { plain = true }
			end
			probe:Hide()
		end
		report["shard burst"] = ANIM.burstArt.atlas or ANIM.burstArt.texture or "plain light"
	end
	return ANIM.burstArt
end

function ANIM.GetBurst()
	if not ANIM.layer then ANIM.GetFlyer() end -- makes the layer
	for _, tex in ipairs(ANIM.bursts) do
		if not tex.busy then return tex end
	end
	local tex = ANIM.layer:CreateTexture(nil, "OVERLAY", nil, -1)
	local art = ANIM.BurstArt()
	if art.atlas then tex:SetAtlas(art.atlas)
	elseif art.texture then tex:SetTexture(art.texture)
	else tex:SetColorTexture(1, 1, 1, 1) end
	tex:SetBlendMode("ADD")
	tex:Hide()
	ANIM.bursts[#ANIM.bursts + 1] = tex
	return tex
end

-- A purple flash where the shard comes into being, before it is thrown.
function ANIM.Burst(x, y, size)
	local tex = ANIM.GetBurst()
	tex.busy = true
	tex:SetVertexColor(0.72, 0.35, 1)
	tex:SetAlpha(0)
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
	tex:Show()
	ANIM.StartAnimation({
		tex = tex, size = size, t = 0, dur = ANIM.BURST, burst = true,
		spin = (math.random() < 0.5 and -1 or 1) * math.pi * 0.6,
	})
end

-- The portrait mask is a circle that fades out towards its edge, which is exactly the
-- shape wanted: the icon keeps its middle and loses its corners.
function ANIM.MaskArt()
	if ANIM.maskArt == nil then
		ANIM.maskArt = false
		local probe = ANIM.layer and ANIM.layer.CreateMaskTexture and ANIM.layer:CreateMaskTexture()
		if probe then
			for _, path in ipairs({
				"Interface\\CharacterFrame\\TempPortraitAlphaMask",
				"Interface\\Masks\\CircleMaskScalable",
			}) do
				probe:SetTexture(path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
				if probe:GetTexture() then ANIM.maskArt = path break end
			end
			probe:Hide()
		end
		report["flight mask"] = ANIM.maskArt or "none on this client (square corners)"
	end
	return ANIM.maskArt
end

-- Give one flying texture its own mask, following it as it moves and grows.
function ANIM.SoftenEdges(tex)
	local art = ANIM.MaskArt()
	if not art or not ANIM.layer.CreateMaskTexture then return end
	local ok, mask = pcall(ANIM.layer.CreateMaskTexture, ANIM.layer)
	if not ok or not mask then return end
	mask:SetTexture(art, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(tex)
	pcall(tex.AddMaskTexture, tex, mask)
end

-- Something soft and round for the trail: a glow if the client has one, the same star as
-- the burst if not, and plain light as a last resort.
function ANIM.TrailArt()
	if ANIM.trailArt == nil then
		local found
		local probe = ANIM.layer and ANIM.layer:CreateTexture()
		if probe then
			for _, path in ipairs({
				"Interface\\GLUES\\MODELS\\UI_Draenei\\GenericGlow64",
				"Interface\\SpellActivationOverlay\\IconAlert",
				"Interface\\Cooldown\\star4",
			}) do
				probe:SetTexture(path)
				if probe:GetTexture() then found = { texture = path } break end
			end
			probe:Hide()
		end
		if not found then
			for _, atlas in ipairs({ "loottoast-glow", "Azerite-PointGlow", "UI-Frame-IconGlow" }) do
				if HasAtlas(atlas) then found = { atlas = atlas } break end
			end
		end
		ANIM.trailArt = found or { plain = true }
		report["shard trail"] = ANIM.trailArt.atlas or ANIM.trailArt.texture or "plain light"
	end
	return ANIM.trailArt
end

function ANIM.GetTrail()
	if not ANIM.layer then ANIM.GetFlyer() end
	for _, tex in ipairs(ANIM.trails) do
		if not tex.busy then return tex end
	end
	local tex = ANIM.layer:CreateTexture(nil, "OVERLAY", nil, -2)
	local art = ANIM.TrailArt()
	if art.atlas then tex:SetAtlas(art.atlas)
	elseif art.texture then tex:SetTexture(art.texture)
	else tex:SetColorTexture(1, 1, 1, 1) end
	tex:SetBlendMode("ADD")
	tex:Hide()
	ANIM.trails[#ANIM.trails + 1] = tex
	return tex
end

-- One puff of the trail, left behind where the shard just was.
function ANIM.Puff(x, y, size)
	local tex = ANIM.GetTrail()
	tex.busy = true
	tex:SetVertexColor(0.66, 0.3, 1)
	tex:SetSize(size, size)
	tex:SetAlpha(0.55)
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
	tex:Show()
	ANIM.StartAnimation({ tex = tex, size = size, t = 0, dur = ANIM.TRAIL, trail = true })
end

-- Where a frame sits, and how big it looks, in the screen's own units.
function ANIM.OnScreen(f)
	local ui = UIParent:GetEffectiveScale()
	if not ui or ui <= 0 then return end
	local rel = (f:GetEffectiveScale() or ui) / ui
	local x, y = f:GetCenter()
	if not x or not y then return end
	return x * rel, y * rel, rel
end

function ANIM.StepAnimations(_, elapsed)
	for i = #ANIM.running, 1, -1 do
		local a = ANIM.running[i]
		a.t = a.t + elapsed
		local pos = math.min(1, a.t / a.dur)
		if a.arriving then
			-- A quadratic curve: P = (1-t)^2 * start + 2(1-t)t * peak + t^2 * slot. The peak
			-- sits above both ends, so the shard rises and then falls into place.
			--
			-- Time runs straight here on purpose. The peak is set midway across, which makes
			-- the horizontal part of that curve linear and the vertical part a parabola, so
			-- a straight clock gives constant horizontal speed with the vertical slowing to
			-- a stop at the top and gathering pace on the way down. That is a thrown object
			-- under gravity, and bending the clock would only spoil it.
			local t = pos
			local inv = 1 - t
			local x = inv * inv * a.x0 + 2 * inv * t * a.cx + t * t * a.x1
			local y = inv * inv * a.y0 + 2 * inv * t * a.cy + t * t * a.y1
			a.tex:ClearAllPoints()
			a.tex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
			-- Visible the moment it leaves the burst, most of the growth happening early.
			local size = a.size * (0.4 + 0.6 * t ^ 0.5)
			a.tex:SetSize(size, size)
			a.tex:SetAlpha(math.min(1, pos * 8))
			local turned = a.spin and (a.spin * (1 - inv * inv))
			if turned and a.tex.SetRotation then
				-- Fast at first and easing off, ending on a whole turn so it lands upright.
				a.tex:SetRotation(turned)
			end
			if a.tinted then
				-- Ordinary at first, its colour coming on through the second half.
				a.tinted:SetSize(size, size)
				a.tinted:ClearAllPoints()
				a.tinted:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
				if turned and a.tinted.SetRotation then a.tinted:SetRotation(turned) end
				local shade = math.max(0, math.min(1, (t - 0.35) / 0.55))
				a.tinted:SetAlpha(math.min(1, pos * 8) * shade)
			end
			-- A glow dropped every so often along the way, fading behind it.
			a.puff = (a.puff or 0) + elapsed
			if a.puff >= 0.035 and pos < 0.96 then
				a.puff = 0
				ANIM.Puff(x, y, size * 1.5)
			end
		elseif a.trail then
			local size = a.size * (1 - 0.5 * pos)
			a.tex:SetSize(size, size)
			a.tex:SetAlpha(0.55 * (1 - pos) * (1 - pos))
		elseif a.burst then
			-- Swells and fades: bright the instant it appears, gone a moment later.
			local size = a.size * (0.6 + 3 * pos)
			a.tex:SetSize(size, size)
			a.tex:SetAlpha((1 - pos) * (1 - pos))
			if a.tex.SetRotation then a.tex:SetRotation(a.spin * pos) end
		else
			local size = a.size * (1 + 0.7 * pos)
			a.tex:SetSize(size, size)
			a.tex:SetAlpha(1 - pos * pos)
		end
		if pos >= 1 then
			a.tex:Hide()
			a.tex.busy = false
			if a.tinted then
				a.tinted:Hide()
				a.tinted.busy = false
			end
			if a.cell and a.arriving then
				a.cell.animIn = nil
				a.cell.icon:SetAlpha(1)
			end
			table.remove(ANIM.running, i)
		end
	end
	if #ANIM.running == 0 and ANIM.driver then ANIM.driver:SetScript("OnUpdate", nil) end
end

function ANIM.StartAnimation(a)
	if not ANIM.driver then ANIM.driver = CreateFrame("Frame") end
	ANIM.running[#ANIM.running + 1] = a
	ANIM.driver:SetScript("OnUpdate", ANIM.StepAnimations)
end

function ANIM.TossIn(cell, size, tint)
	local x1, y1, rel = ANIM.OnScreen(cell)
	if not x1 then return end -- not laid out yet, so nowhere to fly to

	local w, h = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
	if w <= 0 or h <= 0 then return end

	local tex = ANIM.GetFlyer()
	tex.busy = true
	tex:SetBlendMode("BLEND")
	if tex.SetRotation then tex:SetRotation(0) end
	tex:SetVertexColor(1, 1, 1)
	tex:SetDesaturated(false)
	tex:SetAlpha(0)
	tex:Show()

	-- The colour it will end up, laid over the top and faded in during the flight.
	local tinted
	if tint then
		tinted = ANIM.GetFlyer()
		tinted.busy = true
		tinted:SetBlendMode("BLEND")
		if tinted.SetRotation then tinted:SetRotation(0) end
		tinted:SetDesaturated(true)
		tinted:SetVertexColor(tint[1], tint[2], tint[3])
		tinted:SetAlpha(0)
		tinted:Show()
	end
	cell.animIn = true
	cell.icon:SetAlpha(0)

	-- Thrown from somewhere in a patch of screen around the middle, a third of the way up, so
	-- every shard comes from its own spot rather than all from one point. A random angle with
	-- the square root of a random radius spreads them evenly over the patch instead of
	-- bunching them in the centre.
	local angle = math.random() * 2 * math.pi
	local reach = math.sqrt(math.random())
	local x0 = w * 0.5 + math.cos(angle) * reach * w * 0.09
	local y0 = h * (1 / 3 - 0.1) + math.sin(angle) * reach * h * 0.09

	-- The peak of the lob sits well above whichever end is higher, by more the further it
	-- travels, so the throw carries rather than skimming across.
	local dx, dy = x1 - x0, y1 - y0
	local lift = math.max(h * 0.24, math.sqrt(dx * dx + dy * dy) * 0.55) * (0.88 + math.random() * 0.24)
	local flight = ANIM.IN * (0.9 + math.random() * 0.2)

	-- Rotation follows the throw: clockwise going right, the other way going left. Positive
	-- angles turn counter-clockwise, hence the sign.
	local turns = math.random(1, 2) * 2 * math.pi

	ANIM.Burst(x0, y0, size * rel * 2.2)

	ANIM.StartAnimation({
		tex = tex, tinted = tinted, cell = cell, size = size * rel, t = 0, dur = flight, arriving = true,
		x0 = x0, y0 = y0,
		cx = (x0 + x1) / 2,
		cy = math.max(y0, y1) + lift,
		x1 = x1, y1 = y1,
		spin = (dx >= 0) and -turns or turns,
	})
end

function ANIM.FlashOut(cell, size, tint)
	local x, y, rel = ANIM.OnScreen(cell)
	if x then ANIM.Burst(x, y, size * (rel or 1) * 1.9) end
	local tex = ANIM.GetFlyer()
	tex.busy = true
	tex:SetVertexColor(tint and tint[1] or 1, tint and tint[2] or 1, tint and tint[3] or 1)
	tex:SetDesaturated(tint and true or false)
	tex:SetBlendMode("ADD")
	if tex.SetRotation then tex:SetRotation(0) end
	tex:SetSize(size * (rel or 1), size * (rel or 1))
	tex:SetAlpha(1)
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", cell, "CENTER")
	tex:Show()
	ANIM.StartAnimation({ tex = tex, size = size * (rel or 1), t = 0, dur = ANIM.OUT, arriving = false })
end

ns.ANIM = ANIM -- exposed so the offline tests can check the flight path

-- Clear anything in flight, and give the slots their icons back.
function ANIM.StopAll()
	for i = #ANIM.running, 1, -1 do
		local a = ANIM.running[i]
		a.tex:Hide()
		a.tex.busy = false
		if a.tinted then
			a.tinted:Hide()
			a.tinted.busy = false
		end
		if a.cell and a.arriving then
			a.cell.animIn = nil
			a.cell.icon:SetAlpha(1)
		end
		ANIM.running[i] = nil
	end
	if ANIM.driver then ANIM.driver:SetScript("OnUpdate", nil) end
end

-- Work out what changed since the last refresh and play it.
function ANIM.PlayChanges(data, count, size)
	local before = ns.prevKinds
	ns.prevKinds = {}
	for i = 1, count do ns.prevKinds[i] = data[i].kind end
	if not before or not db.animate then return end

	-- Same shape: a straight comparison says exactly which slots changed.
	if #before == count then
		for i = 1, count do
			local was, now = before[i], data[i].kind
			if was ~= now and cells[i] then
				if was == "empty" and now ~= "empty" then
					ANIM.TossIn(cells[i], size, COLOR[now] ~= COLOR.shard and COLOR[now] or nil)
				elseif was ~= "empty" and now == "empty" then
					ANIM.FlashOut(cells[i], size, COLOR[was] ~= COLOR.shard and COLOR[was] or nil)
				end
			end
		end
		return
	end

	-- The grid changed shape, so fall back to counting: the newest shards sit at the end of
	-- the filled run, and a spent one leaves the slot just past it.
	local function Filled(list, n)
		local total = 0
		for i = 1, n do
			if list[i] and list[i] ~= "empty" then total = total + 1 end
		end
		return total
	end
	local had, has = Filled(before, #before), Filled(ns.prevKinds, count)
	local order = {}
	for i = 1, count do
		local j = db.reverse and (count + 1 - i) or i
		order[#order + 1] = j
	end
	if has > had then
		for k = had + 1, has do
			local cell = cells[order[k]]
			if cell then ANIM.TossIn(cell, size, COLOR[data[order[k]].kind] ~= COLOR.shard and COLOR[data[order[k]].kind] or nil) end
		end
	elseif had > has then
		for k = has + 1, math.min(had, count) do
			local cell = cells[order[k]]
			if cell then ANIM.FlashOut(cell, size) end
		end
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
	if ns.UpdateSummonWindow and ShardGridSummons and ShardGridSummons:IsShown() then ns.UpdateSummonWindow() end
	if ns.UpdateSummonButton and ShardGridSummonButton and ShardGridSummonButton:IsShown() then ns.UpdateSummonButton() end
	if ns.UpdateMakeButton and TradeFrame and TradeFrame:IsShown() then ns.UpdateMakeButton() end

	if not ShouldShow(stats, n) then
		frame:Hide()
		return
	end

	-- Shards outside the soul bag that are over your limit are the next to be deleted, so
	-- they are tinted gold and moved to the end of the run, against the empty slots.
	local over = Excess(stats)
	if over > 0 then
		local function Loose(cell)
			return cell.kind == "overflow" or (not stats.hasSoulBag and cell.kind == "shard")
		end
		local first
		for i = 1, n do
			if Loose(data[i]) then first = i break end
		end
		if first then
			local left = over
			for i = n, first, -1 do
				if left <= 0 then break end
				local cell = data[i]
				if Loose(cell) then
					cell.kind = "excess"
					left = left - (cell.count or 1)
				end
			end
			local keep, going = {}, {}
			for i = first, n do
				local cell = data[i]
				if cell.kind == "excess" then going[#going + 1] = cell else keep[#keep + 1] = cell end
			end
			local at = first
			for _, cell in ipairs(keep) do data[at] = cell at = at + 1 end
			for _, cell in ipairs(going) do data[at] = cell at = at + 1 end
		end
	end

	-- Pad with empty bag slots so the grid keeps a steady shape, then optionally flip it
	-- so the free slots sit at the top.
	local realCount = n
	local cols = db.cols
	if db.showEmpty then
		local want = math.max(math.ceil(n / cols) * cols, db.minRows * cols)
		for i = n + 1, want do data[i] = { kind = "empty", pad = true } end
		n = #data
	end
	if db.reverse then
		for i = 1, math.floor(n / 2) do data[i], data[n + 1 - i] = data[n + 1 - i], data[i] end
	end

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
	ANIM.PlayChanges(data, n, size)
	ns.lastCells = data
	emptyText:SetShown(realCount == 0 and not stats.hasSoulBag)

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
	if frame.sgCog and not frame.sgRaised then
		frame.sgRaised = true
		RaiseWithinParent(frame.sgCog, frame)
		if frame.sgGrip then RaiseWithinParent(frame.sgGrip, frame) end
	end
	local cog = frame.sgCog
	if cog then
		local h = math.min(20 / fit, 26)
		local w = h
		if type(cog.artW) == "number" and type(cog.artH) == "number" and cog.artH > 0 then
			w = h * (cog.artW / cog.artH)
		end
		cog:SetSize(w, h)
		title:SetPoint("RIGHT", cog, "LEFT", -2, 0)
		title:SetPoint("LEFT", frame, "LEFT", 6, 0)
	end
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
	title:ClearAllPoints()
	title:SetPoint("TOP", frame, "TOP", 0, -6)
	title:SetJustifyH("CENTER")
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
		local over = Excess(s)
		if over > 0 then
			GameTooltip:AddDoubleLine("Over your limit", over, 1, 0.38, 0.1, 1, 1, 1)
		end
	else
		GameTooltip:AddDoubleLine("In bags", s.outside, 0.72, 0.35, 1, 1, 1, 1)
		local over = Excess(s)
		if over > 0 then
			GameTooltip:AddDoubleLine("Over your limit", over, 1, 0.38, 0.1, 1, 1, 1)
		end
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
RaiseWithinParent(grip, frame)
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
	if ns.UpdateSummonButton then ns.UpdateSummonButton() end
end

ns.SetStage("summon window")
-- ------------------------------------------------------------------
-- Summon requests: a window listing who asked for a summon (oldest first). Clicking a name
-- targets them and casts Ritual of Summoning (secure button), whispers them and tells the group.
-- Secure buttons cannot be touched in combat, so every layout change is deferred until combat ends.
-- ------------------------------------------------------------------
local SUMMON_SPELL_ID = 698
local MAX_SUMMON_ROWS = 10
local SUMMON_ROW_H = 24
local SUMMON_W = 280
-- Message templates. Placeholders: {name} = player, {zone} = your zone and coordinates, {shards} = shards left after this summon.
local DEFAULT_GROUP_MSG = "Summoning {name} to {minimap} in {area} ({coords}). Need 2 people to help click the portal, please! Shards left after this: {shards}."
local DEFAULT_WHISPER_MSG = "Summon incoming! Bringing you to {minimap} in {area} ({coords}). Please be ready to accept. Shards left after this: {shards}."
local PLACEHOLDER_HELP = table.concat({
	"Placeholders:",
	"|cffffd100{name}|r  the player being summoned",
	"|cffffd100{area}|r  your zone (GetZoneText)",
	"|cffffd100{subzone}|r  your subzone (GetSubZoneText)",
	"|cffffd100{minimap}|r  the minimap zone text (GetMinimapZoneText)",
	"|cffffd100{coords}|r  your coordinates, e.g. 51, 29",
	"|cffffd100{zone}|r  zone, subzone and coordinates together",
	"|cffffd100{shards}|r  shards left after this summon",
	" ",
	"Clear the box and click elsewhere to restore the default.",
}, string.char(10))

-- where = table from WhereAmI(): full, area, subzone, minimap, coords
local function FillTemplate(tpl, req, where, left)
	return (tpl:gsub("{(%w+)}", {
		name = req.short,
		zone = where.full,
		area = where.area,
		subzone = where.subzone,
		minimap = where.minimap,
		coords = where.coords,
		shards = tostring(left),
	}))
end

local DEFAULT_KEYWORDS = "123, 1, summon, summons, summ, sum, smn, summon pls, summon please, need summon, need a summon, lock port, warlock port"

local requests = {}      -- { name, short, class, time, clicked, lastSent, wasGrouped }
local summonDirty = false
local summonWantShow = false
local keywordCache, keywordSource

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

local function SummonSpellName()
	local name
	if C_Spell and C_Spell.GetSpellName then name = C_Spell.GetSpellName(SUMMON_SPELL_ID) end
	if not name and GetSpellInfo then name = GetSpellInfo(SUMMON_SPELL_ID) end
	return name or "Ritual of Summoning"
end

local function Keywords()
	local src = db.summonKeywords or DEFAULT_KEYWORDS
	if src ~= keywordSource then
		keywordSource, keywordCache = src, {}
		for word in src:gmatch("[^,;\n]+") do
			word = word:lower():gsub("%p", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
			if word ~= "" then keywordCache[#keywordCache + 1] = word end
		end
	end
	return keywordCache
end

-- Short keywords ("1") must be the whole message; longer ones match as whole words / phrases.
local function IsSummonRequest(text)
	local msg = text:lower():gsub("%p", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if msg == "" then return false end
	local padded = " " .. msg .. " "
	for _, kw in ipairs(Keywords()) do
		if #kw <= 2 then
			if msg == kw then return true end
		elseif padded:find(" " .. kw .. " ", 1, true) then
			return true
		end
	end
	return false
end
ns.IsSummonRequest = IsSummonRequest

local function ShortName(name)
	if Ambiguate then name = Ambiguate(name, "none") end
	return name
end

local function FindGroupUnit(short)
	local base = short:match("^[^-]+") or short
	local prefix, count = "party", 4
	if IsInRaid and IsInRaid() then prefix, count = "raid", 40 end
	for i = 1, count do
		local unit = prefix .. i
		if UnitExists(unit) then
			local n = UnitName(unit)
			if n == short or n == base then return unit end
		end
	end
end

local function GroupChannel()
	if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid and IsInRaid() then return "RAID" end
	if IsInGroup and IsInGroup() then return "PARTY" end
end

-- Returns the pieces a message template can use. Same sources as the classic macro
-- "... to <GetMinimapZoneText()> in <GetZoneText()>".
local function WhereAmI()
	local function Text(fn) local ok, v = pcall(fn) return (ok and type(v) == "string") and v or "" end
	local area = Text(GetZoneText)
	if area == "" then area = Text(GetRealZoneText) end
	local subzone = Text(GetSubZoneText)
	local minimap = Text(GetMinimapZoneText)
	if minimap == "" then minimap = (subzone ~= "") and subzone or area end

	local coords = ""
	local ok, x, y = pcall(function()
		local map = C_Map.GetBestMapForUnit("player")
		local pos = map and C_Map.GetPlayerMapPosition(map, "player")
		if pos then return pos:GetXY() end
	end)
	if ok and x and y and not IsSecret(x) and (x > 0 or y > 0) then
		coords = ("%d, %d"):format(math.floor(x * 100 + 0.5), math.floor(y * 100 + 0.5))
	end

	local full = area ~= "" and area or "?"
	if subzone ~= "" and subzone ~= area then full = full .. " - " .. subzone end
	if coords ~= "" then full = full .. " (" .. coords .. ")" end
	return { full = full, area = area, subzone = subzone, minimap = minimap, coords = coords }
end

local function PreviewMessage(tpl)
	local total = lastStats and (lastStats.inSoul + lastStats.outside) or 0
	local me = UnitName("player") or "You"
	return FillTemplate(tpl, { short = me, name = me }, WhereAmI(), math.max(0, total - 1))
end

local function SendChat(text, channel, target)
	local ok, err = pcall(SendChatMessage, text, channel, nil, target)
	if not ok then report["summon chat"] = tostring(err) end
end

-- ---- window -----------------------------------------------------------------
local sumWin = CreatePanel("ShardGridSummons", true)
sumWin:SetFrameStrata("MEDIUM")
sumWin:SetWidth(SUMMON_W)
sumWin:Hide()
sumWin.sgTitle:SetText("Summons")

local sumContent = CreateFrame("Frame", nil, sumWin)
sumContent:SetPoint("TOPLEFT", INSET.left, -INSET.top)
sumContent:SetPoint("BOTTOMRIGHT", -INSET.right, INSET.bottom)

-- Minimized look: a plain title strip (the metal border can't shrink that small).
local sumMini
do
	local ok, f = pcall(CreateFrame, "Frame", nil, sumWin, "BackdropTemplate")
	sumMini = (ok and f) or CreateFrame("Frame", nil, sumWin)
	sumMini:SetAllPoints()
	sumMini:SetFrameLevel(sumWin:GetFrameLevel())
	if sumMini.SetBackdrop then
		sumMini:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		sumMini:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
	end
	sumMini.title = sumMini:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	sumMini.title:SetPoint("LEFT", 10, 0)
	sumMini:Hide()
end

local sumMinBtn = CreateFrame("Button", nil, sumWin, "UIPanelButtonTemplate")
sumMinBtn:SetSize(TITLE_BUTTON, TITLE_BUTTON - 4)
if sumWin.sgClose then
	sumMinBtn:SetPoint("RIGHT", sumWin.sgClose, "LEFT", -1, 0)
else
	sumMinBtn:SetPoint("TOPRIGHT", -28, -5)
end
RaiseWithinParent(sumMinBtn, sumWin)
sumMinBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(db and db.summonMin and "Expand" or "Minimize")
	GameTooltip:Show()
end)
sumMinBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local sumFooter = sumContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
sumFooter:SetPoint("BOTTOMLEFT", 2, 4)

local sumClear = CreateFrame("Button", nil, sumContent, "UIPanelButtonTemplate")
sumClear:SetSize(70, 20)
sumClear:SetPoint("BOTTOMRIGHT", 0, 0)
sumClear:SetText("Clear all")

local sumEmpty = sumContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
sumEmpty:SetPoint("TOP", 0, -10)
sumEmpty:SetText("No summon requests")

-- Combat banner: the rows are secure buttons and can't be disabled in combat, so an ordinary
-- frame is laid over them instead. It swallows the clicks and explains why.
local sumBanner = CreateFrame("Frame", nil, sumContent)
sumBanner:SetAllPoints()
sumBanner:SetFrameLevel(sumContent:GetFrameLevel() + 30)
sumBanner:EnableMouse(true)
sumBanner:Hide()
sumBanner.bg = sumBanner:CreateTexture(nil, "BACKGROUND")
sumBanner.bg:SetAllPoints()
sumBanner.bg:SetColorTexture(0, 0, 0, 0.9)
sumBanner.stripe = sumBanner:CreateTexture(nil, "BORDER")
sumBanner.stripe:SetPoint("LEFT")
sumBanner.stripe:SetPoint("RIGHT")
sumBanner.stripe:SetHeight(40)
sumBanner.stripe:SetColorTexture(0, 0, 0, 0.5)
sumBanner.text = sumBanner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
sumBanner.text:SetPoint("LEFT", 8, 0)
sumBanner.text:SetPoint("RIGHT", -8, 0)
sumBanner.text:SetJustifyH("CENTER")
sumBanner.text:SetText("In combat" .. string.char(10) .. "|cff9d9d9dSummons are usable again when combat ends.|r")
sumBanner:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("In combat", 1, 1, 1)
	GameTooltip:AddLine("The game doesn't let addons change cast buttons during combat. New requests are queued and the list unlocks when combat ends.", nil, nil, nil, true)
	GameTooltip:Show()
end)
sumBanner:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function UpdateCombatBanner(inCombat)
	sumBanner:SetShown(inCombat)
	GameTooltip:Hide() -- drop any row tooltip left under the banner
end

local function SaveSummonPosition()
	local left, top = sumWin:GetLeft(), sumWin:GetTop()
	if left and top and db then db.sumX, db.sumY = left, top end
end

local function RestoreSummonPosition()
	sumWin:ClearAllPoints()
	if db and db.sumX and db.sumY then
		sumWin:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", db.sumX, db.sumY)
	else
		sumWin:SetPoint("TOPLEFT", UIParent, "CENTER", 160, 120)
	end
end

sumWin:SetScript("OnDragStart", function(self)
	if InCombatLockdown() then return end
	self:StartMoving()
end)
sumWin:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	SaveSummonPosition()
	if not InCombatLockdown() then RestoreSummonPosition() end
end)

local UpdateSummonWindow -- forward

local function RemoveRequest(short)
	for i, r in ipairs(requests) do
		if r.short == short then table.remove(requests, i) break end
	end
	UpdateSummonWindow()
end

-- What happens (besides the secure cast) when a row is clicked.
local lastSentByName = {}

local function OnSummonClicked(req)
	if req.test then Print("That's a test entry - nothing was cast or sent.") return end
	local now = GetTime()
	if req.lastSent and now - req.lastSent < 5 then return end -- no double posts
	local previous = lastSentByName[req.short]
	if previous and now - previous < 5 then return end
	lastSentByName[req.short] = now
	local total = lastStats and (lastStats.inSoul + lastStats.outside) or 0
	if total <= 0 then
		Print("|cffff4040You have no Soul Shards|r - can't summon " .. req.short .. ".")
		return
	end
	req.lastSent, req.clicked = now, true
	local where = WhereAmI()
	local left = math.max(0, total - 1)
	if db.summonWhisper then
		SendChat(FillTemplate(db.summonWhisperMsg or DEFAULT_WHISPER_MSG, req, where, left), "WHISPER", req.name)
	end
	local channel = db.summonAnnounce and GroupChannel()
	if channel then
		SendChat(FillTemplate(db.summonGroupMsg or DEFAULT_GROUP_MSG, req, where, left), channel)
	end
end

-- Send the summon messages for a player who wasn't clicked in the list (the floating button).
function ns.SummonMessagesFor(name)
	if not name or name == "" then return end
	local short = ShortName(name)
	local req
	for _, r in ipairs(requests) do
		if r.short == short then req = r break end
	end
	req = req or { name = name, short = short }
	OnSummonClicked(req)
	UpdateSummonWindow()
end

local summonRows = {}
-- Test buttons in the options.
function ns.TestGroupMessage()
	-- Shown only to you: posting a test to the real party would spam them.
	local channel = GroupChannel()
	Print(("Preview of the %s message: |cffffffff%s|r"):format(channel and channel:lower():gsub("_", " ") or "party / raid", PreviewMessage(db.summonGroupMsg or DEFAULT_GROUP_MSG)))
	if not channel then Print("(You're not in a group right now, so nothing would actually be sent.)") end
end

function ns.TestWhisperMessage()
	-- Whispering yourself shows exactly what the player will see.
	local text = PreviewMessage(db.summonWhisperMsg or DEFAULT_WHISPER_MSG)
	local me = UnitName("player")
	if me then SendChat(text, "WHISPER", me) else Print("Preview of the whisper: |cffffffff" .. text .. "|r") end
end

local function GetSummonRow(i)
	local row = summonRows[i]
	if row then return row end
	row = CreateFrame("Button", "ShardGridSummonRow" .. i, sumContent, "SecureActionButtonTemplate")
	row:SetHeight(SUMMON_ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * SUMMON_ROW_H)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * SUMMON_ROW_H)
	row:RegisterForClicks("AnyUp", "AnyDown")

	row.stripe = row:CreateTexture(nil, "BACKGROUND")
	row.stripe:SetAllPoints()
	row.stripe:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)

	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	hl:SetBlendMode("ADD")

	row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.nameText:SetPoint("LEFT", 6, 0)
	row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.classText:SetPoint("LEFT", row.nameText, "RIGHT", 6, 0)
	row.ageText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.ageText:SetPoint("RIGHT", -22, 0)
	row.classText:SetPoint("RIGHT", row.ageText, "LEFT", -6, 0)
	row.classText:SetJustifyH("LEFT")
	row.classText:SetWordWrap(false)
	row.nameText:SetWidth(120)
	row.nameText:SetJustifyH("LEFT")
	row.nameText:SetWordWrap(false)

	-- Invite button for people who whispered from outside the group.
	row.invite = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.invite:SetSize(52, 18)
	row.invite:SetPoint("RIGHT", row.ageText, "LEFT", -6, 0)
	row.invite:SetText("Invite")
	row.invite:SetScript("OnClick", function()
		if not row.req then return end
		if row.req.test then Print("That's a test entry - no invite was sent.") return end
		local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
		local ok, err = pcall(invite, row.req.name)
		report["invite"] = ok and "sent" or ("error: " .. tostring(err))
		if ok then Print("Invited " .. row.req.short .. ".") end
	end)
	row.invite:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Invite to group", 1, 1, 1)
		GameTooltip:AddLine("They whispered from outside your group. Invite them, then click their name to summon.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	row.invite:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.invite:Hide()

	row.remove = CreateFrame("Button", nil, row)
	row.remove:SetSize(16, 16)
	row.remove:SetPoint("RIGHT", -3, 0)
	row.remove:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
	row.remove:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
	row.remove:SetScript("OnClick", function()
		if InCombatLockdown() then Print("Can't change the summon list in combat.") return end
		if row.req then RemoveRequest(row.req.short) end
	end)

	-- PostClick runs after the secure cast and is ordinary addon code.
	row:SetScript("PostClick", function(self, _, down)
		local useDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") or false
		if (down and true or false) ~= (useDown and true or false) then return end
		if self.req then OnSummonClicked(self.req) UpdateSummonWindow() end
	end)
	row:SetScript("OnEnter", function(self)
		if not self.req then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Summon " .. self.req.short, 1, 1, 1)
		GameTooltip:AddLine("Left-click: target and cast " .. SummonSpellName() .. ", whisper them and tell the group.", nil, nil, nil, true)
		GameTooltip:AddLine("Right-click: same, but casts straight at their unit frame (no target change).", 0.7, 0.7, 0.7, true)
		if self.req.test then
			GameTooltip:AddLine("Test entry: clicking casts and sends nothing.", 0.6, 0.6, 0.6)
		elseif not self.req.unit then
			GameTooltip:AddLine("Not in your group - use the Invite button first.", 1, 0.3, 0.3)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	summonRows[i] = row
	return row
end

local function AgeText(t)
	local s = math.floor(GetTime() - t)
	if s < 60 then return s .. "s" end
	return math.floor(s / 60) .. "m"
end

local function PaintSummonRow(row, req)
	local color = RAID_CLASS_COLORS and req.class and RAID_CLASS_COLORS[req.class]
	local hex = color and color.colorStr or "ffffffff"
	row.nameText:SetText(("|c%s%s|r"):format(hex, req.short))
	row.classText:SetText(req.clicked and "|cff40ff40summoning|r" or row.classText:GetText())
	local className = req.class and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[req.class]) or req.class) or ""
	local needsInvite = not req.unit
	row.invite:SetShown(needsInvite)
	row.classText:ClearAllPoints()
	row.classText:SetPoint("LEFT", row.nameText, "RIGHT", 6, 0)
	row.classText:SetPoint("RIGHT", needsInvite and row.invite or row.ageText, "LEFT", -6, 0)
	row.classText:SetText(req.test and (className .. " |cff9d9d9dtest|r") or req.unit and className or (className .. " |cffff5050not grouped|r"))
	row.ageText:SetText(AgeText(req.time))
end

local function ApplyMinimized()
	local min = db.summonMin and true or false
	sumContent:SetShown(not min)
	for _, key in ipairs({ "NineSlice", "Bg", "TitleContainer" }) do
		local region = sumWin[key]
		if type(region) == "table" and region.SetShown then region:SetShown(not min) end
	end
	sumMini:SetShown(min)
	sumMinBtn:SetText(min and "+" or "-")
end

function UpdateSummonWindow()
	if not db then return end
	if InCombatLockdown() then summonDirty = true return end
	summonDirty = false

	local spell = SummonSpellName()
	local n = math.min(#requests, MAX_SUMMON_ROWS)
	for i = 1, n do
		local req, row = requests[i], GetSummonRow(i)
		req.unit = FindGroupUnit(req.short)
		row.req = req
		if req.test then
			row:SetAttribute("type1", nil)
			row:SetAttribute("type2", nil)
		else
			row:SetAttribute("type1", "macro")
			row:SetAttribute("macrotext1", "/targetexact " .. req.short .. "\n/cast " .. spell)
			row:SetAttribute("type2", "spell")
			row:SetAttribute("spell2", spell)
			row:SetAttribute("unit2", req.unit)
		end
		PaintSummonRow(row, req)
		row:Show()
	end
	for i = n + 1, #summonRows do
		summonRows[i].req = nil
		summonRows[i]:Hide()
	end
	sumEmpty:SetShown(n == 0)

	local total = lastStats and (lastStats.inSoul + lastStats.outside) or 0
	sumFooter:SetText(("Soul Shards: |cffffffff%d|r"):format(total))
	local title = (#requests > 0) and ("Summons (" .. #requests .. ")") or "Summons"
	sumWin.sgTitle:SetText(title)
	sumMini.title:SetText(title)

	if not sumWin.sgRaised then
		sumWin.sgRaised = true
		ns.RaiseWithinParent(sumMinBtn, sumWin)
	end
	if ns.UpdateSummonButton then ns.UpdateSummonButton() end
	ApplyMinimized()
	local rowsH = math.max(1, n) * SUMMON_ROW_H
	sumWin:SetHeight(db.summonMin and 26 or math.max(MIN_H, INSET.top + rowsH + 28 + INSET.bottom))

	if summonWantShow then
		summonWantShow = false
		RestoreSummonPosition()
		sumWin:Show()
	elseif #requests == 0 and sumWin.autoShown then
		sumWin.autoShown = false
		sumWin:Hide()
	end
end
ns.UpdateSummonWindow = UpdateSummonWindow

sumMinBtn:SetScript("OnClick", function()
	if InCombatLockdown() then Print("Can't resize the summon window in combat.") return end
	db.summonMin = not db.summonMin
	UpdateSummonWindow()
end)
sumClear:SetScript("OnClick", function()
	if InCombatLockdown() then Print("Can't change the summon list in combat.") return end
	for i = #requests, 1, -1 do requests[i] = nil end
	UpdateSummonWindow()
end)

function ns.ToggleSummonWindow()
	if InCombatLockdown() then Print("Can't open the summon window in combat.") return end
	if sumWin:IsShown() then
		sumWin:Hide()
	else
		sumWin.autoShown = false
		summonWantShow = true
		UpdateSummonWindow()
	end
end

local TEST_NAMES = { "Frostbolt", "Stabbington", "Healbot", "Chargeboy", "Arrowhead" }
local TEST_CLASSES = { "MAGE", "ROGUE", "PRIEST", "WARRIOR", "HUNTER" }
local testCount = 0

local function AddSummonRequest(name, guid)
	local short = ShortName(name)
	for _, r in ipairs(requests) do
		if r.short == short then return end -- already queued, keep their place in line
	end
	local unit = FindGroupUnit(short)
	if unit then
		local ok, inRange, checked = pcall(UnitInRange, unit)
		if ok and not IsSecret(inRange) and checked and inRange then return end -- already here
	end
	local class
	if guid and GetPlayerInfoByGUID then
		local ok, _, classFile = pcall(GetPlayerInfoByGUID, guid)
		if ok then class = classFile end
	end
	if not class and unit then class = select(2, UnitClass(unit)) end
	requests[#requests + 1] = { name = name, short = short, class = class, time = GetTime(), wasGrouped = unit ~= nil }

	if db.summonSound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.TELL_MESSAGE) or 3081, "SFX") end
	if db.summonPopup and not sumWin:IsShown() then
		summonWantShow = true
		sumWin.autoShown = true
	end
	if InCombatLockdown() then
		Print(short .. " asked for a summon (the window updates when combat ends).")
	end
	UpdateSummonWindow()
end
ns.AddSummonRequest = AddSummonRequest

function ns.AddTestSummonRequest()
	if InCombatLockdown() then Print("Can't change the summon list in combat.") return end
	testCount = testCount % #TEST_NAMES + 1
	local name = TEST_NAMES[testCount]
	for _, r in ipairs(requests) do
		if r.short == name then Print(name .. " is already in the list.") return end
	end
	requests[#requests + 1] = { name = name, short = name, class = TEST_CLASSES[testCount], time = GetTime(), test = true }
	if db.summonSound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.TELL_MESSAGE) or 3081, "SFX") end
	summonWantShow = true
	UpdateSummonWindow()
end

-- Arrivals: anyone in the list who is now within range has been summoned (or walked).
local function CheckSummonArrivals()
	if not db or #requests == 0 then return end
	local changed = false
	for i = #requests, 1, -1 do
		local r = requests[i]
		local unit = FindGroupUnit(r.short)
		if unit then
			local ok, inRange, checked = pcall(UnitInRange, unit)
			if ok and not IsSecret(inRange) and checked and inRange then
				table.remove(requests, i)
				changed = true
			end
		elseif r.wasGrouped and not r.test then
			table.remove(requests, i) -- left the group
			changed = true
		end
	end
	if changed then
		UpdateSummonWindow()
	elseif sumWin:IsShown() then
		for _, row in ipairs(summonRows) do
			if row.req then row.ageText:SetText(AgeText(row.req.time)) end
		end
	end
end
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(2, CheckSummonArrivals) end

-- ---- Healthstone on trade ------------------------------------------------------
local HEALTHSTONE_IDS = {}
for _, id in ipairs({ 5512, 5511, 5509, 5510, 9421, 19004, 19005, 19006, 19007, 19008, 19009, 19010, 19011, 19012, 19013, 22103, 22104, 22105, 36889, 36890, 36891, 36892, 36893, 36894 }) do
	HEALTHSTONE_IDS[id] = true
end
local inTradePass, tradeBlocked = false, false

local function FindHealthstone()
	for bag = 0, MAX_BAG do
		for slot = 1, (GetNumSlots(bag) or 0) do
			local id = GetSlotItemID(bag, slot)
			if id then
				local isStone = HEALTHSTONE_IDS[id]
				if not isStone and CC.GetContainerItemLink then
					local link = CC.GetContainerItemLink(bag, slot)
					isStone = link and link:find("Healthstone", 1, true) ~= nil
				end
				if isStone then return bag, slot end
			end
		end
	end
end

local function OfferHealthstone()
	if not db or not db.tradeHealthstone or tradeBlocked then return end
	if not (TradeFrame and TradeFrame:IsShown()) then return end
	if db.tradeGroupOnly and not (UnitInParty("NPC") or UnitInRaid("NPC")) then return end
	if GetCursorInfo() then return end
	local bag, slot = FindHealthstone()
	if not bag then return end
	local tradeSlot
	for i = 1, 6 do
		if not GetTradePlayerItemInfo(i) then tradeSlot = i break end
	end
	if not tradeSlot then return end
	inTradePass = true
	local ok, err = pcall(function()
		PickupSlot(bag, slot)
		ClickTradeButton(tradeSlot)
	end)
	inTradePass = false
	if GetCursorInfo() then ClearCursor() end
	report["healthstone trade"] = ok and "placed" or ("error: " .. tostring(err))
end

-- Ranks of Create Healthstone, newest first. Casting by name uses the best one you know,
-- so the list is only needed to find out whether you know the spell at all, and its name.
local HEALTHSTONE_SPELLS = { 47878, 47871, 27230, 11730, 11729, 5699, 6202, 6201 }
local makeButton

local function CreateHealthstoneName()
	for _, id in ipairs(HEALTHSTONE_SPELLS) do
		local known = IsSpellKnown and IsSpellKnown(id)
		if known then
			local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id))
				or (GetSpellInfo and GetSpellInfo(id))
			if type(name) == "string" and name ~= "" then return name end
		end
	end
end

local function EnsureMakeButton()
	if makeButton or InCombatLockdown() or not TradeFrame then return end
	local spell = CreateHealthstoneName()
	if not spell then return end
	local made
	for _, tmpl in ipairs({ "SecureActionButtonTemplate,UIPanelButtonTemplate", "SecureActionButtonTemplate" }) do
		local ok, b = pcall(CreateFrame, "Button", "ShardGridMakeHealthstone", TradeFrame, tmpl)
		if ok and b then made = b report["healthstone button"] = tmpl break end
	end
	if not made then return end
	made:SetSize(150, 22)
	made:SetPoint("BOTTOMLEFT", TradeFrame, "BOTTOMLEFT", 20, 14)
	made:SetAttribute("type", "spell")
	made:SetAttribute("spell", spell)
	if made.SetText then made:SetText(spell) end
	made:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(spell, 1, 1, 1)
		GameTooltip:AddLine("You have no Healthstone to trade. This casts it for you, using one Soul Shard.", nil, nil, nil, true)
		local total = lastStats and (lastStats.inSoul + lastStats.outside) or 0
		if total <= 0 then GameTooltip:AddLine("You have no Soul Shards.", 1, 0.3, 0.3) end
		GameTooltip:Show()
	end)
	made:SetScript("OnLeave", function() GameTooltip:Hide() end)
	made:Hide()
	makeButton = made
end

-- Shown only while a trade is open and you have nothing to give, so it disappears by itself
-- once the stone exists (and the auto-offer above puts it straight into the trade).
function ns.UpdateMakeButton()
	if not db then return end
	if InCombatLockdown() then return end -- a secure button cannot be shown or hidden in combat
	EnsureMakeButton()
	if not makeButton then return end
	local want = db.tradeCreate and TradeFrame and TradeFrame:IsShown() and not FindHealthstone()
	makeButton:SetShown(want and true or false)
end

function ns.OnAddonActionBlocked(what)
	if inTradePass then
		tradeBlocked = true
		Print("|cffff4040this client doesn't let addons place items in the trade window.|r Healthstone auto-trade is off for this session.")
		return true
	end
	if inHardwarePass then passBlocked = true end
end

-- ---- events ----------------------------------------------------------------------
local sumEvents = CreateFrame("Frame")
for _, ev in ipairs({ "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
	"CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER",
	"PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "GROUP_ROSTER_UPDATE", "TRADE_SHOW", "TRADE_CLOSED", "PLAYER_LOGIN",
	"UNIT_SPELLCAST_SENT" }) do
	pcall(sumEvents.RegisterEvent, sumEvents, ev)
end
sumEvents:SetScript("OnEvent", function(_, event, text, sender, ...)
	if not db then return end
	if event == "UNIT_SPELLCAST_SENT" then
		-- args: unit, target name, castGUID, spellID
		local unit, target, _, spellID = text, sender, ...
		if unit == "player" and spellID == SUMMON_SPELL_ID and type(target) == "string" and target ~= "" then
			ns.SummonMessagesFor(target)
		end
		return
	end
	if event == "PLAYER_REGEN_DISABLED" then
		UpdateCombatBanner(true)
	elseif event == "PLAYER_REGEN_ENABLED" then
		UpdateCombatBanner(false)
		ns.UpdateSummonButton()
		if summonDirty then UpdateSummonWindow() end
	elseif event == "PLAYER_LOGIN" then
		RestoreSummonPosition()
		UpdateCombatBanner(InCombatLockdown() and true or false)
	elseif event == "GROUP_ROSTER_UPDATE" then
		if #requests > 0 then UpdateSummonWindow() end
	elseif event == "TRADE_SHOW" then
		ns.UpdateMakeButton()
		if C_Timer and C_Timer.After then
			C_Timer.After(0.3, function() OfferHealthstone() ns.UpdateMakeButton() end)
		else
			OfferHealthstone()
		end
	elseif event == "TRADE_CLOSED" then
		ns.UpdateMakeButton()
	else
		if not db.summonEnabled then return end
		if select(2, UnitClass("player")) ~= "WARLOCK" then return end
		if IsSecret(text) or IsSecret(sender) or type(text) ~= "string" or type(sender) ~= "string" then return end
		if ShortName(sender) == UnitName("player") then return end
		if IsSummonRequest(text) then
			if event == "CHAT_MSG_WHISPER" and not db.summonWhisperAny and not FindGroupUnit(ShortName(sender)) then
				return -- stranger whispering; they need to be in the group to be summoned anyway
			end
			local guid = select(10, ...) -- 12th event argument
			AddSummonRequest(sender, type(guid) == "string" and guid or nil)
		end
	end
end)

ns.SetStage("summon button frame")
-- ------------------------------------------------------------------
-- Floating summon button: click it after clicking (or while hovering) a party/raid frame.
-- The secure button is fixed at load, so nothing needs changing in combat; a drag strip
-- above it moves the pair when the frames are unlocked.
-- ------------------------------------------------------------------
local msHolder = CreateFrame("Frame", "ShardGridSummonButton", UIParent)
msHolder:SetMovable(true)
msHolder:SetClampedToScreen(true)
msHolder:EnableMouse(true)
msHolder:RegisterForDrag("LeftButton")
msHolder:Hide()

-- While the frames are unlocked this sits over the button: it takes the clicks, so the
-- button can be dragged without casting. Locking the frames hands the clicks back.
local msMover = CreateFrame("Frame", nil, msHolder)
msMover:SetAllPoints()
msMover:SetFrameLevel(msHolder:GetFrameLevel() + 20)
msMover:EnableMouse(true)
msMover:RegisterForDrag("LeftButton")
msMover:Hide()

msMover.tint = msMover:CreateTexture(nil, "OVERLAY")
msMover.tint:SetAllPoints()
msMover.tint:SetColorTexture(0.72, 0.35, 1, 0.25)
msMover.icon = msMover:CreateTexture(nil, "OVERLAY")
msMover.icon:SetSize(16, 16)
msMover.icon:SetPoint("CENTER")
msMover.icon:SetTexture("Interface\\Buttons\\UI-RotationRight-Button-Up")

msMover:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Summon button (unlocked)", 1, 1, 1)
	GameTooltip:AddLine("Drag to move it. Tick |cffffffffLock position|r in the options to use it for summoning.", nil, nil, nil, true)
	GameTooltip:Show()
end)
msMover:SetScript("OnLeave", function() GameTooltip:Hide() end)
msMover:SetScript("OnDragStart", function() msHolder:StartMoving() end)
msMover:SetScript("OnDragStop", function()
	msHolder:StopMovingOrSizing()
	local x, y = msHolder:GetCenter()
	if x and y and db then db.msX, db.msY = x, y end
end)

local msBtn
do
	local ok, b = pcall(CreateFrame, "Button", "ShardGridSummonAction", msHolder, "SecureActionButtonTemplate")
	msBtn = (ok and b) or CreateFrame("Button", "ShardGridSummonAction", msHolder)
	report["summon button"] = (ok and b) and "ok" or "insecure fallback"
end
msBtn:SetAllPoints()
msBtn:RegisterForClicks("AnyUp", "AnyDown")

-- Built like an action bar slot: icon inset, the slot's own metal frame over it.
msBtn.icon = msBtn:CreateTexture(nil, "ARTWORK")
msBtn.icon:SetAllPoints()
msBtn.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)

msBtn.slot = msBtn:CreateTexture(nil, "OVERLAY")
msBtn.slot:SetPoint("CENTER")
msBtn.slot:SetTexture("Interface\\Buttons\\UI-Quickslot2")

msBtn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
msBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

msBtn.label = msBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
msBtn.label:SetPoint("TOP", msBtn, "BOTTOM", 0, -2)
msBtn.label:SetText("Summon")
msBtn.label:SetShadowOffset(1, -1)

msBtn.count = msBtn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
msBtn.count:SetPoint("BOTTOMRIGHT", -3, 3)

-- Dim the button when there is nobody to summon, like an out of range action.
local function ManualUnitCheck() end

-- The unit the click will act on: whatever you are hovering, else your target.
local function ManualUnit()
	if UnitExists("mouseover") and UnitIsPlayer("mouseover") and UnitIsFriend("player", "mouseover") then return "mouseover" end
	if UnitExists("target") and UnitIsPlayer("target") and UnitIsFriend("player", "target") then return "target" end
end

local function ManualName(unit)
	if not unit then return end
	local name, realm = UnitName(unit)
	if not name then return end
	if realm and realm ~= "" then return name .. "-" .. realm end
	return name
end

msBtn:SetScript("PostClick", function(_, _, down)
	local useDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") or false
	if (down and true or false) ~= (useDown and true or false) then return end
	-- The messages are sent from UNIT_SPELLCAST_SENT, whichever of these actually cast.
	if not ManualUnit() and not msBtn.waitingFor then
		Print("Nobody to summon. Target a party or raid member, hover one, or wait for a summon request.")
	end
end)
msBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Summon", 1, 1, 1)
	local name = ManualName(ManualUnit())
	if name then
		GameTooltip:AddLine(("Casts %s on %s, whispers them and tells the group."):format(SummonSpellName(), ShortName(name)), nil, nil, nil, true)
	elseif self.waitingFor then
		GameTooltip:AddLine(("Nobody targeted, so this summons %s, who has been waiting longest."):format(self.waitingFor), nil, nil, nil, true)
	else
		GameTooltip:AddLine("Target or hover a party or raid member and click to summon them.", nil, nil, nil, true)
		GameTooltip:AddLine("With nobody targeted it summons whoever has been waiting longest in the request list.", 0.7, 0.7, 0.7, true)
	end
	if not (db and db.locked) then GameTooltip:AddLine("Drag the bar above to move.", 0.5, 0.5, 0.5) end
	GameTooltip:Show()
end)
msBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

msHolder:SetScript("OnDragStart", function(self)
	if db and not db.locked then self:StartMoving() end
end)
msHolder:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local x, y = self:GetCenter()
	if x and y and db then db.msX, db.msY = x, y end
end)

function ns.UpdateSummonButton()
	if not db then return end
	if InCombatLockdown() then return end -- secure attributes are locked in combat
	local spell = SummonSpellName()
	msBtn:SetAttribute("type", "macro")
	local waiting
	for _, req in ipairs(requests) do
		if not req.test and req.unit then waiting = req.short break end
	end
	msBtn.waitingFor = waiting
	local clauses = "[@mouseover,help,exists,nodead][@target,help,exists,nodead]"
	if waiting then clauses = clauses .. "[@" .. waiting .. ",help,exists,nodead]" end
	msBtn:SetAttribute("macrotext", "/cast " .. clauses .. " " .. spell)
	local icon = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(SUMMON_SPELL_ID))
		or (GetSpellTexture and GetSpellTexture(SUMMON_SPELL_ID))
		or SHARD_ICON
	msBtn.icon:SetTexture(icon)

	local size = db.summonButtonSize
	msHolder:SetSize(size, size)
	msBtn.slot:SetSize(size * 1.85, size * 1.85) -- the slot art's opening matches the button
	msMover:SetShown(not db.locked)
	msHolder:ClearAllPoints()
	if db.msX and db.msY then
		msHolder:SetPoint("CENTER", UIParent, "BOTTOMLEFT", db.msX, db.msY)
	else
		msHolder:SetPoint("CENTER", UIParent, "CENTER", 220, -120)
	end
	local total = lastStats and (lastStats.inSoul + lastStats.outside) or 0
	msBtn.count:SetText(total > 0 and total or "")
	msBtn.icon:SetDesaturated(total == 0)
	msHolder:SetShown(db.summonButton and select(2, UnitClass("player")) == "WARLOCK")
end

ns.SetStage("soulstone window")
-- ------------------------------------------------------------------
-- Soulstone tracker: who in the group is carrying a soulstone, for how long, from whom.
-- ------------------------------------------------------------------
local STONE = {
	NAME = "Soulstone Resurrection",
	IDS = { 20707, 20762, 20763, 20764, 20765, 27239, 47883 },
	ROW_H = 40,
	BAR_H = 26,
	TOP_H = 12, -- the line above each bar, for who cast it
	W = 250,
	MAX_ROWS = 10,
}

local stones = {}        -- ordered list of { name, short, class, caster, expires, duration }

local function StoneAura(unit)
	for i = 1, 40 do
		local name, icon, _, _, duration, expires, source, spellId
		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			local a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
			if not a then return end
			name, icon, duration, expires, source, spellId = a.name, a.icon, a.duration, a.expirationTime, a.sourceUnit, a.spellId
		elseif UnitAura then
			name, icon, _, _, duration, expires, source, _, _, spellId = UnitAura(unit, i, "HELPFUL")
			if not name then return end
		else
			return
		end
		if type(name) ~= "string" then return end
		local match = name == STONE.NAME
		if not match and spellId then
			for _, id in ipairs(STONE.IDS) do
				if spellId == id then match = true break end
			end
		end
		if match then
			return duration, expires, source, icon
		end
	end
end

local function ScanStones()
	local found, order = {}, {}
	local units = { "player" }
	if IsInRaid and IsInRaid() then
		for i = 1, 40 do units[#units + 1] = "raid" .. i end
	elseif IsInGroup and IsInGroup() then
		for i = 1, 4 do units[#units + 1] = "party" .. i end
	end
	for _, unit in ipairs(units) do
		if UnitExists(unit) then
			local ok, duration, expires, source, icon = pcall(StoneAura, unit)
			if ok and duration and not IsSecret(duration) then
				local name = ManualName(unit) or UnitName(unit)
				if name and not found[name] then
					local caster = source and UnitName(source)
					found[name] = true
					order[#order + 1] = {
						name = name, short = ShortName(name),
						class = select(2, UnitClass(unit)),
						caster = caster, duration = duration, expires = expires, icon = icon,
					}
				end
			end
		end
	end
	table.sort(order, function(a, b) return (a.expires or 0) > (b.expires or 0) end)
	return order
end

local stoneWin = CreatePanel("ShardGridStones", true)
stoneWin:SetFrameStrata("MEDIUM")
stoneWin:SetWidth(STONE.W)
stoneWin:Hide()
stoneWin.sgTitle:SetText("Soulstones")

local stoneContent = CreateFrame("Frame", nil, stoneWin)
stoneContent:SetPoint("TOPLEFT", INSET.left, -INSET.top)
stoneContent:SetPoint("BOTTOMRIGHT", -INSET.right, INSET.bottom)

local stoneEmpty = stoneContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
stoneEmpty:SetPoint("TOP", 0, -10)
stoneEmpty:SetText("Nobody has a soulstone")

stoneWin:SetScript("OnDragStart", function(self) if not (db and db.locked) then self:StartMoving() end end)
stoneWin:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local left, top = self:GetLeft(), self:GetTop()
	if left and top and db then db.stoneX, db.stoneY = left, top end
end)

local function RestoreStonePosition()
	stoneWin:ClearAllPoints()
	if db and db.stoneX and db.stoneY then
		stoneWin:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", db.stoneX, db.stoneY)
	else
		stoneWin:SetPoint("TOPLEFT", UIParent, "CENTER", 160, -60)
	end
end

ns.SetStage("soulstone rows")
local stoneRows = {}

local ApplyRowArt -- defined below, used when a row is built

-- Bar art. The defaults are the interface's own bar, border and cast spark; each piece can
-- be replaced with "/shards bar grab" by pointing at any bar the game draws itself.
local BAR_DEFAULTS -- worked out on first use

local function BarArt(piece)
	local chosen = db and db["bar" .. piece:gsub("^%l", string.upper)]
	if chosen then return chosen end
	-- A missing atlas is not cached, in case the art is not ready the first time we look.
	if not BAR_DEFAULTS or BAR_DEFAULTS.provisional then
		if HasAtlas("UI-HUD-CoolDownManager-Bar") then
			BAR_DEFAULTS = {
				fill   = "UI-HUD-CoolDownManager-Bar",
				bg     = "UI-HUD-CoolDownManager-Bar-BG",
				spark  = "UI-HUD-CoolDownManager-Bar-Pip",
				icon   = "UI-HUD-CoolDownManager-IconOverlay",
				mask   = "UI-HUD-CoolDownManager-Mask",
				shadow = "UI-HUD-CoolDownManager-IconShadow",
				border = "none", -- the background art already carries the frame
			}
			report["bar art"] = "the client's cooldown bars"
		else
			BAR_DEFAULTS = {
				fill   = "Interface\\TargetingFrame\\UI-StatusBar",
				spark  = "Interface\\CastingBar\\UI-CastingBar-Spark",
				border = "Interface\\Tooltips\\UI-Tooltip-Border",
				bg     = "none",
				icon   = "none",
				mask   = "none",
				shadow = "none",
				provisional = true,
			}
			report["bar art"] = "fallback (no cooldown bar art on this client)"
		end
	end
	return BAR_DEFAULTS[piece]
end

local function SetArt(tex, art, blend)
	if not art or art == "none" then return end
	tex:SetTexCoord(0, 1, 0, 1)
	if HasAtlas(art) then tex:SetAtlas(art) else tex:SetTexture(art) end
	if blend then tex:SetBlendMode(blend) end
end

-- The bar's frame is a backdrop, so the art stretches with the bar like the game's own do.
local function AddBarBorder(bar)
	local ok, frame = pcall(CreateFrame, "Frame", nil, bar, "BackdropTemplate")
	if not ok or not frame or not frame.SetBackdrop then return end
	frame:SetPoint("TOPLEFT", -3, 3)
	frame:SetPoint("BOTTOMRIGHT", 3, -3)
	frame:SetFrameLevel(bar:GetFrameLevel() + 1)
	bar.borderFrame = frame
	return frame
end

local function ApplyBorder(bar)
	local frame = rawget(bar, "borderFrame")
	if type(frame) ~= "table" then return end
	if not frame or not frame.SetBackdrop then return end
	local art = BarArt("border")
	if art == "none" then frame:Hide() return end
	frame:Show()
	frame:SetBackdrop({ edgeFile = art, edgeSize = 10 })
	frame:SetBackdropBorderColor(1, 1, 1, 0.9)
end

function ApplyRowArt(row)
	row.fill:SetStatusBarTexture(BarArt("fill"))

	local bg = BarArt("bg")
	if bg and bg ~= "none" then
		row.bg:Show()
		row.bg:SetVertexColor(1, 1, 1)
		SetArt(row.bg, bg)
	else
		row.bg:Show()
		row.bg:SetColorTexture(0.05, 0.05, 0.05, 0.85)
	end

	local spark = BarArt("spark")
	SetArt(row.spark, spark, "ADD")
	local info = spark and spark ~= "none" and C_Texture and C_Texture.GetAtlasInfo
		and C_Texture.GetAtlasInfo(spark)
	-- The pip spans the whole bar, not just the inset fill, the way the client draws it.
	local h = row.bar:GetHeight()
	if type(h) ~= "number" or h <= 0 then h = STONE.BAR_H end
	if info and type(info.width) == "number" and type(info.height) == "number" and info.height > 0 then
		row.spark:SetSize(h * (info.width / info.height), h)
	else
		row.spark:SetSize(8, h)
	end

	local mask = BarArt("mask")
	if row.iconMask and mask and mask ~= "none" and HasAtlas(mask) then
		row.iconMask:SetAtlas(mask)
		pcall(row.icon.AddMaskTexture, row.icon, row.iconMask)
		row.icon:SetTexCoord(0, 1, 0, 1) -- the mask trims it now
	else
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end

	local shadow = BarArt("shadow")
	if shadow and shadow ~= "none" and HasAtlas(shadow) then
		row.iconShadow:Show()
		SetArt(row.iconShadow, shadow)
	else
		row.iconShadow:Hide()
	end

	local overlay = BarArt("icon")
	if overlay and overlay ~= "none" then
		row.iconOverlay:Show()
		SetArt(row.iconOverlay, overlay)
	else
		row.iconOverlay:Hide()
	end

	ApplyBorder(row.fill)
end

function ns.ApplyBarArt()
	for _, row in ipairs(stoneRows) do ApplyRowArt(row) end
end

-- Copy art from whatever bar you are pointing at.
function ns.GrabBarArt()
	local focus
	if GetMouseFoci then
		local list = GetMouseFoci()
		focus = list and list[1]
	elseif GetMouseFocus then
		focus = GetMouseFocus()
	end
	if not focus or focus == WorldFrame then
		Print("Point at a bar first. Run |cffffffff/shards bar grab|r, then hover the bar you want within 4 seconds.")
		return
	end
	local found, layers = {}, {}
	local function Add(name, layer)
		if type(name) ~= "string" or found[name] then return end
		found[name] = true
		found[#found + 1] = name
		layers[#found] = layer
	end
	local function Collect(f, depth)
		if not f or depth > 3 then return end
		if f.GetStatusBarTexture then
			local ok, tex = pcall(function() return f:GetStatusBarTexture() end)
			if ok and tex then
				local a = (tex.GetAtlas and tex:GetAtlas()) or (tex.GetTexture and tex:GetTexture())
				Add(a, "bar fill")
			end
		end
		if f.GetRegions then
			for _, region in ipairs({ f:GetRegions() }) do
				local kind = region.GetObjectType and region:GetObjectType()
				if kind == "Texture" or kind == "MaskTexture" then
					local ok, atlas = pcall(function() return region.GetAtlas and region:GetAtlas() end)
					local name = ok and atlas or nil
					if not name then
						local ok2, file = pcall(function() return region.GetTexture and region:GetTexture() end)
						if ok2 then name = file end
					end
					local layer = (kind == "MaskTexture") and "mask"
						or (region.GetDrawLayer and region:GetDrawLayer() or "?")
					Add(name, layer)
				end
			end
		end
		if f.GetChildren then
			for _, child in ipairs({ f:GetChildren() }) do Collect(child, depth + 1) end
		end
	end
	Collect(focus, 1)
	if #found == 0 then
		Print("Nothing to copy from that frame.")
		return
	end
	ns.grabbedBar = found
	local function Size(f)
		local w, h = f.GetWidth and f:GetWidth(), f.GetHeight and f:GetHeight()
		if type(w) ~= "number" or type(h) ~= "number" then return "?" end
		return ("%.0f x %.0f"):format(w, h)
	end
	Print("That bar measures " .. Size(focus) .. ".")
	if focus.GetChildren then
		for _, child in ipairs({ focus:GetChildren() }) do
			if child.IsShown and child:IsShown() then
				Print("  a part of it: " .. Size(child))
			end
		end
	end
	Print("Art on that bar:")
	for i, name in ipairs(found) do
		Print(("  %d |cff9d9d9d[%s]|r %s"):format(i, tostring(layers[i]), name))
	end
	Print("Assign with |cffffffff/shards bar fill N|r, |cffffffffbar border N|r or |cffffffffbar spark N|r.")
end

function ns.SetBarArt(piece, index)
	local art = (index == 0) and "none" or (ns.grabbedBar and ns.grabbedBar[index])
	if not art then
		Print("Run /shards bar grab first, then give the number from the list.")
		return
	end
	db["bar" .. piece:gsub("^%l", string.upper)] = art
	ns.ApplyBarArt()
	Print(piece .. ": " .. art)
end

local function GetStoneRow(i)
	local row = stoneRows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, stoneContent)
	row:SetHeight(STONE.ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * STONE.ROW_H)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * STONE.ROW_H)

	row.casterText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.casterText:SetPoint("TOPRIGHT", -4, -1)
	row.casterText:SetJustifyH("RIGHT")

	-- The bar area: everything below the caster line. The art is laid out inside it the way
	-- the client lays out its own cooldown bars, offsets included.
	row.bar = CreateFrame("Frame", nil, row)
	row.bar:SetPoint("TOPLEFT", 0, -STONE.TOP_H)
	row.bar:SetPoint("TOPRIGHT", 0, -STONE.TOP_H)
	row.bar:SetHeight(STONE.BAR_H)

	row.iconFrame = CreateFrame("Frame", nil, row.bar)
	row.iconFrame:SetPoint("TOPLEFT", 2, 0)
	row.iconFrame:SetPoint("BOTTOMLEFT", 2, 0)
	row.iconFrame:SetWidth(STONE.BAR_H)

	if row.iconFrame.CreateMaskTexture then
		local ok, mask = pcall(row.iconFrame.CreateMaskTexture, row.iconFrame, nil, "ARTWORK")
		if ok and mask then
			mask:SetPoint("TOPLEFT", 0, -1)
			mask:SetPoint("BOTTOMRIGHT", 0, 0)
			row.iconMask = mask
		end
	end

	local over = STONE.BAR_H * (7 / 34) -- the client's own bars overhang 7px at 34px tall
	row.iconShadow = row.iconFrame:CreateTexture(nil, "BACKGROUND")
	row.iconShadow:SetPoint("TOPLEFT", -over, over * 0.86)
	row.iconShadow:SetPoint("BOTTOMRIGHT", over, -over)

	row.icon = row.iconFrame:CreateTexture(nil, "ARTWORK")
	row.icon:SetAllPoints()

	row.iconOverlay = row.iconFrame:CreateTexture(nil, "OVERLAY")
	row.iconOverlay:SetPoint("TOPLEFT", -over, over * 0.86)
	row.iconOverlay:SetPoint("BOTTOMRIGHT", over, -over)

	row.fill = CreateFrame("StatusBar", nil, row.bar)
	row.fill:SetPoint("TOPLEFT", row.iconFrame, "TOPRIGHT", 4, -4)
	row.fill:SetPoint("BOTTOMRIGHT", row.bar, "BOTTOMRIGHT", -4, 4)
	row.fill:SetMinMaxValues(0, 1)

	row.bg = row.bar:CreateTexture(nil, "BACKGROUND")
	row.bg:SetPoint("LEFT", row.fill, "LEFT", -2, -2)
	row.bg:SetPoint("RIGHT", row.fill, "RIGHT", 6, -2)
	row.bg:SetHeight(STONE.BAR_H * 1.06)

	AddBarBorder(row.fill)

	row.spark = row.fill:CreateTexture(nil, "OVERLAY")

	-- Text sits above the fill, so the timer is never hidden by it.
	row.nameText = row.fill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.nameText:SetPoint("LEFT", row.fill, "LEFT", 5, 0)
	row.nameText:SetJustifyH("LEFT")
	row.timeText = row.fill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.timeText:SetPoint("RIGHT", row.fill, "RIGHT", -5, 0)
	row.nameText:SetPoint("RIGHT", row.timeText, "LEFT", -6, 0)
	row.nameText:SetWordWrap(false)

	stoneRows[i] = row
	ApplyRowArt(row)
	return row
end

local function TimeLeft(t)
	if t < 0 then t = 0 end
	if t >= 60 then return ("%d:%02d"):format(math.floor(t / 60), math.floor(t % 60)) end
	return ("%ds"):format(math.floor(t))
end

local announcedStones = {}

local function AnnounceNewStones(previous)
	if not db.stoneAnnounce then return end
	local channel = GroupChannel()
	if not channel then return end
	local me = UnitName("player")
	local had = {}
	for _, st in ipairs(previous) do had[st.short] = st.expires end
	for _, st in ipairs(stones) do
		local caster = st.caster and ShortName(st.caster)
		local fresh = had[st.short] ~= st.expires
		local key = st.short .. ":" .. tostring(st.expires)
		if fresh and caster == me and not announcedStones[key] then
			announcedStones[key] = true
			local target = (st.short == me) and "myself" or st.short
			local mins = math.floor((st.duration or 0) / 60)
			local lasts = (mins >= 1) and (mins .. " min") or TimeLeft(st.duration or 0)
			SendChat(("Soulstone on %s, lasts %s."):format(target, lasts), channel)
		end
	end
end

function ns.UpdateStones(rescan)
	if not db then return end
	if rescan then
		local previous = stones
		stones = ScanStones()
		AnnounceNewStones(previous)
	end
	local grouped = IsInGroup and IsInGroup()
	if not db.stoneEnabled or (db.stoneSoloHide and not grouped and #stones == 0) then
		stoneWin:Hide()
		return
	end

	local now = GetTime()
	local n = math.min(#stones, STONE.MAX_ROWS)
	for i = 1, n do
		local st, row = stones[i], GetStoneRow(i)
		local left = (st.expires or 0) - now
		local frac = (st.duration and st.duration > 0) and math.max(0, math.min(1, left / st.duration)) or 1
		local color = RAID_CLASS_COLORS and st.class and RAID_CLASS_COLORS[st.class]
		row.nameText:SetText(("|c%s%s|r"):format(color and color.colorStr or "ffffffff", st.short))
		local caster = st.caster and ShortName(st.caster)
		row.casterText:SetText(caster and ("from " .. caster) or "")
		row.timeText:SetText(TimeLeft(left))
		row.icon:SetTexture(st.icon or "Interface\\Icons\\Spell_Shadow_SoulGem")
		row.fill:SetValue(frac)
		-- purple while comfortable, red in the last minute
		if left <= 60 then row.fill:SetStatusBarColor(0.85, 0.15, 0.15) else row.fill:SetStatusBarColor(0.58, 0.26, 0.9) end
		local width = row.fill:GetWidth() or 0
		row.spark:ClearAllPoints()
		row.spark:SetPoint("CENTER", row.fill, "LEFT", width * frac, 0)
		row.spark:SetShown(frac > 0.01 and frac < 0.99)
		row:Show()
	end
	for i = n + 1, #stoneRows do stoneRows[i]:Hide() end
	stoneEmpty:SetShown(n == 0)

	stoneWin.sgTitle:SetText(n > 0 and ("Soulstones (" .. n .. ")") or "Soulstones")
	stoneWin:SetHeight(math.max(MIN_H, INSET.top + math.max(1, n) * STONE.ROW_H + 6 + INSET.bottom))
	if not stoneWin:IsShown() then
		RestoreStonePosition()
		stoneWin:Show()
	end
end

function ns.ToggleStoneWindow()
	if stoneWin:IsShown() then
		stoneWin:Hide()
	else
		db.stoneEnabled = true
		RestoreStonePosition()
		ns.UpdateStones(true)
		stoneWin:Show()
	end
end

-- Rescan on aura changes, tick the bars once a second. Each registration is staged so that
-- if the client refuses one, the refusal log names it exactly.
local stoneEvents = CreateFrame("Frame")
for _, ev in ipairs({ "UNIT_AURA", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
	ns.SetStage("soulstone event " .. ev)
	pcall(stoneEvents.RegisterEvent, stoneEvents, ev)
end
ns.SetStage("soulstone window")
stoneEvents:SetScript("OnEvent", function(_, event)
	if not db or not db.stoneEnabled then return end
	if event == "PLAYER_ENTERING_WORLD" and C_Timer and C_Timer.After then
		for _, delay in ipairs({ 1, 3, 6 }) do
			C_Timer.After(delay, function() if db and db.stoneEnabled then ns.UpdateStones(true) end end)
		end
	end
	local was = #stones
	ns.UpdateStones(true)
	if db.stonePopup and #stones > was then
		RestoreStonePosition()
		stoneWin:Show()
	end
end)
ns.SetStage("soulstone ticker")
if C_Timer and C_Timer.NewTicker then
	local tick = 0
	C_Timer.NewTicker(1, function()
		tick = tick + 1
		-- The bars tick every second; a full rescan every few seconds catches anything whose
		-- event was missed, including everything already up when the interface reloaded.
		if tick % 5 == 0 then
			if db and db.stoneEnabled then ns.UpdateStones(true) end
		elseif stoneWin:IsShown() then
			ns.UpdateStones(false)
		end
	end)
end
ns.SetStage("config window")

-- ------------------------------------------------------------------
-- Config window
-- ------------------------------------------------------------------
local config
local syncers = {}

-- Every control is positioned through Place(), which remembers where it was put. When a text
-- box is dragged taller, Relayout() shifts everything below it in that column by the extra
-- height, instead of the box growing over its neighbours.
local placed = {}   -- column -> ordered list of { obj, points = { {point, x, y} } }
local boxes = {}    -- column -> list of { frame, y, base }

local function Place(col, obj, point, x, y)
	local list = placed[col]
	if not list then list = {} placed[col] = list end
	local rec = list[obj]
	if not rec then
		rec = { obj = obj, points = {} }
		list[obj] = rec
		list[#list + 1] = rec
	end
	rec.points[#rec.points + 1] = { point = point, x = x, y = y }
	obj:SetPoint(point, col, point, x, y)
	return obj
end

local function ColumnExtra(col, aboveY)
	local extra = 0
	for _, b in ipairs(boxes[col] or {}) do
		if b.y > aboveY then extra = extra + ((b.frame:GetHeight() or b.base) - b.base) end
	end
	return extra
end

local function Relayout(col)
	for _, rec in ipairs(placed[col] or {}) do
		local first = rec.points[1]
		local shift = ColumnExtra(col, first.y)
		rec.obj:ClearAllPoints()
		for _, pt in ipairs(rec.points) do
			rec.obj:SetPoint(pt.point, col, pt.point, pt.x, pt.y - shift)
		end
	end
	if ns.ResizeOptions then ns.ResizeOptions() end
end
local COL_W = 310
local VIEW_MAX_H = 560  -- taller than this and the standalone window scrolls instead of growing
local CONTENT_W, CONTENT_H = COL_W * 2 + 22, 660 -- two columns plus the scrollbar gutter

-- Move the options controls into a host frame (standalone window or the game's Options page).
-- The options are a scrolling page that moves between the standalone window and the
-- game's Options panel. Only the viewport changes size; the controls never shrink.
function ns.HostOptions(host, point, x, y, scale, w, h)
	local view = ns.optionsView
	if not view then return end
	view:SetParent(host)
	view:ClearAllPoints()
	view:SetPoint(point, host, point, x, y)
	view:SetScale(scale or 1)
	if w and h then view:SetSize(w, h) end
	view:Show()
	if ns.UpdateOptionsScroll then ns.UpdateOptionsScroll() end
end

function ns.SyncConfig()
	if not config then return end
	if not (config:IsShown() or (ns.optionsPage and ns.optionsPage:IsVisible())) then return end
	for _, fn in ipairs(syncers) do fn() end
end

local function AddHeader(parent, y, text)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	Place(parent, fs, "TOPLEFT", 16, y)
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
	Place(parent, fs, "TOPLEFT", 22, y)
	fs:SetText(label)

	local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	Place(parent, value, "TOPRIGHT", -20, y)

	local sl = CreateSlider(parent)
	Place(parent, sl, "TOPLEFT", 24, y - 16)
	Place(parent, sl, "TOPRIGHT", -22, y - 16)
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
	-- Scroll the options page instead of nudging the value under the cursor.
	sl:EnableMouseWheel(true)
	sl:SetScript("OnMouseWheel", function(_, delta)
		local sc = ns.optionsScrollFrame
		local handler = sc and sc:GetScript("OnMouseWheel")
		if handler then handler(sc, delta) end
	end)
	syncers[#syncers + 1] = Sync
	return sl
end

local TEXTBOX_W, TEXTBOX_H = 252, 46 -- three lines of small text, inside the column

-- Multi-line, word-wrapped edit box bound to a db key; empty text restores the default.
-- Long text wraps and scrolls inside the box instead of running past the window edge.
local function AddTextBox(parent, y, key, default, tipTitle, tipText, width)
	width = width or TEXTBOX_W
	local ok, frame = pcall(CreateFrame, "Frame", nil, parent, "BackdropTemplate")
	frame = (ok and frame) or CreateFrame("Frame", nil, parent)
	local heightKey = "boxH_" .. key
	frame:SetSize(width, (db and db[heightKey]) or TEXTBOX_H)
	Place(parent, frame, "TOPLEFT", 46, y)
	boxes[parent] = boxes[parent] or {}
	boxes[parent][#boxes[parent] + 1] = { frame = frame, y = y, base = TEXTBOX_H }
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0, 0, 0, 0.6)
		frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	end

	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", 7, -6)
	scroll:SetPoint("BOTTOMRIGHT", -7, 6)

	local box = CreateFrame("EditBox", nil, scroll)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject(GameFontHighlightSmall)
	box:SetWidth(width - 14)
	box:SetMaxLetters(400)
	box:SetTextInsets(0, 0, 0, 0)
	scroll:SetScrollChild(box)

	-- Keep the cursor line in view while typing.
	box:SetScript("OnCursorChanged", function(_, _, cy, _, ch)
		local top, bottom = -cy, -cy + ch
		local offset, visible = scroll:GetVerticalScroll(), scroll:GetHeight()
		if top < offset then
			scroll:SetVerticalScroll(top)
		elseif bottom > offset + visible then
			scroll:SetVerticalScroll(bottom - visible)
		end
	end)
	frame:EnableMouse(true)
	frame:SetScript("OnMouseDown", function() box:SetFocus() end)

	local function Commit(self)
		local text = (self:GetText() or ""):gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
		db[key] = (text ~= "" and text ~= default) and text or nil
		self:SetText(db[key] or default)
		self:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
	end
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) -- commits via focus loss
	box:SetScript("OnEditFocusLost", Commit)
	box:SetScript("OnEscapePressed", function(self) self:SetText(db[key] or default) self:ClearFocus() end)
	local function Tip(self)
		GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
		GameTooltip:SetText(tipTitle, 1, 1, 1)
		GameTooltip:AddLine(tipText, nil, nil, nil, not tipText:find(string.char(10), 1, true))
		GameTooltip:Show()
	end
	frame:SetScript("OnEnter", Tip)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	box:SetScript("OnEnter", Tip)
	box:SetScript("OnLeave", function() GameTooltip:Hide() end)
	syncers[#syncers + 1] = function()
		if not box:HasFocus() then
			box:SetText(db[key] or default)
			box:SetCursorPosition(0)
			scroll:SetVerticalScroll(0)
		end
		local saved = db[heightKey]
		if saved and math.abs((frame:GetHeight() or 0) - saved) > 0.5 then
			frame:SetHeight(saved)
			Relayout(parent)
		end
	end

	-- Drag the bottom edge to make the box taller.
	local sizer = CreateFrame("Button", nil, frame)
	sizer:SetSize(width, 6)
	sizer:SetPoint("BOTTOMLEFT", 0, -2)
	sizer:SetFrameLevel(frame:GetFrameLevel() + 5)
	local grab = sizer:CreateTexture(nil, "OVERLAY")
	grab:SetSize(26, 3)
	grab:SetPoint("CENTER")
	grab:SetColorTexture(0.6, 0.6, 0.6, 0.5)
	sizer:SetScript("OnEnter", function()
		grab:SetColorTexture(1, 0.82, 0, 0.9)
		GameTooltip:SetOwner(sizer, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to resize", 1, 1, 1)
		GameTooltip:Show()
	end)
	sizer:SetScript("OnLeave", function()
		grab:SetColorTexture(0.6, 0.6, 0.6, 0.5)
		GameTooltip:Hide()
	end)
	sizer:SetScript("OnMouseDown", function(self)
		local startY = select(2, GetCursorPosition())
		local startH = frame:GetHeight()
		local scale = frame:GetEffectiveScale()
		self:SetScript("OnUpdate", function()
			local dy = (startY - select(2, GetCursorPosition())) / scale
			local h = math.max(TEXTBOX_H, math.min(220, startH + dy))
			if math.abs(h - (frame:GetHeight() or 0)) > 0.5 then
				frame:SetHeight(h)
				box:SetHeight(math.max(h - 12, 12))
				Relayout(parent)
			end
		end)
	end)
	sizer:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
		db[heightKey] = frame:GetHeight()
	end)
	return frame
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
	Place(parent, cb, "TOPLEFT", 18, y)
	-- Own label: the templates disagree about where theirs lives.
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
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
	config:SetSize(CONTENT_W, CONTENT_H + 34)
	config:SetPoint("CENTER")
	config:SetFrameStrata("DIALOG")
	config.sgTitle:SetText("Shard Grid")
	config:SetScript("OnDragStart", config.StartMoving)
	config:SetScript("OnDragStop", config.StopMovingOrSizing)
	config:SetScript("OnShow", function()
		local viewH = math.min(CONTENT_H + 8, VIEW_MAX_H)
		ns.HostOptions(config, "TOPLEFT", 0, -22, 1, CONTENT_W, viewH)
		ns.SyncConfig()
	end)
	config:SetScript("OnHide", function()
		if alertPreview then alertPreview = false Refresh() end
	end)
	config:Hide()
	tinsert(UISpecialFrames, "ShardGridConfig")

	-- A scrolling viewport holding two columns; every control is parented to its column.
	local view, viewTemplate = CreateFrame("Frame", nil, config), nil
	view:SetSize(CONTENT_W, CONTENT_H)
	view:SetPoint("TOPLEFT", 0, -26)
	ns.optionsView = view

	local scroll
	for _, tmpl in ipairs({ "ScrollFrameTemplate", "UIPanelScrollFrameTemplate" }) do
		local ok, f = pcall(CreateFrame, "ScrollFrame", "ShardGridOptionsScroll", view, tmpl)
		if ok and f then scroll, viewTemplate = f, tmpl break end
	end
	if not scroll then scroll = CreateFrame("ScrollFrame", "ShardGridOptionsScroll", view) end
	report["options scroll"] = viewTemplate or "plain (mouse wheel only)"
	ns.optionsScrollFrame = scroll
	scroll:SetPoint("TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", -22, 4)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(CONTENT_W - 26, CONTENT_H)
	scroll:SetScrollChild(content)
	ns.optionsContent = content

	local bar = scroll.ScrollBar or scroll.scrollBar or _G["ShardGridOptionsScrollScrollBar"]
	if type(bar) ~= "table" then bar = nil end
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = math.max(0, (content:GetHeight() or 0) - (self:GetHeight() or 0))
		self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
	end)

	function ns.UpdateOptionsScroll()
		local range = math.max(0, (content:GetHeight() or 0) - (scroll:GetHeight() or 0))
		if bar then
			if bar.SetMinMaxValues then bar:SetMinMaxValues(0, range) end
			bar:SetShown(range > 1)
		end
		if (scroll:GetVerticalScroll() or 0) > range then scroll:SetVerticalScroll(range) end
	end

	local colL = CreateFrame("Frame", nil, content)
	colL:SetPoint("TOPLEFT")
	colL:SetPoint("BOTTOMLEFT")
	colL:SetWidth(COL_W)
	local colR = CreateFrame("Frame", nil, content)
	colR:SetPoint("TOPRIGHT")
	colR:SetPoint("BOTTOMRIGHT")
	colR:SetWidth(COL_W)
	local col = colL
	local lowest = 0

	local y = -34
	AddHeader(col, y, "Display")
	y = y - 22
	AddSlider(col, y, "Grid width (columns)", {
		min = MIN_COLS, max = MAX_COLS, step = 1,
		get = function() return db.cols end,
		set = function(v) db.cols = v Refresh() end,
	})
	y = y - 40
	AddSlider(col, y, "Slot size", {
		min = 12, max = 64, step = 2,
		get = function() return db.size end,
		set = function(v) db.size = v Refresh() end,
	})
	y = y - 40
	AddSlider(col, y, "Scale", {
		min = 50, max = 200, step = 5,
		get = function() return math.floor(db.scale * 100 + 0.5) end,
		set = function(v) SetGridScale(v / 100) Refresh() end,
		format = function(v) return v .. "%" end,
	})
	y = y - 40
	AddCheck(col, y, "Show empty slots",
		function() return db.showEmpty end,
		function(v) db.showEmpty = v Refresh() end,
		"Fills out the grid with empty bag slots, so it keeps the shape of a bag instead of growing and shrinking with your shard count.")
	y = y - 26
	AddSlider(col, y, "Minimum rows", {
		min = 1, max = 8, step = 1,
		get = function() return db.minRows end,
		set = function(v) db.minRows = v Refresh() end,
	})
	y = y - 40
	AddCheck(col, y, "Empty slots first",
		function() return db.reverse end,
		function(v) db.reverse = v Refresh() end,
		"Reverses the order, so free slots sit at the top of the grid and your shards fill it from the bottom.")
	y = y - 26
	AddCheck(col, y, "Animate shards",
		function() return db.animate end,
		function(v)
			db.animate = v
			if not v then ANIM.StopAll() end
		end,
		"A new shard is tossed into its slot, growing as it arrives, and a spent one flashes out of its slot.")
	y = y - 26
	AddCheck(col, y, "Lock position",
		function() return db.locked end,
		function(v) db.locked = v ApplyLock() end,
		"Stops the grid from being dragged and hides the width grip.")
	y = y - 26
	AddCheck(col, y, "Show grid",
		function() return db.shown end,
		function(v) db.shown = v Refresh() end)

	y = y - 26
	AddCheck(col, y, "Show minimap button",
		function() return db.minimapShown end,
		function(v) db.minimapShown = v ns.UpdateMinimapButton() end)

	y = y - 36
	AddHeader(col, y, "Overflow shards")
	y = y - 22
	AddCheck(col, y, "Auto-delete extra shards",
		function() return db.autoDelete end,
		function(v) SetAutoDelete(v) end,
		"Destroys Soul Shards sitting in your normal bags once you hold more than your soul bag capacity plus the allowance below. Shards inside the soul bag are never touched.")
	y = y - 28
	AddSlider(col, y, "Extra shards to keep", {
		min = 0, max = KEEP_MAX, step = 1,
		get = function() return db.keepExtra end,
		set = function(v) db.keepExtra = v Refresh() end,
	})
	y = y - 40
	AddCheck(col, y, "Pause while no soul bag is equipped",
		function() return db.onlyWithBag end,
		function(v) db.onlyWithBag = v Refresh() end,
		"With no soul bag your capacity is 0, so \"extra shards to keep\" becomes your total shard limit. Tick this if you'd rather nothing is deleted while you have no soul bag (e.g. while swapping bags).")
	y = y - 26
	AddCheck(col, y, "Announce deletions in chat",
		function() return db.announce end,
		function(v) db.announce = v end)
	y = y - 26
	AddCheck(col, y, "Delete extras on a key press",
		function() return not db.noKeyListener end,
		function(v) db.noKeyListener = not v ns.ApplyKeyListener() end,
		"The game only lets an addon delete an item during a real key press or click. With this on, Shard Grid watches for your next key press (without taking it). If your client objects to that, untick it and extras are deleted when you click the grid instead.")

	-- status + manual delete sit under the overflow options
	y = y - 30
	local status = colL:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	Place(colL, status, "TOPLEFT", 22, y)
	Place(colL, status, "TOPRIGHT", -18, y)
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
	y = y - 18
	local now = CreateFrame("Button", nil, colL, "UIPanelButtonTemplate")
	now:SetSize(150, 22)
	Place(colL, now, "TOPLEFT", 20, y)
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

	y = y - 40
	AddHeader(col, y, "Healthstones")
	y = y - 22
	AddCheck(col, y, "Offer a Healthstone when a trade opens",
		function() return db.tradeHealthstone end,
		function(v) db.tradeHealthstone = v end,
		"When a trade window opens and you have a Healthstone in your bags, it is placed in the trade for you. You still press Trade yourself.")
	y = y - 26
	AddCheck(col, y, "Only for players in my group",
		function() return db.tradeGroupOnly end,
		function(v) db.tradeGroupOnly = v end,
		"Keeps your Healthstone out of trades with people outside your party or raid.")
	y = y - 26
	AddCheck(col, y, "Add a Create Healthstone button to trades",
		function() return db.tradeCreate end,
		function(v) db.tradeCreate = v ns.UpdateMakeButton() end,
		"When a trade opens and you have no Healthstone, a button appears on the trade window to cast Create Healthstone. It uses a Soul Shard, and goes away once the stone is made.")

	y = y - 36
	AddHeader(col, y, "Soulstone tracker")
	y = y - 22
	AddCheck(col, y, "Track soulstones in my group",
		function() return db.stoneEnabled end,
		function(v) db.stoneEnabled = v ns.UpdateStones(true) end,
		"Lists everyone in your group carrying a soulstone, who cast it, and a countdown bar of the time left.")
	y = y - 26
	AddCheck(col, y, "Pop up when a soulstone is cast",
		function() return db.stonePopup end,
		function(v) db.stonePopup = v end)
	y = y - 26
	AddCheck(col, y, "Hide while not in a group",
		function() return db.stoneSoloHide end,
		function(v) db.stoneSoloHide = v ns.UpdateStones(true) end,
		"Your own soulstone is still listed when you have one.")
	y = y - 26
	AddCheck(col, y, "Tell the group when I soulstone someone",
		function() return db.stoneAnnounce end,
		function(v) db.stoneAnnounce = v end,
		"Posts a line to party or raid naming who you stoned and how long it lasts. Only stones you cast are announced, so several warlocks will not repeat each other.")
	y = y - 28
	local showStones = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
	showStones:SetSize(170, 22)
	Place(col, showStones, "TOPLEFT", 20, y)
	showStones:SetText("Show soulstone window")
	showStones:SetScript("OnClick", function() ns.ToggleStoneWindow() end)
	y = y - 30

	lowest = math.min(lowest, y)

	-- right column
	col, y = colR, -34
	AddHeader(col, y, "Low shard alert")
	y = y - 22
	AddCheck(col, y, "Show alert icon when low",
		function() return db.alertEnabled end,
		function(v) db.alertEnabled = v Refresh() end,
		"A separate, movable icon that pulses while your total Soul Shards (soul bag + other bags) are below the threshold.")
	y = y - 28
	AddSlider(col, y, "Alert when below", {
		min = 1, max = 40, step = 1,
		get = function() return db.alertThreshold end,
		set = function(v) db.alertThreshold = v Refresh() end,
	})
	y = y - 40
	AddSlider(col, y, "Alert icon size", {
		min = 24, max = 128, step = 4,
		get = function() return db.alertSize end,
		set = function(v) db.alertSize = v Refresh() end,
	})
	y = y - 40
	AddCheck(col, y, "Play a sound when shards run low",
		function() return db.alertSound end,
		function(v) db.alertSound = v end)
	y = y - 28
	local soundBtn = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
	soundBtn:SetSize(200, 22)
	Place(col, soundBtn, "TOPLEFT", 46, y)
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
	AddCheck(col, y, "Show alert now (to position it)",
		function() return alertPreview end,
		function(v) alertPreview = v Refresh() end,
		"Keeps the alert icon visible so you can drag it where you want. Turns itself off when this window closes.")



	y = y - 36
	AddHeader(col, y, "Summon requests")
	y = y - 22
	AddCheck(col, y, "Watch chat for summon requests",
		function() return db.summonEnabled end,
		function(v) db.summonEnabled = v end,
		"Listens to party, raid and whispers for the keywords below and lists who asked, oldest first. Click a name to summon them.")
	y = y - 26
	AddCheck(col, y, "Accept whispers from outside my group",
		function() return db.summonWhisperAny end,
		function(v) db.summonWhisperAny = v end,
		"Party, raid and instance chat are always watched. Whispers normally only count from people already in your group, since you can't summon anyone else. Tick this to list strangers too (invite them, then click).")
	y = y - 26
	AddCheck(col, y, "Pop the summon window up on a request",
		function() return db.summonPopup end,
		function(v) db.summonPopup = v end)
	y = y - 26
	AddCheck(col, y, "Tell party / raid and ask for clickers",
		function() return db.summonAnnounce end,
		function(v) db.summonAnnounce = v end,
		"Posts the message below to party, raid or instance chat when you click a name.")
	y = y - 24
	local groupBox = AddTextBox(col, y, "summonGroupMsg", DEFAULT_GROUP_MSG, "Party / raid message", PLACEHOLDER_HELP, TEXTBOX_W - 52)
	local groupTest = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
	groupTest:SetSize(48, 22)
	groupTest:SetPoint("TOPLEFT", groupBox, "TOPRIGHT", 4, 0)
	groupTest:SetText("Test")
	groupTest:SetScript("OnClick", function() ns.TestGroupMessage() end)
	groupTest:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Test party / raid message", 1, 1, 1)
		GameTooltip:AddLine("Shows the filled-in message in your chat window only. Nothing is sent to the group.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	groupTest:SetScript("OnLeave", function() GameTooltip:Hide() end)
	y = y - (TEXTBOX_H + 8)
	AddCheck(col, y, "Whisper the player being summoned",
		function() return db.summonWhisper end,
		function(v) db.summonWhisper = v end,
		"Sends the message below to the player when you click their name.")
	y = y - 24
	local whisperBox = AddTextBox(col, y, "summonWhisperMsg", DEFAULT_WHISPER_MSG, "Whisper message", PLACEHOLDER_HELP, TEXTBOX_W - 52)
	local whisperTest = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
	whisperTest:SetSize(48, 22)
	whisperTest:SetPoint("TOPLEFT", whisperBox, "TOPRIGHT", 4, 0)
	whisperTest:SetText("Test")
	whisperTest:SetScript("OnClick", function() ns.TestWhisperMessage() end)
	whisperTest:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Test whisper", 1, 1, 1)
		GameTooltip:AddLine("Whispers the filled-in message to yourself so you see it exactly as the player would.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	whisperTest:SetScript("OnLeave", function() GameTooltip:Hide() end)
	y = y - (TEXTBOX_H + 8)
	AddCheck(col, y, "Play a sound on a new request",
		function() return db.summonSound end,
		function(v) db.summonSound = v end)
	y = y - 30
	local kwLabel = col:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	Place(col, kwLabel, "TOPLEFT", 22, y)
	kwLabel:SetText("Request keywords (comma separated)")
	y = y - 18
	AddTextBox(col, y, "summonKeywords", DEFAULT_KEYWORDS, "Request keywords",
		"A message counts as a summon request when it contains one of these as a whole word or phrase. One or two character keywords (like \"1\") must be the entire message. Clear the box and click elsewhere to restore the defaults.")
	y = y - (TEXTBOX_H + 8)
	local showSum = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
	showSum:SetSize(150, 22)
	Place(col, showSum, "TOPLEFT", 20, y)
	showSum:SetText("Show window")
	showSum:SetScript("OnClick", function() ns.ToggleSummonWindow() end)

	local testSum = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
	testSum:SetSize(130, 22)
	testSum:SetPoint("LEFT", showSum, "RIGHT", 6, 0)
	testSum:SetText("Add test request")
	testSum:SetScript("OnClick", function() ns.AddTestSummonRequest() end)
	testSum:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Add test request", 1, 1, 1)
		GameTooltip:AddLine("Adds a fake summon request so you can see, move and minimize the window. Clicking the fake name won't cast or send anything.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	testSum:SetScript("OnLeave", function() GameTooltip:Hide() end)

	y = y - 36
	AddHeader(col, y, "Summon button")
	y = y - 22
	AddCheck(col, y, "Show a floating summon button",
		function() return db.summonButton end,
		function(v) db.summonButton = v ns.UpdateSummonButton() end,
		"Click a party or raid frame (or hover one), then click this button to summon that player. It sends the same whisper and group message as the list.")
	y = y - 28
	AddSlider(col, y, "Summon button size", {
		min = 24, max = 80, step = 2,
		get = function() return db.summonButtonSize end,
		set = function(v) db.summonButtonSize = v ns.UpdateSummonButton() end,
	})
	y = y - 40
	lowest = math.min(lowest, y)

	local baseH = math.max(320, -lowest + 24)
	function ns.ResizeOptions()
		local extra = math.max(ColumnExtra(colL, -math.huge), ColumnExtra(colR, -math.huge))
		CONTENT_H = baseH + extra
		content:SetSize(CONTENT_W - 26, CONTENT_H)
		local viewH = math.min(CONTENT_H + 8, VIEW_MAX_H)
		if config:GetParent() == ns.optionsView or not ns.optionsPage or not ns.optionsPage:IsVisible() then
			view:SetSize(CONTENT_W, viewH)
			config:SetSize(CONTENT_W, viewH + 30)
		end
		ns.UpdateOptionsScroll()
	end
	ns.ResizeOptions()
end

-- ------------------------------------------------------------------
-- Options live in the game's own Options > AddOns list. The page is a plain canvas holding
-- our controls: we never register proxy settings, because handing addon values to the Settings
-- system tainted Blizzard code on this client (the nameplates threw "attempt to compare a
-- secret number value"). Opening the panel is only ever done from a real click.
-- The standalone window is kept solely as a fallback for clients without the Settings API.
-- ------------------------------------------------------------------
local ToggleConfig
local nativeCategory

local function BuildOptionsEntry()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
		error("Settings API not available")
	end
	-- The page hosts the same controls as the standalone window. It shows nothing of its own and
	-- never touches the Settings system beyond registering itself, so no addon values flow into
	-- Blizzard code (the earlier proxy-setting page tainted the nameplates).
	local page = CreateFrame("Frame")
	page:Hide()
	ns.optionsPage = page

	local function Fit()
		if not ns.optionsView then return end
		local w, h = page:GetWidth() or 0, page:GetHeight() or 0
		if w <= 0 or h <= 0 then return end
		-- Shrink only if the panel is narrower than one page of controls; the rest scrolls.
		local scale = math.min(1, w / CONTENT_W)
		ns.HostOptions(page, "TOPLEFT", 0, 0, scale, w / scale, h / scale)
	end
	page:SetScript("OnShow", function()
		if not config then BuildConfig() end
		if config:IsShown() then config:Hide() end
		Fit()
		ns.SyncConfig()
	end)
	page:SetScript("OnSizeChanged", function() if page:IsShown() then Fit() end end)
	page:SetScript("OnHide", function()
		if alertPreview then alertPreview = false Refresh() end
	end)

	local category = Settings.RegisterCanvasLayoutCategory(page, "Shard Grid")
	Settings.RegisterAddOnCategory(category)
	nativeCategory = category
end

function ns.SetupNativeSettings()
	if report["options entry"] then return end
	local ok, err = pcall(BuildOptionsEntry)
	report["options entry"] = ok and "ok (canvas page)" or ("failed: " .. tostring(err))
end

function ToggleConfig()
	if not config then BuildConfig() end -- builds the controls; the window stays hidden
	if ns.optionsPage and ns.optionsPage:IsVisible() then
		-- Closing a Blizzard panel from addon code can be a protected action, so this is a
		-- try, not a promise; the panel's own close button always works.
		if SettingsPanel and HideUIPanel then pcall(HideUIPanel, SettingsPanel) end
		if ns.optionsPage:IsVisible() and not ns.toldYouToClose then
			ns.toldYouToClose = true
			Print("Options are open at Esc > Options > AddOns > Shard Grid. Close them there.")
		end
		return
	end
	if nativeCategory and Settings and Settings.OpenToCategory and not ns.nativeOpenFailed then
		local id = nativeCategory.GetID and nativeCategory:GetID() or nativeCategory.ID or nativeCategory
		pcall(Settings.OpenToCategory, id)
		-- Trust what is on screen, not the call's return value.
		if ns.optionsPage and ns.optionsPage:IsVisible() then
			report["native open"] = "ok"
			return
		end
		ns.nativeOpenFailed = true
		report["native open"] = "refused, using the standalone window from now on"
		Print("The game wouldn't open its options panel, so these are Shard Grid's own. They are also at Esc > Options > AddOns > Shard Grid.")
	end
	config:SetShown(not config:IsShown())
	if config:IsShown() and config.Raise then config:Raise() end
end

ns.SetStage("cog button")
-- Cog in the title bar + right-click on the grid.
local cog = CreateFrame("Button", nil, frame)
cog:SetSize(16, 16)
cog:SetPoint("TOPRIGHT", -5, -3)
frame.sgCog = cog
RaiseWithinParent(cog, frame)
-- Interface art the client may or may not ship. Atlases can be tested for, so the first one
-- that exists is used; "/shards cog" steps through the rest.
-- Art for the options cog. Entries are remembered by name, so the list can be reordered
-- later without moving anyone's choice, and a name copied from another frame also works.
local COG_ART = {
	{ atlas = "common-dropdown-a-button-settings", hover = "common-dropdown-a-button-settings-hover" },
	{ atlas = "common-dropdown-a-button-settings-shadowless", hover = "common-dropdown-a-button-settings-hover-shadowless" },
	{ atlas = "common-dropdown-a-button-settings-hover-shadowless" },
	{ atlas = "common-dropdown-a-button-settings-hover" },
	{ texture = "Interface\\Buttons\\UI-OptionsButton" },
	{ atlas = "GM-icon-settings" },
	{ atlas = "Warfronts-BaseMapIcons-Empty-Workshop" },
	{ atlas = "worldquest-icon-engineering" },
	{ atlas = "UI-HUD-MicroMenu-GameMenu-Up" },
	{ atlas = "optionsicon-brown" },
	{ atlas = "bags-button-autosort-up" },
	{ texture = "Interface\\GossipFrame\\BinderGossipIcon" },
	{ texture = "Interface\\Icons\\Trade_Engineering", crop = true },
}

do
	local gear = cog:CreateTexture(nil, "ARTWORK")
	gear:SetAllPoints()
	cog.gear = gear

	local function CogArtKey(art) return art and (art.atlas or art.texture) end

	-- Accepts a position in the list, or any atlas name / texture path.
	local function ApplyCogArt(index)
		local art = COG_ART[index]
		if type(index) == "string" then
			art = nil
			for _, known in ipairs(COG_ART) do
				if CogArtKey(known) == index then art = known break end
			end
			art = art or (HasAtlas(index) and { atlas = index } or { texture = index })
		end
		if not art then return false end
		if art.atlas then
			if not HasAtlas(art.atlas) then return false end
			gear:SetTexCoord(0, 1, 0, 1)
			gear:SetAtlas(art.atlas)
			cog.restAtlas = art.atlas
			local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(art.atlas)
			cog.artW, cog.artH = info and info.width, info and info.height
			cog.hoverAtlas = art.hover and HasAtlas(art.hover) and art.hover or nil
			report["cog art"] = index .. ": atlas " .. art.atlas
			if cog.ring then cog.ring:Hide() end
		else
			gear:SetTexture(art.texture)
			cog.restAtlas, cog.hoverAtlas = nil, nil
			cog.artW, cog.artH = nil, nil
			if art.crop then gear:SetTexCoord(0.08, 0.92, 0.08, 0.92) else gear:SetTexCoord(0, 1, 0, 1) end
			report["cog art"] = index .. ": " .. art.texture
			if cog.ring then cog.ring:Show() end
		end
		return true
	end
	cog.ApplyArt = ApplyCogArt

	function ns.SetCogArt(wanted)
		if type(wanted) == "string" then
			if ApplyCogArt(wanted) then
				if db then db.cogArt = wanted end
				return wanted
			end
			wanted = 1
		end
		for i = 0, #COG_ART - 1 do
			local try = (((wanted or 1) - 1 + i) % #COG_ART) + 1
			if ApplyCogArt(try) then
				if db then db.cogArt = CogArtKey(COG_ART[try]) end
				return try
			end
		end
	end

	function ns.CurrentCogArt()
		if not db or not db.cogArt then return 1 end
		for i, art in ipairs(COG_ART) do
			if CogArtKey(art) == db.cogArt then return i end
		end
		return 0 -- copied from somewhere else, so not in the list
	end

	-- Copy the art from whatever button you are pointing at.
	function ns.GrabCogArt()
		local focus
		if GetMouseFoci then
			local list = GetMouseFoci()
			focus = list and list[1]
		elseif GetMouseFocus then
			focus = GetMouseFocus()
		end
		if not focus or focus == WorldFrame then
			Print("Point at a button first. Run |cffffffff/shards cog grab|r, then hover the cog you want within 4 seconds.")
			return
		end
		-- The art can sit on the button, on a texture inside it, or on a nested frame, so walk
		-- a few levels down. Atlas names are preferred; a file path works just as well.
		local found = {}
		local function Collect(f, depth)
			if not f or depth > 3 then return end
			if f.GetRegions then
				for _, region in ipairs({ f:GetRegions() }) do
					if region.GetObjectType and region:GetObjectType() == "Texture" then
						local ok, atlas = pcall(function() return region.GetAtlas and region:GetAtlas() end)
						local name = ok and atlas or nil
						if not name then
							local ok2, file = pcall(function() return region.GetTexture and region:GetTexture() end)
							if ok2 and type(file) == "string" then name = file end
						end
						-- Ignore the plain backgrounds and highlights that every button has.
						if name and not found[name] and not name:lower():find("highlight", 1, true) then
							found[name] = true
							found[#found + 1] = name
						end
					end
				end
			end
			if f.GetChildren then
				for _, child in ipairs({ f:GetChildren() }) do Collect(child, depth + 1) end
			end
		end
		Collect(focus, 1)
		local label = focus.GetName and focus:GetName() or "that button"
		if #found == 0 then
			Print("Nothing to copy from " .. tostring(label) .. ".")
			return
		end
		Print("Textures on " .. tostring(label) .. ":")
		for i, name in ipairs(found) do Print("  " .. i .. " " .. name) end
		ns.grabbed = found
		ns.SetCogArt(found[1])
		Print("Using |cffffffff1|r. If that is the frame rather than the gear, try |cffffffff/shards cog grab 2|r, 3 and so on.")
	end
	function ns.CogArtCount() return #COG_ART end
	function ns.CogArtName(i)
		local a = COG_ART[i]
		if not a then return "?" end
		if a.atlas then return "atlas " .. a.atlas .. (HasAtlas(a.atlas) and "" or " |cffff4040(not on this client)|r") end
		return a.texture
	end

	local ring = cog:CreateTexture(nil, "BACKGROUND")
	ring:SetPoint("TOPLEFT", -1, 1)
	ring:SetPoint("BOTTOMRIGHT", 1, -1)
	ring:SetColorTexture(0, 0, 0, 0.6)
	cog.ring = ring

	ns.SetCogArt(1)

	cog:SetScript("OnMouseDown", function() gear:SetAlpha(0.6) end)
	cog:SetScript("OnMouseUp", function() gear:SetAlpha(1) end)
end
cog:SetScript("OnClick", ToggleConfig)
cog:SetScript("OnEnter", function(self)
	if self.hoverAtlas and self.gear then self.gear:SetAtlas(self.hoverAtlas) end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("Shard Grid options")
	GameTooltip:Show()
end)
cog:SetScript("OnLeave", function(self)
	if self.restAtlas and self.gear then self.gear:SetAtlas(self.restAtlas) end
	GameTooltip:Hide()
end)

frame:SetScript("OnMouseUp", function(_, button)
	if button == "RightButton" then ToggleConfig() else ns.HardwareDeletePass() end
end)
alert:SetScript("OnMouseUp", function() ns.HardwareDeletePass() end)

ns.SetStage("minimap frame")
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
	if ns.keyListenerRefused then db.noKeyListener = true end
	if ns.ApplyKeyListener then ns.ApplyKeyListener() end
	-- 1.1: the choice used to be a position in the list, which moved when the list changed.
	if type(db.cogArt) == "number" then db.cogArt = nil end
	if ns.SetCogArt then ns.SetCogArt(db.cogArt) end
	if ns.ApplyBarArt then ns.ApplyBarArt() end

	-- Settings that merely hold a superseded default are dropped, so the new default applies.
	local SUPERSEDED = {
		summonGroupMsg = {
			"Summoning {name} to {zone}. Need 2 people to help click the portal, please! Shards left after this: {shards}.",
		},
		summonWhisperMsg = {
			"Summon incoming! Bringing you to {zone}. Please be ready to accept. Shards left after this: {shards}.",
		},
		summonKeywords = {
			"123, 1, summon, summons, summ, sum, smn, summon pls, summon please, need summon, need a summon, port, port pls, lock port, tp",
		},
	}
	for key, olds in pairs(SUPERSEDED) do
		for _, old in ipairs(olds) do
			if db[key] == old then db[key] = nil end
		end
	end
end

local events = CreateFrame("Frame")
local function SafeRegister(event)
	local ok = pcall(events.RegisterEvent, events, event)
	report["event:" .. event] = ok and "ok" or "missing"
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		ns.SetStage("saved variables")
		ns.InitDB()
		ns.SetStage("options page")
		ns.SetupNativeSettings()
		self:UnregisterEvent("ADDON_LOADED")
		SafeRegister("PLAYER_LOGIN")
		SafeRegister("PLAYER_ENTERING_WORLD")
		SafeRegister("BAG_UPDATE_DELAYED")
		SafeRegister("BAG_UPDATE")
		SafeRegister("BAG_CONTAINER_UPDATE")
		SafeRegister("PLAYER_EQUIPMENT_CHANGED")
		ns.SetStage("alert")
		RestoreAlertPosition()
		ApplyLock()
		ns.SetStage("minimap button")
		ns.UpdateMinimapButton()
		ns.SetStage("summon button")
		ns.UpdateSummonButton()
		ns.SetStage("soulstone scan")
		ns.UpdateStones(true)
		ns.SetStage("idle")
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
	if event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE" then awaitingUpdate = false end
	if event == "BAG_UPDATE" then
		local now = GetTime()
		if ns.lastBagRefresh and now - ns.lastBagRefresh < 0.05 then
			return -- several bags update together; one pass covers them
		end
		ns.lastBagRefresh = now
	end
	Refresh()
	ns.SyncConfig()
end)

ns.SetStage("slash commands")
-- ------------------------------------------------------------------
-- Slash commands
-- ------------------------------------------------------------------
local function Help()
	Print("/shards opens the options window. Also:")
	Print("  /shards width N | size N | scale N (0.5-2)")
	Print("  /shards alert N (threshold) | alert on | alert off")
	Print("  /shards sound ID | minimap (toggle button)")
	Print("  /shards summons (summon request window) | summons test (add a fake request)")
	Print("  /shards stones (soulstone tracker)")
	Print("  /shards cog (next cog art) | cog list | cog grab (copy the art you are pointing at)")
	Print("  /shards bar grab (copy a bar's art for the soulstone bars) | bar reset")
	Print("  /shards anim (shards flying into the grid) | anim on | anim off")
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
	local c = frame.sgCog
	if c then
		Print(("  cog: shown=%s size=%dx%d level=%d strata=%s"):format(
			tostring(c:IsVisible() and true or false), c:GetWidth() or 0, c:GetHeight() or 0,
			c:GetFrameLevel() or 0, tostring(c:GetFrameStrata() or "?")))
	end
	for k, v in pairs(report) do Print("  " .. k .. ": " .. v) end
	if #ns.blockOrder > 0 then
		Print("  refused calls:")
		for _, key in ipairs(ns.blockOrder) do Print("    " .. key .. " (during " .. ns.blockLog[key] .. ")") end
	else
		Print("  refused calls: none this session")
	end
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
	elseif cmd == "summons" or cmd == "summon" then
		if arg == "test" then
			ns.AddTestSummonRequest()
		else
			ns.ToggleSummonWindow()
		end
		return
	elseif cmd == "stones" or cmd == "soulstones" then
		ns.ToggleStoneWindow()
		return
	elseif cmd == "bar" then
		local what, which = arg:match("^(%a+)%s*(%d*)$")
		if what == "grab" then
			if C_Timer and C_Timer.After then
				Print("Hover the bar you want to copy - reading it in 4 seconds.")
				C_Timer.After(4, function() ns.GrabBarArt() end)
			else
				ns.GrabBarArt()
			end
		elseif what == "reset" then
			db.barFill, db.barSpark, db.barBorder = nil, nil, nil
			db.barBg, db.barIcon, db.barMask, db.barShadow = nil, nil, nil, nil
			ns.ApplyBarArt()
			Print("Bar art back to the defaults.")
		elseif (what == "fill" or what == "spark" or what == "border" or what == "bg"
			or what == "icon" or what == "mask" or what == "shadow") and which ~= "" then
			ns.SetBarArt(what, tonumber(which))
		else
			Print("/shards bar grab, then /shards bar fill N | bg N | spark N | icon N | mask N | shadow N | border N (0 removes a piece), or /shards bar reset.")
		end
		return
	elseif cmd == "cog" then
		if arg:match("^grab") then
			local which = tonumber(arg:match("%d+"))
			if which and ns.grabbed and ns.grabbed[which] then
				ns.SetCogArt(ns.grabbed[which])
				Print("Cog art: " .. ns.grabbed[which])
			elseif C_Timer and C_Timer.After then
				Print("Hover the cog you want to copy - reading it in 4 seconds.")
				C_Timer.After(4, function() ns.GrabCogArt() end)
			else
				ns.GrabCogArt()
			end
		elseif arg == "list" then
			Print("cog art on this client:")
			for i = 1, ns.CogArtCount() do
				Print(("  %d%s %s"):format(i, ns.CurrentCogArt() == i and " |cff40ff40(current)|r" or "", ns.CogArtName(i)))
			end
		else
			local want = num or (ns.CurrentCogArt() % ns.CogArtCount() + 1)
			local got = ns.SetCogArt(want)
			Print("Cog art: " .. (got and ns.CogArtName(got) or "none available") .. ". /shards cog again for the next one, /shards cog list to see them all.")
		end
		return
	elseif cmd == "anim" or cmd == "animation" or cmd == "animations" then
		if arg == "on" then db.animate = true
		elseif arg == "off" then db.animate = false
		else db.animate = not db.animate end
		if not db.animate then ANIM.StopAll() end
		Print("Shard animations " .. (db.animate and "on." or "off."))
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
