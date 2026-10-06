 
 
 
 

local API = rawget(_G, "BoneSystemNPCAPI")
if type(API) ~= "table" or not rawget(_G, "__BSFNStockBridgeAuthorized") then
    if not rawget(_G, "__BSFNStockBridgeMainStarted") then
        _G.__BSFNStockBridgeMainStarted = true
        local loader, load_error = package.loadlib("reframework/plugins/BSFNStockBridge.dll", "bsfn_bootstrap")
        if loader then
            local ok, err = pcall(loader)
            if not ok then log.error("[BSFNStockBridge] " .. tostring(err)) end
        else
            log.error("[BSFNStockBridge] " .. tostring(load_error))
        end
    end
    return
end
if rawget(_G, "__BoneSystemForNPCLoaded") or rawget(_G, "__BoneSystemForNPCStagedLoaded") then
    return
end
_G.__BoneSystemForNPCLoaded = true
_G.__BoneSystemForNPCStagedLoaded = true
