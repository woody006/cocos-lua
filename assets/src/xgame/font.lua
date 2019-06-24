local M = {}

local lib = {}

-- font {name = '', path = ''}
function M.register(font)
    lib[#lib + 1] = font
end

function M.lookup(name)
    if not name then
        return assert(lib[1], 'no default font')
    else
        for _, font in ipairs(lib) do
            if string.find(font.name, name) then
                return font
            end
        end
        error(string.format("font '%s' not found", name))
    end
end

return M