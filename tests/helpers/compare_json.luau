-- compares deserialized yaml documents against the json the yaml-test-suite expects

const json = require("@vendor/json")
const null = require("@src/null")

-- the expected json holds one value per document, each starting on a new line,
-- so lines are gathered until they parse
const function split_values(text: string): { any }
	const values = {}
	local pending = ""
	for _, line in string.split(text, "\n") do
		pending ..= line .. "\n"
		if string.find(pending, "%S") then
			const ok, value = pcall(json.deserialize, pending)
			if ok then
				table.insert(values, value)
				pending = ""
			end
		end
	end
	return values
end

const function format_key(key: any): string
	return if typeof(key) == "number" and key == math.floor(key) then string.format("%d", key) else tostring(key)
end

-- returns nil when equal, or a description of the first difference
const function difference(actual: any, expected: any, location: string): string?
	if expected == json.null then
		return if actual == null then nil else `{location}: expected null, got {tostring(actual)}`
	end
	if typeof(expected) ~= "table" or typeof(actual) ~= "table" then
		return if actual == expected then nil else `{location}: expected {tostring(expected)}, got {tostring(actual)}`
	end

	-- { [stringified key]: value }
	const normalized: { [string]: any } = {}
	for key, value in actual do
		normalized[format_key(key)] = value
	end
	const expected_keys: { [string]: boolean } = {}
	for key, value in expected do
		expected_keys[format_key(key)] = true
		const problem = difference(normalized[format_key(key)], value, `{location}.{format_key(key)}`)
		if problem then
			return problem
		end
	end
	for key in normalized do
		if not expected_keys[key] then
			return `{location}: unexpected key {key}`
		end
	end
	return nil
end

const function compare_json(documents: { any }, expected_json: string): string?
	const expected = split_values(expected_json)
	if #expected ~= #documents then
		return `expected {#expected} documents, got {#documents}`
	end
	for index, value in expected do
		const problem = difference(documents[index], value, `document {index}`)
		if problem then
			return problem
		end
	end
	return nil
end

return compare_json
