local class         = require "xgame.class"
local util          = require "xgame.util"
local Dispatcher    = require "xgame.event.Dispatcher"
local AudioEvent    = require "xgame.swf.AudioEvent"
local T             = require "swf.type"

local assert = assert
local ipairs, pairs = ipairs, pairs
local next = next
local trace = util.trace("[AudioScanner]")

local AudioScanner = class("AudioScanner", Dispatcher)

function AudioScanner:ctor()
    self._tag = 0
    self:clear()
end

function AudioScanner:_createAutoTable()
    return setmetatable({}, {__mode = "k", __index = function (t, k)
        local v = {}
        rawset(t, k, v)
        return v
    end})
end

function AudioScanner:_clearAudios(force)
    local playingAudios = self._playingAudios
    if playingAudios then
        for mc, label2tag in pairs(playingAudios) do
            if force or not mc.stage or not mc.cobj.alive then
                playingAudios[mc] = nil
                for _, tag in pairs(label2tag) do
                    self:dispatch(AudioEvent.STOP_AUDIO, nil, tag)
                end
            end
        end
    end
end

function AudioScanner:clear()
    self:_clearAudios(true)
    self._watchedTargets = setmetatable({}, {__mode = "k"})
    self._playingAudios = self:_createAutoTable()
    self._playingStates = self:_createAutoTable()
end

function AudioScanner:_obtainTag()
    self._tag = self._tag + 1
    return self._tag
end

function AudioScanner:addWatch(target)
    assert(target)
    self._watchedTargets[target] = true
end

local function doScan(self, target, found)
    if target.cobj.type == T.MOVIECLIP then
        if not self._watchedTargets[target] and target.metadata.hasAudio then
            self:addWatch(target)
            found[#found + 1] = target
            trace("find audio instance: '%s'", target.name)
        end
    end

    if target.children then
        for _, child in ipairs(target.children) do
            if child.cobj.type == T.MOVIECLIP then
                doScan(self, child, found)
            end
        end
    end

    return found
end

function AudioScanner:scan(target)
    return doScan(self, target, {})
end

function AudioScanner:update()
    local playingAudios = self._playingAudios
    local playingStates = self._playingStates
    local watchedTargets = self._watchedTargets

    for target, _ in pairs(watchedTargets) do
        if not target.stage or not target.cobj.alive then
            watchedTargets[target] = nil
            trace("remove watch: name=%s[%s] label=%s", target.name, target,
                target.currentLabel)
            goto loopNextTarget
        end

        for _, mc in ipairs(target.children) do
            if mc.cobj.type ~= T.MOVIECLIP or not next(mc.metadata.audios) then
                goto loopNextChild
            end

            local state = playingStates[mc]
            if state.lastFrame and state.lastFrame > mc.currentFrame then
                state.lastFrameLabel = nil
            end

            local currentLabel = mc.currentLabel
            if currentLabel ~= state.lastFrameLabel then
                state.lastFrameLabel = currentLabel

                local audios = mc.metadata.audios
                local frameLabels = mc.frameLabels
                local frame = frameLabels[currentLabel]

                for label, labelFrame in pairs(frameLabels) do
                    local option = audios[label]
                    if frame ~= labelFrame or not option then
                        goto loopNextLabel
                    end

                    local label2tag = playingAudios[mc]
                    local tag = label2tag[label]

                    if tag then
                        self:dispatch(AudioEvent.STOP_AUDIO, nil, tag)
                    end

                    tag = self:_obtainTag()
                    label2tag[label] = tag
                    self:dispatch(AudioEvent.PLAY_AUDIO, option, tag)

                    ::loopNextLabel::
                end
            end

            state.lastFrame = mc.currentFrame

            ::loopNextChild::
        end

        ::loopNextTarget::
    end

    self:_clearAudios()
end

return AudioScanner
