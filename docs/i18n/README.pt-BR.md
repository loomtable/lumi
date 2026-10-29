<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a> ·
  <b>Português (Brasil)</b> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.hi.md">हिन्दी</a>
</p>

# Lumi: a luz dentro do seu Mac

Pergunte, e o Lumi encontra no escuro, faz o trabalho e mostra a resposta.

O Lumi da Loomtable é um assistente de voz para macOS. Toque uma tecla em qualquer app e pergunte em voz alta ou digite. A resposta vem do seu próprio Claude Code, que vê o que está na sua tela: a janela da frente, o texto selecionado, o repositório por trás de uma porta localhost, a pasta do terminal. Você ouve uma resposta curta e, quando uma imagem ajuda, aparece um cartão. As mudanças que o Lumi propõe esperam o seu OK.

Quem pensa é a sua própria configuração: o seu login, os seus servidores MCP, o seu CLAUDE.md.

**Na sua tela, ouve você. Encontra e trabalha com os seus arquivos. Integra com as suas ferramentas. Grátis, local e open source.**

Feito para o trabalho que você faz. Fundadores, designers, analistas, escritores, estudantes, desenvolvedores e todo mundo no meio.

- **Site:** [lumi.loomtable.com](https://lumi.loomtable.com)
- **Download:** [versão mais recente](https://github.com/loomtable/lumi/releases/latest) (DMG, veja [Instalação](#instalação))
- **Preço e licença:** grátis, GPL-3.0
- **Feito por:** [Loomtable](https://loomtable.com), um estúdio de produtos nativo de IA. Com tecnologia Claude.

## Requisitos

- macOS 26 em Apple Silicon (M1 ou mais recente). Macs Intel e versões mais antigas do macOS não são compatíveis.
- Claude Code 2.1.312 ou mais recente, instalado e com login feito.
- Recomendamos 16 GB de memória. Com 8 GB, as respostas podem ficar mais lentas quando há muitos apps abertos.

## Como funciona

1. Toque a tecla do Lumi (⌥ direito, por padrão) e faça a sua pergunta. Toque de novo para enviar, ou segure a tecla enquanto fala. Para digitar, toque duas vezes.
2. O Lumi olha o que está na sua frente (veja abaixo) e passa a pergunta para o Claude Code.
3. Você ouve uma resposta de uma linha. Quando uma imagem ajuda, aparece um cartão ao lado do que você estava olhando. Para fechar, aperte Esc, clique em outro lugar ou troque de app.

As perguntas começam no modo Quick, com um modelo rápido. Quando a pergunta precisa de arquivos, comandos ou do navegador, o Quick passa para o Deep, com um modelo mais forte, e avisa quando faz isso. Comece a pergunta com "go deep" para ir direto ao Deep, ou com "research" para iniciar uma tarefa longa em segundo plano. <!-- OWNER: confirmar se os gatilhos "go deep" e "research" também funcionam ditos em português ou só em inglês. --> Em Settings › Models você define o modelo de cada modo e o roteamento (Auto, Always Quick ou Always Deep).

## O que o Lumi vê e envia

O Lumi só olha quando você chama. Nesse momento, ele lê:

- o app e a janela da frente;
- o texto selecionado, o elemento sob o ponteiro e se o campo em foco é editável;
- o que o app da frente está mostrando, quando o Lumi consegue identificar: a pasta e o comando de um terminal, a porta e a pasta de um servidor de desenvolvimento local, o projeto e o arquivo de um editor, o canal e a conversa de um chat, uma pasta do Finder e o que está selecionado nela;
- quais apps você usou recentemente e o layout das suas telas;
- uma captura de tela da janela da frente ou da tela inteira.

O Lumi nunca olha gerenciadores de senhas nem apps que você bloquear em Settings › Privacy. As janelas deles ficam fora das capturas de tela. O Lumi nunca lê o texto de campos de senha, mas os pontinhos de um campo podem aparecer numa captura. Segredos em linhas de comando e endereços, como tokens e chaves, são removidos antes de qualquer envio.

A sua pergunta, esse contexto e a captura de tela vão para **o seu próprio Claude Code**. Ele envia tudo para a Anthropic responder, usando a sua conta Claude. O próprio Lumi só se conecta à internet nestes casos:

- quando você ativa a voz, ele baixa uma vez um pequeno detector de silêncio do Hugging Face (cerca de 1 MB);
- só se você escolher, no onboarding ou em Settings › Voice, ele baixa uma vez cada um destes do Hugging Face: o reconhecimento de fala Parakeet (cerca de 466 MB) ou a voz Kokoro (cerca de 437 MB);
- se você ativar a voz da ElevenLabs, o texto da resposta vai para a ElevenLabs para ser falado.

Os servidores MCP que você adiciona em Settings › Connections rodam dentro do seu Claude Code e se comunicam com os próprios serviços, como qualquer outro servidor MCP.

Por padrão, o Lumi ouve e fala com o reconhecimento de fala e a voz do próprio Mac, então não há nada grande para baixar. Na primeira vez, o macOS pode instalar os arquivos de fala em inglês. O reconhecimento de fala e todas as vozes, exceto a da ElevenLabs, rodam no seu Mac. A gravação da sua voz nunca sai dele. As capturas de tela ficam no seu Mac por no máximo 24 horas, e em Settings › Privacy você pode reduzir esse prazo para 6 horas ou 1 hora. O log de rastreamento vem desligado. Quando ligado, ele registra tempos, tipos de evento e resultados, nunca o que você disse ou viu, e guarda os dados por 7 dias.

## Instalação

O Lumi é distribuído como DMG no GitHub Releases. Ele ainda não está na Mac App Store nem no Homebrew.

1. Baixe `Lumi-<version>.dmg` e `Lumi-<version>.dmg.sha256` na [página de Releases](https://github.com/loomtable/lumi/releases/latest). Para conferir o download, rode `shasum -a 256 -c Lumi-<version>.dmg.sha256` na pasta onde você salvou os dois arquivos.
2. Abra a imagem de disco e arraste o Lumi para Aplicativos.
3. O Lumi ainda não é assinado com um Apple Developer ID, então o macOS bloqueia a primeira abertura. Siga estes passos:
   1. Abra o Lumi uma vez e feche o aviso.
   2. Abra Ajustes do Sistema › Privacidade e Segurança e role a página para baixo.
   3. Clique em **Abrir Mesmo Assim** ("Open Anyway") ao lado do Lumi.
   4. Confirme com a sua senha ou com Touch ID.

   <!-- OWNER: confirmar os rótulos em português de Ajustes do Sistema, Privacidade e Segurança e Abrir Mesmo Assim no macOS 26. --> Depois disso, o Lumi abre normalmente.

   Se você se sente à vontade no Terminal, este comando faz o mesmo, só para este app:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. Siga o onboarding: a tecla do Lumi, as permissões e a voz.

Para atualizar, baixe a nova versão na [página de Releases](https://github.com/loomtable/lumi/releases/latest) e substitua o Lumi em Aplicativos. Os seus ajustes, conversas e permissões continuam lá.

## Permissões

O Lumi pede estas permissões no onboarding. Cada uma abre o lugar certo nos Ajustes do Sistema:

- **Monitoramento de Entrada** (obrigatória): para perceber a tecla do Lumi. O Lumi nunca grava o que você digita.
- **Acessibilidade** (obrigatória): para ler a sua seleção, inserir texto e fechar cartões com Esc.
- **Gravação de Tela** (obrigatória): para a captura de tela enviada com a sua pergunta.
- **Microfone** (opcional): para perguntar em voz alta. Sem ela, você sempre pode digitar.
 <!-- OWNER: confirmar os nomes em português das permissões no macOS 26. --> O macOS só aplica Monitoramento de Entrada e Gravação de Tela depois que o Lumi é reaberto. Use o botão Quit & Reopen ao lado de cada uma.

## Compilar a partir do código-fonte

```sh
Scripts/make-dev-cert.sh   # uma vez: uma identidade de assinatura estável, para as permissões sobreviverem às recompilações
Scripts/build-app.sh       # compila, assina e instala /Applications/Lumi.app
open -a Lumi
```

O `make-dev-cert.sh` pede a sua senha de login uma vez, para confiar no certificado de assinatura de código. Na primeira compilação, o macOS pode perguntar se o codesign pode usar a chave de assinatura que o script criou. Escolha Sempre Permitir.

Outros comandos:
- `INSTALL=0 Scripts/build-app.sh` compila `dist/Lumi.app` sem instalar.
- `Scripts/test.sh` roda os testes.

O ícone do app precisa do Xcode (por causa do `actool`). Sem o Xcode, a compilação usa o ícone genérico.

Abra o Lumi sempre por Aplicativos, Spotlight ou Finder, nunca por um terminal. Uma cópia iniciada pelo terminal usa as permissões do terminal.

## Desinstalação

1. Se você também quer apagar os registros que o Claude Code guarda das conversas do Lumi, faça isso primeiro: em Conversations, use Forget em cada uma. O Claude Code guarda esses registros em `~/.claude/projects/`, junto com as suas próprias sessões.
2. Feche o Lumi pelo menu na barra de menus e arraste `/Applications/Lumi.app` para o Lixo.
3. Apague os dados dele:
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # conversas, relatórios, modelos de voz, cópia do plugin
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # tokens de conexão salvos
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # capturas de tela
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # log de rastreamento
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # cache de rede, se existir
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # dados de pronúncia da voz
   defaults delete com.loomtable.lumi                         # preferências
   ```
4. Se você adicionou uma chave da ElevenLabs, abra o Acesso às Chaves, procure `com.loomtable.lumi.elevenlabs` e apague o item.
5. Se você adicionou servidores MCP em Settings › Connections, rode `claude mcp list` para vê-los e remova cada um com `claude mcp remove --scope user <name>`.
6. Opcional: em Ajustes do Sistema › Privacidade e Segurança, selecione o Lumi em cada lista e clique em −.

## Como o Lumi se compara

| Se você usa… | O que o Lumi acrescenta |
| --- | --- |
| Claude Code no terminal | O mesmo assistente, de qualquer app: uma tecla, a sua voz e a janela da frente como contexto. Você não precisa colar capturas de tela nem explicar onde está. |
| Um app de chat para perguntas de IA | Respostas da sua própria configuração (repositório, CLAUDE.md, servidores MCP, skills), em vez de uma conta e uma memória separadas, mostradas ao lado do que você está olhando. |
| Um assistente que grava a sua tela o dia todo | O Lumi só olha quando você aperta a tecla. As capturas de tela ficam no seu Mac por no máximo 24 horas. |

## Perguntas frequentes

**O que é o Lumi?**
Um app de barra de menus para macOS, grátis e open source. Você toca uma tecla em qualquer app e pergunta em voz alta ou digita. O seu próprio Claude Code responde usando o que está na sua tela. O Lumi fala uma resposta curta e mostra um cartão quando uma imagem ajuda.

**O Lumi é grátis?**
Sim. O Lumi é grátis e open source, sob a GPL-3.0. As suas perguntas passam pelo seu próprio Claude Code, então contam no seu plano Claude ou no seu uso da API.

**Preciso do Claude Code?**
Sim, na versão 2.1.312 ou mais recente, instalado e com login feito. O Lumi roda o Claude Code no seu Mac e não tem login nem servidores próprios.

**O Lumi é feito pela Anthropic?**
Não. O Lumi é feito pela Loomtable. Ele usa o Claude por meio da sua configuração e não é feito pela Anthropic nem afiliado a ela.

**O que o Lumi envia, e para onde?**
A sua pergunta, o contexto que o Lumi leu do app da frente e uma captura de tela vão para o seu Claude Code, que envia tudo para a Anthropic responder. O Lumi não tem servidores nem analytics. Veja [O que o Lumi vê e envia](#o-que-o-lumi-vê-e-envia).

**O Lumi fica olhando a minha tela o tempo todo?**
Não. Ele só olha quando você aperta a tecla do Lumi. Ele ignora gerenciadores de senhas e os apps que você bloquear em Settings › Privacy.

**Dá para usar sem falar?**
Sim. Toque duas vezes na tecla do Lumi para digitar. A permissão de microfone é opcional.

**O Lumi pode mudar arquivos ou rodar comandos?**
Sim. O Lumi trabalha pela sua configuração: ele pode ler, rodar e editar no seu Mac e usar as ferramentas que você conectou. As mudanças que o Lumi propõe esperam o seu OK, e o texto inserido nunca é enviado por você.

**Funciona em Macs Intel, em macOS mais antigo, no Windows ou no Linux?**
Não. O Lumi precisa do macOS 26 em Apple Silicon.

**Funciona offline?**
Não. O reconhecimento de fala e a voz padrão rodam no seu Mac, mas as respostas vêm do Claude, que precisa de internet.

**Por que o macOS bloqueia a primeira abertura?**
O Lumi ainda não é assinado com um Apple Developer ID. Abra o app uma vez e depois clique em Abrir Mesmo Assim em Ajustes do Sistema › Privacidade e Segurança. Veja [Instalação](#instalação).

## Estrutura do repositório

| Caminho | O que é |
| --- | --- |
| `Sources/BuddyCore` | Tipos de valor compartilhados: pacote de contexto, bloco de resposta, modos e modelos |
| `Sources/BuddyKeys` | Gestos da tecla do Lumi, tratamento do Esc por escopo, combinações de teclas |
| `Sources/BuddyContext` | Monta o pacote de contexto a partir do app da frente |
| `Sources/BuddyAct` | Insere texto no seu app |
| `Sources/BuddyVoice` | Microfone, reconhecimento de fala, síntese de voz, medidores, sons |
| `Sources/BuddyOverlay` | Pílula, chip, cartão, cápsula, posicionamento, animação |
| `Sources/BuddyBridge` | Roda o seu Claude Code e interpreta o fluxo de saída |
| `Sources/BuddyConversations` | Índice de conversas e arquivos de sessão do Claude Code |
| `Sources/BuddyTrace` | O log de rastreamento opcional |
| `Sources/BuddyApp` | O coordenador que executa cada pergunta, o runtime do app e a migração de versões anteriores |
| `Sources/BuddyCompanion` | Settings, onboarding, Conversations |
| `Sources/Lumi` | Estrutura do app de barra de menus |
| `buddy-plugin/` | O plugin do Claude Code que faz o raciocínio, distribuído dentro do app |
| `App/` | Info.plist, entitlements e o ícone do app (Icon Composer) |
| `Scripts/` | Scripts de compilação, teste e assinatura |
| `Scenarios/`, `Tools/` | Cenários de resposta e as ferramentas que os verificam |

## Licença

GPL-3.0. © 2026 Loomtable. Com tecnologia Claude. "Claude" e "Claude Code" são marcas registradas da Anthropic. O Lumi não é feito pela Anthropic nem afiliado a ela.

---

**Grátis, open source e local. Funciona com o seu Claude Code, no seu Mac.**
