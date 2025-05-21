local function show_help()
    print([[
Usage: lua gen_list_of_URLs.lua [options]
Options:
  -i, --input FILE     Input file containing URLs (default: links.txt)
  -o, --output FILE    Output file for selected URLs (default: selected_links.txt)
  -k, --keywords FILE  File containing keywords to match, one per line
  -e, --extension EXT  Filter by file extension (e.g., epub, pdf)
  -h, --help           Show this help message
]])
end

local function parse_args(args)
    local options = {
        input = "links.txt",
        output = "selected_links.txt",
        keywords = nil,
        extension = nil
    }
    
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "-i" or arg == "--input" then
            options.input = args[i + 1]
            i = i + 2
        elseif arg == "-o" or arg == "--output" then
            options.output = args[i + 1]
            i = i + 2
        elseif arg == "-k" or arg == "--keywords" then
            options.keywords = args[i + 1]
            i = i + 2
        elseif arg == "-e" or arg == "--extension" then
            options.extension = args[i + 1]
            i = i + 2
        elseif arg == "-h" or arg == "--help" then
            show_help()
            os.exit(0)
        else
            print("Unknown option: " .. arg)
            show_help()
            os.exit(1)
        end
    end
    
    return options
end

local function load_keywords(filename)
    local keywords = {}
    local file = io.open(filename, "r")
    if not file then
        error("Error opening keywords file: " .. filename)
    end
    
    for line in file:lines() do
        if line ~= "" then
            table.insert(keywords, line)
        end
    end
    file:close()
    return keywords
end

local function has_extension(url, extension)
    if not extension then
        return true  -- No extension filter
    end
    
    local escaped_ext = string.gsub(extension, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    return string.match(url, "%." .. escaped_ext .. "$") ~= nil
end

local default_keywords = {
    "Discrete Mathematics",
    "Algorithms",
    "Assembly",
    "x86"
}

local function main(args)
    local options = parse_args(args)
    
    local keywords = default_keywords
    if options.keywords then
        keywords = load_keywords(options.keywords)
    end
    
    print("Opening input file: " .. options.input)
    local file = io.open(options.input, "r")
    if not file then
        error("Error opening input file: " .. options.input)
    end
    
    print("Processing: finding links...")
    local matches = {}
    for line in file:lines() do
        if has_extension(line, options.extension) then
            for _, target in ipairs(keywords) do
                local escaped_target = string.gsub(target, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
                if string.find(line, escaped_target, 1, true) then
                    table.insert(matches, line)
                    break
                end
            end
        end
    end
    file:close()
    
    print("Writing matched links to: " .. options.output)
    local outfile = io.open(options.output, "w")
    if not outfile then
        error("Error opening output file: " .. options.output)
    end
    
    local count = 0
    for _, line in ipairs(matches) do
        count = count + 1
        outfile:write(line .. "\n")
    end
    outfile:close()
    
    print("Done! Found " .. count .. " matching links.")
end

main(arg)
