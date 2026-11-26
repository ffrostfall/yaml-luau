--!native
--!optimize 2
-- a cursor over yaml text that keeps the line bookkeeping indentation rules depend on. it offers
-- character sets, queries about the current position and line, ways to move, and skipping of the
-- whitespace, comments and markers between nodes

export type Identity = {
	src: string,
	pos: number,
	line: number,
	-- position of the first character on the current line
	line_start: number,
	-- position of the first character on the current line that isn't a space or tab
	content_start: number,
}

-- a saved position to return to after looking ahead
export type Mark = {
	pos: number,
	line: number,
	line_start: number,
	content_start: number,
}

const TAB, LINE_FEED, SPACE, HASH, DASH, DOT = string.byte("\t\n #-.", 1, -1)
-- returned when peeking past the end of the text
const EOF = -1

const function byte_set(characters: string): { [number]: boolean }
	const set = {}
	for index = 1, #characters do
		set[string.byte(characters, index)] = true
	end
	return set
end

-- spaces, tabs, line breaks and the end of the text all separate tokens
const WHITESPACE = byte_set(" \t\n")
WHITESPACE[EOF] = true
table.freeze(WHITESPACE)

const FLOW_INDICATORS = table.freeze(byte_set(",[]{}"))

const function peek(state: Identity, offset: number): number
	return string.byte(state.src, state.pos + offset) or EOF
end

const function column(state: Identity): number
	return state.pos - state.line_start
end

const function start_line(state: Identity, pos: number)
	state.pos = pos
	state.line_start = pos
	state.content_start = string.find(state.src, "[^ \t]", pos) or pos
end

const reader = {}

reader.EOF = EOF
-- sets of character codes, indexed directly since they're checked for nearly every character
reader.WHITESPACE = WHITESPACE
reader.FLOW_INDICATORS = FLOW_INDICATORS

function reader.is_blank(byte: number): boolean
	return byte == SPACE or byte == TAB
end

function reader.create(content: string): Identity
	-- line breaks are normalized to "\n", and a final line without one reads as if it had one
	local src: string = string.gsub(content, "\r\n?", "\n")
	if string.sub(src, 1, 3) == "\u{FEFF}" then
		src = string.sub(src, 4)
	end
	if #src > 0 and string.sub(src, -1) ~= "\n" then
		src ..= "\n"
	end

	const state: Identity = {
		src = src,
		pos = 1,
		line = 1,
		line_start = 1,
		content_start = 1,
	}
	start_line(state, 1)
	return state
end

reader.peek = peek
reader.column = column

-- "line 2, column 5", counting characters rather than bytes
function reader.describe_position(state: Identity): string
	const prefix = string.sub(state.src, state.line_start, state.pos - 1)
	return `line {state.line}, column {(utf8.len(prefix) or #prefix) + 1}`
end

function reader.is_first_on_line(state: Identity): boolean
	return state.pos <= state.content_start
end

-- the number of spaces starting the current line. tabs never count as indentation
function reader.indentation(state: Identity): number
	return #(string.match(state.src, "^ *", state.line_start) :: string)
end

-- whether the whitespace starting the current line has a tab in it
function reader.has_leading_tab(state: Identity): boolean
	return state.content_start - state.line_start > reader.indentation(state)
end

-- whether the blanks right before the current position have a tab in them
function reader.has_tab_before(state: Identity): boolean
	for index = state.pos - 1, state.line_start, -1 do
		const byte = string.byte(state.src, index)
		if byte ~= SPACE then
			return byte == TAB
		end
	end
	return false
end

-- steps over the line feed at the current position
function reader.newline(state: Identity)
	state.line += 1
	start_line(state, state.pos + 1)
end

-- consumes the text matching an anchored pattern, which must not span lines
function reader.scan(state: Identity, pattern: string): string
	const text = string.match(state.src, pattern, state.pos) :: string
	state.pos += #text
	return text
end

-- `reuse` is overwritten instead of allocating a new mark, for marks taken repeatedly in a loop
function reader.mark(state: Identity, reuse: Mark?): Mark
	const mark = reuse or {} :: Mark
	mark.pos = state.pos
	mark.line = state.line
	mark.line_start = state.line_start
	mark.content_start = state.content_start
	return mark
end

function reader.restore(state: Identity, mark: Mark)
	state.pos = mark.pos
	state.line = mark.line
	state.line_start = mark.line_start
	state.content_start = mark.content_start
end

-- returns "---" or "..." when the current line starts with that marker
function reader.document_marker(state: Identity): string?
	const byte = peek(state, 0)
	const is_marker = column(state) == 0
		and (byte == DASH or byte == DOT)
		and peek(state, 1) == byte
		and peek(state, 2) == byte
		and WHITESPACE[peek(state, 3)] == true
	return if is_marker then string.rep(string.char(byte), 3) else nil
end

-- skips whitespace, comments and line breaks
function reader.skip_separation(state: Identity)
	while true do
		const byte = peek(state, 0)
		if byte == SPACE or byte == TAB then
			state.pos += 1
		elseif byte == LINE_FEED then
			reader.newline(state)
		elseif byte == HASH then
			assert(WHITESPACE[peek(state, -1)], "comments must be separated from other tokens by whitespace")
			reader.scan(state, "^[^\n]*")
		elseif byte == 0xEF and column(state) == 0 and peek(state, 1) == 0xBB and peek(state, 2) == 0xBF then
			-- a byte order mark may precede any document, and takes up no column
			start_line(state, state.pos + 3)
		else
			return
		end
	end
end

-- skips trailing blanks and an optional comment, which must end the line
function reader.expect_line_end(state: Identity)
	reader.scan(state, "^[ \t]*")
	if peek(state, 0) == HASH and reader.is_blank(peek(state, -1)) then
		reader.scan(state, "^[^\n]*")
	end
	const byte = peek(state, 0)
	assert(byte == LINE_FEED or byte == EOF, "did not find expected comment or line break")
end

return table.freeze(reader)
