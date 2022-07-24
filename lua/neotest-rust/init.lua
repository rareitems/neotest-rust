local async = require("neotest.async")
local context_manager = require("plenary.context_manager")
local lib = require("neotest.lib")
local open = context_manager.open
local Path = require("plenary.path")
local with = context_manager.with
local xml = require("neotest.lib.xml")
local handler = require("neotest.lib.xml.tree")

local adapter = { name = "neotest-rust" }

adapter.root = lib.files.match_root_pattern("Cargo.toml")

function adapter.is_test_file(file_path)
    return vim.endswith(file_path, ".rs")
end

local function is_unit_test(path)
    return vim.startswith(path, adapter.root(path) .. Path.path.sep .. "src" .. Path.path.sep)
end

local function is_integration_test(path)
    return vim.startswith(path, adapter.root(path) .. Path.path.sep .. "tests" .. Path.path.sep)
end

local function path_to_test_path(path)
    local root = adapter.root(path)
    if is_unit_test(path) then
        -- main.rs, lib.rs, and mod.rs aren't part of the test name
        for _, filename in ipairs({ "main", "lib", "mod" }) do
            path = path:gsub(Path.path.sep .. filename .. ".rs$", "")
        end

        path = Path:new(path)
        path = path:make_relative(root .. Path.path.sep .. "src")
        path = path:gsub(Path.path.sep, "::"):gsub(".rs$", "")

        -- If the file was main.rs, lib.rs, or mod.rs, the relative path will
        -- be "." after we strip the filename.
        if path == "." then
            return nil
        else
            return path
        end
    else
        return
    end
end

function adapter.discover_positions(path)
    local query = [[
(
  (attribute_item
    [
      (meta_item
        (identifier) @macro_name
      )
      (attr_item
        [
	  (identifier) @macro_name
	  (scoped_identifier
	    name: (identifier) @macro_name
          )
        ]
      )
    ]
  )+
  .
  (function_item
    name: (identifier) @test.name
  ) @test.definition
  (#contains? @macro_name "test" "rstest" "case")

)
(mod_item name: (identifier) @namespace.name) @namespace.definition
    ]]

    return lib.treesitter.parse_positions(path, query, {
        require_namespaces = true,
        position_id = function(position, namespaces)
            return table.concat(
                vim.tbl_flatten({
                    path_to_test_path(path),
                    vim.tbl_map(function(pos)
                        return pos.name
                    end, namespaces),
                    position.name,
                }),
                "::"
            )
        end,
    })
end

function adapter.build_spec(args)
    local tmp_nextest_config = async.fn.tempname()
    local junit_path = async.fn.tempname()
    local position = args.tree:data()

    local nextest_config = Path:new(adapter.root(position.path) .. ".config/nextest.toml")
    if nextest_config:exists() then
        nextest_config:copy({ destination = tmp_nextest_config })
    end

    with(open(tmp_nextest_config, "a"), function(writer)
        writer:write('[profile.neotest.junit]\npath = "' .. junit_path .. '"')
    end)

    local command

    if position.type == "test" then
        command = {
            "cargo",
            "nextest",
            "run",
            "--config-file",
            tmp_nextest_config,
            "--profile",
            "neotest",
            -- TODO: Support rstest parametrized tests
            "-E 'test(/^"
                .. position.id
                .. "$/)'",
        }
    elseif position.type == "file" then
        -- TODO: Handle files
    end

    return {
        command = table.concat(command, " "),
        context = {
            junit_path = junit_path,
            file = position.path,
        },
    }
end

function adapter.results(spec, result, tree)
    local success, data = pcall(lib.files.read, spec.context.junit_path)
    if not success then
        return {}
    end

    local results = {}

    local parser = xml.parser(handler)
    parser:parse(data)

    -- TODO: Support multiple tests
    local testcase = handler.root.testsuites.testsuite.testcase
    if testcase.failure then
        results[testcase._attr.name] = {
            status = "failed",
            short = testcase.failure[1],
        }
    else
        results[testcase._attr.name] = {
            status = "passed",
        }
    end

    return results
end

setmetatable(adapter, {
    __call = function(_, opts)
        return adapter
    end,
})

return adapter