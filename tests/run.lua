--- Vérifications de la logique du plugin contre l'API `c2` simulée.
---
--- Ce que ces tests couvrent : le repérage de la citation, la recherche du
--- message parent, l'extraction de son corps, et l'assemblage du message
--- reconstruit. Autrement dit, tout ce qui décide de ce qui s'affiche.
---
--- Ce qu'ils NE couvrent PAS, et qu'aucun test hors de Chatterino ne peut
--- couvrir : le rendu réel, le coût en performance, et le comportement de
--- `replace_message` sur un message visible. Voir docs/INSTALL.md.
---
--- Lancer :  lua5.4 tests/run.lua

package.path = "./tests/?.lua;" .. package.path

local mock = require("mock_c2")

-- Le plugin lit le global `c2`. On le pose avant de le charger, et on signale
-- qu'on est sous test pour qu'il ne démarre pas ses minuteries.
_G.c2 = mock.c2
_G.COWLORS_CHAT_TEST = true

local plugin = dofile("plugin/init.lua")

-- ---------------------------------------------------------------------------
-- Micro-harnais
-- ---------------------------------------------------------------------------

local passed, failed = 0, 0
local current = "?"

local function test(name, fn)
    current = name
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print(string.format("  ok   %s", name))
    else
        failed = failed + 1
        print(string.format("  FAIL %s\n       %s", name, tostring(err)))
    end
end

local function check(cond, msg)
    if not cond then
        error(msg or "condition fausse", 2)
    end
end

local function equal(got, want, msg)
    if got ~= want then
        error(string.format("%s\n       attendu : %s\n       obtenu  : %s",
            msg or "valeurs différentes", tostring(want), tostring(got)), 2)
    end
end

local EF = mock.c2.MessageElementFlag

-- ---------------------------------------------------------------------------
-- Fabriques
-- ---------------------------------------------------------------------------

--- Un message de chat ordinaire : horodatage, badge, pseudo, puis le corps.
local function chat_message(opts)
    local elements = {
        mock.element({ type = "timestamp", flags = EF.Timestamp }),
        mock.element({ type = "badge", flags = EF.BadgeSubscription }),
        mock.element({ type = "mention", words = { opts.display_name }, flags = EF.Text | EF.Username }),
    }
    for _, part in ipairs(opts.body or {}) do
        elements[#elements + 1] = part
    end
    elements[#elements + 1] = mock.element({ type = "twitch-moderation", flags = EF.ModeratorTools })

    return mock.message({
        id = opts.id,
        display_name = opts.display_name,
        login_name = (opts.display_name or ""):lower(),
        message_text = opts.message_text,
        username_color = opts.username_color or "#ff0000",
        elements = elements,
    })
end

--- Une réponse, telle que Chatterino la construit : courbe, « Replying to »,
--- « @pseudo: », puis la citation en SingleLineTextElement.
local function reply_message(opts)
    local replied = EF.RepliedMessage
    local elements = {
        mock.element({ type = "reply-curve", flags = replied }),
        mock.element({ type = "text", words = { "Replying", "to" }, flags = replied }),
        mock.element({ type = "text", words = { "@" .. opts.parent_name .. ":" }, flags = replied }),
        mock.element({ type = "single-line-text", words = opts.quote_words, flags = replied | EF.Text }),
        mock.element({ type = "timestamp", flags = EF.Timestamp }),
        mock.element({ type = "mention", words = { opts.display_name }, flags = EF.Text | EF.Username }),
        mock.element({ type = "text", words = opts.body_words or { "d'accord" }, flags = EF.Text }),
    }
    return mock.message({
        id = opts.id,
        display_name = opts.display_name,
        message_text = table.concat(opts.body_words or { "d'accord" }, " "),
        elements = elements,
    })
end

-- ---------------------------------------------------------------------------
print("\nutilitaires")
-- ---------------------------------------------------------------------------

test("has_flag reconnaît un drapeau présent", function()
    check(plugin.has_flag(EF.Text | EF.Username, EF.Username))
end)

test("has_flag rejette un drapeau absent", function()
    check(not plugin.has_flag(EF.Text, EF.Username))
end)

test("has_flag ne lève pas sur une valeur non entière", function()
    check(not plugin.has_flag(nil, EF.Text))
    check(not plugin.has_flag({}, EF.Text))
end)

test("normalize réduit les espaces", function()
    equal(plugin.normalize("  a   b \n c  "), "a b c")
end)

test("strip_mention retire @ et :", function()
    equal(plugin.strip_mention("@Cowlor:"), "Cowlor")
    equal(plugin.strip_mention("Cowlor"), "Cowlor")
end)

-- ---------------------------------------------------------------------------
print("\nrésistance aux drapeaux manquants")
-- ---------------------------------------------------------------------------
-- Le fichier de types de Chatterino liste des drapeaux que l'exécution n'expose
-- pas : les combinés (Emote, Badges, EmojiAll, Default) n'en sont que des OU, et
-- les liaisons n'exportent que les bits simples. Nommer `Badges` empêchait le
-- plugin de se charger. Ces tests verrouillent la leçon.

test("build_mask assemble les drapeaux présents", function()
    local m = plugin.build_mask({ "Text", "Username" })
    equal(m, EF.Text | EF.Username)
end)

test("build_mask ignore un drapeau absent au lieu de lever", function()
    local m, missing = plugin.build_mask({ "Text", "Badges", "Username" })
    equal(m, EF.Text | EF.Username, "le masque doit tenir sans le drapeau absent")
    equal(#missing, 1, "un manquant attendu")
    equal(missing[1], "Badges")
end)

test("build_mask sur des noms tous absents rend un masque nul", function()
    local m, missing = plugin.build_mask({ "Badges", "EmojiAll", "Default" })
    equal(m, 0)
    equal(#missing, 3)
end)

test("aucun drapeau combiné n'est exposé par l'API simulée", function()
    -- Si quelqu'un les rajoute au mock « pour que ça marche », ce test tombe et
    -- rappelle pourquoi ils n'y sont pas.
    for _, name in ipairs({ "Emote", "Badges", "EmojiAll", "Default" }) do
        check(EF[name] == nil,
            "le drapeau combiné " .. name .. " ne doit pas exister à l'exécution")
    end
end)

test("les masques du plugin se résolvent sans drapeau combiné", function()
    check(plugin.FLAGS, "les drapeaux doivent être résolus")
    check(plugin.FLAGS.text ~= 0, "Text est indispensable")
    check(plugin.FLAGS.replied ~= 0, "RepliedMessage est indispensable")
    check(plugin.FLAGS.body ~= 0, "le masque de corps ne peut pas être vide")
end)

-- ---------------------------------------------------------------------------
print("\nrepérage de la citation")
-- ---------------------------------------------------------------------------

test("trouve le corps de la citation et le pseudo cité", function()
    local msg = reply_message({
        display_name = "Bob",
        parent_name = "Alice",
        quote_words = { "salut", "tout", "le", "monde" },
    })
    local ctx = plugin.find_reply_context(msg:elements())
    check(ctx, "aucun contexte trouvé")
    equal(ctx.body_index, 4, "index du corps")
    equal(ctx.name, "Alice", "pseudo cité")
    equal(table.concat(ctx.words, " "), "salut tout le monde", "texte cité")
end)

test("renvoie nil sur un message ordinaire", function()
    local msg = chat_message({
        display_name = "Bob",
        message_text = "coucou",
        body = { mock.element({ type = "text", words = { "coucou" }, flags = EF.Text }) },
    })
    check(plugin.find_reply_context(msg:elements()) == nil)
end)

test("tolère une entrée absurde", function()
    check(plugin.find_reply_context(nil) == nil)
    check(plugin.find_reply_context("bonjour") == nil)
end)

-- ---------------------------------------------------------------------------
print("\nrecherche du parent")
-- ---------------------------------------------------------------------------

local function snapshot_fixture()
    return {
        chat_message({ display_name = "Alice", message_text = "un autre message" }),
        chat_message({ display_name = "Carol", message_text = "salut tout le monde" }),
        chat_message({ display_name = "Alice", message_text = "salut tout le monde" }),
    }
end

test("retrouve le parent par pseudo et texte", function()
    local snap = snapshot_fixture()
    local parent = plugin.match_parent(snap, "Alice", { "salut", "tout", "le", "monde" })
    check(parent, "parent non trouvé")
    equal(parent, snap[3], "doit préférer Alice, pas Carol")
end)

test("ignore un texte identique d'un autre auteur", function()
    local snap = { chat_message({ display_name = "Carol", message_text = "salut" }) }
    check(plugin.match_parent(snap, "Alice", { "salut" }) == nil)
end)

test("compare les pseudos sans tenir compte de la casse", function()
    local snap = { chat_message({ display_name = "Alice", message_text = "salut" }) }
    check(plugin.match_parent(snap, "alice", { "salut" }))
end)

test("prend le plus récent quand le message est répété", function()
    local snap = {
        chat_message({ id = "vieux", display_name = "Alice", message_text = "+1" }),
        chat_message({ id = "recent", display_name = "Alice", message_text = "+1" }),
    }
    equal(plugin.match_parent(snap, "Alice", { "+1" }).id, "recent")
end)

test("normalise les espaces avant de comparer", function()
    local snap = { chat_message({ display_name = "Alice", message_text = "salut   tout  le monde" }) }
    check(plugin.match_parent(snap, "Alice", { "salut", "tout", "le", "monde" }))
end)

test("renvoie nil sur une citation vide", function()
    check(plugin.match_parent(snapshot_fixture(), "Alice", {}) == nil)
end)

-- ---------------------------------------------------------------------------
print("\nextraction du corps du parent")
-- ---------------------------------------------------------------------------

test("garde le texte et les emotes, écarte l'habillage", function()
    local parent = chat_message({
        display_name = "Alice",
        message_text = "salut PogChamp",
        body = {
            mock.element({ type = "text", words = { "salut" }, flags = EF.Text }),
            mock.element({ type = "emote", flags = EF.EmoteImage, tooltip = "PogChamp" }),
            mock.element({ type = "text", words = { "PogChamp" }, flags = EF.EmoteText }),
        },
    })

    local parts = plugin.extract_body(parent:elements())
    equal(#parts, 3, "trois morceaux attendus")
    equal(parts[1].kind, "text")
    equal(parts[2].kind, "element", "l'emote doit être recopiée, pas réémise")
    equal(parts[3].kind, "text", "le doublon texte de l'emote est conservé")
end)

test("écarte la citation que porterait le parent lui-même", function()
    local parent = mock.message({
        display_name = "Alice",
        message_text = "oui",
        elements = {
            mock.element({ type = "single-line-text", words = { "message", "cité" },
                           flags = EF.RepliedMessage | EF.Text }),
            mock.element({ type = "mention", words = { "Alice" }, flags = EF.Text | EF.Username }),
            mock.element({ type = "text", words = { "oui" }, flags = EF.Text }),
        },
    })

    local parts = plugin.extract_body(parent:elements())
    equal(#parts, 1, "seul le corps propre doit rester")
    equal(table.concat(parts[1].words, " "), "oui")
end)

test("tolère une entrée absurde", function()
    equal(#plugin.extract_body(nil), 0)
end)

-- ---------------------------------------------------------------------------
print("\nassemblage")
-- ---------------------------------------------------------------------------

test("fusionne les morceaux de texte consécutifs", function()
    local parts = {
        { kind = "text", words = { "a" } },
        { kind = "text", words = { "b", "c" } },
        { kind = "element", element = mock.element({ type = "emote" }) },
        { kind = "text", words = { "d" } },
    }
    local merged = plugin.merge_text_parts(parts)
    equal(#merged, 3, "trois morceaux après fusion")
    equal(table.concat(merged[1].words, " "), "a b c")
    equal(merged[2].kind, "element")
end)

test("la fusion ne modifie pas les morceaux d'origine", function()
    local parts = { { kind = "text", words = { "a" } }, { kind = "text", words = { "b" } } }
    plugin.merge_text_parts(parts)
    equal(#parts[1].words, 1, "la liste d'origine doit rester intacte")
end)

test("splice remplace le corps de la citation à sa place", function()
    local original = { "a", "b", "CORPS", "d" }
    local out = plugin.splice_elements(original, { body_index = 3 }, { "x", "y" })
    equal(table.concat(out, ","), "a,b,x,y,d")
end)

-- ---------------------------------------------------------------------------
print("\nreconstruction de bout en bout")
-- ---------------------------------------------------------------------------

--- Monte un canal contenant un message parent, puis une réponse à ce message.
local function scenario(parent_body, parent_text, quote_words)
    local channel = mock.channel("#cowlor")
    local parent = chat_message({
        id = "parent",
        display_name = "Alice",
        message_text = parent_text,
        body = parent_body,
    })
    mock.push(channel, parent)

    local reply = reply_message({
        id = "reply",
        display_name = "Bob",
        parent_name = "Alice",
        quote_words = quote_words,
        body_words = { "bien", "vu" },
    })
    mock.push(channel, reply)

    return channel, parent, reply
end

test("la citation reprend les emotes du parent", function()
    local channel, _, reply = scenario({
        mock.element({ type = "text", words = { "salut" }, flags = EF.Text }),
        mock.element({ type = "emote", flags = EF.EmoteImage, tooltip = "PogChamp" }),
    }, "salut PogChamp", { "salut", "PogChamp" })

    local rebuilt = plugin.rebuild_reply(channel, reply)
    check(rebuilt, "aucun remplaçant produit")

    local types = {}
    for _, el in ipairs(rebuilt:elements()) do
        types[#types + 1] = el.type
    end
    -- La citation d'origine (un single-line-text) a disparu au profit d'un
    -- texte et d'une emote.
    equal(table.concat(types, ","),
        "reply-curve,text,text,text,emote,timestamp,mention,text",
        "structure du message reconstruit")
end)

test("aucun single-line-text ne subsiste : la troncature est levée", function()
    local channel, _, reply = scenario({
        mock.element({ type = "text", words = { "un", "message", "vraiment", "long" }, flags = EF.Text }),
    }, "un message vraiment long", { "un", "message", "vraiment", "long" })

    local rebuilt = plugin.rebuild_reply(channel, reply)
    for _, el in ipairs(rebuilt:elements()) do
        check(el.type ~= "single-line-text", "il reste un élément tronquable")
    end
end)

test("les emotes reprises portent le drapeau de citation", function()
    local channel, _, reply = scenario({
        mock.element({ type = "text", words = { "salut" }, flags = EF.Text }),
        mock.element({ type = "emote", flags = EF.EmoteImage }),
    }, "salut PogChamp", { "salut", "PogChamp" })

    local rebuilt = plugin.rebuild_reply(channel, reply)
    for _, el in ipairs(rebuilt:elements()) do
        if el.type == "emote" then
            check(plugin.has_flag(el.flags, EF.RepliedMessage),
                "sans ce drapeau, l'emote sort de la citation")
            return
        end
    end
    error("aucune emote dans le message reconstruit")
end)

test("la citation reçoit la police et la couleur configurées", function()
    local channel, _, reply = scenario({
        mock.element({ type = "text", words = { "salut" }, flags = EF.Text }),
    }, "salut", { "salut" })

    local rebuilt = plugin.rebuild_reply(channel, reply)
    local quote = rebuilt:elements()[4]
    equal(quote.style, mock.c2.FontStyle.ChatMediumSmall, "police de la citation")
    equal(quote.color, plugin.CONFIG.reply.color, "couleur de la citation")
end)

test("parent introuvable : le texte complet est tout de même réémis", function()
    local channel = mock.channel("#cowlor")
    local reply = reply_message({
        display_name = "Bob",
        parent_name = "Fantome",
        quote_words = { "un", "message", "sorti", "de", "l'historique" },
    })
    mock.push(channel, reply)

    local rebuilt = plugin.rebuild_reply(channel, reply)
    check(rebuilt, "un repli doit exister")
    local quote = rebuilt:elements()[4]
    equal(quote.type, "text", "la citation doit devenir un texte ordinaire")
    equal(table.concat(quote.words, " "), "un message sorti de l'historique")
end)

test("les champs du message d'origine sont conservés", function()
    local channel, _, reply = scenario({
        mock.element({ type = "text", words = { "salut" }, flags = EF.Text }),
    }, "salut", { "salut" })

    local rebuilt = plugin.rebuild_reply(channel, reply)
    equal(rebuilt.id, reply.id, "identifiant")
    equal(rebuilt.display_name, reply.display_name, "pseudo")
    equal(rebuilt.message_text, reply.message_text, "texte du message")
end)

test("un message ordinaire n'est pas reconstruit", function()
    local channel = mock.channel("#cowlor")
    local msg = chat_message({ display_name = "Bob", message_text = "coucou" })
    mock.push(channel, msg)
    check(plugin.rebuild_reply(channel, msg) == nil)
end)

-- ---------------------------------------------------------------------------
print("\ncommande de diagnostic")
-- ---------------------------------------------------------------------------
-- Le balayage automatique ne voit pas la fenêtre superposée au navigateur :
-- `c2.windows:all()` renvoie des `Window*`, et `AttachedWindow` est un `QWidget`
-- qui n'y figure pas. `/cowlors` est le rattrapage — et le seul moyen de savoir
-- ce que le plugin voit quand il ne fait rien.

test("branche le canal d'où elle est lancée", function()
    local channel = mock.channel("#superposition")
    plugin.command({ channel = channel })
    equal(#channel._callbacks, 1, "le canal doit avoir été branché")
end)

test("rapporte l'état sans lever", function()
    local channel, _, _ = scenario({
        mock.element({ type = "text", words = { "salut" }, flags = EF.Text }),
    }, "salut", { "salut" })

    plugin.command({ channel = channel })
    check(#channel.system_messages > 0, "un rapport doit être écrit")

    local report = table.concat(channel.system_messages, "\n")
    check(report:find("Cowlor's Chat v"), "la version doit figurer au rapport")
    check(report:find("réponses repérées : 1"), "la réponse présente doit être comptée")
end)

test("signale l'absence de citation plutôt que de se taire", function()
    local channel = mock.channel("#calme")
    mock.push(channel, chat_message({ display_name = "Bob", message_text = "coucou" }))

    plugin.command({ channel = channel })
    local report = table.concat(channel.system_messages, "\n")
    check(report:find("réponses repérées : 0"), "zéro doit être annoncé explicitement")
    check(report:find("aucune citation repérée"), "le cas doit être expliqué")
end)

test("ne lève pas sans canal", function()
    plugin.command({})
end)

test("hook_channel est idempotent", function()
    local channel = mock.channel("#idem")
    local ok1, name1 = plugin.hook_channel(channel)
    local ok2, name2 = plugin.hook_channel(channel)
    check(ok1 and ok2, "les deux appels doivent réussir")
    equal(name1, name2)
    equal(#channel._callbacks, 1, "un seul branchement, pas deux")
end)

-- ---------------------------------------------------------------------------
print("\ncontrat de l'API simulée")
-- ---------------------------------------------------------------------------

test("append_element clone l'élément qu'on lui passe", function()
    local source = mock.element({ type = "emote", flags = EF.EmoteImage })
    local msg = mock.c2.Message.new({ elements = { source } })
    local got = msg:elements()[1]
    check(got ~= source, "l'élément doit être un clone, pas la même instance")
    equal(got.__cloned_from, source, "le clone doit venir de la source")
end)

test("add_flags fonctionne sur un élément cloné", function()
    local msg = mock.c2.Message.new({
        elements = { mock.element({ type = "emote", flags = EF.EmoteImage }) },
    })
    local el = msg:elements()[1]
    el:add_flags(EF.RepliedMessage)
    check(plugin.has_flag(el.flags, EF.RepliedMessage))
    check(plugin.has_flag(el.flags, EF.EmoteImage), "le drapeau d'origine doit survivre")
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d réussis, %d échoués\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
