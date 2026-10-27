 
 
 
 
 
 
local nonhuman_forefoot = (function()
    local helper = {}
     
    local max_checks, interval = 20, 0.05
    local native_apply, native_error, native_inspect, native_check
    local metrics = { prepared = 0, applied = 0, skipped = 0, errors = 0,
        checks = 0, native_calls = 0, native_checks = 0, carrier_scans = 0,
        partial = 0, recent = {}, lifecycle = "initial_apply_only", scope = "equipment_parts" }
    performance.nonhuman_forefoot = metrics

    local function read(object, method, ...)
        if not object then return nil end
        local ok, value = safe_call(object, method, ...)
        if ok then return value end
        return nil
    end

    local function address(object)
        if not object then return nil end
        local ok, value = pcall(function() return math.tointeger(object:get_address()) end)
        if ok and value and value > 0 then return value end
        return nil
    end

    local function normalized(path)
        return tostring(path or ""):gsub("\\", "/"):lower():gsub("^@", ""):gsub("%.%d+$", "")
    end

    local function path_of(object, method)
        return normalized(read(read(object, method), "get_ResourcePath"))
    end

    local function record(entry, status, detail, parts)
        entry.nonhuman_forefoot_pending = nil
        entry.nonhuman_forefoot = { status = status, detail = tostring(detail or ""), parts = parts }
        metrics.recent[#metrics.recent + 1] = { generation = scene_generation,
            npc_id = entry.npc_id, status = status, detail = tostring(detail or ""), parts = parts }
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        if status == "applied" then metrics.applied = metrics.applied + 1
        elseif status == "partial" then metrics.partial = metrics.partial + 1
        elseif status == "error" then metrics.errors = metrics.errors + 1
        else metrics.skipped = metrics.skipped + 1 end
        bs_log("[NonhumanForefoot] " .. tostring(entry.npc_id) .. " " .. status .. " " .. tostring(detail))
    end

    local function get_native()
        if native_apply then return native_apply end
        if native_error then return nil, native_error end
        native_error = "native helper unavailable"
        local ok, result = pcall(function()
            assert(_VERSION == "Lua 5.4", "Lua 5.4 required")
            local path = "reframework/plugins/BSFNForefoot.dll"
            local probe = assert(package.loadlib(path, "bsfn_forefoot_probe"))
            assert(probe(0x42534638, 0, 0, 0, 0, 0, 0) == 8, "native argument ABI refused")
            native_check = assert(package.loadlib(path, "bsfn_forefoot_inspect"))
            return assert(package.loadlib(path, "bsfn_forefoot_apply"))
        end)
        if not ok then native_error = tostring(result); return nil, native_error end
        native_apply, native_error = result, nil
        return native_apply
    end

     
    function helper.prepare(candidate, state, entry, bone_data, body_id)
        if not state or not entry or entry.nonhuman_forefoot or not config.enabled
            or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
            or scene_transition.active or normal_runtime_menu_suspended
            or entry.scene_generation ~= scene_generation or bone_data.FixBone == false then return nil end
        local family = nonhuman_family.classify(candidate, state, entry)
        if not family.ik_asset or not family.leg_ok then return nil end
        local desired = resource_path_from_bone_data(bone_data)
        if not desired or normalized(desired) == normalized(state.resource_path) then return nil end
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then return nil end
        local root, motion, skeleton = address(candidate.obj), address(state.motion), address(state.custom_skeleton)
        if not root or not motion or not skeleton or type(body_id) ~= "string" or body_id == "" then return nil end
        metrics.prepared = metrics.prepared + 1
        return { root = root, motion = motion, skeleton = skeleton, body_id = body_id,
            desired = normalized(desired), profile = family.profile, generation = scene_generation,
            dictionary = dictionary_generation, checks = 0, next_check = 0, completed = {} }
    end

    function helper.finish(plan, bone_ok, entry)
        if not plan or not bone_ok then return end
        entry.nonhuman_forefoot_pending = plan
        entry.nonhuman_forefoot = { status = "pending", detail = "waiting for equipment bindings" }
    end

     
     
    local function current_parts(root_transform, body_id)
        local transform = read(root_transform, "get_Child")
        local parts, seen, body_count = {}, {}, 0
        for _ = 1, 32 do
            if not transform then return body_count == 1 and parts or nil end
            local key = address(transform)
            if not key or seen[key] then return nil end
            seen[key] = true
            local object = read(transform, "get_GameObject")
            local name = object and get_game_object_name(object) or ""
            if name == body_id then body_count = body_count + 1 end
            if name == body_id or name:match("^ch0[23]_%d%d%d_%d%d%d[1-5]$") then
                parts[#parts + 1] = { object = object, transform = transform, name = name }
            end
            transform = read(transform, "get_Next")
        end
        return not transform and body_count == 1 and parts or nil
    end

     
     
     
    local function carrier_components(object)
        local custom = get_component(object, "via.motion.CustomSkeleton")
        if custom then
            return "skipped", "independent skeleton rebuild ordering not verified"
        end
        local motion = get_component(object, "via.motion.Motion")
        if motion then
            if read(motion, "get_JointsConstructed") ~= true then
                return "pending", "joints not constructed"
            end
            local active = read(motion, "getActiveMotionBankCount")
            local dynamic = read(motion, "getDynamicMotionBankCount")
            if active ~= 0 or dynamic ~= 0 then
                return "skipped", "authored Motion ordering not verified"
            end
        end
        local constraints = get_component(object, "via.motion.JointConstraints")
        if not constraints then return nil end
        if not native_inspect then
            native_inspect = assert(package.loadlib("reframework/plugins/BSFNForefoot.dll", "bsfn_forefoot_constraint"))
        end
        local count = read(constraints, "getLayerCount")
        if type(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > 16 then
            return "skipped", "constraint layer count unavailable"
        end
        local unchecked_skin, empty_layers = false, 0
        for index = 0, count - 1 do
            local layer = read(constraints, "getLayer", index)
            if not layer then return "pending", "constraint layer not ready" end
            local pointer = address(layer)
            if not pointer then return "skipped", "constraint identity unavailable" end
            local result = native_inspect(0x42534638, pointer, 0, 0, 0, 0, 0)
            if result == 2 then return "pending", "constraint resource/Scene not ready" end
            if result == 30 then return "skipped", "constraint writes foot; ordering not verified" end
             
            if result ~= 0 and result ~= 33 and result ~= 34 then return "skipped", "constraint format not verified; native=" .. tostring(result) end
            if result == 33 then unchecked_skin = true end
            if result == 34 then empty_layers = empty_layers + 1 end
        end
        return nil, nil, unchecked_skin, empty_layers
    end

     
     
    local function apply_part(plan, root, root_transform, part, apply)
        local object, transform = part.object, part.transform
        if not is_valid_managed_object(object) or read(transform, "get_SameJointsConstraint") ~= true
            or not same_runtime_object(read(transform, "get_Parent"), root_transform) then
            return "skipped", "equipment ownership/constraint changed"
        end
        local mesh = part.mesh
        if not mesh or read(mesh, "get_MeshReady") ~= true then return "pending", "equipment Mesh not ready" end
        if read(mesh, "get_HasJoint") == false then return "not_needed", "render mesh has no skeleton" end
        local root_id, object_id, transform_id, mesh_id = address(root_transform), address(object), address(transform), address(mesh)
        if not root_id or not object_id or not transform_id or not mesh_id then return "skipped", "native identity unavailable" end
        metrics.native_checks = metrics.native_checks + 1
        local checked = native_check(0x42534638, plan.root, root_id, object_id, transform_id, mesh_id, 0)
        if checked == 2 then return "pending", "native Scene lock busy; throttled retry" end
        if checked == 3 then return "not_needed", "render skeleton has no forefoot chain" end
        if checked ~= 0 and checked ~= 1 then return "skipped", "native inspection guard=" .. tostring(checked) end
        local status, detail, unchecked_skin, empty_layers = carrier_components(object)
        if status then return status, detail end
        metrics.native_calls = metrics.native_calls + 1
        local result = apply(0x42534638, plan.root, root_id, object_id, transform_id, mesh_id, 0)
        if address(root) ~= plan.root or address(object) ~= object_id or address(mesh) ~= mesh_id then
            return "error", "identity changed across native call"
        end
        if result == 2 then return "pending", "native Scene lock busy; throttled retry" end
        if result ~= 0 and result ~= 1 then return "skipped", "native guard=" .. tostring(result) end
        return "applied", "own render skeleton forefoot mappings; native=" .. result
            .. (unchecked_skin and "; SC_allowed_unverified" or "")
            .. (empty_layers and empty_layers > 0 and "; empty_layers=" .. empty_layers or "")
    end

     
     
    local function update_parts(entry, plan, root, root_transform, apply)
         
        local core = get_component(root, "app.NpcCharacterCore")
        local builder = read(core, "get_PartsBuilder")
        local builder_id = address(builder)
        if not builder_id or read(builder, "get_IsEnd") ~= true then
            plan.completed = {}
            return "pending", "equipment construction not finished"
        end
        if plan.builder ~= builder_id then plan.completed = {}; plan.builder = builder_id end
        local parts = current_parts(root_transform, plan.body_id)
        metrics.carrier_scans = metrics.carrier_scans + 1
        if not parts then return "pending", "equipment children/Body identity not ready" end
        local completed, rows = {}, {}
        local applied, skipped, errors, waiting = 0, 0, 0, 0
        for _, part in ipairs(parts) do
            local object_id, transform_id = address(part.object), address(part.transform)
            if not object_id or not transform_id then return "pending", "equipment identity not ready" end
            part.mesh = get_component(part.object, "via.render.Mesh")
            local key = tostring(object_id) .. ":" .. tostring(transform_id) .. ":" .. tostring(address(part.mesh)) .. ":" .. part.name
            local row = plan.completed[key]
            if not row then
                local ok, status, detail = pcall(apply_part, plan, root, root_transform, part, apply)
                if not ok then detail, status = tostring(status), "error" end
                row = { name = part.name, status = status, detail = tostring(detail or "") }
            end
            rows[#rows + 1] = row
            if row.status == "pending" then waiting = waiting + 1
            else completed[key] = row end
            if row.status == "applied" then applied = applied + 1
            elseif row.status == "skipped" then skipped = skipped + 1
            elseif row.status == "error" then errors = errors + 1 end
        end
        plan.completed = completed
        entry.nonhuman_forefoot.parts = rows
        if read(builder, "get_IsEnd") ~= true or address(read(core, "get_PartsBuilder")) ~= builder_id then
            plan.completed = {}
            return "pending", "equipment construction changed", rows
        end
        if waiting > 0 then
            return "pending", "waiting for equipment render bindings; pending=" .. waiting, rows
        end
        local detail = "equipment render bindings; applied=" .. applied .. "; skipped=" .. skipped .. "; errors=" .. errors
        if skipped + errors > 0 then return applied > 0 and "partial" or (errors > 0 and "error" or "skipped"), detail, rows end
        return applied > 0 and "applied" or "not_needed", detail, rows
    end

    function helper.update(entry, now)
        local plan = entry.nonhuman_forefoot_pending
        if not nonhuman_retry.ready(plan, now) then return end
        plan.checks, plan.next_check = plan.checks + 1, now + interval
        metrics.checks = metrics.checks + 1
        local ok, status, detail, parts = pcall(function()
            if not config.enabled or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
                or scene_transition.active or normal_runtime_menu_suspended or entry.player_character_rejected
                or scene_generation ~= plan.generation or entry.scene_generation ~= plan.generation
                or dictionary_generation ~= plan.dictionary or registered[tostring(entry.character)] ~= entry then
                return "skipped", "lifecycle/configuration changed"
            end
            if now - entry.last_seen > (tonumber(config.readiness_recent_seen_window) or 0.5) then
                return "pending", "NPC no longer recently updated"
            end
            if entry.nonhuman_ik_pending then return "pending", "waiting for target skeleton/IK" end
            if entry.nonhuman_ik and entry.nonhuman_ik.status == "error" then
                return "skipped", "IK application failed; no automatic write retry"
            end
            local root = read(entry.character, "get_GameObject")
            if not is_valid_managed_object(root) or address(root) ~= plan.root then return "skipped", "root changed" end
            local motion, skeleton = get_component(root, "via.motion.Motion"), get_component(root, "via.motion.CustomSkeleton")
            if address(motion) ~= plan.motion or address(skeleton) ~= plan.skeleton
                or path_of(skeleton, "get_SkeletonResourceHandle") ~= plan.desired then return "skipped", "root skeleton changed" end
            if read(motion, "get_JointsConstructed") ~= true then
                return "pending", "waiting for target skeleton/IK"
            end
            local ik = get_component(root, "via.motion.IkLeg2")
            if path_of(ik, "get_IkLeg2Asset") ~= "motion/npc/decorate/ikleg/npcikleg_default.ikleg2" then
                return "skipped", "human IK asset changed or unavailable"
            end
            if read(ik, "get_Setuped") ~= true then return "pending", "human IK not ready" end
            local apply, why = get_native()
            if not apply then return "skipped", why end
            local root_transform = get_transform(root)
            return update_parts(entry, plan, root, root_transform, apply)
        end)
        if not ok then detail, status = tostring(status), "error" end
        if status == "pending" then
            nonhuman_retry.defer(plan, entry.nonhuman_forefoot, detail, now, max_checks, plan.checks)
            return
        end
        record(entry, status, detail, parts)
    end
    return helper
end)()
