local ADDON, ns = ...

-- Parcel's own interface kit.
--
-- Everything here is built from textures and font objects the game client
-- already ships, which addons are free to use. No artwork is redistributed and
-- nothing is borrowed from another addon.
--
-- Backdrops rather than SetTextureSliceMargins: BackdropTemplate works
-- identically on every client Parcel supports, where texture slicing arrived in
-- 10.x and was backported unevenly.

local Kit = {}
ns.Kit = Kit

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local PALETTES = {
	light = {
		panel = {
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 32,
			edgeSize = 32,
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		},
		panelColor = { 1, 1, 1, 1 },
		borderColor = { 1, 1, 1, 1 },
		title = { 1, 0.82, 0 },
		text = { 0.92, 0.90, 0.84 },
		dim = { 0.62, 0.60, 0.55 },
		accent = { 1, 0.82, 0 },
		rowHighlight = { 1, 1, 1, 0.08 },
		rowSelected = { 1, 0.82, 0, 0.18 },
		inputBackdrop = { 0, 0, 0, 0.35 },
		divider = { 1, 0.82, 0, 0.25 },
	},
	dark = {
		panel = {
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = false,
			edgeSize = 14,
			-- The same proportion of the edge as the other two skins, which use a
			-- 32 pixel border against this one's 14.
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		},
		panelColor = { 0.06, 0.06, 0.07, 0.94 },
		borderColor = { 0.42, 0.40, 0.36, 1 },
		title = { 1, 0.86, 0.30 },
		text = { 0.88, 0.88, 0.90 },
		dim = { 0.52, 0.52, 0.56 },
		accent = { 1, 0.82, 0 },
		rowHighlight = { 1, 1, 1, 0.07 },
		rowSelected = { 1, 0.82, 0, 0.16 },
		inputBackdrop = { 0, 0, 0, 0.45 },
		divider = { 1, 0.86, 0.30, 0.20 },
	},
	-- Blizzard's own marble panel fill and gold trimmed border, tiled at its
	-- native 256, with their font colours over the top.
	--
	-- The mail frame's own UI-MailFrameBG was tried here and does not work: it
	-- is a single 512 illustration that Blizzard anchors oversized and lets the
	-- frame clip, so most of the file is empty. Stretched across a wider window
	-- the artwork collapses into a small patch in one corner. Only a texture
	-- that tiles is usable as a panel fill.
	blizzard = {
		panel = {
			bgFile = "Interface\\FrameGeneral\\UI-Background-Marble",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 256,
			edgeSize = 32,
			-- Tighter than the 11/12 the Light skin uses with the same border art.
			-- That art pairs with UI-DialogBox-Background, which carries its own
			-- margin; marble is a flat tile with none, so at Blizzard's insets it
			-- stops short and leaves a gap inside the gold trim. These run the
			-- fill under the trim instead, where the overlap is hidden.
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		},
		panelColor = { 1, 1, 1, 1 },
		borderColor = { 1, 1, 1, 1 },
		title = { 1, 0.82, 0 },
		text = { 1, 1, 1 },
		dim = { 0.62, 0.60, 0.55 },
		accent = { 1, 0.82, 0 },
		rowHighlight = { 1, 1, 1, 0.10 },
		rowSelected = { 1, 0.82, 0, 0.22 },
		inputBackdrop = { 0, 0, 0, 0.5 },
		divider = { 1, 0.82, 0, 0.30 },
	},
}

-- Order the settings dropdown offers them in.
Kit.themeOrder = { "dark", "light", "blizzard" }

Kit.themeLabels = {
	dark = "Dark",
	light = "Light",
	blizzard = "Blizzard",
}

-- Blizzard's own font objects. Using them rather than shipping fonts keeps
-- Parcel readable in every locale for free, because the client already picked
-- the right face for the language it was installed in.
Kit.fonts = {
	title = "GameFontNormalLarge",
	heading = "GameFontNormal",
	body = "GameFontHighlightSmall",
	dim = "GameFontDisableSmall",
	number = "NumberFontNormalSmall",
}

local currentTheme = "blizzard"
local themed = {}

function Kit:GetPalette(name)
	return PALETTES[name or currentTheme] or PALETTES.light
end

function Kit:GetThemeName()
	return currentTheme
end

function Kit:HasTheme(name)
	return PALETTES[name] ~= nil
end

-- Anything created through the kit registers itself here so a theme change is
-- one pass over a flat list rather than a walk of the frame tree.
function Kit:Adopt(frame, apply)
	themed[#themed + 1] = { frame = frame, apply = apply }
	apply(frame, self:GetPalette())
	return frame
end

function Kit:SetTheme(name)
	if not PALETTES[name] then return false end
	currentTheme = name

	local palette = self:GetPalette()
	for _, entry in ipairs(themed) do
		if entry.frame then
			entry.apply(entry.frame, palette)
		end
	end

	return true
end

-- Panels
-- ---------------------------------------------------------------------------

local function applyPanel(frame, palette)
	frame:SetBackdrop(palette.panel)
	frame:SetBackdropColor(unpack(palette.panelColor))
	frame:SetBackdropBorderColor(unpack(palette.borderColor))
end

-- How much of a panel the border eats. The Blizzard skin uses Blizzard's own
-- 32 pixel dialog edge where Dark uses a 14 pixel tooltip edge, so anything
-- positioned against the panel edge has to ask rather than assume.
function Kit:GetInsets(name)
	local insets = self:GetPalette(name).panel.insets
	return insets.left, insets.right, insets.top, insets.bottom
end

function Kit:CreatePanel(parent, name)
	local frame = CreateFrame("Frame", name, parent, BACKDROP_TEMPLATE)
	return self:Adopt(frame, applyPanel)
end

-- Text
-- ---------------------------------------------------------------------------

-- role is a key into Kit.fonts, and also picks the colour the palette uses.
function Kit:CreateText(parent, role, justify)
	local font = self.fonts[role] or self.fonts.body
	local text = parent:CreateFontString(nil, "OVERLAY", font)
	text:SetJustifyH(justify or "LEFT")

	self:Adopt(text, function(fontString, palette)
		local colour = palette[role] or palette.text
		fontString:SetTextColor(colour[1], colour[2], colour[3])
	end)

	return text
end

function Kit:CreateDivider(parent)
	local texture = parent:CreateTexture(nil, "ARTWORK")
	texture:SetHeight(1)
	texture:SetTexture("Interface\\Buttons\\WHITE8X8")

	self:Adopt(texture, function(line, palette)
		line:SetVertexColor(unpack(palette.divider))
	end)

	return texture
end

function Kit:Colorize(text, role)
	local palette = self:GetPalette()
	local colour = palette[role] or palette.text
	return ("|cff%02x%02x%02x%s|r"):format(colour[1] * 255, colour[2] * 255, colour[3] * 255, text)
end
