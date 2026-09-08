# Réglages Chatterino

Correspondance entre le bloc `CONFIG` de BetterTwitchChat v15.24 et Chatterino7.

Ces réglages se cochent à la main. Un fragment de `settings.json` à fusionner
serait plus rapide, mais Chatterino réécrit ce fichier en quittant : un dépôt
pendant qu'il tourne serait écrasé. La liste est plus fiable.

Chemins donnés tels qu'ils apparaissent dans `Settings`.

## À cocher en priorité

| Réglage | Où | Équivalent chez toi |
|---|---|---|
| **Smooth scrolling on new messages** | Appearance | `smoothScrollMs: 1500` — **désactivé par défaut** |
| **Enable plugins** | Plugins | indispensable au plugin — **désactivé par défaut** |
| **Show timestamps** → décocher | Appearance | retire l'heure à gauche des messages |

L'heure affichée devant chaque message se retire par ce seul décochage
(`/appearance/messages/showTimestamps`). Aucun code n'est nécessaire, et le
gain est réel sur une colonne étroite : autant de largeur rendue au texte.

Si tu préfères la garder mais plus discrète, `Timestamp format` accepte un
format court (`h:mm` par défaut, `H:mm` en 24 h).

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

## Highlights

`Settings → Highlights`, quatre onglets. C'est l'équivalent des « Custom
Highlights » de 7TV, en plus complet et sans règle à bricoler.

### Onglet « Badges » — l'équivalent direct de tes règles 7TV

Colonnes : **Name**, **Show In Mentions**, **Flash taskbar**, **Play sound**,
**Custom sound**, **Color**.

Le bouton « Choose badge » propose : Broadcaster, Admin, Staff, **Moderator**,
Lead Moderator, **VIP**, Founder, Subscriber, Verified, Predicted Blue,
Predicted Pink.

Deux possibilités que le menu ne montre pas, mais que le champ accepte :

- une **version** de badge, `subscriber/12` pour « abonné depuis 12 mois » ;
- une **liste**, `moderator,vip` pour une seule règle couvrant les deux.

### Onglet « Messages » — motifs et catégories intégrées

La première ligne est **ton propre pseudo**, ajoutée automatiquement. Viennent
ensuite des catégories prêtes à l'emploi, chacune avec sa couleur :

| Catégorie | À quoi ça correspond chez toi |
|---|---|
| **First Messages** | le « first-time chatter » de 7TV |
| **Subscriptions** | la teinte de tes notices d'abonnement (`compact.tintOpacity`) |
| **Watch Streaks** | les séries de visionnage |
| **Announcements** / **Colored Announcements** | les annonces de modération |
| **Highlights redeemed with Channel Points** | les messages mis en avant par points |
| **Subscribed Reply Threads** | les fils auxquels tu participes |
| **Whispers**, **AutoMod Caught Messages** | — |

Colonnes : **Pattern**, Show In Mentions, Flash taskbar, **Enable regex**,
**Case-sensitive**, Play sound, Custom sound, **Color**.

### Onglets « Users » et « Blacklisted Users »

`Users` colore par pseudo (mêmes colonnes que Messages).
`Blacklisted Users` fait l'inverse : il **coupe** tout highlight venant de
certains comptes — utile pour les bots qui déclencheraient tes motifs.

### Le détail qui compte : l'alpha

Ton `compact.tintOpacity: 0.15` se traduit ici par une couleur à **canal alpha
bas**. Le sélecteur de couleur de Chatterino a un curseur de transparence :
sans lui, la teinte écrase le message au lieu de le souligner. Vise 15 à 25 %.

### Un bonus que 7TV n'a pas

Chaque message relevé laisse une **marque de sa couleur dans la barre de
défilement** (`Message::getScrollBarHighlight`) : on repère une mention loin
au-dessus sans remonter. Réglable par `hideScrollbarHighlights`.

### Interaction avec le plugin

`reply.lineTint` est laissé à `nil` dans `init.lua` **exprès** : il écrirait
`highlight_color` sur le message et écraserait la couleur posée par tes règles.
Si tu utilises les highlights — et tu devrais — laisse-le désactivé.

## Divers utile

| Réglage | Où | Pourquoi |
|---|---|---|
| **Scrollback limit** | Misc | plus haut = le plugin retrouve plus souvent le message parent d'une réponse |
| Taille et police du chat | Appearance → Font | un seul réglage global, pas de taille par type de message |
