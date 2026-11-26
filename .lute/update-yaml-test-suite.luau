-- replaces the vendored yaml-test-suite in tests/samples with a data release from upstream, and records
-- which release and commit it came from in the test runner's header.
--
-- usage: lute .lute/update-yaml-test-suite.luau [ref]
-- `ref` is a tag or branch of the suite's data releases, and defaults to the newest "data-*" tag

const fs = require("@std/fs")
const path = require("@std/path")
const process = require("@std/process")
const system = require("@std/system")

const REPOSITORY = "https://github.com/yaml/yaml-test-suite"
const SAMPLES_DIRECTORY = "tests/samples/yaml-test-suite"
const TEST_FILE = "tests/yaml_test_suite.test.luau"

-- entries of a data release that aren't test cases. name/ and tags/ only index the cases through symlinks
const SKIPPED_ENTRIES: { [string]: boolean } = {
	[".git"] = true,
	name = true,
	tags = true,
}

-- runs a command, returning its output and stopping the script if it fails
const function run(args: { string }, cwd: string?): string
	const result = process.run(args, { cwd = cwd })
	assert(result.ok, `{table.concat(args, " ")} failed:\n{result.stderr}`)
	return result.stdout
end

-- data release tags are named by date, so the newest one sorts last
const function find_latest_release(): string
	local latest: string? = nil
	for tag in string.gmatch(run({ "git", "ls-remote", "--tags", "--refs", REPOSITORY }), "refs/tags/(data%-[%d%-]+)") do
		if latest == nil or tag > latest then
			latest = tag
		end
	end
	assert(latest, "found no data releases in the upstream repository")
	return latest
end

const function copy_directory(source: string, destination: string)
	fs.createDirectory(destination, { makeParents = true })
	for _, entry in fs.listDirectory(source) do
		const from = `{source}/{entry.name}`
		const to = `{destination}/{entry.name}`
		if entry.type == "dir" then
			copy_directory(from, to)
		elseif entry.type == "file" then
			fs.copy(from, to)
		end
	end
end

-- swaps the vendored cases for those in the clone, keeping nothing from the previous release
const function replace_samples(clone: string, license: string)
	if fs.exists(SAMPLES_DIRECTORY) then
		fs.removeDirectory(SAMPLES_DIRECTORY, { recursive = true })
	end
	fs.createDirectory(SAMPLES_DIRECTORY, { makeParents = true })

	for _, entry in fs.listDirectory(clone) do
		if entry.type == "dir" and not SKIPPED_ENTRIES[entry.name] then
			copy_directory(`{clone}/{entry.name}`, `{SAMPLES_DIRECTORY}/{entry.name}`)
		end
	end
	-- data releases carry no license, so the one from the main branch travels with the cases
	fs.writeStringToFile(`{SAMPLES_DIRECTORY}/License`, license)
end

-- rewrites the release and commit named in the test runner's header comment
const function record_source(ref: string, commit: string)
	const contents = fs.readFileToString(TEST_FILE)
	local updated, release_count =
		string.gsub(contents, "vendored from the [^\n]- release of", `vendored from the {ref} release of`)
	local commit_count = 0
	updated, commit_count = string.gsub(updated, "%(commit %x+%)", `(commit {string.sub(commit, 1, 8)})`)

	if release_count ~= 1 or commit_count ~= 1 then
		print(`could not find the source comment in {TEST_FILE}; record {ref} at {commit} there by hand`)
		return
	end
	fs.writeStringToFile(TEST_FILE, updated)
end

const ref = process.args[2] or find_latest_release()
const clone = path.format(path.join(system.tmpdir(), `yaml-test-suite-{ref}-{os.time()}`))

print(`cloning {ref} of {REPOSITORY}`)
run({ "git", "clone", "--quiet", "--depth", "1", "--branch", ref, REPOSITORY, clone })
const commit = string.gsub(run({ "git", "rev-parse", "HEAD" }, clone), "%s+$", "")
run({ "git", "fetch", "--quiet", "--depth", "1", "origin", "main" }, clone)
const license = run({ "git", "show", "FETCH_HEAD:License" }, clone)

replace_samples(clone, license)
record_source(ref, commit)

-- git marks its object files read-only, which can stop the clone from being removed on windows
const removed = pcall(function()
	fs.removeDirectory(clone, { recursive = true })
end)
if not removed then
	print(`could not remove the temporary clone at {clone}`)
end

print(`vendored {ref} at {commit} into {SAMPLES_DIRECTORY}; run lute test tests to check it`)
