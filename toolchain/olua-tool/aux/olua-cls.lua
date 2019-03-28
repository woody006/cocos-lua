local typeinfo_map = {}

local function to_pretty_typename(typename)
    -- t = '   const   type   *   &  '
    -- typename = string.gsub(typename, '&', '')   -- t = '   const  type   *    '
    typename = string.gsub(typename, '^ *', '') -- t = 'const  type   *    '
    typename = string.gsub(typename, ' *$', '') -- t = 'const  type   *'
    typename = string.gsub(typename, ' +', ' ') -- t = 'const type *'

    -- const type * * => const type **
    typename = string.gsub(typename, ' %*', '*')
    typename = string.gsub(typename, '%*+', function (str) return " " .. str end)

    typename = string.gsub(typename, ' %&', '&')
    typename = string.gsub(typename, '%&+', function (str) return " " .. str end)

    return typename
end

local function to_real_typename(typename)
    typename = string.gsub(typename, '&', '')
    typename = string.gsub(typename, ' *$', '')

    if typeinfo_map[typename] then
        return typename, true
    end

    local noconst = string.gsub(typename, 'const *', '')
    if typeinfo_map[noconst] then
        return noconst, true
    end
    
    return typename, false
end

function test_typename(typename)
    return typeinfo_map[typename]
end

function get_typeinfo(typename, cls)
    local typename = to_pretty_typename(typename)
    local typeinfo
    local subtypeinfo, subtypename -- for typename<T>

    if string.find(typename, '<') then
        subtypename = string.match(typename, '<(.*)>')
        subtypeinfo, subtypename = get_typeinfo(subtypename, cls)
        typename = string.gsub(typename, '<.*>', '')
    end

    typename = to_real_typename(typename)
    typeinfo = typeinfo_map[typename]

    if typeinfo then
        typeinfo = setmetatable({SUBTYPE = subtypeinfo}, {__index = typeinfo})
        return typeinfo, typename, subtypename
    end

    if cls and cls.CPPCLS then
        local function try_namespace(ns, typename)
            local tn = string.gsub(typename, '[%w:_]+ *%**$', function (s)
                return ns .. '::' .. s
            end)
            tn = to_real_typename(tn)
            return typeinfo_map[tn], tn
        end

        local ti, tn
        local nsarr = {}
        for n in string.gmatch(cls.CPPCLS, '[^:]+') do
            nsarr[#nsarr + 1] = n
        end

        while #nsarr > 0 do
            local ns = table.concat(nsarr, "::")
            ti, tn = try_namespace(ns, typename)
            if not ti then
                nsarr[#nsarr] = nil
            else
                break
            end
        end

        if ti then
            typeinfo = ti
            typename = tn
        end

        if typeinfo then
            typeinfo = setmetatable({SUBTYPE = subtypeinfo}, {__index = typeinfo})
            return typeinfo, typename, subtypename
        end
    end

    if not typeinfo then
        error(string.format("type info not found: %s", typename))
    end
end

local function to_decl_type(cls, typename, remove_const, keep_ref)
    local ref = string.match(typename, '&+')
    local typeinfo, typename, subtypename = get_typeinfo(typename, cls)

    if subtypename then
        typename = string.format('%s<%s>', typename, subtypename)
        if remove_const then
            typename = string.gsub(typename, 'const *', '')
        end
    end

    if keep_ref and ref then
        typename = typename .. ' ' .. ref
    end

    return typename
end

local function parse_attr(arg)
    local attr = {}
    arg = string.gsub(arg, '^ *', '')
    while true do
        local opt, value = string.match(arg, '^@(%w+)%(([%w ]*)%)')
        if opt then
            local arr = {}
            for v in string.gmatch(value, '[^ ]+') do
                arr[#arr + 1] = v
            end
            attr[string.upper(opt)] = arr
            arg = string.gsub(arg, '^@%w+%([%w ]*%)', '')
        else
            opt = string.match(arg, '^@(%w+)')
            if opt then
                attr[string.upper(opt)] = true
                arg = string.gsub(arg, '^@%w+', '')
            else
                break
            end
        end
    end
    local arg, static = string.gsub(arg, '^ *static *', '')
    attr.STATIC = static > 0
    return attr, arg
end

local function parse_def(str)
    local KEYWORD = {const = true, signed = true, unsigned = true}
    local attr, str = parse_attr(str)
    local typename = string.match(str, '^[^<>(),]*%b<>[ &*]*')
    if not typename then
        local from, to
        while true do
            from, to = string.find(str, ' *[^ (),]+[ &*]*', to)
            if not from then
                break
            end
            typename = string.sub(str, from, to)
            if not KEYWORD[string.match(typename, '%w+')] then
                typename = string.sub(str, 1, to)
                break
            end
        end
    end
    str = string.sub(str, #typename + 1)
    return to_pretty_typename(typename), attr, str
end

local parse_args

local function parse_callback(cls, typename, default)
    local rt, rt_attr, cb_args_str
    local cb_args_str = string.match(typename, '<(.*)>')
    rt, rt_attr, cb_args_str = parse_def(cb_args_str)
    cb_args_str = string.gsub(cb_args_str, '^[^(]+', '')
    local cb_args = parse_args(cls, cb_args_str)
    local cb_args_decl = {}
    for _, ai in ipairs(cb_args) do
        cb_args_decl[#cb_args_decl + 1] = ai.FUNC_ARG_DECL_TYPE
    end
    cb_args_decl = table.concat(cb_args_decl, ", ")
    cb_args_decl = string.format('std::function<%s(%s)>',
        to_decl_type(cls, rt, false, true), cb_args_decl)
    return {
        DEFAULT = default,
        ARGS = cb_args,
        RET = get_typeinfo(rt, cls),
        RET_ATTR = rt_attr,
        ARGS_DECL = cb_args_decl,
    }
end

function parse_args(cls, args_str)
    local args = {}
    local max_args = 0
    args_str = assert(string.match(args_str, '%((.*)%)'), args_str)

    while #args_str > 0 do
        local typename, attr, varname, default
        typename, attr, args_str = parse_def(args_str)
        if typename == 'void' then
            return args, max_args
        end

        varname, default = string.match(args_str, '^([^ ]+) *= *([^ ,]*)')
        if not varname then
            varname = string.match(args_str, '^ *[^ ,]+')
        end

        args_str = string.gsub(args_str, '^[^,]*,? *', '')

        if default then
            if string.find(default, '%(') then
                local other = string.match(args_str, '[^)]+%)')
                default = default .. ', ' .. other
                args_str = string.gsub(args_str, '^[^)]*%),? *', '')
                local deft = string.match(default, '[^(]+')
                local defti = get_typeinfo(deft, cls)
                default = defti.TYPENAME .. string.match(default, '(%([^()]*%))')
            elseif string.find(default, '::') then
                local deft, def = string.match(default, '(.*)::([^:]+)$')
                local defti = get_typeinfo(deft, cls)
                default = defti.TYPENAME .. '::' .. def
            end
        end

        if string.find(typename, 'std::function<') then
            local callback = parse_callback(cls, typename, default)
            args[#args + 1] = {
                TYPE = setmetatable({
                    DECL_TYPE = callback.ARGS_DECL,
                }, {__index = get_typeinfo('std::function', cls)}),
                DECL_TYPE = callback.ARGS_DECL,
                VARNAME = varname,
                ATTR = attr,
                CALLBACK = callback,
            }
        else
            args[#args + 1] = {
                TYPE = get_typeinfo(typename, cls),
                DECL_TYPE = to_decl_type(cls, typename, true),
                FUNC_ARG_DECL_TYPE = to_decl_type(cls, typename, false, true),
                DEFAULT = default,
                VARNAME = varname,
                ATTR = attr,
                CALLBACK = {},
            }
        end

        if attr.PACK then
            max_args = max_args + assert(args[#args].TYPE.VARS, args[#args].TYPE.TYPENAME)
        else
            max_args = max_args + 1
        end
    end

    return args, max_args
end

local function parse_func(cls, name, ...)
    local function copy(t)
        return setmetatable({}, {__index = t})
    end
    local arr = {MAX_ARGS = 0}
    local is_static_func
    for i, func_decl in ipairs({...}) do
        local fi = {RET = {}}
        if string.find(func_decl, '{') then
            fi.LUAFUNC = assert(name)
            fi.CPPFUNC = name
            fi.CPPFUNC_SNIPPET = func_decl
            fi.FUNC_DECL = '<function snippet>'
            fi.RET.NUM = 0
            fi.RET.TYPE = get_typeinfo('void', cls)
            fi.RET.ATTR = {}
            fi.ARGS = {}
            fi.INJECT = {}
            fi.PROTOTYPE = false
            fi.MAX_ARGS = #fi.ARGS
        else
            local typename, attr, str = parse_def(func_decl)
            fi.CPPFUNC = string.match(str, '[^ ()]+')
            fi.LUAFUNC = name or fi.CPPFUNC
            fi.STATIC = attr.STATIC
            fi.FUNC_DECL = func_decl
            fi.INJECT = {}
            if string.find(typename, 'std::function<') then
                local callback = parse_callback(cls, typename, default)
                fi.RET = {
                    TYPE = setmetatable({
                        DECL_TYPE = callback.ARGS_DECL,
                    }, {__index = get_typeinfo('std::function', cls)}),
                    DECL_TYPE = callback.ARGS_DECL,
                    ATTR = attr,
                    NUM = 1,
                    CALLBACK = callback,
                }
            else
                fi.RET.TYPE = get_typeinfo(typename, cls)
                fi.RET.NUM = fi.RET.TYPE.TYPENAME == "void" and 0 or 1
                fi.RET.DECL_TYPE = to_decl_type(cls, typename, false, true)
                fi.RET.ATTR = attr
            end
            fi.ARGS, fi.MAX_ARGS = parse_args(cls, string.sub(str, #fi.CPPFUNC + 1))

            do
                local ARGS_DECL = {}
                local RET_DECL = fi.RET.DECL_TYPE
                local CPPFUNC = fi.CPPFUNC
                local STATIC = fi.STATIC and "static " or ""
                for _, v in ipairs(fi.ARGS) do
                    ARGS_DECL[#ARGS_DECL + 1] = v.DECL_TYPE
                end
                ARGS_DECL = table.concat(ARGS_DECL, ", ")

                fi.PROTOTYPE = format_snippet([[
                    ${STATIC}${RET_DECL} ${CPPFUNC}(${ARGS_DECL})
                ]])
                cls.PROTOTYPES[fi.PROTOTYPE] = true
            end

            if is_static_func == nil then
                is_static_func = fi.STATIC
            else
                assert(is_static_func == fi.STATIC, func_decl)
            end

            -- has @pack? gen one more func
            if fi.MAX_ARGS ~= #fi.ARGS then
                local packarg
                local fi2 = copy(fi)
                fi2.RET = copy(fi.RET)
                fi2.RET.ATTR = copy(fi.RET.ATTR)
                fi2.ARGS = {}
                fi2.FUNC_DECL = string.gsub(fi.FUNC_DECL, '@pack *', '')
                for i in ipairs(fi.ARGS) do
                    fi2.ARGS[i] = copy(fi.ARGS[i])
                    fi2.ARGS[i].ATTR = copy(fi.ARGS[i].ATTR)
                    if fi.ARGS[i].ATTR.PACK then
                        assert(not packarg, 'too many pack args')
                        packarg = fi.ARGS[i]
                        fi2.ARGS[i].ATTR.PACK = false
                        fi2.MAX_ARGS = fi2.MAX_ARGS + 1 - packarg.TYPE.VARS
                    end
                end
                assert(packarg, func_decl)
                if packarg.TYPE.TYPENAME == fi.RET.TYPE.TYPENAME then
                    fi2.RET.ATTR.UNPACK = fi.RET.ATTR.UNPACK or false
                    fi.RET.ATTR.UNPACK = true
                end
                arr[#arr + 1] = fi2
                fi2.INDEX = #arr
            end
        end
        assert(not string.find(fi.LUAFUNC, '[^_%w]+'), '"' .. fi.LUAFUNC .. '"')
        arr[#arr + 1] = fi
        arr.MAX_ARGS = math.max(arr.MAX_ARGS, fi.MAX_ARGS)
        fi.INDEX = #arr
    end

    return arr
end

local function to_prop_func_name(cppfunc, prefix)
    return prefix .. string.gsub(cppfunc, '^%w', function (s)
        return string.upper(s)
    end)
end

local function parse_prop(cls, name, func_get, func_set)
    local pi = {}
    pi.PROP_NAME = assert(name)

    local name2 = string.gsub(name, '^%l+', function (s)
        return string.upper(s)
    end)

    local function test(f, name, op)
        name = to_prop_func_name(name, op)
        return name == f.CPPFUNC or name == f.LUAFUNC
    end

    if func_get then
        pi.GET = func_get and parse_func(cls, name, func_get)[1] or nil
    else
        for _, v in ipairs(cls.FUNCS) do
            for _, f in ipairs(v) do
                if test(f, name, 'get') or
                    test(f, name, 'is') or
                    test(f, name2, 'get') or
                    test(f, name2, 'is') then
                    assert(#f.ARGS == 0, f.CPPFUNC)
                    pi.GET = f
                end
            end
        end
        assert(pi.GET, name)
    end

    if func_set then
        pi.SET = func_set and parse_func(cls, name, func_set)[1] or nil
    else
        for _, v in ipairs(cls.FUNCS) do
            for _, f in ipairs(v) do
                if test(f, name, 'set') or
                    test(f, name2, 'set') then
                    assert(#f.ARGS >= 1, f.CPPFUNC)
                    pi.SET = f
                end
            end
        end
    end

    if not pi.GET.CPPFUNC_SNIPPET then
        assert(pi.GET.RET.NUM > 0, func_get)
    else
        pi.GET.CPPFUNC = 'get_' .. pi.GET.CPPFUNC
    end

    if pi.SET and pi.SET.CPPFUNC_SNIPPET then
        pi.SET.CPPFUNC = 'set_' .. pi.SET.CPPFUNC
    end

    return pi
end

function class(collection)
    local cls = {}
    cls.FUNCS = {}
    cls.CONSTS = {}
    cls.ENUMS = {}
    cls.PROPS = {}
    cls.VARS = {}
    cls.PROTOTYPES = {}
    cls.REG_LUATYPE = true

    if collection then
        collection[#collection + 1] = cls
    end

    function cls.func(name, ...)
        cls.FUNCS[#cls.FUNCS + 1] = parse_func(cls, name, ...)
    end

    function cls.funcs(funcs_str)
        local arr = {}
        local dict = {}
        for func_decl in string.gmatch(funcs_str, '[^\n\r]+') do
            func_decl = string.gsub(func_decl, '^ *', '')
            if #func_decl > 0 then
                if not string.find(func_decl, '^ *//') then
                    local _, str = parse_attr(func_decl)
                    local fn = string.match(str, '([^ ]+) *%(')
                    local t = dict[fn]
                    assert(fn, func_decl)
                    if not t then
                        t = {}
                        arr[#arr + 1] = t
                        dict[fn] = t
                    end
                    t[#t + 1] = string.gsub(func_decl, '^ *', '')
                end
            end
        end
        for _, v in ipairs(arr) do
            cls.func(nil, table.unpack(v))
        end
    end

    function cls.inject(cppfunc, codes)
        local found
        local function doinject(fi)
            if fi and fi.CPPFUNC == cppfunc then
                found = true
                assert(not fi.INJECT.BEFORE or fi.INJECT.AFTER == codes.AFTER, 'already has inject before')
                assert(not fi.INJECT.AFTER or fi.INJECT.AFTER == codes.AFTER, 'already has inject after')
                fi.INJECT.BEFORE = codes.BEFORE
                fi.INJECT.AFTER = codes.AFTER
            end
        end
        for _, arr in ipairs(cls.FUNCS) do
            for _, fi in ipairs(arr) do
                doinject(fi)
            end
        end

        for _, pi in ipairs(cls.PROPS) do
            doinject(pi.GET)
            doinject(pi.SET)
        end

        assert(found, 'func not found: ' .. cppfunc)
    end

    function cls.alias(func, aliasname)
        local funcs = {}
        for _, arr in ipairs(cls.FUNCS) do
            for _, fi in ipairs(arr) do
                if fi.LUAFUNC == func then
                    funcs[#funcs + 1] = setmetatable({LUAFUNC = assert(aliasname)}, {__index = fi})
                end
            end
            if #funcs > 0 then
                cls.FUNCS[#cls.FUNCS + 1] = funcs
                return
            end
        end

        error('func not found: ' .. func)
    end

    function cls.callback(...)
        local arr = {...}
        local opt = table.remove(arr, #arr)
        local name = arr[1]
        if string.find(name, '%(') then
            name = nil
        else
            table.remove(arr, 1)
        end
        assert(type(opt) == 'table', 'no callback opt')
        cls.FUNCS[#cls.FUNCS + 1] = parse_func(cls, name, table.unpack(arr))
        for i, v in ipairs(cls.FUNCS[#cls.FUNCS]) do
            v.CALLBACK_OPT = assert(opt)
            v.CALLBACK_OPT = setmetatable({}, {__index = assert(opt)})
            if type(v.CALLBACK_OPT.CALLBACK_MAKER) == 'table' then
                v.CALLBACK_OPT.CALLBACK_MAKER = assert(v.CALLBACK_OPT.CALLBACK_MAKER[i])
            end
            if type(v.CALLBACK_OPT.CALLBACK_MODE) == 'table' then
                v.CALLBACK_OPT.CALLBACK_MODE = assert(v.CALLBACK_OPT.CALLBACK_MODE[i])
            end
        end
    end

    function cls.callbacks(callbacks_str, callback_maker)
        local function default_maker(name)
            name = string.gsub(name, '^add', '')
            name = string.gsub(name, '^get', '')
            name = string.gsub(name, '^set', '')
            return 'olua_makecallbacktag("' .. name .. '")'
        end
        local dict = {}
        local funcs = {}
        for callback_decl in string.gmatch(callbacks_str, '[^\n\r]+') do
            if not string.find(callback_decl, '^ *//') then
                callback_decl = string.gsub(callback_decl, '^ *', '')
                local _, _, str = parse_def(callback_decl)
                local funcname = string.match(str, '[^() ]+')
                local arr = dict[funcname]
                if not arr then
                    arr = {}
                    dict[funcname] =  arr
                    funcs[#funcs + 1] = arr
                    arr.funcname = funcname
                end
                arr[#arr + 1] = callback_decl
            end
        end
        for _, v in ipairs(funcs) do
            v[#v + 1] = {
                CALLBACK_MAKER = (callback_maker or default_maker)(v.funcname),
                CALLBACK_REPLACE = true,
                CALLBACK_MODE = "OLUA_CALLBACK_TAG_ENDWITH",
            }
            cls.callback(table.unpack(v))
        end
    end

    function cls.var(name, var_decl)
        var_decl = string.gsub(var_decl, ';*$', '')
        local ARGS = parse_args(cls, '(' .. var_decl .. ')')
        local CALLBACK_OPT
        name = name or ARGS[1].VARNAME
        if ARGS[1].CALLBACK.ARGS then
            CALLBACK_OPT = {
                CALLBACK_MAKER = 'olua_makecallbacktag("' .. name .. '")',
                CALLBACK_MODE = 'OLUA_CALLBACK_TAG_ENDWITH',
                CALLBACK_REPLACE = true,
            }
        end
        cls.VARS[#cls.VARS + 1] = {
            VARNAME = assert(name),
            GET = {
                LUAFUNC = name,
                CPPFUNC = 'get_' .. ARGS[1].VARNAME,
                VARNAME = ARGS[1].VARNAME,
                INJECT = {},
                FUNC_DECL = '<function var>',
                RET = {
                    NUM = 1,
                    TYPE = ARGS[1].TYPE,
                    DECL_TYPE = ARGS[1].DECL_TYPE,
                    ATTR = {},
                },
                ISVAR = true,
                ARGS = {},
                INDEX = 0,
                CALLBACK_OPT = CALLBACK_OPT,
            },
            SET = {
                LUAFUNC = name,
                CPPFUNC = 'set_' .. ARGS[1].VARNAME,
                VARNAME = ARGS[1].VARNAME,
                INJECT = {},
                FUNC_DECL = '<function var>',
                RET = {
                    NUM = 0,
                    TYPE = get_typeinfo('void', cls),
                    ATTR = {},
                },
                ISVAR = true,
                ARGS = ARGS,
                INDEX = 0,
                CALLBACK_OPT = CALLBACK_OPT,
            },
        }
    end

    function cls.vars(vars_str)
        for line in string.gmatch(vars_str, '[^\n\r]+') do
            line = string.gsub(line, '^ *', '')
            if #line > 0 then
                local line, readonly = string.gsub(line, '@readonly', '')
                cls.var(nil, line)
                if readonly > 0 then
                    cls.VARS[#cls.VARS].SET = nil
                end
            end
        end
    end

    function cls.prop(name, func_get, func_set)
        assert(not string.find(name, '[^_%w]+'), '"' .. name .. '"')
        cls.PROPS[#cls.PROPS + 1] = parse_prop(cls, name, func_get, func_set)
    end

    function cls.props(props_str)
        for line in string.gmatch(props_str, '[^\n\r]+') do
            local name = string.match(line, '%w+')
            if name then
                cls.prop(name)
            end
        end
    end

    function cls.const(name, value)
        local tv = type(value)
        assert(not string.find(name, '[^_%w]+'), '"' .. name .. '"')
        assert(tv == "boolean" or tv == "number" or tv == "string", tv)
        cls.CONSTS[#cls.CONSTS + 1] = {
            CONST_NAME = assert(name),
            CONST_VALUE = value,
            CONST_TYPE = tv == "number" and (math.type(value)) or tv,
        }
    end

    function cls.enum(name, value, type)
        cls.ENUMS[#cls.ENUMS + 1] = {
            ENUM_NAME = name,
            ENUM_VALUE = value or (cls.CPPCLS .. '::' .. name),
            ENUM_TYPE = type,
        }
    end

    function cls.enums(enums_str)
        for line in string.gmatch(enums_str, '[^\n\r]+') do
            local name, value = string.match(line, '([^ ]+) *= *([^ ]+)')
            if not name then
                name = string.match(line, '[%w:_]+')
            elseif not string.find(value, cls.CPPCLS) then
                value = cls.CPPCLS .. '::' .. value
            end
            if name then
                cls.enum(name, value)
            end
        end
    end

    return cls
end

function include(file)
    local value = dofile(file)
    assert(type(value) == "table", file)
    return value
end

function merge(t, file)
    local ret = include(file)
    if #ret > 0 then
        for _, v in ipairs(include(file)) do
            t[#t + 1] = v
        end
    else
        t[#t + 1] = ret
    end
end

function class_path(cls)
    local classname = cls.RAWCPPCLS or cls.CPPCLS
    return string.gsub(classname, '[.:]+', '_')
end

function stringfy(value)
    if value then
        return '"' .. tostring(value) .. '"'
    else
        return nil
    end
end

function REG_TYPE(typeinfo)
    for n in string.gmatch(typeinfo.TYPENAME, '[^\n\r]+') do
        local typename = to_pretty_typename(n)
        local info = setmetatable({}, {__index = typeinfo})
        info.TYPENAME = typename
        info.DECL_TYPE = info.DECL_TYPE or typename
        typeinfo_map[typename] = info
        typeinfo_map['const ' .. typename] = info

        if info.INIT_VALUE ~= false then
            if not info.INIT_VALUE then
                if typename == 'bool' then
                    info.INIT_VALUE = 'false'
                elseif string.find(typename, '%*$') then
                    info.INIT_VALUE = 'nullptr'
                else
                    info.INIT_VALUE = '0'
                end
            end
        end

        if type(info.CONV_FUNC) == "function" then
            info.CONV_FUNC = info.CONV_FUNC(typename)
        end

        info.FUNC_PUSH_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "push")
        info.FUNC_TO_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "to")
        info.FUNC_CHECK_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "check")
        info.FUNC_OPT_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "opt")
        info.FUNC_IS_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "is")
        -- multi ret
        info.FUNC_PACK_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "pack")
        info.FUNC_UNPACK_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "unpack")

        if info.VARS and info.VARS > 1 then
            info.FUNC_ISPACK_VALUE = string.gsub(info.CONV_FUNC, '[$]+', "ispack")
        end

        if info.LUACLS then
            if type(info.LUACLS) == "function" then
                info.LUACLS = info.LUACLS(typename)
            elseif type(info.LUACLS) ~= "string" then
                error("not support: " .. type(info.LUACLS))
            end
        end
    end
end

function REG_CONV(ci)
    local func = ci.FUNC or "push|check|pack|unpack|opt|is"
    ci.PROPS = {}
    for line in string.gmatch(assert(ci.DEF, 'no DEF'), '[^\n\r]+') do
        local typename, varname, luaname = string.match(line, '([^{} ]+[ *&])([^ *&]+) *= *([^ ;]*)')
        if not typename then
            typename, varname = string.match(line, '([^{}]+[ *&])([^ *&;]+)')
        end
        if typename then
            typename = to_pretty_typename(typename)
            varname = to_pretty_typename(varname)
            luaname = to_pretty_typename(luaname or varname)
            local typeinfo, typename = get_typeinfo(typename)
            ci.PROPS[#ci.PROPS + 1] = {
                TYPE = typeinfo,
                VARNAME = varname,
                LUANAME = luaname,
            }
        end
    end

    ci.FUNC = {}
    for f in string.gmatch(func, '[^|]+') do
        ci.FUNC[string.upper(f)] = true
    end

    local ti = typeinfo_map[ci.CPPCLS] or typeinfo_map[ci.CPPCLS .. ' *']
    assert(ti, ci.CPPCLS)
    if ti.VARS and ti.VARS > 1 then
        ci.FUNC['ISPACK'] = true
    else
        ci.FUNC['UNPACK'] = nil
        ci.FUNC['PACK'] = nil
    end

    ci.FUNC.IS = true
    return ci
end

function newcppobj(cls)
    local CPPCLS = cls.CPPCLS
    local LUACLS = cls.LUACLS
    local new = format_snippet([[
        {
            ${CPPCLS} *obj = new ${CPPCLS}();
            olua_push_cppobj<${CPPCLS}>(L, obj, "${LUACLS}");
            lua_pushstring(L, ".ownership");
            lua_pushboolean(L, true);
            olua_setvariable(L, -3);
            return 1;
        }
    ]])
    return new
end

function gccppobj(cls)
    local CPPCLS = cls.CPPCLS
    local LUACLS = cls.LUACLS
    local gc = format_snippet([[
        {
            if (olua_isa(L, 1, "${LUACLS}")) {
                lua_pushstring(L, ".ownership");
                olua_getvariable(L, -2);
                if (lua_toboolean(L, -1)) {
                    ${CPPCLS} *obj = olua_touserdata(L, 1, ${CPPCLS} *);
                    if (obj) {
                        delete obj;
                        *(void **)lua_touserdata(L, 1) = nullptr;
                    }
                }
            }
            return 0;
        }
    ]])
    return gc
end
