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

Sur une version trop ancienne, le plugin se charge, se met en veille et écrit la
raison dans la console — il ne plante pas.

Le nightly est explicitement marqué expérimental par SevenTV. C'est un vrai coût
à peser : voir « Limites connues ».

## État

**v0.1.1 — citations de réponse.** Le reste est en chantier, voir la feuille de
route plus bas.

| | |
|---|---|
| Logique | testée — 34 vérifications contre une API `c2` simulée |
| Rendu réel | **jamais exécuté dans Chatterino** |

Ce plugin n'a pas encore tourné une seule fois dans un vrai Chatterino. La
logique est vérifiée, le comportement à l'écran ne l'est pas. Les points à
contrôler au premier lancement sont listés dans [`docs/INSTALL.md`](docs/INSTALL.md).

## Ce que fait la v0.1

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
