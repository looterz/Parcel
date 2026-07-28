local ADDON, ns = ...

local AuctionPage = {}
ns.AuctionPage = AuctionPage

local Kit = ns.Kit
local Auction = ns.Auction
local Window = ns.Window
local Events = ns.Events

local ROW_HEIGHT = 24
local LIST_TOP = 174
local FOOTER_HEIGHT = 24
local TILE_TOP = 34
local TILE_HEIGHT = 74

local MODES = {
	{ key = "sales", label = "Sales" },
	{ key = "items", label = "Top items" },
}

local COLUMNS = {
	sales = {
		{ key = "a", title = "When", x = 4, width = 96 },
		{ key = "b", title = "Item", x = 104, width = 210 },
		{ key = "c", title = "Buyer", x = 318, width = 130 },
		{ key = "d", title = "Net", x = 452, width = 118, justify = "RIGHT" },
	},
	items = {
		{ key = "a", title = "Item", x = 4, width = 230 },
		{ key = "b", title = "Sales", x = 238, width = 76, justify = "RIGHT" },
		{ key = "c", title = "Units", x = 318, width = 130, justify = "RIGHT" },
		{ key = "d", title = "Net", x = 452, width = 118, justify = "RIGHT" },
	},
}

local page
local list
local period = "month"
local mode = "sales"
local search = ""
local character
local rows = {}

local ALL = "all"

local function characterOptions()
	local options = { { value = ALL, label = "All characters" } }
	for _, name in ipairs(ns.Archive:GetCharacters()) do
		options[#options + 1] = { value = name, label = name }
	end
	return options
end

local function periodSeconds()
	for _, entry in ipairs(Auction.periods) do
		if entry.key == period then return entry.seconds end
	end
end

local function shortMoney(copper)
	return Auction:FormatShort(copper)
end

local function rebuild()
	local seconds = periodSeconds()

	if mode == "sales" then
		local entries = Auction:Entries(seconds, search, character)
		wipe(rows)
		for _, entry in ipairs(entries) do
			if entry.mtype == "ahSold" then
				rows[#rows + 1] = entry
			end
		end
	else
		rows = Auction:TopItems(seconds, 200, character)
		if search ~= "" then
			local needle = search:lower()
			local filtered = {}
			for _, bucket in ipairs(rows) do
				if bucket.name:lower():find(needle, 1, true) then
					filtered[#filtered + 1] = bucket
				end
			end
			rows = filtered
		end
	end

	if list then list:SetData(rows) end
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

	row.Cells = {}
	for _, key in ipairs({ "a", "b", "c", "d" }) do
		row.Cells[key] = Kit:CreateText(row, "text")
		row.Cells[key]:SetWordWrap(false)
	end

	row:SetScript("OnClick", function(self)
		if self.entry then
			ns.Reader:OpenArchived(self.entry)
		end
	end)

	return row
end

local function layoutCells(row)
	for _, column in ipairs(COLUMNS[mode]) do
		local cell = row.Cells[column.key]
		cell:ClearAllPoints()
		cell:SetPoint("LEFT", row, "LEFT", column.x, 0)
		cell:SetWidth(column.width)
		cell:SetJustifyH(column.justify or "LEFT")
	end
end

local function updateRow(row, item)
	layoutCells(row)

	if mode == "sales" then
		row.entry = item
		local invoice = item.invoice
		local name = (invoice and invoice.item)
			or (item.items and item.items[1] and item.items[1].name)
			or item.subj or ""
		local units = Auction:UnitsOf(item)
		if units > 1 then
			name = ("%s x%d"):format(name, units)
		end

		row.Cells.a:SetText(item.at and date("%d %b %H:%M", item.at) or "")
		row.Cells.b:SetText(name)
		row.Cells.c:SetText((invoice and invoice.player) or "")
		row.Cells.d:SetText(ns.Money(Auction:NetOf(item)))
	else
		row.entry = nil
		row.Cells.a:SetText(item.name or "")
		row.Cells.b:SetText(tostring(item.sales or 0))
		row.Cells.c:SetText(tostring(item.units or 0))
		row.Cells.d:SetText(ns.Money(item.net or 0))
	end
end

-- Page
-- ---------------------------------------------------------------------------

local function makeTile(host, index, title)
	local tile = Kit:CreatePanel(host, nil)
	tile:SetSize(142, TILE_HEIGHT)
	tile:SetPoint("TOPLEFT", host, "TOPLEFT", (index - 1) * 148, -TILE_TOP)

	tile.Title = Kit:CreateText(tile, "dim", "CENTER")
	tile.Title:SetText(title)

	-- The tile abbreviates so it fits. The exact figure lives here.
	tile.titleText = title
	tile:EnableMouse(true)
	tile:SetScript("OnEnter", function(self)
		if not self.exactText then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.titleText, 1, 0.82, 0)
		GameTooltip:AddLine(self.exactText, 1, 1, 1)
		if self.detailText then
			GameTooltip:AddLine(self.detailText, 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	tile:SetScript("OnLeave", function() GameTooltip:Hide() end)

	tile.Value = Kit:CreateText(tile, "title", "CENTER")
	tile.Note = Kit:CreateText(tile, "dim", "CENTER")

	-- Laid out against the panel's own insets and redone whenever the theme
	-- changes. The Blizzard skin's border is more than twice as thick as the
	-- others, and fixed offsets put the text underneath it.
	Kit:Adopt(tile, function()
		local left, right, top, bottom = Kit:GetInsets()

		tile.Title:ClearAllPoints()
		tile.Title:SetPoint("TOP", tile, "TOP", 0, -(top + 2))

		tile.Value:ClearAllPoints()
		tile.Value:SetPoint("TOP", tile.Title, "BOTTOM", 0, -4)
		tile.Value:SetPoint("LEFT", tile, "LEFT", left, 0)
		tile.Value:SetPoint("RIGHT", tile, "RIGHT", -right, 0)

		tile.Note:ClearAllPoints()
		-- Clear of the border art, which the Blizzard skin draws thicker than
		-- its inset alone accounts for.
		tile.Note:SetPoint("BOTTOM", tile, "BOTTOM", 0, bottom + 6)
		tile.Note:SetPoint("LEFT", tile, "LEFT", left, 0)
		tile.Note:SetPoint("RIGHT", tile, "RIGHT", -right, 0)
	end)

	return tile
end

local function build(host)
	local self = { frame = host }

	-- Period
	self.Periods = {}
	local previous
	for _, entry in ipairs(Auction.periods) do
		local tab = Kit:CreateTab(host, entry.label, 56, function()
			period = entry.key
			for _, other in ipairs(self.Periods) do
				other:SetSelected(other.key == entry.key)
			end
			rebuild()
		end)
		tab.key = entry.key

		if previous then
			tab:SetPoint("LEFT", previous, "RIGHT", 2, 0)
		else
			tab:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
		end

		previous = tab
		self.Periods[#self.Periods + 1] = tab
		if entry.key == period then tab:SetSelected(true) end
	end

	self.Search = Kit:CreateSearchBox(host, 200, "Search auction mail", function(value)
		search = value
		rebuild()
	end)
	self.Search:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, 0)
	self.Search:SetPoint("TOPLEFT", host, "TOPLEFT", 358, 0)

	-- Tiles
	self.Tiles = {
		net = makeTile(host, 1, "Earned"),
		sold = makeTile(host, 2, "Sold"),
		fees = makeTile(host, 3, "House cut"),
		spent = makeTile(host, 4, "Spent buying"),
	}

	-- Mode
	self.Modes = {}
	previous = nil
	for _, entry in ipairs(MODES) do
		local tab = Kit:CreateTab(host, entry.label, 78, function()
			mode = entry.key
			for _, other in ipairs(self.Modes) do
				other:SetSelected(other.key == entry.key)
			end
			self:UpdateHeaders()
			rebuild()
		end)
		tab.key = entry.key

		if previous then
			tab:SetPoint("LEFT", previous, "RIGHT", 2, 0)
		else
			tab:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(TILE_TOP + TILE_HEIGHT + 8))
		end

		previous = tab
		self.Modes[#self.Modes + 1] = tab
		if entry.key == mode then tab:SetSelected(true) end
	end

	-- Five period tabs run to x=288, so this cannot share their row. It sits
	-- opposite the mode tabs instead, directly above the list it filters.
	self.Character = Kit:CreateDropdown(host, 168, function(value)
		character = value ~= ALL and value or nil
		rebuild()
	end)
	self.Character:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, -(TILE_TOP + TILE_HEIGHT + 7))

	self.Headers = {}
	for _, key in ipairs({ "a", "b", "c", "d" }) do
		local header = Kit:CreateText(host, "dim")
		header:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(LIST_TOP - 16))
		self.Headers[key] = header
	end

	function self:UpdateHeaders()
		for _, column in ipairs(COLUMNS[mode]) do
			local header = self.Headers[column.key]
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", host, "TOPLEFT", column.x, -(LIST_TOP - 16))
			header:SetWidth(column.width)
			header:SetJustifyH(column.justify or "LEFT")
			header:SetText(column.title)
		end
	end
	self:UpdateHeaders()

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
	self.Empty:SetPoint("CENTER", host, "CENTER", 0, -40)
	self.Empty:Hide()

	self.Footer = Kit:CreateText(host, "dim")
	self.Footer:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 4, 4)

	function self:UpdateChrome()
		local seconds = periodSeconds()
		local summary = Auction:Summary(seconds, character)

		self.Tiles.net.Value:SetText(shortMoney(summary.net))
		self.Tiles.net.Note:SetText(seconds
			and ("%s per day"):format(shortMoney(Auction:DailyAverage(seconds, character)))
			or "all time")
		self.Tiles.net.exactText = ns.Money(summary.net)
		self.Tiles.net.detailText = ("%s bid, %s deposit returned, less %s house cut."):format(
			ns.Money(summary.gross), ns.Money(summary.deposits), ns.Money(summary.fees))

		self.Tiles.sold.Value:SetText(tostring(summary.sold))
		self.Tiles.sold.Note:SetText(summary.units > summary.sold
			and ("%d units"):format(summary.units) or "auctions")
		self.Tiles.sold.exactText = ("%d auctions, %d units"):format(summary.sold, summary.units)
		self.Tiles.sold.detailText = ("%d expired, %d cancelled, %d outbid."):format(
			summary.expired, summary.cancelled, summary.outbid)

		self.Tiles.fees.Value:SetText(shortMoney(summary.fees))
		self.Tiles.fees.Note:SetText(summary.gross > 0
			and ("%.0f%% of gross"):format(summary.fees / summary.gross * 100)
			or "no sales")
		self.Tiles.fees.exactText = ns.Money(summary.fees)
		self.Tiles.fees.detailText = summary.gross > 0
			and ("Taken from %s of winning bids."):format(ns.Money(summary.gross))
			or "Nothing sold in this period."

		self.Tiles.spent.Value:SetText(shortMoney(summary.spent))
		self.Tiles.spent.Note:SetText(("%d won"):format(summary.bought))
		self.Tiles.spent.exactText = ns.Money(summary.spent)
		self.Tiles.spent.detailText = ("Across %d auctions won."):format(summary.bought)

		self.Empty:SetShown(#rows == 0)
		self.Empty:SetText(ns.Archive:Count() == 0
			and "Nothing archived yet.\nAuction mail is recorded as you collect it."
			or "No auction sales in this period.")

		self.Footer:SetText(("%d expired  ·  %d cancelled  ·  %d outbid, %s refunded"):format(
			summary.expired, summary.cancelled, summary.outbid, ns.Money(summary.refunded)))

		Window:SetSummary("")
	end

	function self:Refresh()
		rebuild()
	end

	function self:OnShow()
		self.Character:SetOptions(characterOptions())
		if character == nil and self.Character:GetValue() == nil then
			character = ns.Archive:CurrentCharacter()
		end
		self.Character:SetValue(character or ALL)

		rebuild()
		list:ScrollToTop()
	end

	page = self
	return self
end

Window:AddPage("auction", "Auction", build)

Events:Register("Parcel.Collect.Changed", function()
	if page and page.frame:IsShown() then
		rebuild()
	end
end)
