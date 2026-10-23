package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local mod = require("config.ctags_callsite")

local tags = {
  { name = "doWork", kind = "f", filename = "README.md", line = "1" },
  { name = "doWork", kind = "m", filename = "src/main/java/App.java", line = "42", class = "App" },
  { name = "doWork", kind = "m", filename = "logs/app.log", line = "9", class = "Noise" },
}

local filtered = mod._test_only_java_method_tags(tags)
assert(#filtered == 1, "expected exactly one Java method tag")
assert(filtered[1].filename == "src/main/java/App.java", "expected Java file to win")
