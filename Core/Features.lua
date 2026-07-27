local ADDON, ns = ...

-- Whole subsystems a player can switch off.
--
-- Postal and zMail are both built as modules with an on/off switch each, and
-- anyone moving across will look for the same list. The split is deliberate:
-- this answers "is this part of Parcel running at all", while the settings in
-- each group answer "how does it behave once it is".

local Features = {}
ns.Features = Features

local Events = ns.Events

Features.list = {
	{
		key = "focus",
		label = "Hold off trades at the mailbox",
		desc = "Turns away trade requests and guild charters while a mailbox is open, "
			.. "so neither can steal the click you were about to make.",
		default = true,
	},
	{
		key = "rowShortcuts",
		label = "Click shortcuts in the inbox",
		desc = "Shift-click a mail to take its contents, ctrl-click to return it. "
			.. "Turn this off if you would rather a stray modifier never acted on mail.",
		default = true,
	},
	{
		key = "broker",
		label = "Minimap button",
		desc = "A button showing what is waiting, for the minimap or any panel addon "
			.. "that displays broker plugins.",
		default = true,
	},
	{
		key = "expiryWarning",
		label = "Warn about expiring mail at login",
		desc = "Says which of your characters has mail about to run out, "
			.. "using what Parcel has already seen rather than making you check each one.",
		default = true,
	},
	{
		key = "drafts",
		label = "Saved drafts",
		desc = "Keep mail you send often and load it back into the send page.",
		default = true,
	},
}

Features.labels = {}
for _, feature in ipairs(Features.list) do
	Features.labels[feature.key] = feature.label
end

local defaults = {}
for _, feature in ipairs(Features.list) do
	defaults[feature.key] = feature.default
end

local function store()
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile
	return profile and profile.modules
end

function Features:IsEnabled(key)
	local settings = store()
	if not settings then return defaults[key] ~= false end

	local value = settings[key]
	if value == nil then return defaults[key] ~= false end
	return value and true or false
end

function Features:SetEnabled(key, enabled)
	local settings = store()
	if not settings then return end

	settings[key] = enabled and true or false
	-- Anything that has to start or stop listens for this rather than being
	-- poked from here, so adding a feature never means editing this file.
	Events:Trigger("Parcel.Features.Changed", key, self:IsEnabled(key))
end
