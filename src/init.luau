const compose = require("@self/compose")
const null = require("@self/null")
const parse = require("@self/parse")
const serialize = require("@self/serialize")

const yaml_luau = {}

--[=[
	The value yaml `null` is read as, since `nil` cannot be stored in a table.
	Serializing it (or `nil`) writes `null`.
]=]
yaml_luau.null = null

--[=[
	Writes a value as block-style yaml, ending with a newline.

	Tables whose keys are exactly `1..n` become sequences and other tables become mappings, with keys sorted.
	A table referenced more than once (including cycles) is written once with an anchor and aliased afterwards.
]=]
function yaml_luau.serialize(content: unknown): string
	return serialize(content)
end

--[=[
	Reads yaml text using the yaml 1.2 core schema, returning one value per document in the stream.

	Mappings and sequences become tables, aliases refer to the same table as their anchor, and null becomes
	`yaml_luau.null`. Errors with the line and column of invalid input.
]=]
function yaml_luau.deserialize(content: string): ...any
	if typeof(content) ~= "string" then
		error(`expected yaml text as a string, got {typeof(content)}`, 2)
	end
	return table.unpack(compose(parse(content)))
end

return table.freeze(yaml_luau)
