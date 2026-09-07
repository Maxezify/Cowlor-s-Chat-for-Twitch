--- Cowlor's Chat for Twitch — plugin Chatterino
---
--- Objectif de la v0.1 : réparer les citations de réponse.
---
--- Chatterino affiche la citation d'une réponse dans un `SingleLineTextElement`
--- construit à partir de `threadRoot->messageText` — c'est-à-dire du texte brut,
--- coupé à une seule ligne avec « … ». C'est exactement le défaut que
--- BetterTwitchChat corrige sur le chat web de Twitch.
---
--- Deux faits rendent la réparation possible depuis un plugin :
---
---   1. La troncature a lieu à la MISE EN PAGE, pas au stockage. L'élément garde
---      la liste de mots complète, et la liaison Lua l'expose (`element.words`).
---   2. `Message:append_element()` clone l'élément qu'on lui passe. On ne peut pas
---      *fabriquer* une emote en Lua, mais on peut en recopier une depuis un autre
---      message.
---
--- La stratégie est donc : retrouver le message parent parmi les messages récents
--- du canal, et reconstruire la citation à partir de SES éléments — texte réémis
--- à la bonne taille, emotes clonées telles quelles. Si le parent n'est plus dans
--- l'historique, on se rabat sur les mots de la citation elle-même : on perd les
--- emotes, mais on garde le texte entier.
---
--- Un seul fichier, volontairement : les chercheurs de modules de Chatterino sont
--- personnalisés et non documentés, et `package.path` est vidé. Un `require` sur
--- nos propres fichiers serait un pari.

-- =============================================================================
-- Réglages
-- =============================================================================

local CONFIG = {
    reply = {
        -- Reconstruire la citation des réponses. Le cœur du plugin.
        enabled = true,

        -- Réémettre les emotes du message parent dans la citation. Sans cela, on
        -- corrige la troncature mais la citation reste du texte brut.
        renderEmotes = true,

        -- Couleur du texte cité. `nil` garde celle que Chatterino a choisie.
        -- Valeur reprise de BetterTwitchChat (`reply.color`).
        color = "#8f8f9a",

        -- Style de police de la citation. Chatterino n'expose pas d'échelle
        -- libre : on choisit dans une énumération. `ChatMediumSmall` est ce que
        -- Chatterino utilise déjà pour la citation, `ChatSmall` est un cran en
        -- dessous. Équivalent approché de `reply.fontScale` (0.825).
        fontStyle = "ChatMediumSmall",

        -- Nombre de messages récents à fouiller pour retrouver le parent.
        -- Trop bas : on rate des parents et on perd les emotes. Trop haut : on
        -- paie une recherche linéaire sur chaque réponse.
        lookbackMessages = 200,

        -- Teinte de fond du message qui répond (équivalent de `reply.lineTint`).
        -- Désactivé par défaut : Chatterino s'en sert pour ses propres highlights
        -- et l'écraser ferait disparaître un signal utile.
        lineTint = nil,
    },

    -- Intervalle de balayage pour découvrir les canaux ouverts, en millisecondes.
    -- Chatterino n'expose aucun événement « un canal vient de s'ouvrir » : la
    -- seule voie est de parcourir périodiquement l'arbre des fenêtres.
    channelSweepMs = 3000,

    -- Journalise les décisions dans la console de Chatterino.
    debug = false,
}

-- =============================================================================
-- Utilitaires
-- =============================================================================

local M = {}

local function log(level, ...)
    if c2 and c2.log then
        c2.log(level, "[cowlors-chat]", ...)
    end
end

local function debug(...)
    if CONFIG.debug then
        log(c2.LogLevel.Debug, ...)
    end
end

--- Teste la présence d'un drapeau dans un jeu de drapeaux.
--- Les énumérations de Chatterino arrivent en Lua sous forme d'entiers, mais on
--- reste défensif : un jour où elles deviendraient des userdata, ce test doit
--- renvoyer false plutôt que lever une erreur.
---@param value any
---@param flag any
---@return boolean
local function has_flag(value, flag)
    if type(value) ~= "number" or type(flag) ~= "number" then
        return false
    end
    return (value & flag) ~= 0
end
M.has_flag = has_flag

--- Normalise un texte pour comparaison : espaces réduits, extrémités coupées.
---@param s string?
---@return string
local function normalize(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end
M.normalize = normalize

--- Retire le « @ » de tête et le « : » de queue d'un pseudo cité.
---@param s string?
---@return string
local function strip_mention(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^@", ""):gsub(":$", ""))
end
M.strip_mention = strip_mention

-- =============================================================================
-- Drapeaux d'élément
-- =============================================================================

-- Résolus une seule fois, au démarrage, quand `c2` est disponible.
local FLAGS = nil

local function resolve_flags()
    local EF = c2.MessageElementFlag
    FLAGS = {
        -- Ce qui constitue le corps d'un message : son texte et ses emotes.
        -- Chatterino émet DEUX éléments par emote (image et texte) et n'en met
        -- qu'un en page selon les réglages ; on recopie les deux pour que le
        -- réglage de l'utilisateur continue de décider.
        body = EF.Text | EF.EmoteImage | EF.EmoteText | EF.EmojiImage | EF.EmojiText,

        -- Ce qui n'en fait pas partie et ne doit pas être recopié dans la citation.
        notBody = EF.Username | EF.Timestamp | EF.Badges | EF.ModeratorTools
            | EF.RepliedMessage | EF.ChannelName | EF.ReplyButton,

        replied = EF.RepliedMessage,
        text = EF.Text,
    }
end

-- =============================================================================
-- Lecture de la citation
-- =============================================================================

--- Localise la citation dans la liste d'éléments d'un message.
---
--- On identifie le corps de la citation par son TYPE plutôt que par ses drapeaux :
--- `SingleLineTextElement` n'est utilisé nulle part ailleurs dans Chatterino que
--- pour les citations de réponse (deux emplois, tous deux dans le constructeur de
--- réponse). C'est donc un marqueur fiable, et il ne dépend pas de la
--- représentation des énumérations.
---
---@param elements table liste d'éléments (ordre du message)
---@return table? info { body_index, name_index, name, words }
function M.find_reply_context(elements)
    if type(elements) ~= "table" then
        return nil
    end

    for i, el in ipairs(elements) do
        if el.type == "single-line-text" then
            local info = {
                body_index = i,
                words = el.words or {},
            }

            -- Le pseudo cité est l'élément textuel le plus proche AVANT le corps
            -- dont le premier mot commence par « @ ». Chatterino l'émet juste
            -- avant, mais on remonte pour tolérer un élément intercalé.
            for j = i - 1, 1, -1 do
                local prev = elements[j]
                local w = prev.words and prev.words[1]
                if type(w) == "string" and w:sub(1, 1) == "@" then
                    info.name_index = j
                    info.name = strip_mention(w)
                    break
                end
            end

            return info
        end
    end

    return nil
end

-- =============================================================================
-- Recherche du message parent
-- =============================================================================

--- Retrouve le message cité parmi les messages récents du canal.
---
--- Chatterino n'expose pas `reply-parent-msg-id` à Lua : on ne peut pas demander
--- le parent par son identifiant. On le reconnaît donc par son auteur et son
--- texte — la même heuristique que BetterTwitchChat emploie dans le DOM.
---
--- Le texte cité est comparé au `message_text` du candidat après normalisation
--- des espaces : la citation est reconstruite mot à mot par Chatterino, donc les
--- espaces multiples de l'original y sont déjà réduits.
---
---@param snapshot table liste de messages, du plus ancien au plus récent
---@param name string pseudo cité, sans « @ » ni « : »
---@param words table mots de la citation
---@return table? parent
function M.match_parent(snapshot, name, words)
    if type(snapshot) ~= "table" or type(words) ~= "table" then
        return nil
    end

    local wanted = normalize(table.concat(words, " "))
    if wanted == "" then
        return nil
    end

    local wanted_name = name and name:lower() or nil

    -- Du plus récent au plus ancien : si quelqu'un a répété le même message,
    -- c'est presque toujours au plus proche qu'on répond.
    for i = #snapshot, 1, -1 do
        local m = snapshot[i]
        if m and normalize(m.message_text) == wanted then
            if not wanted_name then
                return m
            end
            local display = (m.display_name or ""):lower()
            local login = (m.login_name or ""):lower()
            if display == wanted_name or login == wanted_name then
                return m
            end
        end
    end

    return nil
end

-- =============================================================================
-- Construction de la citation
-- =============================================================================

--- Extrait du message parent les éléments qui constituent son corps.
---
--- On écarte l'horodatage, les badges, le pseudo, les boutons de modération et
--- toute citation que le parent porterait lui-même — sinon une réponse à une
--- réponse embarquerait la citation de la citation.
---
---@param parent_elements table
---@return table parts liste de { kind = "text"|"element", ... }
function M.extract_body(parent_elements)
    local parts = {}
    if type(parent_elements) ~= "table" then
        return parts
    end

    for _, el in ipairs(parent_elements) do
        local flags = el.flags
        local is_body = has_flag(flags, FLAGS.body)
        local is_chrome = has_flag(flags, FLAGS.notBody)

        if is_body and not is_chrome then
            if el.type == "text" or el.type == "link" then
                -- Le texte est RÉÉMIS, pas cloné : un clone garderait la taille
                -- du message d'origine (ChatMedium) et la citation ressortirait
                -- à la taille d'un message normal. Un élément neuf nous laisse
                -- imposer la police et la couleur.
                --
                -- Un lien cité perd donc son caractère cliquable. C'est assumé :
                -- le cloner le rendrait cliquable mais à la mauvaise taille, et
                -- une citation est là pour situer, pas pour être suivie.
                parts[#parts + 1] = { kind = "text", words = el.words or {} }
            else
                -- Emotes, emoji : aucune table d'initialisation n'existe côté
                -- Lua, on ne peut que les recopier. Leur taille n'est donc pas
                -- réglable — c'est la limite connue de cette approche.
                parts[#parts + 1] = { kind = "element", element = el }
            end
        end
    end

    return parts
end

--- Fusionne les morceaux de texte consécutifs.
--- Chatterino émet un élément par mot dans certains cas ; les recoller limite le
--- nombre d'éléments créés et donc le coût de mise en page.
---@param parts table
---@return table
function M.merge_text_parts(parts)
    local merged = {}

    for _, part in ipairs(parts) do
        local last = merged[#merged]
        if part.kind == "text" and last and last.kind == "text" then
            for _, w in ipairs(part.words) do
                last.words[#last.words + 1] = w
            end
        elseif part.kind == "text" then
            local copy = {}
            for _, w in ipairs(part.words) do
                copy[#copy + 1] = w
            end
            merged[#merged + 1] = { kind = "text", words = copy }
        else
            merged[#merged + 1] = part
        end
    end

    return merged
end

--- Transforme les morceaux en éléments prêts pour `c2.Message.new`.
--- Les morceaux de texte deviennent des tables d'initialisation (donc des
--- éléments neufs, à notre police) ; les autres sont passés tels quels et seront
--- clonés à l'insertion.
---@param parts table
---@return table elements
local function parts_to_elements(parts)
    local out = {}

    for _, part in ipairs(parts) do
        if part.kind == "text" then
            local text = table.concat(part.words, " ")
            if text ~= "" then
                out[#out + 1] = {
                    type = "text",
                    text = text,
                    flags = FLAGS.replied | FLAGS.text,
                    color = CONFIG.reply.color or "system",
                    style = c2.FontStyle[CONFIG.reply.fontStyle],
                }
            end
        else
            out[#out + 1] = part.element
        end
    end

    return out
end

--- Construit la liste d'éléments du message reconstruit.
---@param original table éléments du message d'origine
---@param ctx table résultat de find_reply_context
---@param quote table éléments de remplacement de la citation
---@return table
function M.splice_elements(original, ctx, quote)
    local out = {}

    for i, el in ipairs(original) do
        if i == ctx.body_index then
            for _, q in ipairs(quote) do
                out[#out + 1] = q
            end
        else
            out[#out + 1] = el
        end
    end

    return out
end

-- =============================================================================
-- Reconstruction du message
-- =============================================================================

--- Recopie les champs scalaires d'un message vers une table d'initialisation.
--- Tout oubli ici se voit à l'écran : un pseudo qui perd sa couleur, un message
--- qui sort de la recherche, un horodatage qui saute.
---@param msg table
---@return table
local function carry_over(msg)
    local init = {
        flags = msg.flags,
        id = msg.id,
        parse_time = msg.parse_time,
        search_text = msg.search_text,
        message_text = msg.message_text,
        login_name = msg.login_name,
        display_name = msg.display_name,
        localized_name = msg.localized_name,
        user_id = msg.user_id,
        channel_name = msg.channel_name,
        username_color = msg.username_color,
        server_received_time = msg.server_received_time,
    }

    -- `highlight_color` vaut "" quand il n'y en a pas ; passer la chaîne vide
    -- poserait une couleur nulle au lieu de n'en poser aucune.
    local hl = msg.highlight_color
    if type(hl) == "string" and hl ~= "" then
        init.highlight_color = hl
    elseif CONFIG.reply.lineTint then
        init.highlight_color = CONFIG.reply.lineTint
    end

    return init
end

--- Reconstruit un message de réponse avec sa citation complète.
---@param channel table
---@param msg table
---@return table? replacement
local function rebuild_reply(channel, msg)
    local elements = msg:elements()
    local ctx = M.find_reply_context(elements)
    if not ctx then
        return nil
    end

    local quote

    local parent = nil
    if CONFIG.reply.renderEmotes and ctx.name then
        local ok, snapshot = pcall(function()
            return channel:message_snapshot(CONFIG.reply.lookbackMessages)
        end)
        if ok and snapshot then
            parent = M.match_parent(snapshot, ctx.name, ctx.words)
        end
    end

    if parent then
        local parts = M.merge_text_parts(M.extract_body(parent:elements()))
        quote = parts_to_elements(parts)
        debug("citation reconstruite depuis le parent :", ctx.name, #quote, "éléments")
    end

    -- Parent introuvable, ou corps vide : on réémet au moins le texte complet.
    -- La troncature disparaît, les emotes restent absentes.
    if not quote or #quote == 0 then
        local text = table.concat(ctx.words, " ")
        if text == "" then
            return nil
        end
        quote = {
            {
                type = "text",
                text = text,
                flags = FLAGS.replied | FLAGS.text,
                color = CONFIG.reply.color or "system",
                style = c2.FontStyle[CONFIG.reply.fontStyle],
            },
        }
        debug("parent introuvable, citation réémise en texte :", ctx.name)
    end

    local init = carry_over(msg)
    init.elements = M.splice_elements(elements, ctx, quote)

    local replacement = c2.Message.new(init)

    -- Les éléments clonés (emotes) n'ont pas encore le drapeau qui les range dans
    -- la citation. On le pose après coup : `add_flags` fonctionne sur n'importe
    -- quel élément, y compris ceux qu'on vient de faire cloner.
    local built = replacement:elements()
    local from, to = ctx.body_index, ctx.body_index + #quote - 1
    for i = from, to do
        local el = built[i]
        if el and not has_flag(el.flags, FLAGS.replied) then
            el:add_flags(FLAGS.replied)
        end
    end

    return replacement
end

M.rebuild_reply = rebuild_reply

-- =============================================================================
-- Branchement sur les canaux
-- =============================================================================

local hooked = {}      -- nom de canal -> ConnectionHandle
local reentrant = false

local function on_message(channel, msg)
    if reentrant or not CONFIG.reply.enabled then
        return
    end

    -- Un message déjà affiché est gelé : on ne peut pas le modifier sur place, il
    -- faut construire un remplaçant. On teste tout de même, parce que rien ne
    -- garantit que ce soit vrai à tous les points d'appel.
    local ok, replacement = pcall(rebuild_reply, channel, msg)
    if not ok then
        log(c2.LogLevel.Warning, "reconstruction échouée :", replacement)
        return
    end
    if not replacement then
        return
    end

    reentrant = true
    local replaced, err = pcall(function()
        channel:replace_message(msg, replacement)
    end)
    reentrant = false

    if not replaced then
        log(c2.LogLevel.Warning, "remplacement échoué :", err)
    end
end

local function hook_channel(channel)
    if not channel then
        return
    end

    local ok, name = pcall(function()
        return channel:get_name()
    end)
    if not ok or not name or name == "" or hooked[name] then
        return
    end

    local connected, handle = pcall(function()
        return channel:on_message_appended(function(msg)
            on_message(channel, msg)
        end)
    end)

    if connected then
        hooked[name] = handle
        debug("canal branché :", name)
    end
end

--- Parcourt l'arbre des fenêtres pour découvrir les canaux ouverts.
--- Chatterino n'émet aucun événement à l'ouverture d'un split : ce balayage
--- périodique est la seule voie. Il inclut la fenêtre superposée au navigateur,
--- qui est un `WindowType.Attached` comme les autres.
local function sweep_channels()
    local ok, err = pcall(function()
        for _, window in ipairs(c2.windows:all()) do
            local notebook = window.notebook
            if notebook then
                for i = 0, (notebook.page_count or 0) - 1 do
                    local page = notebook:page_at(i)
                    if page then
                        for _, split in ipairs(page:splits()) do
                            hook_channel(split.channel)
                        end
                    end
                end
            end
        end
    end)

    if not ok then
        debug("balayage interrompu :", err)
    end

    -- Purge des canaux fermés, sinon la table grossit indéfiniment sur une
    -- session longue où l'on change souvent de chaîne.
    for name, handle in pairs(hooked) do
        local valid = true
        local checked = pcall(function()
            valid = handle:is_connected()
        end)
        if checked and not valid then
            hooked[name] = nil
        end
    end

    c2.later(sweep_channels, CONFIG.channelSweepMs)
end

-- =============================================================================
-- Démarrage
-- =============================================================================

M.CONFIG = CONFIG

-- Sous le harnais de test, `c2` est une API simulée et on ne démarre pas les
-- minuteries : les tests appellent les fonctions pures directement.
if c2 then
    resolve_flags()
    M.FLAGS = FLAGS

    if not rawget(_G, "COWLORS_CHAT_TEST") then
        log(c2.LogLevel.Info, "v0.1.0 — citations de réponse")
        sweep_channels()
    end
end

return M
