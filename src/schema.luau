-- the yaml 1.2 core schema: how scalar text becomes null, booleans, numbers or strings

const null = require("./null")

const CORE_TAG_PREFIX = "tag:yaml.org,2002:"
const NULL_WORDS: { [string]: boolean } = { [""] = true, ["~"] = true, null = true, Null = true, NULL = true }
const INFINITY_WORDS: { [string]: boolean } = { [".inf"] = true, [".Inf"] = true, [".INF"] = true }
const NAN_WORDS: { [string]: boolean } = { [".nan"] = true, [".NaN"] = true, [".NAN"] = true }

-- { [word]: value }
const BOOLEAN_WORDS: { [string]: boolean } = {
	["true"] = true,
	True = true,
	TRUE = true,
	["false"] = false,
	False = false,
	FALSE = false,
}

const function parse_int(text: string): number?
	if string.find(text, "^0o[0-7]+$") then
		return tonumber(string.sub(text, 3), 8)
	end
	if string.find(text, "^0x%x+$") then
		return tonumber(string.sub(text, 3), 16)
	end
	return if string.find(text, "^[-+]?%d+$") then tonumber(text) else nil
end

-- [-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?, or infinity and nan
const function parse_float(text: string): number?
	if NAN_WORDS[text] then
		return math.nan
	end

	const sign = if string.byte(text, 1) == string.byte("-") then -1 else 1
	const unsigned = if string.find(text, "^[-+]") then string.sub(text, 2) else text
	if INFINITY_WORDS[unsigned] then
		return sign * math.huge
	end

	const exponent_start = string.find(unsigned, "[eE]")
	const mantissa = string.sub(unsigned, 1, (exponent_start or 0) - 1)
	const exponent = if exponent_start then string.sub(unsigned, exponent_start + 1) else "0"
	const valid_mantissa = string.find(mantissa, "^%d+%.?%d*$") or string.find(mantissa, "^%.%d+$")
	if not valid_mantissa or not string.find(exponent, "^[-+]?%d+$") then
		return nil
	end
	return sign * (tonumber(unsigned) :: number)
end

const schema = {}

-- resolves an untagged plain scalar
function schema.resolve_plain(text: string): any
	if NULL_WORDS[text] then
		return null
	end
	if BOOLEAN_WORDS[text] ~= nil then
		return BOOLEAN_WORDS[text]
	end
	-- numbers start with a sign, a dot or a digit, which rules most words out early
	if not string.find(text, "^[-+.%d]") then
		return text
	end
	return parse_int(text) or parse_float(text) or text
end

-- resolves a scalar with an explicit tag; returns nil when the text is invalid for that tag. tags outside
-- the core schema, including the non-specific "!", leave the text as a string
function schema.resolve_tagged(text: string, tag: string): any
	if string.sub(tag, 1, #CORE_TAG_PREFIX) ~= CORE_TAG_PREFIX then
		return text
	end

	const kind = string.sub(tag, #CORE_TAG_PREFIX + 1)
	if kind == "null" then
		return if NULL_WORDS[text] then null else nil
	elseif kind == "bool" then
		return BOOLEAN_WORDS[text]
	elseif kind == "int" then
		return parse_int(text)
	elseif kind == "float" then
		return parse_float(text) or parse_int(text)
	end
	return text
end

return table.freeze(schema)
