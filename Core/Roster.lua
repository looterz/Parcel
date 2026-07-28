local ADDON, ns = ...

-- Who you might be mailing. Three sources, in the order they are worth
-- offering: people you actually mail, your own characters, then whatever the
-- client already knows about friends and guild.

local Roster = {}
ns.Roster = Roster

local MAX_RECENT = 20

local function db()
	local addon = ns.Addon
	return addon and addon.db and addon.db.global
end

-- Retail addresses mail as Name-Realm on connected realms. Your own realm is
-- implied and is dropped, because "Bob" and "Bob-YourRealm" are one person and
-- storing both means suggesting both. Another realm is genuinely part of the
-- name and is kept.
function Roster:NormalizeName(name)
	name = strtrim(name or "")
	if name == "" then return name end

	local base, realm = name:match("^(.-)%-(.+)$")
	if not base or base == "" then return name end

	local own = (GetRealmName() or ""):gsub("%s+", "")
	if realm:gsub("%s+", "") == own then return base end

	return name
end

local function realmKey()
	return (GetRealmName() or "?") .. "|" .. (UnitFactionGroup("player") or "?")
end

-- Characters
-- ---------------------------------------------------------------------------

function Roster:RecordSelf()
	local store = db()
	if not store then return end

	local name = UnitName("player")
	if not name then return end

	store.characters = store.characters or {}
	local bucket = store.characters[realmKey()]
	if not bucket then
		bucket = {}
		store.characters[realmKey()] = bucket
	end

	local _, class = UnitClass("player")
	bucket[name] = {
		level = UnitLevel("player"),
		class = class,
		seen = time(),
	}
end

-- No client API lists the rest of your account, so Parcel only learns a
-- character by seeing you log into it. Typing the name in is the way to know
-- about an alt you have not played since installing.
function Roster:AddAlt(name)
	name = self:NormalizeName(name)
	if name == "" then return false end

	local store = db()
	if not store then return false end

	store.characters = store.characters or {}
	local bucket = store.characters[realmKey()]
	if not bucket then
		bucket = {}
		store.characters[realmKey()] = bucket
	end

	if bucket[name] then return false end
	bucket[name] = { manual = true, seen = time() }
	return true
end

function Roster:RemoveAlt(name)
	name = self:NormalizeName(name)
	local bucket = self:GetCharacters()
	if not bucket[name] then return false end

	-- Logging in re-adds a real character, so removing one you actually play is
	-- pointless rather than harmful.
	bucket[name] = nil
	return true
end

function Roster:GetCharacters()
	local store = db()
	local bucket = store and store.characters and store.characters[realmKey()]
	return bucket or {}
end

function Roster:IsSelf(name)
	name = self:NormalizeName(name or "")
	if name == "" then return false end
	return name:lower() == (self:NormalizeName(UnitName("player") or "")):lower()
end

function Roster:IsOwnCharacter(name)
	if not name then return false end
	return self:GetCharacters()[self:NormalizeName(name)] ~= nil
end

-- Recent recipients
-- ---------------------------------------------------------------------------

function Roster:RecordRecipient(name)
	name = self:NormalizeName(name)
	if name == "" then return end

	local store = db()
	if not store then return end

	store.recipients = store.recipients or {}
	local list = store.recipients[realmKey()]
	if not list then
		list = {}
		store.recipients[realmKey()] = list
	end

	for index = #list, 1, -1 do
		if list[index]:lower() == name:lower() then
			table.remove(list, index)
		end
	end

	table.insert(list, 1, name)
	while #list > MAX_RECENT do
		table.remove(list)
	end

	-- Recents are capped so the ordering stays useful, but forgetting someone
	-- you have mailed is never helpful. This set is unbounded and is what makes
	-- an alt keep suggesting itself long after it fell off the recent list.
	store.known = store.known or {}
	local known = store.known[realmKey()]
	if not known then
		known = {}
		store.known[realmKey()] = known
	end
	known[name] = true
end

function Roster:GetKnown()
	local store = db()
	local known = store and store.known and store.known[realmKey()]
	return known or {}
end

function Roster:GetRecent()
	local store = db()
	local list = store and store.recipients and store.recipients[realmKey()]
	return list or {}
end

-- Contacts
-- ---------------------------------------------------------------------------

Roster.sourceLabels = {
	alt = "Your characters",
	recent = "Recently mailed",
	guild = "Guild",
	friend = "Friends",
}

-- Every name Parcel can offer, each with where it came from. Recents keep their
-- order; everything else is alphabetical.
function Roster:Contacts()
	local out, seen = {}, {}
	local me = (self:NormalizeName(UnitName("player") or "")):lower()

	local function add(name, source)
		if not name or name == "" then return end
		local normalised = self:NormalizeName(name)
		local lower = normalised:lower()
		if lower == "" or lower == me or seen[lower] then return end
		seen[lower] = true
		out[#out + 1] = { name = normalised, source = source }
	end

	for _, name in ipairs(self:GetRecent()) do add(name, "recent") end

	local function sorted(names)
		table.sort(names)
		return names
	end

	local alts = {}
	for name in pairs(self:GetCharacters()) do alts[#alts + 1] = name end
	for _, name in ipairs(sorted(alts)) do add(name, "alt") end

	local mailed = {}
	for name in pairs(self:GetKnown()) do mailed[#mailed + 1] = name end
	for _, name in ipairs(sorted(mailed)) do add(name, "recent") end

	if IsInGuild and IsInGuild() and GetNumGuildMembers then
		local guild = {}
		for index = 1, GetNumGuildMembers() or 0 do
			local name = GetGuildRosterInfo(index)
			if name then guild[#guild + 1] = name end
		end
		for _, name in ipairs(sorted(guild)) do add(name, "guild") end
	end

	if C_FriendList and C_FriendList.GetNumFriends then
		local friends = {}
		for index = 1, C_FriendList.GetNumFriends() or 0 do
			local info = C_FriendList.GetFriendInfoByIndex(index)
			if info and info.name then friends[#friends + 1] = info.name end
		end
		for _, name in ipairs(sorted(friends)) do add(name, "friend") end
	end

	return out
end

-- Suggestions
-- ---------------------------------------------------------------------------

local function startsWith(name, prefix)
	return name:lower():sub(1, #prefix) == prefix
end

-- Returns an ordered, de-duplicated list of names starting with text. Recent
-- recipients first because they are what you are most likely reaching for,
-- then your own characters, then whatever the client can offer.
function Roster:Suggest(text, limit)
	text = strtrim(text or "")
	if text == "" then return {} end

	limit = limit or 8
	local prefix = text:lower()
	local seen = {}
	local out = {}

	-- The game refuses mail addressed to the character sending it, and Blizzard's
	-- own field never offers it. One guard here rather than in each loop below,
	-- because the guild roster and the friends list both contain you and so can
	-- the recents if an older build ever recorded it.
	local me = (self:NormalizeName(UnitName("player") or "")):lower()

	local function add(name, source)
		if not name or name == "" then return end
		local lower = self:NormalizeName(name):lower()
		if lower == me then return end
		if seen[lower] then return end
		if not startsWith(name, prefix) then return end
		seen[lower] = true
		out[#out + 1] = { name = name, source = source }
	end

	for _, name in ipairs(self:GetRecent()) do
		if #out >= limit then return out end
		add(name, "recent")
	end

	for name in pairs(self:GetCharacters()) do
		if #out >= limit then return out end
		add(name, "alt")
	end

	for name in pairs(self:GetKnown()) do
		if #out >= limit then return out end
		add(name, "recent")
	end

	-- The client already tracks friends, guild and anyone you have interacted
	-- with. Battle.net accounts are excluded because they are not mailable.
	--
	-- The third argument is the cursor position, and it is what decides how much
	-- of the text counts as the prefix. Passing a constant 1 means asking for
	-- matches on the first letter only, which is why this returned nothing
	-- useful; Blizzard passes the edit box's real cursor position.
	if GetAutoCompleteResults then
		local cursor = strlenutf8 and strlenutf8(text) or #text
		local include = AUTOCOMPLETE_FLAG_ALL or 0
		local exclude = AUTOCOMPLETE_FLAG_BNET or 0
		local ok, results = pcall(GetAutoCompleteResults, text, limit, cursor, include, exclude)
		if ok and type(results) == "table" then
			for _, entry in ipairs(results) do
				if #out >= limit then return out end
				add(type(entry) == "table" and entry.name or entry, "game")
			end
		end
	end

	-- Guild and friends explicitly as well. GetAutoCompleteResults does not
	-- reliably include the guild roster on every client, and Postal carries its
	-- own guild matching for exactly that reason.
	if IsInGuild and IsInGuild() and GetNumGuildMembers then
		local total = GetNumGuildMembers()
		for i = 1, total or 0 do
			if #out >= limit then return out end
			add((GetGuildRosterInfo(i)), "guild")
		end
	end

	if C_FriendList and C_FriendList.GetNumFriends then
		for i = 1, C_FriendList.GetNumFriends() or 0 do
			if #out >= limit then return out end
			local info = C_FriendList.GetFriendInfoByIndex(i)
			add(info and info.name, "friend")
		end
	end

	return out
end

-- Lifecycle
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	-- Faction and level are not reliable until the world is loaded.
	Roster:RecordSelf()
end)

ns.Events:Register("Parcel.Send.Success", function(sent)
	if sent and sent.recipient then
		Roster:RecordRecipient(sent.recipient)
	end
end)
