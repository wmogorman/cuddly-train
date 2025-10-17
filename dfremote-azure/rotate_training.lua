-- rotate_training.lua
-- Rotates squad alerts between Train-A and Train-B each in-game month.
-- Usage:
--   rotate_training start    -> start the monthly rotation
--   rotate_training stop     -> stop the monthly rotation
--   rotate_training once     -> run one immediate flip (for testing)
--   rotate_training status   -> show current config and next run

local repeat_name = 'rotate-training-monthly'
local alertA_name = 'Train-A'
local alertB_name = 'Train-B'

-- Put your squad names here. Any not listed are ignored.
-- Example: two squads you want to alternate.
local groupA = { 'Bronze Blades A' }
local groupB = { 'Bronze Blades B' }

-- --------------- helpers ----------------

local function find_alert_index_by_name(name)
  -- Alerts live on the fortress civ entity
  local fort = df.global.plotinfo.main.fortress_entity
  if not fort then return nil end
  local alerts = fort.alerts -- list<entity_alert>
  if not alerts then return nil end
  for i, a in ipairs(alerts) do
    if a and a.name == name then
      -- Alerts are 0-based indexed in squads.alert_index fields.
      return i-1
    end
  end
  return nil
end

local function list_squads_by_name()
  local list = {}
  for _,sq in ipairs(df.global.world.squads.all) do
    if sq and sq.name and #sq.name.words > 0 then
      local n = dfhack.TranslateName(sq.name)
      list[n] = sq
    end
  end
  return list
end

local function set_squad_alert(squad, alert_index)
  -- Each squad tracks its current alert index.
  -- Field is cur_alert_idx in current DFHack builds.
  -- Fallback to alert_index if cur_alert_idx is absent in your build.
  if squad.cur_alert_idx ~= nil then
    squad.cur_alert_idx = alert_index
  elseif squad.alert_index ~= nil then
    squad.alert_index = alert_index
  else
    qerror('Could not find alert index field on squad; DF/DFHack version mismatch')
  end
end

local function assign_group_alert(squads_by_name, names, alert_idx)
  for _,wanted in ipairs(names) do
    local sq = squads_by_name[wanted]
    if sq then
      set_squad_alert(sq, alert_idx)
      dfhack.println(('Set "%s" to alert index %d'):format(wanted, alert_idx))
    else
      dfhack.printerr(('Squad "%s" not found (spelling must match).'):format(wanted))
    end
  end
end

local function do_flip()
  local idxA = find_alert_index_by_name(alertA_name)
  local idxB = find_alert_index_by_name(alertB_name)
  if not idxA or not idxB then
    qerror(('Could not find alerts %q and/or %q. Create them in the military→alerts screen.')
      :format(alertA_name, alertB_name))
  end

  local squads_by_name = list_squads_by_name()

  -- Decide month parity: even months -> A trains; odd months -> B trains (customize if you like)
  local month = dfhack.world.ReadCurrentMonth() -- 0..11
  local even = (month % 2) == 0

  if even then
    -- Even month: Group A on Train-A, Group B on Train-B
    assign_group_alert(squads_by_name, groupA, idxA)
    assign_group_alert(squads_by_name, groupB, idxB)
    dfhack.println(('Month %d: GroupA→%s, GroupB→%s'):format(month+1, alertA_name, alertB_name))
  else
    -- Odd month: swap
    assign_group_alert(squads_by_name, groupA, idxB)
    assign_group_alert(squads_by_name, groupB, idxA)
    dfhack.println(('Month %d: GroupA→%s, GroupB→%s'):format(month+1, alertB_name, alertA_name))
  end
end

local function start()
  -- Run immediately once so current month is correct
  do_flip()
  -- Then schedule monthly
  dfhack.run_command('repeat', '-name', repeat_name, '-time', '1', '-timeUnits', 'months',
                     '-command', 'lua', 'script', 'run', 'rotate_training', 'once')
  dfhack.println('Rotation started (will flip every in-game month).')
end

local function stop()
  dfhack.run_command('repeat', '-cancel', repeat_name)
  dfhack.println('Rotation stopped.')
end

local function status()
  local info = dfhack.run_command_silent('repeat', '-list')
  local active = info:find(repeat_name, 1, true) ~= nil
  dfhack.println(('Repeat job "%s": %s'):format(repeat_name, active and 'ACTIVE' or 'not running'))
  dfhack.println(('Alerts looked for: %s, %s'):format(alertA_name, alertB_name))
  dfhack.println(('GroupA squads: %s'):format(table.concat(groupA, ', ')))
  dfhack.println(('GroupB squads: %s'):format(table.concat(groupB, ', ')))
end

-- --------------- entrypoint ----------------

local mode = ({...})[1]
if mode == 'start' then
  start()
elseif mode == 'stop' then
  stop()
elseif mode == 'once' then
  do_flip()
elseif mode == 'status' then
  status()
else
  dfhack.println([[
rotate_training: rotate squads between two alerts monthly.

Commands:
  rotate_training start    - start monthly rotation (and flip now)
  rotate_training stop     - stop rotation
  rotate_training once     - do one flip right now (no scheduler)
  rotate_training status   - show config and whether the scheduler is active

Configure:
  - Create alerts named "Train-A" and "Train-B" in military→alerts.
  - Edit this script's `groupA` and `groupB` tables to match your squad names exactly.
]])
end
