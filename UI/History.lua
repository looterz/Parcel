local ADDON, ns = ...

local History = {}
ns.History = History

local Kit = ns.Kit
local Archive = ns.Archive
local Window = ns.Window
local Events = ns.Events

local ROW_HEIGHT = 26
local LIST_TOP = 78
local FOOTER_HEIGHT = 28

local COLUMNS = {
	{ key = "when", title = "When", x = 4, width = 92 },
	{ key = "who", title = "From / To", x = 100, width = 112 },
	{ key = "subject", title = "Subject", x = 216, width = 190 },
	{ key = "value", title = "Value", x = 410, width = 100, justify = "RIGHT" },
	{ key = "state", title = "", x = 514, width = 56, justify = "RIGHT" },
}

local FILTERS = {
	{ key = "all", label = "All", direction = nil },
	{ key = "in", label = "Received", direction = "in" },
	{ key = "out", label = "Outbox", direction = "out" },
}

local STATE_LABEL = {
	inbox = "waiting",
	collected = "taken",
	returned = "returned",
	deleted = "deleted",
	sent = "sent",
}

local STATE_COLOR = {
	inbox = { 1, 0.82, 0 },
	collected = { 0.55, 0.85, 0.55 },
	returned = { 0.85, 0.7, 0.4 },
	deleted = { 0.8, 0.4, 0.4 },
	sent = { 0.6, 0.75, 0.95 },
}

local page
local list
local search = ""
local filter = "all"
local character
local results = {}
local nearMatches = false

-- nil means every character. Defaults to whoever is logged in, because that is
-- almost always what you came to look at.
local ALL = "all"

local function characterOptions()
	local options = { { value = ALL, label = "All characters" } }
	for _, name in ipairs(Archive:GetCharacters()) do
		options[#options + 1] = { value = name, label = name }
	end
	return options
end

local function ageText(at)
	if not at or at <= 0 then return "" end

	local elapsed = time() - at
	if elapsed < 3600 then
		return ("%dm ago"):format(math.max(1, math.floor(elapsed / 60)))
	elseif elapsed < 86400 then
		return ("%dh ago"):format(math.floor(elapsed / 3600))
	elseif elapsed < 86400 * 30 then
		return ("%dd ago"):format(math.floor(elapsed / 86400))
	end
	return date("%d %b", at)
end

local function rebuild()
	local direction
	for _, entry in ipairs(FILTERS) do
		if entry.key == filter then direction = entry.direction end
	end

	results, nearMatches = Archive:Search(search, direction, character)

	if list then list:SetData(results) end
	if page then page:UpdateChrome() end
end

-- Rows
-- ---------------------------------------------------------------------------

local function createRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\WHITE8X8")

	Kit:Adopt(row, function(_, palette)
		highlight:SetVertexColor(unpack(palette.rowHighlight))
	end)

	row.Columns = {}
	for _, column in ipairs(COLUMNS) do
		local text = Kit:CreateText(row, "text", column.justify)
		text:SetPoint("LEFT", row, "LEFT", column.x, 0)
		text:SetWidth(column.width)
		text:SetWordWrap(false)
		row.Columns[column.key] = text
	end

	row:SetScript("OnEnter", function(self)
		local entry = self.entry
		if not entry then return end

		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(entry.subj or "", 1, 1, 1)
		GameTooltip:AddLine((entry.dir == "out" and "To " or "From ") .. (entry.who or UNKNOWN), 0.8, 0.8, 0.8)
		GameTooltip:AddLine(entry.char or "", 0.6, 0.6, 0.6)

		GameTooltip:AddLine(" ")
		if entry.at then
			GameTooltip:AddLine("Received ~" .. date("%d %b %H:%M", entry.at), 0.7, 0.7, 0.7)
		end
		if entry.opened then
			GameTooltip:AddLine("Opened " .. date("%d %b %H:%M", entry.opened), 0.7, 0.7, 0.7)
		end
		if entry.dispAt then
			GameTooltip:AddLine((STATE_LABEL[entry.disp] or "closed"):gsub("^%l", string.upper)
				.. " " .. date("%d %b %H:%M", entry.dispAt), 0.7, 0.7, 0.7)
		end

		if entry.items and #entry.items > 0 then
			GameTooltip:AddLine(" ")
			for _, item in ipairs(entry.items) do
				local name = item.name or (item.id and C_Item.GetItemInfo(item.id)) or "Item"
				local count = (item.n or 1) > 1 and (" x" .. item.n) or ""
				GameTooltip:AddLine(name .. count, 0.9, 0.9, 0.9)
			end
		end

		if entry.invoice then
			local invoice = entry.invoice
			GameTooltip:AddLine(" ")
			if invoice.bid then
				GameTooltip:AddLine("Sale " .. ns.Money(invoice.bid), 0.9, 0.9, 0.9)
			end
			if invoice.deposit then
				GameTooltip:AddLine("Deposit " .. ns.Money(invoice.deposit), 0.9, 0.9, 0.9)
			end
			if invoice.cut then
				GameTooltip:AddLine("House cut " .. ns.Money(invoice.cut), 0.9, 0.6, 0.6)
			end
		end

		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	row:SetScript("OnClick", function(self)
		if self.entry then
			ns.Reader:OpenArchived(self.entry)
		end
	end)

	return row
end

local function updateRow(row, entry)
	row.entry = entry

	row.Columns.when:SetText(ageText(entry.at))
	row.Columns.who:SetText(entry.who or UNKNOWN)
	row.Columns.subject:SetText(entry.subj or "")

	local value = (entry.money or 0) + (entry.cod or 0)
	if value > 0 then
		row.Columns.value:SetText(ns.Money(value))
	elseif entry.items and #entry.items > 0 then
		row.Columns.value:SetText(("%d items"):format(#entry.items))
	else
		row.Columns.value:SetText("")
	end

	local state = entry.disp or "inbox"
	row.Columns.state:SetText(STATE_LABEL[state] or state)
	local colour = STATE_COLOR[state] or { 0.6, 0.6, 0.6 }
	row.Columns.state:SetTextColor(colour[1], colour[2], colour[3])
end

-- Page
-- ---------------------------------------------------------------------------

local function build(host)
	local self = { frame = host }

	self.Search = Kit:CreateSearchBox(host, 200,
		"Search, or try from: to: item: subject: body:", function(value)
			search = value
			rebuild()
		end)
	self.Search:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
	self.Search:SetPoint("TOPRIGHT", host, "TOPRIGHT", -206, 0)

	self.Character = Kit:CreateDropdown(host, 168, function(value)
		character = value ~= ALL and value or nil
		rebuild()
	end)
	self.Character:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -30)

	self.Filters = {}
	local previous
	for _, entry in ipairs(FILTERS) do
		local tab = Kit:CreateTab(host, entry.label, 62, function()
			filter = entry.key
			for _, other in ipairs(self.Filters) do
				other:SetSelected(other.key == entry.key)
			end
			rebuild()
		end)
		tab.key = entry.key

		if previous then
			tab:SetPoint("LEFT", previous, "RIGHT", 2, 0)
		else
			tab:SetPoint("TOPRIGHT", host, "TOPRIGHT", -128, -1)
		end

		previous = tab
		self.Filters[#self.Filters + 1] = tab
	end
	self.Filters[1]:SetSelected(true)

	for _, column in ipairs(COLUMNS) do
		if column.title ~= "" then
			local header = Kit:CreateText(host, "dim", column.justify)
			header:SetPoint("TOPLEFT", host, "TOPLEFT", column.x, -60)
			header:SetWidth(column.width)
			header:SetText(column.title)
		end
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

	self.Empty = Kit:CreateText(host, "dim", "CENTER")
	self.Empty:SetPoint("CENTER", host, "CENTER", 0, 0)
	self.Empty:Hide()

	self.Footer = Kit:CreateText(host, "dim")
	self.Footer:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 4, 4)

	function self:UpdateChrome()
		local shown = #results
		local total = Archive:Count()

		if shown == 0 then
			self.Empty:Show()
			self.Empty:SetText(total == 0
				and "Nothing archived yet.\nParcel records mail from the moment you open a mailbox."
				or "Nothing matches that search.")
		else
			self.Empty:Hide()
		end

		local gold = 0
		for _, entry in ipairs(results) do
			if entry.dir == "in" and entry.disp == "collected" then
				gold = gold + (entry.money or 0)
			end
		end

		if gold > 0 then
			self.Footer:SetText(("%d of %d archived  ·  %s collected%s"):format(
				shown, total, ns.Money(gold), nearMatches and "  ·  |cffffcc00near matches|r" or ""))
		else
			self.Footer:SetText(("%d of %d archived%s"):format(
				shown, total, nearMatches and "  ·  |cffffcc00near matches|r" or ""))
		end

		Window:SetSummary("")
	end

	function self:Refresh()
		rebuild()
	end

	function self:OnShow()
		Archive:CaptureInbox()

		-- Rebuilt every time, because a character only appears in the list once
		-- it has something archived.
		self.Character:SetOptions(characterOptions())
		if character == nil and self.Character:GetValue() == nil then
			character = Archive:CurrentCharacter()
		end
		self.Character:SetValue(character or ALL)

		rebuild()
		list:ScrollToTop()
	end

	page = self
	return self
end

Window:AddPage("history", "History", build)

Events:Register("Parcel.Archive.Changed", function()
	if page and page.frame:IsShown() then rebuild() end
end)

Events:Register("Parcel.Collect.Changed", function()
	if page and page.frame:IsShown() then
		rebuild()
	end
end)

Events:Register("Parcel.Send.Success", function()
	if page and page.frame:IsShown() then
		rebuild()
	end
end)
