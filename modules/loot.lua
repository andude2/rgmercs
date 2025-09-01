-- SmartLoot Integration Module
local mq                 = require('mq')
local Config             = require('utils.config')
local Core               = require("utils.core")
local Casting            = require("utils.casting")
local Ui                 = require("utils.ui")
local Comms              = require("utils.comms")
local Strings            = require("utils.strings")
local Logger             = require("utils.logger")
local Targeting          = require("utils.targeting")
local Set                = require("mq.Set")
local Icons              = require('mq.ICONS')

local Module             = { _version = '2.0 SmartLoot', _name = "Loot", _author = 'andude2, Algar', }
Module.__index           = Module
Module.settings          = {}
Module.DefaultCategories = {}

Module.ModuleLoaded      = false
Module.TempSettings      = {}

Module.FAQ               = {}
Module.ClassFAQ          = {}

Module.DefaultConfig     = {
	['UseSmartLoot']                           = {
		DisplayName = "Enable SmartLoot",
		Category = "SmartLoot",
		Index = 1,
		Tooltip = "Enable SmartLoot integration for automated looting. SmartLoot must be running separately.",
		Default = false,
		FAQ = "How do I enable looting with RGMercs?",
		Answer = "Enable 'Enable SmartLoot' and ensure SmartLoot script is running. RGMercs will coordinate with SmartLoot for looting.",
	},
	['SLMainLooter']                           = {
		DisplayName = "Set RG Main",
		Category = "SmartLoot",
		Index = 1,
		Tooltip = "Set this toon as the main looter for smartloot.",
		Default = false,
		FAQ = "How do I enable looting with RGMercs?",
		Answer = "Enable 'Enable SmartLoot' and ensure SmartLoot script is running. RGMercs will coordinate with SmartLoot for looting.",
	},
	['LootingTimeout']                         = {
		DisplayName = "Looting Timeout",
		Category = "SmartLoot",
		Index = 4,
		Tooltip = "Maximum time in seconds to wait for SmartLoot to complete before continuing.",
		Default = 30,
		Min = 10,
		Max = 60,
		FAQ = "Why do my characters wait too long for looting?",
		Answer = "The Looting Timeout controls how long RGMercs waits for SmartLoot to finish. Increase if SmartLoot needs more time, decrease to be more responsive.",
	},
	[string.format("%s_Popped", Module._name)] = {
		DisplayName = Module._name .. " Popped",
		Type = "Custom",
		Category = "Custom",
		Tooltip = Module._name .. " Pop Out Into Window",
		Default = false,
		FAQ = "Can I pop out the " .. Module._name .. " module into its own window?",
		Answer = "You can pop out the " .. Module._name .. " module into its own window by toggeling loot_Popped",
	},
}

Module.FAQ               = {
}

Module.CommandHandlers   = {
	['slreset'] = {
		handler = function(self, params)
			Logger.log_info("\\ay[LOOT]: \\agManually resetting loot state")
			self.TempSettings.Looting = false
			self.TempSettings.LootStartTime = nil
			Logger.log_info("\\ay[LOOT]: \\agLoot state reset - RGMercs should resume normal operations")
		end,
		help = "Reset loot state if stuck waiting",
	},
	['slstatus'] = {
		handler = function(self, params)
			Logger.log_info("\\ay[LOOT]: \\ag=== Loot Module Status ===")
			Logger.log_info("\\ay[LOOT]: \\agLooting: %s", tostring(self.TempSettings.Looting))
			Logger.log_info("\\ay[LOOT]: \\agSmartLoot Ready: %s", tostring(self:IsSmartLootReady()))
			if self.TempSettings.LootStartTime then
				local elapsed = (mq.gettime() - self.TempSettings.LootStartTime) / 1000
				Logger.log_info("\\ay[LOOT]: \\agElapsed Time: %.1fs", elapsed)
			end

			-- Check SmartLoot status
			local success, slState, slMode = pcall(function()
				---@diagnostic disable-next-line: undefined-field
				local smartLoot = mq.TLO.SmartLoot
				if smartLoot then
					return smartLoot.State() or "Unknown", smartLoot.Mode() or "Unknown"
				end
				return "Unknown", "Unknown"
			end)

			if success then
				Logger.log_info("\\ay[LOOT]: \\agSmartLoot State: %s (%s)", slState, slMode)
			else
				Logger.log_info("\\ay[LOOT]: \\arError reading SmartLoot status")
			end
		end,
		help = "Show current loot module status",
	},
}

Module.DefaultCategories = Set.new({})
for k, v in pairs(Module.DefaultConfig or {}) do
	if v.Type ~= "Custom" then
		Module.DefaultCategories:add(v.Category)
	end

	Module.FAQ[k] = { Question = v.FAQ or 'None', Answer = v.Answer or 'None', Settings_Used = k, }
end

local function getConfigFileName()
	local server = mq.TLO.EverQuest.Server()
	server = server:gsub(" ", "")
	return mq.configDir ..
		'/rgmercs/PCConfigs/' .. Module._name .. "_" .. server .. "_" .. Config.Globals.CurLoadedChar ..
		"_" .. Config.Globals.CurLoadedClass .. '.lua'
end

function Module:SaveSettings(doBroadcast)
	mq.pickle(getConfigFileName(), self.settings)
	if self.SettingsLoaded then
		-- Initialize SmartLoot integration if enabled
		if self.settings.UseSmartLoot == true then
			self:InitializeSmartLoot()
		end
	end
	if doBroadcast == true then
		Comms.BroadcastUpdate(self._name, "LoadSettings")
	end
end

function Module:LoadSettings()
	Logger.log_debug("\ay[LOOT]: \atSmartLoot Integration Module Loading Settings for: %s.",
		Config.Globals.CurLoadedChar)
	local settings_pickle_path = getConfigFileName()

	local config, err = loadfile(settings_pickle_path)
	if err or not config then
		Logger.log_error("\ay[LOOT]: \aoUnable to load global settings file(%s), creating a new one!",
			settings_pickle_path)
		self.settings = {}
		self:SaveSettings(false)
	else
		self.settings = config()
	end

	local needsSave = false
	self.settings, needsSave = Config.ResolveDefaults(Module.DefaultConfig, self.settings)

	Logger.log_debug("Settings Changes = %s", Strings.BoolToColorString(needsSave))
	if needsSave then
		self:SaveSettings(false)
	end
	self.SettingsLoaded = true
end

function Module:GetSettings()
	return self.settings
end

function Module:GetDefaultSettings()
	return self.DefaultConfig
end

function Module:GetSettingCategories()
	return self.DefaultCategories
end

function Module.New()
	local newModule = setmetatable({ settings = {}, }, Module)
	return newModule
end

function Module:Init()
	self:LoadSettings()
	if not Core.OnEMU() then
		Logger.log_debug("\ay[LOOT]: \agWe are not on EMU unloading module. Build: %s",
			mq.TLO.MacroQuest.BuildName())
	else
		self:InitializeSmartLoot()
		Logger.log_debug("\ay[LOOT]: \agSmartLoot integration module loaded.")
	end

	return { self = self, settings = self.settings, defaults = self.DefaultConfig, categories = self.DefaultCategories, }
end

function Module:ShouldRender()
	return Core.OnEMU()
end

function Module:Render()
	if not self.settings[self._name .. "_Popped"] then
		if ImGui.SmallButton(Icons.MD_OPEN_IN_NEW) then
			self.settings[self._name .. "_Popped"] = not self.settings[self._name .. "_Popped"]
			self:SaveSettings(false)
		end
		Ui.Tooltip(string.format("Pop the %s tab out into its own window.", self._name))
		ImGui.NewLine()

		-- SmartLoot status display
		local smartLootStatus = "Not Running"
		local statusColor = { 1.0, 0.3, 0.3, 1.0, } -- Red

		if self:IsSmartLootReady() then
			local success, slState, slMode = pcall(function()
				local smartLoot = mq.TLO.SmartLoot
				if smartLoot then
					return smartLoot.State() or "Unknown", smartLoot.Mode() or "Unknown"
				end
				return "Unknown", "Unknown"
			end)

			if success then
				smartLootStatus = string.format("%s (%s)", slState, slMode)
				statusColor = { 0.3, 1.0, 0.3, 1.0, } -- Green
			else
				smartLootStatus = "Error Reading Status"
				statusColor = { 1.0, 1.0, 0.3, 1.0, } -- Yellow
			end
		end

		ImGui.TextColored(statusColor[1], statusColor[2], statusColor[3], statusColor[4], "SmartLoot Status: " .. smartLootStatus)
		ImGui.NewLine()

		ImGui.Text("This module integrates with SmartLoot for automated looting.")
		ImGui.Text("SmartLoot must be running separately: /lua run smartloot")
	end
	local pressed = false
	if ImGui.CollapsingHeader("Config Options") then
		self.settings, pressed, _ = Ui.RenderSettings(self.settings, self.DefaultConfig,
			self.DefaultCategories)
		if pressed then
			self:SaveSettings(false)
		end
	end
end

function Module:Pop()
	self.settings[self._name .. "_Popped"] = not self.settings[self._name .. "_Popped"]
	self:SaveSettings(false)
end

-- Initialize SmartLoot integration
function Module:InitializeSmartLoot()
	if not self.settings.UseSmartLoot then
		self.useSmartLoot = false
		return
	end

	-- Check for SmartLoot availability
	local smartLootStatus = mq.TLO.Lua.Script('smartloot')
	if smartLootStatus and smartLootStatus.Status() == 'RUNNING' then
		self.useSmartLoot = true
		Logger.log_info("\ay[LOOT]: \agSmartLoot integration enabled, please ensure you have a Main Looter set!")
		if Config:GetSetting('SLMainLooter') then
			mq.cmd('/sl_mode rgmain')
			Logger.log_info("Loot: Setting this character as the main looter for SmartLoot.")
		end
		self.smartLootInitialized = true
	else
		self.useSmartLoot = false
		self.smartLootInitialized = false
		Logger.log_warn("\ay[LOOT]: \arSmartLoot not running - looting disabled")
	end
end

-- Check if SmartLoot is available and ready
function Module:IsSmartLootReady()
	if not self.useSmartLoot then
		-- Try to re-initialize if settings allow it
		if self.settings.UseSmartLoot then
			self:InitializeSmartLoot()
		end
		return self.useSmartLoot
	end

	-- Verify SmartLoot is still running
	local smartLootStatus = mq.TLO.Lua.Script('smartloot')
	if not smartLootStatus or smartLootStatus.Status() ~= 'RUNNING' then
		self.useSmartLoot = false
		self.smartLootInitialized = false
		return false
	end

	-- Ensure SmartLoot mode is set correctly if not already done
	if not self.smartLootInitialized then
		self:InitializeSmartLoot()
		self.smartLootInitialized = true
	end

	return true
end

-- Trigger SmartLoot to process corpses
function Module:DoLoot()
	if not self:IsSmartLootReady() then
		Logger.log_debug("\ay[LOOT]: \arSmartLoot not ready - skipping loot trigger")
		return false
	end

	-- Trigger SmartLoot RGMain processing
	Logger.log_debug("\ay[LOOT]: \agTriggering SmartLoot RGMain processing")
	mq.cmd('/sl_rg_trigger')

	-- Mark that we've initiated looting
	self.TempSettings.LootStartTime = mq.gettime()
	self.TempSettings.Looting = true

	return true
end

-- Wait for SmartLoot to complete with proper focus holding
function Module:ProcessLooting(combat_state)
	if not self.TempSettings.Looting then
		return
	end

	local timeoutMs = self.settings.LootingTimeout * 1000
	local startTime = self.TempSettings.LootStartTime or mq.gettime()

	-- Hold focus in loot module while SmartLoot is working
	while self.TempSettings.Looting do
		local elapsed = mq.gettime() - startTime

		-- Check for timeout
		if elapsed > timeoutMs then
			Logger.log_warn("\ay[LOOT]: \arLooting timeout reached (%d seconds) - continuing", self.settings.LootingTimeout)
			self.TempSettings.Looting = false
			break
		end

		-- Check for combat and abort if needed
		if combat_state == "Combat" then
			Logger.log_debug("\ay[LOOT]: \arCombat detected - aborting looting")
			if mq.TLO.Window("LootWnd").Open() then
				mq.TLO.Window("LootWnd").DoClose()
			end
			self.TempSettings.Looting = false
			break
		end

		-- Check SmartLoot status
		local success, isIdle, hasWindow = pcall(function()
			local smartLoot = mq.TLO.SmartLoot
			if smartLoot then
				return smartLoot.IsIdle(), mq.TLO.Window("LootWnd").Open()
			end
			return true, false
		end)

		-- If loot window is open, SmartLoot is definitely working
		if success and hasWindow then
			Logger.log_super_verbose("\ay[LOOT]: \aoLoot window open - SmartLoot is working (%.1fs elapsed)", elapsed / 1000)
		elseif success and not isIdle then
			Logger.log_super_verbose("\ay[LOOT]: \aoSmartLoot still processing (%.1fs elapsed)", elapsed / 1000)
		else
			-- SmartLoot is idle and no loot window - check if we should stop
			-- Wait a minimum time to avoid race conditions
			if elapsed > 500 then -- 0.5 second minimum
				Logger.log_verbose("\ay[LOOT]: \agSmartLoot processing complete (%.1fs elapsed)", elapsed / 1000)
				self.TempSettings.Looting = false
				break
			end
		end

		-- Small delay to not hammer the CPU
		mq.delay(50)
		mq.doevents()
	end

	Logger.log_verbose("\ay[LOOT]: \agResuming normal operations")
end

function Module:GiveTime(combat_state)
	if not Config:GetSetting('UseSmartLoot') then return end
	if Config.Globals.PauseMain then return end

	if not Core.OkayToNotHeal() or mq.TLO.Me.Invis() or Casting.IAmFeigning() then return end

	-- If we're currently looting, continue processing
	if self.TempSettings.Looting then
		Logger.log_verbose("\ay[LOOT]: \aoProcessing SmartLoot actions")
		self:ProcessLooting(combat_state)
		return
	end

	-- Check if we should initiate looting
	if not self:IsSmartLootReady() then
		return
	end


	-- Check for corpses using SmartLoot
	local success, hasCorpses = pcall(function()
		local smartLoot = mq.TLO.SmartLoot
		return smartLoot and smartLoot.HasNewCorpses()
	end)

	if success and hasCorpses then
		-- Check SmartLoot's safety conditions
		local safeToLoot = pcall(function()
			local smartLoot = mq.TLO.SmartLoot
			return smartLoot and smartLoot.SafeToLoot() and smartLoot.IsEnabled()
		end)

		if safeToLoot then
			if self:DoLoot() then
				Logger.log_verbose("\ay[LOOT]: \agInitiated SmartLoot processing")
				-- Process looting immediately
				self:ProcessLooting(combat_state)
			end
		end
	end
end

function Module:OnDeath()
	-- Death Handler
end

function Module:OnZone()
	-- Zone Handler
end

function Module:OnCombatModeChanged()
end

function Module:DoGetState()
	-- Reture a reasonable state if queried
	return "Running..."
end

function Module:GetCommandHandlers()
	return { module = self._name, CommandHandlers = self.CommandHandlers, }
end

function Module:GetFAQ()
	return {
		module = self._name,
		FAQ = self.FAQ or {},
	}
end

function Module:GetClassFAQ()
	return {
		module = self._name,
		FAQ = self.ClassFAQ or {},
	}
end

---@param cmd string
---@param ... string
---@return boolean
function Module:HandleBind(cmd, ...)
	local params = ...
	local handled = false

	if self.CommandHandlers[cmd:lower()] ~= nil then
		self.CommandHandlers[cmd:lower()].handler(self, params)
		handled = true
	end

	return handled
end

function Module:Shutdown()
	Logger.log_debug("\ay[LOOT]: \axSmartLoot Integration Module Unloaded.")
	-- Clear any pending loot state
	self.TempSettings.Looting = false
	self.TempSettings.LootStartTime = nil
end

return Module
