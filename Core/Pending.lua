local ADDON, ns = ...

-- Auctions that have sold but whose gold has not arrived yet.
--
-- The auction house knows before your mailbox does. An auction you have sold
-- stays in your own listings, marked sold, until the mail carrying the money
-- turns up an hour later. Both flavors say so plainly and both call it 1:
-- Classic through saleStatus on GetAuctionItemInfo("owner"), Retail through
-- status on C_AuctionHouse.GetOwnedAuctionInfo against Enum.AuctionStatus.Sold.
--
-- Parcel can only be told this while you are standing at an auction house, so
-- what it holds is the last thing it was told rather than live truth. Every
-- number here is labelled as expected for that reason.

local Pending = {}
ns.Pending = Pending

local Events = ns.Events

local SOLD = 1

-- The auction house takes a cut of the sale, so what lands in the mailbox is
-- less than the hammer price. Five percent on every flavor Parcel supports.
Pending.CUT = 0.05

-- Mail from a sale arrives about an hour later. Anything still waiting after
-- this was either never really sold or its mail was missed, and holding it
-- forever would only ever inflate the figure.
local STALE_AFTER = 3 * 86400

local function store()
	local global = ns.Addon and ns.Addon.db and ns.Addon.db.global
	if not global then return nil end

	global.pending = global.pending or { entries = {} }
	global.pending.entries = global.pending.entries or {}

	return global.pending
end

local function characterName()
	return ns.Archive:CurrentCharacter()
end

function Pending:Entries(character)
	local pending = store()
	if not pending then return {} end

	character = character or characterName()

	local out = {}
	for _, entry in ipairs(pending.entries) do
		if entry.char == character then out[#out + 1] = entry end
	end

	return out
end

-- What the mail should be worth: the hammer price less the house cut. The
-- deposit comes back too, but the listing never says what it was.
function Pending:ValueOf(entry)
	local price = entry and entry.price or 0
	return math.floor(price * (1 - self.CUT) + 0.5)
end

function Pending:Totals(character)
	local count, money = 0, 0

	for _, entry in ipairs(self:Entries(character)) do
		count = count + 1
		money = money + self:ValueOf(entry)
	end

	return count, money
end

-- Observing
-- ---------------------------------------------------------------------------

local function alreadyKnown(pending, id, character)
	if not id then return false end

	for _, entry in ipairs(pending.entries) do
		if entry.id == id and entry.char == character then return true end
	end

	return false
end

function Pending:Record(id, name, count, price)
	local pending = store()
	if not pending then return false end

	local character = characterName()
	-- The same listing is seen again on every refresh while you stand there.
	if alreadyKnown(pending, id, character) then return false end

	pending.entries[#pending.entries + 1] = {
		id = id,
		char = character,
		name = name,
		n = count or 1,
		price = price or 0,
		at = time(),
	}

	Events:Trigger("Parcel.Pending.Changed")
	return true
end

function Pending:ReadOwnedAuctions()
	local found = 0

	if C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions then
		local sold = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or SOLD

		for index = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
			local info = C_AuctionHouse.GetOwnedAuctionInfo(index)
			if info and info.status == sold then
				local price = info.buyoutAmount or info.bidAmount or 0
				local itemName = info.itemKey and ns.ItemNames
					and ns.ItemNames:LinkFor(info.itemName or "") or info.itemName
				if self:Record(info.auctionID, info.itemName or itemName, info.quantity, price) then
					found = found + 1
				end
			end
		end

		return found
	end

	if not (GetNumAuctionItems and GetAuctionItemInfo) then return 0 end

	local shown = GetNumAuctionItems("owner")
	for index = 1, (shown or 0) do
		-- The owner list drops duration from the middle of the return, so these
		-- are read positionally against Blizzard's own owner call rather than
		-- the longer browse one.
		local name, _, count, _, _, _, _, _, _, buyout, bid, _, _, _, _, saleStatus =
			GetAuctionItemInfo("owner", index)

		if saleStatus == SOLD then
			local price = (bid and bid > 0) and bid or (buyout or 0)
			-- No auction id on Classic, so the listing is identified by what it
			-- is and what it went for.
			local id = ("%s|%d|%d"):format(tostring(name), count or 1, price)
			if self:Record(id, name, count, price) then found = found + 1 end
		end
	end

	return found
end

-- Clearing
-- ---------------------------------------------------------------------------

-- The mail turned up. Oldest first, because a run of the same item sells in
-- the order it was listed and nothing else distinguishes them.
function Pending:Settle(name, character)
	local pending = store()
	if not pending then return false end

	character = character or characterName()

	local oldest, position
	for index, entry in ipairs(pending.entries) do
		if entry.char == character and (name == nil or entry.name == name) then
			if not oldest or (entry.at or 0) < (oldest.at or 0) then
				oldest, position = entry, index
			end
		end
	end

	if not position then return false end

	table.remove(pending.entries, position)
	Events:Trigger("Parcel.Pending.Changed")

	return true
end

function Pending:Prune()
	local pending = store()
	if not pending then return 0 end

	local cutoff = time() - STALE_AFTER
	local removed = 0

	for index = #pending.entries, 1, -1 do
		if (pending.entries[index].at or 0) < cutoff then
			table.remove(pending.entries, index)
			removed = removed + 1
		end
	end

	if removed > 0 then Events:Trigger("Parcel.Pending.Changed") end
	return removed
end

function Pending:Forget()
	local pending = store()
	if not pending then return 0 end

	local removed = #pending.entries
	pending.entries = {}
	Events:Trigger("Parcel.Pending.Changed")

	return removed
end

-- Wiring
-- ---------------------------------------------------------------------------

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("AUCTION_HOUSE_SHOW")

if C_AuctionHouse then
	watcher:RegisterEvent("OWNED_AUCTIONS_UPDATED")
else
	watcher:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
end

watcher:SetScript("OnEvent", function(_, event)
	if event == "AUCTION_HOUSE_SHOW" then
		Pending:Prune()
		if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
			C_AuctionHouse.QueryOwnedAuctions({})
			return
		end
	end

	Pending:ReadOwnedAuctions()
end)

-- A sale arriving is the thing this was waiting for.
Events:Register("Parcel.Archive.Recorded", function(entry)
	if not entry or entry.mtype ~= "ahSold" then return end
	Pending:Settle(ns.Auction:ItemNameOf(entry), entry.char)
end)
