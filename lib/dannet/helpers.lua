local mq = require('mq')
local Logger = require('utils.logger')

-- This module acts as a thin abstraction over peer-to-peer querying.
-- When MQ2DanNet is available, it uses DanNet. Otherwise it degrades
-- gracefully by returning nil and logging a verbose notice. Callers
-- should already contain local fallbacks (group/raid TLOs, ToT, etc.).

local helpers = {}

local function has_dannet()
    return mq.TLO.Plugin('MQ2DanNet')() == true
end

function helpers.query(peer, query, timeout)
    mq.cmdf('/dquery %s -q "%s"', peer, query)
    if timeout > 0 then
        mq.delay(25)
        mq.delay(timeout or 1000, function() return (mq.TLO.DanNet(peer).Q(query).Received() or 0) > 0 end)
    end
    local value = mq.TLO.DanNet(peer).Q(query)()
    Logger.log_verbose('\ayQuerying - mq.TLO.DanNet(%s).Q(%s) = %s [%d]', peer, query, value, mq.TLO.DanNet(peer).Q(query).Received() or 0)
    return value
    if has_dannet() then
        mq.cmdf('/dquery %s -q "%s"', peer, query)
        if (timeout or 0) > 0 then
            mq.delay(25)
            mq.delay(timeout or 1000, function()
                return (mq.TLO.DanNet(peer).Q(query).Received() or 0) > 0
            end)
        end
        local value = mq.TLO.DanNet(peer).Q(query)()
        Logger.log_verbose('\ayQuerying - mq.TLO.DanNet(%s).Q(%s) = %s', peer, query, value)
        return value
    end

    -- Fallback: no DanNet available.
    Logger.log_verbose("DanNet not loaded; query(%s, %s) returning nil", tostring(peer), tostring(query))
    return nil
end

function helpers.observe(peer, query, timeout)
    if not mq.TLO.DanNet(peer).OSet(query)() then
        mq.cmdf('/dobserve %s -q "%s"', peer, query)
        Logger.log_verbose('\ayAdding Observer - mq.TLO.DanNet(%s).O(%s)', peer, query)
    end
    ---@diagnostic disable-next-line: undefined-field
    mq.delay(timeout or 1000, function() return (mq.TLO.DanNet(peer).O(query).Received() or 0) > 0 end)
    local value = mq.TLO.DanNet(peer).O(query)()
    Logger.log_verbose('\ayObserving - mq.TLO.DanNet(%s).O(%s) = %s [%d]', peer, query, value, mq.TLO.DanNet(peer).Q(query).Received() or 0)
    return value
end

function helpers.unobserve(peer, query)
    if has_dannet() then
        mq.cmdf('/dobserve %s -q "%s" -drop', peer, query)
        Logger.log_verbose('\ayRemoving Observer - mq.TLO.DanNet(%s).O(%s) = %s', peer, query,
            mq.TLO.DanNet(peer).O(query)())
        return
    end
    -- no-op without DanNet
end

return helpers
