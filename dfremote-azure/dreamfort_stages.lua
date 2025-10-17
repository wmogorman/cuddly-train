-- dreamfort_stages.lua
-- Helper for running Dreamfort quickfort blueprints in curated stages.
-- Usage:
--   dreamfort_stages list
--   dreamfort_stages describe <stage>
--   dreamfort_stages run [--dry-run|--orders-only|--skip-orders] <stage|category|all> [...]
-- Place the DF cursor on the Dreamfort central stairs tile before running build stages.

local function detect_dreamfort_file()
  local base_path = dfhack.getDFPath and dfhack.getDFPath() or '.'
  local candidates = {
    {cmd = 'library/dreamfort.csv', path = 'data/blueprints/library/dreamfort.csv'},
    {cmd = 'dreamfort.csv', path = 'data/blueprints/dreamfort.csv'},
    {cmd = 'dreamfort', path = 'data/blueprints/dreamfort.csv'},
  }
  for _, candidate in ipairs(candidates) do
    local full_path = base_path .. '/' .. candidate.path
    local f = io.open(full_path, 'r')
    if f then
      f:close()
      return candidate.cmd
    end
  end
  return 'dreamfort'
end

local DREAMFORT_FILE = detect_dreamfort_file()
local LOG_PREFIX = '[dreamfort_stages] '

local CATEGORY_DISPLAY_NAMES = {
  prep = 'Preparation',
  core = 'Core Fort',
  mature = 'Mature Fort',
}

local blueprint_notice_printed = false

local function tagset(list)
  if not list or #list == 0 then
    return nil
  end
  local set = {}
  for _, tag in ipairs(list) do
    set[string.lower(tag)] = true
  end
  return set
end

local function clone_labels(list)
  if not list then return nil end
  local copy = {}
  for i, v in ipairs(list) do
    copy[i] = v
  end
  return copy
end

local STAGES = {
  setup_help = {
    category = 'prep',
    title = 'Setup Help Notes',
    description = 'Display Dreamfort setup guidance and suggested automation toggles.',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/setup_help'}, tags = tagset{'info'}},
    },
    notes = {
      'This prints the Dreamfort setup walkthrough to the DFHack console.',
      'No designations or buildings are created.',
    },
  },
  queue_core_orders = {
    category = 'prep',
    title = 'Queue Early Manager Orders',
    description = 'Generate manager orders for initial surface and industry blueprints.',
    optional = true,
    actions = {
      {
        type = 'quickfort',
        command = 'orders',
        labels = {'/surface2','/farming2','/surface3','/industry2','/surface4','/industry3'},
        tags = tagset{'orders'},
      },
    },
    notes = {
      'Equivalent to pressing "o" in gui/quickfort for the listed blueprints.',
      'You can safely rerun this stage; duplicate orders are not enqueued.',
    },
  },
  preview_perimeter = {
    category = 'prep',
    title = 'Preview Surface Perimeter',
    description = 'Show the eventual fortress perimeter without applying it.',
    actions = {
      {
        type = 'quickfort',
        command = 'run',
        labels = {'/perimeter'},
        dry_run = true,
        tags = tagset{'preview'},
      },
      {
        type = 'note',
        text = 'Use this preview to align Dreamfort on the surface. The blueprint is not applied.',
      },
    },
  },
  surface1 = {
    category = 'core',
    title = 'Surface Stage 1',
    description = 'Clear initial trees, pen livestock, and dig the central stairs.',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/surface1'}},
      {
        type = 'note',
        text = 'After running, dig down until you locate a rock layer for the industry level.',
      },
    },
    notes = {'Place the cursor on the center tile of the 3x3 stairwell before running.'},
  },
  dig_all = {
    category = 'core',
    title = 'Dig Core Levels',
    description = 'Designate industry, services, guildhall, suites, apartments, and crypt levels.',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/dig_all'}},
    },
    notes = {
      'Run this once you have a non-aquifer rock layer for the industry level.',
      'If caverns interrupt, run the level-specific dig blueprints instead.',
    },
  },
  farming1 = {
    category = 'core',
    title = 'Dig Farming Level',
    description = 'Designate the farming level once surface vents are channeled.',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/farming1'}},
    },
  },
  farming2 = {
    category = 'core',
    title = 'Build Farming Level',
    description = 'Place workshops, stockpiles, and furniture on the farming level.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/farming2'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/farming2'}},
    },
    notes = {'Run immediately after the farming level is fully dug out.'},
  },
  surface3 = {
    category = 'core',
    title = 'Surface Stage 3',
    description = 'Cover miasma vents and armor the central staircase.',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/surface3'}},
    },
  },
  industry2 = {
    category = 'core',
    title = 'Industry Buildout (Phase 1)',
    description = 'Build stockpiles and high-priority industry workshops.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/industry2'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/industry2'}},
    },
    notes = {'Shift production from temporary surface workshops as these complete.'},
  },
  surface4 = {
    category = 'core',
    title = 'Surface Stage 4',
    description = 'Finish staircase protection and lay supporting floors.',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/surface4'}},
    },
  },
  industry3 = {
    category = 'core',
    title = 'Industry Buildout (Phase 2)',
    description = 'Build the remaining industry workshops.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/industry3'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/industry3'}},
    },
  },
  orders_basic = {
    category = 'core',
    title = 'Import Basic Orders',
    description = 'Load the basic automated work orders profile.',
    optional = true,
    actions = {
      {type = 'command', args = {'orders', 'import', 'library/basic'}, tags = tagset{'orders'}},
    },
    notes = {'Run after the first migrant wave so labor exists to satisfy orders.'},
  },
  services2 = {
    category = 'core',
    title = 'Services Level (Phase 1)',
    description = 'Zone minimally functional dining, hospital, and well.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/services2'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/services2'}},
    },
    notes = {'Ensure well cistern plumbing is underway or ready before queueing this.'},
  },
  surface5 = {
    category = 'core',
    title = 'Surface Stage 5',
    description = 'Construct drawbridges, furniture, and trade depot stockpile.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/surface5'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/surface5'}},
    },
  },
  surface6 = {
    category = 'core',
    title = 'Surface Stage 6',
    description = 'Complete walls, floors, and trap defenses.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/surface6'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/surface6'}},
    },
  },
  surface7 = {
    category = 'core',
    title = 'Surface Stage 7',
    description = 'Build the main roof over the surface courtyard.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/surface7'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/surface7'}},
    },
    notes = {'Ensure enough dwarves are idle to build the roof before running this stage.'},
  },
  orders_furnace = {
    category = 'mature',
    title = 'Import Furnace Orders',
    description = 'Enable automated furnace production orders.',
    optional = true,
    actions = {
      {type = 'command', args = {'orders', 'import', 'library/furnace'}, tags = tagset{'orders'}},
    },
  },
  guildhall2_default = {
    category = 'mature',
    title = 'Guildhall Level (Default Furnishings)',
    description = 'Build library, temple, and guildhall foundations with default furniture.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/guildhall2_default'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/guildhall2_default'}},
    },
    aliases = {'guildhall2'},
    notes = {'Use variant stages for custom furnishing workflows if desired.'},
  },
  guildhall2_no_locations = {
    category = 'mature',
    title = 'Guildhall Level (No Locations)',
    description = 'Zones rooms without creating temple or library locations.',
    optional = true,
    variant_of = 'guildhall2_default',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/guildhall2_no_locations'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/guildhall2_no_locations'}},
    },
  },
  guildhall2_custom = {
    category = 'mature',
    title = 'Guildhall Level (Custom Furnishings)',
    description = 'Places only doors and zones so you can furnish by hand.',
    optional = true,
    variant_of = 'guildhall2_default',
    actions = {
      {type = 'quickfort', command = 'run', labels = {'/guildhall2_custom'}},
    },
  },
  services3 = {
    category = 'mature',
    title = 'Services Level (Phase 2)',
    description = 'Upgrade dining hall, hospital, and jail furnishings.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/services3'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/services3'}},
    },
  },
  apartments2 = {
    category = 'mature',
    title = 'Apartments Level',
    description = 'Zone and furnish dwarf apartments.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/apartments2'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/apartments2'}},
    },
    aliases = {'apartments'},
  },
  suites2_default = {
    category = 'mature',
    title = 'Suites Level (Default Zones)',
    description = 'Furnish noble suites, set traffic, and assign zones.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/suites2_default'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/suites2_default'}},
    },
    aliases = {'suites2'},
  },
  suites2_no_zones = {
    category = 'mature',
    title = 'Suites Level (No Zones)',
    description = 'Places furniture but skips noble zone assignments.',
    optional = true,
    variant_of = 'suites2_default',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/suites2_no_zones'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/suites2_no_zones'}},
    },
  },
  crypt2 = {
    category = 'mature',
    title = 'Crypt Level (Base)',
    description = 'Build and zone the starter crypt.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/crypt2'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/crypt2'}},
    },
    aliases = {'crypt'},
  },
  surface8 = {
    category = 'mature',
    title = 'Surface Stage 8',
    description = 'Extend trap corridors outside the main gate.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/surface8'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/surface8'}},
    },
    optional = true,
  },
  farming3 = {
    category = 'mature',
    title = 'Farming Level Doors',
    description = 'Install interior doors that were deferred earlier.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/farming3'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/farming3'}},
    },
  },
  orders_military = {
    category = 'mature',
    title = 'Import Military Orders',
    description = 'Queue automated military equipment production.',
    optional = true,
    actions = {
      {type = 'command', args = {'orders', 'import', 'library/military'}, tags = tagset{'orders'}},
    },
  },
  orders_smelting = {
    category = 'mature',
    title = 'Import Smelting Orders',
    description = 'Queue automated bar production orders.',
    optional = true,
    actions = {
      {type = 'command', args = {'orders', 'import', 'library/smelting'}, tags = tagset{'orders'}},
    },
  },
  services4 = {
    category = 'mature',
    title = 'Services Level (Phase 3)',
    description = 'Complete dining hall, hospital, and jail furnishings.',
    actions = {
      {type = 'quickfort', command = 'orders', labels = {'/services4'}, tags = tagset{'orders'}},
      {type = 'quickfort', command = 'run', labels = {'/services4'}},
    },
  },
  orders_rockstock = {
    category = 'mature',
    title = 'Import Rock Furniture Orders',
    description = 'Maintain stockpiles of rock furniture for future projects.',
    optional = true,
    actions = {
      {type = 'command', args = {'orders', 'import', 'library/rockstock'}, tags = tagset{'orders'}},
    },
  },
  orders_glassstock = {
    category = 'mature',
    title = 'Import Glass Orders',
    description = 'Maintain glass furniture stockpiles (requires access to sand).',
    optional = true,
    actions = {
      {type = 'command', args = {'orders', 'import', 'library/glassstock'}, tags = tagset{'orders'}},
    },
    notes = {'Skip this if your embark lacks sand.'},
  },
}

local STAGE_ORDER = {
  'setup_help',
  'queue_core_orders',
  'preview_perimeter',
  'surface1',
  'dig_all',
  'farming1',
  'farming2',
  'surface3',
  'industry2',
  'surface4',
  'industry3',
  'orders_basic',
  'services2',
  'surface5',
  'surface6',
  'surface7',
  'orders_furnace',
  'guildhall2_default',
  'services3',
  'apartments2',
  'suites2_default',
  'crypt2',
  'surface8',
  'farming3',
  'orders_military',
  'orders_smelting',
  'services4',
  'orders_rockstock',
  'orders_glassstock',
}

local alias_map = {}
for id, stage in pairs(STAGES) do
  alias_map[string.lower(id)] = id
  if stage.aliases then
    for _, alias in ipairs(stage.aliases) do
      alias_map[string.lower(alias)] = id
    end
  end
end

local function normalize_stage_name(name)
  local cleaned = string.lower(tostring(name or ''))
  cleaned = cleaned:gsub('^/*', '')
  cleaned = cleaned:gsub('%s+', '')
  return cleaned
end

local function resolve_stage(name)
  local key = normalize_stage_name(name)
  return alias_map[key]
end

local function action_to_string(action)
  if action.type == 'quickfort' then
    local parts = {'quickfort', action.command or 'run', action.file or DREAMFORT_FILE}
    local labels = action.labels
    if labels and #labels > 0 then
      table.insert(parts, '-n')
      table.insert(parts, table.concat(labels, ','))
    end
    if action.dry_run then
      table.insert(parts, '--dry-run')
    end
    if action.extra_args then
      for _, arg in ipairs(action.extra_args) do
        table.insert(parts, arg)
      end
    end
    return table.concat(parts, ' ')
  elseif action.type == 'command' then
    return table.concat(action.args or {}, ' ')
  elseif action.type == 'note' then
    return action.text or ''
  end
  return '<unknown action>'
end

local function print_usage()
  dfhack.println([[
dreamfort_stages: orchestrate Dreamfort quickfort stages.

Commands:
  dreamfort_stages list
  dreamfort_stages describe <stage>
  dreamfort_stages run [--dry-run|--orders-only|--skip-orders] <stage|category|all> [...]

Categories: prep, core, mature. Use "all" to execute every stage sequentially.
]])
end

local function get_stages_for_category(category)
  local cat = string.lower(category)
  local ids = {}
  for _, id in ipairs(STAGE_ORDER) do
    if STAGES[id] and STAGES[id].category == cat then
      table.insert(ids, id)
    end
  end
  for id, stage in pairs(STAGES) do
    if stage.category == cat then
      local already = false
      for _, existing in ipairs(ids) do
        if existing == id then
          already = true
          break
        end
      end
      if not already then
        table.insert(ids, id)
      end
    end
  end
  return ids
end

local function list_stages()
  local listed = {}
  for _, id in ipairs(STAGE_ORDER) do
    listed[id] = true
  end

  for _, category in ipairs({'prep','core','mature'}) do
    local header = CATEGORY_DISPLAY_NAMES[category] or category
    dfhack.println(header .. ':')
    for _, id in ipairs(STAGE_ORDER) do
      local stage = STAGES[id]
      if stage and stage.category == category then
        local optional_text = stage.optional and ' (optional)' or ''
        dfhack.println(string.format('  %s%s - %s', id, optional_text, stage.description))
      end
    end
    for id, stage in pairs(STAGES) do
      if stage.category == category and not listed[id] then
        local label = string.format('  %s (variant of %s)%s - %s',
          id,
          stage.variant_of or 'n/a',
          stage.optional and ' (optional)' or '',
          stage.description or '')
        dfhack.println(label)
      end
    end
    dfhack.println('')
  end
end

local function describe_stage(id)
  local stage = STAGES[id]
  if not stage then
    dfhack.printerr(LOG_PREFIX .. 'Unknown stage id: ' .. tostring(id))
    return
  end
  dfhack.println(string.format('%s (%s)%s',
    stage.title or id,
    CATEGORY_DISPLAY_NAMES[stage.category] or stage.category,
    stage.optional and ' [optional]' or ''))
  dfhack.println(stage.description or '')
  if stage.variant_of then
    dfhack.println('Variant of: ' .. stage.variant_of)
  end
  if stage.aliases and #stage.aliases > 0 then
    dfhack.println('Aliases: ' .. table.concat(stage.aliases, ', '))
  end
  dfhack.println('')
  dfhack.println('Actions:')
  for index, action in ipairs(stage.actions) do
    local tags = action.tags
    local tag_text = ''
    if tags then
      local list = {}
      for tag, value in pairs(tags) do
        if value then table.insert(list, tag) end
      end
      if #list > 0 then
        table.sort(list)
        tag_text = ' [' .. table.concat(list, ',') .. ']'
      end
    end
    dfhack.println(string.format('  %d) %s%s', index, action_to_string(action), tag_text))
  end
  if stage.notes and #stage.notes > 0 then
    dfhack.println('')
    dfhack.println('Notes:')
    for _, note in ipairs(stage.notes) do
      dfhack.println('  - ' .. note)
    end
  end
end

local function should_run_action(action, opts)
  local tags = action.tags
  if opts.orders_only and (not tags or not tags.orders) then
    return false, 'skipping non-order action (--orders-only)'
  end
  if opts.skip_orders and tags and tags.orders then
    return false, 'skipping order action (--skip-orders)'
  end
  if opts.dry_run and action.type == 'command' then
    return false, 'skipping external command in dry-run mode'
  end
  return true
end

local function run_quickfort_action(action, opts)
  local args = {'quickfort', action.command or 'run', action.file or DREAMFORT_FILE}
  if action.labels and #action.labels > 0 then
    table.insert(args, '-n')
    table.insert(args, table.concat(action.labels, ','))
  end
  if action.dry_run or opts.dry_run then
    table.insert(args, '--dry-run')
  end
  if action.extra_args then
    for _, arg in ipairs(action.extra_args) do
      table.insert(args, arg)
    end
  end
  dfhack.println(LOG_PREFIX .. table.concat(args, ' '))
  local ok, out = dfhack.run_command_silent(table.unpack(args))
  if type(out) == 'string' and #out > 0 then
    dfhack.println(out)
  elseif type(out) == 'table' then
    for _, line in ipairs(out) do
      dfhack.println(line)
    end
  elseif type(out) == 'number' then
    if out ~= 0 then
      dfhack.println(tostring(out))
    end
  elseif out ~= nil and out ~= '' then
    dfhack.println(tostring(out))
  end
  return ok
end

local function run_command_action(action)
  local args = action.args or {}
  dfhack.println(LOG_PREFIX .. table.concat(args, ' '))
  local ok, out = dfhack.run_command_silent(table.unpack(args))
  if type(out) == 'string' and #out > 0 then
    dfhack.println(out)
  elseif type(out) == 'table' then
    for _, line in ipairs(out) do
      dfhack.println(line)
    end
  elseif type(out) == 'number' then
    if out ~= 0 then
      dfhack.println(tostring(out))
    end
  elseif out ~= nil and out ~= '' then
    dfhack.println(tostring(out))
  end
  return ok
end

local function execute_action(action, opts)
  if action.type == 'quickfort' then
    return run_quickfort_action(action, opts)
  elseif action.type == 'command' then
    return run_command_action(action)
  elseif action.type == 'note' then
    dfhack.println(LOG_PREFIX .. (action.text or ''))
    return true
  end
  dfhack.printerr(LOG_PREFIX .. 'Encountered unsupported action type: ' .. tostring(action.type))
  return false
end

local function run_stage(id, opts)
  local stage = STAGES[id]
  if not stage then
    dfhack.printerr(LOG_PREFIX .. 'Unknown stage id: ' .. tostring(id))
    return false
  end
  if not blueprint_notice_printed then
    dfhack.println(string.format('%sUsing blueprint workbook: %s', LOG_PREFIX, DREAMFORT_FILE))
    blueprint_notice_printed = true
  end
  dfhack.println(string.format('%sRunning stage %s: %s', LOG_PREFIX, id, stage.title or stage.description or ''))
  local any_ran = false
  for _, action in ipairs(stage.actions) do
    local should_run, reason = should_run_action(action, opts)
    if should_run then
      any_ran = true
      local ok = execute_action(action, opts)
      if not ok then
        dfhack.printerr(LOG_PREFIX .. 'Stage failed; aborting remaining actions.')
        return false
      end
    elseif reason then
      dfhack.println(LOG_PREFIX .. reason)
    end
  end
  if not any_ran and opts.orders_only then
    dfhack.println(LOG_PREFIX .. 'No order-producing actions in this stage.')
  end
  return true
end

local function collect_stage_ids(arguments)
  local ids = {}
  for _, raw in ipairs(arguments) do
    local token = normalize_stage_name(raw)
    if token == 'all' then
      for _, id in ipairs(STAGE_ORDER) do
        table.insert(ids, id)
      end
    elseif CATEGORY_DISPLAY_NAMES[token] or token == 'prep' or token == 'core' or token == 'mature' then
      local cat_ids = get_stages_for_category(token)
      for _, id in ipairs(cat_ids) do
        table.insert(ids, id)
      end
    else
      local resolved = resolve_stage(token)
      if not resolved then
        dfhack.printerr(LOG_PREFIX .. 'Unknown stage or category: ' .. raw)
      else
        table.insert(ids, resolved)
      end
    end
  end
  return ids
end

local function dedupe_preserve_order(list)
  local seen = {}
  local result = {}
  for _, value in ipairs(list) do
    if value and not seen[value] then
      seen[value] = true
      table.insert(result, value)
    end
  end
  return result
end

local args = {...}
if #args == 0 or args[1] == 'help' then
  print_usage()
  return
end

local command = string.lower(args[1])

if command == 'list' then
  list_stages()
  return
elseif command == 'describe' then
  if not args[2] then
    dfhack.printerr(LOG_PREFIX .. 'Specify a stage to describe.')
    return
  end
  local stage_id = resolve_stage(args[2]) or normalize_stage_name(args[2])
  if not STAGES[stage_id] then
    dfhack.printerr(LOG_PREFIX .. 'Unknown stage: ' .. tostring(args[2]))
    return
  end
  describe_stage(stage_id)
  return
elseif command == 'run' then
  local opts = {dry_run = false, orders_only = false, skip_orders = false}
  local stage_args = {}
  for i = 2, #args do
    local arg = args[i]
    if arg == '--dry-run' then
      opts.dry_run = true
    elseif arg == '--orders-only' then
      opts.orders_only = true
    elseif arg == '--skip-orders' then
      opts.skip_orders = true
    elseif arg == '--' then
      for j = i + 1, #args do
        table.insert(stage_args, args[j])
      end
      break
    else
      table.insert(stage_args, arg)
    end
  end

  if #stage_args == 0 then
    dfhack.printerr(LOG_PREFIX .. 'Specify at least one stage, category, or "all".')
    return
  end

  local stage_ids = dedupe_preserve_order(collect_stage_ids(stage_args))
  if #stage_ids == 0 then
    dfhack.printerr(LOG_PREFIX .. 'No valid stages resolved from arguments.')
    return
  end

  for _, id in ipairs(stage_ids) do
    local ok = run_stage(id, opts)
    if not ok then
      return
    end
  end
  dfhack.println(LOG_PREFIX .. 'Completed requested stages.')
  return
else
  dfhack.printerr(LOG_PREFIX .. 'Unknown command: ' .. tostring(command))
  print_usage()
end
