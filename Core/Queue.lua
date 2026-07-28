local ADDON, ns = ...

local Queue = {}
ns.Queue = Queue

local Compat = ns.Compat
local Mail = ns.Mail
local Events = ns.Events

local DISPOSITION_FOR = {
	drain = "collected",
	takeItems = "collected",
	takeMoney = "collected",
	["return"] = "returned",
	delete = "deleted",
}

-- One mail can hold sixteen attachments plus money. Anything beyond that plus a
-- little slack means the mail is not draining and the run would spin forever.
local MAX_ATTEMPTS_PER_MAIL = ATTACHMENTS_MAX_RECEIVE + 4

-- How long to keep waiting on a command the server never acknowledges.
local COMMAND_TIMEOUT = 10

local DEFAULTS = {
	minInterval = 0.30,
	keepFreeSlots = 1,
	verbose = true,
}

Queue.pending = {}
Queue.failedItems = {}
Queue.running = false
Queue.done = 0
Queue.total = 0
Queue.skipped = 0
Queue.itemsTaken = 0

local driver = CreateFrame("Frame")
driver:Hide()

local events = CreateFrame("Frame")

-- Settings
-- ---------------------------------------------------------------------------

local function setting(key)
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile and addon.db.profile.collect
	local value = profile and profile[key]
	if value == nil then
		return DEFAULTS[key]
	end
	return value
end

-- Reporting each mail
-- ---------------------------------------------------------------------------

-- What a mail is holding, counted by item link so stacks add up rather than
-- being listed slot by slot.
local function countAttachments(index)
	local counts = {}
	for slot = 1, ATTACHMENTS_MAX_RECEIVE do
		local link = GetInboxItemLink(index, slot)
		if link then
			local count = select(4, GetInboxItem(index, slot))
			counts[link] = (counts[link] or 0) + (count or 1)
		end
	end
	return counts
end

-- Reported as the difference between what the mail held when Parcel started on
-- it and what is left, so a run that stops on bag space says what it actually
-- took rather than what it meant to.
local function describeTaken(entry)
	local before = entry.before
	if not before then return nil end

	local record = entry.txn and ns.Ledger:RecordFor(entry.txn) or Mail:Resolve(entry.handle)
	local afterItems = record and countAttachments(record.index) or {}
	local afterMoney = record and record.money or 0

	local parts = {}
	for link, count in pairs(before.items) do
		local taken = count - (afterItems[link] or 0)
		if taken > 0 then
			parts[#parts + 1] = taken > 1 and ("%sx%d"):format(link, taken) or link
		end
	end

	local money = (before.money or 0) - afterMoney
	if money > 0 then
		parts[#parts + 1] = ns.Money(money)
	end

	if #parts == 0 then return nil end
	return ("%s: %s"):format(before.sender or UNKNOWN, table.concat(parts, ", "))
end

-- Queue building
-- ---------------------------------------------------------------------------

function Queue:Push(kind, record)
	local handle = Mail:GetHandle(record)
	if not handle then return false end

	local txn = ns.Ledger and ns.Ledger:For(record) or nil

	self.pending[#self.pending + 1] = { kind = kind, handle = handle, txn = txn }
	return true
end

-- Returns the number of mails queued. The caller decides what is eligible; the
-- runner still refuses COD and GM mail no matter what it is handed.
function Queue:PushMatching(kind, predicate)
	local queued = 0
	for _, record in ipairs(Mail:GetRecords()) do
		if record.isGM or record.cod > 0 then
			-- never automated, in any mode
		elseif not predicate or predicate(record) then
			if self:Push(kind, record) then
				queued = queued + 1
			end
		end
	end
	return queued
end

function Queue:Clear()
	wipe(self.pending)
	self.current = nil
end

-- Running
-- ---------------------------------------------------------------------------

function Queue:IsRunning()
	return self.running
end

function Queue:GetProgress()
	return self.done, self.total
end

function Queue:Report(message)
	if setting("verbose") then
		Events:Trigger("Parcel.Queue.Message", message)
	end
end

function Queue:Start()
	if self.running then return false end
	if #self.pending == 0 then return false end

	self.running = true
	self.done = 0
	self.skipped = 0
	self.total = #self.pending
	self.current = nil
	self.entryAttempts = 0
	self.sinceAction = 0
	self.commandWait = 0
	wipe(self.failedItems)

	-- Retail only. Tells the client an addon is draining the inbox so it stops
	-- re-sorting the list underneath us. Pairing this with the false call on
	-- every exit path is why Stop is the only way out of a run.
	Compat:SetOpeningAll(true)

	events:RegisterEvent("MAIL_INBOX_UPDATE")
	events:RegisterEvent("UI_ERROR_MESSAGE")
	events:RegisterEvent("MAIL_FAILED")
	events:RegisterEvent("MAIL_CLOSED")
	events:RegisterEvent("PLAYER_LEAVING_WORLD")
	if Compat.isRetail then
		events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
	end

	Mail:Refresh()
	if ns.Ledger then ns.Ledger:Observe(Mail:GetRecords()) end
	driver:Show()

	Events:Trigger("Parcel.Queue.Started", self.total)
	return true
end

function Queue:Stop(reason)
	-- Stopping an idle queue still has to drop whatever was queued but never
	-- started, or it runs the moment something calls Start again.
	if not self.running then
		self:Clear()
		return
	end

	self.running = false
	driver:Hide()
	events:UnregisterAllEvents()
	Compat:SetOpeningAll(false)

	self:Clear()

	local done, total, skipped = self.done, self.total, self.skipped
	Events:Trigger("Parcel.Queue.Stopped", reason, done, total, skipped)
end

function Queue:CompleteEntry()
	local entry = self.current

	if entry then
		local line = describeTaken(entry)
		if line then
			self:Report(line)
		end
	end

	self.current = nil
	self.entryAttempts = 0
	self.done = self.done + 1

	-- The archive needs to know what happened to this mail, and only the queue
	-- knows whether it was drained, returned or deleted.
	if entry then
		if ns.Ledger and entry.txn then
			ns.Ledger:Settle(entry.txn, DISPOSITION_FOR[entry.kind])
		end
		Events:Trigger("Parcel.Queue.Completed", entry.kind, entry.handle)
	end

	Events:Trigger("Parcel.Queue.Progress", self.done, self.total)
end

function Queue:Acted()
	self.sinceAction = 0
	self.commandWait = 0
end

function Queue:HasRoomFor(index, slot)
	local free = Compat:GetFreeBagSlots()
	if free > setting("keepFreeSlots") then
		return true
	end
	return Mail:CanStackWith(index, slot)
end

function Queue:Step()
	if not self.current then
		self.current = tremove(self.pending, 1)
		self.entryAttempts = 0
		if not self.current then
			return self:Stop("finished")
		end
	end

	local entry = self.current
	local record = entry.txn and ns.Ledger:RecordFor(entry.txn) or Mail:Resolve(entry.handle)

	-- No record means the mail is gone: fully drained, returned, or pushed past
	-- the hundred the client will show. Nothing left to do with it either way.
	if not record then
		return self:CompleteEntry()
	end

	-- Snapshot on first touch, while the mail still has everything in it.
	if not entry.before then
		entry.before = {
			sender = record.sender,
			subject = record.subject,
			money = record.money,
			items = countAttachments(record.index),
		}
	end

	self.entryAttempts = self.entryAttempts + 1
	if self.entryAttempts > MAX_ATTEMPTS_PER_MAIL then
		self:Report(("Stopped working on %s, it is not emptying."):format(record.subject or UNKNOWN))
		return self:CompleteEntry()
	end

	if record.isGM or record.cod > 0 then
		self.skipped = self.skipped + 1
		return self:CompleteEntry()
	end

	if entry.kind == "return" then
		ReturnInboxItem(record.index)
		self:Acted()
		return self:CompleteEntry()
	end

	if entry.kind == "delete" then
		DeleteInboxItem(record.index)
		self:Acted()
		return self:CompleteEntry()
	end

	if entry.kind ~= "takeMoney" then
		local slot = Mail:GetTopAttachment(record.index, self.failedItems)
		if slot then
			if not self:HasRoomFor(record.index, slot) then
				self:Report("Stopping, your bags are full.")
				return self:Stop("bags")
			end
			TakeInboxItem(record.index, slot)
			self.itemsTaken = self.itemsTaken + 1
			return self:Acted()
		end
	end

	if entry.kind ~= "takeItems" and record.money > 0 then
		TakeInboxMoney(record.index)
		return self:Acted()
	end

	return self:CompleteEntry()
end

driver:SetScript("OnUpdate", function(_, elapsed)
	if not Queue.running then return end

	Queue.sinceAction = Queue.sinceAction + elapsed
	if Queue.sinceAction < setting("minInterval") then
		return
	end

	-- The one question Postal answers by polling item counts, asked directly.
	-- Both Retail and Classic Era expose it and Blizzard's own Open All uses it.
	if Compat:IsCommandPending() then
		Queue.commandWait = Queue.commandWait + elapsed
		if Queue.commandWait > COMMAND_TIMEOUT then
			Queue:Report("The server stopped responding, stopping here.")
			Queue:Stop("timeout")
		end
		return
	end

	Queue.commandWait = 0
	Queue:Step()
end)

events:SetScript("OnEvent", function(_, event, ...)
	if event == "MAIL_INBOX_UPDATE" then
		-- Indices move when new mail lands at the front or old mail rolls in
		-- from past the hundredth, so every entry is re-resolved by fingerprint
		-- rather than holding an index across an update.
		Mail:Refresh()
		if ns.Ledger then ns.Ledger:Observe(Mail:GetRecords()) end
	if ns.Ledger then ns.Ledger:Observe(Mail:GetRecords()) end

	elseif event == "UI_ERROR_MESSAGE" then
		-- The payload is (message) on some clients and (errorType, message) on
		-- others, so match on whichever argument is a string.
		for i = 1, select("#", ...) do
			local value = select(i, ...)
			if type(value) == "string" then
				if value == ERR_INV_FULL then
					Queue:Report("Stopping, your bags are full.")
					Queue:Stop("bags")
				elseif value == ERR_ITEM_MAX_COUNT then
					local record = Queue.current and Mail:Resolve(Queue.current.handle)
					if record then
						local _, _, itemID = Mail:GetTopAttachment(record.index, Queue.failedItems)
						if itemID then
							Queue.failedItems[itemID] = true
						end
					end
				end
			end
		end

	elseif event == "MAIL_FAILED" then
		local itemID = ...
		if itemID then
			Queue.failedItems[itemID] = true
		end

	elseif event == "MAIL_CLOSED" or event == "PLAYER_LEAVING_WORLD" then
		Queue:Stop("closed")

	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		if Compat:IsMailInteraction(...) then
			Queue:Stop("closed")
		end
	end
end)
