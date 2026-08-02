local ADDON, ns = ...

local Options = {}
ns.Options = Options

local Compat = ns.Compat

local FLAVOR_LABELS = {
	retail = "Retail",
	vanilla = "Classic Era",
	tbc = "Burning Crusade Classic",
	wrath = "Wrath Classic",
	cata = "Cataclysm Classic",
	mists = "Mists Classic",
}

function Options:GetFlavorLabel()
	return FLAVOR_LABELS[Compat.flavor] or Compat.flavor
end

-- Help
-- ---------------------------------------------------------------------------

-- One table so the help cannot quietly drift from what the slash handler in
-- Parcel.lua actually accepts. Adding a command means adding it here too.
Options.commands = {
	{ "", "these options" },
	{ "open", "open Parcel, wherever you are" },
	{ "collect", "collect everything your filters allow" },
	{ "stop", "stop a run in progress" },
	{ "history", "open the history tab" },
	{ "expiring", "what is about to run out, on every character" },
	{ "alts", "which characters Parcel knows about" },
	{ "alt add <name>", "teach it a character it has not seen" },
	{ "alt remove <name>", "forget one" },
	{ "minimap", "show or hide the minimap button" },
	{ "diag", "report why history may not be recording" },
	{ "size", "how much room the history is using" },
	{ "status", "client, profile, and what is in the mailbox" },
}

local function heading(text)
	return "|cffffd200" .. text .. "|r"
end

local function key(text)
	return "|cff00ccff" .. text .. "|r"
end

local function commandLines()
	local lines = { heading("Chat commands") }

	for _, entry in ipairs(Options.commands) do
		local command, description = entry[1], entry[2]
		local label = command == "" and "/parcel" or ("/parcel " .. command)
		lines[#lines + 1] = key(label) .. "  " .. description
	end

	lines[#lines + 1] = ""
	return table.concat(lines, "\n")
end

local OVERVIEW = table.concat({
	heading("What is where"),
	key("Inbox") .. "  everything waiting, with search, sorting and one button to take the lot",
	key("Send") .. "  write mail, with autocomplete, attachments, gold or cash on delivery, and drafts",
	key("History") .. "  every mail Parcel has ever seen, searchable, long after it left your mailbox",
	key("Auction") .. "  what you earned, what sold, and what the house took, from auction mail",
	"",
}, "\n")

local OPENING = table.concat({
	heading("Opening Parcel"),
	"Walk up to a mailbox and it opens on its own. Walk away and it closes, the same as the stock window.",
	"",
	"Away from a mailbox, open it with " .. key("/parcel open") .. ", the minimap button, or a keybinding.",
	"Key Bindings has a " .. key("Parcel") .. " section under AddOns with three of them.",
	"",
	"The game only hands over your inbox while you are standing at a mailbox, so away from one the Inbox tab "
		.. "shows what Parcel last recorded as waiting and says " .. key("History mode") .. " at the top. "
		.. "Collecting and sending need a real mailbox; History, Auction and drafts do not.",
	"",
}, "\n")

local SHORTCUTS = table.concat({
	heading("In the inbox"),
	key("Click") .. "  open a mail and read it",
	key("Shift-click") .. "  take its contents without opening it",
	key("Ctrl-click") .. "  send it back to the sender",
	key("Right-click") .. "  tick it, for Open or Return on several at once",
	key("Shift-click a tick") .. "  select a range",
	key("Ctrl-click a tick") .. "  select everything from that sender",
	"",
	"The icon at the end of each row says what happens to that mail when it runs out, "
		.. "and clicking it does that now.",
	"",
	key("Shift-click Collect") .. " takes everything, ignoring your filters for that one run.",
	"",
	heading("Minimap button"),
	key("Click") .. " opens Parcel, " .. key("right-click") .. " opens these settings, and "
		.. key("ctrl-click") .. " hides the button. " .. key("/parcel minimap") .. " brings it back.",
	"",
}, "\n")

local SEARCH = table.concat({
	heading("Searching"),
	"Plain words match the sender, the subject, attached item names and the text of the mail itself.",
	"",
	key("from:name") .. "  received from someone",
	key("to:name") .. "  sent to someone",
	key("subject:word") .. "  the subject only",
	key("item:word") .. "  an attached item",
	key("body:word") .. "  the text of the mail",
	key("type:ah") .. "  auction mail",
	"",
	"Terms combine, so " .. key("from:bankalt item:ore") .. " means both.",
	"",
	"Mistype something and Parcel falls back to near matches rather than an empty list, "
		.. "and says so in the footer.",
	"",
	"Reading a mail is what lets Parcel record its text, so body search finds mail you have opened.",
	"",
}, "\n")

local NOTES = table.concat({
	heading("Worth knowing"),
	"Cash on delivery and Blizzard mail are never collected automatically. Take those by hand.",
	"",
	"Full bags only hold back mail carrying items. Gold needs nowhere to go, so auction sales are still collected.",
	"",
	"Gold you take at a vendor counts towards profit and loss on the Auctions tab, so buying under the vendor price and selling the difference reads as the profit it is.",
	"",
	"Parcel keeps as many bag slots free as you set under Collecting.",
	"",
	"A mailbox with more than a hundred mails is handed over in batches. Parcel asks for the rest and "
		.. "carries on. Refresh nudges it, and the server rate limits that to once a minute.",
	"",
	"History only knows what Parcel has seen. Visit a mailbox on a character to keep that character current.",
	"",
	"Settings are per profile. The Profiles tab copies them between characters.",
	"",
}, "\n")

-- Generated from the registry so adding a feature never means editing this.
function Options:BuildFeatureArgs()
	local args = {
		intro = {
			type = "description",
			order = 0,
			fontSize = "medium",
			name = "Parts of Parcel you can switch off entirely.\n",
		},
	}

	for index, feature in ipairs(ns.Features.list) do
		args[feature.key] = {
			type = "toggle",
			order = index,
			width = "double",
			name = feature.label,
			desc = feature.desc,
		}
	end

	return args
end

function Options:Build(addon)
	return {
		name = "Parcel",
		handler = addon,
		type = "group",
		childGroups = "tab",
		args = {
			help = {
				type = "group",
				order = 0,
				name = "Help",
				args = {
					version = {
						type = "description",
						order = 0,
						fontSize = "large",
						name = function()
							return ("Parcel %s"):format(Compat:GetAddOnMetadata("Version") or "unknown")
						end,
					},
					about = {
						type = "description",
						order = 0.1,
						fontSize = "medium",
						name = function()
							return ("By looterz.  Running on %s, interface %d.\n"):format(
								Options:GetFlavorLabel(), Compat.interface)
						end,
					},
					overview = { type = "description", order = 1, fontSize = "medium", name = OVERVIEW },
					opening = { type = "description", order = 2, fontSize = "medium", name = OPENING },
					shortcuts = { type = "description", order = 3, fontSize = "medium", name = SHORTCUTS },
					search = { type = "description", order = 4, fontSize = "medium", name = SEARCH },
					commands = {
						type = "description",
						order = 5,
						fontSize = "medium",
						name = function() return commandLines() end,
					},
					notes = { type = "description", order = 6, fontSize = "medium", name = NOTES },
				},
			},
			appearance = {
				type = "group",
				order = 1,
				name = "Appearance",
				get = "GetUISetting",
				set = "SetUISetting",
				args = {
					theme = {
						type = "select",
						order = 1,
						name = "Look",
						desc = "How the Parcel window is styled. All three have the same features; "
							.. "Blizzard is the stock panel look for anyone who would rather it "
							.. "blended in.",
						values = ns.Kit.themeLabels,
						sorting = ns.Kit.themeOrder,
					},
					hideBlizzardMail = {
						type = "toggle",
						order = 2,
						width = "double",
						name = "Replace Blizzard's mail window",
						desc = "Parcel stands in for the stock mail window entirely. "
							.. "Turn this off to leave Blizzard's on screen alongside it, "
							.. "which is mostly useful for comparing the two.",
					},
					minimapIcon = {
						type = "select",
						order = 3.5,
						name = "Minimap icon",
						desc = "Which picture the minimap button uses. The envelope is the game's own "
							.. "mail indicator and reads best at that size.",
						values = function() return ns.Broker.iconLabels end,
						sorting = function() return ns.Broker.iconOrder end,
					},
					moneyIcons = {
						type = "toggle",
						order = 3,
						width = "double",
						name = "Show coin icons",
						desc = "Amounts appear with the game's own gold, silver and copper icons. "
							.. "Turn this off for plain text, which is what you want if you copy "
							.. "figures out of chat.",
					},
					resetPosition = {
						type = "execute",
						order = 4,
						name = "Reset window position",
						desc = "Puts the Parcel window back where it started, at its "
							.. "original size, in case you have dragged it off screen "
							.. "or resized it awkwardly.",
						func = function() ns.Addon:ResetWindowPositions() end,
					},
				},
			},
			features = {
				type = "group",
				order = 2,
				name = "Features",
				get = "GetFeatureSetting",
				set = "SetFeatureSetting",
				args = Options:BuildFeatureArgs(),
			},
			collect = {
				type = "group",
				order = 3,
				name = "Collecting",
				get = "GetCollectSetting",
				set = "SetCollectSetting",
				args = {
					keepFreeSlots = {
						type = "range",
						order = 1,
						name = "Keep bag slots free",
						desc = "Mail carrying items is left once your bags get this full. "
							.. "Gold is always taken, and items that can top up a stack you "
							.. "already carry are still collected.",
						min = 0,
						max = 30,
						step = 1,
					},
					minInterval = {
						type = "range",
						order = 2,
						name = "Delay between actions",
						desc = "Seconds to wait between taking one thing and the next. "
							.. "Parcel already waits for the server to acknowledge each action, "
							.. "so this is only worth raising on a laggy realm.",
						min = 0,
						max = 2,
						step = 0.05,
					},
					verbose = {
						type = "toggle",
						order = 3,
						width = "double",
						name = "Report to chat",
						desc = "Print what each collection brought in, and why it stopped if it stopped early.",
					},
					deleteEmptied = {
						type = "toggle",
						order = 4,
						width = "double",
						name = "Remove mail once it is empty",
						desc = "Auction invoices keep their body text, so the server leaves the empty "
							.. "mail behind after you take the money. This clears them out. Only ever "
							.. "applies to mail Parcel has just emptied itself.",
					},
					filters = {
						type = "group",
						order = 10,
						inline = true,
						name = "What Collect takes",
						get = "GetFilterSetting",
						set = "SetFilterSetting",
						args = {
							intro = {
								type = "description",
								order = 0,
								fontSize = "medium",
								name = "Turn a category off and Collect leaves it in the mailbox. "
									.. "Shift-click the Collect button to take everything regardless.\n",
							},
							ahSold = {
								type = "toggle",
								order = 1,
								name = "Auction sold",
								desc = "Mail from the auction house for a listing that sold.",
							},
							ahWon = {
								type = "toggle",
								order = 2,
								name = "Auction won",
								desc = "Mail carrying an auction you won.",
							},
							ahExpired = {
								type = "toggle",
								order = 3,
								name = "Auction expired",
								desc = "Listings that ran out and came back to you.",
							},
							ahCancelled = {
								type = "toggle",
								order = 4,
								name = "Auction cancelled",
								desc = "Listings you pulled off the auction house.",
							},
							ahOutbid = {
								type = "toggle",
								order = 5,
								name = "Outbid notices",
								desc = "Refunds for auctions somebody outbid you on.",
							},
							postmaster = {
								type = "toggle",
								order = 6,
								name = "Postmaster",
								desc = "Items sent back because your bags were full when you looted.",
							},
							player = {
								type = "toggle",
								order = 7,
								name = "Everything else",
								desc = "Mail from players, and anything Parcel could not classify.",
							},
							postmasterNames = {
								type = "input",
								order = 8,
								width = "double",
								name = "Extra Postmaster names",
								desc = "Parcel recognises the Postmaster by name, and that name is translated. "
									.. "If your client calls it something Parcel does not know, add it here. "
									.. "Separate several with commas.",
								get = "GetCollectSetting",
								set = "SetCollectSetting",
							},
						},
					},
				},
			},
			send = {
				type = "group",
				order = 4,
				name = "Sending",
				get = "GetSendSetting",
				set = "SetSendSetting",
				args = {
					autoSubject = {
						type = "toggle",
						order = 1,
						width = "double",
						name = "Fill in a blank subject",
						desc = "Leave the subject empty and Parcel writes what is in the mail: "
							.. "the items attached, or the amount of gold if there are none. The "
							.. "subject field shows what will be sent before you send it.",
					},
					autofillRecipient = {
						type = "toggle",
						order = 2,
						width = "double",
						name = "Remember who you last wrote to",
						desc = "Fills the To field with the last person you mailed. "
							.. "Only ever into an empty field, so a reply is never overwritten.",
					},
				},
			},
			archive = {
				type = "group",
				order = 5,
				name = "History",
				get = "GetArchiveSetting",
				set = "SetArchiveSetting",
				args = {
					intro = {
						type = "description",
						order = 0,
						fontSize = "medium",
						name = "Parcel keeps what it has seen so you can search it later. "
							.. "Mail still sitting in your inbox is never pruned, however old it is.\n",
					},
					retentionDays = {
						type = "range",
						order = 1,
						name = "Keep for",
						desc = "Days to keep mail that has already been dealt with.",
						min = 7,
						max = 365,
						step = 1,
					},
					maxEntries = {
						type = "range",
						order = 2,
						name = "Maximum entries",
						desc = "A hard ceiling so the saved variables file stays a sensible size. "
							.. "The oldest go first.",
						min = 500,
						max = 20000,
						step = 500,
					},
					deduplicate = {
						type = "execute",
						order = 3,
						name = "Merge duplicates",
						desc = "Folds together entries that are the same mail recorded more "
							.. "than once. Runs automatically at login.",
						func = function()
							local merged = ns.Archive:Deduplicate()
							ns.Addon:Print(("Merged %d duplicated entries, %d remain."):format(
								merged, ns.Archive:Count()))
						end,
					},
					purge = {
						type = "execute",
						order = 4,
						name = "Prune now",
						desc = "Applies both limits immediately.",
						func = function()
							local removed = ns.Archive:Prune()
							ns.Addon:Print(("Pruned %d entries, %d remain."):format(removed, ns.Archive:Count()))
						end,
					},
					wipe = {
						type = "execute",
						order = 5,
						name = "Clear history",
						desc = "Removes every entry Parcel has recorded, for every character. "
							.. "Mail still sitting in a mailbox is not affected, but everything "
							.. "already collected, returned or sent is forgotten.",
						confirm = true,
						confirmText = "Clear Parcel's entire mail history? This cannot be undone.",
						func = function()
							local removed = ns.Archive:Wipe()
							ns.Addon:Print(("Cleared %d history entries."):format(removed))
						end,
					},
					size = {
						type = "description",
						order = 5,
						fontSize = "medium",
						name = function()
							return ("\nHolding %d entries, roughly %.0f KB."):format(
								ns.Archive:Count(), ns.Archive:EstimateBytes() / 1024)
						end,
					},
					vendor = {
						type = "group",
						order = 8,
						inline = true,
						name = "Vendor sales",
						args = {
							countVendor = {
								type = "toggle",
								order = 1,
								width = "full",
								name = "Count vendor gold in profit and loss",
								desc = "Buying under the vendor price and selling the difference "
									.. "only shows as a profit if the gold you take at a vendor "
									.. "counts. Turn this off to measure the auction house alone.",
								get = function()
									local auction = ns.Addon.db.profile.auction
									return not auction or auction.countVendor ~= false
								end,
								set = function(_, value)
									ns.Addon.db.profile.auction = ns.Addon.db.profile.auction or {}
									ns.Addon.db.profile.auction.countVendor = value
									ns.Events:Trigger("Parcel.Vendor.Changed")
								end,
							},
							announceVendor = {
								type = "toggle",
								order = 2,
								width = "full",
								name = "Report vendor runs in chat",
								desc = "One line when you leave a vendor, giving what the run "
									.. "made against what those items cost at auction.",
								get = function()
									local auction = ns.Addon.db.profile.auction
									return not auction or auction.announceVendor ~= false
								end,
								set = function(_, value)
									ns.Addon.db.profile.auction = ns.Addon.db.profile.auction or {}
									ns.Addon.db.profile.auction.announceVendor = value
								end,
							},
							wipePending = {
								type = "execute",
								order = 3,
								name = "Clear pending sales",
								desc = "Forgets what Parcel thinks has sold and not yet arrived. "
									.. "It relearns from your own listings next time you visit an "
									.. "auction house, which is also where it corrects itself if "
									.. "you collected the mail on another computer.",
								confirm = true,
								confirmText = "Clear what Parcel is waiting on? This cannot be undone.",
								func = function()
									local removed = ns.Pending:Forget()
									ns.Addon:Print(("Cleared %d pending sales."):format(removed))
								end,
							},
							wipeVendor = {
								type = "execute",
								order = 4,
								name = "Clear vendor record",
								desc = "Forgets every vendor sale Parcel has recorded.",
								confirm = true,
								confirmText = "Clear Parcel's record of vendor sales? This cannot be undone.",
								func = function()
									local removed = ns.Vendor:Forget()
									ns.Addon:Print(("Cleared %d vendor sales."):format(removed))
								end,
							},
							vendorSize = {
								type = "description",
								order = 3,
								fontSize = "medium",
								name = function()
									return ("\nHolding %d vendor sales."):format(ns.Vendor:Count())
								end,
							},
						},
					},
					alerts = {
						type = "group",
						order = 10,
						inline = true,
						name = "Warnings",
						get = "GetAlertSetting",
						set = "SetAlertSetting",
						args = {
							expiryDays = {
								type = "range",
								order = 1,
								name = "Warn this far ahead",
								desc = "At login Parcel says which of your characters has mail running out "
									.. "within this many days. It can only speak for mailboxes it has seen, "
									.. "so visit one on a character to keep its figures current.",
								min = 1,
								max = 14,
								step = 1,
							},
						},
					},
				},
			},
		},
	}
end
