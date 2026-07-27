local ADDON, ns = ...

-- Reading a mail, in Parcel's own panel beside the window.
--
-- Two modes off one layout. Live reads the mailbox and can act on it. History
-- reads an archived entry, shows what it was and what happened to it, and can
-- do nothing, because the mail is gone.

local Reader = {}
ns.Reader = Reader

local Kit = ns.Kit
local Mail = ns.Mail
local Window = ns.Window
local Events = ns.Events

local WIDTH = 340
local SLOT_SIZE = 34
local SLOTS_PER_ROW = 5
local PADDING = 18
local BODY_HEIGHT = 132

local frame
local handle
local archived
local pendingSlot
local selfDriven = false

-- COD mail charges you on taking, so it gets a confirmation of its own rather
-- than borrowing Blizzard's, whose accept handler reaches into their frame.
StaticPopupDialogs["PARCEL_COD_CONFIRM"] = {
	text = "%s\n\nTaking this costs %s.",
	button1 = ACCEPT,
	button2 = CANCEL,
	OnAccept = function()
		local record = Mail:Resolve(handle)
		if record and pendingSlot then
			TakeInboxItem(record.index, pendingSlot)
		end
		pendingSlot = nil
	end,
	OnCancel = function() pendingSlot = nil end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

local function record()
	if archived then return nil end
	return Mail:Resolve(handle)
end

-- Dates
-- ---------------------------------------------------------------------------

local function stamp(at)
	if not at or at <= 0 then return nil end
	return date("%d %b %H:%M", at)
end

-- The mail API never exposes an arrival date, only daysLeft counting down, so
-- arrival is expiry minus the thirty day lifetime and is marked approximate.
-- Everything else here is a moment Parcel witnessed and is exact.
local function dateLine(source)
	local parts = {}

	local arrived = stamp(source.at)
	if arrived then
		parts[#parts + 1] = "Received ~" .. arrived
	end

	local opened = stamp(source.opened)
	if opened then
		parts[#parts + 1] = "Opened " .. opened
	end

	local acted = stamp(source.dispAt)
	if acted and source.disp and source.disp ~= "inbox" then
		local verb = source.disp == "collected" and "Taken"
			or source.disp == "returned" and "Returned"
			or source.disp == "deleted" and "Deleted"
			or source.disp == "sent" and "Sent"
			or "Closed"
		parts[#parts + 1] = verb .. " " .. acted
	end

	return table.concat(parts, "   ")
end

-- Invoice
-- ---------------------------------------------------------------------------

local function invoiceLines(invoice)
	if not invoice then return nil end

	local lines = {}
	local player = invoice.player or UNKNOWN
	local item = invoice.item or ""
	if invoice.count and invoice.count > 1 then
		item = ("%s x%d"):format(item, invoice.count)
	end

	if invoice.kind == "buyer" then
		lines[#lines + 1] = ITEM_PURCHASED_COLON .. " " .. item
		lines[#lines + 1] = SOLD_BY_COLON .. " " .. player
		lines[#lines + 1] = ""
		lines[#lines + 1] = AMOUNT_PAID_COLON .. " " .. ns.Money(invoice.bid or 0)
	else
		lines[#lines + 1] = ITEM_SOLD_COLON .. " " .. item
		lines[#lines + 1] = PURCHASED_BY_COLON .. " " .. player
		lines[#lines + 1] = ""
		lines[#lines + 1] = SALE_PRICE_COLON .. " " .. ns.Money(invoice.bid or 0)
		lines[#lines + 1] = DEPOSIT_COLON .. " " .. ns.Money(invoice.deposit or 0)
		lines[#lines + 1] = AUCTION_HOUSE_CUT_COLON .. " " .. ns.Money(invoice.cut or 0)
		lines[#lines + 1] = ""
		lines[#lines + 1] = AMOUNT_RECEIVED_COLON .. " " .. ns.Money(
			(invoice.bid or 0) + (invoice.deposit or 0) - (invoice.cut or 0))
	end

	return table.concat(lines, "\n")
end

local function readInvoice(index)
	local kind, itemName, player, bid, buyout, deposit, cut,
		_, _, _, count = GetInboxInvoiceInfo(index)
	if not kind then return nil end
	return { kind = kind, item = itemName, player = player, bid = bid,
		buyout = buyout, deposit = deposit, cut = cut, count = count }
end

-- Frame
-- ---------------------------------------------------------------------------

local function build()
	if frame then return frame end

	frame = Kit:CreatePanel(UIParent, "ParcelReaderFrame")
	frame:SetSize(WIDTH, 476)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:Hide()
	tinsert(UISpecialFrames, "ParcelReaderFrame")

	frame.Sender = Kit:CreateText(frame, "title")
	frame.Sender:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + 4, -16)
	frame.Sender:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - 20, -16)
	frame.Sender:SetJustifyH("LEFT")
	frame.Sender:SetWordWrap(false)

	frame.Subject = Kit:CreateText(frame, "text")
	frame.Subject:SetPoint("TOPLEFT", frame.Sender, "BOTTOMLEFT", 0, -3)
	frame.Subject:SetPoint("TOPRIGHT", frame.Sender, "BOTTOMRIGHT", 0, -3)
	frame.Subject:SetJustifyH("LEFT")
	frame.Subject:SetWordWrap(false)

	frame.Dates = Kit:CreateText(frame, "dim")
	frame.Dates:SetPoint("TOPLEFT", frame.Subject, "BOTTOMLEFT", 0, -4)
	frame.Dates:SetPoint("TOPRIGHT", frame.Subject, "BOTTOMRIGHT", 0, -4)
	frame.Dates:SetJustifyH("LEFT")
	frame.Dates:SetWordWrap(false)

	frame.CloseX = CreateFrame("Button", nil, frame)
	frame.CloseX:SetSize(16, 16)
	frame.CloseX:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -16)
	frame.CloseX:SetScript("OnClick", function() Reader:Close() end)
	local cross = Kit:CreateText(frame.CloseX, "dim", "CENTER")
	cross:SetAllPoints()
	cross:SetText("x")

	local topDivider = Kit:CreateDivider(frame)
	topDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -74)
	topDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -74)

	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + 4, -84)
	scroll:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - 4, -84)
	scroll:SetHeight(BODY_HEIGHT)
	scroll:EnableMouseWheel(true)

	local body = CreateFrame("Frame", nil, scroll)
	body:SetSize(WIDTH - PADDING * 2 - 8, BODY_HEIGHT)
	scroll:SetScrollChild(body)

	frame.Body = Kit:CreateText(body, "text")
	frame.Body:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
	frame.Body:SetWidth(WIDTH - PADDING * 2 - 8)
	frame.Body:SetJustifyH("LEFT")
	frame.Body:SetJustifyV("TOP")
	frame.Body:SetSpacing(3)

	scroll:SetScript("OnMouseWheel", function(self, delta)
		local maximum = math.max(0, frame.Body:GetStringHeight() - BODY_HEIGHT)
		self:SetVerticalScroll(math.max(0, math.min(maximum, self:GetVerticalScroll() - delta * 30)))
	end)
	frame.Scroll = scroll

	local midDivider = Kit:CreateDivider(frame)
	midDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -224)
	midDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -224)

	frame.AttachLabel = Kit:CreateText(frame, "dim")
	frame.AttachLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + 4, -234)

	frame.Slots = {}
	for slot = 1, ATTACHMENTS_MAX_RECEIVE do
		local button = ns.Compat:CreateItemButton(frame)
		button:SetSize(SLOT_SIZE, SLOT_SIZE)

		local column = (slot - 1) % SLOTS_PER_ROW
		local row = math.floor((slot - 1) / SLOTS_PER_ROW)
		button:SetPoint("TOPLEFT", frame.AttachLabel, "BOTTOMLEFT",
			column * (SLOT_SIZE + 6), -6 - row * (SLOT_SIZE + 6))

		-- Archived mail disables its slots because there is nothing left to take.
		-- A disabled Button drops OnEnter/OnLeave unless this is set, which is why
		-- history attachments had no tooltip.
		button:SetMotionScriptsWhileDisabled(true)
		button:SetScript("OnClick", function() Reader:TakeSlot(slot) end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			local current = record()
			if current then
				GameTooltip:SetInboxItem(current.index, slot)
				if current.cod > 0 then
					GameTooltip:AddLine(("Costs %s on take."):format(ns.Money(current.cod)), 1, 0.4, 0.4)
				end
			elseif self.link then
				GameTooltip:SetHyperlink(self.link)
			elseif self.itemName then
				GameTooltip:SetText(self.itemName, 1, 1, 1)
			end
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function() GameTooltip:Hide() end)
		button:Hide()

		frame.Slots[slot] = button
	end

	frame.Money = Kit:CreateButton(frame, "", 150, function() Reader:TakeMoney() end)
	frame.Money:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING + 4, 84)
	frame.Money:Hide()

	frame.Notice = Kit:CreateText(frame, "dim")
	frame.Notice:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING + 4, 64)
	frame.Notice:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING - 4, 64)
	frame.Notice:Hide()

	local bottomDivider = Kit:CreateDivider(frame)
	bottomDivider:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING, 52)
	bottomDivider:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, 52)

	frame.TakeAll = Kit:CreateButton(frame, "Take All", 96, function() Reader:TakeAll() end)
	frame.TakeAll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING + 4, 18)

	frame.Reply = Kit:CreateButton(frame, "Reply", 88, function() Reader:Reply() end)
	frame.Reply:SetPoint("LEFT", frame.TakeAll, "RIGHT", 5, 0)

	frame.Dispose = Kit:CreateButton(frame, DELETE, 88, function() Reader:Dispose() end)
	frame.Dispose:SetPoint("LEFT", frame.Reply, "RIGHT", 5, 0)

	-- History only, and only for a record still saying waiting. Parcel can miss
	-- a mail leaving the mailbox, and an older build recorded some wrong, so the
	-- record has to be correctable by hand.
	frame.MarkTaken = Kit:CreateButton(frame, "Mark taken", 110, function() Reader:MarkTaken() end)
	frame.MarkTaken:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING + 4, 18)
	frame.MarkTaken:Hide()

	return frame
end

local function place()
	local parcel = Window:GetFrame()
	if not frame or not parcel then return end

	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", parcel, "TOPRIGHT", 6, 0)
end

-- Rendering
-- ---------------------------------------------------------------------------

local function showSlots(count)
	for slot = count + 1, ATTACHMENTS_MAX_RECEIVE do
		frame.Slots[slot]:Hide()
	end
	frame.AttachLabel:SetText(count > 0 and ("Attachments  %d"):format(count) or "No attachments")
end

-- The live view puts Reply back beside Take All, since Mark taken only ever
-- appears on history and would otherwise leave a hole.
local function restoreLiveButtons()
	frame.MarkTaken:Hide()
	frame.Reply:ClearAllPoints()
	frame.Reply:SetPoint("LEFT", frame.TakeAll, "RIGHT", 5, 0)
end

local function renderLive(current)
	restoreLiveButtons()

	frame.Sender:SetText(current.sender or UNKNOWN)
	frame.Subject:SetText(current.subject or "")

	local body = GetInboxText(current.index) or ""
	local invoice = invoiceLines(readInvoice(current.index))
	if invoice then
		body = (body ~= "" and (body .. "\n\n") or "") .. invoice
	end
	frame.Body:SetText(body)

	frame.Dates:SetText(dateLine({
		at = current.arrivedAt,
		opened = time(),
	}))

	local shown = 0
	for slot = 1, ATTACHMENTS_MAX_RECEIVE do
		local button = frame.Slots[slot]
		local name, itemID, texture, count, quality = GetInboxItem(current.index, slot)

		if name then
			button.link = GetInboxItemLink(current.index, slot)
			button.itemName = name
			SetItemButtonTexture(button, texture)
			SetItemButtonCount(button, count or 0)
			SetItemButtonQuality(button, quality, itemID)
			button:Enable()
			button:Show()
			shown = shown + 1
		else
			button:Hide()
		end
	end
	showSlots(shown)

	if current.money > 0 then
		frame.Money:SetText("Take " .. ns.Money(current.money))
		frame.Money:Show()
	else
		frame.Money:Hide()
	end

	if current.cod > 0 then
		frame.Notice:SetText(("|cffff6060Cash on delivery: %s|r"):format(ns.Money(current.cod)))
		frame.Notice:Show()
	else
		frame.Notice:Hide()
	end

	frame.TakeAll:Show()
	frame.Reply:Show()
	frame.Dispose:Show()
	frame.TakeAll:SetEnabled(current.cod == 0 and (shown > 0 or current.money > 0))
	-- The auction house does not read mail. Classified by subject rather than
	-- sender, so "Alliance Auction House" against "Horde Auction House" against
	-- every translation of both never has to be enumerated.
	frame.Reply:SetEnabled(current.canReply and not current.isGM
		and not Mail:IsAuction(current.mailType))
	frame.Dispose:SetText(InboxItemCanDelete(current.index) and DELETE or MAIL_RETURN)
	frame.Dispose:SetEnabled(true)
end

local function renderArchived(entry)
	frame.Sender:SetText(entry.who or UNKNOWN)
	frame.Subject:SetText(entry.subj or "")
	frame.Dates:SetText(dateLine(entry))

	local body = entry.body or ""
	local invoice = invoiceLines(entry.invoice)
	if invoice then
		body = (body ~= "" and (body .. "\n\n") or "") .. invoice
	end
	if body == "" then
		body = "|cff808080No message body was captured for this mail.|r"
	end
	frame.Body:SetText(body)

	local shown = 0
	for index, item in ipairs(entry.items or {}) do
		if index > ATTACHMENTS_MAX_RECEIVE then break end
		local button = frame.Slots[index]

		local name, _, quality, _, _, _, _, _, _, texture = C_Item.GetItemInfo(item.id or 0)
		-- The stored link carries enchants and suffixes; the bare item id is
		-- the fallback for mail archived before links were kept.
		button.link = item.l or (item.id and ("item:" .. item.id)) or nil
		button.itemName = item.name or name

		SetItemButtonTexture(button, texture or "Interface\\Icons\\INV_Misc_QuestionMark")
		SetItemButtonCount(button, item.n or 0)
		SetItemButtonQuality(button, item.q or quality, item.id)
		-- Nothing to take: this mail is gone.
		button:Disable()
		button:Show()
		shown = index
	end
	showSlots(shown)

	local value = (entry.money or 0) + (entry.cod or 0)
	if value > 0 then
		frame.Money:SetText(ns.Money(value))
		frame.Money:SetEnabled(false)
		frame.Money:Show()
	else
		frame.Money:Hide()
	end

	frame.Notice:SetText("|cff808080From your history. This mail is no longer in your mailbox.|r")
	frame.Notice:Show()

	frame.TakeAll:Hide()
	frame.Dispose:Hide()
	frame.Reply:Show()
	local auction = entry.mtype and entry.mtype:sub(1, 2) == "ah"
	frame.Reply:SetEnabled(entry.dir == "in" and entry.who ~= nil and not auction)

	local waiting = entry.dir == "in" and entry.disp == "inbox"
	frame.MarkTaken:SetShown(waiting)
	if waiting then
		frame.Reply:ClearAllPoints()
		frame.Reply:SetPoint("LEFT", frame.MarkTaken, "RIGHT", 5, 0)
	end
end

function Reader:Refresh()
	if not frame then return end

	if archived then
		renderArchived(archived)
		return
	end

	local current = record()
	if not current then
		self:Close()
		return
	end

	renderLive(current)
end

-- Actions
-- ---------------------------------------------------------------------------

function Reader:TakeSlot(slot)
	local current = record()
	if not current then return end

	if current.cod > 0 then
		if current.cod > GetMoney() then
			ns.Addon:Print("You cannot afford the cash on delivery charge.")
			return
		end
		pendingSlot = slot
		StaticPopup_Show("PARCEL_COD_CONFIRM", current.subject or "", ns.Money(current.cod))
		return
	end

	TakeInboxItem(current.index, slot)
end

function Reader:TakeMoney()
	local current = record()
	if current then
		TakeInboxMoney(current.index)
	end
end

function Reader:TakeAll()
	local current = record()
	if not current or current.cod > 0 then return end

	-- Through the queue like everything else, so bag space and pacing are
	-- handled the same way a full collect would handle them.
	selfDriven = true
	ns.Queue:Clear()
	ns.Queue:Push("drain", current)
	ns.Queue:Start()
	selfDriven = false
end

function Reader:Reply()
	local sender = archived and archived.who or nil
	local subject = archived and archived.subj or nil

	if not archived then
		local current = record()
		if not current then return end
		sender, subject = current.sender, current.subject
	end

	subject = subject or ""
	local prefix = (MAIL_REPLY_PREFIX or "RE:") .. " "
	if subject:sub(1, #prefix) ~= prefix then
		subject = prefix .. subject
	end

	ns.Compose:Open(sender, subject)
end

function Reader:Dispose()
	local current = record()
	if not current then return end

	selfDriven = true
	ns.Queue:Clear()
	ns.Queue:Push(InboxItemCanDelete(current.index) and "delete" or "return", current)
	ns.Queue:Start()
	selfDriven = false

	self:Close()
end

-- Lifecycle
-- ---------------------------------------------------------------------------

function Reader:Open(target)
	if not target then return end

	build()
	archived = nil
	handle = Mail:GetHandle(target)

	place()
	frame:Show()

	-- Capture before rendering, so the opened stamp exists to display.
	ns.Archive:CaptureBody(target)
	self:Refresh()
	frame.Scroll:SetVerticalScroll(0)
end

function Reader:OpenArchived(entry)
	if not entry then return end

	build()
	handle = nil
	archived = entry

	place()
	frame:Show()
	self:Refresh()
	frame.Scroll:SetVerticalScroll(0)
end

function Reader:MarkTaken()
	if not archived then return end

	if ns.Archive:SetDisposition(archived, "collected") then
		ns.Addon:Print(("Marked as collected: %s"):format(archived.subj or UNKNOWN))
	end

	self:Refresh()
end

function Reader:Close()
	handle = nil
	archived = nil
	pendingSlot = nil
	if frame then frame:Hide() end
end

function Reader:IsOpen()
	return frame and frame:IsShown()
end

Events:Register("Parcel.Mail.Closed", function()
	Reader:Close()
end)

-- Collecting empties mail out from underneath whatever is on screen, so a live
-- reader would be showing a mail that no longer exists. A run the reader itself
-- started is working on the mail being read, so that one stays open.
Events:Register("Parcel.Queue.Started", function()
	if Reader:IsOpen() and not archived and not selfDriven then
		Reader:Close()
	end
end)

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MAIL_INBOX_UPDATE")
watcher:SetScript("OnEvent", function()
	if Reader:IsOpen() and not archived then
		Reader:Refresh()
	end
end)
