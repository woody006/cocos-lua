local class         = require "xgame.class"
local Event         = require "xgame.event.Event"
local TouchEvent    = require "xgame.event.TouchEvent"
local UIView        = require "xgame.ui.UIView"
local MovieClip     = require "xgame.swf.MovieClip"
local swf           = require "xgame.swf.swf"
local window        = require "xgame.window"
local EditBox       = require "ccui.EditBox"
local InputFlag     = require "ccui.EditBox.InputFlag"
local InputMode     = require "ccui.EditBox.InputMode"

local CocosInput

local TextInput = swf.class("TextInput", MovieClip)

function TextInput:ctor()
    self._restrict = false
    self._cocosobj = false
    self.label = self.ns['label']
    self.mode = 'NONE'
    self.touchable = true
    self.touchChildren = false
    
    self:addListener(Event.REMOVED, self._onRemoved, self)
    self:addListener(Event.FOCUS_OUT, self._focusOut, self)
    self:addListener(TouchEvent.CLICK, self._focusIn, self)
end

function TextInput:_onRemoved()
    if self._cocosobj then
        self._cocosobj.cobj:unregisterScriptEditBoxHandler()
        self._cocosobj:remove_self()
        self._cocosobj = false
    end
end

function TextInput.Get:mode()
    return self._mode
end

function TextInput.Set:mode(value)
    self._mode = value
    if value == 'PASSWORD' then
        self.label.displayAsPassword = true
        self._inputMode = InputMode.EMAIL_ADDRESS
        self._inputFlag = InputFlag.PASSWORD
    elseif value == 'ACCOUNT' then
        self.label.displayAsPassword = false
        self._inputMode = InputMode.EMAIL_ADDRESS
        self._inputFlag = InputFlag.LOWERCASE_ALL_CHARACTERS
    else
        self.label.displayAsPassword = false
        self._inputMode = InputMode.ANY
        self._inputFlag = InputFlag.LOWERCASE_ALL_CHARACTERS
    end
end

function TextInput:_createCocosobj()
    local cocosobj = self._cocosobj
    if not cocosobj then
        cocosobj = CocosInput.new()
        cocosobj.width = self.label.width
        cocosobj.height = self.label.height
        cocosobj:setFontSize(self.label.fontSize)
        cocosobj:addListener(Event.COMPLETE, function ()
            if self.stage and self.stage.focus == self then
                self.stage.focus = false
            else
                self:_focusOut()
            end
            self:dispatch(Event.COMPLETE)
        end)
        cocosobj:addListener(Event.CHANGE, function ()
            self.label.text = self._cocosobj.text
            self:dispatch(Event.CHANGE)
        end)
        self.rootNode.cobj:addChild(cocosobj.cobj, 0xFF)
        self._cocosobj = cocosobj
    end
end

function TextInput:_focusOut()
    if self._cocosobj then
        self._cocosobj.visible = false
        self._cocosobj:closeKeyboard()
        self.label.text = self._cocosobj.text
    end
    self.label.visible = true
end

function TextInput:_focusIn()
    if (self._cocosobj and self._cocosobj.open) then
        return
    end

    self.label.visible = false

    self:_createCocosobj()

    local cocosobj = self._cocosobj
    local x, y = self.label:localToGlobal(0, self.label.fontSize +
        (self.label.height - self.label.fontSize) / 2)
    x, y = self.rootNode:globalToLocal(x, y)
    cocosobj.x = x
    cocosobj.y = y
    cocosobj.restrict = self.restrict
    cocosobj.text = self.label.plain_text
    cocosobj.color = self.label.color
    cocosobj.placeholder = self.placeholder
    cocosobj:setInputMode(self._inputMode)
    cocosobj:setInputFlag(self._inputFlag)
    cocosobj:openKeyboard()
end

function TextInput.Get:restrict() return self._restrict end
function TextInput.Set:restrict(value)
    self._restrict = value
end

function TextInput.Get:text()
    if self._cocosobj and self._cocosobj.visible then
        self.label.text = self._cocosobj.text
    end

    return self.label.plainText or ""
end
function TextInput.Set:text(value)
    value = value or ""
    if self._cocosobj then
        self._cocosobj.text = value
    end
    self.label.text = value
end

function TextInput.Get:placeholder()
    return self._placeholder
end
function TextInput.Set:placeholder(value)
    value = value or ""
    if self._cocosobj then
        self._cocosobj.placeholder = value
    end
    self._placeholder = value
end

function TextInput.Get:multiline()
    return self.label.multiline
end

function TextInput.Set:multiline(value)
    self.label.multiline = value
    if self._cocosobj then
        if not value then
            self._cocosobj:setInputMode(6)
        end
    end
end

--
-- CocosInput
--
local LuaEditBoxDelegate = require "ccui.LuaEditBoxDelegate"
local Scale9Sprite = require "ccui.Scale9Sprite"

CocosInput = class("CocosInput", UIView)

function CocosInput:ctor()
    self.open = false
    self.touchable = false
    self.restrict = false
end

function CocosInput.Get:cobj()
    local cobj = EditBox.create({width = 10, height = 10},
        Scale9Sprite.create(), nil, nil)
    cobj.touchEnabled = false
    cobj.inputFlag = InputFlag.SENSITIVE
    rawset(self, "cobj", cobj)

    local delegate = LuaEditBoxDelegate.create()

    delegate.onReturn = function ()
        self.open = false
        self:dispatch(Event.COMPLETE)
    end

    delegate.onTextChanged = function (_, text)
        if self.restrict then
            local restrict = "[^" .. self.restrict .. "]"
            self.text = string.gsub(self.text, restrict, "")
        end
        self:dispatch(Event.CHANGE)

        -- when use keyborad, if set text, label will be visible again
        for _, child in ipairs(self.cobj:getChildren()) do
            child.visible = false
        end
    end

    cobj.delegate = delegate

    return cobj
end

function CocosInput:openKeyboard()
    self.cobj:openKeyboard()
    self.open = true
end

function CocosInput:closeKeyboard()
    if self.open then
        self.cobj:closeKeyboard()
        self.open = false
    end
end

function CocosInput:setFontName(value)
    self.cobj.fontName = value
end

function CocosInput:setFontSize(value)
    self.cobj.fontSize = value
    self.cobj.placeholderFontSize = value
end

function CocosInput:setInputMode(value)
    self.cobj.inputMode = value
end

function CocosInput:setInputFlag(value)
    self.cobj.inputFlag = value
end

function CocosInput.Set:width(value)
    self._width = value
    if value ~= 0 then
        self.cobj.width = value
    end
end
function CocosInput.Get:width()
    return self._width
end

function CocosInput.Set:height(value)
    self._height = value
    if value ~= 0 then
        self.cobj.height = value
    end
end
function CocosInput.Get:height()
    return self._height
end

function CocosInput.Get:color()
    return self.cobj.fontColor
end
function CocosInput.Set:color(value)
    self.cobj.fontColor = value
end

function CocosInput.Get:placeholder()
	return self.cobj.placeHolder
end
function CocosInput.Set:placeholder(value)
    self.cobj.placeholder = value
end

function CocosInput.Get:text()
	return self.cobj.text
end
function CocosInput.Set:text(value)
    self.cobj.text = value or ""
end

return TextInput
