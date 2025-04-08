-- Remove the dkjson path addition since we'll use plenary
local json = require("plenary.json") -- Use plenary's JSON module instead of dkjson
local cache_file = vim.fn.stdpath("cache") .. "/arduino_libs.json"
local cache_expiration = 7 * 24 * 60 * 60 -- Cache expires in 7 days

local M = {}

-- Function to fetch libraries from Arduino CLI and store in cache
local function fetch_and_cache_libraries()
	print("Fetching libraries from arduino-cli...")
	local handle = io.popen("arduino-cli lib search --format json")
	local result = handle:read("*a")
	handle:close()

	local ok, lib_data = pcall(vim.json.decode, result)
	if ok and lib_data then
		print("Successfully parsed libraries from JSON.")
		-- Save to cache file
		local cache_handle = io.open(cache_file, "w")
		cache_handle:write(vim.json.encode(lib_data))
		cache_handle:close()
		return lib_data
	else
		print("Failed to fetch libraries or parse JSON.")
		return nil
	end
end

-- Load libraries from cache or fetch if expired
local function load_libraries_from_cache()
	local cache_stat = vim.loop.fs_stat(cache_file)
	if cache_stat and (os.time() - cache_stat.mtime.sec) < cache_expiration then
		print("Loading libraries from cache.")
		local cache_handle = io.open(cache_file, "r")
		local cache_content = cache_handle:read("*a")
		cache_handle:close()
		local ok, lib_data = pcall(vim.json.decode, cache_content)
		if ok and lib_data then
			print("Successfully loaded libraries from cache.")
			return lib_data
		else
			print("Failed to parse cached libraries.")
		end
	end
	print("Cache expired or missing, fetching new data.")
	return fetch_and_cache_libraries()
end

-- Fetch list of installed libraries
local function get_installed_libraries()
	local handle = io.popen("arduino-cli lib list --format json")
	local result = handle:read("*a")
	handle:close()

	local ok, installed_data = pcall(vim.json.decode, result)
	local installed_libs = {}

	if ok and installed_data and installed_data.installed_libraries then
		for _, entry in ipairs(installed_data.installed_libraries) do
			if entry.library and entry.library.name then
				installed_libs[entry.library.name] = entry.library.version -- Store version for comparison
			end
		end
	else
		print("Failed to fetch installed libraries.")
	end

	return installed_libs
end

-- Fetch libraries with available updates
local function get_libraries_with_updates()
	local handle = io.popen("arduino-cli outdated --format json")
	local result = handle:read("*a")
	handle:close()

	local ok, outdated_data = pcall(vim.json.decode, result)
	local outdated_libs = {}

	if ok and outdated_data and outdated_data.libraries then
		for _, lib_entry in ipairs(outdated_data.libraries) do
			local lib_info = lib_entry.library
			local lib_name = lib_info and lib_info.name
			local latest_version = lib_entry.release and lib_entry.release.version

			if lib_name and latest_version then
				outdated_libs[lib_name] = latest_version -- Store the latest version for display
			else
				print("Warning: Missing lib_name or latest_version for entry:")
				print(vim.inspect(lib_entry))
			end
		end
	else
		print("Failed to fetch outdated libraries.")
	end

	return outdated_libs
end

-- Function to update and reopen library selection
local function update_library_picker()
	M.library_manager() -- Reload the library manager to reflect changes
end

-- Main function for library management using vim.ui.select
function M.library_manager()
	local libraries_data = load_libraries_from_cache()
	local libraries = libraries_data and libraries_data.libraries

	if libraries and #libraries > 0 then
		local library_items = {}
		local display_items = {}

		-- Get the list of currently installed libraries
		local installed_libs = get_installed_libraries()
		local outdated_libs = get_libraries_with_updates()

		for _, lib in ipairs(libraries) do
			if lib.name then
				local display_name = lib.name
				local status = "uninstalled"

				if installed_libs[lib.name] then
					display_name = "✅ " .. display_name -- Add tick mark for installed libs
					status = "installed"

					if outdated_libs[lib.name] then
						display_name = "🔄 " .. display_name -- Append update available icon
						status = "outdated"
					end
				end

				-- Store both the display name and the actual library data
				table.insert(library_items, {
					name = lib.name,
					display = display_name,
					status = status,
				})

				table.insert(display_items, display_name)
			end
		end

		-- Use vim.ui.select to display the libraries
		vim.ui.select(library_items, {
			prompt = "Arduino Libraries",
			format_item = function(item)
				return item.display
			end,
		}, function(choice)
			if choice then
				local lib_name = choice.name
				local cmd

				if choice.status == "outdated" then
					-- Update the library if an update is available
					print("Updating library: " .. lib_name)
					cmd = 'arduino-cli lib install "' .. lib_name .. '" > /dev/null 2>&1'
					os.execute(cmd)
					vim.notify("Library '" .. lib_name .. "' updated successfully.")
				elseif choice.status == "uninstalled" then
					-- Install the library if it's not installed
					print("Installing library: " .. lib_name)
					cmd = 'arduino-cli lib install "' .. lib_name .. '" > /dev/null 2>&1'
					os.execute(cmd)
					vim.notify("Library '" .. lib_name .. "' installed successfully.")
				else
					-- For installed libraries that don't need updates
					vim.notify("Library '" .. lib_name .. "' is already installed and up to date.")
				end

				-- Give a small delay before refreshing to allow the command to complete
				vim.defer_fn(function()
					update_library_picker()
				end, 500)
			end
		end)
	else
		print("No libraries found.")
	end
end

-- Run library fetch on startup only if cache is expired
--[[ vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*.ino",
    callback = function()
        load_libraries_from_cache()
    end,
})]]

-- Create Neovim command to open the library manager
vim.api.nvim_create_user_command("InoLib", function()
	M.library_manager()
end, {})

-- Return M to make it accessible
return M
