local ADDON, ns = ...

local Parcel = LibStub("AceAddon-3.0"):NewAddon(ADDON, "AceConsole-3.0", "AceEvent-3.0")
ns.Addon = Parcel
_G.Parcel = Parcel

local Compat = ns.Compat
local Options = ns.Options
local Mail = ns.Mail
local Queue = ns.Queue

local defaults = {
	profile = {
		modules = {},
		collect = {
			minInterval = 0.30,
			keepFreeSlots = 1,
			verbose = true,
			deleteEmptied = true,
			postmasterNames = "",
			-- Everything on, so a fresh install collects the way it always did.
			filters = {
				ahSold = true, ahWon = true, ahExpired = true,
				ahCancelled = true, ahOutbid = true,
				postmaster = true, player = true,
			},
		},
		send = {
			autoSubject = true,
			autofillRecipient = true,
		},
		archive = {
			retentionDays = 60,
			maxEntries = 5000,
		},
		alerts = {
			expiryDays = 3,
		},
		auction = {
			countVendor = true,
			announceVendor = true,
			period = "month",
		},
		minimap = {
			hide = false,
		},
		ui = {
			theme = "blizzard",
			moneyIcons = true,
			minimapIcon = "envelope",
			hideBlizzardMail = true,
			position = {},
		},
	},
	global = {
		characters = {},
		recipients = {},
		known = {},
		archive = { entries = {} },
		vendor = { entries = {} },
		drafts = {},
	},
}

function Parcel:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("ParcelDB", defaults, true)

	local AceConfig = LibStub("AceConfig-3.0")
	local AceConfigDialog = LibStub("AceConfigDialog-3.0")

	AceConfig:RegisterOptionsTable(ADDON .. "_options", Options:Build(self))
	self.optionsFrame = AceConfigDialog:AddToBlizOptions(ADDON .. "_options", "Parcel")

	AceConfig:RegisterOptionsTable(ADDON .. "_profiles", LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db))
	AceConfigDialog:AddToBlizOptions(ADDON .. "_profiles", "Profiles", "Parcel")

	self.db.RegisterCallback(self, "OnProfileChanged", "ApplyProfile")
	self.db.RegisterCallback(self, "OnProfileCopied", "ApplyProfile")
	self.db.RegisterCallback(self, "OnProfileReset", "ApplyProfile")

	self:ApplyProfile()
end

-- The framework resolves its theme at file scope, before AceDB exists, so the
-- saved choice is pushed across once the profile is available.
function Parcel:ApplyProfile()
	ns.Theme:Apply()
end

function Parcel:OnEnable()
	self:RegisterChatCommand("parcel", "HandleCommand")

	ns.Migrations:Run()
end

function Parcel:ResetWindowPositions()
	ns.Window:ResetPosition()
	self:Print("Window position reset.")
end

function Parcel:GetCollectSetting(info)
	return self.db.profile.collect[info[#info]]
end

function Parcel:SetCollectSetting(info, value)
	self.db.profile.collect[info[#info]] = value
end

function Parcel:GetFilterSetting(info)
	return ns.Filters:IsEnabled(info[#info])
end

function Parcel:SetFilterSetting(info, value)
	ns.Filters:SetEnabled(info[#info], value)
end

function Parcel:GetFeatureSetting(info)
	return ns.Features:IsEnabled(info[#info])
end

function Parcel:SetFeatureSetting(info, value)
	ns.Features:SetEnabled(info[#info], value)
end

function Parcel:GetSendSetting(info)
	return self.db.profile.send[info[#info]]
end

function Parcel:SetSendSetting(info, value)
	self.db.profile.send[info[#info]] = value
end

function Parcel:GetAlertSetting(info)
	return self.db.profile.alerts[info[#info]]
end

function Parcel:SetAlertSetting(info, value)
	self.db.profile.alerts[info[#info]] = value
end

function Parcel:GetArchiveSetting(info)
	return self.db.profile.archive[info[#info]]
end

function Parcel:SetArchiveSetting(info, value)
	self.db.profile.archive[info[#info]] = value
end

function Parcel:GetUISetting(info)
	return self.db.profile.ui[info[#info]]
end

function Parcel:SetUISetting(info, value)
	local key = info[#info]
	self.db.profile.ui[key] = value
	ns.Theme:Apply()
	ns.Events:Trigger("Parcel.UI.Changed", key, value)
end

function Parcel:OpenOptions()
	if self.optionsFrame and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(self.optionsFrame.name)
	end
end

function Parcel:PrintStatus()
	self:Print(("%s, interface %d, profile %s."):format(
		Options:GetFlavorLabel(), Compat.interface, self.db:GetCurrentProfile()))

	if not MailFrame or not MailFrame:IsShown() then
		self:Print("Open a mailbox to see what is in it.")
		return
	end

	Mail:Refresh()
	local shown, total = Mail:GetCounts()
	local money, attachments, expiring = Mail:GetTotals()

	if total > shown then
		self:Print(("%d mails, %d shown. %d attachments and %s waiting."):format(
			total, shown, attachments, ns.Money(money)))
	else
		self:Print(("%d mails, %d attachments and %s waiting."):format(
			shown, attachments, ns.Money(money)))
	end

	if expiring > 0 then
		self:Print(("%d expire within a day."):format(expiring))
	end
end

-- Parcel learns your characters as you log into them, the same way Postal does,
-- because no client API lists the rest of your account. This says what it knows
-- so the answer is checkable rather than guessed at.
function Parcel:PrintKnownNames()
	local characters = ns.Roster:GetCharacters()
	local names = {}
	for name in pairs(characters) do
		names[#names + 1] = name
	end
	table.sort(names)

	if #names == 0 then
		self:Print("No characters known yet on this realm and faction.")
	else
		self:Print("Characters seen: " .. table.concat(names, ", "))
	end

	local known = {}
	for name in pairs(ns.Roster:GetKnown()) do
		known[#known + 1] = name
	end
	table.sort(known)

	if #known > 0 then
		self:Print("Mailed before: " .. table.concat(known, ", "))
	end

	self:Print("Log in to a character once and it starts suggesting itself, "
		.. "or name one now with /parcel alt add <name>.")
end

BINDING_HEADER_PARCEL = "Parcel"
BINDING_NAME_PARCEL_TOGGLE = "Open or close Parcel"
BINDING_NAME_PARCEL_COLLECT = "Collect all mail"
BINDING_NAME_PARCEL_HISTORY = "Open mail history"

function ParcelBinding_Toggle()
	ns.Window:Toggle()
end

function ParcelBinding_Collect()
	if not ns.Collect:IsMailOpen() then
		ns.Addon:Print("You are not at a mailbox.")
		return
	end
	ns.Collect:Start(ns.Filters:Predicate())
end

function ParcelBinding_History()
	ns.Window:Show("history")
end

function Parcel:PrintDiagnostics()
	local stats = ns.Archive.stats

	self:Print(("Parcel %s on %s, saved data version %s."):format(
		ns.Compat:GetAddOnMetadata("Version") or "unknown", ns.Options:GetFlavorLabel(),
		tostring(ns.Migrations:Version())))
	self:Print(("Mail session open: %s.  Queue running: %s."):format(
		tostring(ns.Collect:IsMailOpen()), tostring(ns.Queue:IsRunning())))
	self:Print(("Captures %d, records seen %d, created %d, updated %d, incomplete %d, no store %d."):format(
		stats.captures, stats.seen, stats.created, stats.updated, stats.incomplete, stats.noStore))
	self:Print(("History holds %d entries for %s."):format(
		ns.Archive:Count(), ns.Archive:CurrentCharacter()))

	ns.Mail:Refresh()
	local records = ns.Mail:GetRecords()
	self:Print(("Inbox right now: %d records."):format(#records))

	local matched, missing = 0, 0
	for index, record in ipairs(records) do
		local entry = ns.Archive:EntryFor(record)
		if entry then
			matched = matched + 1
		else
			missing = missing + 1
			if missing <= 5 then
				self:Print(("  no entry: [%s] from %s, %.4f days left, complete=%s"):format(
					tostring(record.subject), tostring(record.sender),
					record.daysLeft or -1, tostring(ns.Archive:IsComplete(record))))
			end
		end
	end

	self:Print(("Of those, %d already have a history entry and %d do not."):format(matched, missing))

	for index, record in ipairs(records) do
		if index <= 6 then
			self:Print(("  live: [%s] %s  type=%s  money=%d"):format(
				tostring(record.sender), tostring(record.subject),
				tostring(record.mailType), record.money or 0))
		end
	end

	local entries = ns.Archive:GetEntries()
	local first = math.max(1, #entries - 7)
	self:Print(("Last %d history entries:"):format(math.min(8, #entries)))
	for index = first, #entries do
		local entry = entries[index]
		self:Print(("  [%s] %s  dir=%s type=%s disp=%s money=%d char=%s"):format(
			tostring(entry.who), tostring(entry.subj), tostring(entry.dir),
			tostring(entry.mtype), tostring(entry.disp), entry.money or 0,
			tostring(entry.char)))
	end

	local committed, settled, pending = ns.Ledger:Stats()
	self:Print(("Ledger: %d committed, %d settled, %d pending."):format(committed, settled, pending))

	local counts, waiting = ns.Archive:DispositionCounts()
	local parts = {}
	for disposition, count in pairs(counts) do
		parts[#parts + 1] = ("%s %d"):format(disposition, count)
	end
	table.sort(parts)
	self:Print("History by state: " .. table.concat(parts, ", "))
	self:Print(("Still waiting: %d received mails."):format(waiting))

	local vendorTotal = ns.Auction:VendorTotals(nil, ns.Archive:CurrentCharacter())
	self:Print(("Vendor sales: %d recorded, worth %s, counted in profit: %s."):format(
		ns.Vendor:Count(), ns.Money(vendorTotal), tostring(ns.Auction:CountsVendor())))
	self:Print(("Item names learned: %d."):format(ns.ItemNames:Count()))
	self:Print(("Settles: %d by transaction, %d by handle, %d missed."):format(
		stats.settledByLedger, stats.settledByHandle, stats.settleMissed))
end

function Parcel:PrintArchiveSize()
	local entries = ns.Archive:Count()
	local bytes = ns.Archive:EstimateBytes()
	local limit = self.db.profile.archive.maxEntries

	self:Print(("History holds %d of a possible %d entries, roughly %.0f KB."):format(
		entries, limit, bytes / 1024))

	if entries >= limit * 0.9 then
		self:Print("Close to the ceiling. The oldest entries go first when it is reached.")
	end
end

-- Character names keep their capitalisation, so only the verb is lowercased.
function Parcel:HandleAltCommand(rest)
	local verb, name = rest:match("^(%S*)%s*(.*)$")
	verb = (verb or ""):lower()
	name = strtrim(name or "")

	if verb == "add" and name ~= "" then
		if ns.Roster:AddAlt(name) then
			self:Print(("Added %s. It will suggest itself when you type."):format(name))
		else
			self:Print(("%s is already known."):format(name))
		end
	elseif (verb == "remove" or verb == "delete") and name ~= "" then
		if ns.Roster:RemoveAlt(name) then
			self:Print(("Removed %s."):format(name))
		else
			self:Print(("%s was not in the list."):format(name))
		end
	else
		self:Print("Usage: /parcel alt add <name>, or /parcel alt remove <name>.")
	end
end

function Parcel:HandleCommand(input)
	local word, rest = strtrim(input or ""):match("^(%S*)%s*(.*)$")
	local command = (word or ""):lower()
	rest = rest or ""

	if command == "" or command == "config" or command == "options" then
		self:OpenOptions()
	elseif command == "status" then
		self:PrintStatus()
	elseif command == "collect" then
		ns.Collect:Start(ns.Filters:Predicate())
	elseif command == "stop" then
		ns.Collect:Stop()
	elseif command == "alts" or command == "names" then
		self:PrintKnownNames()
	elseif command == "alt" then
		self:HandleAltCommand(rest)
	elseif command == "open" or command == "show" then
		ns.Window:Show()
	elseif command == "minimap" then
		local wanted = not ns.Features:IsEnabled("broker")
		ns.Features:SetEnabled("broker", wanted)
		self:Print(wanted and "Minimap button shown." or "Minimap button hidden.")
	elseif command == "diag" then
		self:PrintDiagnostics()
	elseif command == "size" then
		self:PrintArchiveSize()
	elseif command == "expiring" then
		ns.Alerts:Report(true)
	elseif command == "history" or command == "outbox" then
		-- Works away from a mailbox, which is the point of keeping an archive.
		ns.Window:Show("history")
	else
		-- Built from the same table the Help tab reads, so the two cannot drift.
		local names = {}
		for _, entry in ipairs(ns.Options.commands) do
			if entry[1] ~= "" then names[#names + 1] = entry[1] end
		end
		self:Print("Unknown command. Try: " .. table.concat(names, ", ") .. ".")
	end
end
