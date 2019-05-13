return function (conf)
    local shell = require "core.shell"
    local lfs   = require "lfs"

    require "core.simulator"

    print("start build manifest")
    print("  setting name: " .. conf.NAME)
    print("    build path: " .. conf.BUILD_PATH)
    print("  publish path: " .. conf.PUBLISH_PATH)
    print("           url: " .. conf.URL)
    print("       version: " .. conf.VERSION)
    print("         debug: " .. tostring(conf.DEBUG))

    local LAST_MANIFEST_PATH = conf.PUBLISH_PATH .. '/current/assets.manifest'
    local ASSETS_PATH = conf.BUILD_PATH .. '/assets'
    local SHOULD_BUILD = conf.SHOULD_BUILD or function () return true end
    local IS_BUILTIN = conf.IS_BUILTIN or function () return false end

    if conf.NAME == 'BUILTIN' then
        LAST_MANIFEST_PATH = conf.BUILD_PATH .. '/assets/builtin.manifest'
    end

    local lastManifest = shell.readJson(LAST_MANIFEST_PATH, {assets = {}})
    local currManifest = {assets = {}}
    local hasUpdate = false

    for _, path in ipairs(shell.list(ASSETS_PATH)) do
        if path == 'builtin.manifest' or not SHOULD_BUILD(path) then
            goto continue
        end

        local fullPath = ASSETS_PATH .. "/" .. path
        local modified = lfs.attributes(fullPath, "modification")
        local last = lastManifest.assets[path]
        local curr

        if DEBUG and last and last.modified == modified then
            curr = {
                path = path,
                date = last.date,
                builtin = last.builtin,
                md5 = last.md5,
                modified = last.modified,
            }
        else
            curr = {
                path = path,
                date = os.time(),
                modified = modified,
                md5 = shell.md5sum(fullPath),
            }
        end

        currManifest.assets[#currManifest.assets + 1] = curr
        curr.builtin = IS_BUILTIN(path) and true or false
        if last and last.md5 == curr.md5 and last.builtin == curr.builtin then
            curr.date = last.date
        else
            print('update path: ' .. path)
            hasUpdate = true
        end

        ::continue::
    end

    if not hasUpdate then
        print("manifest is up-to-date")
    else
        table.sort(currManifest.assets, function (v1, v2)
            return v1.path < v2.path
        end)

        local data = {}
        local function writeline(fmt, ...)
            data[#data + 1] = string.format(fmt, ...)
            data[#data + 1] = '\n'
        end

        writeline('{')
        writeline('  "package_url":"%s",', conf.URL .. '/assets')
        writeline('  "manifest_url":"%s",', conf.URL .. '/assets.manifest')
        writeline('  "date":"%s",', os.date("!%Y-%m-%d %H:%M:%S", os.time() + 8 * 60 * 60))
        writeline('  "version":"%s",', conf.VERSION)

        local assets = {}
        for _, entry in ipairs(currManifest.assets) do
            local t = {}
            t[#t + 1] = string.format('"md5":"%s"', entry.md5)
            t[#t + 1] = string.format('"date":"%s"', entry.date)
            t[#t + 1] = string.format('"builtin":%s', entry.builtin)
            if DEBUG then
                t[#t + 1] = string.format('"modified":%d', entry.modified)
            end
            assets[#assets + 1] = string.format('    "%s":{%s}', entry.path, table.concat(t, ', '))
        end
        writeline('  "assets": {')
        writeline(table.concat(assets, ',\n'))
        writeline('  }')
        writeline('}')

        if conf.NAME == 'BUILTIN' then
            shell.write(conf.BUILD_PATH .. '/assets/builtin.manifest', table.concat(data, ''))
        else
            shell.write(conf.BUILD_PATH .. '/assets.manifest', table.concat(data, ''))

            data = {}
            writeline('{')
            writeline('  "main": {')
            writeline('    "package_url":"%s",', conf.URL .. '/assets')
            writeline('    "manifest_url":"%s",', conf.URL .. '/assets.manifest')
            writeline('    "date":"%s",', os.date("!%Y-%m-%d %H:%M:%S", os.time() + 8 * 60 * 60))
            writeline('    "version":"%s"', conf.VERSION)
            writeline('  }')
            writeline('}')
            shell.write(conf.BUILD_PATH .. '/version.manifest', table.concat(data, ''))
        end
    end

    return hasUpdate
end