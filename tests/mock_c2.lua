--- API `c2` simulée, juste assez complète pour exercer la logique du plugin.
---
--- Elle ne rejoue pas Chatterino : elle reproduit le CONTRAT observé dans les
--- liaisons Lua (`src/controllers/plugins/api/Message.cpp`) — éléments en lecture
--- seule sauf `add_flags`, `Message.new` acceptant un mélange de tables
--- d'initialisation et d'éléments existants, clonage à l'insertion.
---
--- Les valeurs des énumérations n'ont pas à correspondre à celles de Chatterino ;
--- seul compte qu'elles soient des entiers à bits distincts, comme en vrai.

local mock = {}

local function bit(n)
    return 1 << n
end

local c2 = {}

-- Uniquement les drapeaux à BIT SIMPLE : les liaisons de Chatterino
-- n'exportent pas les drapeaux combinés (Emote, Badges, EmojiAll, Default),
-- même si le fichier de types les liste. Les omettre ici garantit qu'un test
-- échoue si le plugin se remet à en dépendre.
c2.MessageElementFlag = {
    None = 0,
    Misc = bit(0),
    Text = bit(1),
    Username = bit(2),
    Timestamp = bit(3),
    EmoteImage = bit(4),
    EmoteText = bit(5),
    BadgeGlobalAuthority = bit(6),
    BadgeSubscription = bit(7),
    ChannelName = bit(8),
    ModeratorTools = bit(9),
    EmojiImage = bit(10),
    EmojiText = bit(11),
    RepliedMessage = bit(12),
    ReplyButton = bit(13),
    AlwaysShow = bit(14),
}

c2.MessageFlag = {
    None = 0,
    System = bit(0),
    Highlighted = bit(1),
    Subscription = bit(2),
    ReplyMessage = bit(3),
    WatchStreak = bit(4),
    Announcement = bit(5),
    Disabled = bit(6),
}

c2.FontStyle = {
    Tiny = 1,
    ChatSmall = 2,
    ChatMediumSmall = 3,
    ChatMedium = 4,
    ChatMediumBold = 5,
    ChatLarge = 6,
}

c2.LogLevel = {
    Debug = "debug",
    Info = "info",
    Warning = "warning",
    Critical = "critical",
}

c2.logs = {}
function c2.log(level, ...)
    c2.logs[#c2.logs + 1] = { level = level, args = { ... } }
end

c2.timers = {}
function c2.later(cb, msec)
    c2.timers[#c2.timers + 1] = { cb = cb, msec = msec }
end

-- ---------------------------------------------------------------------------
-- Éléments
-- ---------------------------------------------------------------------------

local Element = {}
Element.__index = Element

--- @param spec table { type, words?, flags?, color?, style?, text? }
function mock.element(spec)
    local el = setmetatable({}, Element)
    el.type = spec.type
    el.flags = spec.flags or 0
    el.color = spec.color
    el.style = spec.style
    el.tooltip = spec.tooltip
    -- Une table d'initialisation porte `text` (une chaîne) ; un élément vivant
    -- porte `words` (une liste). Chatterino fait cette conversion au moment de
    -- construire l'élément, on la reproduit.
    if spec.words then
        el.words = spec.words
    elseif spec.text then
        el.words = {}
        for w in tostring(spec.text):gmatch("%S+") do
            el.words[#el.words + 1] = w
        end
    end
    el.__cloned_from = spec.__cloned_from
    return el
end

function Element:add_flags(flag)
    self.flags = self.flags | flag
end

function Element:clone()
    local copy = mock.element({
        type = self.type,
        flags = self.flags,
        color = self.color,
        style = self.style,
        tooltip = self.tooltip,
        words = self.words and { table.unpack(self.words) } or nil,
    })
    copy.__cloned_from = self
    return copy
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

local Message = {}
Message.__index = Message

function Message:elements()
    return self._elements
end

function Message:append_element(elem)
    if getmetatable(elem) == Element then
        -- Contrat réel : un élément existant est CLONÉ à l'insertion.
        self._elements[#self._elements + 1] = elem:clone()
    else
        self._elements[#self._elements + 1] = mock.element(elem)
    end
end

function Message:clone()
    local copy = c2.Message.new({})
    for k, v in pairs(self) do
        if k ~= "_elements" then
            copy[k] = v
        end
    end
    copy.frozen = false
    copy._elements = {}
    for _, el in ipairs(self._elements) do
        copy._elements[#copy._elements + 1] = el:clone()
    end
    return copy
end

c2.Message = {}

function c2.Message.new(init)
    local msg = setmetatable({}, Message)
    for k, v in pairs(init or {}) do
        if k ~= "elements" then
            msg[k] = v
        end
    end
    msg.frozen = false
    msg._elements = {}
    for _, el in ipairs((init or {}).elements or {}) do
        msg:append_element(el)
    end
    return msg
end

--- Fabrique un message « déjà affiché » (donc gelé), comme en reçoit un plugin.
function mock.message(spec)
    local msg = c2.Message.new(spec)
    msg.frozen = true
    return msg
end

-- ---------------------------------------------------------------------------
-- Canaux
-- ---------------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel:get_name()
    return self._name
end

function Channel:message_snapshot(n)
    local out = {}
    local from = math.max(1, #self._messages - n + 1)
    for i = from, #self._messages do
        out[#out + 1] = self._messages[i]
    end
    return out
end

function Channel:replace_message(old, replacement)
    for i, m in ipairs(self._messages) do
        if m == old then
            self._messages[i] = replacement
            self.replacements[#self.replacements + 1] = { index = i, old = old, new = replacement }
            return
        end
    end
    error("message introuvable")
end

function Channel:on_message_appended(cb)
    self._callbacks[#self._callbacks + 1] = cb
    return { is_connected = function() return true end }
end

function mock.channel(name)
    return setmetatable({
        _name = name or "#test",
        _messages = {},
        _callbacks = {},
        replacements = {},
    }, Channel)
end

function mock.push(channel, msg)
    channel._messages[#channel._messages + 1] = msg
    return msg
end

mock.c2 = c2
mock.Element = Element
mock.Message = Message

return mock
