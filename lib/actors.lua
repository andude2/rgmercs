local mq = require('mq')
local Logger = require('rgmercs.utils.logger')

local Actors = {}

-- Simple mailbox implementation
local mailboxes = {}

-- Register a mailbox to handle incoming messages
function Actors.register(mailbox_name, handler)
    if mailboxes[mailbox_name] then
        Logger.log_verbose("Mailbox %s already registered", mailbox_name)
        return nil
    end
    
    mailboxes[mailbox_name] = {
        name = mailbox_name,
        handler = handler,
        messages = {}
    }
    
    Logger.log_verbose("Registered mailbox: %s", mailbox_name)
    
    -- Return a handle that can be used to send messages
    return {
        send = function(self, target, message)
            Actors.send(target, message)
        end
    }
end

-- Send a message to a mailbox
function Actors.send(target, message)
    -- Check if DanNet is available
    if not mq.TLO.Plugin('MQ2DanNet')() then
        Logger.log_verbose("DanNet not available, skipping message send")
        return
    end
    
    if not target or not target.mailbox then
        Logger.log_verbose("Invalid target for message send")
        return
    end
    
    local mailbox_name = target.mailbox
    
    -- If we have a local handler for this mailbox, call it directly
    if mailboxes[mailbox_name] then
        local mailbox = mailboxes[mailbox_name]
        local success, err = pcall(mailbox.handler, function() return message end)
        if not success then
            Logger.log_error("Error in mailbox handler for %s: %s", mailbox_name, err)
        end
        return
    end
    
    -- Otherwise, send via DanNet to other clients
    local groupName = mq.TLO.Group.Leader() or "None"
    if groupName ~= "None" then
        local serverName = (mq.TLO.EverQuest.Server() or "Unknown"):gsub(" ", "")
        
        -- Encode message as JSON for transmission
        local json = require('dkjson')
        local messageStr = json.encode(message)
        
        -- Send the message
        mq.cmdf("/dgt rg_peer_msg_%s_%s_%s %s", 
            serverName, 
            groupName, 
            mailbox_name, 
            messageStr)
    end
end

-- Function to handle incoming DanNet messages
-- This would be called by the main loop when DanNet messages arrive
function Actors.handle_incoming_dannet_message(mailbox_name, message_str)
    if not mailboxes[mailbox_name] then
        Logger.log_verbose("No handler for mailbox: %s", mailbox_name)
        return
    end
    
    -- Decode the JSON message
    local json = require('dkjson')
    local success, message = pcall(json.decode, message_str)
    if not success then
        Logger.log_error("Failed to decode message for mailbox %s: %s", mailbox_name, message_str)
        return
    end
    
    -- Call the handler
    local mailbox = mailboxes[mailbox_name]
    local handler_success, err = pcall(mailbox.handler, function() return message end)
    if not handler_success then
        Logger.log_error("Error in mailbox handler for %s: %s", mailbox_name, err)
    end
end

return Actors