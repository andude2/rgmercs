local mq       = require('mq')
local imgui    = require('ImGui')
local actors   = require('rgmercs.lib.actors')

local M = {}

-- Timers and state
local REFRESH_INTERVAL_MS  = 10
local PUBLISH_INTERVAL_S   = 0.2
local STALE_DATA_TIMEOUT_S = 30

local last_publish_time = 0
local last_refresh_time = 0
local actor_mailbox     = nil

-- Identity
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

local MY_NAME   = me_name()
local MY_SERVER = server_name()

-- Options (subset aligned with EZBots)
M.options = {
    sort_mode         = 'Alphabetical', -- Alphabetical | HP | Distance | Class | Group
    show_name         = true,
    show_hp           = true,
    show_endurance    = true,
    show_mana         = true,
    show_pethp        = true,
    show_distance     = true,
    show_target       = true,
    show_combat       = true,
    show_casting      = true,
    show_group        = true,
    use_class         = false,
    font_scale        = 1.0,
}

-- Data
M.peers      = {}
M.peer_list  = {}
local last_peer_count    = 0
local cached_peer_height = 300

-- Helpers
local function get_groupstatus_text(peerName)
    if peerName == MY_NAME then return 'F1' end
    if mq.TLO.Group.Members() > 0 then
        local gm = mq.TLO.Group.Member(peerName)
        if gm() then return 'F' .. ((gm.Index() or 0) + 1) end
    end
    if mq.TLO.Raid.Members() > 0 then
        local rm = mq.TLO.Raid.Member(peerName)
        if rm() then return 'G' .. (rm.Group() or 0) end
    end
    return 'X'
end

local function health_color(p)
    p = p or 0
    if p < 35 then return ImVec4(1,0,0,1) end
    if p < 75 then return ImVec4(1,1,0,1) end
    return ImVec4(0,1,0,1)
end

local endurance_classes = {
    BRD=true,BST=true,BER=true,MNK=true,PAL=true,RNG=true,ROG=true,SHD=true,WAR=true,
}
local mana_classes = {
    BRD=true,BST=true,CLR=true,DRU=true,ENC=true,MAG=true,NEC=true,PAL=true,RNG=true,SHD=true,SHM=true,WIZ=true,
}
local pet_classes = {
    BST=true,DRU=true,ENC=true,MAG=true,NEC=true,SHD=true,SHM=true,
}

-- Publishing and receiving
local MAILBOX = 'rg_peer_status'

local function publish_status()
    local now = os.time()
    if os.difftime(now, last_publish_time) < PUBLISH_INTERVAL_S then return end
    if not actor_mailbox then return end

    local status = {
        name        = MY_NAME,
        server      = MY_SERVER,
        hp          = safe_call(mq.TLO.Me.PctHPs, 0),
        endurance   = safe_call(mq.TLO.Me.PctEndurance, 0),
        mana        = safe_call(mq.TLO.Me.PctMana, 0),
        pethp       = safe_call(mq.TLO.Me.Pet.PctHPs, 0),
        zone        = safe_call(mq.TLO.Zone.ShortName, 'unknown'),
        distance    = 0,
        aa          = safe_call(mq.TLO.Me.AAPoints, 0),
        target      = safe_call(mq.TLO.Target.CleanName, 'None'),
        combat_state= safe_call(mq.TLO.Me.Combat, false) == true,
        casting     = safe_call(mq.TLO.Me.Casting, 'None'),
        class       = safe_call(mq.TLO.Me.Class.ShortName, 'Unknown'),
    }

    actor_mailbox:send({ mailbox = MAILBOX }, status)
    last_publish_time = now
end

local function handle_peer_message(message)
    local content = message()
    if not content or type(content) ~= 'table' then return end
    if not content.name or not content.server then return end
    local id = content.server .. '_' .. content.name
    if id == (MY_SERVER .. '_' .. MY_NAME) then return end

    local now = os.time()
    M.peers[id] = {
        id           = id,
        name         = content.name,
        server       = content.server,
        hp           = content.hp or 0,
        endurance    = content.endurance or 0,
        mana         = content.mana or 0,
        pethp        = content.pethp or 0,
        zone         = content.zone or 'unknown',
        aa           = content.aa or 0,
        target       = content.target or 'None',
        combat_state = content.combat_state == true or content.combat_state == 'TRUE' or false,
        casting      = content.casting or 'None',
        last_update  = now,
        distance     = 0,
        inSameZone   = false,
        class        = content.class or 'Unknown',
    }
end

local function cleanup_stale()
    local now = os.time()
    for id, data in pairs(M.peers) do
        if os.difftime(now, data.last_update or 0) > STALE_DATA_TIMEOUT_S then
            M.peers[id] = nil
        end
    end
end

local function refresh_peers()
    local list = {}
    local now = os.time()
    local my_zone = safe_call(mq.TLO.Zone.ShortName, 'unknown')
    local my_id = safe_call(mq.TLO.Me.ID, 0)
    local my_key = MY_SERVER .. '_' .. MY_NAME

    -- ensure self entry
    local self_entry = M.peers[my_key] or {id=my_key, name=MY_NAME, server=MY_SERVER}
    self_entry.hp           = safe_call(mq.TLO.Me.PctHPs, 0)
    self_entry.endurance    = safe_call(mq.TLO.Me.PctEndurance, 0)
    self_entry.mana         = safe_call(mq.TLO.Me.PctMana, 0)
    self_entry.pethp        = safe_call(mq.TLO.Me.Pet.PctHPs, 0)
    self_entry.zone         = my_zone
    self_entry.aa           = safe_call(mq.TLO.Me.AAPoints, 0)
    self_entry.target       = safe_call(mq.TLO.Target.CleanName, 'None')
    self_entry.combat_state = safe_call(mq.TLO.Me.Combat, false) == true
    self_entry.casting      = safe_call(mq.TLO.Me.Casting, 'None')
    self_entry.class        = safe_call(mq.TLO.Me.Class.ShortName, 'Unknown')
    self_entry.last_update  = now
    self_entry.distance     = 0
    self_entry.inSameZone   = true
    self_entry.group_status = get_groupstatus_text(self_entry.name)
    M.peers[my_key] = self_entry
    table.insert(list, self_entry)

    for id, data in pairs(M.peers) do
        if id ~= my_key and os.difftime(now, data.last_update or 0) <= STALE_DATA_TIMEOUT_S then
            data.inSameZone = (data.zone == my_zone)
            data.group_status = get_groupstatus_text(data.name)
            if data.inSameZone then
                local spawn = mq.TLO.Spawn(string.format('pc "%s"', data.name))
                if spawn and spawn() and spawn.ID() and spawn.ID() ~= my_id then
                    local dist = spawn.Distance3D()
                    data.distance = dist ~= nil and dist or 9999
                else
                    data.distance = 9999
                end
            else
                data.distance = 9999
            end
            table.insert(list, data)
        end
    end

    -- sort
    if M.options.sort_mode == 'Alphabetical' then
        table.sort(list, function(a,b) return (a.name or ''):lower() < (b.name or ''):lower() end)
    elseif M.options.sort_mode == 'HP' then
        table.sort(list, function(a,b) return (a.hp or 0) < (b.hp or 0) end)
    elseif M.options.sort_mode == 'Distance' then
        table.sort(list, function(a,b) return (a.distance or 9999) < (b.distance or 9999) end)
    elseif M.options.sort_mode == 'Class' then
        table.sort(list, function(a,b)
            local ca = (a.class or 'Unknown'):lower()
            local cb = (b.class or 'Unknown'):lower()
            if ca == cb then return (a.name or ''):lower() < (b.name or ''):lower() end
            return ca < cb
        end)
    elseif M.options.sort_mode == 'Group' then
        table.sort(list, function(a,b) return (a.group_status or 'Z') < (b.group_status or 'Z') end)
    end

    M.peer_list = list

    -- calc height to fit rows nicely
    local row_h   = imgui.GetTextLineHeight() + (imgui.GetStyle().CellPadding.y * 2)
    local header_h= row_h + 2
    local rows    = #list
    local new_h   = (rows > 0 and header_h or 20) + rows * row_h + imgui.GetStyle().FramePadding.y
    cached_peer_height = math.max(rows > 0 and header_h or 20, new_h)
    last_peer_count = rows

    cleanup_stale()
end

-- Drawing
function M.draw_peer_list()
    local column_count = 0
    local first_col_is_name_or_class = false
    if M.options.show_name or M.options.use_class then column_count = column_count + 1; first_col_is_name_or_class = true end
    if M.options.show_hp then column_count = column_count + 1 end
    if M.options.show_endurance then column_count = column_count + 1 end
    if M.options.show_mana then column_count = column_count + 1 end
    if M.options.show_pethp then column_count = column_count + 1 end
    if M.options.show_distance then column_count = column_count + 1 end
    if M.options.show_target then column_count = column_count + 1 end
    if M.options.show_combat then column_count = column_count + 1 end
    if M.options.show_casting then column_count = column_count + 1 end
    if M.options.show_group then column_count = column_count + 1 end

    if column_count == 0 then
        imgui.Text('No columns selected for RG Peer HUD.')
        return
    end

    local flags = bit32.bor(ImGuiTableFlags.Reorderable, ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.NoHostExtendX)
    if not imgui.BeginTable('##RGPeerTable', column_count, flags) then return end

    local header_text = (M.options.use_class and not (M.options.sort_mode == 'Class')) and 'Class/Name' or 'Name'
    if first_col_is_name_or_class then imgui.TableSetupColumn(header_text, ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 150) end
    if M.options.show_hp then imgui.TableSetupColumn('HP', ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_endurance then imgui.TableSetupColumn('End', ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_mana then imgui.TableSetupColumn('Mana', ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_pethp then imgui.TableSetupColumn('PetHP', ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_distance then imgui.TableSetupColumn('Dist', ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_target then imgui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed, 100) end
    if M.options.show_combat then imgui.TableSetupColumn('Combat', ImGuiTableColumnFlags.WidthFixed, 70) end
    if M.options.show_casting then imgui.TableSetupColumn('Casting', ImGuiTableColumnFlags.WidthFixed, 100) end
    if M.options.show_group then imgui.TableSetupColumn('Group', ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 45) end
    imgui.TableHeadersRow()

    for _, peer in ipairs(M.peer_list) do
        imgui.TableNextRow()

        if first_col_is_name_or_class then
            imgui.TableNextColumn()
            local isSelf = (peer.name == MY_NAME and peer.server == MY_SERVER)
            local zoneColor = peer.inSameZone and ImVec4(0.8, 1, 0.8, 1) or ImVec4(1, 0.7, 0.7, 1)
            if isSelf then zoneColor = ImVec4(1, 1, 0.7, 1) end
            imgui.PushStyleColor(ImGuiCol.Text, zoneColor)
            local displayValue = peer.name
            if M.options.sort_mode ~= 'Class' and M.options.use_class then
                displayValue = peer.class or 'Unknown'
            end
            local uniqueLabel = string.format('%s##%s_peer', displayValue, peer.id)
            imgui.Text(uniqueLabel)
            imgui.PopStyleColor()
        end

        if M.options.show_hp then
            imgui.TableNextColumn(); imgui.PushStyleColor(ImGuiCol.Text, health_color(peer.hp)); imgui.Text(string.format('%.0f%%', peer.hp or 0)); imgui.PopStyleColor()
        end
        if M.options.show_endurance then
            imgui.TableNextColumn()
            local show = endurance_classes[peer.class or ''] == true
            imgui.PushStyleColor(ImGuiCol.Text, show and health_color(peer.endurance) or ImVec4(0.7,0.7,0.7,1))
            imgui.Text(show and string.format('%.0f%%', peer.endurance or 0) or '')
            imgui.PopStyleColor()
        end
        if M.options.show_mana then
            imgui.TableNextColumn()
            local show = mana_classes[peer.class or ''] == true
            imgui.PushStyleColor(ImGuiCol.Text, show and ImVec4(0.678,0.847,0.902,1) or ImVec4(0.7,0.7,0.7,1))
            imgui.Text(show and string.format('%.0f%%', peer.mana or 0) or '')
            imgui.PopStyleColor()
        end
        if M.options.show_pethp then
            imgui.TableNextColumn()
            local show = pet_classes[peer.class or ''] == true
            local col = (peer.pethp or 0) > 0 and health_color(peer.pethp) or ImVec4(0.7,0.7,0.7,1)
            imgui.PushStyleColor(ImGuiCol.Text, col); imgui.Text(show and string.format('%.0f%%', peer.pethp or 0) or ''); imgui.PopStyleColor()
        end
        if M.options.show_distance then
            imgui.TableNextColumn()
            local distText, col = 'N/A', ImVec4(0.7,0.7,0.7,1)
            local d = peer.distance or 0
            if not peer.inSameZone then distText='MIA'; col=ImVec4(1,0.6,0.6,1)
            elseif d >= 9999 then distText='???'; col=ImVec4(1,1,0.6,1)
            else
                distText = string.format('%.0f', d)
                if d < 20 then col=ImVec4(0.6,1,0.6,1) elseif d < 100 then col=ImVec4(0.8,1,0.8,1) elseif d < 175 then col=ImVec4(1,0.8,0.6,1) else col=ImVec4(1,0.6,0.6,1) end
            end
            imgui.PushStyleColor(ImGuiCol.Text, col); imgui.Text(distText); imgui.PopStyleColor()
        end
        if M.options.show_target then
            imgui.TableNextColumn()
            local col
            if M.options.show_combat then
                col = (peer.target == 'None') and ImVec4(0.7,0.7,0.7,1) or ImVec4(1,1,1,1)
            else
                if peer.combat_state then col = ImVec4(1,0,0,1) else col = (peer.target == 'None') and ImVec4(0.7,0.7,0.7,1) or ImVec4(1,1,1,1) end
            end
            imgui.PushStyleColor(ImGuiCol.Text, col); imgui.Text(peer.target or 'None'); imgui.PopStyleColor()
        end
        if M.options.show_combat then
            imgui.TableNextColumn()
            local combat = peer.combat_state
            imgui.PushStyleColor(ImGuiCol.Text, combat and ImVec4(1,0.7,0.7,1) or ImVec4(1,1,0.7,1))
            imgui.Text(combat and 'Fighting' or 'Idle')
            imgui.PopStyleColor()
        end
        if M.options.show_casting then
            imgui.TableNextColumn(); imgui.PushStyleColor(ImGuiCol.Text, (peer.casting == 'None' or peer.casting == '') and ImVec4(0.7,0.7,0.7,1) or ImVec4(0.8,0.8,1,1)); imgui.Text(peer.casting or 'None'); imgui.PopStyleColor()
        end
        if M.options.show_group then
            imgui.TableNextColumn();
            local txt = peer.group_status or 'X'
            imgui.PushStyleColor(ImGuiCol.Text, txt=='X' and ImVec4(1,0.7,0.7,1) or ImVec4(0.8,0.8,1,1)); imgui.Text(txt); imgui.PopStyleColor()
        end
    end

    imgui.EndTable()
end

-- Public API
function M.update()
    local now = os.clock()*1000
    if (now - last_refresh_time) >= REFRESH_INTERVAL_MS then
        refresh_peers()
        last_refresh_time = now
    end
    publish_status()
end

function M.init()
    MY_NAME   = me_name()
    MY_SERVER = server_name()
    actor_mailbox = actors.register(MAILBOX, handle_peer_message)
    if not actor_mailbox then
        print(string.format('\ar[RGPeerHUD] Failed to register mailbox %s\ax', MAILBOX))
        return false
    end
    print(string.format('[RGPeerHUD] Mailbox registered: %s', MAILBOX))
    refresh_peers()
    return true
end

function M.get_peer_data()
    return { list = M.peer_list, count = #M.peer_list, my_aa = safe_call(mq.TLO.Me.AAPoints, 0), cached_height = cached_peer_height }
end

function M.get_refresh_interval()
    return REFRESH_INTERVAL_MS
end

return M

