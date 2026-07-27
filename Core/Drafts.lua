local ADDON, ns = ...

-- Mail you send often, kept.
--
-- Attachments are deliberately not part of a draft. They live in the client's
-- send slots, not in Parcel, and an item that was attached last week may be
-- gone, sold or on another character. Saving a name that cannot be honoured
-- would be worse than not saving it, so a draft is the words and the amount.

local Drafts = {}
ns.Drafts = Drafts

local Events = ns.Events

local function store()
	local addon = ns.Addon
	local global = addon and addon.db and addon.db.global
	if not global then return nil end

	global.drafts = global.drafts or {}
	return global.drafts
end

function Drafts:IsEnabled()
	return ns.Features:IsEnabled("drafts")
end

function Drafts:Save(name, draft)
	name = strtrim(name or "")
	if name == "" then return false, "A draft needs a name." end

	local drafts = store()
	if not drafts then return false end

	drafts[name] = {
		to = draft.to or "",
		subject = draft.subject or "",
		body = draft.body or "",
		mode = draft.mode or "money",
		amount = draft.amount or 0,
		at = time(),
	}

	Events:Trigger("Parcel.Drafts.Changed")
	return true
end

function Drafts:Get(name)
	local drafts = store()
	return drafts and drafts[name]
end

function Drafts:Delete(name)
	local drafts = store()
	if not drafts or not drafts[name] then return false end

	drafts[name] = nil
	Events:Trigger("Parcel.Drafts.Changed")
	return true
end

function Drafts:Count()
	local drafts = store()
	if not drafts then return 0 end

	local count = 0
	for _ in pairs(drafts) do count = count + 1 end
	return count
end

-- Alphabetical, because a draft is looked up by the name you gave it rather
-- than by when you last touched it.
function Drafts:List()
	local drafts = store()
	if not drafts then return {} end

	local names = {}
	for name in pairs(drafts) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end
