local ADDON, ns = ...

local Kit = ns.Kit

-- A uniform row virtualised list.
--
-- Rows are recycled, so a hundred mails costs the same number of frames as
-- seven do. Blizzard's ScrollBox would do this too, but it does not exist on
-- Classic Era and its API has changed twice on retail, so this is one small
-- implementation rather than three code paths.

local function clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

-- opts:
--   rowHeight   pixels, uniform
--   spacing     pixels between rows, default 1
--   createRow   function(parent) -> frame
--   updateRow   function(frame, entry, index)
function Kit:CreateScrollList(parent, opts)
	local rowHeight = opts.rowHeight
	local spacing = opts.spacing or 1
	local step = rowHeight + spacing

	local list = {
		data = {},
		rows = {},
		offset = 0,
	}

	local view = CreateFrame("Frame", nil, parent)
	view:SetClipsChildren(true)
	view:EnableMouseWheel(true)
	list.view = view

	local bar = CreateFrame("Slider", nil, parent)
	bar:SetWidth(12)
	bar:SetOrientation("VERTICAL")
	bar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
	bar:SetMinMaxValues(0, 0)
	bar:SetValue(0)
	bar:Hide()
	list.bar = bar

	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("TOPLEFT", 3, 0)
	track:SetPoint("BOTTOMRIGHT", -3, 0)
	track:SetTexture("Interface\\Buttons\\WHITE8X8")

	Kit:Adopt(track, function(texture, palette)
		texture:SetVertexColor(palette.dim[1], palette.dim[2], palette.dim[3], 0.25)
	end)

	local thumb = bar:GetThumbTexture()
	if thumb then
		thumb:SetSize(12, 24)
	end

	local function maxOffset()
		local height = view:GetHeight()
		if height <= 0 then return 0 end
		return math.max(0, #list.data * step - height)
	end

	local function acquireRow(slot)
		local row = list.rows[slot]
		if row then return row end

		row = opts.createRow(view)
		row:SetHeight(rowHeight)
		list.rows[slot] = row
		return row
	end

	local updating = false
	local retrying = false
	local layout

	-- A frame sized purely by anchors can report zero height on the tick it was
	-- created. Bailing out then and never looking again is how the list ends up
	-- permanently empty, so a single retry is scheduled instead.
	local function retryLayout()
		if retrying then return end
		retrying = true
		C_Timer.After(0, function()
			retrying = false
			layout()
		end)
	end

	function layout()
		local height = view:GetHeight()
		if height <= 0 then
			retryLayout()
			return
		end

		local limit = maxOffset()
		list.offset = clamp(list.offset, 0, limit)

		local first = math.floor(list.offset / step) + 1
		local slots = math.ceil(height / step) + 1

		for slot = 1, slots do
			local index = first + slot - 1
			local entry = list.data[index]
			local row = acquireRow(slot)

			if entry then
				local y = (index - 1) * step - list.offset
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -y)
				row:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, -y)
				opts.updateRow(row, entry, index)
				row:Show()
			else
				row:Hide()
			end
		end

		for slot = slots + 1, #list.rows do
			list.rows[slot]:Hide()
		end

		updating = true
		bar:SetMinMaxValues(0, limit)
		bar:SetValue(list.offset)
		bar:SetShown(limit > 0)
		updating = false
	end

	list.Layout = layout

	function list:SetData(data)
		self.data = data or {}
		layout()
	end

	function list:Refresh()
		layout()
	end

	function list:ScrollToTop()
		self.offset = 0
		layout()
	end

	-- Anchored on all four sides rather than given a size, so the list tracks
	-- its host instead of freezing whatever height was readable at build time.
	function list:Fill(host, topOffset, bottomOffset, rightInset, leftInset)
		view:ClearAllPoints()
		view:SetPoint("TOPLEFT", host, "TOPLEFT", leftInset or 0, -(topOffset or 0))
		view:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -(rightInset or 18), bottomOffset or 0)
		layout()
	end

	view:SetScript("OnMouseWheel", function(_, delta)
		list.offset = clamp(list.offset - delta * step * 3, 0, maxOffset())
		layout()
	end)

	view:SetScript("OnSizeChanged", layout)

	bar:SetScript("OnValueChanged", function(_, value)
		if updating then return end
		list.offset = value
		layout()
	end)

	bar:SetScript("OnMouseWheel", function(_, delta)
		list.offset = clamp(list.offset - delta * step * 3, 0, maxOffset())
		layout()
	end)

	return list
end
