local ADDON, ns = ...

-- The launcher.
--
-- A broker object rather than a bespoke minimap button, because one
-- implementation then serves Titan Panel, Bazooka, ElvUI, ChocolateBar and the
-- minimap alike. LibDBIcon puts it on the minimap for anyone not running a
-- display addon, which is what zMail hand rolled.

local Broker = {}
ns.Broker = Broker

local Events = ns.Events
local Archive = ns.Archive
local Alerts = ns.Alerts

-- The envelope is the client's own mail indicator, the one Blizzard_Minimap
-- uses for MiniMapMailIcon, and it is the default because it reads cleanly at
-- the size a minimap button actually gets drawn.
Broker.icons = {
	{ key = "envelope", label = "Envelope", path = "Interface\\Icons\\INV_Letter_15" },
	{ key = "box", label = "Box", path = "Interface\\Icons\\INV_Crate_03" },
	{ key = "parcel", label = "Parcel logo", path = "Interface\\AddOns\\Parcel\\Media\\icon" },
}

Broker.iconLabels = {}
Broker.iconOrder = {}
for _, entry in ipairs(Broker.icons) do
	Broker.iconLabels[entry.key] = entry.label
	Broker.iconOrder[#Broker.iconOrder + 1] = entry.key
end

function Broker:CurrentIcon()
	local addon = ns.Addon
	local ui = addon and addon.db and addon.db.profile and addon.db.profile.ui
	local wanted = ui and ui.minimapIcon

	for _, entry in ipairs(self.icons) do
		if entry.key == wanted then return entry.path end
	end

	return self.icons[1].path
end

local dataObject
local icon

local function label()
	if not HasNewMail or not HasNewMail() then return "Parcel" end
	return "|cffffd100Parcel|r"
end

function Broker:Update()
	if dataObject then dataObject.text = label() end
end

local function tooltip(frame)
	GameTooltip:SetOwner(frame, "ANCHOR_NONE")
	GameTooltip:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT")
	GameTooltip:AddLine("Parcel", 1, 0.82, 0)

	if HasNewMail and HasNewMail() then
		GameTooltip:AddLine("You have new mail.", 1, 1, 1)
	end

	local expiring = Alerts:Expiring()
	if #expiring > 0 then
		GameTooltip:AddLine(" ")
		for _, bucket in ipairs(expiring) do
			local days = math.max(0, math.floor((bucket.soonest - time()) / 86400))
			GameTooltip:AddDoubleLine(bucket.character,
				("%d mail, %dd left"):format(bucket.count, days), 1, 1, 1, 1, 0.6, 0.6)
		end
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("History", ("%d entries"):format(Archive:Count()), 0.7, 0.7, 0.7, 1, 1, 1)

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click to open Parcel.", 0.5, 0.5, 0.5)
	GameTooltip:AddLine("Right-click for settings.", 0.5, 0.5, 0.5)
	GameTooltip:AddLine("Ctrl-click to hide this button.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

function Broker:Build()
	if dataObject then return end

	local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
	if not LDB then return end

	dataObject = LDB:NewDataObject("Parcel", {
		type = "launcher",
		icon = Broker:CurrentIcon(),
		label = "Parcel",
		text = label(),
		OnClick = function(_, button)
			-- Ctrl-click to put it away, which is what every other minimap button
			-- does. It goes through the feature switch rather than hiding the icon
			-- directly, so the settings panel and this agree with each other.
			if IsControlKeyDown() then
				ns.Features:SetEnabled("broker", false)
				ns.Addon:Print("Minimap button hidden. /parcel minimap brings it back.")
				return
			end

			if button == "RightButton" then
				ns.Addon:OpenOptions()
			else
				ns.Window:Toggle()
			end
		end,
		OnTooltipShow = function(target)
			-- Broker displays that build their own tooltip call this instead.
			target:AddLine("Parcel", 1, 0.82, 0)
			target:AddLine("Click to open, right-click for settings.", 0.5, 0.5, 0.5)
			target:AddLine("Ctrl-click to hide this button.", 0.5, 0.5, 0.5)
		end,
		OnEnter = tooltip,
		OnLeave = function() GameTooltip:Hide() end,
	})
end

-- LibDBIcon watches the data object and repaints the button itself, so setting
-- the attribute is the whole job. No reload, and broker displays follow too.
function Broker:RefreshIcon()
	if dataObject then dataObject.icon = self:CurrentIcon() end
end

function Broker:Apply()
	self:Build()
	self:RefreshIcon()

	local DBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
	if not DBIcon or not dataObject then return end

	local db = ns.Addon.db.profile.minimap
	local wanted = ns.Features:IsEnabled("broker")

	if not icon then
		DBIcon:Register("Parcel", dataObject, db)
		icon = true
	end

	-- LibDBIcon reads hide from the table it was handed, so the table is what
	-- has to change, not just the call.
	db.hide = not wanted
	if wanted then
		DBIcon:Show("Parcel")
	else
		DBIcon:Hide("Parcel")
	end
end

Events:Register("Parcel.Features.Changed", function(key)
	if key == "broker" then Broker:Apply() end
end)

Events:Register("Parcel.UI.Changed", function(key)
	if key == "minimapIcon" then Broker:RefreshIcon() end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("UPDATE_PENDING_MAIL")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		Broker:Apply()
	end
	Broker:Update()
end)
