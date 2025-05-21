const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();
    defer _ = general_purpose_allocator.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <sql_file_path> [output_file_path] [--languages=lang1,lang2,...] [--debug=md5]\n", .{args[0]});
        std.debug.print("If output_file_path is not provided, results will be printed to stdout\n", .{});
        std.debug.print("Example: {s} libgen.sql books.txt --languages=english,german,russian\n", .{args[0]});
        return;
    }

    const file_path = args[1];

    const output_to_file = args.len >= 3;
    const output_path = if (output_to_file) args[2] else "";

    var debug_md5: []const u8 = "";
    var languages = std.ArrayList([]const u8).init(gpa);
    defer {
        for (languages.items) |lang| {
            gpa.free(lang);
        }
        languages.deinit();
    }

    for (args[3..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--languages=")) {
            const langs_str = arg["--languages=".len..];
            var lang_iter = std.mem.split(u8, langs_str, ",");
            while (lang_iter.next()) |lang| {
                if (lang.len > 0) {
                    const normalized_lang = try gpa.dupe(u8, lang);
                    for (0..normalized_lang.len) |i| {
                        normalized_lang[i] = std.ascii.toLower(normalized_lang[i]);
                    }
                    try languages.append(normalized_lang);
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--debug=")) {
            debug_md5 = arg["--debug=".len..];
        }
    }

    if (languages.items.len > 0) {
        std.debug.print("Filtering for languages: ", .{});
        for (languages.items) |lang| {
            std.debug.print("{s} ", .{lang});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("No language filters - including all languages\n", .{});
    }

    var output_file: ?fs.File = null;
    if (output_to_file) {
        output_file = try fs.cwd().createFile(output_path, .{});
    }

    try processLargeSQLFile(file_path, output_file, debug_md5, &languages, gpa);

    if (output_file) |of| {
        of.close();
    }

    std.debug.print("SQL processing completed.\n", .{});
}

fn processLargeSQLFile(file_path: []const u8, output_file: ?fs.File, debug_md5: []const u8, languages: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    std.debug.print("Opening file: {s}\n", .{file_path});

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    std.debug.print("File size: {} bytes\n", .{file_size});

    var reader = file.reader();

    // Using a 1MB buffer to read chunks
    const buffer_size = 1024 * 1024;
    var buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var in_values_section = false;
    var in_tuple = false;
    var in_quotes = false;
    var tuple_start: usize = 0;
    var bytes_read: usize = 0;
    var tuple_buffer = std.ArrayList(u8).init(allocator);
    defer tuple_buffer.deinit();

    var entry_count: usize = 0;
    var last_progress_pct: usize = 0;

    while (true) {
        const read_amount = try reader.read(buffer);
        if (read_amount == 0) break; // End of file

        bytes_read += read_amount;

        const progress_pct = bytes_read * 100 / file_size;
        if (progress_pct > last_progress_pct) {
            std.debug.print("Progress: {}% ({} of {} bytes)\n", .{ progress_pct, bytes_read, file_size });
            last_progress_pct = progress_pct;
        }

        var i: usize = 0;
        while (i < read_amount) {
            const c = buffer[i];

            if (!in_values_section) {
                if (c == 'L') {
                    if (i + 11 < read_amount and
                        mem.eql(u8, buffer[i .. i + 11], "LOCK TABLES"))
                    {
                        in_values_section = true;
                        std.debug.print("Found start of values section\n", .{});
                    }
                }
                i += 1;
                continue;
            }

            if (c == '\'' and (i == 0 or buffer[i - 1] != '\\')) {
                in_quotes = !in_quotes;
            }

            if (!in_quotes) {
                if (c == '(') {
                    if (!in_tuple) {
                        in_tuple = true;
                        tuple_start = i + 1;
                        tuple_buffer.clearRetainingCapacity();
                    }
                } else if (c == ')' and in_tuple) {
                    try tuple_buffer.append(')'); // Add the closing parenthesis
                    if (processEntryTupleFromBuffer(&tuple_buffer, output_file, debug_md5, languages, allocator, &entry_count)) {
                        // Success - continue
                    } else |err| {
                        // Log error but continue processing
                        std.debug.print("Error processing tuple: {}\n", .{err});
                    }
                    in_tuple = false;
                }
            }

            if (in_tuple) {
                try tuple_buffer.append(c);
            }

            i += 1;
        }
    }

    std.debug.print("Processed {} entries from {} bytes\n", .{ entry_count, bytes_read });
}

fn processEntryTupleFromBuffer(tuple_buffer: *std.ArrayList(u8), output_file: ?fs.File, debug_md5: []const u8, languages: *std.ArrayList([]const u8), allocator: std.mem.Allocator, entry_count: *usize) !void {
    const tuple = tuple_buffer.items;

    if (tuple.len < 10) return; // Skip very small tuples

    // The tuple format is (field1,field2,field3,...)
    // We need to extract fields 1 (Title), 37 (MD5), and 40 (Locator)

    var fields = std.ArrayList([]const u8).init(allocator);
    defer fields.deinit();

    var in_quotes = false;
    var field_start: usize = 0;

    var start_idx: usize = 0;
    if (tuple.len > 0 and tuple[0] == '(') {
        start_idx = 1;
        field_start = 1;
    }

    for (tuple[start_idx..], start_idx..) |c, i| {
        if (c == '\'' and (i == start_idx or tuple[i - 1] != '\\')) {
            in_quotes = !in_quotes;
        } else if (c == ',' and !in_quotes) {
            try fields.append(tuple[field_start..i]);
            field_start = i + 1;
        } else if (c == ')' and !in_quotes and i == tuple.len - 1) {
            // End of tuple
            if (field_start < i) {
                try fields.append(tuple[field_start..i]);
            }
            break;
        }
    }

    if (fields.items.len < 41) {
        return;
    }

    const id_raw = if (fields.items.len > 0) fields.items[0] else ""; // ID is field 0
    const title_raw = if (fields.items.len > 1) fields.items[1] else ""; // Title is field 1
    const extension_raw = if (fields.items.len > 36) fields.items[36] else ""; // Extension is field 36
    const md5_raw = if (fields.items.len > 37) fields.items[37] else ""; // MD5 is field 37
    const locator_raw = if (fields.items.len > 40) fields.items[40] else ""; // Locator is field 40
    const local_raw = if (fields.items.len > 41) fields.items[41] else ""; // Local is field 41
    const language_raw = if (fields.items.len > 12) fields.items[12] else "";

    const language = cleanSQLString(language_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(language);

    const id = cleanSQLString(id_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(id);

    const title = cleanSQLString(title_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(title);

    const extension = cleanSQLString(extension_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(extension);

    const md5 = cleanSQLString(md5_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(md5);

    if (md5.len == 0) return; // Skip if no MD5

    const locator = cleanSQLString(locator_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(locator);

    const local = cleanSQLString(local_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(local);

    const author_raw = if (fields.items.len > 5) fields.items[5] else "";
    const year_raw = if (fields.items.len > 6) fields.items[6] else "";

    const author = cleanSQLString(author_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(author);

    const year = cleanSQLString(year_raw, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(year);

    const is_debug_entry = debug_md5.len > 0 and std.mem.eql(u8, md5, debug_md5);

    // I'm not so sure how this ID is defined, so i tried this and it does seem to work (for testing examples)
    // Thus, im using this logic here
    // A simple, direct approach to get folder ID: use record ID / 1000 * 1000
    var folder_id_buf: [20]u8 = undefined; // Stack buffer for folder ID
    var folder_id: []const u8 = "0"; // Default

    // First try to get the raw ID directly
    if (id.len > 0) {
        const id_num = std.fmt.parseInt(u32, id, 10) catch 0;
        if (id_num > 0) {
            // Calculate folder as ID/1000*1000
            const folder_num = (id_num / 1000) * 1000;
            folder_id = std.fmt.bufPrint(&folder_id_buf, "{d}", .{folder_num}) catch "0";

            if (is_debug_entry) {
                std.debug.print("Calculated folder ID: {s} from record ID: {s}\n", .{ folder_id, id });
            }
        } else {
            // Error parsing, fallback
            if (is_debug_entry) {
                std.debug.print("Couldn't parse ID, using default folder 0\n", .{});
            }
        }
    }

    var filename_buffer = std.ArrayList(u8).init(allocator);
    defer filename_buffer.deinit();

    // Format: Author - Title (Year).extension
    if (author.len > 0) {
        try filename_buffer.appendSlice(author);
        try filename_buffer.appendSlice(" - ");
    }

    try filename_buffer.appendSlice(title);

    if (year.len > 0) {
        try filename_buffer.appendSlice(" (");
        try filename_buffer.appendSlice(year);
        try filename_buffer.appendSlice(")");
    }

    if (extension.len > 0) {
        try filename_buffer.appendSlice(".");
        try filename_buffer.appendSlice(extension);
    }

    // SQL LANGUAGE
    var language_allowed = false;
    if (languages.items.len == 0) {
        language_allowed = true;
    } else {
        for (languages.items) |allowed_lang| {
            if (std.ascii.eqlIgnoreCase(language, allowed_lang)) {
                language_allowed = true;
                break;
            }
        }
    }

    if (!language_allowed) return;

    const filename = filename_buffer.items;

    var encoded_filename = try allocator.alloc(u8, filename.len * 3); // Worst case: each char becomes %XX
    defer allocator.free(encoded_filename);

    const encoded_size = try urlEncode(filename, encoded_filename);

    const url = try std.fmt.allocPrint(allocator, "https://download.books.ms/main/{s}/{s}/{s}", .{ folder_id, md5, encoded_filename[0..encoded_size] });
    defer allocator.free(url);

    if (is_debug_entry) {
        std.debug.print("\n=== DEBUG INFO FOR MD5: {s} ===\n", .{md5});
        std.debug.print("ID: {s}\n", .{id});
        std.debug.print("Title: {s}\n", .{title});
        std.debug.print("Extension: {s}\n", .{extension});
        std.debug.print("Author: {s}\n", .{author});
        std.debug.print("Year: {s}\n", .{year});
        std.debug.print("Locator: {s}\n", .{locator});
        std.debug.print("Local: {s}\n", .{local});
        std.debug.print("Folder ID: {s}\n", .{folder_id});
        std.debug.print("Generated URL: {s}\n", .{url});
        std.debug.print("=== END DEBUG INFO ===\n\n", .{});
    }

    if (output_file) |of| {
        of.writeAll(url) catch {
            std.debug.print("Error writing to file\n", .{});
        };
        of.writeAll("\n") catch {};
    } else {
        std.debug.print("{s}\n", .{url});
    }

    entry_count.* += 1;
}

fn cleanSQLString(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (s.len == 0) return allocator.dupe(u8, "");

    var result = s;
    if (result.len >= 2 and result[0] == '\'' and result[result.len - 1] == '\'') {
        result = result[1 .. result.len - 1];
    }

    var cleaned = std.ArrayList(u8).init(allocator);
    errdefer cleaned.deinit();

    var i: usize = 0;
    while (i < result.len) {
        if (i + 1 < result.len and result[i] == '\\') {
            switch (result[i + 1]) {
                '\'', '\\', '"' => {
                    try cleaned.append(result[i + 1]);
                    i += 2;
                },
                'n' => {
                    try cleaned.append('\n');
                    i += 2;
                },
                't' => {
                    try cleaned.append('\t');
                    i += 2;
                },
                else => {
                    // Skip the backslash but include the character after it
                    i += 1;
                    try cleaned.append(result[i]);
                    i += 1;
                },
            }
        } else {
            try cleaned.append(result[i]);
            i += 1;
        }
    }

    return cleaned.toOwnedSlice();
}

fn urlEncode(input: []const u8, buffer: []u8) !usize {
    var j: usize = 0;
    for (input) |c| {
        if (j + 3 >= buffer.len) {
            // Buffer is too small, avoid overrun
            return error.BufferTooSmall;
        }

        if (ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            buffer[j] = c;
            j += 1;
        } else if (c == ' ') {
            buffer[j] = '%';
            buffer[j + 1] = '2';
            buffer[j + 2] = '0';
            j += 3;
        } else {
            // Encode as %XX
            buffer[j] = '%';

            // Convert to hex
            const hi = c >> 4;
            const lo = c & 0x0F;

            if (hi < 10) {
                buffer[j + 1] = '0' + @as(u8, @intCast(hi));
            } else {
                buffer[j + 1] = 'A' + @as(u8, @intCast(hi - 10));
            }

            if (lo < 10) {
                buffer[j + 2] = '0' + @as(u8, @intCast(lo));
            } else {
                buffer[j + 2] = 'A' + @as(u8, @intCast(lo - 10));
            }

            j += 3;
        }
    }

    return j; // Return the number of bytes written
}
