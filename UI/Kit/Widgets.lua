local ADDON, ns = ...

local Kit = ns.Kit

-- Buttons
-- ---------------------------------------------------------------------------

-- UIPanelButtonTemplate is the stock button on every client Parcel supports and
-- already matches the game, so the kit styles the label rather than replacing
-- the button.
function Kit:CreateButton(parent, text, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 110, 24)
	button:SetText(text)
	button:SetScript("OnClick", onClick)

	function button:SetEnabled(enabled)
		if enabled then self:Enable() else self:Disable() end
	end

	return button
end

-- Icon buttons
-- ---------------------------------------------------------------------------

function Kit:CreateIconButton(parent, texture, size, tooltip, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(size or 20, size or 20)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture(texture)
	-- Item icons carry a border in the outer few pixels that reads as grime at
	-- this size.
	icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
	icon:SetDesaturated(true)
	button.Icon = icon

	button:SetScript("OnEnter", function(self)
		icon:SetDesaturated(false)
		if not tooltip then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(tooltip, 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		icon:SetDesaturated(true)
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick", onClick)

	return button
end

-- Checkboxes
-- ---------------------------------------------------------------------------

function Kit:CreateCheckbox(parent, size, onClick)
	local check = CreateFrame("Button", nil, parent)
	check:SetSize(size or 18, size or 18)
	check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	check:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	check:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")

	local tick = check:CreateTexture(nil, "OVERLAY")
	tick:SetAllPoints()
	tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
	tick:Hide()
	check.Tick = tick

	function check:SetChecked(value)
		tick:SetShown(value and true or false)
	end

	function check:GetChecked()
		return tick:IsShown()
	end

	check:SetScript("OnClick", onClick)
	return check
end

-- Search box
-- ---------------------------------------------------------------------------

function Kit:CreateSearchBox(parent, width, placeholderText, onChanged)
	local holder = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	holder:SetSize(width, 22)

	self:Adopt(holder, function(frame, palette)
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(unpack(palette.inputBackdrop))
		frame:SetBackdropBorderColor(palette.dim[1], palette.dim[2], palette.dim[3], 0.7)
	end)

	local box = CreateFrame("EditBox", nil, holder)
	box:SetPoint("TOPLEFT", holder, "TOPLEFT", 8, -1)
	box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -22, 1)
	box:SetAutoFocus(false)
	box:SetFontObject(self.fonts.body)
	box:SetMaxLetters(64)

	local placeholder = self:CreateText(box, "dim")
	placeholder:SetPoint("LEFT", box, "LEFT", 0, 0)
	placeholder:SetText(placeholderText or "")

	-- A glyph rather than a texture. The obvious candidates for a small clear
	-- button have all been retired from one client or another at some point;
	-- text cannot go missing.
	local clear = CreateFrame("Button", nil, holder)
	clear:SetSize(16, 16)
	clear:SetPoint("RIGHT", holder, "RIGHT", -5, 0)
	clear:Hide()

	local cross = self:CreateText(clear, "dim", "CENTER")
	cross:SetAllPoints()
	cross:SetText("x")

	clear:SetScript("OnEnter", function()
		local palette = self:GetPalette()
		cross:SetTextColor(palette.accent[1], palette.accent[2], palette.accent[3])
	end)
	clear:SetScript("OnLeave", function()
		local palette = self:GetPalette()
		cross:SetTextColor(palette.dim[1], palette.dim[2], palette.dim[3])
	end)

	local function changed()
		local value = strtrim(box:GetText() or "")
		placeholder:SetShown(value == "")
		clear:SetShown(value ~= "")
		if onChanged then onChanged(value) end
	end

	box:SetScript("OnTextChanged", changed)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)

	clear:SetScript("OnClick", function()
		box:SetText("")
		box:ClearFocus()
	end)

	holder.EditBox = box
	function holder:GetValue() return strtrim(box:GetText() or "") end
	function holder:SetValue(value) box:SetText(value or "") end

	return holder
end

-- Text input
-- ---------------------------------------------------------------------------

function Kit:CreateInput(parent, width, height, onChanged)
	local holder = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	holder:SetSize(width, height or 22)

	self:Adopt(holder, function(frame, palette)
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(unpack(palette.inputBackdrop))
		frame:SetBackdropBorderColor(palette.dim[1], palette.dim[2], palette.dim[3], 0.7)
	end)

	local box = CreateFrame("EditBox", nil, holder)
	box:SetPoint("TOPLEFT", holder, "TOPLEFT", 7, -1)
	box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -7, 1)
	box:SetAutoFocus(false)
	box:SetFontObject(self.fonts.body)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	if onChanged then
		box:SetScript("OnTextChanged", function(self) onChanged(self:GetText() or "") end)
	end

	holder.EditBox = box
	function holder:GetValue() return strtrim(box:GetText() or "") end
	function holder:SetValue(value) box:SetText(value or "") end
	function holder:Focus() box:SetFocus() end

	return holder
end

-- Autocomplete
-- ---------------------------------------------------------------------------

-- Attaches a suggestion list to an input built by CreateInput.
--
-- Tab and Shift-Tab move through the list and Enter commits, which is how
-- Blizzard's own name field behaves. Arrow keys are not used because an EditBox
-- consumes those for the caret and an addon cannot get them back.
function Kit:AttachAutoComplete(input, suggest, onAccept)
	local box = input.EditBox
	local rows = {}
	local matches = {}
	local index = 0
	local suppress = false

	local drop = CreateFrame("Frame", nil, input, BackdropTemplateMixin and "BackdropTemplate" or nil)
	drop:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -2)
	drop:SetPoint("TOPRIGHT", input, "BOTTOMRIGHT", 0, -2)
	drop:SetFrameStrata("DIALOG")
	drop:Hide()

	self:Adopt(drop, function(frame, palette)
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0, 0, 0, 0.92)
		frame:SetBackdropBorderColor(palette.accent[1], palette.accent[2], palette.accent[3], 0.5)
	end)

	local function hide()
		drop:Hide()
		matches = {}
		index = 0
	end

	local function commit(name)
		suppress = true
		box:SetText(name)
		box:SetCursorPosition(#name)
		suppress = false
		hide()
		if onAccept then onAccept(name) end
	end

	local function highlight()
		for slot, row in ipairs(rows) do
			row.Selected:SetShown(slot == index)
		end
	end

	local function row(slot)
		if rows[slot] then return rows[slot] end

		local button = CreateFrame("Button", nil, drop)
		button:SetHeight(18)
		button:SetPoint("TOPLEFT", drop, "TOPLEFT", 5, -4 - (slot - 1) * 18)
		button:SetPoint("TOPRIGHT", drop, "TOPRIGHT", -5, -4 - (slot - 1) * 18)

		local selected = button:CreateTexture(nil, "BACKGROUND")
		selected:SetAllPoints()
		selected:SetTexture("Interface\\Buttons\\WHITE8X8")
		selected:Hide()
		button.Selected = selected

		local label = self:CreateText(button, "text")
		label:SetPoint("LEFT", button, "LEFT", 4, 0)
		button.Label = label

		local source = self:CreateText(button, "dim", "RIGHT")
		source:SetPoint("RIGHT", button, "RIGHT", -4, 0)
		button.Source = source

		self:Adopt(button, function(_, palette)
			selected:SetVertexColor(unpack(palette.rowSelected))
		end)

		button:SetScript("OnClick", function() commit(button.value) end)
		button:SetScript("OnEnter", function()
			index = slot
			highlight()
		end)

		rows[slot] = button
		return button
	end

	local SOURCE_LABEL = {
		recent = "recent",
		alt = "your character",
		guild = "guild",
		friend = "friend",
		game = "",
	}

	local function refresh()
		if suppress then return end

		matches = suggest(box:GetText() or "") or {}
		index = 0

		for _, button in ipairs(rows) do button:Hide() end

		if #matches == 0 then
			drop:Hide()
			return
		end

		for slot, match in ipairs(matches) do
			local button = row(slot)
			button.value = match.name
			button.Label:SetText(match.name)
			button.Source:SetText(SOURCE_LABEL[match.source] or "")
			button.Selected:Hide()
			button:Show()
		end

		drop:SetHeight(8 + #matches * 18)
		drop:Show()
	end

	local function step(delta)
		if #matches == 0 then return false end
		index = index + delta
		if index > #matches then index = 1 end
		if index < 1 then index = #matches end
		highlight()
		return true
	end

	box:HookScript("OnTextChanged", refresh)
	box:HookScript("OnEditFocusLost", function()
		-- Deferred so a click on a suggestion lands before the list disappears.
		C_Timer.After(0.15, hide)
	end)

	box:SetScript("OnTabPressed", function()
		step(IsShiftKeyDown() and -1 or 1)
	end)

	box:SetScript("OnEnterPressed", function(self)
		if #matches > 0 then
			commit(matches[index > 0 and index or 1].name)
			return
		end
		self:ClearFocus()
	end)

	box:SetScript("OnEscapePressed", function(self)
		if drop:IsShown() then
			hide()
			return
		end
		self:ClearFocus()
	end)

	input.HideSuggestions = hide
	return drop
end

-- Money input
-- ---------------------------------------------------------------------------

local COIN_ICONS = {
	gold = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t",
	silver = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t",
	copper = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t",
}

-- Three numeric fields rather than MoneyInputFrameTemplate, which exists but
-- differs enough between clients that owning it outright is less work than
-- accommodating it.
function Kit:CreateMoneyInput(parent, onChanged)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(190, 22)

	local fields = {}
	local previous

	local function changed()
		if onChanged then onChanged(holder:GetCopper()) end
	end

	for _, spec in ipairs({
		{ key = "gold", width = 62, letters = 7 },
		{ key = "silver", width = 42, letters = 2 },
		{ key = "copper", width = 42, letters = 2 },
	}) do
		local input = self:CreateInput(holder, spec.width, 22, changed)
		input.EditBox:SetNumeric(true)
		input.EditBox:SetMaxLetters(spec.letters)
		input.EditBox:SetJustifyH("RIGHT")

		if previous then
			input:SetPoint("LEFT", previous, "RIGHT", 16, 0)
		else
			input:SetPoint("LEFT", holder, "LEFT", 0, 0)
		end

		local icon = self:CreateText(input, "text")
		icon:SetPoint("LEFT", input, "RIGHT", 1, 0)
		icon:SetText(COIN_ICONS[spec.key])

		fields[spec.key] = input
		previous = input
	end

	local function value(key)
		return tonumber(fields[key].EditBox:GetText()) or 0
	end

	function holder:GetCopper()
		return value("gold") * 10000 + value("silver") * 100 + value("copper")
	end

	function holder:SetCopper(copper)
		copper = math.max(0, math.floor(copper or 0))
		fields.gold.EditBox:SetText(copper >= 10000 and tostring(math.floor(copper / 10000)) or "")
		fields.silver.EditBox:SetText(copper >= 100 and tostring(math.floor(copper / 100) % 100) or "")
		fields.copper.EditBox:SetText(copper > 0 and tostring(copper % 100) or "")
	end

	function holder:Clear()
		for _, input in pairs(fields) do
			input.EditBox:SetText("")
		end
	end

	return holder
end

-- Radio buttons
-- ---------------------------------------------------------------------------

function Kit:CreateRadio(parent, text, onClick)
	local radio = CreateFrame("Button", nil, parent)
	radio:SetSize(20, 20)
	radio:SetNormalTexture("Interface\\Buttons\\UI-RadioButton")
	radio:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)

	local selectedTexture = radio:CreateTexture(nil, "OVERLAY")
	selectedTexture:SetAllPoints()
	selectedTexture:SetTexture("Interface\\Buttons\\UI-RadioButton")
	selectedTexture:SetTexCoord(0.25, 0.5, 0, 1)
	selectedTexture:Hide()

	local label = self:CreateText(radio, "text")
	label:SetPoint("LEFT", radio, "RIGHT", 4, 0)
	label:SetText(text)
	radio.Label = label

	function radio:SetSelected(selected)
		selectedTexture:SetShown(selected and true or false)
	end

	radio:SetScript("OnClick", onClick)
	radio:SetSelected(false)
	return radio
end

-- Dropdown
-- ---------------------------------------------------------------------------

-- options is a list of { value, label }. onSelect receives the value.
function Kit:CreateDropdown(parent, width, onSelect)
	local dropdown = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	dropdown:SetSize(width or 160, 22)

	self:Adopt(dropdown, function(frame, palette)
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(unpack(palette.inputBackdrop))
		frame:SetBackdropBorderColor(palette.dim[1], palette.dim[2], palette.dim[3], 0.7)
	end)

	local label = self:CreateText(dropdown, "text")
	label:SetPoint("LEFT", dropdown, "LEFT", 8, 0)
	label:SetPoint("RIGHT", dropdown, "RIGHT", -18, 0)
	label:SetWordWrap(false)
	dropdown.Label = label

	local arrow = self:CreateText(dropdown, "dim", "RIGHT")
	arrow:SetPoint("RIGHT", dropdown, "RIGHT", -6, -1)
	arrow:SetText("v")

	local menu = CreateFrame("Frame", nil, dropdown, BackdropTemplateMixin and "BackdropTemplate" or nil)
	menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
	menu:SetPoint("TOPRIGHT", dropdown, "BOTTOMRIGHT", 0, -2)
	menu:SetFrameStrata("DIALOG")
	menu:Hide()

	self:Adopt(menu, function(frame, palette)
		frame:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0, 0, 0, 0.94)
		frame:SetBackdropBorderColor(palette.accent[1], palette.accent[2], palette.accent[3], 0.5)
	end)

	local rows = {}
	local options = {}
	local selected

	local function close()
		menu:Hide()
	end

	local function row(slot)
		if rows[slot] then return rows[slot] end

		local button = CreateFrame("Button", nil, menu)
		button:SetHeight(18)
		button:SetPoint("TOPLEFT", menu, "TOPLEFT", 5, -4 - (slot - 1) * 18)
		button:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -5, -4 - (slot - 1) * 18)

		local tick = button:CreateTexture(nil, "BACKGROUND")
		tick:SetAllPoints()
		tick:SetTexture("Interface\\Buttons\\WHITE8X8")
		tick:Hide()
		button.Tick = tick

		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
		highlight:SetVertexColor(1, 1, 1, 0.08)

		button.Label = self:CreateText(button, "text")
		button.Label:SetPoint("LEFT", button, "LEFT", 4, 0)
		button.Label:SetWordWrap(false)

		self:Adopt(button, function(_, palette)
			tick:SetVertexColor(unpack(palette.rowSelected))
		end)

		button:SetScript("OnClick", function(self)
			dropdown:SetValue(self.value)
			close()
			if onSelect then onSelect(self.value) end
		end)

		rows[slot] = button
		return button
	end

	function dropdown:SetOptions(list)
		options = list or {}
		for _, button in ipairs(rows) do button:Hide() end

		for slot, option in ipairs(options) do
			local button = row(slot)
			button.value = option.value
			button.Label:SetText(option.label)
			button.Tick:SetShown(option.value == selected)
			button:Show()
		end

		menu:SetHeight(8 + math.max(1, #options) * 18)
	end

	function dropdown:SetValue(value)
		selected = value
		for _, option in ipairs(options) do
			if option.value == value then
				label:SetText(option.label)
			end
		end
		for _, button in ipairs(rows) do
			button.Tick:SetShown(button.value == value)
		end
	end

	function dropdown:GetValue()
		return selected
	end

	dropdown:SetScript("OnClick", function()
		if menu:IsShown() then
			close()
		else
			menu:Show()
		end
	end)

	dropdown:SetScript("OnHide", close)
	return dropdown
end

-- Tabs
-- ---------------------------------------------------------------------------

function Kit:CreateTab(parent, text, width, onClick)
	local tab = CreateFrame("Button", nil, parent)
	tab:SetSize(width or 90, 24)

	local label = self:CreateText(tab, "text", "CENTER")
	label:SetAllPoints()
	label:SetText(text)
	tab.Label = label

	local underline = tab:CreateTexture(nil, "ARTWORK")
	underline:SetHeight(2)
	underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 4, 0)
	underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -4, 0)
	underline:SetTexture("Interface\\Buttons\\WHITE8X8")
	underline:Hide()
	tab.Underline = underline

	local highlight = tab:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
	highlight:SetVertexColor(1, 1, 1, 0.06)

	self:Adopt(tab, function(_, palette)
		underline:SetVertexColor(unpack(palette.accent))
		local colour = tab.selected and palette.accent or palette.dim
		label:SetTextColor(colour[1], colour[2], colour[3])
	end)

	function tab:SetSelected(selected)
		self.selected = selected and true or false
		underline:SetShown(self.selected)
		local palette = Kit:GetPalette()
		local colour = self.selected and palette.accent or palette.dim
		label:SetTextColor(colour[1], colour[2], colour[3])
	end

	tab:SetScript("OnClick", onClick)
	tab:SetSelected(false)
	return tab
end

-- Column headers
-- ---------------------------------------------------------------------------

function Kit:CreateColumnHeader(parent, title, width, justify, onClick)
	local header = CreateFrame("Button", nil, parent)
	header:SetSize(width, 18)

	local label = self:CreateText(header, "dim", justify)
	label:SetAllPoints()
	header.Label = label

	local highlight = header:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
	highlight:SetVertexColor(1, 1, 1, 0.06)

	header.title = title
	header:SetScript("OnClick", onClick)

	-- "" not sorted, "asc" or "desc" when this column is the sort key.
	function header:SetSort(direction)
		if direction == "asc" then
			label:SetText(title .. " |TInterface\\Buttons\\UI-SortArrow:10:10:0:0:32:32:0:32:0:32|t")
		elseif direction == "desc" then
			label:SetText(title .. " |TInterface\\Buttons\\UI-SortArrow:10:10:0:0:32:32:0:32:32:0|t")
		else
			label:SetText(title)
		end
	end

	header:SetSort(nil)
	return header
end
