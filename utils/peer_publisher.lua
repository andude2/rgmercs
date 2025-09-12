local mq     = require('mq')
local actors = require('rgmercs.lib.actors')

local M = { _name = 'RGPeerPublisher' }

-- Mailbox routing used by the HUD
local MAILBOX = 'rg_peer_status'

-- Publish timing
local PUBLISH_INTERVAL_S = 0.2
local last_publish_time  = 0

-- Registered mailbox handle if available
local mailbox_handle = nil
local use_global_send = false

local function safe_call(fn, default)
    local ok, res = pcall(function() return fn() end)
    if not ok or res == nil then return default end
    return res
end

local function me_name()
    return safe_call(mq.TLO.Me.CleanName, 'Unknown')
end

local function server_name()
    return safe_call(mq.TLO.EverQuest.Server, 'Unknown')
end

local function handle_incoming(_message)
    -- No-op: publisher ignores inbound peer updates
end

function M.init()
    -- Try to register a dedicated mailbox; if it fails, fall back to global send
    mailbox_handle = actors.register(MAILBOX, handle_incoming)
    if not mailbox_handle then
        print(string.format('\ay[%s]\ax Mailbox %s in use; falling back to global send.', M._name, MAILBOX))
        use_global_send = true
    else
        print(string.format('[%s] Publishing to mailbox: %s', M._name, MAILBOX))
    end
end

local function build_status()
    return {
        name         = me_name(),
        server       = server_name(),
        hp           = safe_call(mq.TLO.Me.PctHPs, 0),
        endurance    = safe_call(mq.TLO.Me.PctEndurance, 0),
        mana         = safe_call(mq.TLO.Me.PctMana, 0),
        pethp        = safe_call(mq.TLO.Me.Pet.PctHPs, 0),
        zone         = safe_call(mq.TLO.Zone.ShortName, 'unknown'),
        distance     = 0,
        aa           = safe_call(mq.TLO.Me.AAPoints, 0),
        target       = safe_call(mq.TLO.Target.CleanName, 'None'),
        combat_state = safe_call(mq.TLO.Me.Combat, false) == true,
        casting      = safe_call(mq.TLO.Me.Casting, 'None'),
        class        = safe_call(mq.TLO.Me.Class.ShortName, 'Unknown'),
    }
end

function M.update()
    -- Only publish in game
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then return end

    local now = os.time()
    if os.difftime(now, last_publish_time) < PUBLISH_INTERVAL_S then return end
    last_publish_time = now

    local status = build_status()

    if use_global_send then
        actors.send({ mailbox = MAILBOX }, status)
    else
        mailbox_handle:send({ mailbox = MAILBOX }, status)
    end
end

return M

