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
local ok_utils, ts_utils = pcall(require, "nvim-treesitter.ts_utils")

local MATH_ENVIRONMENTS =
	{ displaymath = true, equation = true, eqnarray = true, align = true, math = true, array = true, aligned = true }
local MATH_NODES = { displayed_equation = true, inline_formula = true }

local function get_node_text(node, bufnr)
	if query and type(query.get_node_text) == "function" then
		return query.get_node_text(node, bufnr)
	elseif vim.treesitter.get_node_text then
		return vim.treesitter.get_node_text(node, bufnr)
	end
end

local function inline_dollar_fallback()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] + 1
	local in_math, i = false, 1
	while i <= #line do
		if line:sub(i, i + 1) == "$$" then
			in_math = not in_math
			i = i + 2
		elseif line:sub(i, i) == "$" then
			in_math = not in_math
			i = i + 1
		else
			i = i + 1
		end
		if i > col then
			break
		end
	end
	return in_math
end

local function block_dollar_fallback()
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	-- Find all $$ lines and their positions
	local math_delimiters = {}
	for i = 1, #lines do
		if lines[i] and lines[i]:match("^%s*%$%$%s*$") then
			table.insert(math_delimiters, i)
		end
	end

	-- Check if current row is inside a math block
	for i = 1, #math_delimiters, 2 do
		local start_line = math_delimiters[i]
		local end_line = math_delimiters[i + 1]

		if end_line and row > start_line and row < end_line then
			return true
		end
	end

	return false
end

local function node_at_cursor()
	if ok_utils then
		local n = ts_utils.get_node_at_cursor()
		if n then
			return n
		end
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local buf = vim.api.nvim_get_current_buf()
	local ok, parser = pcall(ts.get_parser, buf, "markdown_inline")
	if not ok then
		ok, parser = pcall(ts.get_parser, buf, "markdown")
		if not ok then
			return nil
		end
	end
	local tree = parser:parse()[1]
	if not tree then
		return nil
	end
	local n = tree:root():descendant_for_range(row - 1, col, row - 1, col)
	if n then
		return n
	end
	if col > 0 then
		return tree:root():descendant_for_range(row - 1, col - 1, row - 1, col - 1)
	end
end

local function in_markdown_mathzone()
	if block_dollar_fallback() then
		return true
	end
	if not has_treesitter then
		return inline_dollar_fallback()
	end
	local node = node_at_cursor()
	while node do
		local ok, lang = pcall(node.lang, node)
		if ok and lang == "latex" then
			return true
		end
		local t = node:type()
		if
			t == "math_inline"
			or t == "math_block"
			or t == "dollar_math"
			or t == "dollar_dollar_math"
			or t == "inline_formula"
			or t == "displayed_equation"
		then
			return true
		end
		node = node:parent()
	end
	return inline_dollar_fallback()
end

local function get_latex_node_at_cursor()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local buf = vim.api.nvim_get_current_buf()
	local ok, parser = pcall(ts.get_parser, buf, "latex")
	if not ok or not parser then
		return nil
	end
	local tree = parser:parse()[1]
	if not tree then
		return nil
	end
	return tree:root():named_descendant_for_range(row - 1, col, row - 1, col)
end

function M.in_mathzone()
	if vim.bo.filetype == "markdown" then
		return in_markdown_mathzone()
	elseif vim.bo.filetype == "tex" then
		local node = get_latex_node_at_cursor()
		if not node then
			return false
		end
		local buf = vim.api.nvim_get_current_buf()
		while node do
			if MATH_NODES[node:type()] then
				return true
			elseif node:type() == "math_environment" or node:type() == "generic_environment" then
				local name_field = node:child(0):field("name")
				if name_field and name_field[1] then
					local env = get_node_text(name_field[1], buf)
					if env and MATH_ENVIRONMENTS[env:match("%a+")] then
						return true
					end
				end
			end
			node = node:parent()
		end
		return false
	end
	return false
end

return M
