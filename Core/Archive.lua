local ADDON, ns = ...

-- Everything Parcel sees, kept and searchable.
--
-- Two constraints shape this. Parcel can only archive mail it actually saw, so
-- anything that expired while you were offline was never in front of us. And
-- GetInboxText marks a mail read and can cause a text only mail to be deleted
-- when the frame closes, so body text is never read speculatively. Headers,
-- attachments, gold and invoices are all safe without opening anything.

local Archive = {}
ns.Archive = Archive

local Mail = ns.Mail
local Events = ns.Events

local DEFAULTS = {
	retentionDays = 60,
	maxEntries = 5000,
}

local SECONDS_PER_DAY = 86400

-- Declared up here because store() calls it, and store() is defined first.
local invalidateIndex

-- Rebuilt on demand, never saved. Keeping a lowercased blob per entry turns
-- search into one string find rather than six.
local haystacks = {}

local function setting(key)
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile and addon.db.profile.archive
	local value = profile and profile[key]
	if value == nil then return DEFAULTS[key] end
	return value
end

local function store()
	local addon = ns.Addon
	if not addon or not addon.db then return nil end

	local global = addon.db.global
	global.archive = global.archive or { entries = {} }
	global.archive.entries = global.archive.entries or {}

	-- An earlier build persisted its lookup index here. Drop it on sight so the
	-- saved file stops carrying a duplicate of every entry.
	if global.archive.byKey or global.archive.byID then
		global.archive.byKey = nil
		global.archive.byID = nil
		invalidateIndex()
	end

	return global.archive
end

local function characterName()
	local name = UnitName("player") or "?"
	return name .. "-" .. (GetRealmName() or "?")
end

function Archive:GetEntries()
	local archive = store()
	return archive and archive.entries or {}
end

function Archive:Count()
	return #self:GetEntries()
end

-- Capture
-- ---------------------------------------------------------------------------

-- A link is only worth keeping when it says something the item id does not.
-- Fields two to eight of the item string are the enchant, the four gem sockets,
-- the suffix and the unique id; everything after that is the level and spec it
-- happened to be linked at, which no tooltip depends on.
function Archive:LinkMatters(link)
	if type(link) ~= "string" then return false end

	local payload = link:match("|Hitem:([^|]*)") or link:match("^item:(.*)$")
	if not payload then return true end

	local fields = {}
	for value in (payload .. ":"):gmatch("([^:]*):") do
		fields[#fields + 1] = value
	end

	for index = 2, 8 do
		local value = fields[index]
		if value and value ~= "" and value ~= "0" then return true end
	end

	return false
end

local function itemsFor(record)
	local items = {}

	-- Packed by Mail:Attachments, because the slots are sparse. A slot with
	-- nothing known about it yet is skipped: IsComplete holds the whole mail
	-- back until at least one of them can be named.
	for _, attachment in ipairs(Mail:Attachments(record.index)) do
		local link = attachment.link
		if link or attachment.id or attachment.name then
			if link and ns.ItemNames then ns.ItemNames:Learn(link) end
			items[#items + 1] = {
				id = attachment.id or (link and tonumber(link:match("item:(%d+)"))) or nil,
				l = (link and Archive:LinkMatters(link)) and link or nil,
				name = attachment.name,
				n = attachment.count or 1,
				q = attachment.quality,
			}
		end
	end

	return items
end

local function invoiceFor(record)
	if not Mail:IsAuction(record.mailType) then return nil end

	-- Retail adds moneyDelay, etaHour and etaMin before the stack count, so the
	-- count is read positionally rather than by name to stay correct on both.
	local kind, itemName, player, bid, buyout, deposit, consignment,
		_, _, _, count = GetInboxInvoiceInfo(record.index)
	if not kind then return nil end

	return {
		kind = kind,
		item = itemName,
		player = player,
		bid = bid,
		buyout = buyout,
		deposit = deposit,
		cut = consignment,
		count = count,
	}
end

-- Matching an archived mail is the same problem the queue solves, and it has
-- the same trap. expiresAt is recomputed as time() + daysLeft * 86400 on every
-- refresh, and because time() is whole seconds and daysLeft is a float it
-- jitters by a second or two even though the mail has not moved.
--
-- Keying on it exactly meant every MAIL_INBOX_UPDATE minted a fresh entry, so
-- one auction sale turned into six. Lookup is tolerant now, exactly like
-- Mail:Resolve, and the stored expiry is never rewritten once set so drift
-- cannot accumulate.
local TOLERANCE = Mail.EXPIRY_TOLERANCE or 120

-- Held here rather than on the archive table, which is saved variables.
--
-- Storing it there wrote the whole index out to ParcelDB and, worse, the saved
-- file expands every shared reference into its own literal. After a reload the
-- entries reachable through the index were separate tables from the ones in
-- archive.entries, so marking a mail collected updated a copy nobody was
-- looking at and the history kept saying it was still waiting.
local indexCache, indexOwner

local nameIDs, nameIDsOwner

function invalidateIndex()
	indexCache, indexOwner = nil, nil
	nameIDs, nameIDsOwner = nil, nil
end

-- Mail that hands an item back carries the real thing, so its attachments say
-- what an item of that name actually is. A sale only ever gives the name.
local function itemIDsByName(archive)
	if nameIDs and nameIDsOwner == archive then return nameIDs end

	nameIDs = {}
	nameIDsOwner = archive

	for _, entry in ipairs(archive.entries) do
		for _, item in ipairs(entry.items or {}) do
			if item.name and item.id and not nameIDs[item.name] then
				nameIDs[item.name] = item.id
			end
		end
	end

	return nameIDs
end

function Archive:ItemIDForName(name)
	if type(name) ~= "string" or name == "" then return nil end

	local archive = store()
	if not archive then return nil end

	return itemIDsByName(archive)[name]
end

local function index(archive)
	if indexCache and indexOwner == archive then return indexCache end

	local map = {}
	for _, entry in ipairs(archive.entries) do
		if entry.key then
			local bucket = map[entry.key]
			if not bucket then
				bucket = {}
				map[entry.key] = bucket
			end
			bucket[#bucket + 1] = entry
		end
	end
	indexCache, indexOwner = map, archive
	return map
end

local function findEntry(archive, key, expiresAt)
	local bucket = index(archive)[key]
	if not bucket then return nil end

	local best, bestDelta
	for _, entry in ipairs(bucket) do
		local delta = math.abs((entry.expires or 0) - expiresAt)
		if delta <= TOLERANCE and (not bestDelta or delta < bestDelta) then
			best, bestDelta = entry, delta
		end
	end
	return best
end

local function addToIndex(archive, entry)
	if not entry.key then return end
	local map = index(archive)
	local bucket = map[entry.key]
	if not bucket then
		bucket = {}
		map[entry.key] = bucket
	end
	bucket[#bucket + 1] = entry
end

-- skip holds entries already spoken for this session, so mails identical down
-- to the second each adopt their own record instead of collapsing onto one.
function Archive:AdoptExisting(record, skip)
	local archive = store()
	if not archive then return nil end

	local bucket = index(archive)[record.key]
	if not bucket then return nil end

	local best, bestDelta
	for _, entry in ipairs(bucket) do
		if not (skip and skip[entry]) then
			local delta = math.abs((entry.expires or 0) - record.expiresAt)
			if delta <= TOLERANCE and (not bestDelta or delta < bestDelta) then
				best, bestDelta = entry, delta
			end
		end
	end

	return best
end

function Archive:NewEntry(record)
	local archive = store()
	if not archive then return nil end

	local entry = {
			id = record.key .. "|" .. tostring(math.floor(record.expiresAt)),
			key = record.key,
			-- Set once. Rewriting it every refresh would let the jitter walk.
			expires = math.floor(record.expiresAt),
			dir = "in",
			char = characterName(),
			disp = "inbox",
			-- Derived from daysLeft, so an estimate. seen is the exact moment
			-- Parcel first laid eyes on it, which is the honest timestamp.
			at = math.floor(record.arrivedAt),
			seen = time(),
		}
	archive.entries[#archive.entries + 1] = entry
	addToIndex(archive, entry)
	self.stats.created = self.stats.created + 1
	return entry
end

function Archive:ApplyRecord(entry, record)
	if not entry or not record then return end

	self.stats.updated = self.stats.updated + 1
	entry.who = record.sender
	entry.subj = record.subject
	entry.mtype = record.mailType
	entry.money = math.max(entry.money or 0, record.money or 0)
	entry.cod = math.max(entry.cod or 0, record.cod or 0)

	-- Attachments are re-read every pass because item data arrives from the
	-- server after the header does, so the first look often has no names.
	if record.itemCount > 0 then
		local found = itemsFor(record)
		-- Never trade a fuller answer for an emptier one. Item data trails the
		-- header, so an early pass sees less than a later one, and a mail
		-- drained in between would otherwise keep the early answer for good.
		if #found >= #(entry.items or {}) then
			entry.items = found
		end
	end

	entry.invoice = entry.invoice or invoiceFor(record)
	if entry.invoice and entry.invoice.item and entry.items and entry.items[1]
		and entry.invoice.item == entry.items[1].name then
		entry.invoice.item = nil
	end
	haystacks[entry] = nil
end

function Archive:Upsert(record)
	local entry = self:AdoptExisting(record) or self:NewEntry(record)
	self:ApplyRecord(entry, record)
	return entry
end

-- Counters behind /parcel diag.
Archive.stats = {
	captures = 0, seen = 0, created = 0, updated = 0, incomplete = 0, noStore = 0,
	settledByLedger = 0, settledByHandle = 0, settleMissed = 0,
}

-- The client fills the inbox in stages, so a header can arrive before its
-- sender and subject. Blizzard's own inbox falls back to UNKNOWN for display.
function Archive:IsComplete(record)
	if not record then return false end
	if not record.sender or record.sender == "" then return false end
	if not record.subject or record.subject == "" then return false end

	if RETRIEVING_DATA and (record.subject == RETRIEVING_DATA or record.sender == RETRIEVING_DATA) then
		return false
	end

	-- The item data arrives after the header carrying it. A mail that says it
	-- has attachments and cannot name a single one has not finished arriving,
	-- and filing it now records it as having carried nothing at all, which is
	-- permanent once it is collected.
	if (record.itemCount or 0) > 0 and not Mail:AttachmentsReadable(record.index) then
		return false
	end

	return true
end

function Archive:CaptureInbox()
	local archive = store()
	if not archive then
		self.stats.noStore = self.stats.noStore + 1
		return
	end

	self.stats.captures = self.stats.captures + 1

	ns.Ledger:Observe(Mail:GetRecords())
end

function Archive:EntryFor(record)
	local archive = store()
	if not archive or not record then return nil end
	return findEntry(archive, record.key, record.expiresAt)
end

function Archive:Wipe()
	local archive = store()
	if not archive then return 0 end

	local removed = #archive.entries
	archive.entries = {}
	wipe(haystacks)
	invalidateIndex()

	if ns.Ledger then ns.Ledger:Reset() end
	Events:Trigger("Parcel.Archive.Changed")
	return removed
end

-- Only ever called for a mail the player actually opened. GetInboxText marks a
-- mail read and creates its letter item, which causes a text only mail to be
-- deleted when the frame closes, so it must never run speculatively. Opening a
-- mail does all of that anyway, which is what makes this the one safe moment.
function Archive:CaptureBody(record)
	local archive = store()
	if not archive or not record then return end

	local entry = findEntry(archive, record.key, record.expiresAt)
	if not entry then
		self:Upsert(record)
		entry = findEntry(archive, record.key, record.expiresAt)
	end
	if not entry then return end

	entry.opened = entry.opened or time()

	local body = GetInboxText(record.index)
	if body and body ~= "" then
		entry.body = body
		haystacks[entry] = nil
	end

	entry.invoice = entry.invoice or invoiceFor(record)
end

local DISPOSITION = {
	drain = "collected",
	takeItems = "collected",
	takeMoney = "collected",
	["return"] = "returned",
	delete = "deleted",
}

function Archive:MarkDisposition(handle, kind)
	local archive = store()
	if not archive or not handle then return end

	local entry = findEntry(archive, handle.key, handle.expiresAt)
	if not entry then
		self.stats.settleMissed = self.stats.settleMissed + 1
		return
	end

	local disposition = DISPOSITION[kind]
	if disposition then
		if entry.disp ~= disposition then
			self.stats.settledByHandle = self.stats.settledByHandle + 1
		end
		entry.disp = disposition
		entry.dispAt = time()
	end
	haystacks[entry] = nil
end

-- How the archive currently reads, for the diagnostic.
function Archive:DispositionCounts()
	local counts, waiting = {}, 0

	for _, entry in ipairs(self:GetEntries()) do
		local disposition = entry.disp or "inbox"
		counts[disposition] = (counts[disposition] or 0) + 1
		if disposition == "inbox" and entry.dir == "in" then waiting = waiting + 1 end
	end

	return counts, waiting
end

function Archive:SetDisposition(entry, disposition, manual)
	if not entry or not disposition then return false end
	if entry.disp == disposition then return false end

	entry.disp = disposition
	entry.dispAt = time()
	if manual ~= false then entry.manual = true end
	haystacks[entry] = nil

	Events:Trigger("Parcel.Archive.Changed")
	return true
end

function Archive:RecordSent(sent)
	local archive = store()
	if not archive or not sent then return end

	local now = time()
	local entry = {
		id = ("out|%d|%s"):format(now, sent.recipient or "?"),
		dir = "out",
		char = characterName(),
		disp = "sent",
		at = now,
		seen = now,
		dispAt = now,
		who = sent.recipient,
		subj = sent.subject,
		mtype = "player",
		money = sent.money or 0,
		cod = sent.cod or 0,
		postage = sent.postage or 0,
		items = sent.items,
	}

	archive.entries[#archive.entries + 1] = entry
end

-- Repair
-- ---------------------------------------------------------------------------

-- Merges entries that are the same mail recorded more than once. Needed because
-- an earlier build keyed on the exact expiry and minted a new entry on every
-- inbox update, so anyone who used it has a history full of copies.
--
-- Also backfills the key and expiry fields those entries never had, reading
-- them back out of the old composite id.
function Archive:Deduplicate()
	local archive = store()
	if not archive then return 0 end

	local kept = {}
	local buckets = {}
	local removed = 0

	for _, entry in ipairs(archive.entries) do
		if entry.dir == "in" and not entry.key and entry.id then
			local key, expires = entry.id:match("^(.*)|(%d+)$")
			if key then
				entry.key = key
				entry.expires = entry.expires or tonumber(expires)
			end
		end

		-- Keys written while the icons were still part of them do not match
		-- anything captured now, so the same mail would sit in the history
		-- twice. Trimming brings them onto the current format exactly.
		if entry.key then
			entry.key = Mail:ModerniseKey(entry.key)
		end

		if not entry.key then
			kept[#kept + 1] = entry
		else
			local bucket = buckets[entry.key]
			if not bucket then
				bucket = {}
				buckets[entry.key] = bucket
			end

			local match
			for _, other in ipairs(bucket) do
				if math.abs((other.expires or 0) - (entry.expires or 0)) <= TOLERANCE then
					match = other
					break
				end
			end

			if match then
				-- Fold anything the survivor is missing across, so merging never
				-- loses a body or an invoice that only one copy happened to hold.
				if entry.body and not match.body then match.body = entry.body end
				if entry.invoice and not match.invoice then match.invoice = entry.invoice end
				if entry.items and (not match.items or #entry.items > #match.items) then
					match.items = entry.items
				end
				if entry.opened and (not match.opened or entry.opened < match.opened) then
					match.opened = entry.opened
				end
				if entry.seen and (not match.seen or entry.seen < match.seen) then
					match.seen = entry.seen
				end
				if entry.dispAt and (not match.dispAt or entry.dispAt > match.dispAt) then
					match.dispAt = entry.dispAt
					match.disp = entry.disp
				end
				haystacks[match] = nil
				removed = removed + 1
			else
				bucket[#bucket + 1] = entry
				kept[#kept + 1] = entry
			end
		end
	end

	archive.entries = kept
	invalidateIndex()
	return removed
end

-- Retention
-- ---------------------------------------------------------------------------

-- Approximate: the real cost is whatever the client's serialiser writes.
function Archive:EstimateBytes()
	local total = 0

	local function measure(value)
		local kind = type(value)
		if kind == "string" then
			total = total + #value + 3
		elseif kind == "number" then
			total = total + 8
		elseif kind == "boolean" then
			total = total + 5
		elseif kind == "table" then
			for key, item in pairs(value) do
				measure(key)
				measure(item)
			end
			total = total + 4
		end
	end

	measure(self:GetEntries())
	return total
end

function Archive:Prune()
	local archive = store()
	if not archive then return 0 end

	local entries = archive.entries
	local cutoff = time() - setting("retentionDays") * SECONDS_PER_DAY
	local removed = 0

	for position = #entries, 1, -1 do
		local entry = entries[position]
		-- Mail still sitting in the inbox is never pruned, however old it is;
		-- it is not history yet.
		if entry.disp ~= "inbox" and (entry.at or 0) < cutoff then
			haystacks[entry] = nil
			table.remove(entries, position)
			removed = removed + 1
		end
	end

	local limit = setting("maxEntries")
	while #entries > limit do
		haystacks[entries[1]] = nil
		table.remove(entries, 1)
		removed = removed + 1
	end

	invalidateIndex()
	archive.lastPrune = time()
	return removed
end

-- Search
-- ---------------------------------------------------------------------------

local function haystack(entry)
	local cached = haystacks[entry]
	if cached then return cached end

	local parts = { entry.who or "", entry.subj or "", entry.char or "", entry.body or "" }
	if entry.items then
		for _, item in ipairs(entry.items) do
			-- The name is stored when it was known, but an item seen before the
			-- client cached it comes back later, so try again on every rebuild.
			local name = item.name
			if not name and item.id then
				name = C_Item.GetItemInfo(item.id)
				item.name = name
			end
			parts[#parts + 1] = name or ""
		end
	end

	cached = table.concat(parts, " "):lower()
	haystacks[entry] = cached
	return cached
end

-- Supports bare words and field:value terms. Quoted phrases are not split.
local function parse(query)
	local terms = {}

	for chunk in (query or ""):gmatch("%S+") do
		local field, value = chunk:match("^(%a+):(.+)$")
		if field and value then
			terms[#terms + 1] = { field = field:lower(), value = value:lower() }
		else
			terms[#terms + 1] = { field = "any", value = chunk:lower() }
		end
	end

	return terms
end

-- Typo tolerance, used only as a fallback. Levenshtein with an early bail as
-- soon as an entire row of the matrix exceeds the limit, so a word that cannot
-- possibly match costs almost nothing.
local function withinDistance(word, value, limit)
	local lw, lv = #word, #value
	if math.abs(lw - lv) > limit then return false end

	local previous, current = {}, {}
	for j = 0, lv do previous[j] = j end

	for i = 1, lw do
		current[0] = i
		local best = i
		local byte = word:byte(i)

		for j = 1, lv do
			local cost = (byte == value:byte(j)) and 0 or 1
			local score = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
			current[j] = score
			if score < best then best = score end
		end

		if best > limit then return false end
		previous, current = current, previous
	end

	return previous[lv] <= limit
end

-- Short terms are never fuzzed. At three characters almost everything is within
-- one edit of almost everything else, and the results stop meaning anything.
local function fuzzLimit(value)
	local length = #value
	if length >= 7 then return 2 end
	if length >= 4 then return 1 end
	return 0
end

local function fuzzyFind(text, value)
	local limit = fuzzLimit(value)
	if limit == 0 then return false end

	for word in text:gmatch("[%w']+") do
		if #word <= 24 and withinDistance(word, value, limit) then
			return true
		end
	end

	return false
end

local function contains(text, value, fuzzy)
	if (text or ""):find(value, 1, true) then return true end
	return fuzzy and fuzzyFind(text or "", value) or false
end

local function matchesTerm(entry, term, fuzzy)
	local value = term.value

	if term.field == "body" then
		return contains((entry.body or ""):lower(), value, fuzzy)
	end

	if term.field == "from" then
		return entry.dir == "in" and (entry.who or ""):lower():find(value, 1, true) ~= nil
	elseif term.field == "to" then
		return entry.dir == "out" and (entry.who or ""):lower():find(value, 1, true) ~= nil
	elseif term.field == "subject" then
		return contains((entry.subj or ""):lower(), value, fuzzy)
	elseif term.field == "type" then
		return (entry.mtype or ""):lower():find(value, 1, true) ~= nil
	elseif term.field == "item" then
		if not entry.items then return false end
		for _, item in ipairs(entry.items) do
			local name = item.name or (item.id and C_Item.GetItemInfo(item.id))
			if name and contains(name:lower(), value, fuzzy) then return true end
		end
		return false
	end

	return contains(haystack(entry), value, fuzzy)
end

-- GetInboxText marks the mail read and creates a letter item, so bodies are
-- matched against what was captured rather than read live.
function Archive:Find(record)
	local archive = store()
	if not archive or not record then return nil end
	return findEntry(archive, record.key, record.expiresAt)
end

-- Correcting records left saying waiting
-- ---------------------------------------------------------------------------

-- A complete view of the inbox is the only sound evidence that a record saying
-- waiting is wrong. Partial views lie in both directions: the display caps at
-- fifty mails, and a header can arrive before its sender and subject do.
function Archive:CanReconcile()
	if not ns.Collect:IsMailOpen() then return false end
	if ns.Queue:IsRunning() then return false end
	if ns.Ledger.pending > 0 then return false end

	local shown, total = Mail:GetCounts()
	return shown == total
end

-- Anything this character still has filed as waiting that the mailbox is not
-- showing has left it, whether or not Parcel was running when it did. Records
-- from a build that wrote outcomes unreliably are corrected here.
function Archive:ReconcileWaiting()
	local archive = store()
	if not archive or not self:CanReconcile() then return 0 end

	local live = ns.Ledger:LiveEntries()
	local character = characterName()
	local healed = 0

	for _, entry in ipairs(archive.entries) do
		if entry.dir == "in" and entry.disp == "inbox" and entry.char == character
			and not live[entry] then
			entry.disp = "collected"
			entry.dispAt = entry.dispAt or time()
			-- Flagged, because this is inferred from the mail being absent
			-- rather than watched happening.
			entry.healed = true
			haystacks[entry] = nil
			healed = healed + 1
		end
	end

	if healed > 0 then
		Events:Trigger("Parcel.Archive.Changed")
		ns.Addon:Print(("Corrected %d records that still said waiting for mail your mailbox no longer holds."):format(healed))
	end

	return healed
end

local EMPTY_CONFIRM = 2
local confirming = false

-- An inbox that has not arrived yet and one that is genuinely empty both read
-- as zero, so an empty mailbox only counts as evidence once a second look
-- agrees. A mailbox with anything in it has already proved its data arrived.
function Archive:ReconcileOnUpdate()
	local shown = Mail:GetCounts()
	if shown > 0 then return self:ReconcileWaiting() end

	if confirming or not self:CanReconcile() then return 0 end
	confirming = true

	C_Timer.After(EMPTY_CONFIRM, function()
		confirming = false
		local stillShown, stillTotal = Mail:GetCounts()
		if stillShown == 0 and stillTotal == 0 then
			Archive:ReconcileWaiting()
		end
	end)

	return 0
end

function Archive:ResetReconcile()
	confirming = false
end

function Archive:Waiting(character)
	local out = {}

	for _, entry in ipairs(self:GetEntries()) do
		if entry.dir == "in" and entry.disp == "inbox"
			and (not character or entry.char == character) then
			out[#out + 1] = entry
		end
	end

	table.sort(out, function(a, b) return (a.expires or 0) < (b.expires or 0) end)
	return out
end

-- at is derived from daysLeft and is only ever an estimate of when the mail
-- arrived. dispAt and seen are moments Parcel recorded exactly, so history is
-- ordered by those: when you dealt with it if you did, when it arrived if not.
function Archive:TimeOf(entry)
	if not entry then return 0 end

	if entry.disp and entry.disp ~= "inbox" then
		return entry.dispAt or entry.seen or entry.at or 0
	end

	return entry.at or entry.seen or 0
end

function Archive:CurrentCharacter()
	return characterName()
end

-- Every character that has anything in the archive, current one first.
function Archive:GetCharacters()
	local seen, out = {}, {}

	local current = characterName()
	seen[current] = true
	out[#out + 1] = current

	for _, entry in ipairs(self:GetEntries()) do
		if entry.char and not seen[entry.char] then
			seen[entry.char] = true
			out[#out + 1] = entry.char
		end
	end

	table.sort(out, function(a, b)
		if a == current then return true end
		if b == current then return false end
		return a < b
	end)

	return out
end

-- direction is "in", "out" or nil for both. character is nil for all of them.
-- Results are newest first.
-- Returns the matches and whether they are near matches rather than exact.
--
-- The fuzzy pass only runs when the exact one found nothing, so typing towards
-- a word costs no more than it ever did, and a typo still lands somewhere
-- useful instead of on an empty list.
function Archive:Search(query, direction, character)
	local terms = parse(query)

	local function gather(fuzzy)
		local results = {}

		for _, entry in ipairs(self:GetEntries()) do
			if (not direction or entry.dir == direction)
				and (not character or entry.char == character) then
				local ok = true
				for _, term in ipairs(terms) do
					if not matchesTerm(entry, term, fuzzy) then
						ok = false
						break
					end
				end
				if ok then
					results[#results + 1] = entry
				end
			end
		end

		table.sort(results, function(a, b) return Archive:TimeOf(a) > Archive:TimeOf(b) end)
		return results
	end

	local exact = gather(false)
	if #exact > 0 or #terms == 0 then return exact, false end

	local fuzzable = false
	for _, term in ipairs(terms) do
		if fuzzLimit(term.value) > 0 then fuzzable = true end
	end
	if not fuzzable then return exact, false end

	local near = gather(true)
	return near, #near > 0
end

-- Wiring
-- ---------------------------------------------------------------------------

Events:Register("Parcel.Mail.Opened", function()
	Archive:CaptureInbox()
end)

Events:Register("Parcel.Mail.Closed", function()
	Archive:ResetReconcile()
	Archive:Prune()
end)

Events:Register("Parcel.Queue.Completed", function(kind, handle)
	Archive:MarkDisposition(handle, kind)
end)

-- A run empties mail faster than inbox updates arrive, so a mail could vanish
-- before any capture saw it. Queue:Start refreshes immediately before this.
Events:Register("Parcel.Queue.Started", function()
	Archive:CaptureInbox()
end)

Events:Register("Parcel.Send.Success", function(sent)
	Archive:RecordSent(sent)
end)

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MAIL_INBOX_UPDATE")
watcher:SetScript("OnEvent", function()
	-- Parcel's own session state, not MailFrame:IsShown(). Parcel reparents the
	-- Blizzard frame to a hidden holder, so it reads as hidden while a mail
	-- session is very much open.
	if not (ns.Collect:IsMailOpen() or ns.Window and ns.Window:IsShown()) then
		return
	end

	-- Handlers run in registration order and Core loads before UI, so nothing
	-- has refreshed the model for this update yet. The queue refreshes its own.
	if not ns.Queue:IsRunning() then
		Mail:Refresh()
	end

	Archive:CaptureInbox()
	Archive:ReconcileOnUpdate()
end)
