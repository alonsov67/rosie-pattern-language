---- -*- Mode: Lua; -*-                                                                           
----
---- engine.lua    The RPL matching engine
----
---- © Copyright IBM Corporation 2016, 2017.
---- LICENSE: MIT License (https://opensource.org/licenses/mit-license.html)
---- AUTHOR: Jamie A. Jennings

-- TODO: a module-aware version of strict.lua that works with _ENV and not _G
--require "strict"

-- The two principle use case categories for Rosie may be characterized as Interactive and
-- Production, where the latter includes big data scenarios in which performance is paramount and
-- functions like compiling, tracing, and generating human-readable output are not needed.
-- Support for matching using compiled patterns is the focus of "Production" use.

----------------------------------------------------------------------------------------
-- Engine
----------------------------------------------------------------------------------------
-- A matching engine is a stateful Lua object instantiated in order to match patterns
-- against input data.  An engine is the primary abstraction for using Rosie
-- programmatically in Lua.  (Recall that the REPL, CLI, and API are written in Lua.)
--
-- engine.new(optional_name) creates a new engine with only a "base" environment
--   returns id which is a string;
--   never raises error (unless for internal rosie bug)
-- e:name() returns the engine name (a string) or nil if not set
--   never raises error (unless for internal rosie bug)
-- e:id() returns the engine id
--   never raises error (unless for internal rosie bug)
-- 
-- e:load(rpl_string) compiles rpl_string in the current engine environment
--   the rpl_string has file semantics
--   returns messages where messages is a table of strings
--   raises error if rpl_string fails to compile
-- 
-- e:compile(expression, flavor) compiles the rpl expression
--   returns an rplx object and messages
--   raises error if expression fails to compile
--   API only: returns the (string) id of an rplx object with indefinite extent;
--   The flavor argument, if nil or "match" compiles expression unmodified.  Otherwise:
--     flavor=="search" compiles {{!expression .}* expression}+
--     and more flavors can be added later, e.g.
--     flavor==n, for integer n, compiles {{!expression .}* expression}{0,n}
--   The flavor feature is a convenience function that is a stopgap until we have macros/functions 
--
-- r:match(input, optional_start) like e:match but r is a compiled rplx object
--   returns matches, leftover;
--   never raises an error (unless for internal rosie bug)
--
-- e:match(expression, input, optional_start, optional_flavor)
--   behaves like: r=e:compile(expression, optional_flavor); r:match(input, optional_start)
--   API only: expression can be an rplx id, in which case that compiled expression is used
--   returns matches, leftover;
--   raises error if expression fails to compile
-- 
-- e:tracematch(expression, input, optional_start, optional_flavor) like match, with tracing (was eval)
--   API only: expression can be an rplx id, in which case that compiled expression is used
--   returns matches, leftover, trace;
--   raises error if expression fails to compile
-- 
-- e:output(optional_formatter) sets or returns the formatter (a function)
--   an engine calls formatter on each successful match result;
--   raises error if optional_formatter is not a function
-- e:lookup(optional_identifier) returns the definition of optional_identifier or the entire environment
--   never raises an error (unless for internal rosie bug)
-- e:clear(optional_identifier) erases the definition of optional_identifier or the entire environment
--   never raises an error (unless for internal rosie bug)

-- FUTURE:
--
-- e:trace(id1, ... | nil) trace the listed identifiers, or if nil return the identifiers being traced
-- e:traceall(flag) trace all identifiers if flag is true, or no indentifiers if flag is false
-- e:untrace(id1, ...) untrace the listed identifiers
-- e:tracesearch(identifier, input, optional_start) like search, but generates a trace output (was eval)
--
-- e:stats() returns number of patterns bound, some measure of env size (via lua collectgarbage), more...
--
-- e:match and e:search return a third argument which is the (user) cpu time that it took to match/search


local engine_module = {}

local string = require "string"

local lpeg = require "lpeg"
local recordtype = require "recordtype"
local common = require "common"
local rmatch = common.rmatch
local environment = require "environment"
local lookup = environment.lookup
local bind = environment.bind
local writer = require "writer"
local eval = require "eval"

local rplx 					    -- forward reference
local engine_error				    -- forward reference

----------------------------------------------------------------------------------------

-- Grep searches a line for all occurrences of a given pattern.  For Rosie to search a line for
-- all occurrences of pattern p, we want to transform p into:  {{!p .}* p}+
-- E.g.
--    bash-3.2$ ./run '{{!int .}* int}+' /etc/resolv.conf 
--    10 0 1 1 
--    2606 000 1120 8152 2 7 6 4 1 
--
-- Flavors are RPL "macros" hand-coded in Lua, used in Rosie v1.0 as a very limited kind of macro
-- system that we can extend in versions 1.x without losing backwards compatibility (and without
-- introducing a "real" macro facility.
-- N.B. Macros are transformations on ASTs, so they leverage the (rough and in need of
-- refactoring) syntax module.

local function compile_search(en, pattern_exp)
   error("compile_search NOT REWRITTEN YET")
   local parse_exp, env = en.compiler.parser.parse_expression, en._env
   local env = environment.extend(env)		    -- new scope, which will be discarded
   -- First, we compile the exp in order to give an accurate message if it fails
   -- TODO: do something with leftover?
   local astlist, orig_astlist, warnings, leftover = parse_exp(pattern_exp)
   if not astlist then return nil, warnings, leftover; end
   local pat, msgs = en.compiler.compile_expression(astlist, orig_astlist, pattern_exp, env)
   if not pat then return nil, msgs; end
   local replacement = pat.ast
   -- Next, transform pat.ast
   local astlist, orig_astlist = rpl_parser("{{!e .}* e}+")
   assert(type(astlist)=="table" and astlist[1] and (not astlist[2]))
   local template = astlist[1]
   local grep_ast = syntax.replace_ref(template, "e", replacement)
   assert(type(grep_ast)=="table", "syntax.replace_ref failed")
   return en.compiler.compile_expression({grep_ast}, orig_astlist, "SEARCH(" .. pattern_exp .. ")", env)
end

local function compile_match(en, source)
   local parse = en.compiler.parser.parse_expression
   local astlist, original_astlist, warnings = parse(source)
   print("*** in compile_match, source is:\n" .. source)
   return en.compiler.compile_expression(nil, astlist, en._modtable, en._env)
end

local function engine_compile(en, expression, flavor)
   flavor = flavor or "match"
   if type(expression)~="string" then engine_error(en, "Expression not a string: " .. tostring(expression)); end
   if type(flavor)~="string" then engine_error(en, "Flavor not a string: " .. tostring(flavor)); end
   local ok, pat, msgs
   if flavor=="match" then
      ok, pat, msgs = compile_match(en, expression)
   elseif flavor=="search" then
      ok, pat, msgs = compile_search(en, expression)
   else
      engine_error(en, "Unknown flavor: " .. flavor)
   end
   if not ok then return en:_error(table.concat(msgs, '\n')); end
   return rplx.new(en, pat), msgs
end

-- N.B. This code is essentially duplicated (for speed, to avoid a function call) in process_input_file.lua
-- There's still room for optimizations, e.g.
--   Create a closure over the encode function to avoid looking it up in e.
--   Close over lpeg.match to avoid looking it up via the peg.
--   Close over the peg itself to avoid looking it up in pat.
local function _engine_match(e, pat, input, start, total_time_accum, lpegvm_time_accum)
   local result, nextpos
   local encode = e.encode_function
   result, nextpos, total_time_accum, lpegvm_time_accum =
      rmatch(pat.peg,
	     input,
	     start,
	     type(encode)=="number" and encode,
	     total_time_accum,
	     lpegvm_time_accum)
   if result then
      return (type(encode)=="function") and encode(result) or result,
             #input - nextpos + 1, 
             total_time_accum, 
             lpegvm_time_accum
   end
   return false, 1, total_time_accum, lpegvm_time_accum;
end

-- TODO: Maybe cache expressions?
-- returns matches, leftover, total match time, total spent in lpeg vm
local function make_matcher(processing_fcn)
   return function(e, expression, input, start, flavor, total_time_accum, lpegvm_time_accum)
	     if type(input)~="string" then engine_error(e, "Input not a string: " .. tostring(input)); end
	     if start and type(start)~="number" then engine_error(e, "Start position not a number: " .. tostring(start)); end
	     if flavor and type(flavor)~="string" then engine_error(e, "Flavor not a string: " .. tostring(flavor)); end
	     if rplx.is(expression) then
		return processing_fcn(e, expression._pattern, input, start, total_time_accum, lpegvm_time_accum)
	     elseif type(expression)=="string" then -- expression has not been compiled
		-- If we cache, look up expression in the cache here.
		local r, msgs = e:compile(expression, flavor)
		if not r then engine_error(e, table.concat(msgs, '\n')); end
		return processing_fcn(e, r._pattern, input, start, total_time_accum, lpegvm_time_accum)
	     else
		engine_error(e, "Expression not a string or rplx object: " .. tostring(expression));
	     end
	  end  -- matcher function
end

-- returns matches, leftover
local engine_match = make_matcher(_engine_match)

-- returns matches, leftover, trace
local engine_tracematch = make_matcher(function(e, pat, input, start)
				    local m, left, ttime, lptime = _engine_match(e, pat, input, start)
				    local _,_,trace, ttime, lptime = eval.eval(pat, input, start, e._env, false)
				    return m, left, trace, ttime, lptime
				 end)

----------------------------------------------------------------------------------------

local load_dependency				    -- forward reference
local load_dependencies				    -- forward reference
local import_dependency				    -- forward reference

-- load a unit of rpl code (decls and statements) into an environment:
--   * parse out the dependencies (import decls)
--   * load dependencies that have not been loaded (into the modtable)
--   * import the dependencies into the target environment
--   * compile the input in the target environment
--   * return a possibly-empty table of messages, or throw an error if compilation fails.

local function load_input(e, target_env, input, importpath)
   assert(engine.is(e))
   assert(environment.is(target_env), "target not an environment: " .. tostring(target_env))
   assert(type(e.searchpath)=="string", "engine search path not a string")
   local messages = {}
   local parser = e.compiler.parser
   local astlist, original_astlist, warnings, leftover
   if type(input)=="string" then
      astlist, original_astlist, warnings, leftover = parser.parse_statements(input)
   else
      assert(type(input)=="table")
      astlist, original_astlist, warnings, leftover = input, input, {}, 0
   end
   table.insert(warnings, 1, "Processing " .. (importpath or "<top level>"))
   if not astlist then
      engine_error(e, table.concat(warnings, '\n')) -- in this case, warnings contains errors
   end
   -- load_dependencies has side-effects on e._modtable and target_env
   load_dependencies(e, astlist, target_env, messages, importpath)
   -- now we can compile the input
   local success, modname, messages = e.compiler.load(importpath, astlist, e._modtable, target_env)

   if not modname then modname = "<top level>"; end -- for display

   if success then
      assert(type(messages)=="table")
      common.note(string.format("COMPILED %s", modname))
      table.move(messages, 1, #messages, #warnings+1, warnings)
      return modname, warnings
   else
      common.note(string.format("FAILED TO COMPILE %s", modname))
      assert(type(messages)=="table", "messages is: " .. tostring(messages))
      table.move(messages, 1, #messages, #warnings+1, warnings)
      engine_error(e, table.concat(warnings, '\n'))
   end
end

load_dependencies =
   function(e, astlist, target_env, messages, importpath)
      local deps = e.compiler.parser.parse_deps(e.compiler.parser, astlist)
      -- find and load all dependencies
      for _, dep in ipairs(deps) do
	 local new_messages, modname
	 modname, new_messages = load_dependency(e, astlist, target_env, dep, importpath);
	 table.move(new_messages, 1, #new_messages, #messages+1, messages)
	 if modname then
	    assert(e._modtable[dep.importpath],
		   tostring(dep.importpath) .. " is not in module table?")
	 end
      end
      -- if all dependecies loaded ok, we can import them
      for _, dep in ipairs(deps) do import_dependency(e, target_env, dep); end
end
      
-- find and load any missing dependency
load_dependency =
   function(e, astlist, target_env, dep, importpath)
      local success, messages
      print("-> Loading dependency " .. dep.importpath .. " required by " .. (importpath or "<top level>"))
      local modname = dep.prefix
      local modenv = e._modtable[dep.importpath]
      if not modenv then
	 common.note("Looking for ", dep.importpath, " required by ", (importpath or "<top level>"))
	 local fullpath, source = common.get_file(dep.importpath, e.searchpath)
	 if not fullpath then
	    local err = "cannot find module '" .. dep.importpath ..
	       "' needed by module '" .. (importpath or "<top level>") .. "'"
	    engine_error(e, err)
	 else
	    common.note("Loading ", dep.importpath, " from ", fullpath)
	    modname, messages = load_input(e, target_env, source, dep.importpath) -- recursive
	 end -- if not fullpath
      end -- if dependency was not already loaded
      return modname, messages
   end

import_dependency =
   function(e, target_env, dep)
      assert(engine.is(e))
      assert(environment.is(target_env))
      if environment.lookup(target_env, dep.prefix) then
	 table.insert(messages, "REBINDING " .. dep.prefix) -- TODO: make this an error
      end
      local modenv = e._modtable[dep.importpath]
      environment.bind(target_env, dep.prefix, modenv)
      print("-> Binding module prefix: " .. dep.prefix)
   end

----------------------------------------------------------------------------------------

local function reconstitute_pattern_definition(id, p)
   if p then
      return ( (p.original_ast and writer.reveal_ast(p.original_ast)) or
	    (p.ast and writer.reveal_ast(p.ast)) or
	 "// built-in RPL pattern //" )
   end
   engine_error(e, "undefined identifier: " .. id)
end

local function pattern_properties(name, pat)
   local kind = (pat.alias and "alias") or "definition"
   local color = (co and co.colormap and co.colormap[item]) or ""
   local binding = reconstitute_pattern_definition(name, pat)
   return {type=kind, color=color, binding=binding}
end

-- Lookup an identifier in the engine's environment, and get a human-readable definition of it
-- (reconstituted from its ast).  If identifier is null, return the entire environment.
local function get_environment(en, identifier)
   if identifier then
      local val = lookup(en._env, identifier)
      return val and pattern_properties(identifier, val)
   end
   local flat_env = environment.flatten(en._env)
   -- Rewrite the flat_env table, replacing the pattern with a table of properties
   for id, pat in pairs(flat_env) do flat_env[id] = pattern_properties(id, pat); end
   return flat_env
end

local function clear_environment(en, identifier)
   if identifier then
      if lookup(en._env, identifier) then bind(en._env, identifier, nil); return true
      else return false; end
   else -- no identifier arg supplied, so wipe the entire env
      en._env = environment.new()
      return true
   end
end

-- Built-in encoder options:
-- false = return lua table as usual
-- -1 = no output
--  0 = compact byte encoding with only start/end indices (no text)
--  1 = compact json encoding with only start/end indices (no text)
local function get_set_encoder_function(en, f)
   if f==nil then return en.encode_function; end
   if f==false or type(f)=="number" or type(f)=="function" then
      en.encode_function = f;
   else engine_error(en, "Invalid output encoder: " .. tostring(f)); end
end

---------------------------------------------------------------------------------------------------

local default_compiler = false

local function set_default_compiler(compiler)
   default_compiler = compiler
end

local default_searchpath = false

local function set_default_searchpath(str)
   default_searchpath = str
end

---------------------------------------------------------------------------------------------------

local function engine_create(name, compiler, searchpath)
   compiler = compiler or default_compiler
   searchpath = searchpath or default_searchpath
   if not compiler then error("no default compiler set"); end
   return engine.factory { name=function() return name; end,
			   compiler=compiler,
			   searchpath=searchpath,
			   _env=environment.new(),
			   _modtable=environment.make_module_table(),
			}
end

function engine_error(e, msg)
   error(string.format("Engine %s: %s\n%s", tostring(e), tostring(msg),
		       ROSIE_DEV and (debug.traceback().."\n") or "" ), 0)
end

local engine = 
   recordtype.new("engine",
		  {  name=function() return nil; end, -- for reference, debugging
		     compiler=false,
		     _env=false,
		     _modtable=false,
		     _error=engine_error,

		     id=recordtype.id,

		     encode_function=false,	      -- false or nil ==> use default encoder
		     output=get_set_encoder_function,

		     lookup=get_environment,
		     clear=clear_environment,

		     load=function(e, input)
			     return load_input(e, e._env, input)
			  end,
		     compile=engine_compile,
		     searchpath="";

		     match=engine_match,
		     tracematch=engine_tracematch,

		  },
		  engine_create
	       )

----------------------------------------------------------------------------------------

local rplx_create = function(en, pattern)			    
		       return rplx.factory{ _engine=en,
					    _pattern=pattern,
					    match=function(self, ...)
						     return _engine_match(en, pattern, ...)
						  end }; end

rplx = recordtype.new("rplx",
		      { _pattern=recordtype.NIL;
			_engine=recordtype.NIL;
			--
			match=false;
		      },
		      rplx_create
		   )

---------------------------------------------------------------------------------------------------

engine_module.engine = engine
engine_module._set_default_compiler = set_default_compiler
engine_module._set_default_searchpath = set_default_searchpath
engine_module.rplx = rplx

return engine_module
