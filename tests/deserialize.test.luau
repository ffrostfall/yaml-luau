const test = require("@std/test")
const yaml = require("@src")

test.suite("deserialize", function(suite)
	suite:case("returns one value per document in the stream", function(assert)
		const first, second, third = yaml.deserialize("--- a\n--- [b]\n...\n--- { c: d }\n")

		assert.eq(first, "a")
		assert.eq(second, { "b" })
		assert.eq(third, { c = "d" })
	end)

	suite:case("returns nothing for a stream without documents", function(assert)
		assert.eq(select("#", yaml.deserialize("")), 0)
		assert.eq(select("#", yaml.deserialize("# only a comment\n")), 0)
	end)

	suite:case("reads null as the null sentinel so it survives inside tables", function(assert)
		const document = yaml.deserialize("list: [1, ~, null, 3]\nempty:\n")

		assert.eq(#document.list, 4)
		assert.eq(document.list[2], yaml.null)
		assert.eq(document.list[3], yaml.null)
		assert.eq(document.empty, yaml.null)
	end)

	suite:case("resolves plain scalars with the core schema", function(assert)
		const document = yaml.deserialize("[42, -7, 0o17, 0x1F, 1.5, 6.02e23, .inf, -.Inf, true, False, yes, 1_000]")

		assert.eq(document, { 42, -7, 15, 31, 1.5, 6.02e23, math.huge, -math.huge, true, false, "yes", "1_000" })
	end)

	suite:case("reads .nan as nan", function(assert)
		const value = yaml.deserialize(".nan")
		assert.that(value ~= value)
	end)

	suite:case("keeps quoted and block scalars as strings", function(assert)
		const document = yaml.deserialize("- '42'\n- \"true\"\n- |\n  null\n")
		assert.eq(document, { "42", "true", "null\n" })
	end)

	suite:case("converts scalars with an explicit core tag", function(assert)
		const document = yaml.deserialize("- !!int '42'\n- !!str 42\n- !!float 3\n- !!bool 'true'\n- ! 12\n")
		assert.eq(document, { 42, "42", 3, true, "12" })
	end)

	suite:case("rejects text that is invalid for its explicit tag", function(assert)
		assert.throwsWith(
			"found invalid value for tag tag:yaml.org,2002:int at line 1, column 1",
			yaml.deserialize,
			"!!int abc"
		)
	end)

	suite:case("makes aliases refer to the same table as their anchor", function(assert)
		const document = yaml.deserialize("base: &base { a: 1 }\ncopy: *base\n")
		assert.that(rawequal(document.base, document.copy))
	end)

	suite:case("supports aliases that refer back to their own collection", function(assert)
		const document = yaml.deserialize("&node\nname: loop\nself: *node\n")
		assert.that(rawequal(document.self, document))
	end)

	suite:case("uses collections written as explicit keys as table keys", function(assert)
		const document = yaml.deserialize("? [a, b]\n: joined\n")

		const key = next(document)
		assert.eq(key, { "a", "b" })
		assert.eq(document[key], "joined")
	end)

	suite:case("rejects duplicate mapping keys", function(assert)
		assert.throwsWith("found duplicate mapping key at line 2, column 1", yaml.deserialize, "a: 1\na: 2\n")
	end)

	suite:case("rejects aliases to anchors that were never defined", function(assert)
		assert.throwsWith("found undefined alias missing at line 1, column 4", yaml.deserialize, "a: *missing")
	end)

	suite:case("reports the line and column of invalid input", function(assert)
		assert.throwsWith(
			"mapping values are not allowed in this context at line 2, column 11",
			yaml.deserialize,
			"key: value\nother: bad: value\n"
		)
	end)

	suite:case("treats windows line endings like unix ones", function(assert)
		assert.eq(yaml.deserialize("a: |\r\n  x\r\n  y\r\nb: 2\r\n"), { a = "x\ny\n", b = 2 })
	end)

	suite:case("rejects input that is not a string", function(assert)
		assert.throwsWith("expected yaml text as a string, got number", yaml.deserialize :: any, 42)
	end)
end)
