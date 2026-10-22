<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <b>हिन्दी</b>
</p>

# Lumi: आपके Mac के अंदर की रोशनी।

पूछिए, और Lumi अँधेरे में भी उसे ढूँढ लेता है, काम कर देता है, और आपको जवाब दिखाता है।

Lumi by Loomtable एक मुफ़्त, open-source macOS voice assistant है। किसी भी app में एक key tap कीजिए और बोलकर या type करके पूछिए। जवाब उसी चीज़ को सामने रखकर बनता है जो आपकी screen पर है: front window, आपका selection, localhost port के पीछे का repo, terminal का folder। आपको एक छोटा spoken जवाब सुनाई देता है, और जब picture से बात साफ़ हो, तो एक card भी दिखता है। Lumi जो भी बदलाव propose करता है, वह आपके OK का इंतज़ार करता है।

सोचने का काम आपका अपना harness करता है। Harness वह coding agent है जो आपने पहले से install और sign in किया है, और उसका नाम नीचे दिया है। वह आपके setup के साथ काम करता है: आपका login, आपके MCP servers, आपका CLAUDE.md।

आपके लिए बने जवाब: एक line, जब मदद करे तो एक picture, और ठीक उसी जगह पर एक ring।

आपके काम के लिए बना। Founders, designers, analysts, writers, students, developers और हर वह इंसान जो इनके बीच कहीं है।

**आपकी screen पर, आपकी बात सुनता है। आपकी files ढूँढता है और उन पर काम करता है। आपके tools के साथ जुड़ता है। मुफ़्त, local और open source।**

- **Website:** [lumi.loomtable.com](https://lumi.loomtable.com)
- **Download:** [latest release](https://github.com/loomtable/lumi/releases/latest) (DMG, [Install](#install) देखें)
- **Price और license:** मुफ़्त, GPL-3.0
- **बनाया है:** [Loomtable](https://loomtable.com) ने, जो एक AI-native product studio है। Powered by Claude.

**मुफ़्त, open source और local। आपके Claude Code (2.1.259 या नया, installed और signed in) के साथ, आपके Mac (macOS 26, Apple Silicon) पर काम करता है।**

## Requirements

- Apple Silicon (M1 या नया) पर macOS 26। Intel Macs और पुराने macOS versions supported नहीं हैं।
- ऊपर बताया harness, version 2.1.259 या नया, installed और signed in।
- 16 GB memory recommended है। 8 GB पर, अगर बहुत से apps खुले हों, तो जवाब धीमे आ सकते हैं।

## यह कैसे काम करता है

1. Lumi key tap कीजिए और अपना सवाल पूछिए। Default key right ⌥ (right Option) है। भेजने के लिए दोबारा tap कीजिए, या बोलते समय key दबाए रखिए। Type करना हो तो key को double-tap कीजिए।
2. Lumi देखता है कि आपके सामने क्या है (नीचे देखें) और आपका सवाल harness को सौंप देता है।
3. आपको एक line का जवाब सुनाई देता है। जब picture से मदद मिले, तो आप जिस चीज़ को देख रहे थे उसके पास एक card दिखता है। उसे बंद करने के लिए Esc दबाइए, कहीं और click कीजिए या app बदलिए।

सवाल पहले Quick में, एक तेज़ model पर शुरू होते हैं। जब किसी सवाल के लिए files, commands या browser चाहिए, तो Quick उसे Deep को सौंप देता है, जो एक ज़्यादा ताक़तवर model पर चलता है। ऐसा होने पर Lumi आपको बता देता है। सीधे Deep में जाने के लिए सवाल "go deep" से शुरू कीजिए। लंबा background job शुरू करने के लिए "research" से शुरू कीजिए। Settings › Models में हर lane का model और routing (Auto, Always Quick या Always Deep) सेट होता है।

<a id="what-it-sees-and-sends"></a>

## यह क्या देखता है और क्या भेजता है

Lumi सिर्फ़ तभी देखता है जब आप उसे बुलाते हैं। तब यह पढ़ता है:

- सामने वाला app और window;
- आपका selected text, pointer के नीचे वाला element, और यह कि focused field editable है या नहीं;
- सामने वाला app क्या दिखा रहा है, जहाँ Lumi यह पहचान सके: terminal का folder और command, local dev server का port और folder, editor का project और file, chat का channel और thread, Finder का folder और उसका selection;
- आपने हाल में कौन-से apps इस्तेमाल किए, और आपके displays का layout;
- front window का screenshot, या display का।

यह password managers को या उन apps को कभी नहीं देखता जिन्हें आप Settings › Privacy में block करते हैं। उनकी windows screenshots से बाहर रखी जाती हैं। यह password fields का text कभी नहीं पढ़ता, हालाँकि किसी field के dots screenshot में दिख सकते हैं। Command lines और addresses में मौजूद secrets, जैसे tokens और keys, कुछ भी भेजे जाने से पहले हटा दिए जाते हैं।

आपका सवाल, यह context और screenshot **आपके अपने harness** को जाते हैं। वह इन्हें आपके Claude account के तहत जवाब के लिए Anthropic को भेजता है। Lumi ख़ुद सिर्फ़ इन कामों के लिए internet से जुड़ता है:

- जब आप voice on करते हैं, तो यह Hugging Face से एक छोटा silence detector download करता है (लगभग 1 MB, एक बार)।
- सिर्फ़ अगर आप onboarding या Settings › Voice में इन्हें चुनें, तो यह Hugging Face से Parakeet speech-to-text (लगभग 466 MB) या Kokoro voice (लगभग 437 MB) download करता है, हर एक को एक बार।
- अगर आप ElevenLabs voice on करते हैं, तो जवाब का text बोले जाने के लिए ElevenLabs को जाता है।

Settings › Connections में जोड़े गए MCP servers आपके harness के अंदर चलते हैं और अपनी-अपनी services से बात करते हैं, जैसे कोई भी दूसरा MCP server करता है।

Default रूप से Lumi Mac की अपनी speech recognition और voice से सुनता और बोलता है, इसलिए कुछ बड़ा download नहीं करना पड़ता। पहली बार macOS अपनी English speech files जोड़ सकता है। Speech-to-text और ElevenLabs को छोड़कर हर voice आपके Mac पर चलती है। आपकी voice recording कभी आपके Mac से बाहर नहीं जाती। Screenshots आपके Mac पर ज़्यादा से ज़्यादा 24 घंटे रहते हैं, और Settings › Privacy में इसे 6 या 1 घंटे तक घटाया जा सकता है। Trace log default रूप से off है। On होने पर यह timings, event types और outcomes record करता है, पर कभी नहीं कि आपने क्या कहा या क्या देखा। यह log 7 दिन तक रहता है।

<a id="install"></a>

## Install

Lumi GitHub Releases पर DMG के रूप में आता है। यह अभी Mac App Store या Homebrew पर नहीं है।
 <!-- OWNER: System Settings labels नीचे English में हैं। Hindi में चल रहे macOS 26 पर asli labels confirm करें और ज़रूरत हो तो उन्हें साथ में जोड़ें। -->

1. [Releases page](https://github.com/loomtable/lumi/releases/latest) से `Lumi-<version>.dmg` और `Lumi-<version>.dmg.sha256` download कीजिए। Download check करने के लिए, जिस folder में दोनों files save की हैं वहाँ यह चलाइए: `shasum -a 256 -c Lumi-<version>.dmg.sha256`।
2. Disk image खोलिए और Lumi को Applications में drag कीजिए।
3. Lumi अभी Apple Developer ID से signed नहीं है, इसलिए macOS पहली launch को रोकता है। उसके बाद ये steps कीजिए:
   - Lumi को एक बार खोलिए और warning बंद कर दीजिए।
   - System Settings › Privacy & Security खोलिए और नीचे scroll कीजिए।
   - Lumi के आगे **Open Anyway** पर click कीजिए।
   - अपने password या Touch ID से confirm कीजिए।

   इसके बाद Lumi सामान्य रूप से खुलता है।

   अगर आप Terminal के साथ सहज हैं, तो यह command वही काम करती है, सिर्फ़ इसी app के लिए:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. Onboarding follow कीजिए: Lumi key, permissions और voice।

Update करने के लिए [Releases page](https://github.com/loomtable/lumi/releases/latest) से नया release download कीजिए और Applications में Lumi को replace कर दीजिए। आपकी settings, conversations और permissions वैसी ही रहती हैं।

## Permissions

Lumi onboarding में ये permissions माँगता है। हर एक System Settings में सही जगह खोलती है:

- **Input Monitoring** (ज़रूरी): Lumi key पहचानने के लिए। Lumi कभी record नहीं करता कि आप क्या type करते हैं।
- **Accessibility** (ज़रूरी): आपका selection पढ़ने, text insert करने और Esc से cards बंद करने के लिए।
- **Screen Recording** (ज़रूरी): सवाल के साथ भेजे जाने वाले screenshot के लिए।
- **Microphone** (optional): बोलकर पूछने के लिए। इसके बिना आप हमेशा type कर सकते हैं।

macOS, Input Monitoring और Screen Recording को Lumi के दोबारा खुलने के बाद ही लागू करता है। इसके लिए हर एक के आगे दिया Quit & Reopen button इस्तेमाल कीजिए।

## Source से build करें

```sh
Scripts/make-dev-cert.sh   # एक बार: एक stable signing identity, ताकि rebuild के बाद भी permission grants बने रहें
Scripts/build-app.sh       # build, sign और /Applications/Lumi.app install करता है
open -a Lumi
```

Code signing के लिए certificate को trust करने के लिए `make-dev-cert.sh` एक बार आपका login password माँगता है। पहली build में codesign पूछ सकता है कि क्या वह `make-dev-cert.sh` से बनी development signing key इस्तेमाल कर सकता है। वहाँ Always Allow चुनिए। <!-- OWNER: English README इस key का नाम app के पुराने working name से देता है। Scripts/make-dev-cert.sh में key का नाम बदलें, फिर नया नाम यहाँ जोड़ें। -->

- `INSTALL=0 Scripts/build-app.sh` install किए बिना `dist/Lumi.app` build करता है।
- Tests चलाने के लिए `Scripts/test.sh` चलाइए।
- App icon के लिए Xcode चाहिए (`actool` के लिए)। Xcode के बिना build generic icon इस्तेमाल करती है।

Lumi को हमेशा Applications, Spotlight या Finder से खोलिए, कभी terminal से नहीं। Terminal से शुरू की गई copy terminal की permissions उधार ले लेती है।

## Uninstall

1. अगर आप चाहते हैं कि Lumi की conversations के records भी हट जाएँ, तो सबसे पहले उन्हें delete कीजिए। Conversations में हर एक पर Forget इस्तेमाल कीजिए। आपका harness इन्हें `~/.claude/projects/` में आपके अपने sessions के साथ मिलाकर रखता है।
2. Menu-bar menu से Lumi quit कीजिए और `/Applications/Lumi.app` को Trash में drag कीजिए।
3. इसका data delete कीजिए:
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # conversations, reports, voice models, plugin copy
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # saved connection tokens
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # screenshots
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # trace log
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # network cache, अगर मौजूद हो
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # voice का pronunciation data
   defaults delete com.loomtable.lumi                         # preferences
   ```
4. अगर आपने ElevenLabs key जोड़ी थी, तो Keychain Access खोलिए, `com.loomtable.lumi.elevenlabs` search कीजिए और उसे delete कीजिए।
5. अगर आपने Settings › Connections में MCP servers जोड़े थे, तो उन्हें देखने के लिए `claude mcp list` चलाइए। फिर हर एक को `claude mcp remove --scope user <name>` से हटाइए।
6. Optional: System Settings › Privacy & Security में हर list में Lumi select कीजिए और − पर click कीजिए।

## Lumi किससे कैसे अलग है

| अगर आप इस्तेमाल करते हैं… | Lumi क्या जोड़ता है |
| --- | --- |
| Terminal में अपना harness | वही harness, किसी भी app से: एक key, आपकी आवाज़, और context के रूप में front window। Screenshots paste करने या यह समझाने की ज़रूरत नहीं कि आप कहाँ हैं। |
| AI सवालों के लिए एक chat app | जवाब आपके अपने setup से आते हैं (repo, CLAUDE.md, MCP servers, skills), किसी अलग account और memory से नहीं। जवाब उसी चीज़ के पास दिखते हैं जिसे आप देख रहे हैं। |
| ऐसा assistant जो दिन भर आपकी screen record करता है | Lumi सिर्फ़ तब देखता है जब आप key दबाते हैं। Screenshots आपके Mac पर ज़्यादा से ज़्यादा 24 घंटे रहते हैं। |

## FAQ

**Lumi क्या है?**
एक मुफ़्त, open-source macOS menu-bar app। आप किसी भी app में एक key tap करते हैं और बोलकर या type करके पूछते हैं। आपका अपना harness आपकी screen पर मौजूद चीज़ों के आधार पर जवाब देता है। Lumi एक छोटा जवाब बोलता है और जब picture से मदद मिले तो एक card दिखाता है।

**क्या Lumi मुफ़्त है?**
हाँ। Lumi GPL-3.0 के तहत मुफ़्त और open source है। आपके सवाल आपके अपने harness से होकर जाते हैं, इसलिए वे आपके अपने Claude plan या API usage में गिने जाते हैं।

**क्या मुझे अलग से कुछ चाहिए?**
हाँ: ऊपर बताया harness, version 2.1.259 या नया, installed और signed in। Lumi उसे आपके Mac पर चलाता है। Lumi का अपना कोई login या server नहीं है।

**क्या Lumi को Anthropic ने बनाया है?**
नहीं। Lumi को Loomtable ने बनाया है। यह आपके harness के ज़रिए Claude से powered है, और इसे Anthropic ने नहीं बनाया है, न ही यह Anthropic से affiliated है।

**Lumi क्या भेजता है, और कहाँ?**
आपका सवाल, सामने वाले app से Lumi का पढ़ा हुआ context और एक screenshot आपके harness को जाते हैं। Harness इन्हें जवाब के लिए Anthropic को भेजता है। Lumi के कोई servers नहीं हैं और कोई analytics नहीं है। [यह क्या देखता है और क्या भेजता है](#what-it-sees-and-sends) देखें।

**क्या Lumi हर समय मेरी screen देखता है?**
नहीं। यह सिर्फ़ तब देखता है जब आप Lumi key दबाते हैं। यह password managers को और उन apps को छोड़ देता है जिन्हें आप Settings › Privacy में block करते हैं।

**क्या मैं इसे बिना बोले इस्तेमाल कर सकता हूँ?**
हाँ। Type करने के लिए Lumi key को double-tap कीजिए। Microphone permission optional है।

**क्या Lumi files बदल सकता है या commands चला सकता है?**
Lumi आपके harness के ज़रिए काम करता है। यह आपके Mac पर पढ़ सकता है, चला सकता है, edit कर सकता है, और उन tools का इस्तेमाल कर सकता है जो आपने जोड़े हैं। Lumi जो बदलाव propose करता है, वे आपके OK का इंतज़ार करते हैं। Insert किया गया text आपकी तरफ़ से कभी भेजा नहीं जाता।

**क्या यह Intel Macs, पुराने macOS, Windows या Linux पर चलता है?**
नहीं। Lumi को Apple Silicon पर macOS 26 चाहिए।

**क्या यह offline चलता है?**
नहीं। Speech-to-text और default voice आपके Mac पर चलते हैं, पर जवाब आपके harness के ज़रिए Claude से आते हैं, और उसके लिए internet चाहिए।

**macOS पहली launch को क्यों रोकता है?**
Lumi अभी Apple Developer ID से signed नहीं है। इसे एक बार खोलिए, फिर System Settings › Privacy & Security में Open Anyway पर click कीजिए। [Install](#install) देखें।

## Repository layout

| Path | क्या है |
| --- | --- |
| `Sources/BuddyCore` | Shared value types: context packet, answer block, modes और models |
| `Sources/BuddyKeys` | Lumi key gestures, scoped Esc handling, chords |
| `Sources/BuddyContext` | सामने वाले app से context packet बनाता है |
| `Sources/BuddyAct` | आपके app में text insert करता है |
| `Sources/BuddyVoice` | Mic, speech-to-text, text-to-speech, meters, sounds |
| `Sources/BuddyOverlay` | Pill, chip, card, capsule, placement, motion |
| `Sources/BuddyBridge` | आपका harness चलाता है और उसकी stream parse करता है |
| `Sources/BuddyConversations` | Conversation index और harness की session files |
| `Sources/BuddyTrace` | Optional trace log |
| `Sources/BuddyApp` | हर सवाल चलाने वाला coordinator, app runtime, पुराने versions से migration |
| `Sources/BuddyCompanion` | Settings, onboarding, Conversations |
| `Sources/Lumi` | Menu-bar app shell |
| `buddy-plugin/` | Harness plugin जो सोचने का काम करता है। यह app के अंदर ship होता है |
| `App/` | Info.plist, entitlements और app icon (Icon Composer) |
| `Scripts/` | Build, test और signing scripts |
| `Scenarios/`, `Tools/` | Answer scenarios और उन्हें check करने वाले tools |

## License

GPL-3.0. © 2026 Loomtable. Powered by Claude. "Claude" और उससे जुड़े product नाम Anthropic के trademarks हैं। Lumi को Anthropic ने नहीं बनाया है और यह Anthropic से affiliated नहीं है।

हमें बताइए कि इसने आपके हफ़्ते के लिए क्या किया: hello@loomtable.com

Loomtable
