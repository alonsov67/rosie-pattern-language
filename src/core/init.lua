---- -*- Mode: Lua; -*-                                                                           
----
---- init.lua    Load the Rosie system, given the location of the installation directory
----
---- © Copyright IBM Corporation 2016, 2017.
---- LICENSE: MIT License (https://opensource.org/licenses/mit-license.html)
---- AUTHOR: Jamie A. Jennings

----------------------------------------------------------------------------------------
-- Explanation of key globals
----------------------------------------------------------------------------------------
-- 
-- ROSIE_HOME indicates from where this executing instance of rosie is running.  It will
--            typically be a system location like /usr/local/lib/rosie, but could also
--            be any local rosie install directory, like ~/rosie.  Code and other non-RPL
--            artifacts are found via ROSIE_HOME.
-- ROSIE_ROOT is the variable that the rosie code uses to find the standard RPL library.
--            Unless the user supplies a different value (by setting the environment
--            variable ROSIE_ROOT), the value is the set to ROSIE_HOME.  This is the ONLY
--            configuration parameter that the user can control via the environment.
-- ROSIE_DEV  will be true iff rosie is running in "development mode".  Certain errors
--            that are normally fatal will instead return control to the Lua interpreter
--            (after being signaled) when in development mode.

----------------------------------------------------------------------------------------
-- Define key globals
----------------------------------------------------------------------------------------
-- The value of ROSIE_HOME on entry to this file is set by either:
--    (1) The shell script bin/rosie, which was
--         - created by the Rosie installation process (Makefile), to include the value
--           of ROSIE_HOME. 
--         - When that script is invoked by the user in order to run Rosie,
--           the script passes ROSIE_HOME to cli.lua, which has called this file (init).
-- Or (2) The code in rosie.lua, which was also created by the Rosie installation.

if not ROSIE_HOME then error("Error while initializing: variable ROSIE_HOME not set"); end

-- When init is loaded from run-rosie, ROSIE_DEV will be a boolean (as set by cli.lua)
-- When init is loaded from rosie.lua, ROSIE_DEV will be unset.  In this case, it should be set to
-- true so that rosie errors do not invoke os.exit().

ROSIE_DEV = ROSIE_DEV or (ROSIE_DEV==nil)

local function read_version_or_die(home)
   assert(type(home)=="string")
   local vfile = io.open(home.."/VERSION")
   if vfile then
      local v = vfile:read("l"); vfile:close();
      if v then return v; end			    -- success
   end
   -- otherwise either vfile is nil or v is nil
   local msg = "Error while initializing: "..tostring(home).."/VERSION does not exist or is not readable\n"
   if not ROSIE_DEV then io.stderr:write(msg); os.exit(-3); end
   error(msg)					    -- should do throw(msg) to end of init?
end

ROSIE_VERSION = read_version_or_die(ROSIE_HOME)

-- The location of the Rosie standard library (of patterns) is ROSIE_ROOT/rpl.
-- And compiled Rosie packages are stored in ROSIE_ROOT/pkg.
--
-- ROSIE_ROOT = ROSIE_HOME by default.  The user can override the default by setting the
-- environment variable $ROSIE_ROOT to point somewhere else.

ROSIE_ROOT = ROSIE_HOME

local ok, value = pcall(os.getenv, "ROSIE_ROOT")
if (not ok) then error('Internal error: call to os.getenv(ROSIE_ROOT)" failed'); end
if value then ROSIE_ROOT = value; end

---------------------------------------------------------------------------------------------------
-- Load the entire rosie world... (which includes the "core" parser for "rpl 1.0")
---------------------------------------------------------------------------------------------------

local loader, msg = loadfile(ROSIE_HOME .. "/src/core/load-modules.lua", "t", _ENV)
if not loader then error("Internal error while loading modules: " .. msg); end
loader()

---------------------------------------------------------------------------------------------------
-- Bootstrap the rpl parser, which is defined using "rpl 1.0" (defined in parse.lua)
---------------------------------------------------------------------------------------------------
-- 
-- The engines we create now will use parse.core_parse_and_explain, which defines "rpl 0.0",
-- i.e. the core language (which has many limitations).
-- 
-- An engine that accepts "rpl 0.0" is needed to parse $ROSIE_HOME/rpl/rpl-1.0.rpl, which defines
-- "rpl 1.0".  This is the version of rpl used for the Rosie v0.99x releases.
--
-- We use the rpl 1.0 parser to load the rpl 1.1 parser (which is obviously written in rpl 1.0).

local announcements = false
local function announce(name, engine)
   if announcements then
      print(name .. " created: _rpl_version = ".. engine._rpl_version ..
	                    "; _rpl_parser = " .. tostring(engine._rpl_parser))
   end
end

CORE_ENGINE = engine.new("RPL core engine")
announce("CORE_ENGINE", CORE_ENGINE)

local rpl_1_0_filename = ROSIE_HOME.."/rpl/rpl-1.0.rpl"
local rpl_1_0, msg = util.readfile(rpl_1_0_filename)
if not rpl_1_0 then error("Error while reading " .. rpl_1_0_filename .. ": " .. msg); end
RPL_1_0_ENGINE = engine.new("RPL 1.0 engine")
RPL_1_0_ENGINE._rpl_parser = parse.core_parse_and_explain
RPL_1_0_ENGINE:load(rpl_1_0)
local success, result, messages = pcall(RPL_1_0_ENGINE.compile, RPL_1_0_ENGINE, 'rpl')
if not success then error("Error while initializing: could not compile "
			  .. rpl_1_0_filename .. ":\n" .. tostring(result)); end

RPL_1_0_ENGINE._rpl_version = "1.0"
announce("RPL_1_0_ENGINE", RPL_1_0_ENGINE)

ROSIE_RPLX = result

-- Install the fancier parser, parse_and_explain, which uses ROSIE_RPLX
load_module("rpl-parser")
local parse_and_explain = make_parse_and_explain(ROSIE_RPLX)
-- And make these the defaults for all new engines:
engine._set_default_rpl_parser(parse_and_explain, "1.1");

ROSIE_ENGINE = engine.new("RPL 1.1 engine")
announce("ROSIE_ENGINE", ROSIE_ENGINE)

----------------------------------------------------------------------------------------
-- INFO for debugging
----------------------------------------------------------------------------------------

-- N.B. All values in table must be strings, even if original value was nil or another type.
-- Two ways to use this table:
-- (1) Iterate over the numeric entries with ipairs to access an organized (well, ordered) list of
--     important parameters, with their values and descriptions.
-- (2) Index the table by a parameter key to obtain its value.
ROSIE_INFO = {
   {name="ROSIE_HOME",    value=ROSIE_HOME,                  desc="location of the rosie installation directory"},
   {name="ROSIE_VERSION", value=ROSIE_VERSION,               desc="version of rosie installed"},
   {name="RPL_VERSION",   value=ROSIE_ENGINE._rpl_version,   desc="version of rpl (language) accepted"},
   {name="ROSIE_ROOT",    value=tostring(ROSIE_ROOT),        desc="root of the standard rpl library"},
   {name="ROSIE_DEV",     value=tostring(ROSIE_DEV),         desc="true if rosie was started in development mode"},
   {name="HOSTNAME",      value=os.getenv("HOSTNAME") or "", desc="host on which rosie is running"},
   {name="HOSTTYPE",      value=os.getenv("HOSTTYPE") or "", desc="type of host on which rosie is running"},
   {name="OSTYPE",        value=os.getenv("OSTYPE") or "",   desc="type of OS on which rosie is running"},
   {name="CWD",           value=os.getenv("PWD") or "",      desc="current working directory"},
   {name="ROSIE_COMMAND", value=ROSIE_COMMAND or "",         desc="invocation command, if rosie invoked through the CLI"}
}
for _,entry in ipairs(ROSIE_INFO) do ROSIE_INFO[entry.name] = entry.value; end

----------------------------------------------------------------------------------------
-- Output encoding functions
----------------------------------------------------------------------------------------
-- Lua applications (including the Rosie CLI & REPL) can use this table to install known
-- output encoders by name.

local encoder_table =
   {json = json.encode,
    color = color_output.color_string_from_leaf_nodes,
    nocolor = color_output.string_from_leaf_nodes,
    fulltext = common.match_to_text,
    [false] = function(...) return ...; end
 }

----------------------------------------------------------------------------------------
-- Build the rosie module as seen by the Lua client
----------------------------------------------------------------------------------------
local file_functions = {
   match = process_input_file.match,
   tracematch = process_input_file.tracematch,
   grep = process_input_file.grep,
   load = process_rpl_file.load_file	    -- TEMP until module system
}

local rosie = {
   engine = engine,
   file = file_functions,
   encoders = encoder_table
}

function rosie.info() return ROSIE_INFO; end

-- When rosie is loaded into Lua, such as for development, for using Rosie in Lua, or for
-- supporting the foreign function API, these internals are exposed through the rosie package table.  
if ROSIE_DEV then
   rosie._env = _ENV
   rosie._module = module
end

return rosie