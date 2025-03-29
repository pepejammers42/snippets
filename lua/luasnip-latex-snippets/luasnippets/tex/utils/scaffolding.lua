-- Basically a list of snippet-generating functions or other dynamics that are used frequently
-- [
-- snip_env + autosnippets
-- ]
local ls = require("luasnip")
local s = ls.snippet
local sn = ls.snippet_node
local isn = ls.indent_snippet_node
local t = ls.text_node
local i = ls.insert_node
local f = ls.function_node
local c = ls.choice_node
local d = ls.dynamic_node
local r = ls.restore_node
local events = require("luasnip.util.events")
local ai = require("luasnip.nodes.absolute_indexer")
local extras = require("luasnip.extras")
local l = extras.lambda
local rep = extras.rep
local p = extras.partial
local m = extras.match
local n = extras.nonempty
local dl = extras.dynamic_lambda
local fmt = require("luasnip.extras.fmt").fmt
local fmta = require("luasnip.extras.fmt").fmta
local conds = require("luasnip.extras.expand_conditions")
local postfix = require("luasnip.extras.postfix").postfix
local types = require("luasnip.util.types")
local parse = require("luasnip.util.parser").parse_snippet
local ms = ls.multi_snippet
local autosnippet = ls.extend_decorator.apply(s, { snippetType = "autosnippet" })

M = {}

local generate_postfix_dynamicnode = function(_, parent, _, user_arg1, user_arg2)
	local original_capture = parent.snippet.env.POSTFIX_MATCH
	local visual_placeholder = parent.snippet.env.SELECT_RAW

	-- Debugging (optional)
	print(
		"--- Postfix Debug ---",
		"Original Capture:",
		vim.inspect(original_capture),
		"Pre (user_arg1):",
		vim.inspect(user_arg1), -- Should be [[\hat{]]
		"Post (user_arg2):",
		vim.inspect(user_arg2)
	)

	local final_capture = original_capture

	-- <<<--- KEEP THIS WORKAROUND for capture --->>>
	if #original_capture > 0 and original_capture:match("^[a-zA-Z]+$") then
		print("--- Postfix Debug --- Applying backslash workaround to capture")
		final_capture = "\\" .. original_capture -- Should result in \mu
	end
	-- <<<-------------------------------------->>>

	-- Debug the capture after potential modification
	print("--- Postfix Debug --- Final Capture:", vim.inspect(final_capture))

	if #final_capture > 0 then
		-- Use f() node for the prefix, t() for the corrected capture and postfix
		return sn(nil, {
			f(function()
				return user_arg1
			end), -- Use function node for raw prefix
			t(final_capture), -- Use text node for corrected capture (\mu)
			t(user_arg2), -- Use text node for postfix (})
			i(0), -- Final cursor position
		})
	elseif #visual_placeholder > 0 then
		-- Visual selection: Use f() node for prefix as well
		return sn(nil, {
			f(function()
				return user_arg1
			end), -- Use function node for raw prefix
			i(1, visual_placeholder), -- Insert node for selection
			t(user_arg2), -- Use text node for postfix (})
			i(0),
		})
	else
		-- Fallback: Use f() node for prefix
		return sn(nil, {
			f(function()
				return user_arg1
			end), -- Use function node for raw prefix
			i(1, ""), -- Empty insert node
			t(user_arg2), -- Use text node for postfix (})
			i(0),
		})
	end
end

-- visual util to add insert node - thanks ejmastnak!
M.get_visual = function(args, parent)
	if #parent.snippet.env.SELECT_RAW > 0 then
		return sn(nil, i(1, parent.snippet.env.SELECT_RAW))
	else -- If SELECT_RAW is empty, return a blank insert node
		return sn(nil, i(1))
	end
end

-- Auto backslash - thanks kunzaatko! (ref: https://github.com/kunzaatko/nvim-dots/blob/trunk/lua/snippets/tex/utils/snippet_templates.lua)
M.auto_backslash_snippet = function(context, opts)
	opts = opts or {}
	if not context.trig then
		error("context doesn't include a `trig` key which is mandatory", 2)
	end
	context.dscr = context.dscr or (context.trig .. "with automatic backslash")
	context.name = context.name or context.trig
	context.docstring = context.docstring or ([[\]] .. context.trig)
	context.trigEngine = "ecma"
	context.trig = "(?<!\\\\)" .. "(" .. context.trig .. ")"
	return autosnippet(
		context,
		fmta(
			[[
    \<><>
    ]],
			{ f(function(_, snip)
				return snip.captures[1]
			end), i(0) }
		),
		opts
	)
end

-- Auto symbol
M.symbol_snippet = function(context, command, opts)
	opts = opts or {}
	if not context.trig then
		error("context doesn't include a `trig` key which is mandatory", 2)
	end
	context.dscr = context.dscr or command
	context.name = context.name or command:gsub([[\]], "")
	context.docstring = context.docstring or (command .. [[{0}]])
	context.wordTrig = context.wordTrig or false
	return autosnippet(context, t(command), opts)
end

-- single command with option
M.single_command_snippet = function(context, command, opts, ext)
	opts = opts or {}
	if not context.trig then
		error("context doesn't include a `trig` key which is mandatory", 2)
	end
	context.dscr = context.dscr or command
	context.name = context.name or context.dscr
	local docstring, offset, cnode, lnode
	if ext.choice == true then
		docstring = "[" .. [[(<1>)?]] .. "]" .. [[{]] .. [[<2>]] .. [[}]] .. [[<0>]]
		offset = 1
		cnode = c(1, { t(""), sn(nil, { t("["), i(1, "opt"), t("]") }) })
	else
		docstring = [[{]] .. [[<1>]] .. [[}]] .. [[<0>]]
	end
	if ext.label == true then
		docstring = [[{]] .. [[<1>]] .. [[}]] .. [[\label{(]] .. ext.short .. [[:<2>)?}]] .. [[<0>]]
		ext.short = ext.short or command
		lnode = c(2 + (offset or 0), {
			t(""),
			sn(
				nil,
				fmta(
					[[
        \label{<>:<>}
        ]],
					{ t(ext.short), i(1) }
				)
			),
		})
	end
	context.docstring = context.docstring or (command .. docstring)
	-- stype = ext.stype or s
	return s(
		context,
		fmta(command .. [[<>{<>}<><>]], { cnode or t(""), i(1 + (offset or 0)), (lnode or t("")), i(0) }),
		opts
	)
end

M.postfix_snippet = function(context, command, opts)
	opts = opts or {}
	if not context.trig then
		error("context doesn't include a `trig` key which is mandatory", 2)
	end
	context.dscr = context.dscr or (command.pre .. "{...}" .. command.post) -- Improved description
	context.name = context.name or context.trig
	context.docstring = context.docstring or (command.pre .. "(matched_text)" .. command.post)

	-- This pattern tries to match:
	-- 1. A LaTeX command: A backslash followed by one or more letters (\%a+)
	-- 2. OR: One or more characters that are NOT backslash or whitespace ([^\\%s]+)
	-- Both must occur immediately before the trigger ($)
	local match_pattern = "(\\[a-zA-Z]+)$|([^\\%s]+)$"

	local postfix_opts = vim.tbl_deep_extend("force", {
		match_pattern = match_pattern,
		-- Ensure trigger is removed. 'end' refers to the end of the match + trigger.
		replace_pattern = "^", -- Replace from the start of the match
	}, opts)

	return postfix(context, {
		-- Use the dynamic node generator defined above
		d(1, generate_postfix_dynamicnode, {}, { user_args = { command.pre, command.post } }),
	}, postfix_opts)
end

return M
