local ADDON, ns = ...

-- The outgoing half of the mailbox.
--
-- Attachments are not Parcel state. The client owns a set of send slots and
-- ClickSendMailItemButton moves items in and out of them, which works whether
-- or not Blizzard's compose frame is on screen. Everything here reads that
-- state back rather than shadowing it, so the two can never disagree.

local Send = {}
ns.Send = Send

local Events = ns.Events

local MAX_COD = (MAX_COD_AMOUNT or 10000) * (COPPER_PER_GOLD or 10000)

Send.mode = "money"
Send.amount = 0
Send.sending = false

local function announce()
	Events:Trigger("Parcel.Send.Changed")
end

-- Attachments
-- ---------------------------------------------------------------------------

function Send:GetAttachment(index)
	if not HasSendMailItem(index) then return nil end
	return GetSendMailItem(index)
end

function Send:CountAttachments()
	local count = 0
	for index = 1, ATTACHMENTS_MAX_SEND do
		if HasSendMailItem(index) then
			count = count + 1
		end
	end
	return count
end

function Send:HasRoom()
	return self:CountAttachments() < ATTACHMENTS_MAX_SEND
end

-- Puts whatever is on the cursor into the first free slot, or into a specific
-- one. With an empty cursor and an occupied slot this lifts the item out, which
-- is exactly how Blizzard's own attachment buttons behave.
function Send:ClickSlot(index, rightClick)
	ClickSendMailItemButton(index, rightClick and true or false)
	announce()
end

function Send:AttachCursor()
	ClickSendMailItemButton()
	announce()
end

-- Retail answers this directly. Everywhere else the only reliable source is the
-- tooltip text, which is what Postal and zMail both read.
local scanner
local function scanTooltip()
	if not scanner then
		scanner = CreateFrame("GameTooltip", "ParcelScanTooltip", nil, "GameTooltipTemplate")
		-- WorldFrame, not UIParent. A scanning tooltip that shares an anchor
		-- ancestor with the real GameTooltip corrupts it while it is showing
		-- something that refreshes on a timer: weapon imbues, buffs, bag items
		-- that are still tradeable. Parentless is not enough on its own.
		scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	return scanner
end

function Send:IsSoulbound(bag, slot)
	if C_Item and C_Item.IsBound and ItemLocation then
		local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
		if location and location:IsValid() then
			return C_Item.IsBound(location)
		end
	end

	local tooltip = scanTooltip()
	tooltip:ClearLines()
	tooltip:SetBagItem(bag, slot)

	-- Binding text sits near the top, so there is no reason to walk the whole
	-- tooltip and read an item's flavour text.
	for line = 2, math.min(tooltip:NumLines(), 6) do
		local text = _G["ParcelScanTooltipTextLeft" .. line]
		local value = text and text:GetText()
		-- "Binds when picked up" is not the same as bound: that item has never
		-- been equipped and is still perfectly sendable.
		if value == ITEM_SOULBOUND or value == ITEM_BIND_QUEST then
			return true
		end
	end

	return false
end

function Send:AttachFromBag(bag, slot)
	if not self:HasRoom() then return false end

	if self:IsSoulbound(bag, slot) then
		return false, "That item is soulbound and cannot be mailed."
	end

	if CursorHasItem() then ClearCursor() end

	C_Container.PickupContainerItem(bag, slot)
	ClickSendMailItemButton()

	-- A refusal leaves the item on the cursor rather than raising anything, so
	-- put it back instead of leaving the player holding it.
	if CursorHasItem() then
		ClearCursor()
		announce()
		return false, "The mail would not take that item."
	end

	announce()
	return true
end

-- Quick attach
-- ---------------------------------------------------------------------------

-- Blizzard's own auction categories carry the comment "SubClasses Added in
-- TBC", and on Classic Era the trade goods category is a flat filter. Rather
-- than gate on the flavor, the grouping asks the client to name the subclass of
-- what is actually in the bags: a client that names nothing useful yields one
-- group, and one that does yields real ones. No table of ids per flavor either
-- way.
local TRADE_GOODS = 7

-- Nothing has come close to this many, and the loop stops at the first gap only
-- if the ids were contiguous, which they are not.
local MAX_SUBCLASS = 24

-- Everything under one heading, where subclasses say nothing useful.
local FLAT = -1
Send.FLAT_TRADE_GOODS = FLAT

function Send:TradeGoodsClass()
	return (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or TRADE_GOODS
end

-- Discovered by asking the client to name each one rather than written down per
-- flavor. The set grows with every expansion, and a hardcoded table stops
-- covering new materials without anyone noticing it has.
local subclassNames

function Send:TradeGoodsSubclasses()
	if subclassNames then return subclassNames end

	subclassNames = {}
	if not GetItemSubClassInfo then return subclassNames end

	local class = self:TradeGoodsClass()
	for id = 0, MAX_SUBCLASS do
		local name = GetItemSubClassInfo(class, id)
		if name and name ~= "" then subclassNames[id] = name end
	end

	return subclassNames
end

-- Discovered once per session. Nothing about the client's answer changes while
-- it is running, so this only exists for tests that stand in for another one.
function Send:ForgetTradeGoodsSubclasses()
	subclassNames = nil
end

-- What is in the bags right now, grouped by material. Only groups holding
-- something, because a row of empty buttons is worse than no row.
--
-- Soulbound items are not filtered out here. The cheap test is only available
-- on newer clients and the fallback reads a tooltip per item, which is too much
-- to spend on every refresh of the page. Attaching refuses them instead.
function Send:TradeGoodsInBags()
	local class = self:TradeGoodsClass()
	local names = self:TradeGoodsSubclasses()
	local groups, order = {}, {}

	ns.Compat:ForEachBag(function(bag)
		local slots = C_Container.GetContainerNumSlots(bag) or 0

		for slot = 1, slots do
			local link = C_Container.GetContainerItemLink(bag, slot)
			if link then
				local itemClass, subclass = ns.Compat:GetItemClass(link)
				if itemClass == class then
					local key = names[subclass] and subclass or FLAT
					local group = groups[key]

					if not group then
						group = {
							subclass = key,
							label = names[key] or (GetItemClassInfo and GetItemClassInfo(class))
								or "Trade Goods",
							items = {},
						}
						groups[key] = group
						order[#order + 1] = group
					end

					local info = ns.Compat:GetContainerItemInfo(bag, slot)
					group.items[#group.items + 1] = {
						bag = bag,
						slot = slot,
						name = link:match("|h%[(.-)%]|h"),
						count = (info and (info.stackCount or info.itemCount)) or 1,
					}
				end
			end
		end
	end)

	table.sort(order, function(left, right) return left.label < right.label end)
	return order
end

-- Attaching empties the bag slot it came from and leaves every other slot where
-- it was, so a list gathered up front stays valid all the way through.
function Send:AttachTradeGoods(subclass)
	local attached, refused, full = 0, 0, false

	for _, group in ipairs(self:TradeGoodsInBags()) do
		if group.subclass == subclass then
			for _, item in ipairs(group.items) do
				if not self:HasRoom() then
					full = true
					break
				end
				if self:AttachFromBag(item.bag, item.slot) then
					attached = attached + 1
				else
					refused = refused + 1
				end
			end
		end
	end

	return attached, refused, full
end

function Send:ClearAttachments()
	for index = ATTACHMENTS_MAX_SEND, 1, -1 do
		if HasSendMailItem(index) then
			ClickSendMailItemButton(index, true)
		end
	end
	announce()
end

-- Money
-- ---------------------------------------------------------------------------

function Send:SetMode(mode)
	self.mode = (mode == "cod") and "cod" or "money"
	announce()
end

function Send:GetMode()
	return self.mode
end

function Send:SetAmount(copper)
	self.amount = math.max(0, math.floor(tonumber(copper) or 0))
	announce()
end

function Send:GetAmount()
	return self.amount
end

function Send:GetPostage()
	return GetSendMailPrice() or 0
end

-- What actually leaves your bags: postage always, plus the attached money when
-- sending rather than charging on delivery.
function Send:GetTotalCost()
	local total = self:GetPostage()
	if self.mode == "money" then
		total = total + self.amount
	end
	return total
end

-- Validation
-- ---------------------------------------------------------------------------

-- Returns ok, reason. The reason is shown to the player, so it explains rather
-- than just refusing.
-- A blank subject on a mail carrying gold becomes the amount, which is what
-- the recipient wants to see anyway.
--
-- Plain text on purpose: a mail subject is not a font string and will not
-- render the texture escapes ns.Money produces, so the coin icons cannot be
-- used here.
-- The client caps a mail subject at 64 characters.
local SUBJECT_LIMIT = 64

local function textLength(text)
	return strlenutf8 and strlenutf8(text) or #text
end

-- Anything the client draws rather than spells out. A mail subject carrying a
-- texture, a colour code or a link is refused outright, which is what made a
-- gold only mail impossible to send with the subject Parcel filled in: the
-- coin icons are markup, so the server saw no subject at all.
local function plainText(text)
	if type(text) ~= "string" then return "" end

	text = text:gsub("|[Tt]......-|[Tt]", "")
	text = text:gsub("|A.-|a", "")
	text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
	text = text:gsub("|r", "")
	text = text:gsub("|H.-|h(.-)|h", "%1")
	text = text:gsub("|n", " ")

	return strtrim((text:gsub("%s+", " ")))
end

Send.plainText = plainText

function Send:HasMarkup(text)
	if type(text) ~= "string" then return false end
	return text:find("|", 1, true) ~= nil
end

local GOLD = 10000
local SILVER = 100

-- A localised amount, but only if the locale spells it out. Some carry plural
-- markers, which are markup like any other.
local function amount(pattern, fallback, value)
	if type(pattern) == "string" and not pattern:find("|", 1, true) then
		local ok, text = pcall(string.format, pattern, value)
		if ok then return text end
	end
	return fallback:format(value)
end

function Send:PlainMoney(copper)
	copper = math.floor(tonumber(copper) or 0)

	local gold = math.floor(copper / GOLD)
	local silver = math.floor((copper % GOLD) / SILVER)
	local units = copper % SILVER

	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = amount(GOLD_AMOUNT, "%d Gold", gold)
	end
	if silver > 0 then
		parts[#parts + 1] = amount(SILVER_AMOUNT, "%d Silver", silver)
	end
	if units > 0 or #parts == 0 then
		parts[#parts + 1] = amount(COPPER_AMOUNT, "%d Copper", units)
	end

	return table.concat(parts, " ")
end

-- What is attached, said in a way that fits a subject line. Nil when there is
-- nothing attached.
function Send:DescribeAttachments()
	local kinds, totals, attached = {}, {}, 0

	for index = 1, ATTACHMENTS_MAX_SEND do
		if HasSendMailItem(index) then
			attached = attached + 1
			local name, _, _, quantity = GetSendMailItem(index)
			if name and name ~= "" then
				-- The same item in several slots is one thing in three stacks,
				-- not three things. Counted together, listed once, in the order
				-- the slots run.
				if not totals[name] then
					kinds[#kinds + 1] = name
					totals[name] = 0
				end
				totals[name] = totals[name] + (quantity or 1)
			end
		end
	end

	if attached == 0 then return nil end
	-- Names arrive with the item data, so a slot the client has not caught up
	-- with yet still gets counted.
	if #kinds == 0 then return ("%d items"):format(attached) end

	local function say(name)
		local total = totals[name]
		return total > 1 and ("%s x%d"):format(name, total) or name
	end

	local text
	if #kinds == 1 then
		text = say(kinds[1])
	elseif #kinds == 2 then
		text = ("%s, %s"):format(say(kinds[1]), say(kinds[2]))
	else
		-- More kinds, not more slots: two stacks of the same thing already
		-- folded into one of these.
		text = ("%s, %s and %d more"):format(say(kinds[1]), say(kinds[2]), #kinds - 2)
	end

	-- A truncated item name reads worse than a plain count.
	if textLength(text) > SUBJECT_LIMIT then
		return ("%d items"):format(attached)
	end

	return text
end

function Send:EffectiveSubject(subject)
	subject = strtrim(subject or "")
	if subject ~= "" then return subject end

	local addon = ns.Addon
	local settings = addon and addon.db and addon.db.profile and addon.db.profile.send
	if settings and settings.autoSubject == false then return subject end

	-- Attachments first: what is in the mail says more than what it is worth,
	-- and the gold is visible on the mail either way.
	local attachments = self:DescribeAttachments()
	if attachments then return plainText(attachments) end

	if self.mode == "money" and self.amount > 0 then
		return self:PlainMoney(self.amount)
	end

	return subject
end

function Send:Validate(recipient, subject)
	if self.sending then
		return false, "Already sending."
	end

	recipient = strtrim(recipient or "")
	subject = self:EffectiveSubject(subject)

	if recipient == "" then
		return false, "Who is it going to?"
	end

	-- The server rejects this outright, so catching it here turns a silent
	-- failure into an answer.
	if ns.Roster:IsSelf(recipient) then
		return false, "You cannot send mail to yourself."
	end
	if subject == "" then
		return false, "Mail needs a subject."
	end

	-- Turns a silent refusal into an answer. The client accepts these into the
	-- box and the server then throws the mail away.
	if self:HasMarkup(subject) then
		return false, "A subject cannot contain icons or links."
	end

	if self.mode == "cod" then
		if self:CountAttachments() == 0 then
			return false, "Cash on delivery needs something attached."
		end
		if self.amount > MAX_COD then
			return false, ("Cash on delivery cannot be more than %s."):format(ns.Money(MAX_COD))
		end
	end

	if self:GetTotalCost() > GetMoney() then
		return false, "You cannot afford the postage."
	end

	return true
end

function Send:CanSend(recipient, subject)
	return (self:Validate(recipient, subject))
end

function Send:Send(recipient, subject, body)
	local ok, reason = self:Validate(recipient, subject)
	if not ok then
		return false, reason
	end

	subject = self:EffectiveSubject(subject)

	-- Both are cleared first because the client keeps whichever was set last,
	-- and a leftover value from a previous draft would ride along.
	SetSendMailCOD(0)
	SetSendMailMoney(0)

	if self.amount > 0 then
		if self.mode == "cod" then
			SetSendMailCOD(self.amount)
		else
			SetSendMailMoney(self.amount)
		end
	end

	-- Snapshotted before the send, because by the time it succeeds the client
	-- has already emptied the slots and there is nothing left to record.
	local items = {}
	for index = 1, ATTACHMENTS_MAX_SEND do
		if HasSendMailItem(index) then
			local name, itemID, _, count, quality = GetSendMailItem(index)
			items[#items + 1] = { id = itemID, name = name, n = count or 1, q = quality }
		end
	end

	self.pending = {
		recipient = strtrim(recipient),
		subject = strtrim(subject),
		money = (self.mode == "money") and self.amount or 0,
		cod = (self.mode == "cod") and self.amount or 0,
		items = items,
		postage = self:GetPostage(),
	}

	self.sending = true
	announce()

	SendMail(strtrim(recipient), strtrim(subject), body or "")
	return true
end

function Send:Reset()
	self.mode = "money"
	self.amount = 0
	self.sending = false
	SetSendMailCOD(0)
	SetSendMailMoney(0)
	announce()
end

-- The client only accepts attachments while it believes the compose pane is
-- open, which normally follows Blizzard's tab. Parcel drives it directly.
function Send:SetComposing(composing)
	if SetSendMailShowing then
		SetSendMailShowing(composing and true or false)
	end
end

-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("MAIL_SEND_INFO_UPDATE")
events:RegisterEvent("MAIL_SEND_SUCCESS")
events:RegisterEvent("MAIL_FAILED")
events:RegisterEvent("MAIL_LOCK_SEND_ITEMS")
events:RegisterEvent("MAIL_UNLOCK_SEND_ITEMS")

events:SetScript("OnEvent", function(_, event, ...)
	if event == "MAIL_SEND_INFO_UPDATE" then
		announce()

	elseif event == "MAIL_SEND_SUCCESS" then
		local sent = Send.pending
		Send.pending = nil
		Send.sending = false
		Send.amount = 0
		Send.mode = "money"
		Events:Trigger("Parcel.Send.Success", sent)
		announce()

	elseif event == "MAIL_FAILED" then
		Send.pending = nil
		Send.sending = false
		Events:Trigger("Parcel.Send.Failed")
		announce()

	elseif event == "MAIL_LOCK_SEND_ITEMS" then
		-- Mailing something still refundable forfeits the refund, and the
		-- confirmation for that lives in Blizzard's frame, which Parcel hides.
		-- Raising it here keeps the warning the player is entitled to.
		local slot, itemLink = ...
		if StaticPopupDialogs and StaticPopupDialogs["CONFIRM_MAIL_ITEM_UNREFUNDABLE"] then
			local name, _, quality, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemLink)
			local r, g, b = C_Item.GetItemQualityColor(quality or 1)
			StaticPopup_Show("CONFIRM_MAIL_ITEM_UNREFUNDABLE", nil, nil, {
				texture = texture,
				name = name,
				color = { r, g, b, 1 },
				link = itemLink,
				slot = slot,
			})
		end

	elseif event == "MAIL_UNLOCK_SEND_ITEMS" then
		if StaticPopup_Hide then
			StaticPopup_Hide("CONFIRM_MAIL_ITEM_UNREFUNDABLE")
		end
	end
end)
