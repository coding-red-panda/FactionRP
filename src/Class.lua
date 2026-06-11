-- Class.lua
--
-- A tiny, dependency-free class system built on Lua metatables. It provides
-- single inheritance and a uniform constructor convention so that the rest of
-- the AddOn can be written as small, reusable, object-oriented components.
--
-- Usage:
--   local Animal = ns.Class("Animal")
--   function Animal:init(name) self.name = name end
--   function Animal:speak() return "..." end
--
--   local Dog = ns.Class("Dog", Animal)        -- Dog inherits from Animal
--   function Dog:init(name)
--       Animal.init(self, name)                -- call the parent constructor
--       self.legs = 4
--   end
--   function Dog:speak() return "Woof" end
--
--   local rex = Dog:new("Rex")                 -- builds the object, runs :init
--   rex:speak()            --> "Woof"
--   rex:isInstanceOf(Animal) --> true

local _, ns = ...

--- Create a new class (prototype).
-- @param name  string  Human-readable class name, used for debugging.
-- @param base  table?  Optional parent class to inherit from.
-- @return table The new class. Call `Class:new(...)` to instantiate it.
function ns.Class(name, base)
	-- The class table doubles as the metatable for its instances. Instances
	-- resolve missing keys through `__index = class`, and the class itself
	-- resolves missing keys (inherited methods) through its own metatable
	-- pointing at `base`. This gives us a clean two-level lookup chain:
	--     instance -> class -> base -> base.base -> ...
	local class = setmetatable({}, base and { __index = base } or nil)
	class.__index = class
	class.__name = name
	class.__super = base

	--- Construct an instance of this class.
	-- `self` is the class the method was invoked on, so subclasses that inherit
	-- `new` still produce an instance of the correct (sub)class.
	-- Any arguments are forwarded to the class's `init` method, if present.
	function class.new(self, ...)
		local instance = setmetatable({}, self)
		if instance.init then
			instance:init(...)
		end
		return instance
	end

	--- Test whether this instance descends from `klass`.
	-- Walks the inheritance chain so subclasses report true for their ancestors.
	-- @param klass table A class returned by ns.Class.
	-- @return boolean
	function class.isInstanceOf(self, klass)
		local current = getmetatable(self)
		while current do
			if current == klass then
				return true
			end
			current = current.__super
		end
		return false
	end

	return class
end
