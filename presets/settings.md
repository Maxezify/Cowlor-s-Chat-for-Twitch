# Réglages Chatterino

Correspondance entre le bloc `CONFIG` de BetterTwitchChat v15.24 et Chatterino7.

Ces réglages se cochent à la main. Un fragment de `settings.json` à fusionner
serait plus rapide, mais Chatterino réécrit ce fichier en quittant : un dépôt
pendant qu'il tourne serait écrasé. La liste est plus fiable.

Chemins donnés tels qu'ils apparaissent dans `Settings`.

## À cocher en priorité

Ces deux-là changent le plus, et sont **désactivés par défaut**.

| Réglage | Où | Équivalent chez toi |
|---|---|---|
| **Smooth scrolling on new messages** | Appearance | `smoothScrollMs: 1500` |
| **Enable plugins** | Plugins | (indispensable au plugin) |

## Réponses

| Ton réglage | Chatterino | Note |
|---|---|---|
| `reply.hidePrefix` | Appearance → **Strip reply mention** | déjà actif par défaut |
| `reply.renderEmotes` | — | **fourni par le plugin** |
| citation entière | — | **fourni par le plugin** |
| `reply.color`, `reply.fontScale` | — | dans le `CONFIG` du plugin |
| `reply.colorQuotedName` | — | Chatterino colore déjà le pseudo cité |
| `reply.style`, `accentWidth`, `lineHeight`, `gap`, `blockTint`, `emoteHeight`, `underlineNames` | — | hors de portée sans fork |

## Notices sub / prime / gift / raid

| Ton réglage | Chatterino | Note |
|---|---|---|
| `compact.enabled` | Appearance → décocher **Show subscription header**, **Show announcement header**, **Show watch streak header** | |
| `compact.colorNames` | — | déjà fait nativement |
| `compact.tintOpacity` | Highlights → couleurs **Subscriptions** / **Announcements** | |
| `compact.aggregateGifts` | — | à venir dans le plugin |
| `compact.textIndent`, `fontSize` | — | hors de portée sans fork |

## Emotes et affichage

| Ton réglage | Chatterino | Note |
|---|---|---|
| emotes 7TV | Emotes → **7TV global** / **7TV channel** / **7TV EventAPI** | actifs par défaut |
| badges 7TV | Appearance → Badges → **7TV** | |
| paints, emotes personnelles | — | natifs dans Chatterino7 |
| `separators` | Appearance → **Separate messages** | tu l'avais à `false` |
| `emoteAlign`, `emotePaddingTop` | — | sans doute inutile : Chatterino cale déjà tout sur un bas de ligne commun |
| `messageBatchMs` | — | sans objet, Chatterino n'insère pas par paquets |

## Highlights par badge

L'équivalent des « Custom Highlights » de 7TV, et plus direct : chez 7TV il faut
créer une règle par badge, ici c'est intégré.

`Settings → Highlights → Badges` → ajouter Moderator, VIP, etc. avec leur couleur.

## Divers utile

| Réglage | Où | Pourquoi |
|---|---|---|
| **Scrollback limit** | Misc | plus haut = le plugin retrouve plus souvent le message parent d'une réponse |
| Taille et police du chat | Appearance → Font | un seul réglage global, pas de taille par type de message |
