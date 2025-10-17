-- grazer_autopen.lua
-- Auto-assign newly spawned/arrived grazing animals to a named pasture.
-- Requires: a pre-made zone named PASTURE_NAME with type Pen/Pasture.
--
-- Commands:
--   grazer_autopen start    -> begin listening for new units (births/migrants)
--   grazer_autopen stop     -> stop listening
--   grazer_autopen once     -> scan all current units now (assign any loose grazers)
--   grazer_autopen status   -> show whether listener is active

local eventful = require('plugins.eventful')

-- === CONFIG ===
local PASTURE_NAME = 'Grazers'       -- <-- change if you named your pasture differently
local INCLUDE_TAME_ONLY = true       -- only auto-pen tame animals (recommended)
local INCLUDE_PETS = true            -- include pets (true) or skip them (false)
local LOG_PREFIX = '[grazer_autopen] '

-- --- helpers ---

local function is_grazer(unit)
  if not unit or unit.flags1.dead or unit.flags1.caged then return false end
  -- skip vermin
  if unit.flags1.vermin then return false end
  -- skip citizens/dwarves and sapients
  if unit.race == df.global.ui.race_id then return false end

  local raw = df.global.world.raws.creatures.all[unit.race]
  if not raw then return false end
  local caste = raw.caste[unit.caste]
  if not caste then return false end

  -- DF raws: GRAZER token is stored as an integer > 0 on the caste in DF/DFHack
  -- (If your DFHack build uses a different field name, ping me and I’ll adapt.)
  if (caste.grazer or 0) <= 0 then return false end

  -- optional filters
  if INCLUDE_TAME_ONLY and not (unit.flags1.tame or unit.flags2.domesticated) then
    return false
  end

  -- Pets are typically tame; toggle if you want to exclude them.
  if not INCLUDE_PETS and unit.flags2.roaming_wilderness_population == false then
    -- treat “not wild” as pet/domestic; skip if excluding pets
    return false
  end

  return true
end

local function zone_assign_unit(zone_name, unit_id)
  -- Use DFHack's 'zone' command to assign to a named Pen/Pasture zone.
  -- This relies on the zone tool supporting named assignment.
  local ok, err = dfhack.run_command_silent(
    'zone', 'assign', '--name', zone_name, '--pen', '--unit', tostring(unit_id)
  )
  if not ok then
    dfhack.printerr(('%sFailed to assign unit %d to pasture %q: %s')
      :format(LOG_PREFIX, unit_id, zone_name, tostring(err)))
  else
    dfhack.println(('%sAssigned unit %d to pasture %q')
      :format(LOG_PREFIX, unit_id, zone_name))
  end
end

local function assign_if_grazer(unit)
  if not unit then return end
  if is_grazer(unit) then
    zone_assign_unit(PASTURE_NAME, unit.id)
  end
end

local LISTENER_NAME = 'grazer_autopen_onNewUnit'
local active = false

local function start()
  if active then
    dfhack.println(LOG_PREFIX .. 'already running.')
    return
  end
  -- Hook: fires for births, migrants, invaders, etc.
  eventful.onNewUnit[LISTENER_NAME] = function(id)
    local u = df.unit.find(id)
    assign_if_grazer(u)
  end
  active = true
  dfhack.println(LOG_PREFIX .. 'started. New grazers will be auto-pastured.')
end

local function stop()
  if eventful.onNewUnit[LISTENER_NAME] then
    eventful.onNewUnit[LISTENER_NAME] = nil
  end
  active = false
  dfhack.println(LOG_PREFIX .. 'stopped.')
end

local function status()
  dfhack.println(('%sstatus: %s (pasture=%q, tame_only=%s, include_pets=%s)')
    :format(LOG_PREFIX, active and 'ACTIVE' or 'inactive', PASTURE_NAME,
            tostring(INCLUDE_TAME_ONLY), tostring(INCLUDE_PETS)))
end

local function once_scan_existing()
  local count = 0
  for _,u in ipairs(df.global.world.units.active) do
    if is_grazer(u) then
      zone_assign_unit(PASTURE_NAME, u.id)
      count = count + 1
    end
  end
  dfhack.println(('%sScanned current map: attempted to assign %d grazers.')
    :format(LOG_PREFIX, count))
end

-- entrypoint
local args = {...}
local cmd = args[1]
if cmd == 'start' then
  start()
elseif cmd == 'stop' then
  stop()
elseif cmd == 'status' then
  status()
elseif cmd == 'once' then
  once_scan_existing()
else
  dfhack.println([[
grazer_autopen: auto-assign newly spawned/arrived grazing animals to a named pasture.

Usage:
  grazer_autopen start     - begin listening for new units (births/migrants)
  grazer_autopen stop      - stop listening
  grazer_autopen status    - show current settings and whether listener is active
  grazer_autopen once      - scan all current units now and assign grazers

Config:
  - Edit PASTURE_NAME at top to match your zone's name.
  - Toggle INCLUDE_TAME_ONLY / INCLUDE_PETS as desired.
Notes:
  - Requires a pre-made Pen/Pasture zone with that name.
  - If zone assignment fails, ensure the zone exists and is a Pen/Pasture.
]])
end
