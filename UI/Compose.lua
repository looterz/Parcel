local ADDON, ns = ...

local Compose = {}
ns.Compose = Compose

local Kit = ns.Kit
local Drafts = ns.Drafts

-- The dropdown always carries a first entry that is a label rather than a
-- draft, so it reads as a control instead of looking pre-filled.
local NONE_KEY = "none"
local Send = ns.Send
local Window = ns.Window
local Events = ns.Events

local SLOT_SIZE = 34
-- Beside the twelve slots, which stop six across.
local QUICK_LEFT = 6 * (34 + 6) + 14
local QUICK_WIDTH, QUICK_HEIGHT = 150, 20
local QUICK_COLUMNS, QUICK_MAX = 2, 8
local SLOTS_PER_ROW = 6

local page

local function build(host)
	local self = { frame = host }

	-- Labelled inside rather than beside, so the fields start at the same left
	-- edge as the body, the attachments and the buttons. A label column would
	-- indent only these two, and putting labels above costs enough height to
	-- push the money row into the footer.
	self.Recipient = Kit:CreateInput(host, 240, 22, function() self:Refresh() end)
	self.Recipient:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -2)
	self.Recipient:SetPlaceholder("To")

	-- Attached after the change handler, because AttachAutoComplete hooks the
	-- scripts it needs and a later SetScript would replace the lot.
	Kit:AttachAutoComplete(self.Recipient, function(text)
		return ns.Roster:Suggest(text, 8)
	end, function()
		self:Refresh()
	end)

	-- Recents first, because the name you want is usually one you used lately.
	self.RecentPicker = Kit:CreateDropdown(host, 150, function(value)
		if value == NONE_KEY then return end
		self.Recipient:SetValueQuiet(value)
		self:Refresh()
	end)
	self.RecentPicker:SetPoint("LEFT", self.Recipient, "RIGHT", 8, 0)

	self.AddressBookButton = Kit:CreateButton(host, "Address Book", 116, function()
		ns.AddressBook:Toggle(function(name)
			self.Recipient:SetValueQuiet(name)
			self:Refresh()
		end)
	end)
	self.AddressBookButton:SetPoint("LEFT", self.RecentPicker, "RIGHT", 6, 0)

	function self:RefreshRecents()
		local options = { { value = NONE_KEY, label = "Recent" } }
		for _, name in ipairs(ns.Roster:GetRecent()) do
			options[#options + 1] = { value = name, label = name }
		end

		self.RecentPicker:SetOptions(options)
		self.RecentPicker:SetValue(NONE_KEY)
	end

	self.Subject = Kit:CreateInput(host, 240, 22, function() self:Refresh() end)
	self.Subject:SetPoint("TOPLEFT", self.Recipient, "BOTTOMLEFT", 0, -8)
	self.Subject.EditBox:SetMaxLetters(64)

	-- Body
	-- -----------------------------------------------------------------------

	local bodyHolder = CreateFrame("Frame", nil, host, BackdropTemplateMixin and "BackdropTemplate" or nil)
	bodyHolder:SetPoint("TOPLEFT", self.Subject, "BOTTOMLEFT", 0, -12)
	bodyHolder:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, 0)
	bodyHolder:SetHeight(120)

	Kit:Adopt(bodyHolder, function(frame, palette)
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(unpack(palette.inputBackdrop))
		frame:SetBackdropBorderColor(palette.dim[1], palette.dim[2], palette.dim[3], 0.7)
	end)

	local scroll = CreateFrame("ScrollFrame", nil, bodyHolder)
	scroll:SetPoint("TOPLEFT", bodyHolder, "TOPLEFT", 7, -6)
	scroll:SetPoint("BOTTOMRIGHT", bodyHolder, "BOTTOMRIGHT", -7, 6)

	local body = CreateFrame("EditBox", nil, scroll)
	body:SetMultiLine(true)
	body:SetAutoFocus(false)
	body:SetFontObject(Kit.fonts.body)
	body:SetWidth(440)
	body:SetHeight(108)
	body:SetMaxLetters(500)
	body:SetScript("OnEscapePressed", body.ClearFocus)
	scroll:SetScrollChild(body)
	self.Body = body

	bodyHolder:EnableMouse(true)
	bodyHolder:SetScript("OnMouseDown", function() body:SetFocus() end)

	-- Attachments
	-- -----------------------------------------------------------------------

	local attachLabel = Kit:CreateText(host, "dim")
	attachLabel:SetPoint("TOPLEFT", bodyHolder, "BOTTOMLEFT", 0, -10)
	attachLabel:SetText("Attachments")
	self.AttachLabel = attachLabel

	self.Slots = {}
	for index = 1, ATTACHMENTS_MAX_SEND do
		local slot = ns.Compat:CreateItemButton(host)
		slot:SetSize(SLOT_SIZE, SLOT_SIZE)
		slot:SetID(index)
		slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		local column = (index - 1) % SLOTS_PER_ROW
		local row = math.floor((index - 1) / SLOTS_PER_ROW)
		slot:SetPoint("TOPLEFT", attachLabel, "BOTTOMLEFT",
			column * (SLOT_SIZE + 6), -6 - row * (SLOT_SIZE + 6))

		slot:SetScript("OnClick", function(_, button)
			Send:ClickSlot(index, button == "RightButton")
		end)
		slot:SetScript("OnReceiveDrag", function()
			Send:ClickSlot(index)
		end)
		slot:SetScript("OnEnter", function(button)
			if not HasSendMailItem(index) then return end
			GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
			GameTooltip:SetSendMailItem(index)
			GameTooltip:Show()
		end)
		slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

		self.Slots[index] = slot
	end

	-- Money
	-- -----------------------------------------------------------------------

	local firstSlot = self.Slots[1]

	self.MoneyRadio = Kit:CreateRadio(host, "Send money", function()
		Send:SetMode("money")
	end)
	-- Quick attach, in the space beside the slots. Two rows of six leaves most
	-- of the width empty, which is where these go.
	self.QuickLabel = Kit:CreateText(host, "dim")
	self.QuickLabel:SetPoint("TOPLEFT", attachLabel, "TOPLEFT", QUICK_LEFT, 0)
	self.QuickLabel:SetText("Quick attach")
	self.QuickLabel:Hide()

	self.QuickButtons = {}
	for index = 1, QUICK_MAX do
		local column = (index - 1) % QUICK_COLUMNS
		local row = math.floor((index - 1) / QUICK_COLUMNS)

		local button = Kit:CreateButton(host, "", QUICK_WIDTH, function()
			local group = self.QuickButtons[index].group
			if not group then return end

			local attached, refused, full = Send:AttachTradeGoods(group.subclass)
			if attached > 0 then
				self:Refresh()
			end

			if full then
				ns.Addon:Print(("Attached %d, and the mail is full."):format(attached))
			elseif refused > 0 then
				ns.Addon:Print(("Attached %d, left %d that cannot be mailed."):format(
					attached, refused))
			end
		end)
		button:SetHeight(QUICK_HEIGHT)
		button:SetPoint("TOPLEFT", attachLabel, "BOTTOMLEFT",
			QUICK_LEFT + column * (QUICK_WIDTH + 4), -6 - row * (QUICK_HEIGHT + 4))
		button:Hide()

		self.QuickButtons[index] = button
	end

	self.MoneyRadio:SetPoint("TOPLEFT", firstSlot, "BOTTOMLEFT", 0, -14 - (SLOT_SIZE + 6))

	self.CodRadio = Kit:CreateRadio(host, "Cash on delivery", function()
		Send:SetMode("cod")
	end)
	self.CodRadio:SetPoint("LEFT", self.MoneyRadio, "LEFT", 130, 0)

	self.Money = Kit:CreateMoneyInput(host, function(copper)
		Send:SetAmount(copper)
	end)
	self.Money:SetPoint("TOPLEFT", self.MoneyRadio, "BOTTOMLEFT", 0, -10)

	self.Cost = Kit:CreateText(host, "dim", "RIGHT")
	self.Cost:SetPoint("RIGHT", host, "RIGHT", -4, 0)
	self.Cost:SetPoint("TOP", self.Money, "TOP", 0, -4)

	-- Footer
	-- -----------------------------------------------------------------------

	self.SendButton = Kit:CreateButton(host, "Send", 120, function()
		local ok, reason = Send:Send(self.Recipient:GetValue(), self.Subject:GetValue(), body:GetText())
		if not ok then
			ns.Addon:Print(reason)
		end
	end)
	self.SendButton:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)

	self.ClearButton = Kit:CreateButton(host, "Clear", 100, function()
		self:Clear()
	end)
	self.ClearButton:SetPoint("LEFT", self.SendButton, "RIGHT", 6, 0)

	-- Drafts
	-- -----------------------------------------------------------------------

	self.DraftPicker = Kit:CreateDropdown(host, 170, function(value)
		if value == NONE_KEY then return end
		self:LoadDraft(value)
	end)
	self.DraftPicker:SetPoint("LEFT", self.ClearButton, "RIGHT", 10, 0)

	self.SaveDraftButton = Kit:CreateButton(host, "Save draft", 104, function()
		local popup = StaticPopup_Show("PARCEL_NAME_DRAFT")
		if popup then popup.data = self end
	end)
	self.SaveDraftButton:SetPoint("LEFT", self.DraftPicker, "RIGHT", 6, 0)

	self.DeleteDraftButton = Kit:CreateButton(host, "Delete", 78, function()
		local name = self.DraftPicker:GetValue()
		if not name or name == NONE_KEY then
			ns.Addon:Print("Pick a draft first.")
			return
		end
		if Drafts:Delete(name) then
			ns.Addon:Print(("Deleted the draft %s."):format(name))
		end
		self:RefreshDrafts()
	end)
	self.DeleteDraftButton:SetPoint("LEFT", self.SaveDraftButton, "RIGHT", 6, 0)

	function self:CurrentDraft()
		return {
			to = self.Recipient:GetValue(),
			subject = self.Subject:GetValue(),
			body = body:GetText(),
			mode = Send:GetMode(),
			amount = Send:GetAmount(),
		}
	end

	function self:LoadDraft(name, quiet)
		local draft = Drafts:Get(name)
		if not draft then return end

		self.loadedDraft = name

		self.Recipient:SetValueQuiet(draft.to or "")
		self.Subject:SetValue(draft.subject or "")
		body:SetText(draft.body or "")

		Send:SetMode(draft.mode or "money")
		Send:SetAmount(draft.amount or 0)
		self.Money:SetCopper(draft.amount or 0)

		self:Refresh()

		if not quiet then
			-- Said out loud because attachments cannot come back with a draft and
			-- a silently empty attachment row would look like a bug.
			ns.Addon:Print(("Loaded the draft %s. Attach any items again before sending."):format(name))
		end
	end

	function self:RefreshDrafts()
		local options = { { value = NONE_KEY, label = "Drafts" } }
		for _, name in ipairs(Drafts:List()) do
			options[#options + 1] = { value = name, label = name }
		end

		self.DraftPicker:SetOptions(options)

		-- Keep the draft on screen if it is still there, so a reload after
		-- sending does not look like nothing is selected.
		local keep = self.loadedDraft and Drafts:Get(self.loadedDraft) and self.loadedDraft
		if not keep then self.loadedDraft = nil end
		self.DraftPicker:SetValue(keep or NONE_KEY)

		local on = Drafts:IsEnabled()
		self.DraftPicker:SetShown(on)
		self.SaveDraftButton:SetShown(on)
		self.DeleteDraftButton:SetShown(on)
	end

	function self:Clear()
		self.loadedDraft = nil
		if self.DraftPicker then self.DraftPicker:SetValue(NONE_KEY) end
		self.Recipient:SetValueQuiet("")
		self.Subject:SetValue("")
		body:SetText("")
		self.Money:Clear()
		Send:ClearAttachments()
		Send:Reset()
		self:Refresh()
	end

	function self:RefreshQuickAttach()
		local groups = Send:TradeGoodsInBags()

		for index, button in ipairs(self.QuickButtons) do
			local group = groups[index]
			button.group = group

			if group then
				local stacks = #group.items
				button:SetText(("%s  (%d)"):format(group.label, stacks))
				button:SetEnabled(Send:HasRoom() and not Send:IsLocked())
				button:Show()
			else
				button:Hide()
			end
		end

		self.QuickLabel:SetShown(groups[1] ~= nil)
	end

	function self:Refresh()
		-- What will actually be sent if the subject is left blank, and the label
		-- when there is nothing to fill in.
		self:RefreshQuickAttach()

		local auto = Send:EffectiveSubject("")
		self.Subject:SetPlaceholder(auto ~= "" and auto or "Subject")

		for index = 1, ATTACHMENTS_MAX_SEND do
			local slot = self.Slots[index]
			local name, itemID, texture, count, quality = Send:GetAttachment(index)

			if name then
				SetItemButtonTexture(slot, texture)
				SetItemButtonCount(slot, count or 0)
				SetItemButtonQuality(slot, quality, itemID)
			else
				SetItemButtonTexture(slot, nil)
				SetItemButtonCount(slot, 0)
				SetItemButtonQuality(slot, nil)
			end
		end

		local attached = Send:CountAttachments()
		self.AttachLabel:SetText(attached > 0
			and ("Attachments  %d/%d"):format(attached, ATTACHMENTS_MAX_SEND)
			or "Attachments")

		local mode = Send:GetMode()
		self.MoneyRadio:SetSelected(mode == "money")
		self.CodRadio:SetSelected(mode == "cod")

		local postage = Send:GetPostage()
		local total = Send:GetTotalCost()
		if total > postage then
			self.Cost:SetText(("Postage %s   Total %s"):format(ns.Money(postage), ns.Money(total)))
		else
			self.Cost:SetText(("Postage %s"):format(ns.Money(postage)))
		end

		local ok = Send:CanSend(self.Recipient:GetValue(), self.Subject:GetValue())
		self.SendButton:SetEnabled(ok)

		Window:SetSummary(attached > 0
			and ("%d attached"):format(attached)
			or "")
	end

	function self:OnShow()
		self:RefreshDrafts()
		self:RefreshRecents()

		-- The client only accepts attachments while it believes the compose
		-- pane is open, which normally follows Blizzard's tab.
		Send:SetComposing(true)

		-- Only into an empty field, so this can never overwrite a name that was
		-- put there by Reply or by the player.
		local settings = ns.Addon.db.profile.send
		if settings.autofillRecipient and self.Recipient:GetValue() == "" then
			local recent = ns.Roster:GetRecent()[1]
			if recent then self.Recipient:SetValueQuiet(recent) end
		end

		self:Refresh()
	end

	function self:OnHide()
		Send:SetComposing(false)
		ns.AddressBook:Close()
	end

	page = self
	return self
end

StaticPopupDialogs["PARCEL_NAME_DRAFT"] = {
	text = "Name this draft",
	button1 = SAVE or "Save",
	button2 = CANCEL,
	hasEditBox = true,
	maxLetters = 40,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
	OnAccept = function(popup)
		local page = popup.data
		local box = popup.editBox or (popup.GetEditBox and popup:GetEditBox())
		if not page or not box then return end

		local ok, reason = Drafts:Save(box:GetText(), page:CurrentDraft())
		if ok then
			ns.Addon:Print(("Saved the draft %s."):format(strtrim(box:GetText())))
			page:RefreshDrafts()
		else
			ns.Addon:Print(reason or "That draft could not be saved.")
		end
	end,
	EditBoxOnEnterPressed = function(box)
		local popup = box:GetParent()
		if StaticPopupDialogs["PARCEL_NAME_DRAFT"].OnAccept then
			StaticPopupDialogs["PARCEL_NAME_DRAFT"].OnAccept(popup)
		end
		popup:Hide()
	end,
	EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
}

Events:Register("Parcel.Features.Changed", function(key)
	if key == "drafts" and page and page.RefreshDrafts then
		page:RefreshDrafts()
	end
end)

Window:AddPage("send", "Send", build)

Events:Register("Parcel.Send.Changed", function()
	if page and page.frame:IsShown() then
		page:Refresh()
	end
end)

Events:Register("Parcel.Send.Success", function(sent)
	ns.Addon:Print("Mail sent.")
	if not page then return end

	page:RefreshRecents()

	-- Sending the same thing repeatedly is the point of a draft, so it is put
	-- straight back rather than leaving an empty form to fill in again.
	if page.loadedDraft and Drafts:Get(page.loadedDraft) then
		page:LoadDraft(page.loadedDraft, true)
		page.DraftPicker:SetValue(page.loadedDraft)

		local attached = sent and sent.items and #sent.items or 0
		if attached > 0 then
			ns.Addon:Print(("Draft %s is ready again. Attach the items before sending."):format(
				page.loadedDraft))
		else
			ns.Addon:Print(("Draft %s is ready again."):format(page.loadedDraft))
		end
		return
	end

	page.Recipient:SetValueQuiet("")
	page.Subject:SetValue("")
	page.Body:SetText("")
	page.Money:Clear()
	page:Refresh()
end)

Events:Register("Parcel.Send.Failed", function()
	ns.Addon:Print("The mail could not be sent.")
end)

-- Composing a reply or a forward opens the window straight onto this page with
-- the fields already filled in.
function Compose:Open(recipient, subject, bodyText)
	Window:Show("send")
	if not page then return end

	if recipient then page.Recipient:SetValueQuiet(recipient) end
	if subject then page.Subject:SetValue(subject) end
	if bodyText then page.Body:SetText(bodyText) end
	page:Refresh()
end

-- Reading a mail still uses Blizzard's open mail window, and its Reply button
-- switches Blizzard's mail frame to the compose tab. That frame is hidden while
-- Parcel is standing in for it, so the reply would go somewhere invisible.
-- Blizzard has already worked out the recipient and the prefixed subject by the
-- time this runs, so they are read back rather than recomputed.
hooksecurefunc("OpenMail_Reply", function()
	if not Window:IsShown() then return end

	local recipient = SendMailNameEditBox and SendMailNameEditBox:GetText() or ""
	local subject = SendMailSubjectEditBox and SendMailSubjectEditBox:GetText() or ""

	Compose:Open(recipient, subject)
	page.Body:SetFocus()
end)
