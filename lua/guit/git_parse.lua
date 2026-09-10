local M = {}

--- Splits a NUL-separated git stream into fields.
--- Git terminates every field with NUL, so the trailing empty field is dropped.
local function nul_fields(output)
  local fields = vim.split(output or '', '\0', { plain = true })
  while #fields > 0 and fields[#fields] == '' do
    fields[#fields] = nil
  end
  return fields
end

local function is_rename_or_copy(status)
  return status:match('^R%d*$') ~= nil or status:match('^C%d*$') ~= nil
end

--- Parses `git diff --name-status -z` output.
---
--- With -z every field is NUL-terminated, so paths containing spaces, tabs,
--- newlines or non-ASCII bytes survive intact (`core.quotePath` never applies).
--- A record is a status field followed by one path, or by two paths when the
--- status is a rename or a copy:
---   M\0path\0                     R100\0old path\0new path\0
---@param output string raw stdout of a `--name-status -z` invocation
---@return table[] items
function M.name_status_z(output)
  local fields = nul_fields(output)
  local items = {}
  local i = 1

  while i <= #fields do
    local status = fields[i]
    i = i + 1

    if status ~= '' then
      local old_path, path
      if is_rename_or_copy(status) then
        old_path = fields[i]
        path = fields[i + 1]
        i = i + 2
      else
        path = fields[i]
        i = i + 1
      end

      if path and path ~= '' then
        items[#items + 1] = {
          status = status,
          path = path,
          old_path = old_path,
          kind = 'file',
          additions = 0,
          deletions = 0,
        }
      end
    end
  end

  return items
end

--- Parses `git diff --numstat -z` output.
---
--- A record is `<additions>\t<deletions>\t` followed by the path. For renames
--- and copies the path is empty in that field and the old and new paths follow
--- as two separate NUL fields:
---   1\t0\tpath\0                  0\t0\t\0old path\0new path\0
--- Both paths are registered as keys so callers can look a file up by either
--- side of a rename without reconstructing git's `{old => new}` brace form.
---@param output string raw stdout of a `--numstat -z` invocation
---@return table stats keyed by path
---@return table total { additions = number, deletions = number }
function M.numstat_z(output)
  local fields = nul_fields(output)
  local stats = {}
  local total = { additions = 0, deletions = 0 }
  local i = 1

  while i <= #fields do
    local add_s, del_s, inline_path = fields[i]:match('^(%S+)\t(%S+)\t(.*)$')
    i = i + 1

    if add_s and del_s then
      -- Binary files report "-" for both counts.
      local entry = {
        additions = tonumber(add_s) or 0,
        deletions = tonumber(del_s) or 0,
      }

      local paths = {}
      if inline_path ~= '' then
        paths[1] = inline_path
      else
        paths[1] = fields[i]
        paths[2] = fields[i + 1]
        i = i + 2
      end

      for _, path in ipairs(paths) do
        if path and path ~= '' then
          stats[path] = entry
        end
      end

      total.additions = total.additions + entry.additions
      total.deletions = total.deletions + entry.deletions
    end
  end

  return stats, total
end

--- Splits the path half of a tab-separated `--name-status` line.
---
--- Git separates the fields with tabs, so splitting on generic whitespace
--- truncates any path containing a space: "old name.txt\tnew.txt" would yield
--- "old" and "name.txt\tnew.txt".
---@param rest string everything after the status field
---@return string|nil old_path
---@return string|nil new_path
function M.rename_paths(rest)
  local parts = vim.split(rest or '', '\t', { plain = true })
  if #parts < 2 then
    return nil, nil
  end
  return parts[1], parts[2]
end

return M
