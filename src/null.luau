-- stands in for yaml null, since nil cannot be stored in tables

const null = newproxy(true)
getmetatable(null).__tostring = function(): string
	return "null"
end

return null
