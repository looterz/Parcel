local ADDON, ns = ...

-- Trades and guild charters, held off while you are at the mailbox.
--
-- Both open a frame over whatever you were doing and take the next click with
-- them, which during a collect run is the click that was about to take an item.

local Focus = {}
ns.Focus = Focus

local Events = ns.Events

-- Nil means not engaged. It also holds what the setting was before Parcel
-- touched it, which is the whole reason this is not a boolean.
local previousBlockTrades
local petitionSuppressed = false

local function enabled()
	return ns.Features:IsEnabled("focus")
end

function Focus:IsEngaged()
	return previousBlockTrades ~= nil
end

function Focus:Engage()
	if self:IsEngaged() then return end
	if not GetCVar or not SetCVar then return end

	-- Remembered rather than assumed to have been off. zMail clears this
	-- unconditionally when the mailbox closes, so anyone who deliberately runs
	-- with trades blocked finds it silently switched off after visiting a
	-- mailbox. Restoring what was there costs nothing and cannot do that.
	previousBlockTrades = GetCVar("BlockTrades")
	if previousBlockTrades == "0" then
		SetCVar("BlockTrades", "1")
	end

	if PetitionFrame then
		PetitionFrame:UnregisterEvent("PETITION_SHOW")
		petitionSuppressed = true
	end
end

function Focus:Release()
	if previousBlockTrades ~= nil then
		SetCVar("BlockTrades", previousBlockTrades)
		previousBlockTrades = nil
	end

	if petitionSuppressed then
		if ClosePetition then ClosePetition() end
		if PetitionFrame then PetitionFrame:RegisterEvent("PETITION_SHOW") end
		petitionSuppressed = false
	end
end

Events:Register("Parcel.Mail.Opened", function()
	if enabled() then Focus:Engage() end
end)

-- Released whatever the setting now says. Turning the option off while the
-- mailbox is open must not strand the block on, and Collect fires this on
-- PLAYER_LEAVING_WORLD too, so a reload or a logout cannot either.
Events:Register("Parcel.Mail.Closed", function()
	Focus:Release()
end)

-- Switching it off mid visit lets go immediately rather than at the next
-- mailbox, which is what someone reaching for the setting is asking for.
Events:Register("Parcel.Features.Changed", function(key, value)
	if key ~= "focus" then return end
	if value then
		if ns.Collect:IsMailOpen() then Focus:Engage() end
	else
		Focus:Release()
	end
end)
