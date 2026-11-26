-- builds luau values from parse events: mappings and sequences become tables, aliases share them

const parse = require("./parse")
const schema = require("./schema")

type Event = parse.Event

type State = {
	events: { Event },
	index: number,
	-- { [anchor name]: value }
	anchors: { [string]: any },
}

const function scalar_value(event: Event): any
	if event.tag == nil then
		-- only plain scalars are resolved; quoted and block scalars are always strings
		return if event.style == "plain" then schema.resolve_plain(event.value) else event.value
	end

	const value = schema.resolve_tagged(event.value, event.tag)
	assert(value ~= nil, `found invalid value for tag {event.tag}`)
	return value
end

local compose_node: (state: State) -> any

-- reads entries up to the sequence's end event
const function compose_sequence(state: State, sequence: { any })
	while state.events[state.index].kind ~= "sequence_end" do
		table.insert(sequence, compose_node(state))
	end
	state.index += 1
end

-- reads key and value pairs up to the mapping's end event
const function compose_mapping(state: State, mapping: { [any]: any })
	while state.events[state.index].kind ~= "mapping_end" do
		const key = compose_node(state)
		assert(key == key, "found nan as a mapping key")
		assert(mapping[key] == nil, "found duplicate mapping key")
		mapping[key] = compose_node(state)
	end
	state.index += 1
end

function compose_node(state: State): any
	const event = state.events[state.index]
	state.index += 1

	if event.kind == "alias" then
		const value = state.anchors[event.value]
		assert(value ~= nil, `found undefined alias {event.value}`)
		return value
	end
	if event.kind == "scalar" then
		const value = scalar_value(event)
		if event.anchor then
			state.anchors[event.anchor] = value
		end
		return value
	end

	-- a collection is registered under its anchor before its entries, so they can alias it
	const collection = {}
	if event.anchor then
		state.anchors[event.anchor] = collection
	end
	if event.kind == "sequence_start" then
		compose_sequence(state, collection)
	else
		compose_mapping(state, collection)
	end
	return collection
end

const function compose_documents(state: State, documents: { any })
	while state.events[state.index].kind == "document_start" do
		state.index += 1
		state.anchors = {}
		table.insert(documents, compose_node(state))
		state.index += 1
	end
end

-- returns the value of every document in the stream, in order
const function compose(events: { Event }): { any }
	const state: State = {
		events = events,
		index = 2,
		anchors = {},
	}

	const documents: { any } = {}
	const ok, problem = pcall(compose_documents, state, documents)
	if not ok then
		-- failures concern the event just read; assertions also name this file's line, which is dropped
		const message = string.gsub(tostring(problem), "^.-:%d+: ", "")
		const event = events[state.index - 1]
		error(`{message} at line {event.line}, column {event.column + 1}`, 0)
	end
	return documents
end

return compose
