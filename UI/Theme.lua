local ADDON, ns = ...

local Theme = {}
ns.Theme = Theme

local Kit = ns.Kit
local Events = ns.Events

-- All three are skins for the Parcel window, Blizzard included. Picking
-- Blizzard used to turn the window off and fall back to the stock frame, which
-- meant losing search, sorting and selection along with the styling. Now it
-- only changes how the window looks.

local DEFAULT = "dark"

function Theme:GetName()
	local addon = ns.Addon
	local ui = addon and addon.db and addon.db.profile.ui
	local name = ui and ui.theme
	if Kit:HasTheme(name) then
		return name
	end
	return DEFAULT
end

function Theme:GetDefault()
	return DEFAULT
end

-- Parcel stands in for the whole mail frame, not just its list, so the default
-- is to put Blizzard's away entirely. Turning this off leaves both on screen,
-- which is only useful while checking Parcel against the stock behaviour.
function Theme:HidesBlizzardMail()
	local addon = ns.Addon
	local ui = addon and addon.db and addon.db.profile.ui
	return ui == nil or ui.hideBlizzardMail ~= false
end

function Theme:Apply()
	local name = self:GetName()
	Kit:SetTheme(name)
	Events:Trigger("Parcel.Theme.Changed", name)
end
