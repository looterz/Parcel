local ADDON, ns = ...

-- Names back to something that can draw a tooltip.
--
-- A sold auction is the problem this exists for. That mail carries the money,
-- not the goods, so all the archive ever learns about what was sold is a name
-- read out of "Auction successful: %s". Mail that hands an item back, a win, an
-- expiry, a cancellation, carries the real thing, and so do your bags and your
-- own listings. Anything seen from any of those teaches the name.
--
-- Plain items are kept as an id, which "item:<id>" rebuilds. A link carrying
-- more than the id is kept whole: on Classic a random suffix is part of the
-- name, and "Barbarian War Axe of the Bear" is a different item to a plain one.

local ItemNames = {}
ns.ItemNames = ItemNames

-- Names are small, but a busy auction character sees a great many of them and
-- this is saved data.
local MAX_NAMES = 4000

local counted, countOwner

local function store()
	local global = ns.Addon and ns.Addon.db and ns.Addon.db.global
	if not global then return nil end

	global.itemNames = global.itemNames or {}
	return global.itemNames
end

local function total(known)
	if countOwner == known then return counted end

	counted = 0
	for _ in pairs(known) do counted = counted + 1 end
	countOwner = known

	return counted
end

function ItemNames:Learn(link)
	if type(link) ~= "string" then return false end

	local id = tonumber(link:match("item:(%d+)"))
	if not id then return false end

	local name = link:match("|h%[(.-)%]|h")
	if not name or name == "" then return false end

	local known = store()
	if not known or known[name] then return false end
	if total(known) >= MAX_NAMES then return false end

	known[name] = ns.Archive:LinkMatters(link) and link or id
	counted = counted + 1

	return true
end

function ItemNames:LinkFor(name)
	if type(name) ~= "string" or name == "" then return nil end

	local known = store()
	local value = known and known[name]
	if type(value) == "string" then return value end
	if type(value) == "number" then return "item:" .. value end

	-- Mail that handed the item back is already in the archive.
	local id = ns.Archive:ItemIDForName(name)
	if id then return "item:" .. id end

	-- Finally whatever the client itself has cached, which covers items this
	-- character has never held.
	local _, link = C_Item.GetItemInfo(name)
	return link
end

function ItemNames:Count()
	local known = store()
	return known and total(known) or 0
end

function ItemNames:Forget()
	local global = ns.Addon and ns.Addon.db and ns.Addon.db.global
	if not global then return 0 end

	local removed = self:Count()
	global.itemNames = {}
	counted, countOwner = nil, nil

	return removed
end

-- Learning
-- ---------------------------------------------------------------------------

function ItemNames:LearnFromBags()
	local learned = 0

	ns.Compat:ForEachBag(function(bag)
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local link = C_Container.GetContainerItemLink(bag, slot)
			if link and self:Learn(link) then learned = learned + 1 end
		end
	end)

	return learned
end

-- Your own listings, which is the only place an item you posted and have not
-- sold yet can be seen at all.
function ItemNames:LearnFromOwnedAuctions()
	local learned = 0

	if C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions then
		for index = 1, (C_AuctionHouse.GetNumOwnedAuctions() or 0) do
			local info = C_AuctionHouse.GetOwnedAuctionInfo(index)
			local itemID = info and info.itemKey and info.itemKey.itemID
			local link = info and info.itemLink
				or (itemID and select(2, C_Item.GetItemInfo(itemID)))
			if link and self:Learn(link) then learned = learned + 1 end
		end
		return learned
	end

	if GetNumAuctionItems and GetAuctionItemLink then
		local shown = GetNumAuctionItems("owner")
		for index = 1, (shown or 0) do
			local link = GetAuctionItemLink("owner", index)
			if link and self:Learn(link) then learned = learned + 1 end
		end
	end

	return learned
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MAIL_SHOW")
watcher:RegisterEvent("AUCTION_HOUSE_SHOW")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")

if C_AuctionHouse then
	watcher:RegisterEvent("OWNED_AUCTIONS_UPDATED")
else
	watcher:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
end

watcher:SetScript("OnEvent", function(_, event)
	if event == "OWNED_AUCTIONS_UPDATED" or event == "AUCTION_OWNED_LIST_UPDATE" then
		ItemNames:LearnFromOwnedAuctions()
		return
	end

	ItemNames:LearnFromBags()

	if event == "AUCTION_HOUSE_SHOW" then
		-- Retail answers this asynchronously and replies with the event above.
		if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
			C_AuctionHouse.QueryOwnedAuctions({})
		else
			ItemNames:LearnFromOwnedAuctions()
		end
	end
end)
