 
 
 
 
 
local nonhuman_retry = (function()
    local helper = {}

    function helper.ready(plan, now)
        return plan ~= nil and config.enabled and not scene_transition.active
            and not normal_runtime_menu_suspended and now >= plan.next_check
    end

     
    local function slow_interval()
        local value = tonumber(config.inspect_interval) or 1.0
        if value ~= value or value == math.huge or value == -math.huge then value = 1.0 end
        return math.max(0.5, value)
    end

    function helper.defer(plan, state, detail, now, limit, checks)
        local slow = checks >= limit
        plan.next_check = now + (slow and slow_interval() or 0.05)
        state.status, state.detail = "pending", tostring(detail or "not ready")
        state.checks, state.retry_mode = plan.checks, slow and "throttled" or "initial"
    end
    return helper
end)()
