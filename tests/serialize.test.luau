const test = require("@std/test")
const yaml = require("@src")

const function round_trip(value: any): any
	return yaml.deserialize(yaml.serialize(value))
end

test.suite("serialize", function(suite)
	suite:case("round trips nested mappings and sequences", function(assert)
		const value = {
			name = "service",
			ports = { 80, 443 },
			nested = { list = { { a = 1 }, { b = { 2, 3 } } }, empty = {} },
			enabled = true,
			ratio = 0.25,
			missing = yaml.null,
		}
		assert.eq(round_trip(value), value)
	end)

	suite:case("keeps strings that resemble other values as strings", function(assert)
		const strings = { "true", "False", "1", "-2.5", "0x10", ".inf", "null", "~", "", "yes", "off" }
		assert.eq(round_trip(strings), strings)
	end)

	suite:case("round trips strings that need quoting", function(assert)
		const strings = {
			" padded ",
			"a: b",
			"trailing:",
			"x #comment",
			"- item",
			"? key",
			"[flow]",
			"&anchor",
			"*alias",
			"!tag",
			"'single'",
			'"double"',
			"---",
			"...",
			"back\\slash",
		}
		assert.eq(round_trip(strings), strings)
	end)

	suite:case("round trips multi-line strings", function(assert)
		const strings = {
			"two\nlines",
			"trailing newline\n",
			"many trailing\n\n\n",
			"\nleading newline",
			"  indented first line\nsecond",
			"blank\n\nline inside",
			"tab\tinside\n",
		}
		assert.eq(round_trip({ text = strings }), { text = strings })
	end)

	suite:case("round trips control characters and unicode line separators", function(assert)
		const strings = {
			"nul\0byte",
			"bell\a",
			"escape\27",
			"carriage\rreturn",
			"next\u{85}line",
			"line\u{2028}sep",
			"\u{FEFF}bom",
			"émoji 🎉",
		}
		assert.eq(round_trip(strings), strings)
	end)

	suite:case("round trips special numbers", function(assert)
		const result = round_trip({ math.huge, -math.huge, math.nan, 1e300, 1e-7, -0.5, 2 ^ 53 })

		assert.eq(result[1], math.huge)
		assert.eq(result[2], -math.huge)
		assert.that(result[3] ~= result[3])
		assert.eq(result[4], 1e300)
		assert.eq(result[5], 1e-7)
		assert.eq(result[6], -0.5)
		assert.eq(result[7], 2 ^ 53)
	end)

	suite:case("round trips keys that are not strings", function(assert)
		const value = { [1.5] = "number", [true] = "boolean", [false] = "other", ["1.5"] = "string" }
		assert.eq(round_trip(value), value)
	end)

	suite:case("round trips tables used as keys", function(assert)
		const key = { "a", "b" }
		const result = round_trip({ [key] = "joined" })

		const result_key = next(result)
		assert.eq(result_key, key)
		assert.eq(result[result_key], "joined")
	end)

	suite:case("keeps shared tables shared", function(assert)
		const shared = { value = 1 }
		const result = round_trip({ first = shared, second = shared, list = { shared } })

		assert.eq(result.first, shared)
		assert.that(rawequal(result.first, result.second))
		assert.that(rawequal(result.first, result.list[1]))
	end)

	suite:case("writes cyclic tables", function(assert)
		const node: any = { name = "loop" }
		node.self = node
		node.children = { node }

		const result = round_trip(node)

		assert.eq(result.name, "loop")
		assert.that(rawequal(result.self, result))
		assert.that(rawequal(result.children[1], result))
	end)

	suite:case("writes the same text regardless of key insertion order", function(assert)
		const forward = {}
		const backward = {}
		for index = 1, 20 do
			forward[`key{index}`] = index
			backward[`key{21 - index}`] = 21 - index
		end
		assert.eq(yaml.serialize(forward), yaml.serialize(backward))
	end)

	suite:case("writes nil and the null sentinel as null", function(assert)
		assert.eq(round_trip(nil), yaml.null)
		assert.eq(round_trip(yaml.null), yaml.null)
	end)

	suite:case("writes top-level scalars as single documents", function(assert)
		for _, value in { "text", "multi\nline\n", 12, false } do
			assert.eq(round_trip(value), value)
		end
	end)

	suite:case("rejects values yaml cannot represent", function(assert)
		assert.throwsWith("cannot serialize a value of type function", yaml.serialize, { callback = print })
	end)

	suite:case("rejects strings that are not valid utf-8", function(assert)
		assert.throwsWith("cannot serialize a string that is not valid utf-8", yaml.serialize, { "\255" })
	end)
end)
