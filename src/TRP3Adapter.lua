-- TRP3Adapter.lua
--
-- Concrete ProfileAdapter for Total RP 3. All TRP3-specific knowledge lives
-- here; if TRP3's internal APIs change, this is the only file that should need
-- updating. TRP3 may load after us, so we resolve TRP3_API lazily at call time
-- rather than caching references at file load.
--
-- v1 replicates three profile sections: characteristics, character and misc.
-- The "about" section is intentionally excluded (see README "Additional Plans").
--
-- The adapter-private `data` payload we produce/consume looks like:
--   { profileID = "abc123", sections = { characteristics = {...}, character = {...}, misc = {...} } }
-- profileID is required by TRP3's register on injection (saveCurrentProfileID).

local _, ns = ...
local C = ns.Const

local TRP3Adapter = ns.Class("TRP3Adapter", ns.ProfileAdapter)

function TRP3Adapter:init()
	ns.ProfileAdapter.init(self, C.SOURCE.TRP3)
end

--- True only when TRP3 is loaded and every API we depend on is present.
function TRP3Adapter:isAvailable()
	local api = TRP3_API
	if not api or not api.register or not api.profile or not api.dashboard then
		return false
	end
	local reg = api.register
	return reg.getUnitIDProfile ~= nil
		and reg.getUnitIDProfileID ~= nil
		and reg.isUnitIDKnown ~= nil
		and reg.hasProfile ~= nil
		and reg.saveInformation ~= nil
		and reg.saveCurrentProfileID ~= nil
		and reg.addCharacter ~= nil
		and reg.registerInfoTypes ~= nil
end

--- Use TRP3's own unit-id helper so our keys match its register exactly.
function TRP3Adapter:getUnitID(unit)
	if self:isAvailable() and TRP3_API.utils and TRP3_API.utils.str then
		return TRP3_API.utils.str.getUnitID(unit)
	end
	return ns.Util.getUnitID(unit)
end

--- TRP3 keys the local player by its own globals.player_id; use it so the
-- self-extraction branch and update events line up exactly.
function TRP3Adapter:getPlayerUnitID()
	if self:isAvailable() and TRP3_API.globals then
		return TRP3_API.globals.player_id
	end
	return ns.ProfileAdapter.getPlayerUnitID(self)
end

-- Build the opaque content-version from the sections' per-section counters.
-- Missing sections contribute 0. Equality of this string means "same content".
--
-- MSP-sourced profiles (non-TRP3 RP addons) lack .v counters; TRP3 instead
-- tracks per-field CRC versions in profile.mspver. We fold them in as a sorted
-- suffix so MSP updates still produce a distinct content version.
local mspFields = {} -- scratch: refilled per buildContentVersion call

local function buildContentVersion(sections, mspver)
	local function v(section)
		return (section and section.v) or 0
	end
	local version = string.format(
		"%s:%s:%s",
		v(sections.characteristics),
		v(sections.character),
		v(sections.misc)
	)
	if mspver then
		local n = 0
		for field, ver in pairs(mspver) do
			n = n + 1
			mspFields[n] = tostring(field) .. "=" .. tostring(ver)
		end
		for i = #mspFields, n + 1, -1 do
			mspFields[i] = nil
		end
		if n > 0 then
			table.sort(mspFields)
			version = version .. "|msp:" .. table.concat(mspFields, ",")
		end
	end
	return version
end

-- Gather the three sections for the LOCAL player via TRP3's exchange getters.
local function getLocalSections()
	local reg = TRP3_API.register
	return {
		characteristics = reg.player.getCharacteristicsExchangeData(),
		character = TRP3_API.dashboard.getCharacterExchangeData(),
		misc = reg.player.getMiscExchangeData(),
	}
end

-- Gather the three sections for another known unit from TRP3's register.
-- Also returns the profile's mspver table (nil for non-MSP profiles) so the
-- caller can fold it into the content version.
local function getRegisteredSections(unitID)
	local profile = TRP3_API.register.getUnitIDProfile(unitID)
	if not profile then
		return nil
	end
	return {
		characteristics = profile.characteristics,
		character = profile.character,
		misc = profile.misc,
	}, profile.mspver
end

--- Extract a profile for `unitID` from TRP3's own data, deep-copying so we
-- never alias (and later serialize) TRP3's live tables.
-- @return table|nil A profile object, or nil if TRP3 has no data for the unit.
function TRP3Adapter:extract(unitID)
	if not self:isAvailable() then
		return nil
	end
	local reg = TRP3_API.register

	local profileID, rawSections, mspver
	if unitID == TRP3_API.globals.player_id then
		-- Ourselves: pull from the player profile getters.
		profileID = TRP3_API.profile.getPlayerCurrentProfileID()
		rawSections = getLocalSections()
	else
		-- Someone else: only possible if TRP3 already exchanged with them.
		if not reg.isUnitIDKnown(unitID) or not reg.hasProfile(unitID) then
			return nil
		end
		profileID = reg.getUnitIDProfileID(unitID)
		rawSections, mspver = getRegisteredSections(unitID)
	end

	-- Without a profile id we cannot inject on the receiving end, so this
	-- profile is not shareable.
	if not profileID or not rawSections then
		return nil
	end

	-- Deep-copy only the sections that exist.
	local sections = {}
	for key, section in pairs(rawSections) do
		sections[key] = CopyTable(section)
	end

	return {
		addon = self.name,
		contentVersion = buildContentVersion(sections, mspver),
		data = { profileID = profileID, sections = sections },
	}
end

--- Cheap "could we serve this unit's profile" check for the pull exchange:
-- true when TRP3 holds a profile for the unit (or it is us). Does not
-- extract — the expensive copy only runs once a request is granted.
function TRP3Adapter:canServe(unitID)
	if not unitID or not self:isAvailable() then
		return false
	end
	if unitID == TRP3_API.globals.player_id then
		return TRP3_API.profile.getPlayerCurrentProfileID() ~= nil
	end
	local reg = TRP3_API.register
	return reg.isUnitIDKnown(unitID)
		and reg.hasProfile(unitID)
		and reg.getUnitIDProfileID(unitID) ~= nil
end

--- Inject a received profile into TRP3's register so TRP3 renders it.
-- Mirrors the sequence TRP3 itself uses when receiving a profile.
-- @return boolean Whether anything was injected.
function TRP3Adapter:inject(unitID, data, classID)
	if not self:isAvailable() then
		return false
	end
	if not data or not data.profileID or not data.sections then
		return false
	end

	local reg = TRP3_API.register
	local types = reg.registerInfoTypes

	-- Ensure the character exists, mark them a TRP3 user, and bind the profile.
	if not reg.isUnitIDKnown(unitID) then
		reg.addCharacter(unitID)
	end
	-- Minimal client info: enough for TRP3 to treat them as a TRP3 user.
	-- (client, clientVersion, msp, extended, isTrial, extendedVersion, rpExperience, classID)
	reg.saveClientInformation(unitID, "Total RP 3", "", false, 0, false, "", nil, classID)
	reg.saveCurrentProfileID(unitID, data.profileID)

	-- Write each present section, skipping ones TRP3 already holds at the same
	-- version to avoid redundant writes and update events (unrolled: the
	-- section map would be a per-call allocation for only three entries).
	local injected = false
	local section = data.sections.characteristics
	if section and reg.shouldUpdateInformation(unitID, types.CHARACTERISTICS, section.v) then
		reg.saveInformation(unitID, types.CHARACTERISTICS, section)
		injected = true
	end
	section = data.sections.character
	if section and reg.shouldUpdateInformation(unitID, types.CHARACTER, section.v) then
		reg.saveInformation(unitID, types.CHARACTER, section)
		injected = true
	end
	section = data.sections.misc
	if section and reg.shouldUpdateInformation(unitID, types.MISC, section.v) then
		reg.saveInformation(unitID, types.MISC, section)
		injected = true
	end
	return injected
end

--- Hook TRP3's internal "register data updated" callback so the Scanner can
-- react when a same-faction profile arrives/changes asynchronously.
-- @param callback function Invoked as callback(unitID).
function TRP3Adapter:registerUpdateListener(callback)
	if not self:isAvailable() or not TRP3_Addon or not TRP3_API.RegisterCallback then
		return
	end
	TRP3_API.RegisterCallback(TRP3_Addon, TRP3_Addon.Events.REGISTER_DATA_UPDATED, function(_, unitID)
		-- unitID is nil for some player-only events; ignore those.
		if unitID then
			callback(unitID)
		end
	end)
end

--- Hook TRP3's profile-receipt signals so the Scanner can re-publish data
--- that arrived over TRP3's own comm channels. Two sources:
---   * REGISTER_DATA_RECEIVED: TRP3 exchange protocol section receipts.
---   * msp.callback.received: MSP profiles merged from non-TRP3 RP AddOns.
--- Neither fires for FactionRP's own injections, so this is loop-safe.
-- @param callback function Invoked as callback(unitID).
function TRP3Adapter:registerReceivedListener(callback)
	if not self:isAvailable() then
		return
	end
	if TRP3_Addon and TRP3_Addon.Events and TRP3_Addon.Events.REGISTER_DATA_RECEIVED then
		TRP3_API.RegisterCallback(TRP3_Addon, TRP3_Addon.Events.REGISTER_DATA_RECEIVED, function(_, unitID)
			if unitID then
				callback(unitID)
			end
		end)
	end
	-- LibMSP exposes a plain callback list on the `msp` global. Our listener is
	-- appended after TRP3's own (it registers during init, before login), so
	-- the register writes have already landed when we fire.
	if msp and msp.callback and msp.callback.received then
		msp.callback.received[#msp.callback.received + 1] = function(unitID)
			callback(unitID)
		end
	end
end

-- Register the singleton adapter.
ns.registerAdapter(TRP3Adapter:new())
