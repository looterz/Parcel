local ADDON, ns = ...

-- Every name Parcel knows, searchable, for when autocomplete cannot help
-- because you have forgotten how the name starts.

local AddressBook = {}
ns.AddressBook = AddressBook

local Kit = ns.Kit
local Roster = ns.Roster

local WIDTH, HEIGHT = 366, 420
local ROW_HEIGHT = 22
local LIST_TOP = 68
local FOOTER = 16

local frame
local list
local rows = {}
local search = ""
local onPick

local function matches(contact, needle)
	if needle == "" then return true end
	if contact.name:lower():find(needle, 1, true) then return true end

	local label = Roster.sourceLabels[contact.source]
	return label ~= nil and label:lower():find(needle, 1, true) ~= nil
end

local function rebuild()
	wipe(rows)

	local needle = search:lower()
	for _, contact in ipairs(Roster:Contacts()) do
		if matches(contact, needle) then
			rows[#rows + 1] = contact
		end
	end

	if list then list:SetData(rows) end
	if frame then
		frame.Empty:SetShown(#rows == 0)
		frame.Count:SetText(("%d of %d"):format(#rows, #Roster:Contacts()))
	end
end

local function choose(contact)
	if contact and onPick then onPick(contact.name) end
	AddressBook:Close()
end

local function createRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\WHITE8X8")

	Kit:Adopt(row, function(_, palette)
		highlight:SetVertexColor(unpack(palette.rowHighlight))
	end)

	row.Name = Kit:CreateText(row, "text")
	row.Name:SetPoint("LEFT", row, "LEFT", 6, 0)
	row.Name:SetWidth(196)
	row.Name:SetWordWrap(false)

	row.Source = Kit:CreateText(row, "dim", "RIGHT")
	row.Source:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	row.Source:SetWidth(94)
	row.Source:SetWordWrap(false)

	row:SetScript("OnClick", function() choose(row.contact) end)
	return row
end

local function updateRow(row, contact)
	row.contact = contact
	row.Name:SetText(contact.name)
	row.Source:SetText(Roster.sourceLabels[contact.source] or "")
end

local function build()
	if frame then return frame end

	frame = Kit:CreatePanel(UIParent, "ParcelAddressBook")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	frame.Title = Kit:CreateText(frame, "title")
	frame.Title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
	frame.Title:SetText("Address Book")

	frame.CloseButton = Kit:CreateButton(frame, CLOSE, 64, function() AddressBook:Close() end)
	frame.CloseButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -12)

	frame.Search = Kit:CreateSearchBox(frame, 200, "Search names", function(value)
		search = value
		rebuild()
	end)
	frame.Search:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -42)
	frame.Search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -42)

	list = Kit:CreateScrollList(frame, {
		rowHeight = ROW_HEIGHT,
		spacing = 1,
		createRow = createRow,
		updateRow = updateRow,
	})
	-- Inset on both sides: this list lives inside a bordered panel rather than
	-- the window's content area, and the Blizzard skin's border is the widest.
	list:Fill(frame, LIST_TOP, FOOTER + 14, 34, 14)
	list.bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -LIST_TOP)
	list.bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, FOOTER + 14)

	frame.Empty = Kit:CreateText(frame, "dim", "CENTER")
	frame.Empty:SetPoint("CENTER", frame, "CENTER", 0, 0)
	frame.Empty:SetText("No contacts match.")
	frame.Empty:Hide()

	frame.Count = Kit:CreateText(frame, "dim")
	frame.Count:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 12)

	-- Escape closes it without touching the Parcel window behind it.
	tinsert(UISpecialFrames, "ParcelAddressBook")

	return frame
end

function AddressBook:Open(callback)
	build()
	onPick = callback

	search = ""
	frame.Search:SetValue("")
	rebuild()

	-- Beside the Parcel window, level with its top, the same as the reader.
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

function AddressBook:Close()
	if frame then frame:Hide() end
	onPick = nil
end

function AddressBook:IsShown()
	return frame and frame:IsShown()
end

function AddressBook:Toggle(callback)
	if self:IsShown() then
		self:Close()
	else
		self:Open(callback)
	end
end
