local ADDON, ns = ...

-- FNV-1a, used to keep mail keys short in saved variables.
--
-- Two traps make this less trivial than the reference implementation looks.
--
-- The 32 bit multiply overflows a double's exact integer range: 2^32 * 16777619
-- is about 7.2e16 and doubles are exact only to 2^53. It is done in 16 bit
-- halves so every intermediate stays well inside that.
--
-- WoW's bit library works on 32 bit signed values, so anything with the top bit
-- set comes back negative and has to be folded back to unsigned.

local Hash = {}
ns.Hash = Hash

local bxor = bit and bit.bxor
local OFFSET = 2166136261      -- 0x811c9dc5
local PRIME_LO = 0x0193        -- 16777619 = 0x01000193
local PRIME_HI = 0x0100
local WRAP = 4294967296        -- 2^32

local function unsigned(value)
	if value < 0 then return value + WRAP end
	return value
end

function Hash:FNV1a(text, seed)
	local hash = seed or OFFSET

	for index = 1, #text do
		hash = unsigned(bxor(hash, text:byte(index)))

		local lo = hash % 65536
		local hi = (hash - lo) / 65536

		local low = lo * PRIME_LO
		local mid = hi * PRIME_LO + lo * PRIME_HI + (low - low % 65536) / 65536

		hash = (mid % 65536) * 65536 + low % 65536
	end

	return hash
end

-- Sixty four bits as two independent passes. At the twenty thousand entry
-- ceiling a 32 bit hash carries roughly a one in twenty chance of a collision
-- somewhere in the archive; at 64 bits it is about one in a hundred billion.
--
-- The second pass is seeded differently and fed the text reversed, so the two
-- halves do not agree about which bytes matter most.
local memo = {}
local memoCount = 0

function Hash:Key(text)
	local cached = memo[text]
	if cached then return cached end

	local first = self:FNV1a(text, OFFSET)
	local second = self:FNV1a(text:reverse(), 0x01000193)
	local key = ("%08x%08x"):format(first, second)

	-- The same sender and subject recur constantly, so memoising makes the
	-- repeat cost nothing. Bounded so a long session cannot grow it without end.
	if memoCount > 4096 then
		memo = {}
		memoCount = 0
	end
	memo[text] = key
	memoCount = memoCount + 1

	return key
end

function Hash:ResetCache()
	memo = {}
	memoCount = 0
end
