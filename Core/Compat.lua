local ADDON, ns = ...

local Compat = {}
ns.Compat = Compat

local _G = _G

local function projectFlavor()
	local project = _G.WOW_PROJECT_ID
	if project then
		if project == _G.WOW_PROJECT_MAINLINE then return "retail" end
		if project == _G.WOW_PROJECT_CLASSIC then return "vanilla" end
		if project == _G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC then return "tbc" end
		if project == _G.WOW_PROJECT_WRATH_CLASSIC then return "wrath" end
		if project == _G.WOW_PROJECT_CATACLYSM_CLASSIC then return "cata" end
		if project == _G.WOW_PROJECT_MISTS_CLASSIC then return "mists" end
	end

	-- A client newer than this addon reports a WOW_PROJECT_ID we have no constant
	-- for, so fall back to the interface number rather than refusing to load.
	local interface = select(4, GetBuildInfo()) or 0
	if interface >= 100000 then return "retail" end
	if interface >= 50000 then return "mists" end
	if interface >= 40000 then return "cata" end
	if interface >= 30000 then return "wrath" end
	if interface >= 20000 then return "tbc" end
	return "vanilla"
end

Compat.flavor = projectFlavor()
Compat.interface = select(4, GetBuildInfo()) or 0
Compat.isRetail = Compat.flavor == "retail"
Compat.isClassic = not Compat.isRetail

-- Coin icons rather than the letters g, s and c. This is what the client's own
-- money frames show, and it reads the same in every locale.
--
-- GetCoinTextureString ships on every flavor Parcel supports. The text form is
-- kept behind it so a client that somehow lacks it degrades instead of erroring.
function ns.Money(copper)
	copper = math.floor(tonumber(copper) or 0)

	-- Retail routes this through C_CurrencyInfo, which errors on a negative
	-- amount, and a profit and loss figure is routinely negative.
	local sign = ""
	if copper < 0 then
		sign = "-"
		copper = -copper
	end

	local addon = ns.Addon
	local ui = addon and addon.db and addon.db.profile and addon.db.profile.ui
	if ui and ui.moneyIcons == false then
		return sign .. GetMoneyString(copper)
	end

	if GetCoinTextureString then return sign .. GetCoinTextureString(copper) end
	return sign .. GetMoneyString(copper)
end

-- An item slot button.
--
-- Blizzard_ItemButton ships two of these. Shared/ItemButtonTemplate.xml defines
-- ItemButton as an *intrinsic*, which is a frame type rather than a template and
-- so cannot be passed as CreateFrame's fourth argument. Classic/ additionally
-- defines ItemButtonTemplate as a virtual template, and that file is not loaded
-- on Retail at all, which is why asking for it there fails outright.
--
-- The intrinsic exists on every flavor Parcel supports, so it is tried first.
-- The template stays as a fallback for any client where it does not.
local itemButtonKind

function Compat:CreateItemButton(parent)
	if itemButtonKind == nil then
		local ok, frame = pcall(CreateFrame, "ItemButton", nil, parent)
		if ok and frame then
			itemButtonKind = "intrinsic"
			return frame
		end

		local fallbackOk, fallback = pcall(CreateFrame, "Button", nil, parent, "ItemButtonTemplate")
		if fallbackOk and fallback then
			itemButtonKind = "template"
			return fallback
		end

		itemButtonKind = "plain"
	end

	if itemButtonKind == "intrinsic" then
		return CreateFrame("ItemButton", nil, parent)
	elseif itemButtonKind == "template" then
		return CreateFrame("Button", nil, parent, "ItemButtonTemplate")
	end

	-- Nothing to inherit from. A bare button with the pieces the SetItemButton
	-- helpers reach for, so the slots are plain rather than broken.
	local button = CreateFrame("Button", nil, parent)
	button.icon = button:CreateTexture(nil, "BORDER")
	button.icon:SetAllPoints()
	button.Count = button:CreateFontString(nil, "ARTWORK", "NumberFontNormal")
	button.Count:SetPoint("BOTTOMRIGHT", -5, 2)
	return button
end

function Compat:GetAddOnMetadata(field)
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		return C_AddOns.GetAddOnMetadata(ADDON, field)
	end
	return _G.GetAddOnMetadata and _G.GetAddOnMetadata(ADDON, field)
end

-- Mail
-- ---------------------------------------------------------------------------

-- The compose body is a plain EditBox on retail and TBC, and a ScrollingEditBox
-- named MailEditBox everywhere else. Feature detection rather than a flavor list,
-- because Blizzard has moved this control between clients more than once.
function Compat:GetComposeBody()
	local scrolling = _G.MailEditBox
	if scrolling and scrolling.GetInputText then
		return scrolling:GetInputText() or ""
	end
	local plain = _G.SendMailBodyEditBox
	return plain and plain:GetText() or ""
end

function Compat:SetComposeBody(text)
	local scrolling = _G.MailEditBox
	if scrolling and scrolling.SetText then
		scrolling:SetText(text or "")
		return true
	end
	local plain = _G.SendMailBodyEditBox
	if plain then
		plain:SetText(text or "")
		return true
	end
	return false
end

function Compat:FocusComposeBody()
	local scrolling = _G.MailEditBox
	if scrolling and scrolling.GetEditBox then
		scrolling:GetEditBox():SetFocus()
		return
	end
	if _G.SendMailBodyEditBox then
		_G.SendMailBodyEditBox:SetFocus()
	end
end

function Compat:IsCommandPending()
	if C_Mail and C_Mail.IsCommandPending then
		return C_Mail.IsCommandPending()
	end
	return false
end

function Compat:HasInboxMoney(index)
	if C_Mail and C_Mail.HasInboxMoney then
		return C_Mail.HasInboxMoney(index)
	end
	local money = select(5, GetInboxHeaderInfo(index))
	return (money or 0) > 0
end

-- Retail only. Tells the client an addon is draining the inbox so it stops
-- fighting us over the mail list. Must always be paired with a false call.
function Compat:SetOpeningAll(opening)
	if C_Mail and C_Mail.SetOpeningAll then
		C_Mail.SetOpeningAll(opening and true or false)
	end
end

local lastCheckInbox = 0
local INBOX_REFRESH_SECONDS = 60

-- Returns canCheck, secondsUntilAllowed. Only retail exposes the real answer,
-- so on Classic we track our own CheckInbox calls against the server's 60s window.
function Compat:CanCheckInbox()
	if C_Mail and C_Mail.CanCheckInbox then
		return C_Mail.CanCheckInbox()
	end
	local elapsed = GetTime() - lastCheckInbox
	if elapsed >= INBOX_REFRESH_SECONDS then
		return true, 0
	end
	return false, INBOX_REFRESH_SECONDS - elapsed
end

function Compat:CheckInbox()
	lastCheckInbox = GetTime()
	CheckInbox()
end

function Compat:SetMinimapMailShown(shown)
	if shown then
		if _G.MiniMapMailFrame then _G.MiniMapMailFrame:Show() end
		return
	end
	if _G.MiniMapMailFrame then
		_G.MiniMapMailFrame:Hide()
	elseif _G.MiniMapMailFrameMixin and _G.MiniMapMailFrameMixin.OnLeave then
		_G.MiniMapMailFrameMixin:OnLeave()
	end
end

-- Bags
-- ---------------------------------------------------------------------------

function Compat:ForEachBag(callback)
	for bag = 0, NUM_BAG_SLOTS do
		if callback(bag) == false then return end
	end

	local reagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
	if type(reagentBag) == "number" then
		callback(reagentBag)
	end
end

-- Only counts general purpose slots. A profession bag with room in it will not
-- hold the random item we are about to pull out of a mail.
function Compat:GetFreeBagSlots()
	local free = 0
	self:ForEachBag(function(bag)
		local count, family = C_Container.GetContainerNumFreeSlots(bag)
		if family == 0 then
			free = free + (count or 0)
		end
	end)
	return free
end

function Compat:GetContainerItemInfo(bag, slot)
	return C_Container.GetContainerItemInfo(bag, slot)
end

function Compat:GetItemClass(item)
	if GetItemInfoInstant then
		local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(item)
		if classID then
			return classID, subClassID
		end
	end
	local classID = select(12, C_Item.GetItemInfo(item))
	local subClassID = select(13, C_Item.GetItemInfo(item))
	return classID, subClassID
end

-- Classic Era reports every trade good as Trade Goods with no subclass, so the
-- per material attach buttons cannot exist there.
function Compat:HasTradeGoodsSubclasses()
	return self.flavor ~= "vanilla"
end

-- Events
-- ---------------------------------------------------------------------------

-- MAIL_SHOW and MAIL_CLOSED fire on every flavor. Retail additionally fires the
-- interaction manager events, and some Blizzard code paths only honour those, so
-- both are registered and the caller is expected to tolerate a duplicate.
function Compat:GetMailFrameEvents()
	if self.isRetail then
		return "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE"
	end
	return "MAIL_SHOW", "MAIL_CLOSED"
end

-- Blizzard_UIPanels_Game/Shared/PlayerInteractionFrameManager.lua registers
-- MailFrame against Enum.PlayerInteractionType.MailInfo on Classic Era exactly
-- as it does on Retail, and neither MailFrame ever registers MAIL_CLOSED.
-- Walking out of range fires the interaction hide and nothing else, so gating
-- these events on the flavor left the window open on every classic client.
function Compat:HasInteractionManager()
	return Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo ~= nil
end

function Compat:IsMailInteraction(paneType)
	if not self:HasInteractionManager() then return true end
	return paneType == Enum.PlayerInteractionType.MailInfo
end
