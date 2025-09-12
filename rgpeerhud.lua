-- RGMercs Peer HUD (actors/mailboxes based)
-- Shows peer info only for RGMercs characters via a dedicated mailbox

local mq     = require('mq')
local imgui  = require('ImGui')
local peers  = require('rgmercs.ui.peers')

local open_window   = true
local initialized   = false

local function RGPeerHUD()
    if not initialized then
        imgui.SetNextWindowSize(ImVec2(360, 640), ImGuiCond.FirstUseEver)
        initialized = true
    end
    if not mq.TLO.EverQuest.HWND() then return end

    local window_flags = 0
    local open, show = imgui.Begin('RG Peer HUD', true, window_flags)
    if show then
        -- Controls
        imgui.TextColored(ImVec4(0.7, 0.9, 1, 1), 'RGMercs Peer HUD')
        imgui.SameLine()
        imgui.TextDisabled('(Right-click window for options)')
        imgui.Separator()

        -- Options popup
        if imgui.BeginPopupContextWindow('##RGPeerHUDContext', ImGuiPopupFlags.MouseButtonRight) then
            imgui.Text('Columns')
            imgui.Separator()
            peers.options.show_name      = imgui.Checkbox('Show Name', peers.options.show_name)
            peers.options.use_class      = imgui.Checkbox('Use Class Name', peers.options.use_class)
            peers.options.show_hp        = imgui.Checkbox('Show HP (%)', peers.options.show_hp)
            peers.options.show_endurance = imgui.Checkbox('Show End (%)', peers.options.show_endurance)
            peers.options.show_mana      = imgui.Checkbox('Show Mana (%)', peers.options.show_mana)
            peers.options.show_pethp     = imgui.Checkbox('Show PetHP (%)', peers.options.show_pethp)
            peers.options.show_distance  = imgui.Checkbox('Show Distance', peers.options.show_distance)
            peers.options.show_target    = imgui.Checkbox('Show Target', peers.options.show_target)
            peers.options.show_combat    = imgui.Checkbox('Show Combat', peers.options.show_combat)
            peers.options.show_casting   = imgui.Checkbox('Show Casting', peers.options.show_casting)
            peers.options.show_group     = imgui.Checkbox('Show Group Status', peers.options.show_group)

            imgui.Separator()
            if imgui.BeginMenu('Sort By') then
                if imgui.MenuItem('Alphabetical', nil, peers.options.sort_mode == 'Alphabetical') then peers.options.sort_mode = 'Alphabetical' end
                if imgui.MenuItem('HP (Asc)', nil, peers.options.sort_mode == 'HP') then peers.options.sort_mode = 'HP' end
                if imgui.MenuItem('Distance (Asc)', nil, peers.options.sort_mode == 'Distance') then peers.options.sort_mode = 'Distance' end
                if imgui.MenuItem('Class', nil, peers.options.sort_mode == 'Class') then peers.options.sort_mode = 'Class' end
                if imgui.MenuItem('Group', nil, peers.options.sort_mode == 'Group') then peers.options.sort_mode = 'Group' end
                imgui.EndMenu()
            end

            imgui.Separator()
            imgui.Text('Font Scale')
            imgui.SameLine()
            imgui.PushItemWidth(120)
            local fs_changed
            peers.options.font_scale, fs_changed = imgui.SliderFloat('##rgph_fs', peers.options.font_scale, 0.6, 2.0, '%.1f')
            imgui.PopItemWidth()
            imgui.EndPopup()
        end

        -- Body
        local pd = peers.get_peer_data()
        imgui.TextColored(ImVec4(0.8, 0.8, 1, 1), string.format('Peers: %d', pd.count))
        imgui.SameLine(imgui.GetWindowContentRegionWidth() - 120)
        imgui.TextColored(ImVec4(0.8, 0.8, 1, 1), string.format('My AA: %d', pd.my_aa or 0))
        imgui.Separator()

        local opened = imgui.BeginChild('RGPeerListChild', ImVec2(0, pd.cached_height), false, ImGuiWindowFlags.None)
        if opened then
            ImGui.SetWindowFontScale(peers.options.font_scale)
            peers.draw_peer_list()
        end
        imgui.EndChild()
    end
    imgui.End()

    if not open then mq.exit() end
end

-- Init
local gameState = mq.TLO.MacroQuest.GameState()
if gameState ~= 'INGAME' then
    print('\ar[RGPeerHUD] Not in game. Enter world and /lua run rgmercs/rgpeerhud\ax')
    mq.exit()
end

if not peers.init() then mq.exit() end

mq.imgui.init('RGPeerHUD', RGPeerHUD)

-- Loop
while mq.TLO.MacroQuest.GameState() == 'INGAME' do
    peers.update()
    mq.doevents()
    mq.delay(peers.get_refresh_interval())
end
