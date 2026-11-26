--!native
--!optimize 2
-- reads the text of scalars: plain, single and double quoted, and literal or folded block scalars, in
-- that order after the line folding they share. every reader takes `parent_indent`, the indentation
-- of the enclosing block collection, which continuation lines must be indented past

const reader = require("./reader")

export type Style = "plain" | "single_quoted" | "double_quoted" | "literal" | "folded"

type Reader = reader.Identity

const TAB, LINE_FEED, SPACE, HASH, DASH, COLON, QUESTION, BACKSLASH, PIPE, SINGLE_QUOTE =
	string.byte("\t\n #-:?\\|'", 1, -1)
const EOF = reader.EOF
const WHITESPACE, FLOW_INDICATORS = reader.WHITESPACE, reader.FLOW_INDICATORS
const peek, column, newline, scan = reader.peek, reader.column, reader.newline, reader.scan

const function byte_set(characters: string): { [number]: boolean }
	const set = {}
	for index = 1, #characters do
		set[string.byte(characters, index)] = true
	end
	return set
end

const INDICATORS = byte_set("-?:,[]{}#&*!|>'\"%@`")

-- { [escape letter]: replacement }
const SIMPLE_ESCAPES: { [string]: string } = {
	["0"] = "\0",
	a = "\a",
	b = "\b",
	t = "\t",
	["\t"] = "\t",
	n = "\n",
	v = "\v",
	f = "\f",
	r = "\r",
	e = "\27",
	[" "] = " ",
	['"'] = '"',
	["/"] = "/",
	["\\"] = "\\",
	N = "\u{85}",
	_ = "\u{A0}",
	L = "\u{2028}",
	P = "\u{2029}",
}

-- { [escape letter]: hex digit count }
const HEX_ESCAPES: { [string]: number } = { x = 2, u = 4, U = 8 }

-- skips the blanks and line breaks inside a multi-line scalar, returning what line folding turns them
-- into and whether a line was crossed. blanks within a line are kept, one line break becomes a space
-- and each further one a newline. after an escaped line break (`joined`) only the newlines remain
const function scan_fold(state: Reader, joined: boolean): (string, boolean)
	const blanks = scan(state, "^[ \t]*")
	local breaks = 0
	while peek(state, 0) == LINE_FEED do
		newline(state)
		scan(state, "^[ \t]*")
		breaks += 1
	end

	if joined then
		return string.rep("\n", breaks), true
	end
	if breaks == 0 then
		return blanks, false
	end
	return if breaks == 1 then " " else string.rep("\n", breaks - 1), true
end

-- whether the current character ends a run of plain text: whitespace, ": ", and in flow collections
-- also flow indicators and ':' before one
const function ends_plain_run(state: Reader, in_flow: boolean): boolean
	const byte = peek(state, 0)
	const target = if byte == COLON then peek(state, 1) else byte
	return WHITESPACE[target] == true or (in_flow and FLOW_INDICATORS[target] == true)
end
-- reads `length` hex digits starting `offset` bytes past the current position
const function read_hex(state: Reader, offset: number, length: number): number
	const digits = string.sub(state.src, state.pos + offset, state.pos + offset + length - 1)
	assert(
		string.find(digits, `^{string.rep("%x", length)}$`),
		"found invalid hexadecimal escape in double-quoted scalar"
	)
	return tonumber(digits, 16) :: number
end

-- reads one escape sequence, returning its text and whether it was an escaped line break
const function scan_escape(state: Reader): (string, boolean)
	const letter = string.char(peek(state, 1))
	if letter == "\n" then
		state.pos += 1
		newline(state)
		return "", true
	end
	if SIMPLE_ESCAPES[letter] then
		state.pos += 2
		return SIMPLE_ESCAPES[letter], false
	end

	const length = HEX_ESCAPES[letter]
	assert(length, "found unknown escape character in double-quoted scalar")
	local code = read_hex(state, 2, length)
	state.pos += length + 2

	const is_high_surrogate = code >= 0xD800 and code <= 0xDBFF
	if is_high_surrogate and peek(state, 0) == BACKSLASH and peek(state, 1) == string.byte("u") then
		-- combine utf-16 surrogate pairs, as json-style producers emit them
		const low = read_hex(state, 2, 4)
		assert(low >= 0xDC00 and low <= 0xDFFF, "found invalid unicode surrogate pair")
		state.pos += 6
		code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
	end
	assert(code <= 0x10FFFF, "found invalid unicode escape")
	return utf8.char(code), false
end

-- consumes indentation and empty lines inside a block scalar whose indentation is known
const function scan_block_breaks(state: Reader, indent: number): string
	local count = 0
	while true do
		while column(state) < indent and peek(state, 0) == SPACE do
			state.pos += 1
		end
		if peek(state, 0) ~= LINE_FEED then
			return string.rep("\n", count)
		end
		count += 1
		newline(state)
	end
end

-- consumes leading empty lines and settles the indentation from the first non-empty line
const function detect_block_indent(state: Reader, parent_indent: number): (number, string)
	local count = 0
	local max_empty_indent = 0
	while true do
		scan(state, "^ *")
		if peek(state, 0) ~= LINE_FEED then
			break
		end
		max_empty_indent = math.max(max_empty_indent, column(state))
		count += 1
		newline(state)
	end

	const content_column = column(state)
	assert(
		peek(state, 0) ~= TAB or content_column > parent_indent,
		"found a tab character where block scalar indentation was expected"
	)
	-- without content, the empty lines only matter for keeping trailing line breaks
	if peek(state, 0) == EOF or content_column <= parent_indent then
		return math.max(max_empty_indent, parent_indent + 1), string.rep("\n", count)
	end
	assert(
		content_column >= max_empty_indent,
		"leading empty lines of a block scalar must not be indented more than its content"
	)
	return content_column, string.rep("\n", count)
end

const scalars = {}

-- a plain scalar may start with any character but an indicator, or with "-", "?" or ":" before text
function scalars.can_start_plain(byte: number, next_byte: number, in_flow: boolean): boolean
	if not INDICATORS[byte] then
		return not WHITESPACE[byte]
	end
	return (byte == DASH or byte == QUESTION or byte == COLON)
		and not WHITESPACE[next_byte]
		and not (in_flow and FLOW_INDICATORS[next_byte])
end

-- reads a plain scalar, leaving the position right after its last character rather than after the
-- whitespace that follows it
function scalars.scan_plain(state: Reader, parent_indent: number, in_flow: boolean): string
	const parts: { string } = {}
	local separator, crossed = "", false
	const text_end = reader.mark(state)

	while not reader.document_marker(state) and peek(state, 0) ~= HASH do
		const start = state.pos
		const tab_indented = crossed and reader.has_leading_tab(state) and reader.indentation(state) <= parent_indent
		while not ends_plain_run(state, in_flow) do
			state.pos += 1
		end
		if state.pos == start then
			break
		end
		assert(not tab_indented, "found a tab character that violates indentation")

		table.insert(parts, separator)
		table.insert(parts, string.sub(state.src, start, state.pos - 1))
		reader.mark(state, text_end)

		separator, crossed = scan_fold(state, false)
		if crossed and not in_flow and column(state) <= parent_indent then
			break
		end
	end

	reader.restore(state, text_end)
	return table.concat(parts)
end

-- reads a single or double quoted scalar, starting at its opening quote
function scalars.scan_quoted(state: Reader, parent_indent: number): (string, Style)
	const quote = peek(state, 0)
	const single = quote == SINGLE_QUOTE
	state.pos += 1

	const parts: { string } = {}
	while true do
		assert(not reader.document_marker(state) and peek(state, 0) ~= EOF, "found unexpected end of quoted scalar")

		-- the text up to the next whitespace, closing quote or escaped line break
		local joined = false
		while not WHITESPACE[peek(state, 0)] and not joined do
			const byte = peek(state, 0)
			if single and byte == SINGLE_QUOTE and peek(state, 1) == SINGLE_QUOTE then
				table.insert(parts, "'")
				state.pos += 2
			elseif byte == quote then
				break
			elseif byte == BACKSLASH and not single then
				const text, line_break = scan_escape(state)
				table.insert(parts, text)
				joined = line_break
			else
				table.insert(parts, scan(state, if single then "^[^ \t\n']+" else '^[^ \t\n"\\]+'))
			end
		end
		if peek(state, 0) == quote and not joined then
			break
		end

		const separator, crossed = scan_fold(state, joined)
		assert(not crossed or reader.indentation(state) > parent_indent, "found invalid indentation in quoted scalar")
		table.insert(parts, separator)
	end

	state.pos += 1
	return table.concat(parts), if single then "single_quoted" else "double_quoted"
end

-- reads a literal ("|") or folded (">") block scalar, starting at its indicator
function scalars.scan_block(state: Reader, parent_indent: number): (string, Style)
	const literal = peek(state, 0) == PIPE
	state.pos += 1

	-- a chomping indicator (strip, clip or keep trailing lines) and an indentation indicator, in either order
	const header = scan(state, "^[%-+1-9]*")
	assert(
		string.find(header, "^[%-+]?[1-9]?$") or string.find(header, "^[1-9][%-+]$"),
		"found invalid block scalar header"
	)
	const strip = string.find(header, "-", 1, true) ~= nil
	const keep = string.find(header, "+", 1, true) ~= nil
	const increment = tonumber(string.match(header, "%d"))
	reader.expect_line_end(state)
	newline(state)

	local indent: number, trailing_breaks: string
	if increment then
		indent = parent_indent + increment
		trailing_breaks = scan_block_breaks(state, indent)
	else
		indent, trailing_breaks = detect_block_indent(state, parent_indent)
	end

	const parts: { string } = {}
	local leading_break = ""
	local leading_blank = false
	while column(state) == indent and peek(state, 0) ~= EOF and not reader.document_marker(state) do
		-- folding joins adjacent lines of ordinary text, but keeps breaks around indented lines
		const trailing_blank = reader.is_blank(peek(state, 0))
		if literal or leading_break == "" or leading_blank or trailing_blank then
			table.insert(parts, leading_break)
		elseif trailing_breaks == "" then
			table.insert(parts, " ")
		end
		table.insert(parts, trailing_breaks)
		table.insert(parts, scan(state, "^[^\n]*"))
		newline(state)
		leading_blank = trailing_blank
		leading_break = "\n"
		trailing_breaks = scan_block_breaks(state, indent)
	end

	if not strip then
		table.insert(parts, leading_break)
	end
	if keep then
		table.insert(parts, trailing_breaks)
	end
	return table.concat(parts), if literal then "literal" else "folded"
end

return table.freeze(scalars)
