local ADDON, ns = ...

-- Drives rounds of the queue until the mailbox is empty. No interface of its
-- own: both the Parcel window and the Blizzard frame fallback call into this.

local Collect = {}
ns.Collect = Collect

local Compat = ns.Compat
local Mail = ns.Mail
local Queue = ns.Queue
local Events = ns.Events

-- Mail past the hundredth only becomes visible as space frees up, and the
-- server will not refresh the inbox more than once a minute. Bounded so a
-- mailbox that keeps refilling cannot loop forever.
local MAX_REFRESH_ROUNDS = 10

-- Mail the client has not finished sending is not eligible, so a run has to be
-- able to wait for it rather than deciding there is nothing to do.
local MAX_PENDING_ROUNDS = 10
local PENDING_WAIT = 0.5

local refreshRounds = 0
local pendingRounds = 0
local pendingAnnounced = false
local collecting = false
local lastEligible
local filter

-- Every visit to a mailbox is its own session. Deferred work captures the
-- session it belongs to and does nothing if that session has ended, which is
-- what stops an abandoned run from picking itself back up when the player
-- returns. C_Timer.After cannot be cancelled, so the timer has to be the one
-- that checks.
local session = 0
local mailOpen = false

local function endSession()
	session = session + 1
end

local function stillCurrent(mySession)
	return collecting and session == mySession
end

local function hasSomethingToTake(record)
	return record.money > 0 or record.itemCount > 0
end

local function eligible(record)
	if record.isGM or record.cod > 0 then return false end
	if not ns.Archive:IsComplete(record) then return false end
	if not hasSomethingToTake(record) then return false end
	if filter and not filter(record) then return false end
	return true
end

local function eligibleCount()
	local count = 0
	for _, record in ipairs(Mail:GetRecords()) do
		if eligible(record) then
			count = count + 1
		end
	end
	return count
end

local function announce()
	Events:Trigger("Parcel.Collect.Changed")
end

-- Reporting what a run brought in
-- ---------------------------------------------------------------------------

-- Measured against GetMoney rather than added up from each mail's headline
-- amount, because a run that stops early on bag space has not taken everything
-- it was queued for and the totals would overstate it.
local runMoney, runItems
local sessionMoney, sessionReported

local function verbose()
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile and addon.db.profile.collect
	return not profile or profile.verbose ~= false
end

local function describe(money, items)
	local parts = {}
	if items > 0 then
		parts[#parts + 1] = ("%d item%s"):format(items, items == 1 and "" or "s")
	end
	if money > 0 then
		parts[#parts + 1] = ns.Money(money)
	end
	return table.concat(parts, " and ")
end

local function beginRun()
	runMoney = GetMoney()
	runItems = Queue.itemsTaken
end

local function reportRun()
	if not runMoney then return end

	local money = GetMoney() - runMoney
	local items = Queue.itemsTaken - runItems
	runMoney, runItems = nil, nil

	if money <= 0 and items <= 0 then return end

	sessionReported = (sessionReported or 0) + math.max(0, money)

	if verbose() then
		ns.Addon:Print("Collected " .. describe(money, items) .. ".")
	end
end

function Collect:IsCollecting()
	return collecting
end

-- Whether there is a live mail session. Tracked from the events rather than
-- read off MailFrame, whose shown state Parcel deliberately manipulates.
function Collect:IsMailOpen()
	return mailOpen
end

function Collect:Reset()
	collecting = false
	refreshRounds = 0
	pendingRounds = 0
	pendingAnnounced = false
	lastEligible = nil
	filter = nil
	endSession()
	Queue:Stop("cancelled")
	Queue:Clear()
	announce()
end

local function scheduleRefresh()
	local mySession = session
	local canCheck, wait = Compat:CanCheckInbox()

	if canCheck then
		Mail:RequestRefresh()
		-- The inbox arrives on MAIL_INBOX_UPDATE, so give the client a moment to
		-- deliver it before looking again.
		C_Timer.After(1.5, function()
			if not stillCurrent(mySession) then return end
			-- A refresh genuinely changes the picture, so the no-progress guard
			-- starts over rather than mistaking new mail for stuck mail.
			lastEligible = nil
			Collect:Continue()
		end)
		return
	end

	ns.Addon:Print(("Waiting %d seconds for the mailbox to refresh."):format(math.ceil(wait or 60)))
	C_Timer.After((wait or 60) + 0.5, function()
		if not stillCurrent(mySession) then return end
		scheduleRefresh()
	end)
end

function Collect:Continue()
	if not collecting then return end

	Mail:Refresh()
	local remaining = eligibleCount()

	if remaining == 0 and ns.Ledger.pending > 0 and pendingRounds < MAX_PENDING_ROUNDS then
		pendingRounds = pendingRounds + 1
		if not pendingAnnounced then
			pendingAnnounced = true
			ns.Addon:Print(("Waiting for %d mails to finish loading."):format(ns.Ledger.pending))
		end

		local mySession = session
		C_Timer.After(PENDING_WAIT, function()
			if not stillCurrent(mySession) then return end
			Collect:Continue()
		end)
		return
	end

	-- A round that leaves exactly as much behind as it started with is not going
	-- to do better on the next pass, and re-queueing it is an infinite loop. The
	-- realistic cause is an item the server keeps refusing.
	if remaining > 0 and remaining == lastEligible then
		ns.Addon:Print(("Stopping, %d mails would not empty."):format(remaining))
		return self:Finish()
	end

	if remaining > 0 then
		lastEligible = remaining
		Queue:PushMatching("drain", eligible)
		if Queue:Start() then
			announce()
			return
		end
	end

	if Mail:HasHiddenMail() and refreshRounds < MAX_REFRESH_ROUNDS then
		refreshRounds = refreshRounds + 1
		scheduleRefresh()
		return
	end

	self:Finish()
end

function Collect:Finish()
	-- Anything the run emptied but left without an outcome. Only while the
	-- mailbox is still open, because the inbox reads as empty once it closes,
	-- and only while nothing is hidden past the display cap, because a mail can
	-- drop off the list without leaving the mailbox.
	if mailOpen and not Mail:HasHiddenMail() then
		Mail:Refresh()
		ns.Ledger:Observe(Mail:GetRecords())

		local reconciled = ns.Ledger:ReconcileGone("collected")
		if reconciled > 0 and verbose() then
			ns.Addon:Print(("Recorded %d mails that had already gone."):format(reconciled))
		end
	end

	reportRun()
	collecting = false
	refreshRounds = 0
	pendingRounds = 0
	pendingAnnounced = false
	lastEligible = nil
	filter = nil
	endSession()
	announce()
end

-- predicate is optional and narrows what this run will take. Nil means
-- everything the queue is willing to touch.
function Collect:Start(predicate)
	if Queue:IsRunning() then return end

	self:Reset()
	collecting = true
	filter = predicate
	beginRun()

	Mail:Refresh()
	if Mail:GetCounts() == 0 then
		ns.Addon:Print("Nothing in the mailbox.")
		return self:Finish()
	end

	self:Continue()
end

function Collect:Stop()
	self:Reset()
end

-- Returns the selected mails through the queue rather than draining them.
function Collect:OpenRecords(records)
	if Queue:IsRunning() then return 0 end

	local handles = {}
	for _, record in ipairs(records) do
		handles[#handles + 1] = Mail:GetHandle(record)
	end

	if #handles == 0 then return 0 end

	self:Start(function(record)
		for _, handle in ipairs(handles) do
			if Mail:Matches(record, handle) then return true end
		end
		return false
	end)

	return #handles
end

function Collect:ReturnRecords(records)
	if Queue:IsRunning() then return 0 end

	local queued = 0
	for _, record in ipairs(records) do
		if not record.isGM and record.cod == 0 and record.canReply and not record.wasReturned then
			if Queue:Push("return", record) then
				queued = queued + 1
			end
		end
	end

	if queued > 0 then
		Queue:Start()
		announce()
	end

	return queued
end

-- Lifecycle
-- ---------------------------------------------------------------------------

-- Collect owns these directly rather than being fed by another file. Closing
-- the mailbox has to reset the run, and routing that through somewhere else is
-- one more place for it to be missed.
local events = CreateFrame("Frame")
events:RegisterEvent("MAIL_SHOW")
events:RegisterEvent("MAIL_CLOSED")
events:RegisterEvent("PLAYER_LEAVING_WORLD")
if Compat:HasInteractionManager() then
	events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
	events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
end

local function mailOpened()
	mailOpen = true
	-- A fresh visit always starts clean, whatever state the last one was left in.
	Collect:Reset()
	sessionMoney = GetMoney()
	sessionReported = 0
	Mail:Refresh()
	Events:Trigger("Parcel.Mail.Opened")
end

local function mailClosed()
	mailOpen = false
	Mail:ResetExpiryAnchors()
	reportRun()

	-- Anything taken by hand in the reader never went through a run, so the
	-- session total covers what the per-run lines missed.
	if sessionMoney and verbose() then
		local unreported = (GetMoney() - sessionMoney) - (sessionReported or 0)
		if unreported > 0 then
			ns.Addon:Print("Also took " .. ns.Money(unreported) .. " by hand.")
		end
	end
	sessionMoney, sessionReported = nil, nil

	Collect:Reset()
	Events:Trigger("Parcel.Mail.Closed")
end

events:SetScript("OnEvent", function(_, event, ...)
	if event == "MAIL_SHOW" then
		mailOpened()
	elseif event == "MAIL_CLOSED" or event == "PLAYER_LEAVING_WORLD" then
		mailClosed()
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		if Compat:IsMailInteraction(...) then mailOpened() end
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		if Compat:IsMailInteraction(...) then mailClosed() end
	end
end)

Events:Register("Parcel.Queue.Stopped", function(reason, done, total, skipped)
	if reason == "finished" then
		if skipped and skipped > 0 then
			ns.Addon:Print(("Skipped %d COD or Blizzard mails."):format(skipped))
		end
		if collecting then
			Collect:Continue()
		else
			announce()
		end
		return
	end

	-- Anything other than a clean finish ends the run. Reset rather than only
	-- clearing the flag, so nothing deferred can resume it.
	if collecting then
		reportRun()
		Collect:Reset()
	else
		announce()
	end

	if reason == "bags" then
		ns.Addon:Print("Stopped, your bags are full.")
	elseif reason == "timeout" then
		ns.Addon:Print("Stopped, the server stopped responding.")
	end
end)

Events:Register("Parcel.Queue.Started", announce)
Events:Register("Parcel.Queue.Progress", announce)

Events:Register("Parcel.Queue.Message", function(message)
	ns.Addon:Print(message)
end)
