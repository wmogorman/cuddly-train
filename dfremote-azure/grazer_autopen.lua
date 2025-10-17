-- grazer_autopen.lua
-- Auto-assign newly spawned/arrived grazing animals to a named pasture.
-- Requires: a pre-made zone named PASTURE_NAME with type Pen/Pasture.
--
-- Commands:
--   grazer_autopen start    -> begin listening for new units (births/migrants)
--   grazer_autopen stop     -> stop listening
--   grazer_autopen once     -> scan all current units now (assign any loose grazers)
--   grazer_autopen status   -> show whether listener is active

-- === CONFIG ===
local PASTURE_NAME = 'Grazers'       -- <-- change if you named your pasture differently
local INCLUDE_TAME_ONLY = true       -- only auto-pen tame animals (recommended)
local INCLUDE_PETS = true            -- include pets (true) or skip them (false)
local LOG_PREFIX = '[grazer_autopen] '
local SCAN_INTERVAL_TICKS = 1200     -- rescan every in-game day

-- --- helpers ---

local state = dfhack.script_environment('grazer_autopen_state')
state.seen_units = state.seen_units or {}
state.running = state.running or false
state.on_state_change_registered = state.on_state_change_registered or false

local function reset_state()
  state.seen_units = {}
end

if not state.on_state_change_registered then
  dfhack.onStateChange.grazer_autopen = function(code)
    if code == SC_WORLD_UNLOADED then
      state.running = false
      reset_state()
    elseif code == SC_WORLD_LOADED then
      reset_state()
    end
  end
  state.on_state_change_registered = true
end

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
  if not unit then return false end
  if is_grazer(unit) then
    zone_assign_unit(PASTURE_NAME, unit.id)
    return true
  end
  return false
end

local function scan_units(force_rescan)
  local count = 0
  local world = df.global.world
  if not world or not world.units then
    return 0
  end
  local seen = state.seen_units
  if not seen then
    seen = {}
    state.seen_units = seen
  end
  for _, u in ipairs(world.units.active) do
    if force_rescan or not seen[u.id] then
      seen[u.id] = true
      if assign_if_grazer(u) then
        count = count + 1
      end
    end
  end
  return count
end

local function schedule_scan()
  if not state.running then return end
  dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function()
    if not state.running then return end
    scan_units(false)
    schedule_scan()
  end)
end

local function start()
  if state.running then
    dfhack.println(LOG_PREFIX .. 'already running.')
    return
  end
  state.running = true
  state.seen_units = {}
  scan_units(false)
  schedule_scan()
  dfhack.println(LOG_PREFIX .. 'started. New grazers will be auto-pastured.')
end

local function stop()
  if not state.running then
    dfhack.println(LOG_PREFIX .. 'already stopped.')
    return
  end
  state.running = false
  dfhack.println(LOG_PREFIX .. 'stopped.')
end

local function status()
  dfhack.println(('%sstatus: %s (pasture=%q, tame_only=%s, include_pets=%s)')
    :format(LOG_PREFIX, state.running and 'ACTIVE' or 'inactive', PASTURE_NAME,
            tostring(INCLUDE_TAME_ONLY), tostring(INCLUDE_PETS)))
end

local function once_scan_existing()
  local count = scan_units(true)
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
