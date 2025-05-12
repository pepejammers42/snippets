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
	local open_line
	for i = row, 1, -1 do
		if lines[i]:match("^%s*%$%$%s*$") then
			open_line = i
			break
		end
	end
	if not open_line then
		return false
	end
	for j = open_line + 1, #lines do
		if lines[j]:match("^%s*%$%$%s*$") then
			return row > open_line and row < j
		end
	end
	return false
end

local function parser_node_at_cursor()
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
	return tree:root():descendant_for_range(row - 1, col, row - 1, col)
end

local function in_markdown_mathzone()
	if block_dollar_fallback() then
		return true
	end
	if not has_treesitter then
		return inline_dollar_fallback()
	end
	local node = parser_node_at_cursor()
	while node do
		if node.lang and node:lang() == "latex" then
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
