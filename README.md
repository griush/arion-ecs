# arion-ecs
Fast ECS library module for arion engine

## Usage
Add this dependency in the `build.zig.zon`:

```zig
.arion_ecs = .{
    .url = "https://github.com/griush/arion-ecs/archive/refs/heads/master.tar.gz"
    .hash = "hash here",
},

```

Then in the `build.zig` add:
```zig
const aecs = b.dependency("arion_ecs", .{});
exe.root_module.addImport("aecs", amth.module("root"));
```
Now, in your code, you can use:
```zig
const aecs = @import("aecs");
```
