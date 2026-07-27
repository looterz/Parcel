local ADDON, ns = ...

local Window = {}
ns.Window = Window

local Kit = ns.Kit
local Theme = ns.Theme
local Events = ns.Events

local WIDTH, HEIGHT = 640, 476
local PADDING = 18
local CONTENT_TOP = 80

-- Flush to the left edge, where Blizzard's panel manager puts the mail frame.
-- Parcel is wider than that frame and the reader opens to its right, so
-- starting further in pushed the pair across the screen and left no room for
-- bags. The player can drag it anywhere; this is only where it begins.
local DEFAULT_POINT = { "TOPLEFT", "TOPLEFT", 16, -104 }

local frame
local pages = {}
local order = {}
local current

-- Blizzard's mail frame
-- ---------------------------------------------------------------------------

-- The mail frame is put out of sight rather than hidden, and that distinction
-- is not cosmetic. MailFrame_Show does this:
--
--     ShowUIPanel(MailFrame);
--     if ( not MailFrame:IsShown() ) then
--         CloseMail();
--         return;
--     end
--     ... CheckInbox() ...
--
-- So hiding the frame at any point during its own show sequence makes Blizzard
-- close the mail session and never request the inbox. Parcel then had no mail to
-- display, which is exactly the symptom that turned up: mail only appeared when
-- the frame was left alone.
--
-- Reparenting to a hidden holder sidesteps it. IsShown stays true, so every
-- Blizzard code path behaves as though the window is open, while IsVisible is
-- false so nothing renders and nothing takes a click.
local holder = CreateFrame("Frame")
holder:Hide()

local originalParent

local function setBlizzardMailShown(shown)
	if not MailFrame then return end

	if shown then
		if originalParent then
			MailFrame:SetParent(originalParent)
			originalParent = nil
		end
		return
	end

	if not originalParent then
		originalParent = MailFrame:GetParent() or UIParent
		MailFrame:SetParent(holder)
	end
end

function Window:ApplyBlizzardMailVisibility()
	if not self:IsShown() then return end
	setBlizzardMailShown(not Theme:HidesBlizzardMail())
end

-- Pages
-- ---------------------------------------------------------------------------

-- build(contentFrame) returns a table with optional OnShow, OnHide and Refresh.
function Window:AddPage(key, label, build)
	pages[key] = { key = key, label = label, build = build }
	order[#order + 1] = key
end

function Window:GetPage(key)
	return pages[key]
end

function Window:Select(key)
	local page = pages[key]
	if not page then return end

	self:Build()

	if current and current ~= page and current.instance then
		if current.instance.OnHide then current.instance:OnHide() end
		current.instance.frame:Hide()
	end

	if not page.instance then
		local host = CreateFrame("Frame", nil, frame.Content)
		host:SetAllPoints()
		page.instance = page.build(host) or {}
		page.instance.frame = page.instance.frame or host
	end

	current = page
	page.instance.frame:Show()
	if page.instance.OnShow then page.instance:OnShow() end

	for _, tab in ipairs(frame.Tabs) do
		tab:SetSelected(tab.key == key)
	end
end

function Window:Refresh()
	if current and current.instance and current.instance.Refresh then
		current.instance:Refresh()
	end
end

function Window:SetSummary(text)
	if frame then
		frame.Summary:SetText(text or "")
	end
end

-- Frame
-- ---------------------------------------------------------------------------

function Window:Build()
	if frame then return frame end

	frame = Kit:CreatePanel(UIParent, "ParcelFrame")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		Window:SavePosition()
	end)
	frame:Hide()
	tinsert(UISpecialFrames, "ParcelFrame")

	frame.Title = Kit:CreateText(frame, "title")
	frame.Title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + 4, -18)
	frame.Title:SetText("Parcel")

	frame.Summary = Kit:CreateText(frame, "dim", "RIGHT")
	frame.Summary:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - 30, -22)

	frame.Tabs = {}
	local previous
	for _, key in ipairs(order) do
		local page = pages[key]
		local tab = Kit:CreateTab(frame, page.label, 92, function()
			Window:Select(key)
		end)
		tab.key = key

		if previous then
			tab:SetPoint("LEFT", previous, "RIGHT", 4, 0)
		else
			tab:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + 2, -48)
		end

		previous = tab
		frame.Tabs[#frame.Tabs + 1] = tab
	end

	local divider = Kit:CreateDivider(frame)
	divider:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -CONTENT_TOP + 6)
	divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -CONTENT_TOP + 6)

	frame.Content = CreateFrame("Frame", nil, frame)
	frame.Content:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -CONTENT_TOP)
	frame.Content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING - 4)

	frame.CloseButton = Kit:CreateButton(frame, CLOSE, 90, function()
		Window:Hide()
	end)
	frame.CloseButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - 2, -46)
	frame.CloseButton:SetHeight(22)

	frame.SettingsButton = Kit:CreateIconButton(frame, "Interface\\Icons\\INV_Misc_Gear_01", 14,
		"Parcel settings", function()
			ns.Addon:OpenOptions()
		end)
	frame.SettingsButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING - 2, -20)

	-- Every way of closing this window ends up here, which is the point.
	--
	-- Escape goes through UISpecialFrames and calls Hide on the frame directly,
	-- never reaching Window:Hide. That left the mail session open, so the client
	-- still believed the mailbox was up and did not fire MAIL_SHOW the next time
	-- it was clicked, and Parcel simply never appeared until a reload.
	frame:HookScript("OnHide", function()
		if ns.Reader then ns.Reader:Close() end

		if current and current.instance and current.instance.OnHide then
			current.instance:OnHide()
		end

		-- Give the frame back to UIParent before anything else, so the panel
		-- manager is looking at a normal frame again.
		setBlizzardMailShown(true)

		-- Deliberately no HideUIPanel here. MailFrame is panel managed, and
		-- hiding it by hand after Parcel has reparented it leaves the manager
		-- believing the left slot is still taken. The next ShowUIPanel then
		-- refuses, and MailFrame_Show's own guard sees an unshown frame and
		-- calls CloseMail, so the mailbox stopped responding entirely.
		--
		-- Closing the session is enough. Blizzard hides its own frame on
		-- MAIL_CLOSED, through the panel system, the way it expects to.
		if ns.Collect and ns.Collect:IsMailOpen() then
			CloseMail()
		end
	end)

	self:RestorePosition()
	return frame
end

function Window:SavePosition()
	local addon = ns.Addon
	if not addon or not addon.db or not frame then return end
	local point, _, relativePoint, x, y = frame:GetPoint()
	addon.db.profile.ui.position = { point = point, relativePoint = relativePoint, x = x, y = y }
end

function Window:RestorePosition()
	if not frame then return end

	local addon = ns.Addon
	local saved = addon and addon.db and addon.db.profile.ui.position

	frame:ClearAllPoints()
	if saved and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
	else
		frame:SetPoint(DEFAULT_POINT[1], UIParent, DEFAULT_POINT[2], DEFAULT_POINT[3], DEFAULT_POINT[4])
	end
end

function Window:ResetPosition()
	local addon = ns.Addon
	if addon and addon.db then
		addon.db.profile.ui.position = {}
	end

	if not frame then return end
	frame:ClearAllPoints()
	frame:SetPoint(DEFAULT_POINT[1], UIParent, DEFAULT_POINT[2], DEFAULT_POINT[3], DEFAULT_POINT[4])
end

function Window:Show(key)
	self:Build()

	self:RestorePosition()
	frame:Show()

	self:Select(key or current and current.key or order[1])
	setBlizzardMailShown(not Theme:HidesBlizzardMail())
end

-- Hiding the frame is what runs the teardown, so there is one path whether the
-- player used the button, pressed Escape, or walked away. The parent is given
-- back here as well as in OnHide, because a frame that is already hidden will
-- not fire OnHide again and the mail frame would be stranded on the holder.
function Window:Toggle(key)
	if self:IsShown() then
		self:Hide()
	else
		self:Show(key)
	end
end

function Window:Hide()
	setBlizzardMailShown(true)
	if frame then
		frame:Hide()
	end
end

function Window:IsShown()
	return frame and frame:IsShown()
end

function Window:GetFrame()
	return frame
end

Events:Register("Parcel.Mail.Opened", function()
	Window:Show("inbox")
end)

Events:Register("Parcel.Mail.Closed", function()
	Window:Hide()
end)

Events:Register("Parcel.Theme.Changed", function()
	Window:ApplyBlizzardMailVisibility()
end)
