local ADDON, ns = ...

-- What is about to run out, on every character, said once at login.
--
-- This is the one thing Parcel can do that Postal and zMail cannot, and it
-- comes free: the archive already records every mail Parcel has seen, which
-- character it was sitting on and when it expires. Nothing new is captured for
-- it. Blizzard's own warning covers the character you are standing on and
-- nothing else, which is exactly the case where mail is lost.

local Alerts = {}
ns.Alerts = Alerts

local Archive = ns.Archive

local DAY = 86400

local function settings()
	local addon = ns.Addon
	local profile = addon and addon.db and addon.db.profile
	return profile and profile.alerts
end

function Alerts:Threshold()
	local store = settings()
	return (store and store.expiryDays) or 3
end

-- Grouped by character, soonest first. Anything Parcel last saw still sitting
-- in an inbox counts; anything it watched being collected, returned or deleted
-- does not.
function Alerts:Expiring(withinDays)
	local cutoff = time() + (withinDays or self:Threshold()) * DAY
	local byCharacter, order = {}, {}

	for _, entry in ipairs(Archive:GetEntries()) do
		local expires = entry.expires
		if entry.dir == "in" and entry.disp == "inbox" and expires and expires <= cutoff then
			local who = entry.char or UNKNOWN
			local bucket = byCharacter[who]
			if not bucket then
				bucket = { character = who, count = 0, soonest = expires }
				byCharacter[who] = bucket
				order[#order + 1] = bucket
			end

			bucket.count = bucket.count + 1
			if expires < bucket.soonest then bucket.soonest = expires end
		end
	end

	table.sort(order, function(a, b) return a.soonest < b.soonest end)
	return order
end

local function describe(seconds)
	if seconds <= 0 then return "already past" end
	if seconds < DAY then
		return ("%d hours"):format(math.max(1, math.floor(seconds / 3600)))
	end
	return ("%d days"):format(math.floor(seconds / DAY))
end

function Alerts:Report(force)
	if not force and not ns.Features:IsEnabled("expiryWarning") then return end

	local expiring = self:Expiring()
	if #expiring == 0 then
		if force then ns.Addon:Print("Nothing Parcel has seen is close to expiring.") end
		return
	end

	local now = time()
	local current = Archive:CurrentCharacter()

	for _, bucket in ipairs(expiring) do
		local where = bucket.character == current and "here" or bucket.character
		ns.Addon:Print(("%d mail on %s expires in %s."):format(
			bucket.count, where, describe(bucket.soonest - now)))
	end

	-- Said plainly rather than implied. The archive is a record of what Parcel
	-- watched, so a mailbox it has never been shown is invisible to this, and a
	-- player should not read silence as an all clear.
	ns.Addon:Print("Based on what Parcel has seen. Visit a mailbox on a character to keep it current.")
end

-- Login and every reload. The delay is so this lands after the chat frame has
-- settled, where it can actually be read, rather than in the wall of addon
-- messages that arrives with the world.
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	C_Timer.After(8, function() Alerts:Report() end)
end)
