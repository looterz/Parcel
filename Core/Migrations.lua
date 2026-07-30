local ADDON, ns = ...

-- Saved data changes shape between releases and players keep their history, so
-- every change to that shape gets a numbered step that runs once.
--
-- The version is deliberately not an AceDB default. Defaults fill in missing
-- keys, so a defaulted version would make an existing database claim to be
-- current and skip the very migration it needs.

local Migrations = {}
ns.Migrations = Migrations

Migrations.CURRENT = 3

-- [version] = what to do to reach that version from the one before it.
Migrations.steps = {
	-- An early build filed a fresh entry on every inbox update, and keys carried
	-- attachment icons that changed as a mail drained. Both leave duplicates.
	[1] = function()
		local merged = ns.Archive:Deduplicate()
		if merged > 0 then
			ns.Addon:Print(("Merged %d duplicated history entries."):format(merged))
		end
	end,

	-- Item links were stored whole. For a plain item the link says nothing the
	-- id does not, and it is the single largest thing in the archive.
	[2] = function()
		local dropped = 0

		for _, entry in ipairs(ns.Archive:GetEntries()) do
			for _, item in ipairs(entry.items or {}) do
				if item.l and not ns.Archive:LinkMatters(item.l) then
					item.l = nil
					dropped = dropped + 1
				end
			end

			local invoice = entry.invoice
			if invoice and invoice.item and entry.items and entry.items[1]
				and invoice.item == entry.items[1].name then
				invoice.item = nil
			end
		end

		if dropped > 0 then
			ns.Addon:Print(("Tidied %d stored item links."):format(dropped))
		end
	end,

	-- The Light skin is gone. It was the dark dialog stone with pale text on it,
	-- which is a second Dark theme wearing the wrong name, and no texture the
	-- client ships made a paper version of it readable.
	--
	-- Theme:GetName already falls back for a name it does not recognise, so
	-- this is only about not leaving a dead value in saved data.
	[3] = function()
		local db = ns.Addon and ns.Addon.db
		local profiles = db and db.profiles
		if not profiles then return end

		local moved = 0
		for _, profile in pairs(profiles) do
			if type(profile) == "table" and type(profile.ui) == "table"
				and profile.ui.theme == "light" then
				profile.ui.theme = "dark"
				moved = moved + 1
			end
		end

		if moved > 0 and ns.Theme then ns.Theme:Apply() end
	end,
}

local function looksUsed(global)
	local archive = global.archive
	if archive and archive.entries and #archive.entries > 0 then return true end
	if global.characters and next(global.characters) then return true end
	if global.recipients and next(global.recipients) then return true end
	if global.drafts and next(global.drafts) then return true end
	return false
end

function Migrations:Run()
	local addon = ns.Addon
	local global = addon and addon.db and addon.db.global
	if not global then return 0 end

	local from = global.schema
	if from == nil then
		-- Nothing recorded means a fresh install, which has nothing to repair.
		from = looksUsed(global) and 0 or self.CURRENT
	end

	if from >= self.CURRENT then
		global.schema = self.CURRENT
		return 0
	end

	local ran = 0
	for version = from + 1, self.CURRENT do
		local step = self.steps[version]
		if step then
			local ok, err = pcall(step, global)
			if ok then
				ran = ran + 1
			else
				-- A step that throws must not take the addon down or leave the
				-- version claiming work that did not happen.
				ns.Addon:Print(("History upgrade step %d failed: %s"):format(version, tostring(err)))
				global.schema = version - 1
				return ran
			end
		end
	end

	global.schema = self.CURRENT
	return ran
end

function Migrations:Version()
	local addon = ns.Addon
	local global = addon and addon.db and addon.db.global
	return global and global.schema or nil
end
