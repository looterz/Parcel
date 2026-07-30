local ADDON, ns = ...

-- Gold taken at a vendor.
--
-- Buying under the vendor price and selling the difference is a real auction
-- strategy, and without this half of it the auction figures only ever see the
-- money going out. A run of those purchases reads as a straight loss.
--
-- Only money coming in is recorded. Money going out at a merchant is a repair
-- bill as often as it is a purchase, and there is no way to tell them apart
-- worth trusting, so nothing here tries.

local Vendor = {}
ns.Vendor = Vendor

local Events = ns.Events

local merchantOpen = false
local lastMoney = 0

-- The item the player just clicked, held only until the money arrives.
local pending

local function store()
	local global = ns.Addon and ns.Addon.db and ns.Addon.db.global
	if not global then return nil end

	global.vendor = global.vendor or { entries = {} }
	global.vendor.entries = global.vendor.entries or {}

	return global.vendor
end

local function characterName()
	return ns.Archive:CurrentCharacter()
end

function Vendor:Entries()
	local vendor = store()
	return vendor and vendor.entries or {}
end

function Vendor:Count()
	return #self:Entries()
end

-- The auction purchase this sale closes out, if there is one. The oldest
-- unclosed buy of the same item wins, so a run of purchases is settled in the
-- order they were made.
function Vendor:MatchPurchase(itemID)
	if not itemID then return nil, nil end

	local oldest, cost

	for _, entry in ipairs(ns.Archive:GetEntries()) do
		if entry.mtype == "ahWon" and entry.dir == "in" and not entry.vendoredAt
			and entry.char == characterName() then
			for _, item in ipairs(entry.items or {}) do
				if item.id == itemID then
					local at = entry.at or entry.seen or 0
					if not oldest or at < (oldest.at or oldest.seen or 0) then
						local paid = (entry.invoice and entry.invoice.bid) or 0
						local units = math.max(1, item.n or 1)
						oldest, cost = entry, paid / units
					end
					break
				end
			end
		end
	end

	return oldest, cost
end

function Vendor:Record(money, item)
	if not money or money <= 0 then return nil end

	local vendor = store()
	if not vendor then return nil end

	local entry = {
		at = time(),
		char = characterName(),
		money = money,
		id = item and item.id or nil,
		name = item and item.name or nil,
		n = item and item.count or nil,
	}

	local purchase, unitCost = self:MatchPurchase(entry.id)
	if purchase then
		-- Marked so the same purchase cannot be closed out twice.
		purchase.vendoredAt = entry.at
		entry.cost = math.floor(unitCost * math.max(1, entry.n or 1) + 0.5)
		entry.bought = purchase.id
	end

	vendor.entries[#vendor.entries + 1] = entry
	self:Prune()
	self:Tally(entry)
	Events:Trigger("Parcel.Vendor.Changed")

	return entry
end

-- Telling you about it
-- ---------------------------------------------------------------------------

local runMoney, runCost, runSales, runMatched = 0, 0, 0, 0

local function announces()
	local profile = ns.Addon and ns.Addon.db and ns.Addon.db.profile
	local auction = profile and profile.auction
	return not auction or auction.announceVendor ~= false
end

function Vendor:Tally(entry)
	runSales = runSales + 1
	runMoney = runMoney + entry.money
	if entry.cost then
		runCost = runCost + entry.cost
		runMatched = runMatched + 1
	end
end

-- One line when you leave, not a line per item. What a vendor run is worth is
-- the gold it took less what those items cost at auction, and that is a loss
-- as readily as a profit.
function Vendor:ReportRun()
	if runSales == 0 then return end

	if announces() then
		local profit = runMoney - runCost
		ns.Addon:Print(("Vendor run: %s%s."):format(
			profit >= 0 and "+" or "", ns.Money(profit)))
	end

	runMoney, runCost, runSales, runMatched = 0, 0, 0, 0
end

function Vendor:RunTotals()
	return runSales, runMoney, runCost, runMatched
end

-- A buyback puts the item back and takes the money with it, so the sale it
-- undoes has to come off again.
function Vendor:Unrecord(money)
	local vendor = store()
	if not vendor or money <= 0 then return false end

	for position = #vendor.entries, 1, -1 do
		local entry = vendor.entries[position]
		if entry.money == money and entry.char == characterName() then
			if entry.bought then
				for _, archived in ipairs(ns.Archive:GetEntries()) do
					if archived.id == entry.bought then archived.vendoredAt = nil end
				end
			end

			runSales = math.max(0, runSales - 1)
			runMoney = math.max(0, runMoney - entry.money)
			if entry.cost then
				runCost = math.max(0, runCost - entry.cost)
				runMatched = math.max(0, runMatched - 1)
			end

			table.remove(vendor.entries, position)
			Events:Trigger("Parcel.Vendor.Changed")
			return true
		end
	end

	return false
end

-- Kept to the same limits as the mail history, since it is the same kind of
-- data and the same figures are drawn from it.
function Vendor:Prune()
	local vendor = store()
	if not vendor then return 0 end

	local profile = ns.Addon.db.profile.archive or {}
	local days = profile.retentionDays or 60
	local maximum = profile.maxEntries or 5000
	local cutoff = days > 0 and (time() - days * 86400) or nil
	local removed = 0

	if cutoff then
		for position = #vendor.entries, 1, -1 do
			if (vendor.entries[position].at or 0) < cutoff then
				table.remove(vendor.entries, position)
				removed = removed + 1
			end
		end
	end

	while #vendor.entries > maximum do
		table.remove(vendor.entries, 1)
		removed = removed + 1
	end

	return removed
end

function Vendor:Forget()
	local vendor = store()
	if not vendor then return 0 end

	local removed = #vendor.entries
	vendor.entries = {}
	Events:Trigger("Parcel.Vendor.Changed")

	return removed
end

-- Watching a sale happen
-- ---------------------------------------------------------------------------

-- What is in a bag slot, read before the click empties it.
local function itemAt(bag, slot)
	local link = C_Container.GetContainerItemLink(bag, slot)
	if not link then return nil end

	local info = C_Container.GetContainerItemInfo(bag, slot)
	local id = tonumber(link:match("item:(%d+)"))

	if ns.ItemNames then ns.ItemNames:Learn(link) end

	return {
		id = id,
		name = link:match("|h%[(.-)%]|h"),
		count = (info and (info.stackCount or info.itemCount)) or 1,
	}
end

function Vendor:IsMerchantOpen()
	return merchantOpen
end

function Vendor:NoteClick(bag, slot)
	if not merchantOpen then return end
	pending = itemAt(bag, slot)
end

-- The money is the truth. The click only says what it was for, and a click that
-- sells nothing never reaches here.
function Vendor:Settle()
	if not merchantOpen then return end

	local now = GetMoney()
	local delta = now - lastMoney
	lastMoney = now

	if delta > 0 then
		self:Record(delta, pending)
		pending = nil
	elseif delta < 0 then
		self:Unrecord(-delta)
	end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MERCHANT_SHOW")
watcher:RegisterEvent("MERCHANT_CLOSED")
watcher:RegisterEvent("PLAYER_MONEY")

watcher:SetScript("OnEvent", function(_, event)
	if event == "MERCHANT_SHOW" then
		merchantOpen = true
		lastMoney = GetMoney()
		pending = nil
		runMoney, runCost, runSales, runMatched = 0, 0, 0, 0
	elseif event == "MERCHANT_CLOSED" then
		merchantOpen = false
		pending = nil
		Vendor:ReportRun()
	elseif event == "PLAYER_MONEY" then
		Vendor:Settle()
	end
end)

-- Selling is a container use while a merchant is open. Hooked rather than
-- replaced, so nothing here can stop the click going through.
if C_Container and C_Container.UseContainerItem then
	hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
		Vendor:NoteClick(bag, slot)
	end)
elseif _G.UseContainerItem then
	hooksecurefunc("UseContainerItem", function(bag, slot)
		Vendor:NoteClick(bag, slot)
	end)
end
