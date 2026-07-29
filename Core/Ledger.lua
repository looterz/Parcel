local ADDON, ns = ...

-- One transaction per mail, anchored on the archive entry rather than on any
-- value derived from the mail.
--
-- Matching is done once per observation: each live record takes the closest
-- entry not already matched in that same pass. Anything left over is new. A
-- transaction then holds both the entry and the current record, so draining and
-- settling are direct rather than searches that can miss.

local Ledger = {}
ns.Ledger = Ledger

local Archive = ns.Archive
local Events = ns.Events

local byEntry = {}
local byRecord = {}

Ledger.pending = 0

function Ledger:Reset()
	wipe(byEntry)
	wipe(byRecord)
	self.pending = 0
end

function Ledger:Observe(records)
	wipe(byRecord)

	-- Reset every pass. Held across passes it would stop a mail re-adopting the
	-- entry it already owns, and it would file a duplicate instead.
	local takenThisPass = {}
	local seenTxn = {}
	local pending = 0

	for _, record in ipairs(records) do
		Archive.stats.seen = Archive.stats.seen + 1

		if not Archive:IsComplete(record) then
			pending = pending + 1
			Archive.stats.incomplete = Archive.stats.incomplete + 1
		else
			local entry = Archive:AdoptExisting(record, takenThisPass)
			if not entry then
				entry = Archive:NewEntry(record)
			end

			if entry then
				takenThisPass[entry] = true

				local txn = byEntry[entry]
				if not txn then
					txn = { entry = entry, state = "committed" }
					byEntry[entry] = txn
				end

				txn.record = record
				seenTxn[txn] = true
				byRecord[record] = txn

				Archive:ApplyRecord(entry, record)
			end
		end
	end

	-- Anything not seen this pass has left the mailbox.
	for _, txn in pairs(byEntry) do
		if not seenTxn[txn] then txn.record = nil end
	end

	self.pending = pending
	return pending
end

function Ledger:For(record)
	if not record then return nil end

	local txn = byRecord[record]
	if txn then return txn end

	-- Mail:Refresh builds new record tables, so a miss can just mean nothing
	-- has observed them yet.
	self:Observe(ns.Mail:GetRecords())
	return byRecord[record]
end

-- The live mail a transaction is about, or nil once it has gone.
function Ledger:RecordFor(txn)
	return txn and txn.record or nil
end

function Ledger:Settle(txn, disposition)
	if not txn or not disposition or not txn.entry then return false end

	if Archive:SetDisposition(txn.entry, disposition, false) then
		Archive.stats.settledByLedger = Archive.stats.settledByLedger + 1
	end
	txn.state = "settled"
	return true
end

-- Mail Parcel watched leave the mailbox without an outcome ever being recorded.
-- Both settle paths can miss, and a mail can also leave without the queue being
-- the one that emptied it. Either way it is no longer waiting.
function Ledger:ReconcileGone(disposition)
	local settled = 0

	for _, txn in pairs(byEntry) do
		if txn.state ~= "settled" and txn.entry and not txn.record
			and txn.entry.disp == "inbox" then
			if self:Settle(txn, disposition or "collected") then
				settled = settled + 1
			end
		end
	end

	return settled
end

-- The archive entries the mailbox is showing right now. Anything filed as
-- waiting for this character and absent from this set is not in the mailbox.
function Ledger:LiveEntries()
	local live = {}
	for entry, txn in pairs(byEntry) do
		if txn.record then live[entry] = true end
	end
	return live
end

function Ledger:Stats()
	local committed, settled = 0, 0
	for _, txn in pairs(byEntry) do
		if txn.state == "settled" then
			settled = settled + 1
		else
			committed = committed + 1
		end
	end
	return committed, settled, self.pending
end

Events:Register("Parcel.Mail.Closed", function()
	Ledger:Reset()
end)
