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

	local final_capture = original_capture

	-- <<<--- KEEP THIS WORKAROUND for capture --->>>
	if #original_capture > 0 and original_capture:match("^[a-zA-Z]+$") then
		final_capture = "\\" .. original_capture -- Should result in \mu string
	end
	-- <<<-------------------------------------->>>

	local snippet_string
	local context_snippet = parent.snippet -- Snippet object needed for parse context

	if #final_capture > 0 then
		-- Construct the target snippet string directly
		-- user_arg1 comes from [[\hat{]], final_capture is "\mu", user_arg2 is "}"
		-- $0 indicates the final cursor position
		snippet_string = user_arg1 .. final_capture .. user_arg2 .. "$0"
		-- Example result: "\hat{\mu}$0"

		print("--- Postfix Debug --- Parsing Snippet String:", vim.inspect(snippet_string))

		-- Parse the string into snippet nodes using LuaSnip's parser
		-- The second argument is the snippet body string
		return parse(context_snippet, snippet_string)
	elseif #visual_placeholder > 0 then
		-- For visual selection, constructing a parseable string with the placeholder
		-- content can be tricky due to potential special chars in the selection.
		-- Let's stick to the node approach that worked previously for visual.
		-- If the main case works with parse(), we can revisit this if needed.
		print("--- Postfix Debug --- Using node approach for visual selection")
		return sn(nil, {
			f(function()
				return user_arg1
			end), -- Use function node for raw prefix
			i(1, visual_placeholder), -- Insert node for selection
			t(user_arg2), -- Use text node for postfix (})
			-- No need for i(0) here as i(1) defines the cursor stop
		})
	else
		-- Fallback: Construct string with an insert node $1
		snippet_string = user_arg1 .. "$1" .. user_arg2 .. "$0"
		print("--- Postfix Debug --- Parsing Fallback Snippet String:", vim.inspect(snippet_string))
		return parse(context_snippet, snippet_string)
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
