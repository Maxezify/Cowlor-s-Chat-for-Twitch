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

    -- Chaînes à brancher par leur nom, en minuscules et sans « # ».
    --
    -- C'EST LE RÉGLAGE IMPORTANT si tu utilises la superposition au navigateur.
    -- Le balayage automatique parcourt `c2.windows:all()`, qui ne renvoie que des
    -- `Window` ; or l'extension rattache le canal à un `AttachedWindow`, qui est
    -- un `QWidget` absent de cette liste. La chaîne que tu regardes est donc
    -- invisible au balayage.
    --
    -- Elle est en revanche bien joignable par son nom : le gestionnaire `select`
    -- de Chatterino appelle `getOrAddChannel(name)`, ce qui l'inscrit dans la
    -- table des canaux que `by_name` interroge. Les nommer ici suffit.
    --
    -- Le branchement se fait dès que la chaîne est ouverte, et le balayage
    -- réessaie, donc l'ordre et le moment n'importent pas.
    --
    --   channels = { "zerator", "domingo", "ponce" },
    channels = {},

    -- Intervalle de balayage pour découvrir les canaux ouverts, en millisecondes.
    -- Chatterino n'expose aucun événement « un canal vient de s'ouvrir » : la
    -- seule voie est de réessayer périodiquement.
    channelSweepMs = 3000,

    -- Journalise les décisions dans la console de Chatterino.
    debug = false,
}

-- =============================================================================
-- Utilitaires
-- =============================================================================

local M = {}

local VERSION = "0.6.0"
M.VERSION = VERSION

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

--- Assemble un masque à partir de NOMS de drapeaux, en ignorant ceux que la
--- version installée n'expose pas.
---
--- Le fichier de types `globals.lua` liste des drapeaux que l'exécution n'a pas.
--- `Badges`, `Emote`, `EmojiAll` et `Default` y figurent, mais ce sont des
--- drapeaux COMBINÉS — des OU d'autres drapeaux — et les liaisons n'exportent
--- que les bits simples. Les nommer faisait échouer le chargement du plugin.
--- On ne se fie donc plus au fichier de types : on demande, et on constate.
---@param names string[]
---@return integer mask
---@return string[] missing
local function build_mask(names)
    local EF = c2.MessageElementFlag or {}
    local value = 0
    local missing = {}

    for _, name in ipairs(names) do
        local flag = EF[name]
        if type(flag) == "number" then
            value = value | flag
        else
            missing[#missing + 1] = name
        end
    end

    return value, missing
end
M.build_mask = build_mask

--- Prépare les masques. Renvoie false si l'indispensable manque, auquel cas le
--- plugin se met en veille au lieu de faire échouer son chargement.
---@return boolean ok
local function resolve_flags()
    local missing = {}
    local function collect(names)
        local value, absent = build_mask(names)
        for _, name in ipairs(absent) do
            missing[#missing + 1] = name
        end
        return value
    end

    -- Ce qui constitue le corps d'un message : son texte et ses emotes.
    -- Chatterino émet DEUX éléments par emote (image et texte) et n'en met qu'un
    -- en page selon les réglages ; on recopie les deux pour que le réglage de
    -- l'utilisateur continue de décider.
    local body = collect({ "Text", "EmoteImage", "EmoteText", "EmojiImage", "EmojiText" })

    -- Ce qu'il faut écarter. La liste est courte à dessein : horodatage, badges
    -- et boutons de modération ne portent aucun drapeau de corps, donc le test
    -- positif ci-dessus les élimine déjà. Restent les deux qui, eux, portent
    -- bien `Text` et passeraient au travers : le pseudo de l'auteur, et la
    -- citation que le parent porterait lui-même.
    local notBody = collect({ "Username", "RepliedMessage", "ChannelName" })

    local replied = collect({ "RepliedMessage" })
    local text = collect({ "Text" })

    if #missing > 0 then
        log(c2.LogLevel.Warning, "drapeaux absents de cette version :",
            table.concat(missing, ", "))
    end

    -- Sans ces deux-là, on ne sait ni reconnaître un corps de message ni ranger
    -- quoi que ce soit dans une citation : mieux vaut ne rien faire.
    if text == 0 or replied == 0 then
        return false
    end

    FLAGS = { body = body, notBody = notBody, replied = replied, text = text }
    return true
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
--- Style de police de la citation, résolu une fois. Un nom inconnu retombe sur
--- le défaut de Chatterino plutôt que de poser `nil` sans prévenir.
local function quote_style()
    local style = (c2.FontStyle or {})[CONFIG.reply.fontStyle]
    if style == nil then
        log(c2.LogLevel.Warning, "style de police inconnu :", CONFIG.reply.fontStyle)
    end
    return style
end

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
                    style = quote_style(),
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
                style = quote_style(),
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

-- Compteurs de diagnostic. Sans eux, « le callback ne se déclenche jamais » et
-- « il se déclenche mais ne reconnaît rien » sont indiscernables — et ce sont
-- deux problèmes opposés.
local stats = { seen = 0, detected = 0, rebuilt = 0, failed = 0 }
M.stats = stats

local hooked = {}          -- nom de canal -> ConnectionHandle
local hooked_channels = {} -- nom de canal -> canal, pour le repassage périodique
local warned_no_events = false
local reentrant = false

local function on_message(channel, msg)
    if reentrant or not CONFIG.reply.enabled then
        return
    end

    -- LE REMPLACEMENT DOIT SORTIR DU SIGNAL.
    --
    -- `on_message_appended` est émis depuis `Channel::addMessage`, juste après
    -- `messages_.pushBack`. Les slots sont invoqués dans l'ordre de connexion, et
    -- le nôtre passe avant celui de la vue quand le plugin s'est branché avant
    -- que le split existe — ce qui est le cas normal avec la fenêtre superposée,
    -- branchée par son nom au démarrage.
    --
    -- Remplacer à cet instant ne produit rien de visible :
    --
    --     void ChannelView::messageReplaced(size_t hint, const MessagePtr &prev, …)
    --     {
    --         auto optItem = this->messages_.find(hint, [&](const auto &it) {
    --             return it->getMessagePtr() == prev;
    --         });
    --         if (!optItem) { return; }        // abandon silencieux
    --
    -- La vue n'a pas encore ajouté le message d'origine, donc elle ne le trouve
    -- pas et renonce sans erreur. Son propre slot pose ensuite le calque du
    -- message ORIGINAL. La file du canal porte la version reconstruite, l'écran
    -- affiche l'ancienne — et rien ne le signale.
    --
    -- En différant d'un tour de boucle, toutes les vues ont posé leur calque et
    -- `messageReplaced` les met correctement à jour.
    stats.seen = stats.seen + 1

    c2.later(function()
        if reentrant then
            return
        end

        local ok, replacement = pcall(rebuild_reply, channel, msg)
        if not ok then
            log(c2.LogLevel.Warning, "reconstruction échouée :", replacement)
            return
        end
        if not replacement then
            return
        end

        stats.detected = stats.detected + 1

        reentrant = true
        local replaced, err = pcall(function()
            channel:replace_message(msg, replacement)
        end)
        reentrant = false

        if replaced then
            stats.rebuilt = stats.rebuilt + 1
        else
            stats.failed = stats.failed + 1
            log(c2.LogLevel.Warning, "remplacement échoué :", err)
        end
    end, 0)
end
M.on_message = on_message

--- Branche un canal, s'il ne l'est pas déjà.
---@param channel table
---@param force boolean? rebrancher même si déjà connu
---@return boolean hooked
---@return string? name
--- Reconstruit les réponses DÉJÀ affichées dans un canal.
---
--- Sans cela, brancher un canal ne produit aucun effet visible tant qu'une
--- nouvelle réponse n'arrive pas — ce qui rend impossible de distinguer « ça ne
--- marche pas » de « rien ne s'est encore passé ». L'opération est idempotente :
--- un message déjà reconstruit n'a plus de `single-line-text`, donc il est ignoré.
---@param channel table
---@return integer fixed
local function rebuild_existing(channel)
    local fixed = 0

    pcall(function()
        local snapshot = channel:message_snapshot(CONFIG.reply.lookbackMessages)
        for i = 1, #snapshot do
            local msg = snapshot[i]
            local built = select(2, pcall(rebuild_reply, channel, msg))
            if type(built) == "table" then
                reentrant = true
                local done = pcall(function()
                    channel:replace_message(msg, built)
                end)
                reentrant = false
                if done then
                    fixed = fixed + 1
                end
            end
        end
    end)

    return fixed
end
M.rebuild_existing = rebuild_existing

local function hook_channel(channel, force)
    if not channel then
        return false
    end

    local ok, name = pcall(function()
        return channel:get_name()
    end)
    if not ok or not name or name == "" then
        return false
    end
    if hooked[name] and not force then
        return true, name
    end

    local connected, handle = pcall(function()
        return channel:on_message_appended(function(msg)
            on_message(channel, msg)
        end)
    end)

    if connected then
        hooked[name] = handle
        hooked_channels[name] = channel
        debug("canal branché :", name)

        -- Rendre le branchement VISIBLE, et agir tout de suite sur l'existant.
        -- Une ligne de console ne se voit pas ; un message dans le chat, si.
        local fixed = rebuild_existing(channel)
        pcall(function()
            channel:add_system_message(("Cowlor's Chat v%s branché — %d citation%s reconstruite%s")
                :format(VERSION, fixed, fixed > 1 and "s" or "", fixed > 1 and "s" or ""))
        end)

        return true, name
    elseif not warned_no_events then
        -- Une seule fois : ce balayage tourne toutes les trois secondes, et une
        -- version dépourvue de l'événement le ferait échouer indéfiniment.
        warned_no_events = true
        log(c2.LogLevel.Critical,
            "Channel:on_message_appended est absent de cette version de " ..
            "Chatterino — le plugin ne peut rien faire. Il faut un build " ..
            "nightly de Chatterino7. Détail :", tostring(handle))
    end

    return false, name
end

--- Parcourt l'arbre des fenêtres pour découvrir les canaux ouverts.
---
--- ATTENTION — ce balayage ne voit PAS la fenêtre superposée au navigateur.
--- `c2.windows:all()` renvoie `std::vector<Window *>`, et `AttachedWindow` est un
--- `QWidget` qui n'est jamais inscrit dans cette liste : il tient son propre
--- registre statique. Le canal affiché dans la superposition reste donc invisible
--- ici, et c'est la commande `/cowlors` qui permet de le brancher à la main.
---
--- Ce n'est pas si grave qu'il y paraît : les canaux de Chatterino sont partagés,
--- donc brancher « #chaine » depuis n'importe quel split touche le même objet que
--- celui qu'affiche la superposition.
local last_hooked_count = -1

local function sweep_channels()
    -- Les chaînes nommées dans CONFIG.channels, d'abord : c'est la seule voie
    -- pour la fenêtre superposée.
    for _, name in ipairs(CONFIG.channels or {}) do
        pcall(function()
            local channel = c2.Channel.by_name(name)
            if channel then
                hook_channel(channel)
            end
        end)
    end

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
            hooked_channels[name] = nil
        end
    end

    -- Filet de sécurité. Le chemin événementiel devrait suffire, mais il a
    -- échoué assez longtemps pour qu'on ne lui fasse plus une confiance
    -- exclusive : ce repassage reconstruit ce qui est affiché et n'aurait pas
    -- dû l'être. L'opération est idempotente, donc un message déjà traité ne
    -- coûte qu'un parcours de ses éléments.
    for _, channel in pairs(hooked_channels) do
        pcall(function()
            local fixed = rebuild_existing(channel)
            if fixed > 0 then
                stats.rebuilt = stats.rebuilt + fixed
                debug(("repassage : %d citation(s) reconstruite(s)"):format(fixed))
            end
        end)
    end

    -- Le nombre de canaux branchés est LA information qui dit si le plugin a
    -- prise sur quoi que ce soit. On la journalise à chaque changement, au
    -- niveau Info : rester muet quand on ne trouve rien est ce qui a rendu le
    -- premier diagnostic si long.
    local count = 0
    for _ in pairs(hooked) do
        count = count + 1
    end
    if count ~= last_hooked_count then
        last_hooked_count = count
        if count == 0 then
            log(c2.LogLevel.Info,
                "aucun canal branché. Si tu utilises la superposition au " ..
                "navigateur, nomme tes chaînes dans CONFIG.channels ou tape " ..
                "/cowlors dans le chat.")
        else
            log(c2.LogLevel.Info, ("canaux branchés : %d"):format(count))
        end
    end

    c2.later(sweep_channels, CONFIG.channelSweepMs)
end

-- =============================================================================
-- Commande de diagnostic
-- =============================================================================

--- `/cowlors` — dit ce que le plugin voit, et branche le canal courant.
---
--- Cette commande existe pour deux raisons. La première est le diagnostic : sans
--- elle, un plugin qui ne fait rien est indiscernable d'un plugin qui fait mal
--- son travail. La seconde est fonctionnelle : la fenêtre superposée au
--- navigateur échappe au balayage automatique, et c'est ici qu'on la rattrape.
---@param ctx table CommandContext
local function command(ctx)
    local channel = ctx.channel
    if not channel then
        return
    end

    local function say(text)
        pcall(function()
            channel:add_system_message(text)
        end)
    end

    say(("Cowlor's Chat v%s"):format(VERSION))

    if not FLAGS then
        say("drapeaux NON résolus — le plugin est inactif, voir la console")
        return
    end

    -- Le test qui tranche : est-ce qu'on SAIT repérer une citation dans ce qui
    -- est déjà affiché ? Si ce compte est nul alors qu'il y a des réponses à
    -- l'écran, le défaut est dans la détection. S'il est non nul mais que le
    -- « … » persiste, le défaut est dans le branchement ou le remplacement.
    local scanned, found, example = 0, 0, nil
    pcall(function()
        local snapshot = channel:message_snapshot(CONFIG.reply.lookbackMessages)
        scanned = #snapshot
        for i = #snapshot, 1, -1 do
            local info = M.find_reply_context(snapshot[i]:elements())
            if info then
                found = found + 1
                example = example or info
            end
        end
    end)

    say(("réponses repérées : %d sur %d messages examinés"):format(found, scanned))
    if example then
        say(("exemple — parent @%s, %d mots dans la citation"):format(
            tostring(example.name), #example.words))
    elseif scanned > 0 then
        say("aucune citation repérée : soit il n'y a pas de réponse à l'écran, "
            .. "soit la détection ne colle plus au DOM de Chatterino")
    end

    -- Branche le canal d'où la commande est lancée. C'est le geste utile dans la
    -- fenêtre superposée, que le balayage ne peut pas atteindre.
    local ok, name = hook_channel(channel)
    say(ok and ("canal branché : " .. tostring(name))
           or ("échec du branchement : " .. tostring(name)))

    local names = {}
    for hooked_name in pairs(hooked) do
        names[#names + 1] = hooked_name
    end
    table.sort(names)
    say(("canaux branchés (%d) : %s"):format(
        #names, #names > 0 and table.concat(names, ", ") or "aucun"))

    say(("compteurs — messages vus : %d, citations détectées : %d, reconstruites : %d, échecs : %d")
        :format(stats.seen, stats.detected, stats.rebuilt, stats.failed))

    -- LE diagnostic décisif : la liste brute des types d'éléments d'une réponse,
    -- telle que Chatterino la construit vraiment. Toute la détection repose sur
    -- la présence d'un « single-line-text » ; s'il n'y figure pas, elle est bâtie
    -- sur une hypothèse fausse, et c'est ici qu'on le voit.
    pcall(function()
        local snapshot = channel:message_snapshot(CONFIG.reply.lookbackMessages)
        for i = #snapshot, 1, -1 do
            local types = {}
            local looks_like_reply = false
            for _, el in ipairs(snapshot[i]:elements()) do
                local t = tostring(el.type)
                types[#types + 1] = t
                if t == "reply-curve" or t == "single-line-text" then
                    looks_like_reply = true
                end
            end
            if looks_like_reply then
                say("dernière réponse — éléments : " .. table.concat(types, " "))
                return
            end
        end
        if #snapshot > 0 then
            local types = {}
            for _, el in ipairs(snapshot[#snapshot]:elements()) do
                types[#types + 1] = tostring(el.type)
            end
            say("aucune réponse trouvée ; dernier message — éléments : "
                .. table.concat(types, " "))
        end
    end)

    local fixed = rebuild_existing(channel)
    say(("citations reconstruites à l'instant : %d"):format(fixed))
    say("les nouvelles réponses de ce canal seront reconstruites à leur arrivée")
end

M.command = command
M.hook_channel = hook_channel
M.sweep_channels = sweep_channels

-- =============================================================================
-- Démarrage
-- =============================================================================

M.CONFIG = CONFIG

--- Vérifie que la version installée expose ce dont le plugin a besoin.
---
--- `Channel:on_message_appended` et `c2.windows` n'existent pas dans Chatterino7
--- v7.5.5 : ils sont arrivés après. Sans eux il n'y a ni moyen d'être prévenu
--- qu'un message arrive, ni moyen d'énumérer les canaux ouverts — donc aucune
--- façon de faire ce que ce plugin fait.
---
--- On ne teste ici que `c2.windows`, qui est un simple champ global. Sonder
--- `on_message_appended` demanderait de fabriquer un canal, et un faux négatif
--- mettrait le plugin en veille alors qu'il fonctionnerait : c'est `hook_channel`
--- qui constatera son absence, au moment où il essaie de s'en servir.
---@return boolean ok
---@return string? reason
local function check_api()
    if c2.windows == nil then
        return false, "c2.windows"
    end
    return true
end

-- Sous le harnais de test, `c2` est une API simulée et on ne démarre pas les
-- minuteries : les tests appellent les fonctions pures directement.
if c2 then
    -- Tout le démarrage est sous pcall : une API qui bouge doit mettre le plugin
    -- en veille avec un message lisible, jamais l'empêcher de se charger.
    local ok, err = pcall(function()
        if not resolve_flags() then
            log(c2.LogLevel.Critical,
                "drapeaux indispensables absents — plugin inactif")
            return
        end
        M.FLAGS = FLAGS

        if rawget(_G, "COWLORS_CHAT_TEST") then
            return
        end

        local supported, missing = check_api()
        if not supported then
            log(c2.LogLevel.Critical,
                "cette version de Chatterino n'expose pas " .. tostring(missing) ..
                " — le plugin reste inactif. Il faut une version postérieure à " ..
                "Chatterino7 v7.5.5 (build nightly). Voir le README.")
            return
        end

        -- Chatterino enregistre les commandes avec leur barre oblique.
        if not c2.register_command("/cowlors", command) then
            log(c2.LogLevel.Warning,
                "la commande /cowlors n'a pas pu être enregistrée (déjà prise ?)")
        end

        log(c2.LogLevel.Info, "v" .. VERSION ..
            " — citations de réponse. Tape /cowlors dans un chat pour un état des lieux.")
        sweep_channels()
    end)

    if not ok then
        log(c2.LogLevel.Critical, "démarrage interrompu :", tostring(err))
    end
end

return M
