local mq = require('mq')
local actors = require('actors')
local RGMercsLogger = require('utils.logger')

-- RGMercs Character Status Broadcaster Module
local Status = {}

-- Configuration
local BROADCAST_INTERVAL = 1000  -- Broadcast every 1 second
local STATUS_MAILBOX = 'character_status'

-- Local variables
local status_actor = nil
local group_status = {}
local last_broadcast = 0
local runscript = true

-- Initialize the status broadcaster
function Status.Init()
    RGMercsLogger.log_info("Initializing Character Status Broadcaster...")
    
    -- Register our actor with message handler
    status_actor = actors.register(STATUS_MAILBOX, function(message)
        Status.HandleMessage(message)
    end)
    
    RGMercsLogger.log_info("Character Status Broadcaster initialized")
end

-- Handle incoming status messages from other characters
function Status.HandleMessage(message)
    if not message or not message.content then return end
    
    local content = message.content
    local sender_name = message.sender.character
    
    if content.id == 'status_update' then
        -- Store the status update from another character
        group_status[sender_name] = {
            hp = content.hp,
            max_hp = content.max_hp,
            hp_pct = content.hp_pct,
            mana = content.mana,
            max_mana = content.max_mana,
            mana_pct = content.mana_pct,
            endurance = content.endurance,
            max_endurance = content.max_endurance,
            endurance_pct = content.endurance_pct,
            debuffs = content.debuffs,
            buffs = content.buffs,
            timestamp = os.time()
        }
        
        RGMercsLogger.log_verbose("[StatusBroadcast] Received status from %s: HP=%d/%d, Mana=%d/%d", 
            sender_name, content.hp, content.max_hp, content.mana, content.max_mana)
    elseif content.id == 'status_request' then
        -- Someone is requesting our status, send it immediately
        Status.BroadcastStatus()
    elseif content.id == 'character_leaving' then
        -- Character is leaving, remove from our tracking
        group_status[sender_name] = nil
        RGMercsLogger.log_info("[StatusBroadcast] %s left the group", sender_name)
    end
end

-- Collect current character status
function Status.CollectStatus()
    local me = mq.TLO.Me
    
    -- Collect debuffs
    local debuffs = {}
    if me.Poisoned.ID() and me.Poisoned.ID() > 0 then
        debuffs.poisoned = me.Poisoned.ID()
    end
    if me.Diseased.ID() and me.Diseased.ID() > 0 then
        debuffs.diseased = me.Diseased.ID()
    end
    if me.Cursed.ID() and me.Cursed.ID() > 0 then
        debuffs.cursed = me.Cursed.ID()
    end
    if me.Corrupted.ID() and me.Corrupted.ID() > 0 then
        debuffs.corrupted = me.Corrupted.ID()
    end
    if me.Mezzed.ID() and me.Mezzed.ID() > 0 then
        debuffs.mezzed = me.Mezzed.ID()
    end
    
    -- Collect important buffs (you can customize this list)
    local buffs = {}
    for i = 1, 42 do  -- Check all buff slots
        local buff = me.Buff(i)
        if buff and buff.ID() and buff.ID() > 0 then
            buffs[i] = {
                id = buff.ID(),
                name = buff.Name(),
                duration = buff.Duration.TotalSeconds() or 0
            }
        end
    end
    
    return {
        id = 'status_update',
        hp = me.CurrentHPs(),
        max_hp = me.MaxHPs(),
        hp_pct = me.PctHPs(),
        mana = me.CurrentMana(),
        max_mana = me.MaxMana(),
        mana_pct = me.PctMana(),
        endurance = me.CurrentEndurance(),
        max_endurance = me.MaxEndurance(),
        endurance_pct = me.PctEndurance(),
        debuffs = debuffs,
        buffs = buffs,
        in_combat = me.CombatState() == "COMBAT",
        casting = me.Casting.ID() and me.Casting.ID() > 0,
        sitting = me.Sitting(),
        feigning = me.Feigning()
    }
end

-- Broadcast our current status to all group members
function Status.BroadcastStatus()
    if not status_actor then return end
    
    local status_data = Status.CollectStatus()
    
    -- Send to all characters (no specific addressing = broadcast)
    status_actor:send({}, status_data)
    
    last_broadcast = mq.gettime()
end

-- Get status for a specific character
function Status.GetCharacterStatus(character_name)
    if character_name == mq.TLO.Me.CleanName() then
        -- Return our own status
        return Status.CollectStatus()
    else
        -- Return cached status from broadcast
        return group_status[character_name]
    end
end

-- Check if character needs curing
function Status.NeedsCuring(character_name)
    local status = Status.GetCharacterStatus(character_name)
    if not status or not status.debuffs then return false end
    
    return status.debuffs.poisoned or status.debuffs.diseased or 
           status.debuffs.cursed or status.debuffs.corrupted or 
           status.debuffs.mezzed
end

-- Check if character needs healing
function Status.NeedsHealing(character_name, threshold)
    threshold = threshold or 80
    local status = Status.GetCharacterStatus(character_name)
    if not status then return false end
    
    return status.hp_pct < threshold
end

-- Get all characters that need curing
function Status.GetCharactersNeedingCures()
    local needs_curing = {}
    
    -- Check ourselves
    if Status.NeedsCuring(mq.TLO.Me.CleanName()) then
        table.insert(needs_curing, mq.TLO.Me.CleanName())
    end
    
    -- Check group members
    for char_name, status in pairs(group_status) do
        if Status.NeedsCuring(char_name) then
            table.insert(needs_curing, char_name)
        end
    end
    
    return needs_curing
end

-- Main pulse function - call this from your main RGMercs loop
function Status.Pulse()
    if not status_actor then return end
    
    local current_time = mq.gettime()
    
    -- Broadcast our status periodically
    if current_time - last_broadcast > BROADCAST_INTERVAL then
        Status.BroadcastStatus()
    end
    
    -- Clean up old status entries (older than 30 seconds)
    local cleanup_threshold = os.time() - 30
    for char_name, status in pairs(group_status) do
        if status.timestamp < cleanup_threshold then
            group_status[char_name] = nil
            RGMercsLogger.log_verbose("[StatusBroadcast] Cleaned up stale data for %s", char_name)
        end
    end
end

-- Cleanup function
function Status.Shutdown()
    if status_actor then
        -- Send leaving notification
        status_actor:send({}, {id = 'character_leaving'})
        status_actor:unregister()
        status_actor = nil
    end
    
    group_status = {}
    RGMercsLogger.log_info("Character Status Broadcaster shutdown")
end

-- Request status from all group members (useful on startup)
function Status.RequestGroupStatus()
    if status_actor then
        status_actor:send({}, {id = 'status_request'})
    end
end

return Status