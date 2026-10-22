<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <b>Deutsch</b> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.hi.md">हिन्दी</a>
</p>

# Lumi: Das Licht in deinem Mac.

Frag, und Lumi findet es im Dunkeln, erledigt die Arbeit und zeigt dir die Antwort.

Du steckst in einer Tabelle, einem Vertrag oder einem Thread. Du tippst in einer beliebigen App auf eine Taste, standardmäßig die rechte Option-Taste (⌥), und stellst deine Frage laut. Du kannst auch doppelt tippen und schreiben. Lumi by Loomtable sieht sich genau in diesem Moment an, was vor dir liegt, zum Beispiel:

- das Fenster im Vordergrund
- deine Auswahl
- das Repo hinter einem localhost-Port
- den Ordner im Terminal

Lumi gibt die Frage an dein eigenes Setup weiter: dein Login, deine MCP-Server, deine CLAUDE.md, deine Skills. Du hörst eine kurze gesprochene Antwort. Wenn ein Bild hilft, erscheint dazu eine Karte. Änderungen, die Lumi vorschlägt, warten auf dein OK.

Antworten, für dich gebaut: eine Zeile, ein Bild, wenn es hilft, und ein Ring genau an der richtigen Stelle. Kein Textberg. Lumi zeigt auf die Antwort.

Ob Gründung, Produkt, Design, Analyse, Forschung, Marketing, Vertrieb, Schreiben, Beratung, Betrieb, Studium oder Entwicklung: gebaut für die Arbeit, die du machst.

**Sieht deinen Bildschirm, hört dir zu. Findet deine Dateien und arbeitet damit. Arbeitet mit deinen Tools. Kostenlos, lokal und Open Source.**

- **Website:** [lumi.loomtable.com](https://lumi.loomtable.com)
- **Download:** [aktuelles Release](https://github.com/loomtable/lumi/releases/latest) (DMG, siehe [Installation](#installation))
- **Preis und Lizenz:** kostenlos, GPL-3.0
- **Von:** [Loomtable](https://loomtable.com), einem KI-nativen Produktstudio. Powered by Claude.

**Kostenlos, Open Source und lokal. Funktioniert mit deinem Claude Code, auf deinem Mac.**

## Voraussetzungen

- **Mac:** macOS 26 auf Apple Silicon (M1 oder neuer). Intel-Macs und ältere macOS-Versionen werden nicht unterstützt.
- **Setup:** das Setup aus dem Satz oben, ab Version 2.1.259, installiert und angemeldet.
- **Arbeitsspeicher:** 16 GB werden empfohlen. Mit 8 GB können Antworten langsamer sein, wenn viele Apps offen sind.

## So funktioniert's
 <!-- OWNER: Lumi's own UI labels (Settings › Models, Settings › Privacy, Conversations, Forget, Quit & Reopen and so on) are kept in English here. Change them if the app ships a German UI. -->

1. **Fragen.** Tipp auf die Lumi-Taste (standardmäßig die rechte ⌥) und stell deine Frage.
   - Tipp noch einmal, um sie abzuschicken.
   - Oder halte die Taste gedrückt, solange du sprichst.
   - Tipp doppelt, um stattdessen zu schreiben.
2. **Lumi schaut hin.** Lumi sieht sich an, was vor dir liegt (siehe unten), und gibt deine Frage an dein Setup weiter.
3. **Die Antwort.** Du hörst eine Antwort in einer Zeile. Wenn ein Bild hilft, erscheint eine Karte neben dem, was du gerade angesehen hast. Mit Esc, einem Klick daneben oder einem App-Wechsel schließt du sie.

Einmal gefragt, und du hast den Dreh raus.

**Quick und Deep**

- Fragen starten in **Quick**, auf einem schnellen Modell.
- Braucht eine Frage Dateien, Befehle oder den Browser, gibt Quick sie an **Deep** weiter, auf einem stärkeren Modell. Lumi sagt dir, wenn das passiert.
- Beginnst du eine Frage mit „go deep“, geht sie direkt an Deep.
- Mit „research“ startest du einen langen Job im Hintergrund.
- Unter Settings › Models legst du das Modell für jede Spur fest, außerdem das Routing: Auto, Always Quick oder Always Deep.

## Was Lumi sieht und sendet

Lumi schaut nur hin, wenn du Lumi aufrufst. Dann liest Lumi:

- die App und das Fenster im Vordergrund;
- deinen markierten Text, das Element unter dem Mauszeiger und ob das aktive Feld bearbeitbar ist;
- was die App im Vordergrund zeigt, soweit Lumi das erkennen kann:
  - im Terminal den Ordner und den Befehl,
  - bei einem lokalen Dev-Server den Port und den Ordner,
  - im Editor das Projekt und die Datei,
  - im Chat den Kanal und den Thread,
  - im Finder den Ordner und die Auswahl;
- welche Apps du zuletzt benutzt hast und wie deine Displays angeordnet sind;
- einen Screenshot des Fensters im Vordergrund oder des ganzen Displays.

**Was Lumi auslässt**

- Passwortmanager und Apps, die du unter Settings › Privacy blockierst, sieht Lumi sich nie an. Ihre Fenster fehlen in Screenshots.
- Den Text in Passwortfeldern liest Lumi nie. Die Punkte eines Passwortfelds können aber auf einem Screenshot zu sehen sein.
- Geheimnisse in Befehlszeilen und Adressen, etwa Tokens und Keys, werden entfernt, bevor irgendetwas gesendet wird.

**Was an Anthropic geht**

Deine Frage, dieser Kontext und der Screenshot gehen an **dein eigenes Setup**. Es schickt sie unter deinem Claude-Konto an Anthropic, um die Frage zu beantworten.

**Wann Lumi selbst ins Internet geht**

Lumi verbindet sich nur für diese Dinge mit dem Internet:

- Wenn du die Sprachfunktion einschaltest, lädt Lumi einmalig einen kleinen Stille-Detektor von Hugging Face (etwa 1 MB).
- Nur wenn du sie auswählst, im Onboarding oder unter Settings › Voice, lädt Lumi je einmal von Hugging Face:
  - die Spracherkennung Parakeet (etwa 466 MB),
  - die Stimme Kokoro (etwa 437 MB).
- Wenn du die ElevenLabs-Stimme einschaltest, geht der Antworttext an ElevenLabs, damit er vorgelesen wird.

MCP-Server, die du unter Settings › Connections hinzufügst, laufen in deinem Setup und sprechen mit ihren eigenen Diensten, wie jeder andere MCP-Server auch.

**Was auf deinem Mac bleibt**

- Standardmäßig hört und spricht Lumi mit der Spracherkennung und der Stimme des Macs. Du musst also nichts Großes herunterladen. macOS lädt beim ersten Mal eventuell seine englischen Sprachdateien nach.
- Die Spracherkennung und jede Stimme außer ElevenLabs laufen auf deinem Mac.
- Deine Sprachaufnahme verlässt den Mac nie.
- Screenshots bleiben höchstens 24 Stunden auf deinem Mac. Unter Settings › Privacy kannst du das auf 6 Stunden oder 1 Stunde verkürzen.
- Das Trace-Log ist standardmäßig aus. Ist es an, speichert es Zeiten, Ereignistypen und Ergebnisse, nie das, was du gesagt oder gesehen hast. Es hält 7 Tage.

## Installation

Lumi kommt als DMG über GitHub Releases. Im Mac App Store und über Homebrew gibt es Lumi noch nicht.

1. **Herunterladen.** Lade `Lumi-<version>.dmg` und `Lumi-<version>.dmg.sha256` von der [Releases-Seite](https://github.com/loomtable/lumi/releases/latest).
   Zum Prüfen des Downloads führst du in dem Ordner, in dem beide Dateien liegen, diesen Befehl aus: `shasum -a 256 -c Lumi-<version>.dmg.sha256`
2. **Installieren.** Öffne das Disk-Image und zieh Lumi in den Ordner „Programme“.
3. **Ersten Start freigeben.** Lumi ist noch nicht mit einer Apple Developer ID signiert, deshalb stoppt macOS den ersten Start.
   - Öffne Lumi einmal und schließ die Warnung.
   - Öffne Systemeinstellungen › Datenschutz & Sicherheit und scroll nach unten.
   - Klick neben Lumi auf **Dennoch öffnen** (englisch: Open Anyway) und bestätige mit deinem Passwort oder Touch ID. <!-- OWNER: confirm the German labels on macOS 26. -->
   - Danach öffnet sich Lumi ganz normal.

   Wenn du dich im Terminal wohlfühlst, erledigt das hier dasselbe, nur für diese App:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. **Onboarding.** Folge dem Onboarding: Lumi-Taste, Berechtigungen und Stimme.

**Aktualisieren:** Lade das neue Release von der [Releases-Seite](https://github.com/loomtable/lumi/releases/latest) und ersetze Lumi im Ordner „Programme“. Deine Einstellungen, Unterhaltungen und Berechtigungen bleiben erhalten.

## Berechtigungen

Lumi fragt im Onboarding nach diesen Berechtigungen. Jede öffnet die passende Stelle in den Systemeinstellungen. <!-- OWNER: confirm the German macOS 26 names for these lists. -->

- **Eingabeüberwachung** (erforderlich): damit Lumi die Lumi-Taste bemerkt. Lumi zeichnet nie auf, was du tippst.
- **Bedienungshilfen** (erforderlich): um deine Auswahl zu lesen, Text einzufügen und Karten mit Esc zu schließen.
- **Bildschirmaufnahme** (erforderlich): für den Screenshot, der mit deiner Frage gesendet wird.
- **Mikrofon** (optional): um laut zu fragen. Ohne diese Berechtigung kannst du jederzeit schreiben.

macOS wendet Eingabeüberwachung und Bildschirmaufnahme erst an, nachdem Lumi neu gestartet wurde. Nutze dafür den Button Quit & Reopen neben der jeweiligen Berechtigung.

## Aus dem Quellcode bauen

```sh
Scripts/make-dev-cert.sh   # einmalig: eine stabile Signier-Identität, damit Berechtigungen Rebuilds überstehen
Scripts/build-app.sh       # baut, signiert und installiert /Applications/Lumi.app
open -a Lumi
```

- **Passwort:** `make-dev-cert.sh` fragt einmal nach deinem Login-Passwort, um dem Zertifikat für das Code-Signing zu vertrauen.
- **Signierschlüssel:** Beim ersten Build fragt macOS eventuell, ob codesign den Entwicklerschlüssel verwenden darf, den `make-dev-cert.sh` angelegt hat. Wähle „Immer erlauben“.
- **Ohne Installation bauen:** `INSTALL=0 Scripts/build-app.sh` baut `dist/Lumi.app`, ohne die App zu installieren.
- **Tests:** Die Tests startest du mit `Scripts/test.sh`.
- **App-Icon:** Für das App-Icon brauchst du Xcode (wegen `actool`). Ohne Xcode nutzt der Build das generische Icon.

Öffne Lumi immer über „Programme“, Spotlight oder den Finder, nie aus einem Terminal. Eine aus dem Terminal gestartete Kopie leiht sich die Berechtigungen des Terminals.

## Deinstallieren

1. **Unterhaltungen löschen (optional).** Wenn auch die Aufzeichnungen deines Setups zu Lumis Unterhaltungen verschwinden sollen, lösch sie zuerst: Nutze unter Conversations bei jeder Unterhaltung Forget. Dein Setup speichert sie unter `~/.claude/projects/`, gemischt mit deinen eigenen Sessions.
2. **App entfernen.** Beende Lumi über das Menü in der Menüleiste und zieh `/Applications/Lumi.app` in den Papierkorb.
3. **Daten löschen:**
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # Unterhaltungen, Berichte, Sprachmodelle, Plugin-Kopie
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # gespeicherte Verbindungs-Tokens
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # Screenshots
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # Trace-Log
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # Netzwerk-Cache, falls vorhanden
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # Aussprachedaten der Stimme
   defaults delete com.loomtable.lumi                         # Einstellungen
   ```
4. **ElevenLabs-Key entfernen.** Falls du einen ElevenLabs-Key hinzugefügt hast: Öffne die Schlüsselbundverwaltung, such nach `com.loomtable.lumi.elevenlabs` und lösch den Eintrag. <!-- OWNER: confirm the app name on German macOS 26. -->
5. **MCP-Server entfernen.** Falls du unter Settings › Connections MCP-Server hinzugefügt hast: Mit `claude mcp list` siehst du sie. Entfern jeden mit `claude mcp remove --scope user <name>`.
6. **Berechtigungen entfernen (optional).** Wähle in Systemeinstellungen › Datenschutz & Sicherheit in jeder Liste Lumi aus und klick auf −.

## Was Lumi dazu bringt

| Wenn du … nutzt | Das bringt Lumi dazu |
| --- | --- |
| dein Setup im Terminal | Dasselbe Setup, aus jeder App. Eine Taste, deine Stimme und das Fenster im Vordergrund als Kontext, damit du keine Screenshots einfügen oder erklären musst, wo du gerade bist. |
| eine Chat-App für KI-Fragen | Antworten aus deinem eigenen Setup (Repo, CLAUDE.md, MCP-Server, Skills) statt aus einem separaten Konto mit eigenem Gedächtnis. Sie erscheinen neben dem, was du gerade ansiehst. |
| einen Assistenten, der den ganzen Tag deinen Bildschirm aufzeichnet | Lumi schaut nur hin, wenn du die Taste drückst. Screenshots bleiben höchstens 24 Stunden auf deinem Mac. |

## FAQ

**Was ist Lumi?**
Eine kostenlose Open-Source-App für die macOS-Menüleiste. Du tippst in einer beliebigen App auf eine Taste und fragst laut oder schreibst. Dein eigenes Setup beantwortet die Frage mit dem, was auf deinem Bildschirm ist. Lumi spricht eine kurze Antwort und zeigt eine Karte, wenn ein Bild hilft.

**Ist Lumi kostenlos?**
Ja. Lumi ist kostenlos und Open Source unter GPL-3.0. Deine Fragen laufen über dein eigenes Setup und zählen deshalb zu deinem eigenen Claude-Plan oder deiner API-Nutzung.

**Was brauche ich außer Lumi?**
Das Setup aus den [Voraussetzungen](#voraussetzungen), ab Version 2.1.259, installiert und angemeldet. Lumi startet es auf deinem Mac und hat selbst weder Login noch Server.

**Ist Lumi von Anthropic?**
Nein. Lumi wird von Loomtable entwickelt. Lumi ist powered by Claude, über dein eigenes Setup, und wird nicht von Anthropic entwickelt und ist nicht mit Anthropic verbunden.

**Was sendet Lumi, und wohin?**
Deine Frage, der Kontext aus der App im Vordergrund und ein Screenshot gehen an dein Setup. Es schickt sie an Anthropic, um die Frage zu beantworten. Lumi hat keine Server und keine Analytics. Siehe [Was Lumi sieht und sendet](#was-lumi-sieht-und-sendet).

**Beobachtet Lumi ständig meinen Bildschirm?**
Nein. Lumi schaut nur hin, wenn du die Lumi-Taste drückst. Passwortmanager und Apps, die du unter Settings › Privacy blockierst, lässt Lumi aus.

**Kann ich Lumi ohne Sprechen nutzen?**
Ja. Tipp doppelt auf die Lumi-Taste, um zu schreiben. Die Mikrofon-Berechtigung ist optional.

**Kann Lumi Dateien ändern oder Befehle ausführen?**
Lumi arbeitet über dein Setup. Lumi kann auf deinem Mac lesen, ausführen und bearbeiten und die Tools nutzen, die du verbunden hast. Änderungen, die Lumi vorschlägt, warten auf dein OK. Eingefügter Text wird nie für dich abgeschickt.

**Läuft Lumi auf Intel-Macs, älteren macOS-Versionen, Windows oder Linux?**
Nein. Lumi braucht macOS 26 auf Apple Silicon.

**Funktioniert Lumi offline?**
Nein. Spracherkennung und die Standardstimme laufen auf deinem Mac. Die Antworten kommen aber von Claude über dein Setup, und das braucht eine Internetverbindung.

**Warum blockiert macOS den ersten Start?**
Lumi ist noch nicht mit einer Apple Developer ID signiert. Öffne Lumi einmal und klick dann in Systemeinstellungen › Datenschutz & Sicherheit auf „Dennoch öffnen“. Siehe [Installation](#installation).

## Aufbau des Repos

| Pfad | Inhalt |
| --- | --- |
| `Sources/BuddyCore` | Gemeinsame Werttypen: Kontextpaket, Antwortblock, Modi und Modelle |
| `Sources/BuddyKeys` | Gesten der Lumi-Taste, begrenztes Esc-Handling, Tastenkombinationen |
| `Sources/BuddyContext` | Baut das Kontextpaket aus der App im Vordergrund |
| `Sources/BuddyAct` | Fügt Text in deine App ein |
| `Sources/BuddyVoice` | Mikrofon, Spracherkennung, Sprachausgabe, Pegel, Sounds |
| `Sources/BuddyOverlay` | Pill, Chip, Karte, Kapsel, Platzierung, Animation |
| `Sources/BuddyBridge` | Startet dein Setup und parst dessen Stream |
| `Sources/BuddyConversations` | Index der Unterhaltungen und Session-Dateien deines Setups |
| `Sources/BuddyTrace` | Das optionale Trace-Log |
| `Sources/BuddyApp` | Der Koordinator, der jede Frage ausführt, App-Runtime, Migration von Daten älterer Versionen |
| `Sources/BuddyCompanion` | Einstellungen, Onboarding, Conversations |
| `Sources/Lumi` | Hülle der Menüleisten-App |
| `buddy-plugin/` | Das Plugin für dein Setup, das das Denken übernimmt. Es wird mit der App ausgeliefert. |
| `App/` | Info.plist, Entitlements und das App-Icon (Icon Composer) |
| `Scripts/` | Build-, Test- und Signier-Skripte |
| `Scenarios/`, `Tools/` | Antwortszenarien und die Tools, die sie prüfen |

## Kontakt

Erzähl uns, was Lumi für deine Woche getan hat: hello@loomtable.com. Quellcode: [github.com/loomtable/lumi](https://github.com/loomtable/lumi).

## Lizenz

GPL-3.0. © 2026 Loomtable. Powered by Claude. „Claude“ und die zugehörigen Produktnamen sind Marken von Anthropic. Lumi wird nicht von Anthropic entwickelt und ist nicht mit Anthropic verbunden.
