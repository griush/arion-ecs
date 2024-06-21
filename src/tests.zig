const std = @import("std");
const aecs = @import("aecs");

test "aecs example" {
    const allocator = std.testing.allocator;

    var scene = try aecs.Registry.init(allocator);
    defer scene.deinit();

    const player = try scene.new();

    const Vec2 = struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
    };

    try scene.setComponent(player, "Name", @as([]const u8, "Arion"));
    try scene.setComponent(player, "Position", Vec2{});

    try std.testing.expectEqual(Vec2{}, scene.getComponent(player, "Position", Vec2).?);
    try std.testing.expectEqualStrings(scene.getComponent(player, "Name", []const u8).?, "Arion");

    try std.testing.expect(scene.hasComponent(player, "Position", Vec2) == true);

    try scene.removeComponent(player, "Position");
    try std.testing.expect(scene.getComponent(player, "Position", Vec2) == null);
    try std.testing.expect(scene.hasComponent(player, "Position", Vec2) == false);

    try scene.remove(player);
}
