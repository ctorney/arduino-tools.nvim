require("arduino-tools.libGetter")

local M = {}

M.board = "arduino:avr:uno"
M.port = "/dev/ttyACM0"
M.baudrate = 115200
M.portregex = {
	"^/dev/tty",
	"^COM",
	"^/dev/cu.usbmodem",
	"^/dev/cu.usbserial",
	"^/dev/cu.usbmodem",
	"/dev/cu.usbserial-.*",
}

local config_file = ".arduino_config.lua"

function Trim(s)
	return s:match("^%s*(.-)%s*$")
end

function M.status()
	local buf, win, opts = M.create_floating_cli_monitor()
	local data = string.format("Board: %s\nPort: %s\nBaudrate: %s", M.board, M.port, M.baudrate)
	M.append_to_buffer({ data }, buf, win, opts)
end

-- Function to save settings to the config file
function M.save_config()
	local file = io.open(config_file, "w")
	if file then
		file:write("return {\n")
		file:write(string.format("  board = %q,\n", M.board))
		file:write(string.format("  port = %q,\n", M.port))
		file:write(string.format("  baudrate = %q,\n", M.baudrate))
		file:write("}\n")
		file:close()
	else
		vim.notify("Error: Cannot write to config file.", vim.log.levels.ERROR)
	end
end

function M.load_or_create_config()
	-- Check if sketch.yaml exists
	if vim.fn.filereadable(config_file) == 0 then
		-- If not, create sketch.yaml with default settings
		vim.notify("config file not found. Creating with default settings.", vim.log.levels.INFO)
		local file = io.open(config_file, "w")
		file:write("local M = {}\n")
		file:write("M.board = '" .. M.board .. "'\n")
		file:write("M.port = '" .. M.port .. "'\n")
		file:write("M.baudrate =" .. M.baudrate .. "\n")
		file:write("return M\n")
		file:close()
	else
		-- Read existing file and check if fqbn and port match the config
		local config = loadfile(config_file)
		if config then
			local ok, settings = pcall(config)
			if ok and settings then
				M.board = settings.board or M.board
				M.port = settings.port or M.port
				M.baudrate = settings.baudrate or M.baudrate
				vim.notify("Config loaded from file: " .. config_file, vim.log.levels.INFO)
			end
		end
	end
end

M.load_or_create_config()
-- Utility function to strip ANSI escape codes
local function strip_ansi_codes(line)
	return line:gsub("\27%[[0-9;]*m", "")
end

-- Function to create a floating CLI monitor window that starts small and grows
function M.create_floating_cli_monitor()
	local width = vim.o.columns -- Full width of the screen
	local initial_height = 5 -- Start with a small height (adjustable)

	-- Create a buffer for the floating window
	local buf = vim.api.nvim_create_buf(false, true)

	-- Define initial window options to position it at the bottom
	local opts = {
		relative = "editor",
		width = width,
		height = initial_height,
		row = vim.o.lines - initial_height - 2, -- Position at the bottom
		col = 0,
		style = "minimal",
		border = "rounded", -- Optional: add border for visual separation
	}

	-- Create the floating window and store its ID
	local win = vim.api.nvim_open_win(buf, true, opts)
	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		"<CR>",
		"<cmd>lua vim.api.nvim_win_close(" .. win .. ", false)<CR>",
		{ noremap = true, silent = true }
	)

	return buf, win, opts
end

-- Function to dynamically adjust the floating window height based on buffer content
local function adjust_window_height(win, buf, opts)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local new_height = math.min(line_count, vim.o.lines - 2) -- Max height limited to screen size

	-- Update window height and reposition if necessary to keep it at the bottom
	opts.height = new_height
	opts.row = vim.o.lines - new_height - 2
	vim.api.nvim_win_set_config(win, opts)
end

-- Function to set the COM port and save config
function M.set_com(port)
	M.port = Trim(port)
	vim.notify("Port set to: " .. port)
	M.save_config()
end

-- Function to set the board type and save config
function M.set_board(board)
	M.board = Trim(board)
	vim.notify("Board set to: " .. board)
	M.save_config()
end

-- Function to set the baud rate and save config
function M.set_baudrate(baudrate)
	M.baudrate = Trim(baudrate)
	vim.notify("Baud rate set to: " .. baudrate)
	M.save_config()
end

-- Function to check code
function M.check()
	-- Create the output window buffer and window
	local buf, win, opts = M.create_floating_cli_monitor()

	-- Command to compile in the current directory
	local cmd = "arduino-cli compile --fqbn " .. M.board .. " " .. vim.fn.expand("%")

	-- Run the command asynchronously
	vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if data then
				M.append_to_buffer(data, buf, win, opts)
			end
		end,
		on_stderr = function(_, data)
			-- Only append lines that contain actual content to avoid false errors
			if data then
				local error_lines = {}
				for _, line in ipairs(data) do
					local cleaned_line = strip_ansi_codes(line)
					if cleaned_line:match("%S") then -- Only consider non-empty, non-whitespace lines
						table.insert(error_lines, "Error: " .. cleaned_line)
					end
				end
				if #error_lines > 0 then
					M.append_to_buffer(error_lines)
				end
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code == 0 then
				M.append_to_buffer({ "--- Code checked successfully. ---" }, buf, win, opts)
			else
				M.append_to_buffer({ "--- Code check failed. ---" }, buf, win, opts)
			end
		end,
	})
end

-- Helper function to split a string by newlines
local function split_string_by_newlines(input)
	local result = {}
	for line in input:gmatch("[^\r\n]+") do
		table.insert(result, line)
	end
	return result
end

-- Updated append_to_buffer function
function M.append_to_buffer(lines, buf, win, opts)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	-- Ensure lines is a table, even if a single string is passed
	if type(lines) == "string" then
		lines = { lines }
	end

	-- Split each line in the table by newlines
	local processed_lines = {}
	for _, line in ipairs(lines) do
		local split_lines = split_string_by_newlines(line)
		vim.list_extend(processed_lines, split_lines)
	end

	-- Clean each line to remove ANSI codes and add to the buffer
	local cleaned_lines = vim.tbl_map(strip_ansi_codes, processed_lines)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, cleaned_lines)

	-- local last_line = vim.api.nvim_buf_line_count(buf)
	-- local last_col = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1]:len()
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
	-- Adjust the window height if necessary
	-- adjust_window_height(win, buf, opts)
end

function M.upload()
	-- Create the CLI monitor buffer and window
	local buf, win, opts = M.create_floating_cli_monitor()

	-- Function to append lines to the monitor buffer and adjust height
	-- Strip ANSI codes from each line and append to buffer

	-- Commands for compiling and uploading
	local compile_cmd = "arduino-cli compile --fqbn " .. M.board .. " " .. vim.fn.expand("%:p:h")
	local upload_cmd = "arduino-cli upload -p " .. M.port .. " --fqbn " .. M.board .. " " .. vim.fn.expand("%:p:h")

	-- Function to start upload after successful compilation
	local function start_upload()
		vim.fn.jobstart(upload_cmd, {
			stdout_buffered = false,
			on_stdout = function(_, data)
				if data then
					M.append_to_buffer(data, buf, win, opts)
				end
			end,
			on_stderr = function(_, data)
				if data and #data > 0 and data[1]:match("%S") then -- Only log if there is actual error content
					M.append_to_buffer(
						vim.tbl_map(function(line)
							return "Error: " .. line
						end, data),
						buf,
						win,
						opts
					)
				end
			end,
			on_exit = function()
				M.append_to_buffer({ "--- Upload Complete ---" }, buf, win, opts)
			end,
		})
	end

	-- Start the compilation job
	vim.fn.jobstart(compile_cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if data then
				M.append_to_buffer(data, buf, win, opts)
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 and data[1]:match("%S") then -- Only log if there is actual error content
				M.append_to_buffer(
					vim.tbl_map(function(line)
						return "Error: " .. line
					end, data),
					buf,
					win,
					opts
				)
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code == 0 then
				M.append_to_buffer({ "--- Compilation Complete, Starting Upload ---" }, buf, win, opts)
				start_upload()
			else
				M.append_to_buffer({ "--- Compilation Failed ---" }, buf, win, opts)
			end
		end,
	})
end

function M.select_board_gui(callback)
	-- Run 'arduino-cli board listall --format json' and parse the output
	local handle = io.popen("arduino-cli board listall --format json")
	local result = handle:read("*a")
	handle:close()

	-- local json = require("plenary.json") -- Using plenary for JSON parsing
	local ok, data = pcall(vim.json.decode, result)

	local boards = {}
	if ok and data and data.boards then
		for _, board in ipairs(data.boards) do
			-- Extract the 'name' and 'fqbn' of each board
			local board_name = board.name or "Unknown Board"
			local fqbn = board.fqbn

			if fqbn then
				table.insert(boards, {
					display = board_name,
					fqbn = fqbn,
					ordinal = board_name,
				})
			end
		end
	else
		print("Failed to parse JSON output of 'arduino-cli board listall'")
		return
	end

	-- If no boards are found, display a message
	if #boards == 0 then
		print("No Arduino boards found in the list.")
		return
	end

	-- Use vim.ui.select instead of telescope
	vim.ui.select(boards, {
		prompt = "Select Arduino Board",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if choice then
			M.set_board(choice.fqbn)
			if callback then
				callback()
			end
		end
	end)
end

function M.select_port_gui()
	-- Get list of connected ports using arduino-cli
	local handle = io.popen("arduino-cli board list")
	local result = handle:read("*a")
	handle:close()

	-- Extract port names from the arduino-cli output
	-- Extract port names from the arduino-cli output
	local ports = {}
	for line in result:gmatch("[^\r\n]+") do
		-- Check each regex pattern in M.portregex
		for _, pattern in ipairs(M.portregex) do
			if line:match(pattern) then
				table.insert(ports, line:match("^(%S+)")) -- Capture the port name only
				break -- Once we've matched a pattern, no need to check others for this line
			end
		end
	end

	-- If no ports found, show an error message
	if #ports == 0 then
		vim.notify("No connected COM ports found.", vim.log.levels.ERROR)
		return
	end

	-- Use vim.ui.select instead of telescope
	vim.ui.select(ports, {
		prompt = "Select Arduino Port",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if choice then
			M.set_com(choice)
		end
	end)
end

function M.InoList()
	local buf, win, opts = M.create_floating_cli_monitor()
	-- list all available ports1
	local handle = io.popen("arduino-cli board list")
	local result = handle:read("*a")
	handle:close()
	M.append_to_buffer({ result }, buf, win, opts)
end

-- Main GUI function to link board and port selection
function M.gui()
	M.select_board_gui(function()
		M.select_port_gui()
	end)
end

function M.upload_and_monitor()
	if M.job_id then
		vim.fn.jobstop(M.job_id)
		M.job_id = nil
	end

	-- delete the previous buffer if it exists
	if M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf) then
		vim.api.nvim_buf_delete(M.buf, { force = true })
	end

	-- Create the floating window and buffer
	M.buf, M.win, M.win_opts = M.create_floating_window()

	-- Set buffer options
	-- vim.api.nvim_buf_set_option(buf, "modifiable", true)

	-- Add a header to the buffer
	vim.api.nvim_buf_set_lines(M.buf, 0, 0, false, {
		"Arduino Upload and Serial Monitor - Press Ctrl-C to exit",
		"Port: " .. M.port .. " | Baudrate: " .. M.baudrate,
		"---------------------------------------------------",
		"",
	})

	-- Function to append lines to the monitor buffer and adjust height
	-- Strip ANSI codes from each line and append to buffer

	-- Commands for compiling and uploading
	local compile_cmd = "arduino-cli compile --fqbn "
		.. M.board
		.. " "
		.. vim.fn.expand("%:p:h")
		.. " --board-options flash=8388608_7340032"
	local upload_cmd = "arduino-cli upload -p "
		.. M.port
		.. " --fqbn "
		.. M.board
		.. " "
		.. vim.fn.expand("%:p:h")
		.. " --board-options flash=8388608_7340032"

	-- Function to start upload after successful compilation
	local function start_upload()
		vim.fn.jobstart(upload_cmd, {
			stdout_buffered = false,
			on_stdout = function(_, data)
				if data then
					M.append_to_buffer(data, M.buf, M.win, M.win_opts)
				end
			end,
			on_stderr = function(_, data)
				if data and #data > 0 and data[1]:match("%S") then -- Only log if there is actual error content
					M.append_to_buffer(
						vim.tbl_map(function(line)
							return "Error: " .. line
						end, data),
						M.buf,
						M.win,
						M.win_opts
					)
				end
			end,
			on_exit = function(_, exit_code)
				if exit_code == 0 then
					M.append_to_buffer({ "--- Upload Complete ---" }, M.buf, M.win, M.win_opts)
					M.monitor()
				else
					M.append_to_buffer({ "--- Upload Failed ---" }, M.buf, M.win, M.win_opts)
					M.append_to_buffer({ "--- Ctrl-C to exit ---" }, M.buf, M.win, M.win_opts)
					vim.api.nvim_buf_set_keymap(
						M.buf,
						"n",
						"<C-c>",
						string.format("<cmd>lua vim.api.nvim_buf_delete(%d, {force=true})<CR>", M.buf),
						{ noremap = true, silent = true }
					)
				end
			end,
		})
	end
	-- save all files before uploading
	vim.cmd("wa")
	-- Start the compilation job
	vim.fn.jobstart(compile_cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if data then
				M.append_to_buffer(data, M.buf, M.win, M.win_opts)
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 and data[1]:match("%S") then -- Only log if there is actual error content
				M.append_to_buffer(
					vim.tbl_map(function(line)
						return "Error: " .. line
					end, data),
					M.buf,
					M.win,
					M.win_opts
				)
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code == 0 then
				M.append_to_buffer({ "--- Compilation Complete, Starting Upload ---" }, M.buf, M.win, M.win_opts)
				start_upload()
			else
				M.append_to_buffer({ "--- Compilation Failed ---" }, M.buf, M.win, M.win_opts)
				M.append_to_buffer({ "--- Ctrl-C to exit ---" }, M.buf, M.win, M.win_opts)
				vim.api.nvim_buf_set_keymap(
					M.buf,
					"n",
					"<C-c>",
					string.format("<cmd>lua vim.api.nvim_buf_delete(%d, {force=true})<CR>", M.buf),
					{ noremap = true, silent = true }
				)
			end
		end,
	})
end

function M.create_floating_window()
	local buf = vim.api.nvim_create_buf(false, true)
	local win_width = math.floor(vim.o.columns * 0.8)
	local win_height = math.floor(vim.o.lines * 0.8)
	local win_opts = {
		relative = "editor",
		width = win_width,
		height = win_height,
		row = math.floor((vim.o.lines - win_height) / 2),
		col = math.floor((vim.o.columns - win_width) / 2),
		style = "minimal",
		border = "rounded",
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
	-- vim.api.nvim_win_set_option(M.win, "guicursor", "")
	-- vim.api.nvim_set_option_value("modifiable", false, { buf = M.buf })

	return buf, win, win_opts
end

function M.monitor()
	local serial_command = string.format("arduino-cli monitor -p %s -c %s", M.port, M.baudrate)

	if M.buf == nil or not vim.api.nvim_buf_is_valid(M.buf) then
		M.buf, M.win, M.win_opts = M.create_floating_window()

		-- Set buffer options
		-- vim.api.nvim_buf_set_option(buf, "modifiable", true)

		-- Add a header to the buffer
		vim.api.nvim_buf_set_lines(M.buf, 0, 0, false, {
			"Arduino Serial Monitor - Press Ctrl-C to exit",
			"Port: " .. M.port .. " | Baudrate: " .. M.baudrate,
			"---------------------------------------------------",
			"",
		})
	end

	if M.job_id then
		vim.fn.jobstop(M.job_id)
		M.job_id = nil
	end

	-- Start the job
	M.job_id = vim.fn.jobstart(serial_command, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if data then
				M.append_to_buffer(data, M.buf, M.win, M.win_opts)
				-- set cursor to the end of the buffer and the end of the line
				-- 	{ vim.api.nvim_buf_line_count(M.buf), vim.api.nvim_buf_get_lines(M.buf, -1, -1, false)[1]:len() }
				-- )
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 and data[1]:match("%S") then
				M.append_to_buffer(
					vim.tbl_map(function(line)
						return "Error: " .. line
					end, data),
					M.buf,
					M.win,
					M.win_opts
				)
			end
		end,
	})

	vim.api.nvim_buf_set_keymap(
		M.buf,
		"n",
		"<C-c>",
		string.format("<cmd>lua vim.fn.jobstop(%d); vim.api.nvim_buf_delete(%d, {force=true})<CR>", M.job_id, M.buf),
		{ noremap = true, silent = true }
	)

	-- Set a keymap to hide the floating window without stopping the job
	-- Set a keymap to hide the floating window without stopping the job
	vim.api.nvim_buf_set_keymap(
		M.buf,
		"n",
		"<C-t>",
		string.format("<cmd>lua vim.api.nvim_win_close(%d, true)<CR>", M.win),
		{ noremap = true, silent = true }
	)
end

function M.reopen_monitor()
	if M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf) then
		-- Reopen the window with the existing buffer
		M.win = vim.api.nvim_open_win(M.buf, true, M.win_opts)
	else
		-- If buffer is invalid, start a new monitor session
		M.monitor()
	end
end

function M.monitor2()
	local serial_command = string.format("arduino-cli monitor -p %s -c %s", M.port, M.baudrate)

	local buf = vim.api.nvim_create_buf(false, true)

	local win_width = math.floor(vim.o.columns * 0.8)
	local win_height = math.floor(vim.o.lines * 0.8)
	local win_opts = {
		relative = "editor",
		width = win_width,
		height = win_height,
		row = math.floor((vim.o.lines - win_height) / 2),
		col = math.floor((vim.o.columns - win_width) / 2),
		style = "minimal",
		border = "rounded",
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	vim.fn.termopen(serial_command)

	vim.cmd("startinsert")

	vim.api.nvim_buf_set_keymap(buf, "t", "<C-c>", "<C-\\><C-n>:bd!<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<C-c>", ":bd!<CR>", { noremap = true, silent = true })
end

function M.setup(opts)
	if opts.portsregex then
		M.portregex = M.portregex or {}
		for k, v in pairs(opts.portsregex) do
			M.portregex[k] = v
		end
	end

	vim.api.nvim_create_user_command("InoSelectBoard", function()
		M.select_board_gui()
	end, {})
	vim.api.nvim_create_user_command("InoSelectPort", function()
		M.select_port_gui()
	end, {})
	vim.api.nvim_create_user_command("InoCheck", function()
		M.check()
	end, {})
	vim.api.nvim_create_user_command("InoUpload", function()
		M.upload_and_monitor()
	end, {})
	vim.api.nvim_create_user_command("InoGUI", function()
		M.gui()
	end, {})
	vim.api.nvim_create_user_command("InoMonitor", function()
		M.monitor()
	end, {})
	vim.api.nvim_create_user_command("InoSetBaud", function(opts)
		M.set_baudrate(opts.args)
	end, { nargs = 1 })
	vim.api.nvim_create_user_command("InoStatus", function()
		M.status()
	end, {})
	vim.api.nvim_create_user_command("InoList", function()
		M.InoList()
	end, {})
	vim.api.nvim_create_user_command("InoReopenMonitor", function()
		M.reopen_monitor()
	end, {})
	local lsp = require("arduino-tools.lsp")
	lsp.setup(opts)
end

return M
