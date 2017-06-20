-- -*- Mode: Lua; -*-                                                                             
--
-- loadpkg.lua   load an RPL module, which instantiates a run-time package
--
-- © Copyright IBM Corporation 2017.
-- LICENSE: MIT License (https://opensource.org/licenses/mit-license.html)
-- AUTHOR: Jamie A. Jennings

-- In RPL 1.1, parsing Rosie Pattern Language source (i.e. pattern bindings and expression) is
-- achieved by matching either 'rpl_expression' or 'rpl_statements' (defined in rpl_1_1.rpl)
-- against input text.  (Pre-parsing to look for an RPL language declaration is a separate phase
-- that happens before parsing.)  The result is a single parse tree.
--
-- The parse tree is searched for nodes named 'syntax_error'.  If found, the error is encoded in a
-- violation object which is returned with an indication that the parse failed.
--
-- A successful parse produces a parse tree.
-- 
-- A parse tree is converted to an AST representation, in which: 
--     - Expressions of all kinds are right associative
--     - Sequences and choices are n-ary, not binary
--     - Assignments, aliases, and grammars are encoded as 'bind' ast nodes
--     - Quantified expressions have a uniform representation parameterized by (min, max)
--     - Character set unions and intersections are n-ary, not binary
--     - Each 'cexp' reflects an explicit [...] construct in the source
--     - Each 'cooked' reflects an explicit (...) construct in the source
--     - Each 'raw' reflects an explicit {...} construct in the source
--     - A block contains a package decl (optional), import decls (optional), and zero or more
--       bindings.
-- 
-- Syntax expansion is interleaved with package instantiation, because macros (both user-defined
-- and built-in) are packaged in modules.  A package is the run-time instantiation of a module.
--
-- Packages are currently instantiated by compiling module source (written in RPL) and providing
-- access to the module's exported bindings for use in subsequent compilation of other RPL code.
-- (In the future, packages will be instantiated by reading a representation of the
-- already-compiled module.)
-- 
-- Syntax expansion for a 'block' is the last step in processing an RPL block:
--   1. Validate the block structure, e.g. declarations occur before bindings.
--   2. If the block defines a package, create a fresh environment (else use top level) to be the
--      current environment
--   3. For each import in the block environment: recursively instantiate the imported module; then
--      bind the resulting package name in the current environment
--   4. Expand each binding in the block, in order of appearance


local ast = require "ast"
local environment = require "environment"
local lookup = environment.lookup
local bind = environment.bind
local common = require "common"
local violation = require "violation"

local load = {}

-- 'validate_block' enforces the structure of an rpl module:
--     rpl_module = language_decl? package_decl? import_decl* statement* ignore
--
-- We could parse a module using that pattern, but we can give better error messages this way.
-- Returns: success, table of messages
-- Side effects: fills in block.pdecl, block.ideclist; removes decls from block.stmts
local function validate_block(a)
   assert(ast.block.is(a))
   local stmts = a.stmts
   if not stmts[1] then
      return true, {violation.warning.new{who='load package', message="Empty input", ast=a}}
   elseif ast.pdecl.is(stmts[1]) then
      a.pdecl = table.remove(stmts, 1)
      common.note("load: in package " .. a.pdecl.name)
   end
   if not stmts[1] then
      return true,
	 {violation.warning.new{who='load package',
				message="Empty module (nothing after package declaration)",
				ast=a}}
   elseif not ast.ideclist.is(stmts[1]) then
      return true, {violation.info.new{who='load package',
				       message="Module consists only of import declarations",
				       ast=a}}
   end
   if ast.ideclist.is(stmts[1]) then
      a.ideclist = table.remove(stmts, 1)
   end
   for _, s in ipairs(stmts) do
      if not ast.binding.is(s) then
	 return false, {violation.compile.new{who='load package',
					      message="Declarations must appear before assignments",
					      ast=s}}
      end
   end -- for
   return true, {}
end

local function compile(compiler, a, pkgenv, messages)
   -- We call the compiler with the import declarations already processed, and the imported
   -- bindings accessible in pkgenv
   local pkgname = a.pdecl and a.pdecl.name
   if not compiler.compile_block(a, pkgenv, messages) then
      common.note(string.format("load: FAILED TO COMPILE %s", pkgname or "<top level>"))
      return false
   end
   if a.importpath and (not pkgname) then
      local msg = a.importpath .. " is not a module (no package declaration found)"
      table.insert(messages, violation.compile.new{who='compiler', message=msg, ast=a})
      return false
   end
   common.note(string.format("load: compiled %s", pkgname or "<top level>"))
   return true
end

function load.source(compiler, pkgtable, top_level_env, searchpath, src, importpath, fullpath, messages)
   assert(type(compiler)=="table")
   assert(type(pkgtable)=="table")
   assert(environment.is(top_level_env))
   assert(type(searchpath)=="string")
   assert(type(src)=="string")
   assert(importpath==nil or type(importpath)=="string")
   assert(fullpath==nil or type(fullpath)=="string")
   assert(type(messages)=="table")
   local env = (importpath and environment.new()) or top_level_env
   -- assert((importpath and (env~=top_level_env)) or
   --     ((not importpath) and (env==top_level_env)))
   local a = compiler.parse_block(src, importpath, messages)
   if not a then return false; end
   a.importpath = importpath
   a.filename = fullpath
   if not validate_block(a) then return false; end

   print("*** Block: "); print(ast.tostring(a)); print("*** end")

   -- Via side effects, a.pdecl and a.ideclist are now filled in.
   -- With a mutually recursive call to load.imports, we can load the dependencies in a.ideclist. 
   if not load.imports(compiler, pkgtable, top_level_env, searchpath, importpath, a.ideclist, env, messages) then return false; end
   if not compiler.expand_block(a, env, messages) then
      print("*** EXPAND FAILED"); return false; end
   if not compile(compiler, a, env, messages) then
      print("*** COMPILE FAILED"); return false; end
   if importpath then
      if a.pdecl and a.pdecl.name then
	 common.pkgtableset(pkgtable, importpath, a.pdecl.name, env)
      else
	 error("!!@#!#!#!@#!#@!#@ TODO: imported module source did not define a package")
      end
   end -- if importpath
   return true
end

local function import_from_source(compiler, pkgtable, top_level_env, searchpath, importpath, decl, messages)
   local fullpath, src, msg = common.get_file(decl.importpath, searchpath)
   if not src then
      local msg = ("load: cannot find module source for '" .. decl.importpath ..
		   "' needed by module '" .. (importpath or "<top level>") .. "': "
		   .. msg)
      table.insert(messages, violation.compile.new{who='import package', message=msg, ast=decl})
      return false
   end
   common.note("load: loading ", decl.importpath, " from ", fullpath)
   return load.source(compiler, pkgtable, top_level_env, searchpath, src, importpath, fullpath, messages)
end

local function import(compiler, pkgtable, top_level_env, searchpath, importpath, decl, messages)
   -- First, look in the pkgtable to see if this pkg has been loaded already
   local pkgname, pkgenv = common.pkgtableref(pkgtable, decl.importpath)
   if pkgname then
      common.note("load: ", decl.importpath, " already loaded")
      return pkgname, pkgenv
   end
   common.note("load: looking for ", decl.importpath)
   -- FUTURE: Next, look for a compiled version of the file to load
   -- ...
   -- Finally, look for a source file to compile and load
   return import_from_source(compiler, pkgtable, top_level_env, searchpath, importpath, decl, messages)
end

local function create_import_binding(localname, pkgenv, target_env)
   assert(type(localname)=="string")
   assert(environment.is(pkgenv))
   assert(environment.is(target_env))
   if localname=="." then
      -- import all exported bindings into the target environment
      for name, obj in pkgenv:bindings() do
	 assert(type(obj)=="table", name .. " bound to " .. tostring(obj))
	 if obj.exported then			    -- quack
	    if lookup(target_env, name) then
	       common.note("load: rebinding ", name)
	    else
	       common.note("load: binding ", name)
	    end
	    bind(target_env, name, obj)
	 end
      end -- for each binding in the package
   else
      -- import the entire package under the desired localname
      if lookup(target_env, localname) then
	 common.note("load: rebinding ", localname)
      end
      bind(target_env, localname, pkgenv)
      common.note("load: binding package prefix " .. localname)
   end
end

-- 'load.imports' recursively loads each import in ideclist.
-- Returns success; side-effects the messages argument.
function load.imports(compiler, pkgtable, top_level_env, searchpath, importpath, ideclist, target_env, messages)
   assert(type(compiler)=="table")
   assert(type(pkgtable)=="table")
   assert(environment.is(top_level_env))
   assert(type(searchpath)=="string")
   assert(importpath==nil or type(importpath)=="string")
   assert(ideclist==nil or ast.ideclist.is(ideclist), "ideclist is: "..tostring(ideclist))
   assert(environment.is(target_env))
   assert(type(messages)=="table")
   -- assert((importpath and (target_env~=top_level_env)) or
   --     ((not importpath) and (target_env==top_level_env)))
   local idecls = ideclist and ideclist.idecls or {}
   if #idecls==0 then common.note("load: no imports to load"); end
   for _, decl in ipairs(idecls) do
      local pkgname, pkgenv = import(compiler, pkgtable, top_level_env, searchpath, decl.importpath, decl, messages)
      if not pkgname then
	 common.note("FAILED to import from path " ..
		     tostring(decl.importpath) ..
		     " required by " .. (importpath or "top level"))
	 return false
      end
   end
   -- With all imports loaded and registered in pkgtable, we can now create bindings in target_env
   -- to make the exported bindings accessible.
   for _, decl in ipairs(idecls) do
      local pkgname, pkgenv = common.pkgtableref(pkgtable, decl.importpath)
      local localname = decl.prefix or pkgname
      assert(type(localname)=="string")
      create_import_binding(localname, pkgenv, target_env)
   end
   return true
end

return load