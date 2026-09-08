# Cowlor's Chat for Twitch

Retrouver les réglages de [BetterTwitchChat](https://github.com/Maxezify/BetterTwitchChat-with-7tv)
dans **Chatterino7**, quand celui-ci remplace le chat de Twitch dans le navigateur.

Le chat web de Twitch décroche dès que le débit monte. Chatterino, application
native, ne décroche pas — et son extension officielle sait déjà venir se poser à
la place du chat Twitch, sous Windows. Ce qu'il manque, ce sont les réglages :
Chatterino tronque les citations de réponse exactement comme Twitch le fait.

Ce dépôt les rétablit, **sans compiler quoi que ce soit**.

## ⚠️ Version de Chatterino7 requise

**Il faut un build *nightly*. La v7.5.5 stable ne suffit pas.**

Le plugin a besoin de `Channel:on_message_appended` (être prévenu qu'un message
arrive) et de `c2.windows` (énumérer les canaux ouverts). Ces deux API sont
arrivées **après** la v7.5.5 : sur la stable, il n'existe aucun moyen de réagir à
un message ni de découvrir les canaux, donc aucune façon de faire ce que ce
plugin fait.

Un nightly de septembre 2026 (commit `5a77ec758`) les a, vérifié. Sur une version
trop ancienne, le plugin se charge, se met en veille et écrit la raison dans la
console — il ne plante pas.

Attention à ne pas se fier au numéro affiché : un nightly annonce la version
amont dont il dérive (« 2.5.5 »), pas son âge. C'est la date de build qui
compte.

Le nightly est explicitement marqué expérimental par SevenTV. C'est un vrai coût
à peser : voir « Limites connues ».

## État

**v0.7.0 — la cause racine est corrigée.** Le reste est en chantier, voir la feuille de
route plus bas.

| | |
|---|---|
| Logique | testée — 52 vérifications contre une API `c2` simulée |
| Rendu réel | **jamais exécuté dans Chatterino** |

Ce plugin n'a pas encore tourné une seule fois dans un vrai Chatterino. La
logique est vérifiée, le comportement à l'écran ne l'est pas. Les points à
contrôler au premier lancement sont listés dans [`docs/INSTALL.md`](docs/INSTALL.md).

## Ce que fait le plugin

Chatterino construit la citation d'une réponse avec un `SingleLineTextElement`
alimenté par `threadRoot->messageText` : **du texte brut, coupé à une ligne avec
« … »**. C'est le défaut que BetterTwitchChat corrige côté web, et Chatterino
l'a aussi.

Le plugin le répare :

- **Citation lisible en entier.** La troncature a lieu à la mise en page, pas au
  stockage : l'élément garde la liste de mots complète et Lua peut la lire. On
  réémet ce texte dans un élément qui passe à la ligne.
- **Emotes dans la citation.** On retrouve le message parent parmi les messages
  récents du canal et on recopie ses emotes. Lua ne sait pas *fabriquer* une
  emote, mais `Message:append_element()` clone celle qu'on lui passe.
- **Repli propre.** Parent sorti de l'historique : on réémet le texte complet
  sans emotes. La troncature disparaît quand même.

## La cause racine : l'API ne rend pas des tables Lua

Sept versions, et le vrai coupable était une ligne écrite « par prudence » dans
la toute première.

`Message:elements()` rend un `MessageElements`, `message_snapshot()` un
`std::vector<MessagePtr>`, `element.words` une `QStringList`, `Message.new()` un
`Message`. **Ce sont des objets C++**, pas des tables : pour Lua, du `userdata`.

On les parcourt très bien avec `ipairs` — Lua 5.4 passe par `__index` — ce qui
donne l'illusion de tables. Mais `type()` répond `"userdata"`, et ni `#`, ni
`table.concat`, ni l'écriture n'y fonctionnent.

D'où ceci, en tête de la fonction de détection :

```lua
if type(elements) ~= "table" then
    return nil        -- rejette TOUT ce que l'API fournit
end
```

Écrit pour être robuste, ce garde rendait le plugin inopérant : il n'examinait
jamais un seul message, sans lever la moindre erreur ni écrire une ligne de
journal. Le même garde était présent dans `match_parent`, `extract_body`, et sur
le message reconstruit.

Le diagnostic n'a été possible que quand `/cowlors` a affiché, côte à côte,
« réponses repérées : 0 » et une liste d'éléments contenant bel et bien un
`single-line-text`. La contradiction désignait le garde.

Tout ce qui vient de `c2` passe désormais par `to_list()`, qui copie le
conteneur dans une vraie table. **Un test de source interdit mécaniquement à un
garde `type(v) == "table"` de revenir** — il en a d'ailleurs débusqué une seconde
occurrence à l'écriture même de ce test.

Et l'API simulée des tests rend maintenant des conteneurs, pas des tables : leur
rendre de vraies tables est ce qui a laissé 47 tests au vert pendant que le
plugin ne faisait rien.

## Le piège : ne jamais remplacer pendant le signal

Il a coûté quatre versions, il mérite d'être écrit.

`on_message_appended` est émis depuis `Channel::addMessage`, juste après
`messages_.pushBack`. Les slots partent dans l'ordre de connexion, et celui du
plugin passe avant celui de la vue dès lors qu'il s'est branché avant que le
split existe — le cas normal avec la fenêtre superposée, branchée par son nom au
démarrage.

Remplacer à cet instant ne produit **rien de visible** :

```cpp
void ChannelView::messageReplaced(size_t hint, const MessagePtr &prev, …)
{
    auto optItem = this->messages_.find(hint, [&](const auto &it) {
        return it->getMessagePtr() == prev;
    });
    if (!optItem) { return; }        // abandon silencieux
```

La vue n'a pas encore posé le calque du message d'origine : elle ne le trouve
pas et renonce sans erreur. Son propre slot pose ensuite le calque du message
**original**. La file du canal porte la version reconstruite, l'écran affiche
l'ancienne, et rien ne le signale — ni exception, ni journal.

Le remplacement est donc différé d'un tour de boucle (`c2.later(…, 0)`). Un test
verrouille ce comportement.

## `/cowlors`

Tape `/cowlors` dans un chat. La commande dit ce que le plugin voit — version,
canaux branchés, nombre de réponses qu'il sait repérer dans ce qui est affiché —
**et branche le canal courant**.

Ce second point n'est pas un confort, c'est une nécessité : voir plus bas.

## ⚠️ La fenêtre superposée échappe au balayage automatique

Le plugin découvre les canaux en parcourant `c2.windows:all()`. Or cette fonction
renvoie `std::vector<Window *>`, et **`AttachedWindow` — la fenêtre posée sur le
navigateur — est un `QWidget`**, jamais inscrit dans cette liste : elle tient son
propre registre statique. Son canal est donc invisible au balayage, et les
réponses n'y sont pas reconstruites.

Vérifié dans le gestionnaire `select` de Chatterino :

```cpp
auto channel = getApp()->getTwitch()->getOrAddChannel(name);
setWatchingChannel(channel);
if (attach) {
    auto *window = AttachedWindow::getForeground(args);  // pas un Window
    window->setChannel(getOrAddChannel(name));
}
```

**La solution : nommer tes chaînes dans `CONFIG.channels`**, en haut de
`init.lua` :

```lua
channels = { "zerator", "domingo", "ponce" },
```

`getOrAddChannel` inscrit la chaîne dans la table que `by_name` interroge : elle
est donc parfaitement joignable par son nom, même si aucune fenêtre ne la porte.
Le balayage réessaie toutes les trois secondes, donc le branchement se fait dès
que tu ouvres la chaîne, quel que soit l'ordre.

`/cowlors` reste utile pour une chaîne de passage, ou pour vérifier l'état.

La console dit toujours combien de canaux sont branchés, et le dit explicitement
quand il n'y en a aucun. Rester muet dans ce cas est ce qui a rendu le premier
diagnostic si long.

Lever proprement la limite demanderait que Chatterino expose les fenêtres
attachées, ou un accès au canal regardé — une contribution amont utile à tous.

## Feuille de route

| | |
|---|---|
| Regroupement des gifts multiples | prévu — demande aussi un filtre de canal, Lua ne sait pas masquer un message |
| Notices sub/prime/raid compactées | prévu |
| Traduction des notices | prévu |
| Extension d'extinction du chat Twitch | **à mesurer d'abord** — voir plus bas |
| Alignement des emotes sur la ligne de base | probablement inutile, à juger à l'œil |

### L'extension d'extinction

L'extension officielle exécute `chatShell.children[0].innerHTML = '<div…>'`.
C'est un **effacement du DOM, pas une extinction** : la connexion IRC de Twitch,
l'analyse des messages et leur mise en tampon continuent de tourner, et
l'extension 7TV continue de décorer un chat que plus personne ne regarde.

Avant d'écrire la moindre ligne : **mesurer**. Profileur ouvert sur une grosse
chaîne, comparer trois états — chat normal, chat effacé par l'extension, chat
effacé *et* extension 7TV désactivée. Chatterino7 rendant le 7TV nativement,
couper l'extension est gratuit ; si l'écart est marginal, les leviers plus
agressifs (replier la colonne, bloquer le WebSocket) ne valent pas leur risque.

## Installation

Voir [`docs/INSTALL.md`](docs/INSTALL.md). En bref : Chatterino7, l'extension
officielle, puis deux fichiers à déposer. **Attention** — Chatterino7 partage
`%APPDATA%\Chatterino2\` avec Chatterino2 ; si tu as les deux, ils se marchent
dessus.

Les réglages à cocher en complément sont dans [`presets/settings.md`](presets/settings.md).

## Développement

```sh
lua5.4 tests/run.lua
```

Les tests montent une API `c2` simulée (`tests/mock_c2.lua`) qui reproduit le
contrat observé dans les liaisons de Chatterino : éléments en lecture seule sauf
`add_flags`, clonage à l'insertion, messages gelés une fois affichés. Elle
n'expose **que les drapeaux à bit simple**, comme l'exécution réelle — les
combinés (`Emote`, `Badges`, `EmojiAll`) figurent dans le fichier de types mais
pas dans le binaire, et s'y fier a déjà empêché le plugin de se charger.

Les tests couvrent le repérage de la citation, la recherche du parent,
l'extraction de son corps, l'assemblage du remplaçant, et la résistance à un
drapeau manquant.

Ils ne couvrent pas — et aucun test hors de Chatterino ne le peut — le rendu, le
coût en performance, et le comportement de `replace_message` sur un message déjà
visible.

Le plugin tient dans un seul `plugin/init.lua`. Chatterino vide `package.path` et
remplace les chercheurs de modules par les siens, non documentés : un `require`
sur nos propres fichiers serait un pari. À la taille actuelle, un fichier unique
ne coûte rien.

## Limites connues

- **Windows uniquement.** Le code d'attachement de Chatterino est sous
  `#ifdef USEWINSDK`. Sous Wayland, positionner une fenêtre en coordonnées
  absolues est interdit par le protocole.
- **Superposition, pas intégration.** La fenêtre Chatterino est posée par-dessus
  la page et suivie par un minuteur à 1 ms. Elle n'est pas découpée par le
  navigateur et peut dériver en DPI mis à l'échelle ou en multi-écran.
- **API de plugins alpha, et qui bouge vite.** Entre la v7.5.5 et le nightly,
  l'API des canaux a gagné les événements dont ce plugin dépend. Elle peut donc
  aussi en perdre. Le plugin vérifie ce qu'il trouve au démarrage plutôt que de
  se fier au fichier de types — celui-ci liste des drapeaux que l'exécution
  n'expose pas, ce qui a déjà cassé un chargement.
- **Build nightly requis**, donc explicitement expérimental. Si le nightly
  s'avère instable à l'usage, le projet n'a pas de porte de sortie côté stable :
  il faudrait attendre la prochaine version taguée.
- **Taille des emotes citées non réglable.** Les emotes sont clonées telles
  quelles ; Lua n'expose aucun moyen de les redimensionner. Une emote haute peut
  faire grandir la ligne de citation.
- **Recherche du parent heuristique.** `reply-parent-msg-id` n'est pas exposé à
  Lua : le parent est reconnu par auteur et texte. Deux messages identiques du
  même auteur dans la fenêtre de recherche sont indiscernables — on prend le plus
  récent. Exposer ce champ en amont serait le vrai correctif.

## Licence

MIT.
