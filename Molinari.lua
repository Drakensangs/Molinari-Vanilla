if not (C_SpellBook and type(C_SpellBook.ContainsAnyDisenchantSpell) == "function") then
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_LOGIN")
  f:SetScript("OnEvent", function()
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cffff2020Molinari:|r ClassicAPI is not installed. "
      .. "The addon will not function without it. Please install ClassicAPI and restart the game.")
  end)
  return
end

local frame = CreateFrame('Frame')
frame:SetScript('OnEvent', function()
	local handler = frame[event]
	if handler then handler(frame) end
end)
frame:RegisterEvent('PLAYER_LOGIN')
frame:RegisterEvent('MODIFIER_STATE_CHANGED')
frame:RegisterEvent('LEARNED_SPELL_IN_SKILL_LINE')
frame:RegisterEvent('SKILL_LINES_CHANGED')
frame:RegisterEvent('GET_ITEM_INFO_RECEIVED')
frame:RegisterEvent('ITEM_DATA_LOAD_RESULT')
frame:RegisterEvent('UNIT_SPELLCAST_FAILED')
frame:RegisterEvent('UNIT_SPELLCAST_FAILED_QUIET')
frame:RegisterEvent('UNIT_SPELLCAST_INTERRUPTED')
frame:RegisterEvent('UNIT_SPELLCAST_START')
frame:RegisterEvent('UNIT_SPELLCAST_SUCCEEDED')

-- Trade window slot 7: "Will not be traded". Lockpicking exception.
local TRADE_NOT_TRADED_SLOT = TRADE_ENCHANT_SLOT or 7

-- Equippable items that can never be disenchanted.
local NOT_DISENCHANTABLE = {
	INVTYPE_BAG = true,
	INVTYPE_AMMO = true,
	INVTYPE_BODY = true,   -- shirts
	INVTYPE_TABARD = true,
}

-- An item with a lock has a Lock.dbc row.
local function HasLock(itemID)
	local data = C_Item.GetItemDataByID(itemID)
	return data and data.lockID and data.lockID ~= 0
end

-- A lockbox that is still locked shows the localized LOCKED ("Locked")
-- line in its tooltip; once picked, that line is gone. GameTooltip must
-- be showing the item when this runs (it is: we are called from the
-- tooltip hooks).
local function IsLocked()
	local locked = LOCKED or 'Locked'
	for i = 1, GameTooltip:NumLines() do
		local line = _G['GameTooltipTextLeft' .. i]
		local text = line and line:GetText()
		if text == locked then return true end
	end
	return false
end

local disenchanter, rogue, hunter
local spellDisenchant, spellLockpick, spellFeedPet
local lootAtCursor
local lootSpell
local lootSpellID
local SPELL_ID_DISENCHANT, SPELL_ID_PICK_LOCK = 13262, 1804

-- Matches a UNIT_SPELLCAST_* event (arg3 = spellID, arg4 = spellName)
-- against the spell that armed loot-at-cursor.
local function IsLootSpell(id, name)
	if not lootSpell then return false end
	return (lootSpellID and id == lootSpellID) or name == lootSpell
end

-- Loot frame at cursor when disenchanting/lockpicking via alt+click
local lootCursorFrame = CreateFrame("Frame", "MolinariLootCursor", LootFrame)
local lootButtons = {}
for i = 1, (LOOTFRAME_NUMBUTTONS or 4) do
	lootButtons[i] = _G["LootButton" .. i]
end

lootCursorFrame:RegisterEvent("LOOT_OPENED")
lootCursorFrame:RegisterEvent("LOOT_SLOT_CLEARED")
lootCursorFrame:RegisterEvent("LOOT_CLOSED")

-- Raise LootFrame and all of its descendants (loot buttons, close button,
-- page arrows, etc) above bag frames while shown at the cursor, then
-- restore every frame's original strata/level so normal looting is unaffected.
local savedLootStrata

local function RaiseTree(frame, level, saved)
	saved[frame] = { frame:GetFrameStrata(), frame:GetFrameLevel() }
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetFrameLevel(level)
	local children = { frame:GetChildren() }
	for i = 1, table.getn(children) do
		local child = children[i]
		if child and child ~= lootCursorFrame and not saved[child] then
			-- keep relative ordering: child level = parent level + original offset
			local offset = child:GetFrameLevel() - (saved[frame][2] or 0)
			if offset < 1 then offset = 1 end
			RaiseTree(child, level + offset, saved)
		end
	end
end

local function RaiseLootFrame()
	if savedLootStrata then return end
	savedLootStrata = {}
	RaiseTree(LootFrame, 100, savedLootStrata)
end

local function RestoreLootFrame()
	if not savedLootStrata then return end
	for frame, data in pairs(savedLootStrata) do
		frame:SetFrameStrata(data[1])
		frame:SetFrameLevel(data[2])
	end
	savedLootStrata = nil
end

lootCursorFrame:SetScript("OnEvent", function()
	if event == "LOOT_CLOSED" then
		RestoreLootFrame()
		lootCursorFrame:Hide()
		lootAtCursor = false
		return
	end
	if not lootAtCursor then return end
	if event == "LOOT_OPENED" then
		lootCursorFrame.last_button = nil
		RaiseLootFrame()
		lootCursorFrame:Show()
	elseif event == "LOOT_SLOT_CLEARED" then
		lootCursorFrame:Show()
	end
end)

lootCursorFrame:SetScript("OnUpdate", function()
	if not lootAtCursor then
		lootCursorFrame:Hide()
		return
	end

	if GetNumLootItems() == 0 then
		lootCursorFrame:Hide()
		HideUIPanel(LootFrame)
		lootAtCursor = false
		return
	end

	for i = 1, (LOOTFRAME_NUMBUTTONS or 4) do
		local button = lootButtons[i]
		if button and button:IsVisible() then
			if lootCursorFrame.last_button ~= button then
				local x, y = GetCursorPosition()
				local s = LootFrame:GetEffectiveScale() or 1
				local button_offset = (i - 1) * button:GetHeight()
				x, y = x / s, y / s
				if LootFrame.SetClampedToScreen then
					LootFrame:SetClampedToScreen(true)
				end
				LootFrame:ClearAllPoints()
				LootFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x - 40, y + 100 + button_offset)
				lootCursorFrame.last_button = button
			end
			lootCursorFrame:Hide()
			return
		end
	end
end)
lootCursorFrame:Hide()

-- A Disenchant/Pick Lock that fails or is interrupted never opens a loot
-- window, so stop waiting for one; otherwise the next normal loot window
-- would open at the cursor. Only the armed spell's own failure counts:
-- any other failed spell (arg4 = spellName) leaves the flag alone.
local function CancelLootAtCursor()
	if arg1 ~= 'player' or not IsLootSpell(arg3, arg4) then return end
	if lootAtCursor and not LootFrame:IsShown() then
		lootAtCursor = false
	end
end
frame.UNIT_SPELLCAST_FAILED = CancelLootAtCursor
frame.UNIT_SPELLCAST_FAILED_QUIET = CancelLootAtCursor
frame.UNIT_SPELLCAST_INTERRUPTED = CancelLootAtCursor

-- The flag is armed on click but only confirmed once Disenchant actually
-- starts casting. If applying the item silently fails (slot emptied/locked,
-- targeting cancelled without a failure event), no cast starts and the
-- watcher below drops the flag, so normal looting is never affected.
local lootWatch = CreateFrame('Frame')
lootWatch:Hide()
lootWatch:SetScript('OnUpdate', function()
	if not lootAtCursor or LootFrame:IsShown() then
		lootWatch:Hide()
	elseif GetTime() > (lootWatch.expire or 0) then
		lootAtCursor = false
		lootWatch:Hide()
	end
end)

local function ArmLootAtCursor(spell, spellID)
	lootSpell, lootSpellID = spell, spellID
	lootAtCursor = true
	lootWatch.expire = GetTime() + 1
	lootWatch:Show()
end

function frame:UNIT_SPELLCAST_START()
	if arg1 == 'player' and lootAtCursor and IsLootSpell(arg3, arg4) then
		lootWatch:Hide() -- cast confirmed; LOOT_OPENED or a failure event ends it
	end
end

-- Disenchant and Pick Lock both open a loot window when they go off (our
-- Pick Lock opens the box automatically). If none appears shortly after,
-- stop waiting so a later normal loot window isn't moved.
function frame:UNIT_SPELLCAST_SUCCEEDED()
	if arg1 == 'player' and lootAtCursor and IsLootSpell(arg3, arg4) then
		lootWatch.expire = GetTime() + 1
		lootWatch:Show()
	end
end

-- ---------------------------------------------------------------------------
-- Feed Pet: check whether an item is food a hunter's pet can eat.
--
-- classID 0 (Consumable), subclassID 0 or 5: use C_Item.GetItemSpell to
-- confirm the ON_USE spell name is the localized "Food" string
-- (TUTORIAL_TITLE11). Anything else (Drink, potions, ...) fails that
-- comparison, so it is never matched.
--
-- classID 7 (Trade Goods), subclassID 0: raw meat/fish sold as trade goods.
-- C_Item.GetItemDataByID material == 0 is used as an additional filter to
-- reduce misfires, since most non-food trade goods have a non-zero material.
-- The client has no per-item food type (meat/fish/bread...), so this can't
-- be matched against GetPetFoodTypes().
-- ---------------------------------------------------------------------------
local function IsFeedableItem(itemID, classID, subclassID)
	if not UnitExists('pet') or UnitIsDead('pet') then return false end

	if classID == 0 and (subclassID == 0 or subclassID == 5) then
		local spellName = C_Item.GetItemSpell(itemID)
		if spellName == TUTORIAL_TITLE11 then return true end  -- "Food"
		return false
	end

	if classID == 7 and subclassID == 0 then
		local data = C_Item.GetItemDataByID(itemID)
		if data and data.material == 0 then return true end
		return false
	end

	return false
end

-- Item waiting for its data to reach the cache, so we can retry the glow.
local pendingItemID

-- Works out which spell (if any) applies to the item in bag/slot.
local function GetSpellForSlot(bagID, slotID)
	local link = GetContainerItemLink(bagID, slotID)
	if not link then return end

	local itemID, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
	if not itemID then return end

	-- Not cached yet: ask the server and retry when the data lands.
	if not classID then
		pendingItemID = itemID
		C_Item.RequestLoadItemDataByID(itemID)
		return
	end

	if disenchanter then
		local quality = C_Item.GetItemQualityByID(itemID)
		if not quality then
			local info = C_Container.GetContainerItemInfo(bagID, slotID)
			quality = info and info.quality
		end
		if equipLoc and equipLoc ~= '' and not NOT_DISENCHANTABLE[equipLoc]
		and quality and quality >= LE_ITEM_QUALITY_UNCOMMON
		and classID ~= 1 then
			return spellDisenchant, false
		end
	end

	if rogue and HasLock(itemID) and IsLocked() then
		return spellLockpick, true  -- true = lockpick (yellow glow)
	end

	if hunter and IsFeedableItem(itemID, classID, subclassID) then
		return spellFeedPet, nil, true  -- nil lockpick, true = feedpet (green glow)
	end
end

-- itemID in the "Will not be traded" slot. Falls back to parsing the
-- item link in case the ID companion returns nothing for this slot.
local function GetTradeItemID(side)
	local id, link
	if side == 'target' then
		id = GetTradeTargetItemID and GetTradeTargetItemID(TRADE_NOT_TRADED_SLOT)
		link = GetTradeTargetItemLink and GetTradeTargetItemLink(TRADE_NOT_TRADED_SLOT)
	else
		id = GetTradePlayerItemID and GetTradePlayerItemID(TRADE_NOT_TRADED_SLOT)
		link = GetTradePlayerItemLink and GetTradePlayerItemLink(TRADE_NOT_TRADED_SLOT)
	end
	if not id and link then
		local _, _, n = string.find(link, 'item:(%d+)')
		id = tonumber(n)
	end
	return id
end

-- Lockbox in the "Will not be traded" slot, on either side of the trade.
-- GameTooltip is showing the slot's item when this runs. The "Locked"
-- line is the deciding check, exactly as for bag items; the lock data is
-- only used to rule an item out when it is known to have no lock.
local function GetSpellForTrade(side)
	if not rogue then return end
	if not IsLocked() then return end
	local itemID = GetTradeItemID(side)
	if itemID then
		local data = C_Item.GetItemDataByID(itemID)
		if data and (not data.lockID or data.lockID == 0) then return end
	end
	return spellLockpick, true
end

-- Texture coordinates for IconAlertAnts sprite sheet (frames 1-22 used)
local AntTexCoords = {
	{0.0078125, 0.1796875, 0.00390625, 0.17578125}, {0.1953125, 0.3671875, 0.00390625, 0.17578125}, {0.3828125, 0.5546875, 0.00390625, 0.17578125}, {0.5703125, 0.7421875, 0.00390625, 0.17578125}, {0.7578125, 0.9296875, 0.00390625, 0.17578125},
	{0.0078125, 0.1796875, 0.19140625, 0.36328125}, {0.1953125, 0.3671875, 0.19140625, 0.36328125}, {0.3828125, 0.5546875, 0.19140625, 0.36328125}, {0.5703125, 0.7421875, 0.19140625, 0.36328125}, {0.7578125, 0.9296875, 0.19140625, 0.36328125},
	{0.0078125, 0.1796875, 0.37890625, 0.55078125}, {0.1953125, 0.3671875, 0.37890625, 0.55078125}, {0.3828125, 0.5546875, 0.37890625, 0.55078125}, {0.5703125, 0.7421875, 0.37890625, 0.55078125}, {0.7578125, 0.9296875, 0.37890625, 0.55078125},
	{0.0078125, 0.1796875, 0.56640625, 0.73828125}, {0.1953125, 0.3671875, 0.56640625, 0.73828125}, {0.3828125, 0.5546875, 0.56640625, 0.73828125}, {0.5703125, 0.7421875, 0.56640625, 0.73828125}, {0.7578125, 0.9296875, 0.56640625, 0.73828125},
	{0.0078125, 0.1796875, 0.75390625, 0.92578125}, {0.1953125, 0.3671875, 0.75390625, 0.92578125},
}


local TWO_PI = math.pi * 2
local updateInterval = 0.04
local unusedOverlays = {}
local numOverlays = 0

-- Shared by every overlay; reads its colour from the overlay itself.
local function OverlayOnUpdate()
	local overlay = this
	-- Drive everything from GetTime() so it never depends on the elapsed arg
	local now = GetTime()
	-- The sprite only changes every updateInterval seconds; skip the frames
	-- in between instead of recomputing the same values.
	if now < (overlay.nextUpdate or 0) then return end
	overlay.nextUpdate = now + updateInterval
	local index = math.mod(math.floor(now / updateInterval), 22) + 1
	if index ~= overlay.index then
		overlay.index = index
		overlay.glow:SetTexCoord(AntTexCoords[index][1], AntTexCoords[index][2], AntTexCoords[index][3], AntTexCoords[index][4])
	end

	local t = math.mod(now * 2, TWO_PI)
	local pulse = 0.75 + 0.25 * math.sin(t * 3)

	if overlay.r then
		-- Fixed color with pulse
		overlay.glow:SetVertexColor(overlay.r * pulse, overlay.g * pulse, overlay.b * pulse, 1)
		overlay.background:SetVertexColor(overlay.r * pulse, overlay.g * pulse, overlay.b * pulse, 0.4)
	else
		-- Full-spectrum RGB cycle: R/G/B channels evenly spaced 120° apart
		local cr = (0.5 + 0.5 * math.sin(t)) * pulse
		local cg = (0.5 + 0.5 * math.sin(t + 2.0944)) * pulse  -- +120°
		local cb = (0.5 + 0.5 * math.sin(t + 4.1888)) * pulse  -- +240°
		overlay.glow:SetVertexColor(cr, cg, cb, 1)
		overlay.background:SetVertexColor(cr, cg, cb, 0.4)
	end
end

local function GetOverlay()
	local overlay = tremove(unusedOverlays)
	if not overlay then
		numOverlays = numOverlays + 1
		overlay = CreateFrame('Frame', 'MolinariOverlay' .. numOverlays)

		-- Static glow base from IconAlert
		overlay.background = overlay:CreateTexture(nil, 'BACKGROUND')
		overlay.background:SetTexture('Interface\\AddOns\\Molinari\\Textures\\IconAlert')
		overlay.background:SetTexCoord(0.0546875, 0.4609375, 0.30078125, 0.50390625)
		overlay.background:SetBlendMode('ADD')
		overlay.background:SetAllPoints(overlay)

		-- Animated marching ants from IconAlertAnts
		overlay.glow = overlay:CreateTexture(nil, 'OVERLAY')
		overlay.glow:SetTexture('Interface\\AddOns\\Molinari\\Textures\\IconAlertAnts')
		overlay.glow:SetBlendMode('ADD')
		overlay.glow:SetAllPoints(overlay)
	end
	return overlay
end

local function AddOverlay(button, r, g, b)
	if button.overlay then return end

	local overlay = GetOverlay()
	button.overlay = overlay
	overlay:SetParent(button)
	-- Sit just above the slot button, not in the TOOLTIP layer, so the
	-- additive glow never brightens the tooltip where they overlap.
	overlay:SetFrameStrata(button:GetFrameStrata())
	overlay:SetFrameLevel(button:GetFrameLevel() + 5)
	overlay:SetAllPoints(button)
	overlay.index = 1
	overlay.nextUpdate = 0
	overlay.r, overlay.g, overlay.b = r, g, b
	overlay.glow:SetTexCoord(AntTexCoords[1][1], AntTexCoords[1][2], AntTexCoords[1][3], AntTexCoords[1][4])
	overlay:Show()
	overlay:SetScript('OnUpdate', OverlayOnUpdate)
end

local function RemoveOverlay(button)
	if not button.overlay then return end
	local overlay = button.overlay
	overlay:SetScript('OnUpdate', nil)
	overlay:Hide()
	overlay:SetParent(UIParent)
	button.overlay = nil
	tinsert(unusedOverlays, overlay)
end

-- ---------------------------------------------------------------------------
-- Generic bag addon support
--
-- Instead of hooking each bag addon's slot buttons, we hook
-- GameTooltip:SetBagItem(bag, slot). Blizzard bags, pfUI, Bagnon, OneBag,
-- EngBags, SUCC-bag, ... all call it when a slot is hovered, so it tells us
-- which bag/slot is under the mouse and (via GetOwner) which frame is the
-- slot button. While ALT is held we lay an invisible button over that slot;
-- it takes the click and casts the spell on bag/slot. The bag addon's own
-- click handler is never touched. The trade window's "Will not be traded"
-- slot is handled the same way through SetTradeTargetItem/SetTradePlayerItem.
-- ---------------------------------------------------------------------------

local catcher = CreateFrame('Button', 'MolinariCatcher', UIParent)
catcher:SetFrameStrata('TOOLTIP')
catcher:RegisterForClicks('LeftButtonUp')
catcher:EnableMouse(true)
catcher:Hide()

local hoverOwner, hoverBag, hoverSlot, hoverTrade
local refreshing

-- Snapshot of where the bag addon placed GameTooltip, so the catcher can
-- re-show the tooltip in exactly the same spot instead of re-anchoring it.
local savedAnchor, savedPoints = nil, {}

local function SaveTooltipPosition()
	if not GameTooltip:IsShown() or GameTooltip:GetOwner() == catcher then return end
	savedAnchor = GameTooltip.GetAnchorType and GameTooltip:GetAnchorType() or nil
	for i = table.getn(savedPoints), 1, -1 do savedPoints[i] = nil end
	local n = GameTooltip:GetNumPoints()
	for i = 1, n do
		local point, rel, relPoint, x, y = GameTooltip:GetPoint(i)
		if point then
			tinsert(savedPoints, {point, rel, relPoint, x, y})
		end
	end
end

local function RestoreTooltipPosition(owner)
	-- Cursor-following anchors must stay dynamic; replay the anchor type.
	if savedAnchor == 'ANCHOR_CURSOR' or savedAnchor == 'ANCHOR_PRESERVE' then
		GameTooltip:SetOwner(owner, savedAnchor)
		return false
	end
	GameTooltip:SetOwner(owner, 'ANCHOR_NONE')
	return true
end

local function ApplySavedPoints()
	if table.getn(savedPoints) == 0 then return end
	GameTooltip:ClearAllPoints()
	for i = 1, table.getn(savedPoints) do
		local p = savedPoints[i]
		if p[2] then
			GameTooltip:SetPoint(p[1], p[2], p[3], p[4], p[5])
		else
			GameTooltip:SetPoint(p[1], UIParent, p[3], p[4], p[5])
		end
	end
end

local function Deactivate()
	if catcher.owner then RemoveOverlay(catcher.owner) end
	catcher.owner, catcher.bag, catcher.slot, catcher.trade, catcher.spell = nil, nil, nil, nil, nil
	catcher.link = nil
	catcher.entered = nil
	catcher.pendingSave = nil
	catcher:ClearAllPoints()
	catcher:Hide()
end

-- Identifies the item currently in the hovered slot, so a click can tell
-- whether it is still the same item that was checked on hover.
local function GetHoveredItemKey(bagID, slotID, trade)
	if trade == 'target' then
		return GetTradeTargetItemLink and GetTradeTargetItemLink(TRADE_NOT_TRADED_SLOT) or GetTradeItemID(trade)
	elseif trade == 'player' then
		return GetTradePlayerItemLink and GetTradePlayerItemLink(TRADE_NOT_TRADED_SLOT) or GetTradeItemID(trade)
	end
	return GetContainerItemLink(bagID, slotID)
end

local function IsShown(f)
	return f and f:IsShown()
end

-- Alt+click is easy to hit by accident in these windows and the cast would
-- fail anyway. The trade window is the one exception, and only for picking
-- a lockbox in its "Will not be traded" slot (allowTrade).
local function IsBlocked(allowTrade)
	if IsShown(AuctionFrame) or IsShown(MailFrame) or IsShown(MerchantFrame) or IsShown(BankFrame) then
		return true
	end
	if not allowTrade and IsShown(TradeFrame) then return true end
	return false
end

-- bagID/slotID for a bag slot, or trade = 'player'/'target' for the
-- "Will not be traded" trade slot.
local function Activate(owner, bagID, slotID, trade)
	if not owner or not IsAltKeyDown() then return end
	if IsBlocked(trade ~= nil) then return end
	if catcher.owner == owner and catcher.bag == bagID and catcher.slot == slotID and catcher.trade == trade then return end

	local spell, isLockpick, isFeedPet
	if trade then
		spell, isLockpick = GetSpellForTrade(trade)
	else
		spell, isLockpick, isFeedPet = GetSpellForSlot(bagID, slotID)
	end
	if not spell then
		Deactivate()
		return
	end

	if catcher.owner and catcher.owner ~= owner then RemoveOverlay(catcher.owner) end
	catcher.owner, catcher.bag, catcher.slot, catcher.trade, catcher.spell = owner, bagID, slotID, trade, spell
	catcher.link = GetHoveredItemKey(bagID, slotID, trade)
	catcher:ClearAllPoints()
	catcher:SetAllPoints(owner)
	catcher:SetFrameLevel(owner:GetFrameLevel() + 10)
	SaveTooltipPosition()
	catcher.pendingSave = true
	catcher.entered = nil
	catcher:Show()

	if isLockpick == true then
		AddOverlay(owner, 1, 1, 0)		-- yellow for lockpick
	elseif isFeedPet == true then
		AddOverlay(owner, 0, 1, 0)		-- green for Feed Pet
	else
		AddOverlay(owner)				-- rainbow cycle for disenchant
	end
end

-- Shows the hovered item in GameTooltip again (for scanning / re-showing).
local function RefreshTooltip(bagID, slotID, trade)
	refreshing = true
	if trade == 'target' then
		GameTooltip:SetTradeTargetItem(TRADE_NOT_TRADED_SLOT)
	elseif trade == 'player' then
		GameTooltip:SetTradePlayerItem(TRADE_NOT_TRADED_SLOT)
	else
		GameTooltip:SetBagItem(bagID, slotID)
	end
	refreshing = false
end

local function OnHover(tooltip, bagID, slotID, trade)
	if refreshing then return end
	local owner = tooltip:GetOwner()
	-- Some bag addons (e.g. Guda) anchor the tooltip to UIParent/WorldFrame
	-- instead of the slot button. In that case use the frame under the mouse.
	if not owner or owner == UIParent or owner == WorldFrame or not MouseIsOver(owner) then
		owner = GetMouseFocus()
	end
	if not owner or owner == catcher or owner == UIParent or owner == WorldFrame then return end
	-- Sanity check: never glow anything bigger than a slot button
	local w, h = owner:GetWidth() or 0, owner:GetHeight() or 0
	if w > 80 or h > 80 then return end
	hoverOwner, hoverBag, hoverSlot, hoverTrade = owner, bagID, slotID, trade
	Activate(owner, bagID, slotID, trade)
end

hooksecurefunc(GameTooltip, 'SetBagItem', function(self, bagID, slotID)
	OnHover(self, bagID, slotID, nil)
end)

hooksecurefunc(GameTooltip, 'SetTradeTargetItem', function(self, index)
	if index == TRADE_NOT_TRADED_SLOT then OnHover(self, nil, nil, 'target') end
end)

hooksecurefunc(GameTooltip, 'SetTradePlayerItem', function(self, index)
	if index == TRADE_NOT_TRADED_SLOT then OnHover(self, nil, nil, 'player') end
end)

-- Also hook the "Will not be traded" slot buttons directly, so the glow
-- does not depend on how the trade frame fills its tooltip.
local function HookTradeButton(name, side)
	local button = _G[name]
	if not button then return end
	local orig = button:GetScript('OnEnter')
	button:SetScript('OnEnter', function()
		if orig then orig() end
		if refreshing then return end
		hoverOwner, hoverBag, hoverSlot, hoverTrade = this, nil, nil, side
		Activate(this, nil, nil, side)
	end)
end
HookTradeButton('TradePlayerItem' .. TRADE_NOT_TRADED_SLOT .. 'ItemButton', 'player')
HookTradeButton('TradeRecipientItem' .. TRADE_NOT_TRADED_SLOT .. 'ItemButton', 'target')

catcher:SetScript('OnEnter', function()
	-- The slot underneath got OnLeave; keep its tooltip visible.
	if not this.bag and not this.trade then return end
	this.entered = true
	local fixed = RestoreTooltipPosition(this.owner or this)
	RefreshTooltip(this.bag, this.slot, this.trade)
	if fixed then
		if table.getn(savedPoints) > 0 then
			ApplySavedPoints()
		else
			GameTooltip:SetAnchorType('ANCHOR_RIGHT')
		end
	end
end)

-- Take one more snapshot on the frame after activation, in case the bag
-- addon repositions the tooltip right after SetBagItem.
catcher:SetScript('OnUpdate', function()
	-- The slot underneath went away (bags closed with a key, trade window
	-- closed, ...) while ALT is still held: never leave a live click area
	-- behind on screen.
	local owner = this.owner
	if not owner or not owner:IsVisible() or not IsAltKeyDown() then
		-- Hide the tooltip too when it belongs to us or to the vanished slot.
		local tipOwner = GameTooltip:GetOwner()
		if tipOwner == this or tipOwner == owner or (tipOwner and not tipOwner:IsVisible()) then
			GameTooltip:Hide()
		end
		hoverOwner = nil
		Deactivate()
		return
	end
	if not this.pendingSave then return end
	this.pendingSave = nil
	if not this.entered and this.owner and GameTooltip:GetOwner() == this.owner then
		SaveTooltipPosition()
	end
end)

catcher:SetScript('OnLeave', function()
	GameTooltip:Hide()
	hoverOwner = nil
	Deactivate()
end)

catcher:SetScript('OnClick', function()
	local bagID, slotID, trade, spell = this.bag, this.slot, this.trade, this.spell
	if arg1 ~= 'LeftButton' or not spell or (not bagID and not trade) then return end

	-- Re-check the slot: the item may have changed since it was hovered.
	local current
	if GetHoveredItemKey(bagID, slotID, trade) == this.link then
		RefreshTooltip(bagID, slotID, trade) -- IsLocked() reads GameTooltip
		if trade then
			current = GetSpellForTrade(trade)
		else
			current = GetSpellForSlot(bagID, slotID)
		end
	end
	if current ~= spell then
		local owner = this.owner
		Deactivate()
		-- Re-evaluate whatever is in the slot now.
		if owner and owner:IsVisible() and MouseIsOver(owner) then
			RefreshTooltip(bagID, slotID, trade)
			Activate(owner, bagID, slotID, trade)
		end
		return
	end

	SpellStopTargeting()
	CastSpellByName(spell)

	-- The cast didn't start (moving, in combat, ...): don't touch the item,
	-- or it would just be picked up onto the cursor.
	if SpellIsTargeting() then
		-- Disenchant and picking a bag lockbox both open a loot window.
		if spell == spellDisenchant then
			ArmLootAtCursor(spell, SPELL_ID_DISENCHANT)
		elseif spell == spellLockpick and not trade then
			ArmLootAtCursor(spell, SPELL_ID_PICK_LOCK)
		end

		if trade == 'target' then
			ClickTargetTradeButton(TRADE_NOT_TRADED_SLOT)
		elseif trade == 'player' then
			ClickTradeButton(TRADE_NOT_TRADED_SLOT)
		else
			PickupContainerItem(bagID, slotID) -- applies the pending spell to the item
		end
		SpellStopTargeting()
		ClearCursor()
	end

	GameTooltip:Hide()
	Deactivate()
end)

function frame:MODIFIER_STATE_CHANGED()
	if IsAltKeyDown() then
		-- ALT pressed while already hovering a slot
		if hoverOwner and GetMouseFocus() == hoverOwner then
			RefreshTooltip(hoverBag, hoverSlot, hoverTrade) -- make sure the tooltip shows this item for scanning
			Activate(hoverOwner, hoverBag, hoverSlot, hoverTrade)
		end
	elseif catcher:IsShown() then
		local owner = catcher.owner
		Deactivate()
		-- hand the tooltip back to the real slot
		if owner and MouseIsOver(owner) and owner:GetScript('OnEnter') then
			local saved = this
			this = owner
			owner:GetScript('OnEnter')()
			this = saved
		end
	end
end

-- The hovered item's data reached the cache: retry the glow.
local function OnItemDataReceived()
	if not pendingItemID or arg1 ~= pendingItemID then return end
	pendingItemID = nil
	if hoverOwner and IsAltKeyDown() and GetMouseFocus() == hoverOwner and not catcher.owner then
		RefreshTooltip(hoverBag, hoverSlot, hoverTrade)
		Activate(hoverOwner, hoverBag, hoverSlot, hoverTrade)
	end
end
frame.GET_ITEM_INFO_RECEIVED = OnItemDataReceived
frame.ITEM_DATA_LOAD_RESULT = OnItemDataReceived

-- Re-read every time: spells can be lost (unlearned profession) as well as
-- learned, so each flag is set from what the player knows right now.
local function UpdateSpells()
	disenchanter = C_SpellBook.ContainsAnyDisenchantSpell() and true or false
	spellDisenchant = disenchanter and GetSpellInfo(13262) or nil

	rogue = IsSpellKnown(1804) and true or false
	spellLockpick = rogue and GetSpellInfo(1804) or nil

	hunter = IsSpellKnown(6991) and true or false
	spellFeedPet = hunter and GetSpellInfo(6991) or nil

	-- Drop a glow for a spell that is no longer known.
	if catcher.spell and catcher.spell ~= spellDisenchant
	and catcher.spell ~= spellLockpick and catcher.spell ~= spellFeedPet then
		Deactivate()
	end
end

frame.PLAYER_LOGIN = UpdateSpells
frame.LEARNED_SPELL_IN_SKILL_LINE = UpdateSpells
frame.SKILL_LINES_CHANGED = UpdateSpells

