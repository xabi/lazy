const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const sourcezig = @import("source.zig");
const Integers = sourcezig.Integers;
const RepeatSlice = sourcezig.RepeatSlice;

const ArrayList = std.ArrayList;

const LazyError = error{
    NoNext,
};

pub fn LazyTake(comptime SourceT: type, comptime ItemT: type) type {
    return struct {
        source: SourceT,
        current_count: usize = 0,
        count: usize,
        done: bool = false,
        allocator: Allocator,

        const Self = @This();

        pub fn init(source: SourceT, count: usize) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have an allocator field");
            }
            return Self{ .source = source, .current_count = 0, .count = count, .allocator = source.allocator };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            const slice = try self.source.next();

            if (slice == null) {
                self.done = true;
                return null;
            }

            self.current_count += slice.?.len;
            if (self.current_count < self.count) {
                return slice;
            }
            if (self.current_count == self.count) {
                self.done = true;
                return slice;
            }
            self.done = true;
            defer self.allocator.free(slice.?);
            const remainder: usize = slice.?.len - (self.current_count - self.count);
            if (remainder > 0) {
                return try self.allocator.dupe(ItemT, slice.?[0..remainder]);
            }
            return null;
        }
    };
}

test "simple lazy take over integers" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    var take = LazyTake(Integers(u64), u64).init(integers, 100);
    const allItems = try doAll(&take, u64);
    defer allItems.deinit();
    try testing.expect(allItems.items.len == 100);
}

pub fn LazyFilter(comptime SourceT: type, comptime ItemT: type, comptime filterFn: fn (a: ItemT) bool) type {
    return struct {
        source: SourceT,
        done: bool = false,

        allocator: Allocator,

        const Self = @This();

        pub fn init(source: SourceT) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have an allocator field");
            }
            return Self{
                .source = source,
                .allocator = source.allocator,
            };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            var slice = try self.source.next();

            if (slice == null) {
                self.done = true;
                return null;
            }
            defer self.allocator.free(slice.?);
            var filteredOptSlice = try self.allocator.alloc(?ItemT, slice.?.len);
            defer self.allocator.free(filteredOptSlice);

            var idx: usize = 0;
            var count: usize = 0;
            for (slice.?) |item| {
                if (filterFn(item)) {
                    filteredOptSlice[idx] = item;
                    count += 1;
                } else {
                    filteredOptSlice[idx] = null;
                }
                idx += 1;
            }
            var filteredSlice = try self.allocator.alloc(ItemT, count);
            var filterSliceIdx: usize = 0;
            for (filteredOptSlice) |item| {
                if (item != null) {
                    filteredSlice[filterSliceIdx] = item.?;
                    filterSliceIdx += 1;
                }
            }

            return filteredSlice;
        }
    };
}

pub fn divisibleByThree(num: u64) bool {
    return @rem(num, 3) == 0;
}

test "filter over integers, take 100" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    var filter = LazyFilter(Integers(u64), u64, divisibleByThree).init(integers);
    var take = LazyTake(LazyFilter(Integers(u64), u64, divisibleByThree), u64).init(filter, 6);
    const allItems2 = try doAll(&take, u64);
    defer allItems2.deinit();

    try testing.expectEqualSlices(u64, &[6]u64{ 0, 3, 6, 9, 12, 15 }, allItems2.items);
}

pub fn LazyDrop(comptime SourceT: type, comptime ItemT: type) type {
    return struct {
        source: SourceT,
        count: usize,
        done: bool = false,
        allocator: Allocator,

        const Self = @This();

        pub fn init(source: SourceT, count: usize) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have a next delaration");
            }
            return Self{ .source = source, .count = count, .allocator = source.allocator };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            var slice = try self.source.next();

            if (slice == null) {
                self.done = true;
                return null;
            }

            const old_count = self.count;
            const new_count: i64 = @as(i64, @intCast(old_count)) - @as(i64, @intCast(slice.?.len));
            self.count = @max(new_count, 0);

            if (self.count > 0) {
                defer self.allocator.free(slice.?);
                const empty_slice = try self.allocator.alloc(ItemT, 0);
                return empty_slice;
            }
            if (old_count > 0 and new_count < 0) {
                defer self.allocator.free(slice.?);
                var new_slice = try self.allocator.dupe(ItemT, slice.?[old_count..]);
                return new_slice;
            }

            return slice.?;
        }
    };
}

test "drop 10 from divisible by 3 integers" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    const Filter = LazyFilter(Integers(u64), u64, divisibleByThree);
    var filter = Filter.init(integers);
    const Drop = LazyDrop(Filter, u64);
    var drop = Drop.init(filter, 4);
    const Take = LazyTake(Drop, u64);
    var take = Take.init(drop, 4);
    const someInts = try doAll(&take, u64);
    defer someInts.deinit();
    try testing.expectEqualSlices(u64, &[4]u64{ 12, 15, 18, 21 }, someInts.items);
}

pub fn LazyTakeWhile(comptime SourceT: type, comptime ItemT: type, comptime func: fn (a: ItemT) bool) type {
    return struct {
        source: SourceT,
        done: bool = false,
        allocator: Allocator,

        const Self = @This();
        pub fn init(source: SourceT) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have a next delaration");
            }
            return Self{ .source = source, .allocator = source.allocator };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            var slice = try self.source.next();
            if (slice == null) {
                self.done = true;
                return null;
            }
            var all: bool = true;
            var count: usize = 0;
            for (slice.?) |item| {
                if (!func(item)) {
                    all = false;
                    break;
                }
                count += 1;
            }
            if (all) {
                return slice.?;
            }
            defer self.allocator.free(slice.?);
            self.done = true;
            var new_slice = try self.allocator.dupe(ItemT, slice.?[0..count]);
            return new_slice;
        }
    };
}

pub fn lessThan50(num: u64) bool {
    return num < 50;
}

test "take divisible by 3 integers while they are less than 50" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    const Filter = LazyFilter(Integers(u64), u64, divisibleByThree);
    var filter = Filter.init(integers);
    const TakeWhile = LazyTakeWhile(Filter, u64, lessThan50);
    var takeWhile = TakeWhile.init(filter);
    const someInts = try doAll(&takeWhile, u64);
    defer someInts.deinit();
    try testing.expectEqualSlices(u64, &[_]u64{ 0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48 }, someInts.items);
}

pub fn LazyDropWhile(comptime SourceT: type, comptime ItemT: type, comptime func: fn (ItemT) bool) type {
    return struct {
        source: SourceT,
        allocator: Allocator,
        done: bool = false,
        unlocked: bool,

        const Self = @This();

        pub fn init(source: SourceT) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have a next delaration");
            }
            return Self{ .source = source, .allocator = source.allocator, .unlocked = false };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            var slice = try self.source.next();
            if (slice == null) {
                self.done = true;
                return null;
            }

            if (self.unlocked) {
                return slice.?;
            }

            var count: usize = 0;
            var every: bool = true;
            for (slice.?) |item| {
                if (!func(item)) {
                    every = false;
                    break;
                }
                count += 1;
            }

            defer self.allocator.free(slice.?);
            if (every) {
                return try self.allocator.alloc(ItemT, 0);
            }
            self.unlocked = true;
            return try self.allocator.dupe(ItemT, slice.?[count..]);
        }
    };
}

pub fn lessThan25(num: u64) bool {
    return num < 25;
}

test "take divisible by 3 integers while they are less than 50 and more than 25" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    const Filter = LazyFilter(Integers(u64), u64, divisibleByThree);
    var filter = Filter.init(integers);
    const DropWhile = LazyDropWhile(Filter, u64, lessThan25);
    var dropWhile = DropWhile.init(filter);
    const TakeWhile = LazyTakeWhile(DropWhile, u64, lessThan50);
    var takeWhile = TakeWhile.init(dropWhile);
    const someInts = try doAll(&takeWhile, u64);
    defer someInts.deinit();
    try testing.expectEqualSlices(u64, &[_]u64{ 27, 30, 33, 36, 39, 42, 45, 48 }, someInts.items);
}

pub fn LazyMap(comptime SourceT: type, comptime ItemT: type, comptime FinalItemT: type, comptime mapFn: fn (Allocator, ItemT) FinalItemT) type {
    return struct {
        source: SourceT,
        allocator: Allocator,
        done: bool = false,

        const Self = @This();

        pub fn init(source: SourceT) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have a next delaration");
            }
            return Self{ .source = source, .allocator = source.allocator };
        }

        pub fn next(self: *Self) !?[]FinalItemT {
            if (self.done) return null;

            var slice = try self.source.next();
            if (slice == null) {
                self.done = true;
                return null;
            }
            defer self.allocator.free(slice.?);

            var mapped_slice = try self.allocator.alloc(FinalItemT, slice.?.len);
            for (slice.?, 0..) |item, idx| {
                mapped_slice[idx] = mapFn(self.allocator, item);
            }
            return mapped_slice;
        }
    };
}

fn timesMinus2(allocator: Allocator, num: u64) i64 {
    _ = allocator;
    return @as(i64, @intCast(num)) * -2;
}

test "take divisible by 3 integers while they are less than 50 and more than 25 mul by minus 2" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    const Filter = LazyFilter(Integers(u64), u64, divisibleByThree);
    var filter = Filter.init(integers);
    const DropWhile = LazyDropWhile(Filter, u64, lessThan25);
    var dropWhile = DropWhile.init(filter);
    const TakeWhile = LazyTakeWhile(DropWhile, u64, lessThan50);
    var takeWhile = TakeWhile.init(dropWhile);
    const Map = LazyMap(TakeWhile, u64, i64, timesMinus2);
    var map = Map.init(takeWhile);
    const someInts = try doAll(&map, i64);
    defer someInts.deinit();
    try testing.expectEqualSlices(i64, &[8]i64{ -54, -60, -66, -72, -78, -84, -90, -96 }, someInts.items);
}

fn length(allocator: Allocator, slice: []const u8) usize {
    defer allocator.free(slice);

    return slice.len;
}

test "other test for map" {
    const allocator = std.testing.allocator;
    const Reader = std.io.Reader;
    const File = std.fs.File;
    const ReadError = std.os.ReadError;
    const ReaderIterator = sourcezig.ReaderIterator;
    const FileReader = Reader(File, ReadError, File.read);
    const file = try std.fs.cwd().openFile("src/source.zig", .{});
    defer file.close();
    const reader: FileReader = file.reader();

    var readerIterator = ReaderIterator(FileReader, u8).init(reader, allocator);
    const LazyCollate = LazyCollateWithSeparator(ReaderIterator(FileReader, u8), u8);
    const separator: []const u8 = "\n";
    var collate = LazyCollate.init(readerIterator, separator);
    var map = LazyMap(LazyCollate, []const u8, usize, length).init(collate);
    const someInts = try doAll(&map, usize);
    defer someInts.deinit();
    try testing.expectEqualSlices(usize, &[_]usize{ 27, 0, 36, 28, 29 }, someInts.items[0..5]);
}

pub fn LazyFlapMap(comptime SourceT: type, comptime ItemT: type, comptime IteratorT: type, comptime FinalItemT: type, comptime mapFn: anytype) type {
    return struct {
        source: SourceT,
        allocator: Allocator,
        done: bool = false,
        current_slice: []ItemT = &[_]ItemT{},
        current_iterator: ?*IteratorT = null,

        const Self = @This();

        pub fn init(source: SourceT) Self {
            if (!@hasDecl(SourceT, "next")) {
                @compileError("source must have a next delaration");
            }
            if (!@hasField(SourceT, "allocator")) {
                @compileError("source must have a next delaration");
            }
            return Self{ .source = source, .allocator = source.allocator };
        }

        pub fn next(self: *Self) !?[]FinalItemT {
            if (self.done) return null;

            if (self.current_slice.len == 0) {
                var slice = try self.source.next();
                if (slice == null) {
                    self.done = true;
                    return null;
                }
                defer self.allocator.free(slice.?);
                self.current_slice = try self.allocator.dupe(ItemT, slice.?);
            }

            if (self.current_iterator == null) {
                self.current_iterator = try mapFn(self.allocator, self.current_slice[0]);
            }

            var slice = try self.current_iterator.?.next();

            if (slice == null) {
                var old_slice = self.current_slice;
                defer self.allocator.free(old_slice);
                self.current_slice = try self.allocator.dupe(ItemT, self.current_slice[1..]);
                self.allocator.destroy(self.current_iterator.?);
                self.current_iterator = null;
                return try self.allocator.alloc(FinalItemT, 0);
            }

            return slice;
        }
    };
}

const Integers64 = Integers(u64);
const IntTake = LazyTake(Integers64, u64);
pub fn flatMapFn(allocator: Allocator, num: u64) !*IntTake {
    var integers = Integers64.init(0, 8, allocator);
    var take = IntTake.init(integers, num);

    var heap_take: *IntTake = try allocator.create(IntTake);
    heap_take.* = take;
    return heap_take;
}

test "test flatMap" {
    const allocator = std.testing.allocator;
    var integers = Integers(u64).init(0, 8, allocator);
    const Take = LazyTake(Integers(u64), u64);
    var take = Take.init(integers, 10);
    const FlatMap = LazyFlapMap(Take, u64, IntTake, u64, flatMapFn);
    var flatMap = FlatMap.init(take);

    const someInts = try doAll(&flatMap, u64);
    defer someInts.deinit();
    try testing.expectEqualSlices(u64, &[_]u64{ 0, 0, 1, 0, 1, 2, 0, 1, 2, 3, 0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 6, 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 8 }, someInts.items);
}

pub fn LazyCollateWithSeparator(comptime SourceT: type, comptime ItemT: type) type {
    return struct {
        source: SourceT,
        buffer: ArrayList(ItemT),
        separator: []const ItemT,
        done: bool = false,
        allocator: Allocator,

        const Self = @This();

        pub fn init(source: SourceT, separator: []const ItemT) Self {
            const buffer = ArrayList(ItemT).init(source.allocator);
            return Self{ .source = source, .allocator = source.allocator, .separator = separator, .buffer = buffer };
        }

        pub fn next(self: *Self) !?[][]const ItemT {
            if (self.done) {
                return null;
            }

            var slice = try self.source.next();

            if (slice == null) {
                self.done = true;
                var bufferSlice = try self.buffer.toOwnedSlice();
                if (bufferSlice.len > 0) {
                    var bufferSliceArray = try ArrayList([]ItemT).initCapacity(self.allocator, 1);
                    try bufferSliceArray.append(bufferSlice);
                    const last_slice = try bufferSliceArray.toOwnedSlice();
                    return last_slice;
                }
                return null;
            }
            defer self.allocator.free(slice.?);
            try self.buffer.appendSlice(slice.?);
            if (mem.indexOf(ItemT, self.buffer.items, self.separator) == null) {
                //std.debug.print("\naccumulating and answering empty stuff {s} \n", .{self.buffer.items});
                return try self.allocator.alloc([]ItemT, 0);
            }
            var slices: [][]const u8 = split: {
                var splits = ArrayList([]const ItemT).init(self.allocator);
                var spliterator = mem.splitSequence(ItemT, self.buffer.items, self.separator);
                while (spliterator.next()) |it| {
                    try splits.append(it);
                }
                break :split (try splits.toOwnedSlice());
            };
            defer self.allocator.free(slices);
            const old_buffer = self.buffer;
            defer old_buffer.deinit();
            self.buffer = ArrayList(ItemT).init(self.allocator);
            try self.buffer.appendSlice(slices[slices.len - 1]);
            var result = try self.allocator.alloc([]ItemT, slices.len - 1);
            for (slices[0 .. slices.len - 1], 0..) |it, idx| {
                result[idx] = try self.allocator.dupe(ItemT, it);
            }
            return result;
        }
    };
}

test "lazy collate" {
    const allocator = std.testing.allocator;
    const Reader = std.io.Reader;
    const File = std.fs.File;
    const ReadError = std.os.ReadError;
    const ReaderIterator = sourcezig.ReaderIterator;
    const FileReader = Reader(File, ReadError, File.read);
    const file = try std.fs.cwd().openFile("src/source.zig", .{});
    defer file.close();
    const reader: FileReader = file.reader();

    var readerIterator = ReaderIterator(FileReader, u8).init(reader, allocator);
    const LazyCollate = LazyCollateWithSeparator(ReaderIterator(FileReader, u8), u8);
    const separator: []const u8 = "\n";
    var collate = LazyCollate.init(readerIterator, separator);
    const someInts = try doAll(&collate, []const u8);
    defer someInts.deinit();
    defer {
        switch (@typeInfo(@TypeOf(someInts.items))) {
            .Pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .Slice => {
                        for (someInts.items) |it| {
                            allocator.free(it);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn LazyJoin(comptime T: type, comptime ItemT: type) type {
    return struct {
        source: T,
        allocator: Allocator,
        done: bool = false,

        const Self = @This();
        pub fn init(source: T) Self {
            return Self{ .allocator = source.allocator, .source = source };
        }

        pub fn next(self: *Self) !?[]ItemT {
            if (self.done) return null;

            var slice = try self.source.next();
            if (slice == null) {
                self.done = true;
                return null;
            }
            defer self.allocator.free(slice.?);
            var array = ArrayList(ItemT).init(self.allocator);
            for (slice.?) |it| {
                try array.appendSlice(it);
                defer self.allocator.free(it);
            }
            return try array.toOwnedSlice();
        }
    };
}

test "lazy join" {
    const allocator = std.testing.allocator;
    const Reader = std.io.Reader;
    const File = std.fs.File;
    const ReadError = std.os.ReadError;
    const ReaderIterator = sourcezig.ReaderIterator;
    const FileReader = Reader(File, ReadError, File.read);
    const file = try std.fs.cwd().openFile("src/source.zig", .{});
    defer file.close();
    const reader: FileReader = file.reader();

    var readerIterator = ReaderIterator(FileReader, u8).init(reader, allocator);
    const LazyCollate = LazyCollateWithSeparator(ReaderIterator(FileReader, u8), u8);
    const separator: []const u8 = "\n";
    var collate = LazyCollate.init(readerIterator, separator);
    const Join = LazyJoin(LazyCollate, u8);
    var join = Join.init(collate);
    const someInts = try doAll(&join, u8);
    defer someInts.deinit();
}

pub fn doAll(iterator: anytype, comptime ItemT: type) !std.ArrayList(ItemT) {
    var allItems = std.ArrayList(ItemT).init(iterator.allocator);
    while (true) {
        const slice = try iterator.next();
        if (slice == null) break;
        defer iterator.allocator.free(slice.?);
        try allItems.appendSlice(slice.?);
    }
    return allItems;
}

pub fn main() !void {
    //var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //defer arena.deinit();
    //const allocator = arena.allocator();
}
