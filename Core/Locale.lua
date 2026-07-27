local ADDON, ns = ...

-- Translation scaffolding.
--
-- A missing string falls through to the key, which is written in English, so an
-- untranslated client shows English rather than a blank or an error. That means
-- new strings can be added without touching a single locale file.

local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L

local locale = GetLocale and GetLocale() or "enUS"

function ns.SetLocaleStrings(which, strings)
	if which ~= locale then return end
	for key, value in pairs(strings) do
		L[key] = value
	end
end

-- The Postmaster
-- ---------------------------------------------------------------------------

-- The mail that carries what would not fit in your bags. Nothing in the API
-- marks it, so it has to be recognised by sender name, and the name is
-- translated. Getting this wrong is not cosmetic: on a non-English client the
-- Postmaster collect filter silently applies to nothing.
--
-- Every locale is matched, not just the client's own, because a name costs
-- nothing to test against and a player on a non-English realm can still receive
-- from a differently named source. Entries other than enUS have not been
-- checked against a live client of that locale and are the least certain thing
-- in this file.
ns.postmasterNames = {
	"The Postmaster",
	"Thaumaturge Vashreen",
	"Der Postmeister",
	"Le receveur des postes",
	"El cartero",
	"Il Postino",
	"O Carteiro",
	"Почтмейстер",
	"우편배달부",
	"郵政管理員",
	"邮政管理员",
}

-- Players can add to it, which is the honest answer to a list that cannot be
-- verified for every locale from here.
function ns.ExtraPostmasterNames()
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile
	local extra = profile and profile.collect and profile.collect.postmasterNames
	return extra or ""
end
