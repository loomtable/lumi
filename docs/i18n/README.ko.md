<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <b>한국어</b> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.hi.md">हिन्दी</a>
</p>

# Lumi: Mac 안의 빛

물어보세요. Lumi가 어둠 속에서 찾아내고, 일을 해내고, 답을 보여 줍니다.

Lumi by Loomtable은 Mac용 음성 어시스턴트입니다. 어떤 앱에서든 키 하나를 탭하고 소리 내어 묻거나 입력하세요. Lumi는 지금 화면에 보이는 것을 함께 넘깁니다. 앞에 있는 창, 선택한 텍스트, localhost 포트 뒤의 저장소, 터미널 폴더 같은 것들입니다. 짧은 음성 답을 듣고, 그림이 도움이 될 때는 카드도 함께 봅니다. Lumi가 제안하는 변경은 내가 OK할 때까지 기다립니다.

생각은 내 설정이 합니다. 내 로그인, 내 MCP 서버, 내 CLAUDE.md를 그대로 씁니다.

**화면을 보고, 내 말을 듣습니다. 파일을 찾고 다룹니다. 연결한 도구와 함께 일합니다. 무료, 로컬, 오픈 소스.**

하는 일에 맞게 만들었습니다. 창업자, 디자이너, 분석가, 작가, 학생, 개발자, 그리고 그 사이의 모든 분을 위해.

**무료, 오픈 소스, 로컬. 내 Mac에서, 내 Claude Code와 함께 작동합니다.**

- **웹사이트:** [lumi.loomtable.com](https://lumi.loomtable.com)
- **다운로드:** [최신 릴리스](https://github.com/loomtable/lumi/releases/latest) (DMG, [설치](#install) 참고)
- **가격과 라이선스:** 무료, GPL-3.0
- **만든 곳:** [Loomtable](https://loomtable.com), AI 네이티브 프로덕트 스튜디오. Powered by Claude.

## 요구 사항

- Apple Silicon(M1 이상)의 macOS 26. Intel Mac과 이전 macOS 버전은 지원하지 않습니다.
- Claude Code 2.1.312 이상, 설치 후 로그인된 상태.
- 메모리 16 GB를 권장합니다. 8 GB에서는 앱을 많이 열어 두면 답이 느려질 수 있습니다.

## 작동 방식

1. Lumi 키(기본값: 오른쪽 ⌥, right Option)를 탭하고 질문하세요. 다시 탭하면 보냅니다. 말하는 동안 키를 누르고 있어도 됩니다. 입력하려면 두 번 탭하세요.
2. Lumi가 눈앞의 내용을 살펴보고(아래 참고) 질문을 Claude Code에 넘깁니다.
3. 한 줄짜리 답을 듣습니다. 그림이 도움이 될 때는 보고 있던 곳 옆에 카드가 나타납니다. Esc를 누르거나, 다른 곳을 클릭하거나, 앱을 전환하면 닫힙니다.

질문은 빠른 모델의 Quick에서 시작합니다. 파일, 명령, 브라우저가 필요한 질문이면 Quick이 더 강한 모델의 Deep으로 넘기고, 넘길 때 알려 줍니다. 질문을 "go deep"으로 시작하면 바로 Deep으로 가고, "research"로 시작하면 긴 백그라운드 작업이 시작됩니다. Settings › Models에서 레인별 모델과 라우팅(Auto, Always Quick, Always Deep)을 정합니다.

<a id="what-it-sees-and-sends"></a>

## 무엇을 보고 무엇을 보내는가

Lumi는 불렀을 때만 봅니다. 그때 다음을 읽습니다.

- 앞에 있는 앱과 창
- 선택한 텍스트, 포인터 아래의 요소, 포커스된 필드가 편집 가능한지 여부
- Lumi가 알아볼 수 있는 경우, 앞의 앱이 보여 주는 내용: 터미널의 폴더와 명령, 로컬 개발 서버의 포트와 폴더, 편집기의 프로젝트와 파일, 채팅의 채널과 스레드, Finder 폴더와 선택 항목
- 최근에 쓴 앱, 디스플레이 배치
- 앞 창 또는 디스플레이의 스크린숏

암호 관리자와 Settings › Privacy에서 차단한 앱은 절대 보지 않습니다. 이런 앱의 창은 스크린숏에서 빠집니다. 암호 필드의 텍스트는 읽지 않지만, 필드에 표시된 점은 스크린숏에 보일 수 있습니다. 명령줄과 주소에 들어 있는 토큰, 키 같은 비밀 값은 보내기 전에 제거합니다.

질문, 이 컨텍스트, 스크린숏은 **내 Claude Code**로 가고, Claude Code가 이를 내 Claude 계정으로 Anthropic에 보내 답을 받습니다. Lumi 자체가 인터넷에 연결하는 경우는 다음뿐입니다.

- 음성을 켜면 Hugging Face에서 작은 무음 감지기(약 1 MB)를 한 번 내려받습니다.
- 온보딩이나 Settings › Voice에서 직접 고른 경우에만 Hugging Face에서 Parakeet 음성 인식(약 466 MB) 또는 Kokoro 음성(약 437 MB)을 각각 한 번 내려받습니다.
- ElevenLabs 음성을 켜면 답 텍스트가 음성 변환을 위해 ElevenLabs로 갑니다.

Settings › Connections에서 추가한 MCP 서버는 Claude Code 안에서 실행되며, 다른 MCP 서버와 마찬가지로 각자의 서비스와 통신합니다.

기본 설정에서 Lumi는 Mac 자체의 음성 인식과 음성으로 듣고 말하므로 크게 내려받을 것이 없습니다. 처음 쓸 때 macOS가 영어 음성 파일을 추가할 수 있습니다. 음성 인식과 ElevenLabs를 제외한 모든 음성은 Mac에서 실행됩니다. 음성 녹음은 Mac을 떠나지 않습니다. 스크린숏은 Mac에 최대 24시간 보관되며, Settings › Privacy에서 6시간 또는 1시간으로 줄일 수 있습니다. 트레이스 로그는 기본으로 꺼져 있습니다. 켜면 타이밍, 이벤트 종류, 결과만 기록하고, 내가 말하거나 본 내용은 기록하지 않으며, 7일간 보관합니다.

<a id="install"></a>

## 설치

Lumi는 GitHub Releases에서 DMG로 배포합니다. Mac App Store와 Homebrew에는 아직 없습니다.

1. [Releases 페이지](https://github.com/loomtable/lumi/releases/latest)에서 `Lumi-<version>.dmg`와 `Lumi-<version>.dmg.sha256`을 내려받습니다. 다운로드를 확인하려면 두 파일을 저장한 폴더에서 `shasum -a 256 -c Lumi-<version>.dmg.sha256`을 실행합니다.
2. 디스크 이미지를 열고 Lumi를 응용 프로그램 폴더로 드래그합니다.
3. Lumi는 아직 Apple Developer ID로 서명되지 않았으므로 macOS가 첫 실행을 막습니다. Lumi를 한 번 열고 경고를 닫습니다. 그다음 시스템 설정 › 개인정보 보호 및 보안을 열고 아래로 스크롤해 Lumi 옆의 **그래도 열기**(Open Anyway)를 클릭한 뒤, 암호나 Touch ID로 확인합니다. 이후로는 Lumi가 평소처럼 열립니다.

   터미널이 익숙하다면 이 명령도 같은 일을 하며, 이 앱에만 적용됩니다.
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. 온보딩을 따라 Lumi 키, 권한, 음성을 설정합니다.

업데이트하려면 [Releases 페이지](https://github.com/loomtable/lumi/releases/latest)에서 새 릴리스를 내려받아 응용 프로그램 폴더의 Lumi를 교체합니다. 설정, 대화, 권한은 그대로 유지됩니다.

## 권한

Lumi는 온보딩에서 다음 권한을 요청합니다. 각 항목은 시스템 설정의 해당 위치를 엽니다.

- **입력 모니터링**(필수): Lumi 키를 알아채기 위해 필요합니다. 입력한 내용은 기록하지 않습니다.
- **손쉬운 사용**(필수): 선택 영역을 읽고, 텍스트를 넣고, Esc로 카드를 닫기 위해 필요합니다.
- **화면 기록**(필수): 질문과 함께 보내는 스크린숏에 필요합니다.
- **마이크**(선택): 소리 내어 묻기 위해 필요합니다. 없어도 언제든 입력할 수 있습니다.

macOS는 Lumi를 다시 연 뒤에야 입력 모니터링과 화면 기록 권한을 적용합니다. 각 항목 옆의 Quit & Reopen 버튼을 쓰세요.

## 소스에서 빌드

```sh
Scripts/make-dev-cert.sh   # once: a stable signing identity, so permission grants survive rebuilds
Scripts/build-app.sh       # build, sign and install /Applications/Lumi.app
open -a Lumi
```

`make-dev-cert.sh`는 코드 서명용 인증서를 신뢰하도록 로그인 암호를 한 번 묻습니다. 첫 빌드에서 codesign이 `make-dev-cert.sh`가 만든 개발용 키를 써도 되는지 물을 수 있습니다. 항상 허용을 고르세요. `INSTALL=0 Scripts/build-app.sh`는 설치하지 않고 `dist/Lumi.app`만 빌드합니다. 테스트는 `Scripts/test.sh`로 실행합니다.

앱 아이콘에는 Xcode(`actool`)가 필요합니다. Xcode가 없으면 기본 아이콘으로 빌드됩니다.

Lumi는 항상 응용 프로그램 폴더, Spotlight, Finder에서 여세요. 터미널에서 실행하지 마세요. 터미널에서 실행한 사본은 터미널의 권한을 빌려 씁니다.

## 제거

1. Lumi 대화에 대한 Claude Code의 기록도 지우려면 먼저 지우세요. Conversations에서 각 대화에 Forget을 씁니다. 이 기록은 `~/.claude/projects/` 아래에 내 세션과 섞여 저장되어 있습니다.
2. 메뉴 막대 메뉴에서 Lumi를 종료하고 `/Applications/Lumi.app`을 휴지통으로 드래그합니다.
3. 데이터를 지웁니다.
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # conversations, reports, voice models, plugin copy
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # saved connection tokens
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # screenshots
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # trace log
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # network cache, if present
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # the voice's pronunciation data
   defaults delete com.loomtable.lumi                         # preferences
   ```
4. ElevenLabs 키를 추가했다면 키체인 접근을 열고 `com.loomtable.lumi.elevenlabs`를 검색해 삭제합니다.
5. Settings › Connections에서 MCP 서버를 추가했다면 `claude mcp list`로 확인하고 각각 `claude mcp remove --scope user <name>`으로 제거합니다.
6. 선택: 시스템 설정 › 개인정보 보호 및 보안의 각 목록에서 Lumi를 선택하고 −를 클릭합니다.

## Lumi는 무엇을 더하나

| 지금 쓰는 것 | Lumi가 더하는 것 |
| --- | --- |
| 터미널의 Claude Code | 같은 설정을 어떤 앱에서든 씁니다. 키 하나, 내 목소리, 앞 창을 컨텍스트로 넘기므로 스크린숏을 붙여 넣거나 지금 어디에 있는지 설명할 필요가 없습니다. |
| AI 질문용 채팅 앱 | 별도 계정과 메모리 대신 내 설정(저장소, CLAUDE.md, MCP 서버, 스킬)으로 답하고, 보고 있는 곳 옆에 보여 줍니다. |
| 화면을 하루 종일 기록하는 어시스턴트 | Lumi는 키를 눌렀을 때만 봅니다. 스크린숏은 Mac에 최대 24시간만 보관됩니다. |

## FAQ

**Lumi는 무엇인가요?**
무료 오픈 소스 macOS 메뉴 막대 앱입니다. 어떤 앱에서든 키를 탭하고 소리 내어 묻거나 입력하면, 내 설정이 화면 내용을 바탕으로 답하고, Lumi는 짧은 답을 말해 주며 그림이 도움이 될 때 카드를 보여 줍니다.

**Lumi는 무료인가요?**
네. GPL-3.0의 무료 오픈 소스입니다. 질문은 내 Claude Code를 거치므로 내 Claude 플랜 또는 API 사용량에서 차감됩니다.

**Claude Code가 필요한가요?**
네. Claude Code 2.1.312 이상이 설치되어 있고 로그인되어 있어야 합니다. Lumi는 이를 내 Mac에서 실행하며, 자체 로그인이나 서버가 없습니다.

**Lumi는 Anthropic이 만들었나요?**
아니요. Lumi는 Loomtable이 만들었습니다. 내 설정을 통해 Claude로 작동하며, Anthropic이 만들거나 Anthropic과 제휴한 제품이 아닙니다.

**Lumi는 무엇을 어디로 보내나요?**
질문, 앞 앱에서 읽은 컨텍스트, 스크린숏이 내 설정으로 가고, 이를 Anthropic에 보내 답을 받습니다. Lumi에는 서버도 분석 도구도 없습니다. [무엇을 보고 무엇을 보내는가](#what-it-sees-and-sends)를 참고하세요.

**Lumi가 화면을 항상 보나요?**
아니요. Lumi 키를 눌렀을 때만 봅니다. 암호 관리자와 Settings › Privacy에서 차단한 앱은 건너뜁니다.

**말하지 않고 쓸 수 있나요?**
네. Lumi 키를 두 번 탭하면 입력할 수 있습니다. 마이크 권한은 선택입니다.

**Lumi가 파일을 바꾸거나 명령을 실행할 수 있나요?**
Lumi는 내 설정을 통해 일합니다. Mac에서 읽고, 실행하고, 편집할 수 있고, 연결한 도구를 씁니다. Lumi가 제안하는 변경은 OK할 때까지 기다리며, 넣어 준 텍스트를 대신 보내는 일은 없습니다.

**Intel Mac, 이전 macOS, Windows, Linux에서 작동하나요?**
아니요. Lumi는 Apple Silicon의 macOS 26이 필요합니다.

**오프라인에서 작동하나요?**
아니요. 음성 인식과 기본 음성은 Mac에서 실행되지만, 답은 Claude에서 오므로 인터넷이 필요합니다.

**macOS가 첫 실행을 막는 이유는 무엇인가요?**
Lumi가 아직 Apple Developer ID로 서명되지 않았기 때문입니다. 한 번 연 다음 시스템 설정 › 개인정보 보호 및 보안에서 그래도 열기를 클릭하세요. [설치](#install)를 참고하세요.

## 저장소 구조

| 경로 | 내용 |
| --- | --- |
| `Sources/BuddyCore` | 공유 값 타입: 컨텍스트 패킷, 답 블록, 모드와 모델 |
| `Sources/BuddyKeys` | Lumi 키 제스처, 범위가 지정된 Esc 처리, 코드(chord) |
| `Sources/BuddyContext` | 앞 앱에서 컨텍스트 패킷을 만듭니다 |
| `Sources/BuddyAct` | 앱에 텍스트를 넣습니다 |
| `Sources/BuddyVoice` | 마이크, 음성 인식, 음성 합성, 미터, 사운드 |
| `Sources/BuddyOverlay` | 필, 칩, 카드, 캡슐, 배치, 모션 |
| `Sources/BuddyBridge` | Claude Code를 실행하고 스트림을 파싱합니다 |
| `Sources/BuddyConversations` | 대화 인덱스와 세션 파일 |
| `Sources/BuddyTrace` | 선택형 트레이스 로그 |
| `Sources/BuddyApp` | 각 질문을 처리하는 코디네이터, 앱 런타임, 이전 버전에서의 마이그레이션 |
| `Sources/BuddyCompanion` | Settings, 온보딩, Conversations |
| `Sources/Lumi` | 메뉴 막대 앱 셸 |
| `buddy-plugin/` | 생각을 담당하는 플러그인. 앱 안에 함께 들어 있습니다 |
| `App/` | Info.plist, 인타이틀먼트, 앱 아이콘(Icon Composer) |
| `Scripts/` | 빌드, 테스트, 서명 스크립트 |
| `Scenarios/`, `Tools/` | 답 시나리오와 이를 검사하는 도구 |

## 라이선스

GPL-3.0. © 2026 Loomtable. Powered by Claude. "Claude"와 "Claude Code"는 Anthropic의 상표입니다. Lumi는 Anthropic이 만들거나 Anthropic과 제휴한 제품이 아닙니다.

**무료, 오픈 소스, 로컬. 내 Mac에서, 내 Claude Code와 함께 작동합니다.**
