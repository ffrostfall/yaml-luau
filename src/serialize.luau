-- writes luau values as block-style yaml. tables referenced more than once get anchors and aliases.
-- the functions build up from scalars, to finding shared tables, to collections

const null = require("./null")
const schema = require("./schema")

type State = {
	parts: { string },
	-- tables reachable through more than one path, which need an anchor
	shared: { [any]: boolean },
	-- { [table]: anchor id } for shared tables already written
	anchors: { [any]: number },
	anchor_count: number,
}

-- words that yaml 1.1 parsers read as booleans; quoting them keeps output portable
const YAML_1_1_WORDS: { [string]: boolean } = { y = true, n = true, yes = true, no = true, on = true, off = true }

-- text that would change meaning, or not survive, as a plain scalar
const PLAIN_UNSAFE_PATTERNS = {
	"^[,%[%]{}#&*!|>'\"%%@`]",
	"^[-?:] ",
	"^[-?:]$",
	"^%-%-%-",
	"^%.%.%.",
	"^ ",
	" $",
	"%c",
	": ",
	":$",
	" #",
}

-- { [character]: escape sequence }
const ESCAPES: { [string]: string } = {
	["\0"] = "\\0",
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\t"] = "\\t",
	["\n"] = "\\n",
	["\v"] = "\\v",
	["\f"] = "\\f",
	["\r"] = "\\r",
	["\27"] = "\\e",
	['"'] = '\\"',
	["\\"] = "\\\\",
}

-- { [utf-8 sequence]: escape sequence } for characters yaml treats as line breaks or byte order marks
const UNICODE_ESCAPES: { [string]: string } = {
	["\u{85}"] = "\\N",
	["\u{2028}"] = "\\L",
	["\u{2029}"] = "\\P",
	["\u{FEFF}"] = "\\uFEFF",
}

-- implicit keys longer than this must be written as explicit "? " keys
const MAX_SIMPLE_KEY_LENGTH = 1024
-- { [value type]: rank }, so mapping keys of different types sort consistently
const KEY_TYPE_ORDER: { [string]: number } = { userdata = 1, boolean = 2, number = 3, string = 4, table = 5 }

const function append(state: State, text: string)
	table.insert(state.parts, text)
end

const function has_unicode_break(text: string): boolean
	for sequence in UNICODE_ESCAPES do
		if string.find(text, sequence, 1, true) then
			return true
		end
	end
	return false
end

-- every string goes through this check before it is written
const function can_be_plain(text: string): boolean
	assert(utf8.len(text), "cannot serialize a string that is not valid utf-8")
	if YAML_1_1_WORDS[string.lower(text)] or typeof(schema.resolve_plain(text)) ~= "string" then
		return false
	end
	for _, pattern in PLAIN_UNSAFE_PATTERNS do
		if string.find(text, pattern) then
			return false
		end
	end
	return not has_unicode_break(text)
end

-- multi-line strings read best as literal blocks, when their first line can set the block's indentation
const function can_be_literal(text: string): boolean
	return string.find(text, "\n", 1, true) ~= nil
		and not string.find(text, "^[ \t\n]")
		and not string.find(text, "[\0-\8\11-\31\127]")
		and not has_unicode_break(text)
end

const function quote(text: string): string
	local escaped: string = string.gsub(text, '[%c"\\]', function(character: string): string
		return ESCAPES[character] or string.format("\\x%02X", string.byte(character))
	end)
	for sequence, escape in UNICODE_ESCAPES do
		escaped = string.gsub(escaped, sequence, escape)
	end
	return `"{escaped}"`
end

const function write_literal(state: State, text: string, indent: number)
	local body = text
	local header = "|-"
	if string.sub(text, -1) == "\n" then
		body = string.sub(text, 1, -2)
		header = if string.sub(body, -1) == "\n" then "|+" else "|"
	end

	append(state, header .. "\n")
	for _, line in string.split(body, "\n") do
		append(state, if line == "" then "\n" else `{string.rep(" ", indent)}{line}\n`)
	end
end

const function format_inline_scalar(value: any): string
	const kind = typeof(value)
	if value == nil or value == null then
		return "null"
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		if value ~= value then
			return ".nan"
		end
		if math.abs(value) == math.huge then
			return if value > 0 then ".inf" else "-.inf"
		end
		return tostring(value)
	elseif kind == "string" then
		return if can_be_plain(value) then value else quote(value)
	end
	error(`cannot serialize a value of type {kind}`, 0)
end

-- writes a scalar after an indicator or key, ending the line
const function write_scalar(state: State, value: any, indent: number)
	if typeof(value) == "string" and not can_be_plain(value) and can_be_literal(value) then
		write_literal(state, value, indent)
	else
		append(state, format_inline_scalar(value) .. "\n")
	end
end

-- marks tables that are reachable more than once, including through cycles
const function find_shared(value: any, seen: { [any]: boolean }, shared: { [any]: boolean })
	if typeof(value) ~= "table" then
		return
	end
	if seen[value] then
		shared[value] = true
		return
	end

	seen[value] = true
	for key, item in value do
		find_shared(key, seen, shared)
		find_shared(item, seen, shared)
	end
end
-- "*id" for a shared table that was already written, which is then referenced instead of written again
const function alias_of(state: State, value: { [any]: any }): string?
	const id = state.anchors[value]
	return if id then `*{id}` else nil
end

-- "&id" for a shared table being written for the first time, so later references can alias it
const function anchor_of(state: State, value: { [any]: any }): string?
	if not state.shared[value] then
		return nil
	end
	state.anchor_count += 1
	state.anchors[value] = state.anchor_count
	return `&{state.anchor_count}`
end

--[[
	ffrostfall comment:
	Like what the fuck even is this shit. Is this really supposed to replace us?
	Shit can't even make an `is_array` function properly.
]]

-- an array is a non-empty table whose keys are exactly 1..n
const function is_array(value: { [any]: any }): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return count > 0
end
const function compare_keys(left: any, right: any): boolean
	const left_rank = KEY_TYPE_ORDER[typeof(left)]
	const right_rank = KEY_TYPE_ORDER[typeof(right)]
	if left_rank ~= right_rank then
		return left_rank < right_rank
	end
	if typeof(left) == "boolean" then
		return not left and right
	end
	return (typeof(left) == "number" or typeof(left) == "string") and left < right
end
-- keys that are tables, or too long for an implicit key, are written as "? key"
const function needs_explicit_key(key: any): boolean
	return typeof(key) == "table" or (typeof(key) == "string" and #key > MAX_SIMPLE_KEY_LENGTH)
end

-- array keys sort into index order, and mapping keys into a stable one
const function sorted_keys(value: { [any]: any }): { any }
	const keys: { any } = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, compare_keys)
	return keys
end

local write_collection: (state: State, value: { [any]: any }, indent: number, compact: boolean) -> ()

-- writes the node after an indicator or key, ending the line. nested content is indented past `indent`,
-- and `compact` lets a collection start on the same line, as after "- "
const function write_node(state: State, value: any, indent: number, compact: boolean)
	if typeof(value) ~= "table" then
		append(state, " ")
		write_scalar(state, value, indent + 2)
		return
	end

	const alias = alias_of(state, value)
	if alias then
		append(state, ` {alias}\n`)
		return
	end

	const anchor = anchor_of(state, value)
	if next(value) == nil then
		append(state, if anchor then ` {anchor} \{}\n` else " {}\n")
	elseif compact and not anchor then
		append(state, " ")
		write_collection(state, value, indent + 2, true)
	else
		-- an anchor followed by a compact mapping would attach to the mapping's first key instead
		append(state, if anchor then ` {anchor}\n` else "\n")
		write_collection(state, value, indent + 2, false)
	end
end

-- writes each entry on its own line at `indent`. in `compact` form the first entry continues the
-- current line instead
function write_collection(state: State, value: { [any]: any }, indent: number, compact: boolean)
	const array = is_array(value)
	for index, key in sorted_keys(value) do
		if index > 1 or not compact then
			append(state, string.rep(" ", indent))
		end

		if array then
			append(state, "-")
			write_node(state, value[key], indent, true)
		elseif needs_explicit_key(key) then
			append(state, "?")
			write_node(state, key, indent, true)
			append(state, string.rep(" ", indent) .. ":")
			write_node(state, value[key], indent, true)
		else
			append(state, format_inline_scalar(key) .. ":")
			write_node(state, value[key], indent, false)
		end
	end
end

const function serialize(value: any): string
	const state: State = {
		parts = {},
		shared = {},
		anchors = {},
		anchor_count = 0,
	}
	find_shared(value, {}, state.shared)

	-- the top-level node has no indicator or key before it
	if typeof(value) ~= "table" then
		write_scalar(state, value, 2)
	elseif next(value) == nil then
		append(state, "{}\n")
	else
		const anchor = anchor_of(state, value)
		if anchor then
			append(state, anchor .. "\n")
		end
		write_collection(state, value, 0, false)
	end
	return table.concat(state.parts)
end

return serialize
