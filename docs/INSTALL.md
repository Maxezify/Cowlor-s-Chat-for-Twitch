# Installation

Windows uniquement — le remplacement du chat Twitch par Chatterino n'existe que là.

## Le modèle : quatre couches, deux nous appartiennent

| | Quoi | Qui |
|---|---|---|
| 1 | **Chatterino7** — le client de chat | SevenTV |
| 2 | **Chatterino Native Host** — l'extension qui fait la superposition | Chatterino |
| 3 | **Ce plugin + les réglages** | nous |
| 4 | Extension d'extinction du chat Twitch | nous, plus tard |

On n'installe pas « une application » : deux choses qui existent déjà, puis nos
fichiers dans deux dossiers.

## ⚠️ À lire avant de commencer

**Chatterino7 et Chatterino2 partagent le même dossier de données.**

Le `main.cpp` de Chatterino7 appelle `setApplicationName("chatterino")` —
identique à l'amont — et `Paths.cpp` en dérive `%APPDATA%\Chatterino2\` sous
Windows. Les deux applications se partagent donc `Settings\`, `Plugins\`,
`Themes\`, `Logs\`.

Si Chatterino2 est déjà installé : **sauvegarde
`%APPDATA%\Chatterino2\Settings\settings.json`** avant d'aller plus loin. En
pratique, choisis-en un des deux, pas les deux.

## Étapes

### 1. Chatterino7 — build nightly

**La v7.5.5 stable ne convient pas.** Elle n'expose ni
`Channel:on_message_appended` ni `c2.windows` : sans eux, aucun moyen de réagir à
l'arrivée d'un message ni de découvrir les canaux ouverts. Le plugin s'y charge
mais reste en veille, et écrit pourquoi dans la console.

Prendre donc le [build nightly](https://github.com/SevenTV/chatterino7/releases/tag/nightly-build)
(`Chatterino7TV.Nightly.Installer.exe`), puis **le lancer au moins une fois**.

Pour savoir si un build convient : `Settings → About` donne la date de
compilation et le commit. Le numéro de version affiché est celui de l'amont dont
le nightly dérive, pas le sien — un nightly « 2.5.5 » de septembre 2026 est bien
plus récent que le tag v7.5.5.

SevenTV marque ce build comme expérimental. C'est la contrainte du projet en
l'état, pas une préférence.

Ce premier lancement n'est pas facultatif : c'est Chatterino qui inscrit l'hôte
de messagerie native dans le registre
(`HKCU\Software\Google\Chrome\NativeMessagingHosts\com.chatterino.chatterino`,
et l'équivalent Mozilla). Sans lui, l'extension n'a personne à qui parler.

### 2. Compte Twitch

`Settings → Accounts → Add`.

### 3. Extension officielle

Installer **Chatterino Native Host** depuis le Chrome Web Store ou AMO, puis
cocher **Replace Twitch chat** dans sa popup.

### 4. Le plugin

Copier le dossier `plugin/` de ce dépôt vers :

```
%APPDATA%\Chatterino2\Plugins\CowlorsChat\
```

Le dossier doit contenir `init.lua` **et** `info.json` — Chatterino refuse de
charger un plugin auquel il manque l'un des deux. Le **nom du dossier** est
l'identité du plugin : ne le renomme pas après coup, Chatterino le perdrait de
vue dans sa liste de plugins activés.

### 5. Activer

Dans Chatterino7 :

1. `Settings → Plugins` → cocher **Enable plugins** (désactivé par défaut).
2. Activer **Cowlor's Chat** dans la liste.
3. Redémarrer Chatterino7.

### 6. Les réglages complémentaires

Voir [`../presets/settings.md`](../presets/settings.md). Le plus important, parce
qu'il est **désactivé par défaut** et que c'est l'équivalent de ton
`smoothScrollMs` : `Settings → Appearance → Smooth scrolling on new messages`.

## À vérifier au premier lancement

Ce plugin n'a jamais tourné dans un vrai Chatterino. Voici ce qu'il faut
regarder, dans l'ordre.

**0. Lance `/cowlors` dans le chat.** C'est le point de départ de tout
diagnostic : la commande dit la version chargée, les canaux branchés, et combien
de réponses le plugin sait repérer dans ce qui est déjà affiché.

**Dans la fenêtre superposée au navigateur, cette commande est obligatoire**,
une fois par chaîne : le balayage automatique ne voit pas cette fenêtre (voir le
README). Si le « … » persiste, c'est la première chose à essayer.

**1. Le plugin se charge.** `Settings → Plugins` doit lister « Cowlor's Chat »
sans erreur. Sinon, la console de Chatterino donne la raison.

**2. Une citation longue s'affiche en entier.** Réponds à un message de plus
d'une ligne. Le « … » doit avoir disparu.

**3. Les emotes reviennent dans la citation.** Réponds à un message contenant
une emote 7TV. Elle doit apparaître dans la citation.

**4. Rien ne clignote.** Le plugin remplace le message juste après son arrivée.
`on_message_appended` est synchrone, donc en théorie c'est la même image — mais
c'est exactement le genre de chose qui ne se vérifie qu'à l'œil, sur un chat
rapide. **C'est le point qui déciderait de tout arrêter.**

**5. Le coût en performance.** Reconstruire chaque réponse a un prix. Sur une
grosse chaîne, compare l'usage processeur de Chatterino plugin activé et
désactivé. Il serait ironique de dégrader la seule chose qui motive la migration.

Pour du détail en console, passer `debug = true` dans le bloc `CONFIG` en haut de
`init.lua`.

## Désinstaller

Supprimer `%APPDATA%\Chatterino2\Plugins\CowlorsChat\` et redémarrer. Rien
d'autre n'est touché : le plugin ne demande aucune permission
(`FilesystemRead`, `Network`…) et n'écrit nulle part.
