local ADDON, ns = ...

-- One transaction per mail, from first sight to settled outcome.
--
-- States: pending (client still sending it, nothing written), committed
-- (written, and the transaction holds the entry), settled (outcome recorded).
-- Nothing is ever searched for after commit, so settling cannot miss.

local Ledger = {}
ns.Ledger = Ledger

local Archive = ns.Archive
local Events = ns.Events

local byId = {}
local claimed = {}
local byRecord = {}

Ledger.pending = 0

local function idFor(record)
	return record.key .. "|" .. tostring(math.floor(record.expiresAt))
end

function Ledger:Reset()
	wipe(byId)
	wipe(claimed)
	wipe(byRecord)
	self.pending = 0
end

function Ledger:Commit(txn, record)
	if txn.entry then return txn.entry end

	local entry = Archive:AdoptExisting(record, claimed) or Archive:NewEntry(record)
	if not entry then return nil end

	claimed[entry] = true
	txn.entry = entry
	txn.state = "committed"

	Archive:ApplyRecord(entry, record)
	return entry
end

-- Takes the whole list: telling identical mails apart needs them side by side.
function Ledger:Observe(records)
	wipe(byRecord)

	local counts = {}
	local pending = 0

	for _, record in ipairs(records) do
		Archive.stats.seen = Archive.stats.seen + 1

		if not Archive:IsComplete(record) then
			pending = pending + 1
			Archive.stats.incomplete = Archive.stats.incomplete + 1
		else
			local id = idFor(record)
			counts[id] = (counts[id] or 0) + 1

			local list = byId[id]
			if not list then
				list = {}
				byId[id] = list
			end

			local slot = counts[id]
			local txn = list[slot]
			if not txn then
				txn = { id = id, slot = slot, state = "pending" }
				list[slot] = txn
			end

			byRecord[record] = txn

			if txn.entry then
				Archive:ApplyRecord(txn.entry, record)
			else
				self:Commit(txn, record)
			end
		end
	end

	self.pending = pending
	return pending
end

function Ledger:For(record)
	if not record then return nil end

	local txn = byRecord[record]
	if txn then return txn end

	-- Mail:Refresh builds new record tables, so a lookup can miss simply
	-- because nothing has observed them yet.
	self:Observe(ns.Mail:GetRecords())
	return byRecord[record]
end

function Ledger:Settle(txn, disposition)
	if not txn or not disposition or not txn.entry then return false end

	Archive:SetDisposition(txn.entry, disposition, false)
	txn.state = "settled"
	return true
end

function Ledger:Stats()
	local committed, settled = 0, 0
	for _, list in pairs(byId) do
		for _, txn in ipairs(list) do
			if txn.state == "settled" then
				settled = settled + 1
			elseif txn.entry then
				committed = committed + 1
			end
		end
	end
	return committed, settled, self.pending
end

Events:Register("Parcel.Mail.Closed", function()
	Ledger:Reset()
end)
