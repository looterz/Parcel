local ADDON, ns = ...

-- What counts as wanted mail.
--
-- Postal's filter list and a rules engine are the same question asked twice, so
-- the conditions live here rather than inside the collector. Collect's category
-- filters are the first consumer and Core/Rules.lua will be the second, reusing
-- this vocabulary instead of inventing a parallel one.

local Filters = {}
ns.Filters = Filters

-- Names live in Core/Locale.lua because they are translated. A miss classifies
-- the mail as ordinary player mail, which is the harmless direction to be wrong
-- in, and the setting below lets a player add whatever their client calls it.
local function postmasterNames()
	local names = {}
	for _, name in ipairs(ns.postmasterNames) do
		names[#names + 1] = name
	end

	for name in ns.ExtraPostmasterNames():gmatch("[^,;\n]+") do
		name = strtrim(name)
		if name ~= "" then names[#names + 1] = name end
	end

	return names
end

Filters.categories = {
	{ key = "ahSold", label = "Auction sold" },
	{ key = "ahWon", label = "Auction won" },
	{ key = "ahExpired", label = "Auction expired" },
	{ key = "ahCancelled", label = "Auction cancelled" },
	{ key = "ahOutbid", label = "Outbid notices" },
	{ key = "postmaster", label = "Postmaster" },
	{ key = "player", label = "Everything else" },
}

Filters.categoryLabels = {}
for _, category in ipairs(Filters.categories) do
	Filters.categoryLabels[category.key] = category.label
end

function Filters:IsPostmaster(record)
	local sender = record and record.sender
	if not sender then return false end

	for _, name in ipairs(postmasterNames()) do
		if sender:find(name, 1, true) then return true end
	end

	return false
end

-- Exactly one category per mail, so the filters cannot double count and a mail
-- can never be both included and excluded. Postmaster is tested first because
-- its mail classifies as player mail by subject.
function Filters:CategoryOf(record)
	if self:IsPostmaster(record) then return "postmaster" end

	local kind = record and record.mailType
	if kind and self.categoryLabels[kind] then return kind end

	return "player"
end

-- The condition vocabulary. Rules will compose these; the category filters
-- below use only the first.
Filters.conditions = {
	category = function(record, wanted) return Filters:CategoryOf(record) == wanted end,
	fromAuction = function(record) return (record.mailType or ""):sub(1, 2) == "ah" end,
	fromPostmaster = function(record) return Filters:IsPostmaster(record) end,
	senderIs = function(record, name) return record.sender == name end,
	senderContains = function(record, text)
		return (record.sender or ""):lower():find((text or ""):lower(), 1, true) ~= nil
	end,
	subjectContains = function(record, text)
		return (record.subject or ""):lower():find((text or ""):lower(), 1, true) ~= nil
	end,
	hasItems = function(record) return (record.itemCount or 0) > 0 end,
	hasMoney = function(record) return (record.money or 0) > 0 end,
	isCOD = function(record) return (record.cod or 0) > 0 end,
	wasReturned = function(record) return record.wasReturned and true or false end,
	-- daysLeft drifts, so this is a threshold rather than a comparison. Never
	-- test it for equality.
	expiresWithin = function(record, days) return (record.daysLeft or 0) < days end,
}

-- Settings
-- ---------------------------------------------------------------------------

local function store()
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile
	return profile and profile.collect and profile.collect.filters
end

function Filters:IsEnabled(key)
	local settings = store()
	if not settings then return true end
	if settings[key] == nil then return true end
	return settings[key] and true or false
end

function Filters:SetEnabled(key, enabled)
	local settings = store()
	if not settings then return end
	settings[key] = enabled and true or false
end

function Filters:AllEnabled()
	for _, category in ipairs(self.categories) do
		if not self:IsEnabled(category.key) then return false end
	end
	return true
end

function Filters:DisabledLabels()
	local out = {}
	for _, category in ipairs(self.categories) do
		if not self:IsEnabled(category.key) then
			out[#out + 1] = category.label
		end
	end
	return out
end

-- Nil when nothing is excluded, which keeps Collect on its cheap path and means
-- the default install behaves exactly as it did before filters existed.
function Filters:Predicate()
	if self:AllEnabled() then return nil end

	return function(record)
		return Filters:IsEnabled(Filters:CategoryOf(record))
	end
end
