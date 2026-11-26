-- formats parse events in the yaml-test-suite `test.event` notation

const parse = require("@src/parse")

-- { [scalar style]: indicator }
const STYLE_INDICATORS: { [string]: string } = {
	plain = ":",
	single_quoted = "'",
	double_quoted = '"',
	literal = "|",
	folded = ">",
}

-- { [character]: escape }
const ESCAPES: { [string]: string } = {
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\t"] = "\\t",
	["\n"] = "\\n",
	["\r"] = "\\r",
}

const function format_properties(event: parse.Event): string
	local text = ""
	if event.anchor then
		text ..= ` &{event.anchor}`
	end
	if event.tag then
		text ..= ` <{event.tag}>`
	end
	return text
end

const function format_event(event: parse.Event): string
	const kind = event.kind
	if kind == "stream_start" then
		return "+STR"
	elseif kind == "stream_end" then
		return "-STR"
	elseif kind == "document_start" then
		return if event.explicit then "+DOC ---" else "+DOC"
	elseif kind == "document_end" then
		return if event.explicit then "-DOC ..." else "-DOC"
	elseif kind == "mapping_start" then
		return (if event.flow then "+MAP {}" else "+MAP") .. format_properties(event)
	elseif kind == "mapping_end" then
		return "-MAP"
	elseif kind == "sequence_start" then
		return (if event.flow then "+SEQ []" else "+SEQ") .. format_properties(event)
	elseif kind == "sequence_end" then
		return "-SEQ"
	elseif kind == "alias" then
		return `=ALI *{event.value}`
	end

	const value = string.gsub(event.value, "[\\\b\t\n\r]", ESCAPES)
	return `=VAL{format_properties(event)} {STYLE_INDICATORS[event.style]}{value}`
end

const function format_events(events: { parse.Event }): string
	const lines: { string } = {}
	for _, event in events do
		table.insert(lines, format_event(event))
	end
	return table.concat(lines, "\n") .. "\n"
end

return format_events
