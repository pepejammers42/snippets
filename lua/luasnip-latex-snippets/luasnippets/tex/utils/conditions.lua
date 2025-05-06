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
}

-- Fallback helper
local function get_node_text(node, bufnr)
	if query and type(query.get_node_text) == "function" then
		return query.get_node_text(node, bufnr)
	elseif vim.treesitter.get_node_text then
		return vim.treesitter.get_node_text(node, bufnr)
	end
	return nil
end

-- Detect LaTeX math in .tex
local function get_latex_node_at_cursor()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local range = { row - 1, col }
	local buf = vim.api.nvim_get_current_buf()
	local ok, parser = pcall(ts.get_parser, buf, "latex")
	if not ok or not parser then
		return nil
	end

	local tree = parser:parse()[1]
	if not tree then
		return nil
	end
	return tree:root():named_descendant_for_range(range[1], range[2], range[1], range[2])
end

-- Detect Markdown nodes (inline math, fallback to block)
local function get_markdown_node_at_cursor()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local range = { row - 1, col }
	local buf = vim.api.nvim_get_current_buf()

	-- try inline grammar
	local ok, parser = pcall(ts.get_parser, buf, "markdown_inline")
	if not ok or not parser then
		-- fallback to block grammar
		ok, parser = pcall(ts.get_parser, buf, "markdown")
		if not ok or not parser then
			return nil
		end
	end

	local tree = parser:parse()[1]
	if not tree then
		return nil
	end
	return tree:root():named_descendant_for_range(range[1], range[2], range[1], range[2])
end

-- Simple dollar-sign fallback in single line
local function is_in_math_markdown_fallback()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local in_math = false
	local i = 1
	while i <= #line do
		if i < #line and line:sub(i, i + 1) == "$$" then
			in_math = not in_math
			i = i + 2
		elseif line:sub(i, i) == "$" then
			in_math = not in_math
			i = i + 1
		else
			i = i + 1
		end
		if i > col + 1 then
			break
		end
	end
	return in_math
end

-- Robust fallback: detect $$ ... $$ spanning multiple lines
local function is_in_mathblock_markdown_lines()
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local start_line
	for i = row, 1, -1 do
		if lines[i]:match("^%s*%$%$%s*$") then
			start_line = i
			break
		end
	end
	if not start_line then
		return false
	end
	for j = start_line + 1, #lines do
		if lines[j]:match("^%s*%$%$%s*$") then
			-- cursor strictly between the two $$ lines
			return row > start_line and row < j
		end
	end
	return false
end

-- Markdown math-zone check
local function in_mathzone_markdown()
	-- first, robust block fallback
	if is_in_mathblock_markdown_lines() then
		return true
	end

	-- fallback to single-line $ checks
	if not has_treesitter then
		return is_in_math_markdown_fallback()
	end

	local node = get_markdown_node_at_cursor()
	if not node then
		return is_in_math_markdown_fallback()
	end

	while node do
		local t = node:type()
		if t == "math_inline" or t == "math_block" or t == "dollar_math" or t == "dollar_dollar_math" then
			return true
		end

		if t == "inline" then
			local buf = vim.api.nvim_get_current_buf()
			local txt = get_node_text(node, buf)
			local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
			local srow, scol = node:start()
			local rel = cursor_col - scol
			if txt then
				local in_math = false
				for i = 1, #txt do
					if i < #txt and txt:sub(i, i + 1) == "$$" then
						in_math = not in_math
						i = i + 1
					elseif txt:sub(i, i) == "$" then
						in_math = not in_math
					end
					if i >= rel then
						return in_math
					end
				end
			end
		end
		node = node:parent()
	end

	return is_in_math_markdown_fallback()
end

-- Public API: detect mathzone in .tex or .md
function M.in_mathzone()
	if vim.bo.filetype == "markdown" then
		return in_mathzone_markdown()
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
