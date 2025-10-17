-- list_blocked_practice.lua (v2 - robust)
-- Prints name + profession for citizens who currently have a negative mood
-- due to being unable to practice a martial skill or a craft.
-- It matches thought/need names by *strings* only (no enum indexing),
-- so it won't crash if some enums aren't present in your DFHack build.
--
-- Usage:
--   list_blocked_practice
--   list_blocked_practice --detail

local args = {...}
local DETAIL = (args[1] == '--detail')
local units = dfhack.units

local function call_bool(fn, ...)
  if type(fn) ~= 'function' then return nil end
  local ok, res = pcall(fn, ...)
  if ok then
    return res and true or false
  end
  return nil
end

local function is_citizen_dwarf(u)
  if not u then return false end

  local alive = call_bool(units.isAlive, u)
  if alive ~= nil then
    if not alive then return false end
  else
    local is_dead = call_bool(units.isDead, u)
    if is_dead then return false end
  end

  if call_bool(units.isGhost, u) then return false end
  if call_bool(units.isMerchant, u) then return false end
  if call_bool(units.isForest, u) then return false end

  local is_citizen = call_bool(units.isCitizen, u)
  if is_citizen ~= nil then
    if not is_citizen then return false end
  else
    local fort_entity = df.global.plotinfo.main
      and df.global.plotinfo.main.fortress_entity
    if not fort_entity or u.civ_id ~= fort_entity.id then return false end
  end

  local is_dwarf = call_bool(units.isDwarf, u)
  if is_dwarf ~= nil then
    return is_dwarf
  end

  return (u.race == df.global.ui.race_id)
end

local function unit_name(u)
  return dfhack.TranslateName(dfhack.units.getVisibleName(u))
end

local function prof_name(u)
  return dfhack.units.getProfessionName(u)
end

-- Case-insensitive substring match
local function has(lstr, pat)
  return lstr:find(pat, 1, true) ~= nil
end

-- Does this thought look like "unable to practice a martial art or a craft"?
local function thought_matches_martial_or_craft(thought_id)
  if not thought_id then return false, nil end
  local label = tostring(df.unit_thought_type[thought_id] or '')
  local l = label:lower()
  -- Look for "unable"/"couldn't" + ("martial"/"combat" OR "craft"/"artisan")
  local unable = (l:find('unable', 1, true) ~= nil) or (l:find('couldn', 1, true) ~= nil)
  local is_martial = (l:find('martial', 1, true) ~= nil) or (l:find('combat', 1, true) ~= nil)
  local is_craft   = (l:find('craft',   1, true) ~= nil) or (l:find('artisan',1, true) ~= nil)
  if unable and (is_martial or is_craft) then
    return true, label
  end
  return false, nil
end

-- Need name string match for practice-martial/craft; treat focus_level < 0 as negative
local function need_matches_martial_or_craft(need)
  if not need then return false, nil end
  local label = tostring(df.unit_need_type[need.id] or '')
  local l = label:lower()
  local is_martial = (l:find('martial',1,true) ~= nil) or (l:find('combat',1,true) ~= nil)
  local is_craft   = (l:find('craft',  1,true) ~= nil) or (l:find('artisan',1,true) ~= nil)
  if (is_martial or is_craft) and (need.focus_level or 0) < 0 then
    return true, label
  end
  return false, nil
end

local function has_negative_practice_emotion(u)
  local soul = u.status.current_soul
  if not soul or not soul.personality then return false, nil end
  local ems = soul.personality.emotions
  if not ems then return false, nil end
  for _,e in ipairs(ems) do
    local ok, label = thought_matches_martial_or_craft(e.thought)
    if ok then
      -- Treat any matching thought as negative; severity>0 heuristic to be safe
      if (e.severity or 0) > 0 then
        return true, ('emotion:'..label)
      end
    end
  end
  return false, nil
end

local function has_negative_practice_need(u)
  local soul = u.status.current_soul
  if not soul or not soul.personality then return false, nil end
  local needs = soul.personality.needs
  if not needs then return false, nil end
  for _,n in ipairs(needs) do
    local ok, label = need_matches_martial_or_craft(n)
    if ok then
      return true, ('need:'..label)
    end
  end
  return false, nil
end

local function run()
  local any = false
  for _,u in ipairs(df.global.world.units.active) do
    if is_citizen_dwarf(u) then
      local hit1, why1 = has_negative_practice_emotion(u)
      local hit2, why2 = has_negative_practice_need(u)
      if hit1 or hit2 then
        any = true
        if DETAIL then
          dfhack.println(('%s - %s  [%s%s%s]'):format(
            unit_name(u), prof_name(u),
            hit1 and why1 or '',
            (hit1 and hit2) and ', ' or '',
            hit2 and why2 or ''
          ))
        else
          dfhack.println(('%s - %s'):format(unit_name(u), prof_name(u)))
        end
      end
    end
  end
  if not any then
    dfhack.println('No dwarves currently flagged for blocked martial/craft practice.')
  end
end

run()
