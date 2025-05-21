-- for a more selective approach, a small helper script to parse the linksfile and select each Link containing
-- these keywords and save them in a file.
-- the result is a output.txt file containing Links of URLs matching these Words for filtered Downloading
local strarr = {"Biology", "Computer"}

local file = io.open("links.txt", "r")
if not file then
    error("error opening file ... ")
end

local matches = {}
for line in file:lines() do
    for _, target in ipairs(strarr) do
        -- Escape any special pattern characters in the target string
        local escaped_target = string.gsub(target, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        
        -- Use plain text matching (third parameter as true) to avoid pattern matching
        if string.find(line, escaped_target, 1, true) then
            table.insert(matches, line)
            break
        end
    end
end

file:close()

local outfile = io.open("output.txt", "w")
if not outfile then
    error("error opening output file ... ")
end

for _, line in ipairs(matches) do
    outfile:write(line .. "\n")
end
outfile:close()
print("done...")
