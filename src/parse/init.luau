--!native
--!optimize 2
-- turns yaml text into a flat list of events: the structure of its documents, collections and scalars.
-- the reader tracks position in the text and scalars reads scalar text, so this file only handles structure.
--
-- block collections follow indentation. every block node is read relative to `parent_indent`, the
-- indentation of the collection around it, and ends where content returns to that indentation or less.
-- an implicit "key: value" key can't be recognized until the ':' after it, so a node is parsed first,
-- and a mapping start is inserted before its events once a ':' follows it on the same line.
--
-- the functions build up from event helpers, to properties, flow nodes, block nodes, and documents

const reader = require("@self/reader")
const scalars = require("@self/scalars")

export type ScalarStyle = scalars.Style

export type Event = {
	-- stream_start, stream_end, document_start, document_end, sequence_start, sequence_end,
	-- mapping_start, mapping_end, scalar or alias
	kind: string,
	line: number,
	column: number,
	anchor: string?,
	-- fully resolved tag, or "!" for the non-specific tag
	tag: string?,
	-- scalar text or alias name
	value: string,
	style: ScalarStyle,
	-- whether a collection is written in flow style
	flow: boolean,
	-- whether a document start or end marker is present
	explicit: boolean,
}

-- the parser keeps its output on the reader's table
type State = reader.Identity & {
	events: { Event },
	-- { [handle]: prefix }
	tag_handles: { [string]: string },
}

-- an anchor and tag, and where the first of them was written
type Properties = {
	anchor: string?,
	tag: string?,
	line: number,
	column: number,
}

-- where a block node appears, which decides what may start on its first line
type BlockContext =
	"document" -- after "---", or at the start of a document
	| "sequence_entry" -- after "- "
	| "explicit_entry" -- after "? ", or after the ": " of an explicit key
	| "mapping_value" -- after the ":" of an implicit key

-- how a block mapping entry's key was written, which decides where its value may go
type KeyStyle =
	"implicit" -- "key: value", with the value after the ':' on the key's line
	| "explicit" -- "? key", with the value on a later line starting with ':'
	| "empty" -- ": value", with no key at all

const LINE_FEED, BANG, HASH, PERCENT, AMPERSAND, STAR, COMMA, DASH, COLON, QUESTION, PIPE, GREATER, SINGLE_QUOTE, DOUBLE_QUOTE, OPEN_BRACKET, CLOSE_BRACKET, OPEN_BRACE, CLOSE_BRACE =
	string.byte("\n!#%&*,-:?|>'\"[]{}", 1, -1)

const MAX_KEY_LENGTH = 1024
const TAB_INDENTATION = "found a tab character used as indentation"

const URI_PATTERN = "^[%w%-#;/?:@&=+$,_.!~*'()%[%]%%]*"
-- uri characters, except '!' and flow indicators
const TAG_PATTERN = "^[%w%-#;/?:@&=+$_.~*'()%%]*"
-- anchor names run until whitespace or a flow indicator
const ANCHOR_PATTERN = "^[^ \t\n,%[%]{}]*"

const peek, column = reader.peek, reader.column
const WHITESPACE, FLOW_INDICATORS = reader.WHITESPACE, reader.FLOW_INDICATORS

const function emit(state: State, kind: string): Event
	const event: Event = {
		kind = kind,
		line = state.line,
		column = column(state),
		value = "",
		style = "plain",
		flow = false,
		explicit = false,
	}
	table.insert(state.events, event)
	return event
end

-- inserts a mapping start before the key whose first event is at `index`, once a ':' shows it is a key
const function insert_mapping_start(state: State, index: number, flow: boolean)
	const start = emit(state, "mapping_start")
	start.flow = flow
	start.line = state.events[index].line
	start.column = state.events[index].column
	table.insert(state.events, index, table.remove(state.events) :: Event)
end

-- quoted scalars and flow collections, like json, may be followed directly by a ':'
const function is_json_like(event: Event): boolean
	return event.flow or event.style == "single_quoted" or event.style == "double_quoted"
end

-- whether the current character is the indicator `byte` followed by whitespace, as in "- " or ": "
const function at_indicator(state: State, byte: number): boolean
	return peek(state, 0) == byte and WHITESPACE[peek(state, 1)] == true
end

-- tabs may separate tokens, but never form the indentation that block structure is measured from
const function check_tab_indentation(state: State)
	assert(not reader.has_tab_before(state), TAB_INDENTATION)
end

-- separation inside a flow collection, which must be closed within its document and keep its lines
-- indented past the block collection around it
const function skip_flow_separation(state: State, parent_indent: number)
	reader.skip_separation(state)
	assert(
		peek(state, 0) ~= reader.EOF and not reader.document_marker(state),
		"did not find expected end of flow collection"
	)
	assert(
		not reader.is_first_on_line(state) or reader.indentation(state) > parent_indent,
		"found invalid indentation in flow collection"
	)
end

-- reads a tag and resolves it against the document's tag handles
const function scan_tag(state: State, in_flow: boolean): string
	state.pos += 1
	local tag: string
	if peek(state, 0) == string.byte("<") then
		-- verbatim tags are used as written
		state.pos += 1
		tag = reader.scan(state, URI_PATTERN)
		assert(tag ~= "" and peek(state, 0) == string.byte(">"), "did not find expected '>' after verbatim tag")
		state.pos += 1
	else
		-- "!suffix", "!!suffix" or "!handle!suffix"
		local handle = "!"
		local suffix = reader.scan(state, "^[%w%-]*")
		if peek(state, 0) == BANG then
			state.pos += 1
			handle = `!{suffix}!`
			suffix = ""
		end
		suffix ..= reader.scan(state, TAG_PATTERN)
		assert(suffix ~= "" or #handle <= 2, "did not find expected tag suffix")

		const prefix = state.tag_handles[handle]
		assert(prefix, `found undefined tag handle {handle}`)
		const decoded = string.gsub(suffix, "%%(%x%x)", function(hex: string): string
			return string.char(tonumber(hex, 16) :: number)
		end)
		tag = if handle == "!" and suffix == "" then "!" else prefix .. decoded
	end

	assert(
		WHITESPACE[peek(state, 0)] or (in_flow and FLOW_INDICATORS[peek(state, 0)]),
		"did not find expected whitespace or line break after tag"
	)
	return tag
end

-- reads the anchor and tag that may precede a node, in either order
const function parse_properties(state: State, parent_indent: number, in_flow: boolean): Properties?
	if peek(state, 0) ~= AMPERSAND and peek(state, 0) ~= BANG then
		return nil
	end

	const properties: Properties = { line = state.line, column = column(state) }
	while peek(state, 0) == AMPERSAND or peek(state, 0) == BANG do
		if peek(state, 0) == BANG then
			assert(not properties.tag, "found more than one tag on a node")
			properties.tag = scan_tag(state, in_flow)
		else
			assert(not properties.anchor, "found more than one anchor on a node")
			state.pos += 1
			properties.anchor = reader.scan(state, ANCHOR_PATTERN)
			assert(properties.anchor ~= "", "did not find expected anchor name")
		end

		if in_flow then
			skip_flow_separation(state, parent_indent)
		else
			reader.scan(state, "^[ \t]*")
		end
	end
	return properties
end

-- reads properties that end their line, moving on to the next line. properties that share a line with
-- their node are left in place for that node to read
const function parse_own_line_properties(state: State, parent_indent: number): Properties?
	if peek(state, 0) ~= AMPERSAND and peek(state, 0) ~= BANG then
		return nil
	end
	const before = reader.mark(state)
	const properties = parse_properties(state, parent_indent, false)
	if not properties or (peek(state, 0) ~= HASH and peek(state, 0) ~= LINE_FEED) then
		reader.restore(state, before)
		return nil
	end
	reader.skip_separation(state)
	return properties
end

-- combines properties written in separate places that belong to one node
const function merge_properties(into: Properties | Event, from: Properties)
	assert(
		not (from.anchor and into.anchor) and not (from.tag and into.tag),
		"found more than one anchor or tag on a node"
	)
	into.anchor = into.anchor or from.anchor
	into.tag = into.tag or from.tag
end

-- gives properties to the node whose first event is at `index`
const function attach_properties(state: State, index: number, properties: Properties?)
	if not properties then
		return
	end
	const event = state.events[index]
	assert(event.kind ~= "alias", "an alias cannot have properties")
	merge_properties(event, properties)
	event.line = properties.line
	event.column = properties.column
end

local parse_flow_collection: (state: State, parent_indent: number) -> ()

-- reads an alias, or a scalar or flow collection with any properties in front of it. in block context
-- it may also be a block scalar. the node's first event carries its properties and starting position
const function parse_flow_node(state: State, parent_indent: number, in_flow: boolean)
	const line, start_column = state.line, column(state)
	const index = #state.events + 1
	if peek(state, 0) == STAR then
		state.pos += 1
		const event = emit(state, "alias")
		event.value = reader.scan(state, ANCHOR_PATTERN)
		event.column = start_column
		assert(event.value ~= "", "did not find expected alias name")
		return
	end

	const properties = parse_properties(state, parent_indent, in_flow)
	const byte = peek(state, 0)
	assert(byte ~= STAR, "an alias cannot have properties")
	if byte == OPEN_BRACKET or byte == OPEN_BRACE then
		parse_flow_collection(state, parent_indent)
	elseif byte == SINGLE_QUOTE or byte == DOUBLE_QUOTE then
		const event = emit(state, "scalar")
		event.value, event.style = scalars.scan_quoted(state, parent_indent)
	elseif not in_flow and (byte == PIPE or byte == GREATER) then
		const event = emit(state, "scalar")
		event.value, event.style = scalars.scan_block(state, parent_indent)
	elseif scalars.can_start_plain(byte, peek(state, 1), in_flow) then
		emit(state, "scalar").value = scalars.scan_plain(state, parent_indent, in_flow)
	else
		-- properties alone make a node with empty content
		assert(properties, "did not find expected node content")
		emit(state, "scalar")
	end

	const event = state.events[index]
	event.line = line
	event.column = start_column
	if properties then
		event.anchor = properties.anchor
		event.tag = properties.tag
	end
end

-- a ':' ends a flow key when followed by whitespace or a flow indicator, or directly after a json-like key
const function at_flow_value(state: State, after_json: boolean): boolean
	const next_byte = peek(state, 1)
	return peek(state, 0) == COLON
		and (WHITESPACE[next_byte] == true or FLOW_INDICATORS[next_byte] == true or after_json)
end

-- reads a node inside a flow collection, or an empty scalar when the entry or key ends first
const function parse_optional_flow_node(state: State, parent_indent: number)
	const byte = peek(state, 0)
	if byte == COMMA or byte == CLOSE_BRACKET or byte == CLOSE_BRACE or at_flow_value(state, false) then
		emit(state, "scalar")
	else
		parse_flow_node(state, parent_indent, true)
	end
end

-- reads one entry of a flow collection: a node, an implicit "key: value" pair, or an explicit
-- "? key: value" pair. inside a sequence, a pair becomes a mapping with that one entry
const function parse_flow_entry(state: State, parent_indent: number, in_mapping: boolean)
	const index = #state.events + 1
	const line = state.line

	-- explicit "? key" entries and ": value" entries with an empty key are always pairs
	local is_pair = true
	if peek(state, 0) == QUESTION and (WHITESPACE[peek(state, 1)] or FLOW_INDICATORS[peek(state, 1)]) then
		state.pos += 1
		skip_flow_separation(state, parent_indent)
		parse_optional_flow_node(state, parent_indent)
	elseif at_flow_value(state, false) then
		emit(state, "scalar")
	else
		parse_flow_node(state, parent_indent, true)
		is_pair = false
	end
	skip_flow_separation(state, parent_indent)

	const has_value = at_flow_value(state, is_json_like(state.events[index]))
	assert(
		not has_value or is_pair or in_mapping or state.line == line,
		"implicit keys inside flow sequences must be on a single line"
	)

	const single_pair = not in_mapping and (is_pair or has_value)
	if single_pair then
		insert_mapping_start(state, index, true)
	end
	if has_value then
		state.pos += 1
		skip_flow_separation(state, parent_indent)
		parse_optional_flow_node(state, parent_indent)
	elseif in_mapping or single_pair then
		emit(state, "scalar")
	end
	if single_pair then
		emit(state, "mapping_end")
	end
end

function parse_flow_collection(state: State, parent_indent: number)
	const in_mapping = peek(state, 0) == OPEN_BRACE
	const closer = if in_mapping then CLOSE_BRACE else CLOSE_BRACKET
	emit(state, if in_mapping then "mapping_start" else "sequence_start").flow = true
	state.pos += 1

	while true do
		skip_flow_separation(state, parent_indent)
		if peek(state, 0) == closer then
			break
		end

		parse_flow_entry(state, parent_indent, in_mapping)
		skip_flow_separation(state, parent_indent)
		if peek(state, 0) == COMMA then
			state.pos += 1
		else
			assert(peek(state, 0) == closer, "did not find expected ',' or end of flow collection")
		end
	end

	state.pos += 1
	emit(state, if in_mapping then "mapping_end" else "sequence_end")
end

-- block collections may start on the same line after "- ", "? " and the ": " of an explicit key
const function allows_compact(context: BlockContext): boolean
	return context == "sequence_entry" or context == "explicit_entry"
end

-- a mapping's keys and values may be sequences written at the mapping's own indentation
const function allows_indentless(context: BlockContext): boolean
	return context == "explicit_entry" or context == "mapping_value"
end

-- a block node ends where the next content sits at or left of its parent's indentation, unless it is
-- an indentless sequence
const function at_block_end(state: State, parent_indent: number, context: BlockContext): boolean
	if peek(state, 0) == reader.EOF or reader.document_marker(state) then
		return true
	end
	if not reader.is_first_on_line(state) or column(state) > parent_indent then
		return false
	end
	return not (allows_indentless(context) and column(state) == parent_indent and at_indicator(state, DASH))
end

-- moves to the next entry of a block collection at `indent`, returning false once the collection ends
const function next_block_entry(state: State, indent: number): boolean
	reader.skip_separation(state)
	if peek(state, 0) == reader.EOF or reader.document_marker(state) then
		return false
	end
	if reader.is_first_on_line(state) and column(state) < indent then
		return false
	end
	assert(reader.is_first_on_line(state) and column(state) == indent, "did not find expected key or '-' indicator")
	return true
end

-- parses a node that may turn out to be an implicit key, and returns whether it is one: a ':' follows it
-- on the line it started on
const function parse_possible_key(state: State, parent_indent: number): boolean
	const index, line, start = #state.events + 1, state.line, state.pos
	parse_flow_node(state, parent_indent, false)

	const style = state.events[index].style
	if style == "literal" or style == "folded" then
		return false
	end
	reader.scan(state, "^[ \t]*")
	if not at_indicator(state, COLON) then
		return false
	end
	assert(
		state.line == line and state.pos - start <= MAX_KEY_LENGTH,
		"implicit keys must be on a single line and at most 1024 characters long"
	)
	return true
end

local parse_block_node: (state: State, parent_indent: number, context: BlockContext) -> ()

-- reads the entries of a block sequence at `indent`, after its start event. an indentless sequence sits
-- at its parent mapping's indentation, and ends where that mapping continues
const function parse_block_sequence(state: State, indent: number, indentless: boolean)
	while true do
		check_tab_indentation(state)
		state.pos += 1
		parse_block_node(state, indent, "sequence_entry")
		if not next_block_entry(state, indent) then
			break
		end
		if not at_indicator(state, DASH) then
			assert(indentless, "did not find expected '-' indicator")
			break
		end
	end
	emit(state, "sequence_end")
end

-- reads the key that starts a block mapping entry
const function parse_mapping_key(state: State, indent: number): KeyStyle
	check_tab_indentation(state)
	if at_indicator(state, QUESTION) then
		state.pos += 1
		parse_block_node(state, indent, "explicit_entry")
		reader.skip_separation(state)
		return "explicit"
	end
	if at_indicator(state, COLON) then
		emit(state, "scalar")
		return "empty"
	end

	const is_key = parse_possible_key(state, indent)
	assert(is_key, "could not find expected ':'")
	return "implicit"
end

-- reads the value of a block mapping entry, or an empty scalar when it has none
const function parse_mapping_value(state: State, indent: number, key_style: KeyStyle)
	-- after "? key", the ':' starts its own line at the mapping's indentation
	const explicit_key = key_style == "explicit"
	const placed = not explicit_key or (reader.is_first_on_line(state) and column(state) == indent)
	if not placed or not at_indicator(state, COLON) then
		emit(state, "scalar")
		return
	end

	if explicit_key then
		check_tab_indentation(state)
	end
	state.pos += 1
	parse_block_node(state, indent, if key_style == "implicit" then "mapping_value" else "explicit_entry")
end

-- reads the entries of a block mapping at `indent`, after its start event. `first_key` is given when the
-- caller already read the first entry's key
const function parse_block_mapping(state: State, indent: number, first_key: KeyStyle?)
	local key_style = first_key or parse_mapping_key(state, indent)
	while true do
		parse_mapping_value(state, indent, key_style)
		if not next_block_entry(state, indent) then
			break
		end
		key_style = parse_mapping_key(state, indent)
	end
	emit(state, "mapping_end")
end

-- reads a block sequence or mapping, or a flow node that may be the first key of a block mapping
const function parse_block_content(state: State, parent_indent: number, context: BlockContext, properties: Properties?)
	const indent = column(state)
	const can_open = allows_compact(context) or reader.is_first_on_line(state)

	if at_indicator(state, DASH) or at_indicator(state, QUESTION) or at_indicator(state, COLON) then
		assert(can_open, "block collections are not allowed in this context")
		const is_sequence = at_indicator(state, DASH)
		emit(state, if is_sequence then "sequence_start" else "mapping_start")
		attach_properties(state, #state.events, properties)
		if is_sequence then
			parse_block_sequence(state, indent, indent == parent_indent)
		else
			parse_block_mapping(state, indent, nil)
		end
		return
	end

	const index = #state.events + 1
	const tab_indented = reader.has_tab_before(state)
	if not parse_possible_key(state, parent_indent) then
		attach_properties(state, index, properties)
		return
	end

	assert(can_open, "mapping values are not allowed in this context")
	assert(not tab_indented, TAB_INDENTATION)
	insert_mapping_start(state, index, false)
	attach_properties(state, index, properties)
	parse_block_mapping(state, indent, "implicit")
end

-- reads the node after an indicator, which may also start on a later line. properties on lines of their
-- own belong to the node on the following lines, as long as those lines are still part of this node
function parse_block_node(state: State, parent_indent: number, context: BlockContext)
	reader.skip_separation(state)
	local properties: Properties? = nil
	while not at_block_end(state, parent_indent, context) do
		const own_line = parse_own_line_properties(state, parent_indent)
		if not own_line then
			parse_block_content(state, parent_indent, context, properties)
			return
		end

		if properties then
			merge_properties(properties, own_line)
		else
			properties = own_line
		end
	end

	emit(state, "scalar")
	attach_properties(state, #state.events, properties)
end

const function parse_directive(state: State, declared: { [string]: boolean })
	local text = string.sub(reader.scan(state, "^[^\n]*"), 2)
	text = string.sub(text, 1, (string.find(text, "[ \t]#") or 0) - 1)
	const words: { string } = {}
	for word in string.gmatch(text, "[^ \t]+") do
		table.insert(words, word)
	end
	assert(words[1], "did not find expected directive name")

	-- %YAML may appear once, and %TAG once per handle
	const name = if words[1] == "TAG" then words[2] else words[1]
	assert(not declared[name], `found duplicate %{words[1]} directive`)
	declared[name] = true

	if words[1] == "YAML" then
		assert(
			#words == 2 and string.match(words[2], "^(%d+)%.%d+$") == "1",
			"found invalid or incompatible %YAML directive"
		)
	elseif words[1] == "TAG" then
		assert(#words == 3 and (string.find(words[2], "^!.*!$") or words[2] == "!"), "found invalid %TAG directive")
		state.tag_handles[words[2]] = words[3]
	end
end

const function parse_document(state: State)
	state.tag_handles = { ["!"] = "!", ["!!"] = "tag:yaml.org,2002:" }
	const declared: { [string]: boolean } = {}
	local has_directives = false
	while column(state) == 0 and peek(state, 0) == PERCENT do
		parse_directive(state, declared)
		has_directives = true
		reader.skip_separation(state)
	end

	const explicit = reader.document_marker(state) == "---"
	assert(explicit or not has_directives, "did not find expected '---' after directives")
	emit(state, "document_start").explicit = explicit
	if explicit then
		state.pos += 3
	end
	parse_block_node(state, -1, "document")

	reader.skip_separation(state)
	if reader.document_marker(state) == "..." then
		emit(state, "document_end").explicit = true
		state.pos += 3
		reader.expect_line_end(state)
	else
		assert(peek(state, 0) == reader.EOF or reader.document_marker(state), "did not find expected end of document")
		emit(state, "document_end")
	end
end

const function parse_stream(state: State)
	assert(not string.find(state.src, "\0", 1, true), "found a nul character, which yaml text cannot contain")
	emit(state, "stream_start")
	while true do
		reader.skip_separation(state)
		if peek(state, 0) == reader.EOF then
			break
		end
		if reader.document_marker(state) == "..." then
			-- stray "..." markers between documents are allowed
			state.pos += 3
			reader.expect_line_end(state)
		else
			parse_document(state)
		end
	end
	emit(state, "stream_end")
end

const function parse(content: string): { Event }
	const state = reader.create(content) :: State
	state.events = {}
	state.tag_handles = {}

	const ok, problem = pcall(parse_stream, state)
	if not ok then
		-- failed assertions name the parser's own source line; the position in the yaml is what helps
		const message = string.gsub(tostring(problem), "^.-:%d+: ", "")
		error(`{message} at {reader.describe_position(state)}`, 0)
	end
	return state.events
end

return parse
