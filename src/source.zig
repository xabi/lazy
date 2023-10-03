const std = @import("std");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const Reader = std.io.Reader;
const File = std.fs.File;
const ReadError = std.os.ReadError;

pub fn Integers(comptime ItemT: type) type {
    return struct {
        startPoint: ItemT,
        stepCount: u16 = 8,
        allocator: Allocator,

        const Self = @This();

        pub fn init(startPoint: ItemT, stepCount: u16, allocator: Allocator) Self {
            return Self{ .startPoint = startPoint, .stepCount = stepCount, .allocator = allocator };
        }

        pub fn next(self: *Self) !?[]ItemT {
            var idx: usize = 0;
            var slice: []ItemT = try self.allocator.alloc(ItemT, self.stepCount); // try ArrayList(ItemT).initCapacity(self.allocator, self.stepCount);
            while (idx < self.stepCount) : (idx += 1) {
                slice[idx] = self.startPoint + idx;
            }
            self.startPoint += self.stepCount;
            return slice;
        }
    };
}

test "basic integers functionality" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    const array: [8]u64 = [8]u64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const slice = try integers.next();
    defer integers.allocator.free(slice.?);
    try testing.expectEqualSlices(u64, slice.?, array[0..8]);
    const array2: [8]u64 = [8]u64{ 8, 9, 10, 11, 12, 13, 14, 15 };
    const slice2 = try integers.next();
    defer integers.allocator.free(slice2.?);
    try testing.expectEqualSlices(u64, slice2.?, array2[0..8]);
    const array3: [8]u64 = [8]u64{ 16, 17, 18, 19, 20, 21, 22, 23 };
    const slice3 = try integers.next();
    defer integers.allocator.free(slice3.?);
    try testing.expectEqualSlices(u64, slice3.?, array3[0..8]);
}

pub fn Constant(comptime ItemT: type) type {
    return struct {
        constant: ItemT,
        stepCount: u16 = 8,
        allocator: Allocator,

        const Self = @This();

        pub fn init(constant: ItemT, stepCount: u16, allocator: Allocator) Self {
            return Self{ .constant = constant, .stepCount = stepCount, .allocator = allocator };
        }

        pub fn next(self: *Self) !?[]ItemT {
            var idx: usize = 0;
            var slice: []ItemT = try self.allocator.alloc(ItemT, self.stepCount);
            while (idx < self.stepCount) : (idx += 1) {
                slice[idx] = self.constant;
            }
            return slice;
        }
    };
}

test "Constant" {
    const allocator = std.testing.allocator;
    var constantSlice = Constant(u64).init(1, 8, allocator);
    var slice = try constantSlice.next();
    defer constantSlice.allocator.free(slice.?);
    try testing.expectEqualSlices(u64, &[_]u64{ 1, 1, 1, 1, 1, 1, 1, 1 }, slice.?);
}

pub fn Repeat(comptime ItemT: type, comptime slice: []const ItemT) type {
    return struct {
        allocator: Allocator,

        const Self = @This();
        pub fn init(allocator: Allocator) Self {
            return Self{ .allocator = allocator };
        }

        pub fn next(self: *Self) !?[]ItemT {
            return try self.allocator.dupe(ItemT, slice);
        }
    };
}

test "repeat test" {
    const allocator = std.testing.allocator;
    const RepeatS = Repeat(u64, &[_]u64{ 1, 2, 3, 4 });
    var repeat = RepeatS.init(allocator);
    var slice = try repeat.next();
    defer allocator.free(slice.?);
    try testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 4 }, slice.?);
    var slice2 = try repeat.next();
    defer allocator.free(slice2.?);
    try testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 4 }, slice2.?);
}

pub fn ReaderIterator(comptime ReaderT: type, comptime ItemT: type) type {
    return struct {
        reader: ReaderT,
        allocator: Allocator,
        done: bool = false,

        const Self = @This();

        pub fn init(reader: ReaderT, allocator: Allocator) Self {
            return .{ .allocator = allocator, .reader = reader };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            var buffer: [1024]ItemT = undefined;
            const byteCount: usize = try self.reader.read(&buffer);
            if (byteCount == 0) {
                self.done = true;
                return null;
            }

            return try self.allocator.dupe(ItemT, buffer[0..byteCount]);
        }
    };
}

test "Reader Iterator" {
    const FileReader = Reader(File, ReadError, File.read);
    const file = try std.fs.cwd().openFile("src/source.zig", .{});
    defer file.close();
    const reader: FileReader = file.reader();
    const allocator = std.testing.allocator;

    var readerIterator = ReaderIterator(FileReader, u8).init(reader, allocator);
    var buf = try readerIterator.next();
    defer allocator.free(buf.?);
}
