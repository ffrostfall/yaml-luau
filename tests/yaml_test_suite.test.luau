-- runs the official yaml-test-suite, vendored from the data-2022-01-17 release of
-- https://github.com/yaml/yaml-test-suite (commit 6e6c296a) without its name/ and tags/ index folders

const compare_json = require("@tests/helpers/compare_json")
const compose = require("@src/compose")
const format_events = require("@tests/helpers/format_events")
const fs = require("@std/fs")
const parse = require("@src/parse")
const test = require("@std/test")
const yaml = require("@src")

const SUITE_DIRECTORY = "tests/samples/yaml-test-suite"

const function read_optional(file_path: string): string?
	if not fs.exists(file_path) then
		return nil
	end
	return fs.readFileToString(file_path)
end

-- cases live in `<id>/`, or `<id>/<variant>/` when one id covers several inputs
const function find_cases(): { string }
	const cases: { string } = {}
	for _, entry in fs.listDirectory(SUITE_DIRECTORY) do
		const directory = `{SUITE_DIRECTORY}/{entry.name}`
		if entry.type ~= "dir" then
			continue
		end
		if fs.exists(`{directory}/in.yaml`) then
			table.insert(cases, directory)
			continue
		end
		for _, variant in fs.listDirectory(directory) do
			if fs.exists(`{directory}/{variant.name}/in.yaml`) then
				table.insert(cases, `{directory}/{variant.name}`)
			end
		end
	end
	table.sort(cases)
	return cases
end

const function run_case(assert: any, directory: string)
	const input = fs.readFileToString(`{directory}/in.yaml`)

	if fs.exists(`{directory}/error`) then
		const ok, result = pcall(function()
			return format_events(parse(input))
		end)
		assert.that(not ok, `expected an error, but parsed as:\n{result}`)
		-- a crash inside the parser would also fail, so require a positioned yaml error
		assert.strContains(tostring(result), " at line ")
		return
	end

	const events = parse(input)
	assert.eq(format_events(events), fs.readFileToString(`{directory}/test.event`))

	const expected_json = read_optional(`{directory}/in.json`)
	if not expected_json then
		return
	end

	const documents = compose(events)
	const problem = compare_json(documents, expected_json)
	assert.that(problem == nil, problem)

	-- the serializer must write each document so that it reads back the same
	const reread: { any } = {}
	for _, document in documents do
		const text = yaml.serialize(document)
		const ok, result = pcall(yaml.deserialize, text)
		assert.that(ok, `serialized output failed to parse: {result}\n{text}`)
		table.insert(reread, result)
	end
	const round_trip_problem = compare_json(reread, expected_json)
	assert.that(round_trip_problem == nil, round_trip_problem)
end

test.suite("yaml-test-suite", function(suite)
	for _, directory in find_cases() do
		const id = string.sub(directory, #SUITE_DIRECTORY + 2)
		const name = read_optional(`{directory}/===`) or ""
		suite:case(`{id} {string.gsub(name, "%s+$", "")}`, function(assert)
			run_case(assert, directory)
		end)
	end
end)
