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

	print("Original capture:", vim.inspect(original_capture))

	if #original_capture > 0 then
		-- Check if original capture started with a backslash
		local had_backslash = original_capture:match("^\\")
		-- Clean the capture of any existing backslashes
		local clean_capture = original_capture:gsub("^\\+", "")

		-- Create the result directly with raw strings
		local result
		if had_backslash then
			-- If original had backslash: \muhat -> \hat{\mu}
			result = [[\hat{\]] .. clean_capture .. [[}]]
		else
			-- If original had no backslash: muhat -> \hat{mu}
			result = [[\hat{]] .. clean_capture .. [[}]]
		end

		print("Result:", vim.inspect(result))

		-- Return the snippet directly
		return sn(nil, { t(result), i(0) })
	elseif #visual_placeholder > 0 then
		-- Handle visual selection case
		return sn(nil, {
			t([[\hat{]]),
			i(1, visual_placeholder),
			t([[}]]),
			i(0),
		})
	else
		-- Handle empty case
		return sn(nil, {
			t([[\hat{]]),
			i(1),
			t([[}]]),
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
	context.dscr = context.dscr or (command.pre .. "{...}" .. command.post)
	context.name = context.name or context.trig
	context.docstring = context.docstring or (command.pre .. "(matched_text)" .. command.post)

	local match_pattern = "[a-zA-Z]+$"
	local replace_pattern = "[a-zA-Z]+$"

	local postfix_opts = vim.tbl_deep_extend("force", {
		match_pattern = match_pattern,
		replace_pattern = replace_pattern,
	}, opts)

	return postfix(context, {
		d(1, function(_, parent)
			local original_capture = parent.env.POSTFIX_MATCH or ""

			print("--- Luasnip Postfix Debug (Dynamic Node) ---")
			print("Original Capture:", vim.inspect(original_capture))

			local had_backslash = original_capture:match("^\\")
			local clean_capture = original_capture:gsub("^\\+", "")

			print("Had Backslash:", had_backslash)
			print("Clean Capture:", vim.inspect(clean_capture))

			if had_backslash then
				-- If original had backslash: \muhat -> \hat{\mu}
				return sn(nil, {
					t(command.pre),
					t("\\"),
					t(clean_capture),
					t(command.post),
					i(0),
				})
			else
				-- If original had no backslash: muhat -> \hat{mu}
				return sn(nil, {
					t(command.pre),
					t(clean_capture),
					t(command.post),
					i(0),
				})
			end
		end),
	}, postfix_opts)
end

return M
