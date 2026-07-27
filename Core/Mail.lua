local ADDON, ns = ...

local Mail = {}
ns.Mail = Mail

local Compat = ns.Compat

local records = {}
local byKey = {}
local shownCount, totalCount = 0, 0

-- How far apart two expiry instants can be and still be the same mail. daysLeft
-- is a float counted in days and time() is whole seconds, so the computed expiry
-- jitters by a second or two between refreshes even though the mail has not
-- moved. Generous enough to absorb that, tight enough that two mails which
-- genuinely arrived minutes apart never collide.
local EXPIRY_TOLERANCE = 120
Mail.EXPIRY_TOLERANCE = EXPIRY_TOLERANCE

local MAIL_LIFETIME_DAYS = 30
local SECONDS_PER_DAY = 86400

-- Mail types
-- ---------------------------------------------------------------------------

local function toPattern(subject)
	if type(subject) ~= "string" or subject == "" then
		return nil
	end

	-- Escape the whole string first, which turns the %s format specifier into a
	-- literal %%s, then swap that one token back out for a wildcard.
	local escaped = subject:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	return (escaped:gsub("%%%%s", ".*"))
end

local AH_PATTERNS
local function auctionPatterns()
	if AH_PATTERNS then return AH_PATTERNS end

	AH_PATTERNS = {}
	local sources = {
		ahCancelled = AUCTION_REMOVED_MAIL_SUBJECT,
		ahExpired = AUCTION_EXPIRED_MAIL_SUBJECT,
		ahOutbid = AUCTION_OUTBID_MAIL_SUBJECT,
		ahSold = AUCTION_SOLD_MAIL_SUBJECT,
		ahWon = AUCTION_WON_MAIL_SUBJECT,
	}

	for key, subject in pairs(sources) do
		local pattern = toPattern(subject)
		if pattern then
			AH_PATTERNS[key] = pattern
		end
	end

	return AH_PATTERNS
end

function Mail:ClassifySubject(subject)
	if not subject then return "player" end

	for key, pattern in pairs(auctionPatterns()) do
		if subject:find(pattern) then
			return key
		end
	end

	return "player"
end

function Mail:IsAuction(mailType)
	return mailType:sub(1, 2) == "ah"
end

-- Records
-- ---------------------------------------------------------------------------

-- Only fields that survive the mail being drained. Postal's composite id also
-- carries money and itemCount, which is fine for detecting that the list shifted
-- but useless as a handle: the moment you take the first attachment the id
-- changes and the mail you are working on looks like a different one.
--
-- What is left is not unique on its own, so identity is this key plus the expiry
-- instant, matched with a tolerance. See Resolve.
-- The icons are excluded for the same reason, which cost a second round of
-- duplicate history entries to work out. packageIcon is the first attachment's
-- texture: it is nil for mail carrying nothing, it is nil on the first read
-- before the server has sent the item data, and it changes as attachments come
-- out. stationeryIcon goes with it, since it buys no uniqueness that sender and
-- subject do not already give.
local KEY_FIELDS = 6

local function stableKey(sender, subject, cod, wasReturned, canReply, isGM)
	return table.concat({
		sender or "",
		subject or "",
		tostring(cod or 0),
		wasReturned and "1" or "0",
		canReply and "1" or "0",
		isGM and "1" or "0",
	}, "\30")
end

-- Keys written before the icons were dropped carry two extra leading fields.
-- Trimming them converts an old key to a current one exactly, which is what
-- lets an existing history be repaired rather than recorded a second time.
function Mail:ModerniseKey(key)
	if type(key) ~= "string" then return key end

	local fields = {}
	for field in (key .. "\30"):gmatch("(.-)\30") do
		fields[#fields + 1] = field
	end

	if #fields <= KEY_FIELDS then return key end
	return table.concat(fields, "\30", #fields - KEY_FIELDS + 1)
end

function Mail:Refresh()
	wipe(records)
	wipe(byKey)

	shownCount, totalCount = GetInboxNumItems()
	shownCount = shownCount or 0
	totalCount = totalCount or shownCount

	local now = time()

	for index = 1, shownCount do
		local packageIcon, stationeryIcon, sender, subject, money, cod, daysLeft,
			itemCount, wasRead, wasReturned, textCreated, canReply, isGM,
			firstItemQuantity, firstItem = GetInboxHeaderInfo(index)

		money = money or 0
		cod = cod or 0
		daysLeft = daysLeft or 0

		local key = stableKey(sender, subject, cod, wasReturned, canReply, isGM)

		local mailType
		if isGM then
			mailType = "gm"
		elseif cod > 0 then
			mailType = "cod"
		else
			mailType = self:ClassifySubject(subject)
		end

		-- daysLeft is a live countdown, so expiry is an exact instant and arrival
		-- is only an estimate derived from the standard thirty day lifetime.
		local expiresAt = now + daysLeft * SECONDS_PER_DAY

		local record = {
			index = index,
			key = key,
			packageIcon = packageIcon,
			stationeryIcon = stationeryIcon,
			sender = sender,
			subject = subject,
			money = money,
			cod = cod,
			daysLeft = daysLeft,
			expiresAt = expiresAt,
			arrivedAt = expiresAt - MAIL_LIFETIME_DAYS * SECONDS_PER_DAY,
			itemCount = itemCount or 0,
			wasRead = wasRead,
			wasReturned = wasReturned,
			textCreated = textCreated,
			canReply = canReply,
			isGM = isGM and true or false,
			firstItemQuantity = firstItemQuantity,
			firstItem = firstItem,
			mailType = mailType,
		}

		records[index] = record

		local bucket = byKey[key]
		if not bucket then
			bucket = {}
			byKey[key] = bucket
		end
		bucket[#bucket + 1] = record
	end

	return records
end

function Mail:GetRecords()
	return records
end

function Mail:Get(index)
	return records[index]
end

-- A handle survives the list shifting under it and the mail itself emptying,
-- which an inbox index does not. Anything that wants to come back to a mail
-- later holds one of these.
function Mail:GetHandle(record)
	if not record then return nil end
	return { key = record.key, expiresAt = record.expiresAt }
end

-- Whether a live record is the mail a handle was taken from. expiresAt is
-- recomputed from a float daysLeft on every refresh and jitters by a second or
-- two, so this is the only correct way to compare the two.
function Mail:Matches(record, handle)
	if not record or not handle then return false end
	if record.key ~= handle.key then return false end
	return math.abs(record.expiresAt - handle.expiresAt) <= EXPIRY_TOLERANCE
end

function Mail:Resolve(handle)
	if not handle then return nil end

	local candidates = byKey[handle.key]
	if not candidates then return nil end

	local best, bestDelta
	for _, record in ipairs(candidates) do
		local delta = math.abs(record.expiresAt - handle.expiresAt)
		if delta <= EXPIRY_TOLERANCE and (not bestDelta or delta < bestDelta) then
			best, bestDelta = record, delta
		end
	end

	-- Two mails that share a key and arrived in the same second are genuinely
	-- interchangeable, so returning either of them is correct.
	return best
end

function Mail:GetCounts()
	return shownCount, totalCount
end

function Mail:HasHiddenMail()
	return totalCount > shownCount
end

-- Attachments
-- ---------------------------------------------------------------------------

-- Taking an attachment does not renumber the ones left behind, but a mail that
-- arrives mid run does renumber the mails, so slots are always re-scanned rather
-- than cached.
function Mail:GetTopAttachment(index, skip)
	for slot = ATTACHMENTS_MAX_RECEIVE, 1, -1 do
		local link = GetInboxItemLink(index, slot)
		if link then
			local itemID = tonumber(link:match("item:(%d+)"))
			if not (skip and itemID and skip[itemID]) then
				return slot, link, itemID
			end
		end
	end
end

function Mail:CountAttachments(index)
	local count = 0
	for slot = 1, ATTACHMENTS_MAX_RECEIVE do
		if GetInboxItemLink(index, slot) then
			count = count + 1
		end
	end
	return count
end

-- Whether an incoming stack can merge into a partial stack already in the bags,
-- which is the one case where a full inventory can still accept an item.
function Mail:CanStackWith(index, slot)
	local link = GetInboxItemLink(index, slot)
	if not link then return false end

	local itemID = tonumber(link:match("item:(%d+)"))
	if not itemID then return false end

	local stackSize = select(8, C_Item.GetItemInfo(link))
	if not stackSize or stackSize <= 1 then return false end

	local incoming = select(4, GetInboxItem(index, slot)) or 1
	if C_Item.GetItemCount(itemID) <= 0 then return false end

	local found = false
	Compat:ForEachBag(function(bag)
		for bagSlot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, bagSlot)
			if info and info.itemID == itemID and (info.stackCount or 0) + incoming <= stackSize then
				found = true
				return false
			end
		end
	end)

	return found
end

-- Totals
-- ---------------------------------------------------------------------------

function Mail:GetTotals()
	local money, attachments, expiring = 0, 0, 0
	local soon = time() + SECONDS_PER_DAY

	for _, record in ipairs(records) do
		money = money + record.money
		attachments = attachments + record.itemCount
		if record.expiresAt <= soon then
			expiring = expiring + 1
		end
	end

	return money, attachments, expiring
end

-- Inbox refresh
-- ---------------------------------------------------------------------------

function Mail:CanRefresh()
	return Compat:CanCheckInbox()
end

function Mail:RequestRefresh()
	local canCheck = Compat:CanCheckInbox()
	if not canCheck then return false end
	Compat:CheckInbox()
	return true
end

-- Topping up
-- ---------------------------------------------------------------------------

-- The client will only ever hand over a hundred mails at a time. Past that,
-- GetInboxNumItems reports fewer readable than exist, and the rest arrive only
-- after a CheckInbox that the server rate limits to roughly once a minute.
--
-- So a large mailbox genuinely cannot all be on screen at once, and the list
-- fills in over several passes rather than in one. This drives those passes for
-- as long as the mailbox is open and there is more to fetch.
local topUpSession = 0

function Mail:StopTopUp()
	topUpSession = topUpSession + 1
end

function Mail:IsToppingUp()
	return self.toppingUp == true
end

function Mail:StartTopUp(maxRounds)
	self:StopTopUp()

	local session = topUpSession
	local rounds = 0
	local limit = maxRounds or 8

	local function step()
		if session ~= topUpSession then return end

		if not self:HasHiddenMail() or rounds >= limit then
			self.toppingUp = false
			return
		end

		local canCheck, wait = Compat:CanCheckInbox()
		if canCheck then
			rounds = rounds + 1
			self.toppingUp = true
			Compat:CheckInbox()
			-- Give the server a moment to deliver before judging whether it
			-- helped, otherwise the next round fires against a stale count.
			C_Timer.After(2, step)
		else
			self.toppingUp = true
			C_Timer.After((wait or 60) + 0.5, step)
		end
	end

	step()
end
