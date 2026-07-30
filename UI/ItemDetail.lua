local ADDON, ns = ...

-- One item's auction record, opened from a row on the Top items list.
--
-- Beside the window rather than over it, level with the top, the same as the
-- reader and the address book, so opening one never hides what you clicked.

local ItemDetail = {}
ns.ItemDetail = ItemDetail

local Kit = ns.Kit
local Auction = ns.Auction

local WIDTH, HEIGHT = 366, 420
local ROW_HEIGHT = 22
local LIST_TOP = 214
local FOOTER = 16
local ICON = 40

local frame
local list
local rows = {}
local current

local function createRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\WHITE8X8")

	Kit:Adopt(row, function(_, palette)
		highlight:SetVertexColor(unpack(palette.rowHighlight))
	end)

	row.When = Kit:CreateText(row, "dim")
	row.When:SetPoint("LEFT", row, "LEFT", 6, 0)
	row.When:SetWidth(96)
	row.When:SetWordWrap(false)

	row.Units = Kit:CreateText(row, "text", "RIGHT")
	row.Units:SetPoint("LEFT", row, "LEFT", 104, 0)
	row.Units:SetWidth(38)

	row.Buyer = Kit:CreateText(row, "dim")
	row.Buyer:SetPoint("LEFT", row, "LEFT", 148, 0)
	row.Buyer:SetWidth(76)
	row.Buyer:SetWordWrap(false)

	row.Net = Kit:CreateText(row, "text", "RIGHT")
	row.Net:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	row.Net:SetWidth(90)

	-- The mail the sale arrived in, which is the same thing clicking it on the
	-- history list does.
	row:SetScript("OnClick", function(self)
		if self.entry then ns.Reader:OpenArchived(self.entry) end
	end)

	return row
end

local function updateRow(row, entry)
	row.entry = entry
	row.When:SetText(date("%d %b %H:%M", entry.at or entry.seen or 0))
	row.Units:SetText(tostring(Auction:UnitsOf(entry)))
	row.Buyer:SetText((entry.invoice and entry.invoice.player) or "")
	row.Net:SetText(ns.Money(Auction:NetOf(entry)))
end

local function line(parent, label, top)
	local caption = Kit:CreateText(parent, "dim")
	caption:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, top)
	caption:SetText(label)

	local value = Kit:CreateText(parent, "text", "RIGHT")
	value:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, top)
	value:SetWidth(200)

	return value
end

local function build()
	if frame then return frame end

	frame = Kit:CreatePanel(UIParent, "ParcelItemDetail")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	frame.Icon = ns.Compat:CreateItemButton(frame)
	frame.Icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
	frame.Icon:SetSize(ICON, ICON)
	-- Nothing to take, but a disabled button drops its mouse scripts unless
	-- this is set, which is what cost history attachments their tooltips.
	frame.Icon:SetMotionScriptsWhileDisabled(true)
	frame.Icon:Disable()
	frame.Icon:SetScript("OnEnter", function(self)
		if not current then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.link then
			GameTooltip:SetHyperlink(self.link)
		else
			GameTooltip:SetText(current.name or "", 1, 1, 1)
			GameTooltip:AddLine("Parcel has not seen this item itself yet.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	frame.Icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

	frame.Name = Kit:CreateText(frame, "title")
	frame.Name:SetPoint("TOPLEFT", frame.Icon, "TOPRIGHT", 10, -4)
	frame.Name:SetPoint("RIGHT", frame, "RIGHT", -70, 0)
	frame.Name:SetWordWrap(false)

	frame.Period = Kit:CreateText(frame, "dim")
	frame.Period:SetPoint("TOPLEFT", frame.Icon, "TOPRIGHT", 10, -26)

	frame.CloseButton = Kit:CreateButton(frame, CLOSE, 64, function() ItemDetail:Close() end)
	frame.CloseButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -12)

	frame.Divider = Kit:CreateDivider(frame)
	frame.Divider:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -66)
	frame.Divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -66)

	frame.Net = line(frame, "Earned", -78)
	frame.Sales = line(frame, "Sales", -98)
	frame.Units = line(frame, "Units", -118)
	frame.PerUnit = line(frame, "Average per unit", -138)
	frame.Best = line(frame, "Best single sale", -158)

	frame.ListDivider = Kit:CreateDivider(frame)
	frame.ListDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -186)
	frame.ListDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -186)

	frame.ListTitle = Kit:CreateText(frame, "dim")
	frame.ListTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -196)
	frame.ListTitle:SetText("Every sale")

	list = Kit:CreateScrollList(frame, {
		rowHeight = ROW_HEIGHT,
		spacing = 1,
		createRow = createRow,
		updateRow = updateRow,
	})
	list:Fill(frame, LIST_TOP, FOOTER + 14, 34, 14)
	list.bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -LIST_TOP)
	list.bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, FOOTER + 14)

	frame.Empty = Kit:CreateText(frame, "dim", "CENTER")
	frame.Empty:SetPoint("CENTER", frame, "CENTER", 0, -60)
	frame.Empty:SetText("No sales in this period.")
	frame.Empty:Hide()

	frame.Span = Kit:CreateText(frame, "dim")
	frame.Span:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 12)

	tinsert(UISpecialFrames, "ParcelItemDetail")

	return frame
end

function ItemDetail:Open(name, seconds, character, periodLabel)
	if not name or name == "" then return end

	build()
	current = { name = name, seconds = seconds, character = character }

	local stats, sales = Auction:ItemStats(name, seconds, character)
	wipe(rows)
	for _, entry in ipairs(sales) do rows[#rows + 1] = entry end

	local link = Auction:LinkForName(name)
	local _, _, quality, _, _, _, _, _, _, texture = C_Item.GetItemInfo(link or name)

	frame.Icon.link = link
	SetItemButtonTexture(frame.Icon, texture or "Interface\\Icons\\INV_Misc_QuestionMark")
	SetItemButtonCount(frame.Icon, 0)
	SetItemButtonQuality(frame.Icon, quality)

	frame.Name:SetText(name)
	if quality then
		local r, g, b = C_Item.GetItemQualityColor(quality)
		frame.Name:SetTextColor(r or 1, g or 1, b or 1)
	else
		local colour = Kit:GetPalette().title
		frame.Name:SetTextColor(colour[1], colour[2], colour[3])
	end

	frame.Period:SetText(periodLabel or "")
	frame.Net:SetText(ns.Money(stats.net))
	frame.Sales:SetText(tostring(stats.sales))
	frame.Units:SetText(tostring(stats.units))
	frame.PerUnit:SetText(ns.Money(stats.perUnit))
	frame.Best:SetText(ns.Money(stats.best))

	if stats.first and stats.last then
		frame.Span:SetText(("%s to %s"):format(
			date("%d %b %Y", stats.first), date("%d %b %Y", stats.last)))
	else
		frame.Span:SetText("")
	end

	list:SetData(rows)
	frame.Empty:SetShown(#rows == 0)

	local parcel = ns.Window:GetFrame()
	frame:ClearAllPoints()
	if parcel then
		frame:SetPoint("TOPLEFT", parcel, "TOPRIGHT", 6, 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end

	frame:Show()
	list:ScrollToTop()
end

function ItemDetail:Close()
	if frame then frame:Hide() end
	current = nil
end

function ItemDetail:IsShown()
	return frame and frame:IsShown() or false
end

function ItemDetail:CurrentName()
	return current and current.name or nil
end

-- Re-reads with the window it was opened for. A change of period or character
-- is not that, and the auction page reopens it with the new one instead.
function ItemDetail:Refresh()
	if not self:IsShown() or not current then return end
	self:Open(current.name, current.seconds, current.character, frame.Period:GetText())
end

ns.Events:Register("Parcel.Archive.Changed", function()
	ItemDetail:Refresh()
end)
