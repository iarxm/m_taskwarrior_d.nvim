local M = {}
M.checkbox_pattern = {
  lua = "([%-%*%+]) (%[([%sx~%>])%])",
  vim = "([\\-\\*\\+]) (\\[([\\sx~>])\\])",
}
M.id_pattern = { vim = "(\\$id{([0-9a-fA-F\\-]\\+)})", lua = "(%$id@([0-9a-fA-F$-]+)@)" }
M.task_pattern = {
  lua = M.checkbox_pattern.lua .. " (.*) " .. M.id_pattern.lua,
  vim = M.checkbox_pattern.vim .. " (.*) " .. M.id_pattern.vim,
}
M.task = require("m_taskwarrior_d.task")

function M.convert_timestamp_utc_local(timestamp_utc)
  local year = tonumber(string.sub(timestamp_utc, 1, 4))
  local month = tonumber(string.sub(timestamp_utc, 5, 6))
  local day = tonumber(string.sub(timestamp_utc, 7, 8))
  local hour = tonumber(string.sub(timestamp_utc, 10, 11))
  local min = tonumber(string.sub(timestamp_utc, 12, 13))
  local sec = tonumber(string.sub(timestamp_utc, 14, 15))

  -- Convert UTC time to local time
  local utc_time = os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = sec, dst = true })
  -- Get the local timezone offset in seconds
  local local_tz_offset = os.time() - os.time(os.date("!*t"))

  -- Check if the local timezone is currently observing daylight saving time
  local local_time = os.date("*t", os.time())
  local local_dst = local_time.isdst

  -- Adjust the offset if daylight saving time is in effect
  if local_dst then
    local_tz_offset = local_tz_offset + 3600 -- Add an hour for daylight saving time
  end

  -- Convert UTC time to local time by adding the timezone offset
  return os.date("*t", utc_time + local_tz_offset) -- Convert UTC time to local time
end

function M.encode_patterns(str)
  local lua_pattern = str:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?%s%>]", "%%%1")
  lua_pattern = lua_pattern:gsub(" ", "%s")
  local vim_regex = str:gsub("[\\%*\\.\\[\\^\\$\\(\\)\\|\\?\\+\\s\\-]", "\\%1")
  vim_regex = str:gsub(" ", "\\s")
  return { lua = lua_pattern, vim = vim_regex }
end

function M.set_config(opts)
  M.ns_due_id = vim.api.nvim_create_namespace("due")
  for k, v in pairs(opts) do
    M[k] = v
  end
end

function M.trim(st)
  return st:match("^%s*(.*%S)") or ""
end

local function count_leading_spaces(line)
  if line == nil then
    return nil
  end
  local count = 0
  for i = 1, #line do
    if line:sub(i, i) == " " then
      count = count + 1
    else
      break
    end
  end
  return count
end

function M.get_line(line_number)
  -- Get the current line number if not provided
  if line_number == nil then
    line_number = vim.api.nvim_win_get_cursor(0)[1]
  end

  -- Get the current line content
  local current_line = vim.api.nvim_buf_get_lines(0, line_number - 1, line_number, false)[1]
  return current_line, line_number
end

function findIndex(table, searchString)
  for i, value in ipairs(table) do
    if value == searchString then
      return i
    end
  end
  return nil -- Return nil if the string is not found in the table
end

function M.contains(table, item)
  if #table == 0 then
    return false
  end
  for _, value in ipairs(table) do
    if value == item then
      return true
    end
  end
  return false
end

function findPair(table, search_key, search_value)
  for key, value in pairs(table) do
    if (search_value ~= nil and search_value == value) or (search_key ~= nil and search_key == key) then
      return key, value
    end
  end
end

local function concat_with_quotes(tbl)
  local result = ""
  for i, v in ipairs(tbl) do
    if i > 1 then
      result = result .. ","
    end
    result = result .. '"' .. v .. '"'
  end
  return result
end

local function calculate_final_status(tasks)
  local pendingCount, activeCount, completedCount, deletedCount = 0, 0, 0, 0
  for _, task in ipairs(tasks) do
    if task.status == "pending" then
      if task["start"] ~= nil then
        activeCount = activeCount + 1
      else
        pendingCount = pendingCount + 1
      end
    elseif task.status == "completed" then
      completedCount = completedCount + 1
    elseif task.status == "deleted" then
      deletedCount = deletedCount + 1
    end
  end
  if pendingCount == #tasks then
    return "pending"
  end
  if completedCount == #tasks or (completedCount > 0 and (completedCount + deletedCount) == #tasks) then
    return "completed"
  end
  if deletedCount == #tasks then
    return "deleted"
  end
  return "active"
end

local function find_pattern_line(pattern)
  -- Get the current buffer number
  pattern = string.gsub(pattern, "%-", "%%-")

  -- Get all lines in the current buffer
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  -- Loop through each line
  for i, line in ipairs(lines) do
    -- Check if the pattern exists in the line
    if string.match(line, pattern) then
      -- Return the line number (1-indexed)
      return i
    end
  end

  -- Pattern not found
  return nil
end

function M.update_related_tasks_statuses(uuid)
  local task_mod = require("m_taskwarrior_d.task")
  local _, result = task_mod.get_blocked_tasks_by(uuid)
  local tasks
  if vim == nil then
    local json = require("cjson")
    tasks = json.decode(result)
  else
    tasks = vim.fn.json_decode(result)
  end
  for _, task in ipairs(tasks) do
    local _, dependencies = task_mod.get_tasks_by(task["depends"])
    local new_status = calculate_final_status(dependencies)
    new_status, _ = findPair(M.status_map, nil, new_status)
    task_mod.modify_task_status(task.uuid, new_status)
    local line_number = find_pattern_line(task.uuid)
    if line_number ~= nil then
      M.toggle_task_status(nil, line_number, new_status)
    end
  end
end

function M.toggle_task_status(current_line, line_number, new_status)
  if current_line == nil then
    current_line, _ = M.get_line(line_number)
  end
  if new_status == nil then
    -- Get the current buffer number
    local _, _, status = string.match(current_line, M.checkbox_pattern.lua)
    if status == nil then
      return nil
    end
    local status_index = findIndex(M.task_statuses, status)
    if status_index == #M.task_statuses then
      new_status = M.task_statuses[1]
    else
      new_status = M.task_statuses[status_index + 1]
    end
  end
  local modified_line =
    string.gsub(current_line, M.status_pattern.lua, M.checkbox_prefix .. new_status .. M.checkbox_suffix)
  -- Set the modified line back to the buffer

  vim.api.nvim_buf_set_lines(0, line_number - 1, line_number, false, { modified_line })
  return new_status
end

function M.add_or_sync_task(line, replace_desc)
  local list_sb, _, status = string.match(line, M.checkbox_pattern.lua)
  local desc = string.gsub(line, M.checkbox_pattern.lua, "")
  local result
  local _, _, uuid = string.match(line, M.id_part_pattern.lua)
  if uuid == nil then
    uuid = require("m_taskwarrior_d.task").add_task(desc)
    result = line:gsub("%s+$", "")
      .. (M.comment_prefix ~= "" and " " .. M.comment_prefix or M.comment_prefix)
      .. " $id{"
      .. uuid
      .. "}"
      .. (M.comment_suffix ~= "" and " " .. M.comment_suffix or M.comment_suffix)
  else
    desc = string.gsub(desc, M.id_part_pattern.lua, "")
    if require("m_taskwarrior_d.task").get_task_by(uuid) == nil then
      line = string.gsub(line, M.id_part_pattern.lua, "")
      uuid = require("m_taskwarrior_d.task").add_task(desc)
      result = line:gsub("%s+$", "")
        .. (M.comment_prefix ~= "" and " " .. M.comment_prefix or M.comment_prefix)
        .. " $id{"
        .. uuid
        .. "}"
        .. (M.comment_suffix ~= "" and " " .. M.comment_suffix or M.comment_suffix)
    else
      local new_task = require("m_taskwarrior_d.task").get_task_by(uuid, "task")
      if new_task then
        local active = false
        if new_task.status == "pending" and new_task["start"] ~= nil then
          active = true
        end
        local new_task_status_sym
        if not active then
          new_task_status_sym, _ = findPair(M.status_map, nil, new_task.status)
        else
          new_task_status_sym = ">"
        end
        status = new_task_status_sym
        uuid = new_task.uuid
        local spaces = count_leading_spaces(line)
        if replace_desc then
          require("m_taskwarrior_d.task").modify_task(uuid, desc)
          result = string.rep(" ", spaces or 0)
            .. list_sb
            .. " "
            .. M.checkbox_prefix
            .. new_task_status_sym
            .. M.checkbox_suffix
            .. " "
            .. M.trim(desc)
            .. (M.comment_prefix ~= "" and " " .. M.comment_prefix or M.comment_prefix)
            .. " $id{"
            .. new_task.uuid
            .. "}"
            .. (M.comment_suffix ~= "" and " " .. M.comment_suffix or M.comment_suffix)
        else
          result = string.rep(" ", spaces or 0)
            .. list_sb
            .. " "
            .. M.checkbox_prefix
            .. new_task_status_sym
            .. M.checkbox_suffix
            .. " "
            .. new_task.description
            .. (M.comment_prefix ~= "" and " " .. M.comment_prefix or M.comment_prefix)
            .. " $id{"
            .. new_task.uuid
            .. "}"
            .. (M.comment_suffix ~= "" and " " .. M.comment_suffix or M.comment_suffix)
        end
      else
        result = line
      end
    end
  end
  require("m_taskwarrior_d.task").modify_task_status(uuid, status)
  return result, uuid
end

function M.extract_uuid(line)
  if line == nil then
    return nil
  end
  local uuid_pattern = M.id_part_pattern.lua
  local _, conceal, uuid = string.match(line, uuid_pattern)
  return conceal, uuid
end

function M.check_dependencies(line_number)
  local current_line, _ = M.get_line(line_number)
  if current_line == nil then
    return nil
  end
  local _, current_uuid = M.extract_uuid(current_line)
  local current_number_of_spaces = count_leading_spaces(current_line)
  local deps = {}
  local count = 1
  local next_line = M.get_line(line_number + 1)
  if next_line == nil then
    return nil, nil
  end
  local next_number_of_spaces = count_leading_spaces(next_line)
  if next_number_of_spaces == nil then
    return nil, nil
  end
  local _, checkbox, _ = string.match(next_line, M.checkbox_pattern.lua)
  if checkbox == nil then
    return nil, nil
  end
  while next_line ~= nil and checkbox ~= nil and current_number_of_spaces < next_number_of_spaces do
    local result, uuid = M.add_or_sync_task(next_line)
    vim.api.nvim_buf_set_lines(0, line_number + count - 1, line_number + count, false, { result })
    table.insert(deps, uuid)
    count = count + 1
    next_line = M.get_line(line_number + count)
    if next_line ~= nil then
      next_number_of_spaces = count_leading_spaces(next_line)
      _, checkbox, _ = string.match(next_line, M.checkbox_pattern.lua)
    end
  end
  return current_uuid, deps
end

function M.sync_task(current_line, line_number)
  local result, _ = M.add_or_sync_task(current_line)
  if result then
    vim.api.nvim_buf_set_lines(0, line_number - 1, line_number, false, { result })
  end
  local current_uuid, deps = M.check_dependencies(line_number)
  if current_uuid ~= nil then
    require("m_taskwarrior_d.task").add_task_deps(current_uuid, deps)
  end
end

function M.build_hierarchy(item, visited, items)
  local dependencies = item.depends
  if not dependencies then
    return { uuid = item.uuid, desc = item.description, status = item.status, tags = item.tags }
  else
    local hierarchy = { uuid = item.uuid, desc = item.description, status = item.status, tags = item.tags }
    for _, dependency in ipairs(dependencies) do
      if not visited[dependency] then
        visited[dependency] = true
        local dependent_item = nil
        for _, v in ipairs(items) do
          if v.uuid == dependency then
            dependent_item = v
            break
          end
        end
        if dependent_item then
          local dependent_hierarchy = M.build_hierarchy(dependent_item, visited, items)
          table.insert(hierarchy, dependent_hierarchy)
        end
      end
    end
    return hierarchy
  end
end

function M.render_tasks(tasks, depth)
  depth = depth or 0
  local markdown = {}
  for _, task in ipairs(tasks) do
    local active = false
    if task.status == "pending" and task["start"] ~= nil then
      active = true
    end
    local new_task_status_sym
    if not active then
      new_task_status_sym, _ = findPair(require("m_taskwarrior_d.utils").status_map, nil, task.status)
    else
      new_task_status_sym = ">"
    end
    table.insert(
      markdown,
      string.rep(" ", vim.opt_local.shiftwidth._value * depth)
        .. M.default_list_symbol
        .. " "
        .. M.checkbox_prefix
        .. new_task_status_sym
        .. M.checkbox_suffix
        .. " "
        .. task.desc
        .. (M.comment_prefix ~= "" and " " .. M.comment_prefix or M.comment_prefix)
        .. " $id{"
        .. task.uuid
        .. "}"
        .. (M.comment_suffix ~= "" and " " .. M.comment_suffix or M.comment_suffix)
    )
    if task[1] then
      local nested_tasks = M.render_tasks(task, depth + 1)
      for _, nested_task in ipairs(nested_tasks) do
        table.insert(markdown, nested_task)
      end
    end
  end
  return markdown
end

function M.apply_context_data(line, line_number)
  local no_of_lines = vim.api.nvim_buf_line_count(0)
  if line_number == no_of_lines then
    return
  end
  local _, _, query = string.match(line, M["task_query_pattern"].lua)
  query = query.gsub(query, "status:.*%s", " ")
  local count = 1
  local uuid = nil
  local tasks = {}
  local next_line, next_line_number = M.get_line(line_number + count)
  _, uuid = M.extract_uuid(next_line)
  if uuid then
    table.insert(tasks, uuid)
  end
  local block_ended = true
  if #next_line == 0 or next_line == " " then
    block_ended = false
  end
  while not block_ended and next_line_number <= no_of_lines do
    count = count + 1
    next_line, next_line_number = M.get_line(line_number + count)
    if next_line_number == no_of_lines or #next_line == 0 or next_line == " " then
      block_ended = true
    end
    _, uuid = M.extract_uuid(next_line)
    if uuid then
      table.insert(tasks, uuid)
    end
  end
  for _, task_uuid in ipairs(tasks) do
    require("m_taskwarrior_d.task").execute_taskwarrior_command("task " .. task_uuid .. " mod " .. query)
  end
end

function M.delete_scoped_tasks(line_number)
  local count = 1
  local start_line = nil
  local end_line = nil
  local no_of_lines = vim.api.nvim_buf_line_count(0)
  if line_number == no_of_lines then
    return
  end
  local next_line, next_line_number = M.get_line(line_number + count)
  if #next_line == 0 or next_line == " " then
    start_line = next_line_number
  else
    vim.api.nvim_buf_set_lines(0, line_number, line_number, false, { "" })
    return
  end
  while end_line == nil and next_line_number < no_of_lines do
    count = count + 1
    next_line, next_line_number = M.get_line(line_number + count)
    local list_sb, _, status = string.match(next_line, M.checkbox_pattern.lua)
    if #next_line > 0 and next_line ~= " " and list_sb == nil then
      end_line = next_line_number - 1
    end
  end
  if end_line == nil then
    end_line = no_of_lines
  end
  vim.api.nvim_buf_set_lines(0, start_line, end_line, false, {})
end

function M.parse_ISO8601_date(iso_date)
  local pattern = "(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z"
  local year, month, day, hour, min, sec = iso_date:match(pattern)

  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
end

function M.render_virtual_due_dates(start_line, end_line)
  if true then
      return nil
  end

  if start_line == nil then
    start_line = 0
    if end_line == nil then
      end_line = -1
    end
  end
  if start_line ~= nil and end_line == nil then
    end_line = -1
  end
  vim.api.nvim_buf_clear_namespace(0, M.ns_due_id, start_line, end_line)
  for i, v in ipairs(vim.api.nvim_buf_get_lines(0, start_line, end_line, false)) do
    local _, uuid = M.extract_uuid(v)
    local task_data = M.task.get_task_by(uuid, "task")
    if task_data ~= nil then
      local due = task_data["due"]
      local scheduled = task_data["scheduled"]
      if due ~= nil or scheduled ~= nil then
        local time_text = ""
        local target_time = os.time()
        if scheduled ~= nil then
          time_text = "Scheduled: "
          target_time = M.parse_ISO8601_date(scheduled)
        end
        if due ~= nil then
          time_text = "Due: "
          target_time = M.parse_ISO8601_date(due)
        end
        local current_time = os.time()
        local time_diff = os.difftime(target_time, current_time)
        local days = math.floor(time_diff / (24 * 3600))
        local hours = math.floor((time_diff % (24 * 3600)) / 3600)
        local minutes = math.floor((time_diff % 3600) / 60)
        local text = {}
        if days > 0 then
          text = { time_text .. string.format("%d days, %d hours left", days, hours), "DueDate" }
        else
          text = { time_text .. string.format("%d hours, %d minutes left", hours, minutes), "DueSoon" }
        end
        -- Display the time difference
        vim.api.nvim_buf_set_extmark(0, M.ns_due_id, i + start_line - 1, 0, {
          virt_text = { text },
          virt_text_pos = "eol", -- Position of the text ('overlay' or 'right_align')
        })
      end
    end
  end
end

return M
