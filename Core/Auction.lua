local ADDON, ns = ...

-- Auction house figures, derived from the archive.
--
-- Nothing new is captured for this. Auction mail is just mail, it is already
-- recorded with its invoice, and the invoice carries the numbers the auction
-- house itself never shows you in one place: what you grossed, what the deposit
-- returned, what the house took, and what actually landed in your bags.

local Auction = {}
ns.Auction = Auction

local Archive = ns.Archive

local DAY = 86400

Auction.periods = {
	{ key = "today", label = "Today", seconds = DAY },
	{ key = "week", label = "Week", seconds = 7 * DAY },
	{ key = "month", label = "Month", seconds = 30 * DAY },
	{ key = "year", label = "Year", seconds = 365 * DAY },
	{ key = "all", label = "All", seconds = nil },
}

-- The subject classification already did the hard part, and it is localised, so
-- there is no need to match sender names like "Alliance Auction House" that
-- differ per faction and language.
local SOLD = "ahSold"
local WON = "ahWon"
local EXPIRED = "ahExpired"
local CANCELLED = "ahCancelled"
local OUTBID = "ahOutbid"

function Auction:IsAuctionEntry(entry)
	local kind = entry.mtype
	return kind == SOLD or kind == WON or kind == EXPIRED or kind == CANCELLED or kind == OUTBID
end

local function timestamp(entry)
	return entry.at or entry.seen or 0
end

-- A sale nets the winning bid plus your deposit back, less the cut. That is the
-- number worth knowing and the one the auction house never puts on screen.
function Auction:NetOf(entry)
	local invoice = entry.invoice
	if not invoice then
		-- No invoice captured, so the attached gold is the best available answer.
		return entry.money or 0
	end
	return (invoice.bid or 0) + (invoice.deposit or 0) - (invoice.cut or 0)
end

function Auction:UnitsOf(entry)
	local invoice = entry.invoice
	return (invoice and invoice.count) or 1
end

function Auction:Entries(seconds, query, character)
	local cutoff = seconds and (time() - seconds) or nil
	local matched = Archive:Search(query or "", "in", character)
	local out = {}

	for _, entry in ipairs(matched) do
		if self:IsAuctionEntry(entry) and (not cutoff or timestamp(entry) >= cutoff) then
			out[#out + 1] = entry
		end
	end

	return out
end

function Auction:Summary(seconds, character)
	local summary = {
		sold = 0, units = 0, gross = 0, deposits = 0, fees = 0, net = 0,
		bought = 0, spent = 0,
		expired = 0, cancelled = 0, outbid = 0, refunded = 0,
	}

	for _, entry in ipairs(self:Entries(seconds, nil, character)) do
		local invoice = entry.invoice
		local kind = entry.mtype

		if kind == SOLD then
			summary.sold = summary.sold + 1
			summary.units = summary.units + self:UnitsOf(entry)
			summary.gross = summary.gross + ((invoice and invoice.bid) or entry.money or 0)
			summary.deposits = summary.deposits + ((invoice and invoice.deposit) or 0)
			summary.fees = summary.fees + ((invoice and invoice.cut) or 0)
			summary.net = summary.net + self:NetOf(entry)
		elseif kind == WON then
			summary.bought = summary.bought + 1
			summary.spent = summary.spent + ((invoice and invoice.bid) or 0)
		elseif kind == EXPIRED then
			summary.expired = summary.expired + 1
		elseif kind == CANCELLED then
			summary.cancelled = summary.cancelled + 1
		elseif kind == OUTBID then
			summary.outbid = summary.outbid + 1
			summary.refunded = summary.refunded + (entry.money or 0)
		end
	end

	return summary
end

-- Ranked by what they actually earned, not by how many moved, because a stack
-- of cloth and a rare recipe are not comparable by unit count.
function Auction:TopItems(seconds, limit, character)
	local byName = {}
	local order = {}

	for _, entry in ipairs(self:Entries(seconds, nil, character)) do
		if entry.mtype == SOLD then
			local name = (entry.invoice and entry.invoice.item)
				or (entry.items and entry.items[1] and entry.items[1].name)
				or entry.subj
				or UNKNOWN

			local bucket = byName[name]
			if not bucket then
				bucket = { name = name, sales = 0, units = 0, net = 0 }
				byName[name] = bucket
				order[#order + 1] = bucket
			end

			bucket.sales = bucket.sales + 1
			bucket.units = bucket.units + self:UnitsOf(entry)
			bucket.net = bucket.net + self:NetOf(entry)
		end
	end

	table.sort(order, function(a, b) return a.net > b.net end)

	if limit and #order > limit then
		for index = #order, limit + 1, -1 do
			order[index] = nil
		end
	end

	return order
end

-- Money, abbreviated to fit a tile
-- ---------------------------------------------------------------------------

-- The tiles are too narrow for the full coin string once a figure runs to
-- thousands of gold, so the abbreviation keeps its own icons rather than
-- deferring to ns.Money.
local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

-- Exported so the tests can compose expectations from the same strings rather
-- than restating them and drifting.
Auction.coinIcons = { gold = GOLD, silver = SILVER, copper = COPPER }

-- The stat tiles are narrow, so large figures are abbreviated. Small ones are
-- not: an earlier version divided by 10000 and floored, so a real sale of
-- 9s 35c displayed as "0g" and looked like the addon had lost it.
--
-- Nothing here ever rounds a value down to nothing. Below a gold it switches to
-- silver and copper rather than abbreviating.
function Auction:FormatShort(copper)
	copper = math.floor(tonumber(copper) or 0)

	local sign = ""
	if copper < 0 then
		sign = "-"
		copper = -copper
	end

	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local units = copper % 100

	if gold >= 1000000000 then
		return ("%s%.1fb%s"):format(sign, gold / 1000000000, GOLD)
	elseif gold >= 1000000 then
		return ("%s%.1fm%s"):format(sign, gold / 1000000, GOLD)
	elseif gold >= 10000 then
		return ("%s%.0fk%s"):format(sign, gold / 1000, GOLD)
	elseif gold >= 1000 then
		return ("%s%.1fk%s"):format(sign, gold / 1000, GOLD)
	elseif gold > 0 then
		-- Silver alongside, so 1g 50s does not read as a flat 1g.
		if silver > 0 then
			return ("%s%d%s %d%s"):format(sign, gold, GOLD, silver, SILVER)
		end
		return ("%s%d%s"):format(sign, gold, GOLD)
	elseif silver > 0 then
		if units > 0 then
			return ("%s%d%s %d%s"):format(sign, silver, SILVER, units, COPPER)
		end
		return ("%s%d%s"):format(sign, silver, SILVER)
	end

	return ("%s%d%s"):format(sign, units, COPPER)
end

-- Average net per day over the window, which is the number that tells you
-- whether a slow week was actually slow.
function Auction:DailyAverage(seconds, character)
	if not seconds then return 0 end
	local summary = self:Summary(seconds, character)
	local days = math.max(1, seconds / DAY)
	return math.floor(summary.net / days)
end
