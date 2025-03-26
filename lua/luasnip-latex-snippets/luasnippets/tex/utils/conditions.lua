--[
-- LuaSnip Conditions
--]

local M = {}

-- math / not math zones

function M.in_math()
	return vim.api.nvim_eval("vimtex#syntax#in_mathzone()") == 1
end

-- comment detection
function M.in_comment()
	return vim.fn["vimtex#syntax#in_comment"]() == 1
end

-- document class
function M.in_beamer()
	return vim.b.vimtex["documentclass"] == "beamer"
end

-- general env function
local function env(name)
	local is_inside = vim.fn["vimtex#env#is_inside"](name)
	return (is_inside[1] > 0 and is_inside[2] > 0)
end

function M.in_preamble()
	return not env("document")
end

function M.in_text()
	return not M.in_math()
end

function M.in_tikz()
	return env("tikzpicture")
end

function M.in_bullets()
	return env("itemize") or env("enumerate")
end

function M.in_align()
	return env("align") or env("align*") or env("aligned")
end

-- credits: https://github.com/frankroeder/dotfiles/blob/657a5dc559e9ff526facc2e74f9cc07a1875cac6/nvim/lua/tsutils.lua#L59
local has_treesitter, ts = pcall(require, "vim.treesitter")
local _, query = pcall(require, "vim.treesitter.query")

local has_treesitter, ts = pcall(require, "vim.treesitter")
local _, query = pcall(require, "vim.treesitter.query")

local MATH_ENVIRONMENTS = {
	displaymath = true,
	equation = true,
	eqnarray = true,
	align = true,
	math = true,
	array = true,
	aligned = true,
}

local MATH_NODES = {
	displayed_equation = true,
	inline_formula = true,
	math_environment = true,
}

-- Markdown-specific math node types
local MARKDOWN_MATH_NODES = {
	["math_inline"] = true,
	["math_block"] = true,
	["dollar_math"] = true,
	["dollar_dollar_math"] = true,
}

-- Fallback helper
local function get_node_text(node, bufnr)
	-- If old function is available
	if query and type(query.get_node_text) == "function" then
		return query.get_node_text(node, bufnr)
	-- If new function is available (Neovim ≥ 0.9)
	elseif vim.treesitter.get_node_text then
		return vim.treesitter.get_node_text(node, bufnr)
	end
	-- Otherwise, no function available
	return nil
end

local function get_node_at_cursor()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_range = { cursor[1] - 1, cursor[2] }
	local buf = vim.api.nvim_get_current_buf()
	local filetype = vim.bo.filetype

	-- Determine which parser to use
	local parser_lang
	if filetype == "markdown" then
		parser_lang = "markdown"
	elseif filetype == "tex" or filetype == "latex" then
		parser_lang = "latex"
	else
		-- For unsupported filetypes, return nil
		return nil
	end

	local ok, parser = pcall(ts.get_parser, buf, parser_lang)
	if not ok or not parser then
		return nil
	end

	local root_tree = parser:parse()[1]
	local root = root_tree and root_tree:root()
	if not root then
		return nil
	end

	return root:named_descendant_for_range(cursor_range[1], cursor_range[2], cursor_range[1], cursor_range[2])
end

-- Fallback for markdown if treesitter doesn't work
local function is_in_math_markdown_fallback()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]

	-- Check if we're inside a dollar sign pair
	local in_single_dollars = false
	local in_double_dollars = false
	local i = 1

	while i <= #line do
		-- Check for double dollars
		if i < #line and line:sub(i, i + 1) == "$$" then
			in_double_dollars = not in_double_dollars
			i = i + 2
		-- Check for single dollars
		elseif line:sub(i, i) == "$" then
			in_single_dollars = not in_single_dollars
			i = i + 1
		else
			i = i + 1
		end

		if i > col + 1 then
			break
		end
	end

	return in_single_dollars or in_double_dollars
end

function M.in_mathzone()
	if not has_treesitter then
		-- Fallback for no treesitter
		if vim.bo.filetype == "markdown" then
			return is_in_math_markdown_fallback()
		end
		return false
	end

	local filetype = vim.bo.filetype
	local buf = vim.api.nvim_get_current_buf()
	local node = get_node_at_cursor()

	-- If we couldn't get a node (parser failure, etc.)
	if not node then
		if filetype == "markdown" then
			return is_in_math_markdown_fallback()
		end
		return false
	end

	-- Check if we're in a math node
	while node do
		if filetype == "markdown" then
			-- Check for markdown math nodes
			if MARKDOWN_MATH_NODES[node:type()] then
				return true
			end

			-- Some parsers use generic "inline" nodes with $ delimiters
			if node:type() == "inline" then
				local text = get_node_text(node, buf)
				local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
				local node_start = node:start()
				local relative_col = cursor_col - node_start[2]

				-- Simple checking for $ delimiters
				if text then
					local in_math = false
					local i = 1
					while i <= #text do
						if i < #text and text:sub(i, i + 1) == "$$" then
							in_math = not in_math
							i = i + 2
						elseif text:sub(i, i) == "$" then
							in_math = not in_math
							i = i + 1
						else
							i = i + 1
						end

						if i > relative_col + 1 then
							return in_math
						end
					end
				end
			end
		else
			-- LaTeX math node detection
			if MATH_NODES[node:type()] then
				return true
			elseif node:type() == "math_environment" or node:type() == "generic_environment" then
				local begin = node:child(0)
				local names = begin and begin:field("name")
				if names and names[1] then
					local env_name = get_node_text(names[1], buf)
					if env_name and MATH_ENVIRONMENTS[env_name:match("[A-Za-z]+")] then
						return true
					end
				end
			end
		end
		node = node:parent()
	end

	-- Final fallback for markdown
	if filetype == "markdown" then
		return is_in_math_markdown_fallback()
	end

	return false
end

return M
