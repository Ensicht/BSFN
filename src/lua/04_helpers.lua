 
 
 
 

local function T(key)
    local lang = (config and config.language) or "zh"
    local table_for_lang = Localization[lang] or Localization.zh
    return table_for_lang[key] or Localization.en[key] or tostring(key)
end

local function bs_log(message)
    if config and config.debug_log and log and log.info then
        log.info("[" .. MOD_NAME .. "] " .. tostring(message))
    end
end

local function copy_table(value)
    local out = {}
    for k, v in pairs(value) do
        if type(v) == "table" then
            out[k] = copy_table(v)
        else
            out[k] = v
        end
    end
    return out
end

local function merge_defaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = copy_table(v)
            else
                dst[k] = v
            end
        end
    end
end

local function trim_text(value, max_len)
    local text = tostring(value or "")
    max_len = max_len or 240
    if string.len(text) > max_len then
        return string.sub(text, 1, max_len) .. "..."
    end
    return text
end

local function sanitize_report_value(value, depth)
    depth = depth or 0
    if depth > 16 then
        return trim_text(value, 400)
    end
    local value_type = type(value)
    if value_type == "string" then
        local text = trim_text(value, 2000)
        return (string.gsub(text, "[^\32-\126]", "?"))
    end
    if value_type == "number" or value_type == "boolean" or value == nil then
        return value
    end
    if value_type ~= "table" then
        local text = trim_text(tostring(value), 400)
        return (string.gsub(text, "[^\32-\126]", "?"))
    end
    local out = {}
    for k, v in pairs(value) do
        local key = k
        if type(k) == "string" then
            key = sanitize_report_value(k, depth + 1)
        elseif type(k) ~= "number" then
            key = sanitize_report_value(tostring(k), depth + 1)
        end
        out[key] = sanitize_report_value(v, depth + 1)
    end
    return out
end
local function record_event(kind, detail)
    table.insert(diagnostics.events, { time = os.clock(), kind = tostring(kind or "event"), detail = trim_text(detail, 700) })
    while #diagnostics.events > 80 do
        table.remove(diagnostics.events, 1)
    end
end
