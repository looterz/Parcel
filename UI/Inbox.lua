local ADDON, ns = ...

local Inbox = {}
ns.Inbox = Inbox

local Kit = ns.Kit
local Mail = ns.Mail
local Queue = ns.Queue
local Collect = ns.Collect
local Archive = ns.Archive
local Filters = ns.Filters
local Window = ns.Window
local Events = ns.Events

local ROW_HEIGHT = 26
local LIST_TOP = 52
local FOOTER_HEIGHT = 40

-- x is the offset from the list's left edge, so moving a column is one number.
local COLUMNS = {
	{ key = "sender", title = "From", x = 48, width = 120 },
	{ key = "subject", title = "Subject", x = 172, width = 210 },
	{ key = "money", title = "Value", x = 386, width = 120, justify = "RIGHT" },
	{ key = "expires", title = "Left", x = 510, width = 50, justify = "RIGHT" },
}

-- Both ship on every flavor Parcel supports.
local FATE_RETURN = "Interface\\ChatFrame\\ChatFrameExpandArrow"
local FATE_DELETE = "Interface\\RaidFrame\\ReadyCheck-NotReady"

-- Outside a mail session the client hands over no inbox data at all: the server
-- only sends the inbox on MAIL_SHOW and takes it away again on close. So away
-- from a mailbox the list shows what Parcel last recorded as waiting, clearly
-- marked, and every live action is off.
local function liveMode()
	return Collect:IsMailOpen()
end

local MAIL_ICON = "Interface\\Icons\\INV_Letter_15"

local function fromArchive(entry)
	local expires = entry.expires or 0
	local items = entry.items or {}
	local first = items[1]
	local icon = first and first.id and GetItemIcon and GetItemIcon(first.id)

	return {
		archived = entry,
		key = entry.key or entry.id or "",
		sender = entry.who,
		subject = entry.subj,
		money = entry.money or 0,
		cod = entry.cod or 0,
		itemCount = #items,
		expiresAt = expires,
		daysLeft = math.max(0, (expires - time()) / 86400),
		packageIcon = icon or MAIL_ICON,
	}
end

local page
local list
local selected = {}
local lastClicked
local search = ""
local sortKey, sortAscending = "expires", true
local visible = {}

-- Selection
-- ---------------------------------------------------------------------------

-- Kept as handles rather than as a key built from expiresAt. That value is
-- recomputed from a float daysLeft on every refresh and drifts by a second or
-- two, so an exact key silently lost the selection whenever mail arrived.

local function selectedIndex(record)
	for index, handle in ipairs(selected) do
		if Mail:Matches(record, handle) then return index end
	end
end

local function isSelected(record)
	return selectedIndex(record) ~= nil
end

local function setSelected(record, wanted)
	local index = selectedIndex(record)
	if wanted and not index then
		selected[#selected + 1] = Mail:GetHandle(record)
	elseif not wanted and index then
		table.remove(selected, index)
	end
end

local function clearSelection()
	wipe(selected)
	lastClicked = nil
end

local function selectedRecords()
	if not liveMode() then return {} end

	local out = {}
	for _, record in ipairs(Mail:GetRecords()) do
		if isSelected(record) then
			out[#out + 1] = record
		end
	end
	return out
end

local function toggle(record, shift, control)
	if control then
		-- Everything from the same sender moves to whatever this row is about to
		-- become, rather than each one flipping independently.
		local wanted = not isSelected(record)
		for _, other in ipairs(visible) do
			if other.sender == record.sender then
				setSelected(other, wanted)
			end
		end
		lastClicked = nil
		return
	end

	if shift and lastClicked then
		local from, to
		for index, other in ipairs(visible) do
			if Mail:Matches(other, lastClicked) then from = index end
			if other == record then to = index end
		end
		if from and to then
			for index = from, to, from <= to and 1 or -1 do
				setSelected(visible[index], true)
			end
			return
		end
	end

	local wanted = not isSelected(record)
	setSelected(record, wanted)
	lastClicked = wanted and Mail:GetHandle(record) or nil
end

-- Filtering and sorting
-- ---------------------------------------------------------------------------

local function matchesSearch(record)
	if search == "" then return true end

	local needle = search:lower()
	if (record.sender or ""):lower():find(needle, 1, true) then return true end
	if (record.subject or ""):lower():find(needle, 1, true) then return true end

	if record.archived then
		local entry = record.archived
		if (entry.body or ""):lower():find(needle, 1, true) then return true end
		for _, item in ipairs(entry.items or {}) do
			if (item.name or ""):lower():find(needle, 1, true) then return true end
		end
		return false
	end

	-- Item names only match once the client has them cached. An uncached name
	-- comes back nil and misses this pass; the next refresh catches it.
	for slot = 1, ATTACHMENTS_MAX_RECEIVE do
		local name = GetInboxItem(record.index, slot)
		if name and name:lower():find(needle, 1, true) then return true end
	end

	-- Body text cannot be read from the client without marking the mail read and
	-- creating a letter item in your bags, so this matches the copy the archive
	-- captured when the mail was opened rather than reaching for the live one.
	local archived = Archive:Find(record)
	if archived and (archived.body or ""):lower():find(needle, 1, true) then
		return true
	end

	return false
end

local COMPARATORS = {
	sender = function(a, b) return (a.sender or "") < (b.sender or "") end,
	subject = function(a, b) return (a.subject or "") < (b.subject or "") end,
	money = function(a, b) return a.money + a.cod < b.money + b.cod end,
	expires = function(a, b) return a.expiresAt < b.expiresAt end,
}

local function source()
	if liveMode() then return Mail:GetRecords() end

	local out = {}
	for _, entry in ipairs(Archive:Waiting(Archive:CurrentCharacter())) do
		out[#out + 1] = fromArchive(entry)
	end
	return out
end

local function rebuild()
	wipe(visible)

	for _, record in ipairs(source()) do
		if matchesSearch(record) then
			visible[#visible + 1] = record
		end
	end

	local comparator = COMPARATORS[sortKey] or COMPARATORS.expires
	table.sort(visible, function(a, b)
		if sortAscending then return comparator(a, b) end
		return comparator(b, a)
	end)

	if list then list:SetData(visible) end
	if page then page:UpdateChrome() end
end

-- Actions on a single mail
-- ---------------------------------------------------------------------------

local function openMail(record)
	ns.Reader:Open(record)
end

local function takeOne(record)
	if Queue:IsRunning() then return end
	if record.isGM or record.cod > 0 then
		ns.Addon:Print("That mail has to be opened by hand.")
		return
	end
	if record.money == 0 and record.itemCount == 0 then
		ns.Addon:Print("That mail has nothing to take.")
		return
	end
	Collect:OpenRecords({ record })
end

local function returnOne(record)
	if Queue:IsRunning() then return end
	if Collect:ReturnRecords({ record }) == 0 then
		ns.Addon:Print("That mail cannot be returned.")
	end
	Inbox:UpdateRows()
end

-- Delete is the one action here with nothing behind it, so it asks first. The
-- handle is carried rather than the record because the popup outlives a refresh.
StaticPopupDialogs["PARCEL_CONFIRM_DELETE"] = {
	text = "Delete this mail permanently?\n\n|cffffd100%s|r",
	button1 = YES,
	button2 = NO,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
	OnAccept = function(popup)
		local record = Mail:Resolve(popup.data)
		if not record then
			ns.Addon:Print("That mail is no longer there.")
			return
		end
		if Queue:Push("delete", record) then
			Queue:Start()
		end
	end,
}

local function disposeOne(record)
	if Queue:IsRunning() then return end

	if InboxItemCanDelete(record.index) then
		local popup = StaticPopup_Show("PARCEL_CONFIRM_DELETE", record.subject or UNKNOWN)
		if popup then popup.data = Mail:GetHandle(record) end
		return
	end

	returnOne(record)
end

-- Rows
-- ---------------------------------------------------------------------------

local function attachmentLines(record)
	local lines = {}

	for slot = 1, ATTACHMENTS_MAX_RECEIVE do
		local name, _, texture, count = GetInboxItem(record.index, slot)
		if name then
			local link = GetInboxItemLink(record.index, slot)
			local label = link or name
			if texture then
				label = ("|T%s:14:14:0:0:64:64:5:59:5:59|t %s"):format(texture, label)
			end
			lines[#lines + 1] = { label = label, count = (count or 1) > 1 and count or nil }
		end
	end

	return lines
end

local function showRowTooltip(row)
	local record = row.record
	if not record then return end

	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(record.sender or UNKNOWN, 1, 0.82, 0)
	if record.subject and record.subject ~= "" then
		GameTooltip:AddLine(record.subject, 1, 1, 1, true)
	end

	if record.archived then
		local entry = record.archived
		for _, item in ipairs(entry.items or {}) do
			GameTooltip:AddDoubleLine(item.name or UNKNOWN,
				(item.n or 1) > 1 and ("x" .. item.n) or " ", 1, 1, 1, 0.7, 0.7, 0.7)
		end
		if (entry.money or 0) > 0 then
			GameTooltip:AddDoubleLine("Enclosed", ns.Money(entry.money), 0.7, 0.7, 0.7, 1, 1, 1)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("From your history. Parcel last saw this waiting.", 0.6, 0.8, 1)
		GameTooltip:AddLine("Click to read it.", 0.5, 0.5, 0.5)
		GameTooltip:Show()
		return
	end

	local lines = attachmentLines(record)
	if #lines > 0 then
		GameTooltip:AddLine(" ")
		for _, line in ipairs(lines) do
			if line.count then
				GameTooltip:AddDoubleLine(line.label, "x" .. line.count, 1, 1, 1, 0.7, 0.7, 0.7)
			else
				GameTooltip:AddLine(line.label, 1, 1, 1)
			end
		end
		-- The client only hands over the first sixteen. A mail cannot hold more,
		-- so a shortfall here means item data has not arrived yet.
		if #lines < record.itemCount then
			GameTooltip:AddLine(("%d more still loading."):format(record.itemCount - #lines),
				0.6, 0.6, 0.6)
		end
	end

	if record.cod > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Cash on delivery: " .. ns.Money(record.cod), 1, 0.4, 0.4)
	elseif record.money > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Enclosed", ns.Money(record.money), 0.7, 0.7, 0.7, 1, 1, 1)
	end

	GameTooltip:AddLine(" ")
	if InboxItemCanDelete(record.index) then
		GameTooltip:AddLine("Deleted when it expires.", 0.95, 0.5, 0.5)
	else
		GameTooltip:AddLine("Returned to sender when it expires.", 0.6, 0.8, 1)
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click to open.", 0.5, 0.5, 0.5)
	if ns.Features:IsEnabled("rowShortcuts") then
		GameTooltip:AddLine("Shift-click to take the contents.", 0.5, 0.5, 0.5)
		GameTooltip:AddLine("Ctrl-click to return it to sender.", 0.5, 0.5, 0.5)
	end
	GameTooltip:AddLine("Right-click to select.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function createRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\WHITE8X8")

	local selection = row:CreateTexture(nil, "BACKGROUND")
	selection:SetAllPoints()
	selection:SetTexture("Interface\\Buttons\\WHITE8X8")
	selection:Hide()
	row.Selection = selection

	Kit:Adopt(row, function(_, palette)
		highlight:SetVertexColor(unpack(palette.rowHighlight))
		selection:SetVertexColor(unpack(palette.rowSelected))
	end)

	row.Check = Kit:CreateCheckbox(row, 18, function()
		if not row.record then return end
		toggle(row.record, IsShiftKeyDown(), IsControlKeyDown())
		Inbox:UpdateRows()
	end)
	row.Check:SetPoint("LEFT", row, "LEFT", 4, 0)

	row.Icon = row:CreateTexture(nil, "ARTWORK")
	row.Icon:SetSize(20, 20)
	row.Icon:SetPoint("LEFT", row, "LEFT", 24, 0)
	row.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	row.Columns = {}
	for _, column in ipairs(COLUMNS) do
		local text = Kit:CreateText(row, "text", column.justify)
		text:SetPoint("LEFT", row, "LEFT", column.x, 0)
		text:SetWidth(column.width)
		text:SetWordWrap(false)
		row.Columns[column.key] = text
	end

	-- What happens to this mail if you never come back for it. Anchored to the
	-- right edge rather than a fixed x so it survives a wider window.
	row.Fate = CreateFrame("Button", nil, row)
	row.Fate:SetSize(16, 16)
	row.Fate:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.Fate:SetNormalTexture(FATE_RETURN)
	row.Fate:SetScript("OnClick", function()
		if row.record and not row.record.archived then disposeOne(row.record) end
	end)
	row.Fate:SetScript("OnEnter", function(button)
		if not row.record or row.record.archived then return end
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
		if InboxItemCanDelete(row.record.index) then
			GameTooltip:AddLine("Deleted when it expires.", 1, 1, 1)
			GameTooltip:AddLine("Click to delete it now.", 0.95, 0.5, 0.5)
		else
			GameTooltip:AddLine("Returned to sender when it expires.", 1, 1, 1)
			GameTooltip:AddLine("Click to return it now.", 0.6, 0.8, 1)
		end
		GameTooltip:Show()
	end)
	row.Fate:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Selection keeps shift and ctrl for range and by-sender, which is what a
	-- list is expected to do, so the row body carries the Postal shortcuts.
	row:SetScript("OnClick", function(_, button)
		local record = row.record
		if not record then return end

		if record.archived then
			ns.Reader:OpenArchived(record.archived)
			return
		end

		if button == "RightButton" then
			toggle(record, IsShiftKeyDown(), IsControlKeyDown())
			Inbox:UpdateRows()
		elseif IsShiftKeyDown() and ns.Features:IsEnabled("rowShortcuts") then
			takeOne(record)
		elseif IsControlKeyDown() and ns.Features:IsEnabled("rowShortcuts") then
			returnOne(record)
		else
			openMail(record)
		end
	end)

	row:SetScript("OnEnter", function() showRowTooltip(row) end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	return row
end

local function updateRow(row, record)
	row.record = record

	local chosen = isSelected(record)
	row.Check:SetChecked(chosen)
	row.Selection:SetShown(chosen)
	row.Check:SetShown(not record.archived)

	row.Icon:SetTexture(record.packageIcon or record.stationeryIcon)

	row.Columns.sender:SetText(record.sender or UNKNOWN)
	row.Columns.subject:SetText(record.subject or "")

	if record.cod > 0 then
		row.Columns.money:SetText("|cffff6060COD " .. ns.Money(record.cod) .. "|r")
	elseif record.money > 0 then
		row.Columns.money:SetText(ns.Money(record.money))
	elseif record.itemCount > 0 then
		row.Columns.money:SetText(("%d items"):format(record.itemCount))
	else
		row.Columns.money:SetText("")
	end

	-- InboxItemCanDelete needs a live inbox index, which an archived row has no
	-- equivalent of, so the column simply stands down rather than guessing.
	row.Fate:SetShown(not record.archived)
	if not record.archived then
		row.Fate:SetNormalTexture(InboxItemCanDelete(record.index) and FATE_DELETE or FATE_RETURN)
	end

	if record.daysLeft >= 1 then
		row.Columns.expires:SetText(("%dd"):format(math.floor(record.daysLeft)))
		row.Columns.expires:SetTextColor(0.55, 0.85, 0.55)
	else
		row.Columns.expires:SetText(("%dh"):format(math.max(0, math.floor(record.daysLeft * 24))))
		row.Columns.expires:SetTextColor(0.95, 0.35, 0.35)
	end
end

function Inbox:UpdateRows()
	if list then list:Refresh() end
	if page then page:UpdateChrome() end
end

-- Page
-- ---------------------------------------------------------------------------

local function startCollect()
	if not liveMode() then
		ns.Addon:Print("Stand at a mailbox to collect.")
		return
	end

	-- Holding a modifier takes everything, which is the escape hatch for when
	-- the filters are set up for the usual case and this is not it.
	local override = IsShiftKeyDown() or IsControlKeyDown()
	local predicate = not override and Filters:Predicate() or nil

	if predicate then
		local wanted = 0
		for _, record in ipairs(Mail:GetRecords()) do
			if predicate(record) then wanted = wanted + 1 end
		end
		if wanted == 0 then
			ns.Addon:Print("Nothing here matches your collect filters. Shift-click Collect to take everything.")
			return
		end
	end

	Collect:Start(predicate)
end

local function build(host)
	local self = { frame = host }

	self.Search = Kit:CreateSearchBox(host, 200,
		"Search sender, subject, item or content", function(value)
			search = value
			rebuild()
		end)
	-- Anchored on both sides rather than sized from host:GetWidth(), which is
	-- not reliable on the tick the page is built.
	self.Search:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
	self.Search:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, 0)

	self.Headers = {}
	for _, column in ipairs(COLUMNS) do
		local header = Kit:CreateColumnHeader(host, column.title, column.width, column.justify, function()
			if sortKey == column.key then
				sortAscending = not sortAscending
			else
				sortKey = column.key
				sortAscending = true
			end
			rebuild()
		end)
		header:SetPoint("TOPLEFT", host, "TOPLEFT", column.x, -32)
		header.key = column.key
		self.Headers[#self.Headers + 1] = header
	end

	list = Kit:CreateScrollList(host, {
		rowHeight = ROW_HEIGHT,
		spacing = 1,
		createRow = createRow,
		updateRow = updateRow,
	})
	list:Fill(host, LIST_TOP, FOOTER_HEIGHT, 18)
	list.bar:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -LIST_TOP)
	list.bar:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, FOOTER_HEIGHT)

	self.CollectButton = Kit:CreateButton(host, "Collect", 116, startCollect)
	self.CollectButton:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
	self.CollectButton:SetScript("OnEnter", function(button)
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Collect", 1, 1, 1)
		local excluded = Filters:DisabledLabels()
		if #excluded > 0 then
			GameTooltip:AddLine("Skipping: " .. table.concat(excluded, ", "), 1, 0.82, 0, true)
			GameTooltip:AddLine("Shift-click to take everything anyway.", 0.5, 0.5, 0.5)
		else
			GameTooltip:AddLine("Takes everything in the mailbox.", 0.7, 0.7, 0.7)
		end
		GameTooltip:Show()
	end)
	self.CollectButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	self.OpenButton = Kit:CreateButton(host, "Open", 84, function()
		local records = selectedRecords()
		if Collect:OpenRecords(records) == 0 then
			ns.Addon:Print("Nothing selected can be opened.")
		end
		clearSelection()
		Inbox:UpdateRows()
	end)
	self.OpenButton:SetPoint("LEFT", self.CollectButton, "RIGHT", 6, 0)

	self.ReturnButton = Kit:CreateButton(host, "Return", 90, function()
		local queued = Collect:ReturnRecords(selectedRecords())
		if queued == 0 then
			ns.Addon:Print("Nothing selected can be returned.")
		end
		clearSelection()
		Inbox:UpdateRows()
	end)
	self.ReturnButton:SetPoint("LEFT", self.OpenButton, "RIGHT", 6, 0)

	-- The client hands over a hundred mails at a time and rate limits asking for
	-- more, so a big mailbox fills in over several passes. This is the manual
	-- nudge for when you do not want to wait for the automatic ones.
	self.RefreshButton = Kit:CreateButton(host, "Refresh", 96, function()
		if Mail:RequestRefresh() then
			Mail:StartTopUp()
			ns.Addon:Print("Asking the server for more mail.")
		else
			local _, wait = Mail:CanRefresh()
			ns.Addon:Print(("The server allows another refresh in %d seconds."):format(
				math.ceil(wait or 0)))
		end
	end)
	self.RefreshButton:SetPoint("LEFT", self.ReturnButton, "RIGHT", 6, 0)

	self.SelectionText = Kit:CreateText(host, "dim")
	self.SelectionText:SetPoint("LEFT", self.RefreshButton, "RIGHT", 12, 0)

	-- Sits in the footer rather than above the list, so changing mode never
	-- moves the rows out from under the cursor. It never shows at the same time
	-- as the selection count, which is why they share an anchor.
	self.Notice = Kit:CreateText(host, "dim")
	self.Notice:SetPoint("LEFT", self.RefreshButton, "RIGHT", 12, 0)
	self.Notice:SetPoint("RIGHT", host, "RIGHT", -4, 0)
	self.Notice:SetWordWrap(false)
	self.Notice:Hide()

	self.Empty = Kit:CreateText(host, "dim", "CENTER")
	self.Empty:SetPoint("CENTER", host, "CENTER", 0, 0)
	self.Empty:Hide()

	function self:UpdateChrome()
		if not liveMode() then
			local waiting = #visible

			Window:SetSummary(waiting > 0
				and ("|cffffcc00History mode|r  %d last seen waiting"):format(waiting)
				or "|cffffcc00History mode|r")

			self.Notice:SetText("|cffffcc00Not at a mailbox.|r Showing what Parcel last saw.")
			self.Notice:Show()
			self.SelectionText:SetText("")

			self.CollectButton:SetText("Collect")
			self.CollectButton:SetEnabled(false)
			self.OpenButton:SetEnabled(false)
			self.ReturnButton:SetEnabled(false)
			self.RefreshButton:SetText("Refresh")
			self.RefreshButton:SetEnabled(false)

			self.Empty:SetText("Nothing recorded as waiting.\nHistory has everything Parcel has ever seen.")
			self.Empty:SetShown(waiting == 0)

			for _, header in ipairs(self.Headers) do
				header:SetSort(header.key == sortKey and (sortAscending and "asc" or "desc") or nil)
			end
			return
		end

		self.Notice:Hide()
		self.Empty:Hide()

		local shown, total = Mail:GetCounts()
		local money, attachments, expiring = Mail:GetTotals()

		local summary = ("%d mails  %d attachments  %s"):format(total, attachments, ns.Money(money))
		if total > shown then
			-- Say why rather than just showing a smaller number than the player
			-- can count in their own mailbox.
			summary = summary .. ("  |cffffcc00showing %d, the server sends the rest as room frees up|r")
				:format(shown)
		end
		if expiring > 0 then
			summary = summary .. ("  |cffff6060%d expiring|r"):format(expiring)
		end
		Window:SetSummary(summary)

		local count = #selected
		self.SelectionText:SetText(count > 0 and ("%d selected"):format(count) or "")

		local running = Queue:IsRunning()
		self.ReturnButton:SetEnabled(count > 0 and not running)
		self.OpenButton:SetEnabled(count > 0 and not running)

		local canRefresh, wait = Mail:CanRefresh()
		self.RefreshButton:SetEnabled(not running and canRefresh)
		self.RefreshButton:SetText(canRefresh and "Refresh"
			or ("Refresh %ds"):format(math.ceil(wait or 0)))

		if running then
			local done, queued = Queue:GetProgress()
			self.CollectButton:SetText(("Collecting %d/%d"):format(done, queued))
			self.CollectButton:SetEnabled(false)
		else
			self.CollectButton:SetText(Filters:AllEnabled() and "Collect" or "Collect *")
			self.CollectButton:SetEnabled(shown > 0)
		end

		for _, header in ipairs(self.Headers) do
			header:SetSort(header.key == sortKey and (sortAscending and "asc" or "desc") or nil)
		end
	end

	function self:Refresh()
		rebuild()
	end

	function self:OnShow()
		clearSelection()
		rebuild()
		list:ScrollToTop()

		-- A mailbox with more than the client will hand over needs several
		-- rounds to fill in, so start them as soon as the page is looked at.
		if liveMode() and Mail:HasHiddenMail() then
			Mail:StartTopUp()
		end
	end

	-- The cooldown expires on a clock, not on an event, so nothing would have
	-- re-enabled the button. It used to sit greyed out until some mail happened
	-- to arrive.
	local sinceTick = 0
	host:SetScript("OnUpdate", function(_, elapsed)
		sinceTick = sinceTick + elapsed
		if sinceTick < 0.5 then return end
		sinceTick = 0
		if self.UpdateChrome then self:UpdateChrome() end
	end)

	function self:OnHide()
		Mail:StopTopUp()
	end

	page = self
	return self
end

Window:AddPage("inbox", "Inbox", build)

-- Wiring
-- ---------------------------------------------------------------------------

-- Arriving at or leaving a mailbox flips the whole page between live and
-- history, so both have to redraw it.
Events:Register("Parcel.Archive.Changed", function()
	if page and page.frame:IsShown() and not liveMode() then rebuild() end
end)

Events:Register("Parcel.Mail.Opened", function()
	if page and page.frame:IsShown() then rebuild() end
end)

Events:Register("Parcel.Mail.Closed", function()
	if page and page.frame:IsShown() then rebuild() end
end)

Events:Register("Parcel.Collect.Changed", function()
	if page and page.frame:IsShown() then
		rebuild()
	end
end)

-- Mail arriving, being read elsewhere, or being taken by Blizzard's own buttons
-- all land here. While the queue is running it has already refreshed the model,
-- so this only redraws.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MAIL_INBOX_UPDATE")
watcher:SetScript("OnEvent", function()
	if not page or not page.frame:IsShown() then return end
	if not Queue:IsRunning() then
		Mail:Refresh()
	end
	rebuild()
end)
