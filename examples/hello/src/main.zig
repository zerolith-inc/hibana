const hibana = @import("hibana");
const hw = @import("hibana-workers");

const Ctx = hibana.Context(hw.Runtime, hibana.NoVars);

fn index(c: *Ctx) !hibana.Response {
    return c.text("Hello from hibana!");
}

fn greet(c: *Ctx, p: struct { name: []const u8 }) !hibana.Response {
    return c.json(.{ .hello = p.name });
}

const App = hibana.App(hw.Runtime, .{ .routes = .{
    hibana.get("/", index),
    hibana.get("/hello/:name", greet),
} });

pub const fetch = hw.fetch(App);
