local ADDON, ns = ...

-- A small internal event bus. Parcel's own events travel on this rather than on
-- AceEvent, because AceEvent is for the game's events and mixing the two makes
-- it hard to tell at a glance which is which.

local Events = {}
ns.Events = Events

local listeners = {}

function Events:Register(event, callback)
	local bucket = listeners[event]
	if not bucket then
		bucket = {}
		listeners[event] = bucket
	end
	bucket[#bucket + 1] = callback
	return callback
end

function Events:Unregister(event, callback)
	local bucket = listeners[event]
	if not bucket then return end
	for index = #bucket, 1, -1 do
		if bucket[index] == callback then
			table.remove(bucket, index)
		end
	end
end

function Events:Trigger(event, ...)
	local bucket = listeners[event]
	if not bucket then return end

	-- Iterated over a copy so a listener may unregister itself, which the
	-- inbox does whenever it rebuilds.
	local snapshot = {}
	for index = 1, #bucket do
		snapshot[index] = bucket[index]
	end

	for index = 1, #snapshot do
		snapshot[index](...)
	end
end
