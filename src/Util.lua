-- Util.lua
--
-- Small, pure helper functions shared across modules. Nothing here touches
-- AddOn state; everything is a stateless utility.

local _, ns = ...
local C = ns.Const

local Util = {}
ns.Util = Util

--- Split a string on a literal (non-pattern) separator.
-- The optional `maxFields` caps the number of returned fields: once that many
-- have been produced, the entire remaining string (including any further
-- separators) becomes the final field. This is important for our wire format,
-- where the trailing PROFILE-DATA field may itself legitimately contain "||".
-- @param input     string  The string to split.
-- @param sep       string  Literal separator (treated verbatim, not as a pattern).
-- @param maxFields number?  Optional maximum number of fields to produce.
-- @return table A list of string fields.
function Util.split(input, sep, maxFields)
	local fields = {}
	local start = 1
	while true do
		-- If we are one field short of the cap, the rest is the last field.
		if maxFields and #fields == maxFields - 1 then
			fields[#fields + 1] = input:sub(start)
			break
		end
		local s, e = input:find(sep, start, true) -- plain = true: literal match
		if not s then
			fields[#fields + 1] = input:sub(start)
			break
		end
		fields[#fields + 1] = input:sub(start, s - 1)
		start = e + 1
	end
	return fields
end

--- Join a list of values into a string using the wire separator.
-- @param parts table A list of values (converted with tostring).
-- @return string
function Util.join(parts)
	return table.concat(parts, C.SEPARATOR)
end

--- Trim leading/trailing whitespace.
-- @param s string
-- @return string
function Util.trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Build the "Name-Realm" identifier for a unit, matching the convention used
-- by RP AddOns for keying their character store.
--
-- NOTE: realm names are normalized by stripping spaces (e.g. "Argent Dawn" ->
-- "ArgentDawn"). The TRP3 adapter prefers TRP3's own unit-id helper when
-- available (see TRP3Adapter) so register keys match exactly; this generic
-- version is the fallback used for our own bookkeeping.
-- @param unit string A unit token (e.g. "mouseover", "target", "player").
-- @return string|nil "Name-Realm", or nil if the unit is not a player.
function Util.getUnitID(unit)
	if not UnitIsPlayer(unit) then
		return nil
	end
	local name, realm = UnitName(unit)
	if not name or name == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	else
		realm = realm:gsub("%s+", "")
	end
	return name .. "-" .. realm
end

--- Whether `unit` is a player belonging to the faction opposite the viewer.
-- @param unit string A unit token.
-- @return boolean
function Util.isOppositeFaction(unit)
	if not UnitIsPlayer(unit) then
		return false
	end
	local theirs = UnitFactionGroup(unit)
	local mine = UnitFactionGroup("player")
	-- UnitFactionGroup returns "Alliance"/"Horde"/"Neutral"/nil. Treat any
	-- mismatch between two known, differing groups as opposite faction.
	return theirs ~= nil and mine ~= nil and theirs ~= mine
end
