<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <b>Français</b> ·
  <a href="README.hi.md">हिन्दी</a>
</p>

# Lumi : la lumière au cœur de votre Mac

Demandez, et Lumi le trouve dans le noir, fait le travail et vous montre la réponse.

Lumi by Loomtable répond là où vous travaillez. Dans n'importe quelle app, touchez une seule touche, puis posez votre question à voix haute ou tapez-la. Lumi regarde ce qui est devant vous, à ce moment-là seulement : la fenêtre au premier plan, votre sélection, le dépôt derrière un port localhost, le dossier du terminal. Il trouve vos fichiers, travaille sur votre Mac et utilise les outils que vous avez connectés. Vous entendez une réponse courte, avec une fiche quand une image aide. Les modifications que Lumi propose attendent votre accord.

La réflexion se fait avec votre propre configuration : votre connexion, vos serveurs MCP, votre CLAUDE.md, vos skills.

Des réponses faites pour vous : une ligne, une image quand elle aide, et un anneau sur l'endroit exact.

Conçu pour le travail que vous faites. Fondateurs, designers, analystes, rédacteurs, étudiants, développeurs et tous les autres.

**Sur votre écran, à votre écoute. Trouve vos fichiers et travaille dessus. S'intègre à vos outils. Gratuit, local et open source.**

- **Site web :** [lumi.loomtable.com](https://lumi.loomtable.com)
- **Téléchargement :** [dernière version](https://github.com/loomtable/lumi/releases/latest) (DMG, voir [Installation](#installation))
- **Prix et licence :** gratuit, GPL-3.0
- **Conçu par :** [Loomtable](https://loomtable.com), un studio de produits nativement IA. Propulsé par Claude.

## Configuration requise

- macOS 26 sur Apple Silicon (M1 ou ultérieur). Les Mac Intel et les versions antérieures de macOS ne sont pas pris en charge.
- L'agent en ligne de commande `claude` d'Anthropic, version 2.1.312 ou ultérieure, installé et connecté.
- 16 Go de mémoire recommandés. Avec 8 Go, les réponses peuvent être plus lentes quand beaucoup d'apps sont ouvertes.

## Comment ça marche

1. Touchez la touche Lumi (Option droite, ⌥, par défaut) et posez votre question. Touchez-la à nouveau pour envoyer, ou maintenez-la pendant que vous parlez. Touchez-la deux fois pour taper votre question.
2. Lumi regarde ce qui est devant vous (voir ci-dessous) et transmet votre question à votre agent `claude`.
3. Vous entendez une réponse d'une ligne. Quand une image aide, une fiche s'affiche à côté de ce que vous regardiez. Appuyez sur Échap, cliquez ailleurs ou changez d'app pour la fermer.

Les questions démarrent en Quick, sur un modèle rapide. Quand une question demande des fichiers, des commandes ou le navigateur, Quick la passe à Deep, sur un modèle plus puissant, et vous le signale. Commencez votre question par « go deep » pour aller directement en Deep, ou par « research » pour lancer une longue tâche en arrière-plan. Settings › Models définit le modèle de chaque voie et le routage (Auto, Always Quick ou Always Deep). <!-- OWNER: confirmer si les libellés de l'app et les mots déclencheurs « go deep » et « research » restent en anglais pour un utilisateur francophone -->

## Ce que Lumi voit et envoie

Lumi ne regarde que lorsque vous l'appelez. Il lit alors :

- l'app et la fenêtre au premier plan ;
- le texte sélectionné, l'élément sous le pointeur et si le champ actif est modifiable ;
- ce que l'app au premier plan affiche, quand Lumi peut le déterminer : le dossier et la commande d'un terminal, le port et le dossier d'un serveur de développement local, le projet et le fichier d'un éditeur, le canal et le fil d'une messagerie, un dossier du Finder et sa sélection ;
- les apps utilisées récemment et la disposition de vos écrans ;
- une capture de la fenêtre au premier plan, ou de l'écran.

Il ne regarde jamais les gestionnaires de mots de passe ni les apps que vous bloquez dans Settings › Privacy. Leurs fenêtres sont exclues des captures. Il ne lit jamais le texte des champs de mot de passe, même si les points d'un champ peuvent apparaître sur une capture. Les secrets présents dans les lignes de commande et les adresses, comme les tokens et les clés, sont retirés avant tout envoi.

Votre question, ce contexte et la capture vont à **votre propre agent `claude`**, qui les envoie à Anthropic pour obtenir la réponse, sous votre compte Claude. Lumi lui-même ne se connecte à Internet que dans ces cas :

- quand vous activez la voix, il télécharge un petit détecteur de silence depuis Hugging Face (environ 1 Mo, une seule fois) ;
- seulement si vous les choisissez, à la prise en main ou dans Settings › Voice, il télécharge la reconnaissance vocale Parakeet (environ 466 Mo) ou la voix Kokoro (environ 437 Mo) depuis Hugging Face, une fois chacune ;
- si vous activez la voix ElevenLabs, le texte de la réponse est envoyé à ElevenLabs pour être lu.

Les serveurs MCP ajoutés dans Settings › Connections s'exécutent dans votre agent `claude` et communiquent avec leurs propres services, comme tout autre serveur MCP.

Par défaut, Lumi écoute et parle avec la reconnaissance vocale et la voix du Mac, donc rien de volumineux à télécharger. macOS peut ajouter ses fichiers vocaux anglais la première fois. La reconnaissance vocale et toutes les voix sauf ElevenLabs s'exécutent sur votre Mac. Votre enregistrement vocal ne quitte jamais votre Mac. Les captures sont conservées sur votre Mac 24 heures au maximum. Settings › Privacy permet de réduire ce délai à 6 heures ou 1 heure. Le journal de trace est désactivé par défaut. Une fois activé, il enregistre les durées, les types d'événements et les résultats, jamais ce que vous avez dit ou vu, et les conserve 7 jours.

## Installation

Lumi est distribué sous forme de DMG sur GitHub Releases. Il n'est pas encore sur le Mac App Store ni sur Homebrew.

1. Téléchargez `Lumi-<version>.dmg` et `Lumi-<version>.dmg.sha256` depuis la [page Releases](https://github.com/loomtable/lumi/releases/latest). Pour vérifier le téléchargement, lancez `shasum -a 256 -c Lumi-<version>.dmg.sha256` dans le dossier où vous avez enregistré les deux fichiers.
2. Ouvrez l'image disque et faites glisser Lumi dans Applications.
3. Lumi n'est pas encore signé avec un Apple Developer ID, donc macOS bloque le premier lancement. Ouvrez Lumi une fois et fermez l'avertissement. Ouvrez ensuite Réglages Système › Confidentialité et sécurité, faites défiler vers le bas, cliquez sur **Ouvrir quand même** à côté de Lumi, puis confirmez avec votre mot de passe ou Touch ID. Lumi s'ouvre ensuite normalement. <!-- OWNER: confirmer les libellés exacts « Réglages Système », « Confidentialité et sécurité » et « Ouvrir quand même » sur macOS 26 en français -->

   Si vous êtes à l'aise avec le Terminal, cette commande fait la même chose, pour cette app uniquement :
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. Suivez la prise en main : la touche Lumi, les autorisations et la voix.

Pour mettre à jour, téléchargez la nouvelle version depuis la [page Releases](https://github.com/loomtable/lumi/releases/latest) et remplacez Lumi dans Applications. Vos réglages, conversations et autorisations sont conservés.

## Autorisations

Lumi les demande pendant la prise en main. Chacune ouvre le bon endroit dans Réglages Système :

- **Surveillance de l'entrée** (obligatoire) : pour détecter la touche Lumi. Lumi n'enregistre jamais ce que vous tapez.
- **Accessibilité** (obligatoire) : pour lire votre sélection, insérer du texte et fermer les fiches avec Échap.
- **Enregistrement de l'écran** (obligatoire) : pour la capture envoyée avec votre question.
- **Micro** (facultatif) : pour poser vos questions à voix haute. Sans lui, vous pouvez toujours les taper.
 <!-- OWNER: confirmer les noms exacts de ces listes dans Réglages Système sur macOS 26 en français -->

macOS n'applique Surveillance de l'entrée et Enregistrement de l'écran qu'après la réouverture de Lumi. Utilisez le bouton Quit & Reopen à côté de chacune. <!-- OWNER: confirmer le libellé de ce bouton dans l'app -->

## Compiler depuis les sources

```sh
Scripts/make-dev-cert.sh   # une fois : une identité de signature stable, pour que les autorisations survivent aux recompilations
Scripts/build-app.sh       # compile, signe et installe /Applications/Lumi.app
open -a Lumi
```

`make-dev-cert.sh` demande une fois votre mot de passe de session, pour approuver le certificat de signature de code. La première compilation peut demander si codesign peut utiliser la clé de développement créée par `make-dev-cert.sh` : choisissez Toujours autoriser. `INSTALL=0 Scripts/build-app.sh` compile `dist/Lumi.app` sans l'installer. Lancez les tests avec `Scripts/test.sh`.

L'icône de l'app nécessite Xcode (pour `actool`). Sans Xcode, la compilation utilise l'icône générique.

Ouvrez toujours Lumi depuis Applications, Spotlight ou le Finder, jamais depuis un terminal. Une copie lancée depuis un terminal emprunte les autorisations du terminal.

## Désinstallation

1. Si vous voulez aussi supprimer les enregistrements des conversations de Lumi gardés par votre agent `claude`, faites-le d'abord : dans Conversations, utilisez Forget sur chacune. Votre agent `claude` les conserve dans `~/.claude/projects/`, mêlés à vos propres sessions.
2. Quittez Lumi depuis son menu dans la barre des menus et faites glisser `/Applications/Lumi.app` dans la Corbeille.
3. Supprimez ses données :
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # conversations, rapports, modèles vocaux, copie du plugin
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # tokens de connexion enregistrés
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # captures d'écran
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # journal de trace
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # cache réseau, s'il existe
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # données de prononciation de la voix
   defaults delete com.loomtable.lumi                         # préférences
   ```
4. Si vous avez ajouté une clé ElevenLabs, ouvrez Trousseau d'accès, cherchez `com.loomtable.lumi.elevenlabs` et supprimez-la.
5. Si vous avez ajouté des serveurs MCP dans Settings › Connections, lancez `claude mcp list` pour les voir, puis supprimez chacun avec `claude mcp remove --scope user <name>`.
6. Facultatif : dans Réglages Système › Confidentialité et sécurité, sélectionnez Lumi dans chaque liste et cliquez sur −.

## Lumi face aux autres usages

| Si vous utilisez… | Ce que Lumi apporte |
| --- | --- |
| L'agent `claude` dans un terminal | Le même agent, depuis n'importe quelle app : une touche, votre voix et la fenêtre au premier plan comme contexte. Plus besoin de coller des captures ni d'expliquer où vous en êtes. |
| Une app de chat pour vos questions d'IA | Des réponses issues de votre propre configuration (dépôt, CLAUDE.md, serveurs MCP, skills), sans compte ni mémoire à part, affichées à côté de ce que vous regardez. |
| Un assistant qui enregistre votre écran toute la journée | Lumi ne regarde que lorsque vous appuyez sur la touche. Les captures restent sur votre Mac 24 heures au maximum. |

## FAQ

**Qu'est-ce que Lumi ?**
Une app gratuite et open source pour la barre des menus de macOS. Dans n'importe quelle app, vous touchez une touche et vous posez votre question à voix haute ou par écrit. Votre propre agent `claude` répond à partir de ce qui est à l'écran, et Lumi énonce une réponse courte, avec une fiche quand une image aide.

**Lumi est-il gratuit ?**
Oui. Lumi est gratuit et open source, sous licence GPL-3.0. Vos questions passent par votre propre agent `claude`, donc elles sont décomptées de votre propre forfait Claude ou de votre usage de l'API.

**Faut-il l'agent `claude` d'Anthropic ?**
Oui : version 2.1.312 ou ultérieure, installé et connecté. Lumi l'exécute sur votre Mac. Lumi n'a ni connexion ni serveurs à lui.

**Lumi est-il conçu par Anthropic ?**
Non. Lumi est conçu par Loomtable. Il est propulsé par Claude, via votre agent `claude`, et n'est ni conçu par Anthropic ni affilié à Anthropic.

**Qu'est-ce que Lumi envoie, et où ?**
Votre question, le contexte que Lumi a lu dans l'app au premier plan et une capture vont à votre agent `claude`, qui les envoie à Anthropic pour obtenir la réponse. Lumi n'a ni serveurs ni analytics. Voir [Ce que Lumi voit et envoie](#ce-que-lumi-voit-et-envoie).

**Lumi regarde-t-il mon écran en permanence ?**
Non. Il ne regarde que lorsque vous appuyez sur la touche Lumi. Il ignore les gestionnaires de mots de passe et les apps que vous bloquez dans Settings › Privacy.

**Puis-je l'utiliser sans parler ?**
Oui. Touchez deux fois la touche Lumi pour taper. L'autorisation Micro est facultative.

**Lumi peut-il modifier des fichiers ou lancer des commandes ?**
Lumi travaille via votre agent `claude` : il peut lire, exécuter et modifier sur votre Mac, et utiliser les outils que vous avez connectés. Les modifications que Lumi propose attendent votre accord, et le texte inséré n'est jamais envoyé à votre place.

**Fonctionne-t-il sur les Mac Intel, les anciennes versions de macOS, Windows ou Linux ?**
Non. Lumi nécessite macOS 26 sur Apple Silicon.

**Fonctionne-t-il hors ligne ?**
Non. La reconnaissance vocale et la voix par défaut s'exécutent sur votre Mac, mais les réponses viennent de Claude via votre agent `claude`, qui a besoin d'Internet.

**Pourquoi macOS bloque-t-il le premier lancement ?**
Lumi n'est pas encore signé avec un Apple Developer ID. Ouvrez-le une fois, puis cliquez sur Ouvrir quand même dans Réglages Système › Confidentialité et sécurité. Voir [Installation](#installation).

## Organisation du dépôt

| Chemin | Contenu |
| --- | --- |
| `Sources/BuddyCore` | Types de valeur partagés : paquet de contexte, bloc de réponse, modes et modèles |
| `Sources/BuddyKeys` | Gestes de la touche Lumi, gestion ciblée d'Échap, combinaisons de touches |
| `Sources/BuddyContext` | Construit le paquet de contexte à partir de l'app au premier plan |
| `Sources/BuddyAct` | Insère du texte dans votre app |
| `Sources/BuddyVoice` | Micro, reconnaissance vocale, synthèse vocale, indicateurs de niveau, sons |
| `Sources/BuddyOverlay` | Pastille, puce, fiche, capsule, placement, animations |
| `Sources/BuddyBridge` | Exécute votre agent `claude` et analyse son flux |
| `Sources/BuddyConversations` | Index des conversations et fichiers de session de l'agent |
| `Sources/BuddyTrace` | Le journal de trace facultatif |
| `Sources/BuddyApp` | Le coordinateur qui traite chaque question, l'environnement d'exécution de l'app, la migration depuis les versions antérieures |
| `Sources/BuddyCompanion` | Réglages, prise en main, Conversations |
| `Sources/Lumi` | Coque de l'app dans la barre des menus |
| `buddy-plugin/` | Le plugin de l'agent qui fait la réflexion ; il est livré dans l'app |
| `App/` | Info.plist, entitlements et l'icône de l'app (Icon Composer) |
| `Scripts/` | Scripts de compilation, de test et de signature |
| `Scenarios/`, `Tools/` | Scénarios de réponse et outils qui les vérifient |

## Licence

GPL-3.0. © 2026 Loomtable. Propulsé par Claude. « Claude » et les noms de produits associés sont des marques d'Anthropic. Lumi n'est ni conçu par Anthropic ni affilié à Anthropic.

Dites-nous ce que Lumi a fait pour votre semaine : [hello@loomtable.com](mailto:hello@loomtable.com).

**Gratuit, open source et local. Fonctionne avec votre Claude Code, sur votre Mac.**
