<!-- OWNER: confirm the Spanish macOS 26 labels used below on a Mac set to Spanish (Spain) and to Spanish (Latin America): "Ajustes del Sistema", "Privacidad y seguridad", "Abrir igualmente", "Monitorización de entrada", "Accesibilidad", "Grabación de pantalla", "Micrófono", "Acceso a Llaveros". -->

<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <b>Español</b> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.hi.md">हिन्दी</a>
</p>

<!-- OWNER: Lumi's own interface labels (Settings › Privacy, Settings › Models, Settings › Voice, Settings › Connections, Conversations, Forget, Quit & Reopen) are kept in English on the assumption that the app's interface is in English. Change them if the app ships a Spanish interface. --> <!-- OWNER: have one native reviewer from Spain and one from Latin America read this file before it is merged. -->

# Lumi: la luz dentro de tu Mac

Pregunta, y Lumi lo encuentra en la oscuridad, hace el trabajo y te muestra la respuesta.

Estás en una hoja de cálculo, en un contrato, en un hilo de chat o en una terminal. Toca una tecla en cualquier app y pregunta en voz alta, o escribe. Lumi by Loomtable responde con lo que tienes delante: la ventana del frente, tu selección, la carpeta de la terminal o el repositorio detrás de un puerto localhost. Oyes una respuesta corta y, cuando una imagen ayuda, aparece una tarjeta junto a lo que estabas mirando. Los cambios que propone Lumi esperan tu OK.

El trabajo lo hace tu propia configuración: tu sesión, tus servidores MCP y tu CLAUDE.md.

**Está en tu pantalla y te escucha. Encuentra tus archivos y trabaja con ellos. Se integra con tus herramientas. Gratis, local y de código abierto.**

Respuestas hechas para ti: una línea, una imagen cuando ayuda y un anillo sobre el punto exacto.

Hecho para el trabajo que haces: fundadores, diseñadores, analistas, escritores, estudiantes, desarrolladores y todos los demás.

- **Web:** [lumi.loomtable.com](https://lumi.loomtable.com)
- **Descarga:** [última versión](https://github.com/loomtable/lumi/releases/latest) (DMG, consulta [Instalación](#instalación))
- **Precio y licencia:** gratis, GPL-3.0
- **Hecho por:** [Loomtable](https://loomtable.com), un estudio de productos nativo de IA. Con la tecnología de Claude.

**Gratis, de código abierto y local. Funciona con tu Claude Code, en tu Mac.**

## Requisitos

- macOS 26 en Apple Silicon (M1 o posterior). Los Mac con Intel y las versiones anteriores de macOS no son compatibles.
- La versión 2.1.312 o posterior de ese agente, instalada y con la sesión iniciada (el comando `claude`). En este README lo llamamos «tu agente de Claude».
- Se recomiendan 16 GB de memoria. Con 8 GB, las respuestas pueden tardar más cuando hay muchas apps abiertas.

## Cómo funciona

1. Toca la tecla de Lumi (**right Option**, la ⌥ derecha, por defecto) y haz tu pregunta. Tócala de nuevo para enviarla, o mantenla presionada mientras hablas. Si prefieres escribir, tócala dos veces.
2. Lumi mira lo que tienes delante (consulta más abajo) y le pasa tu pregunta a tu agente de Claude.
3. Oyes una respuesta de una línea. Cuando una imagen ayuda, aparece una tarjeta junto a lo que estabas mirando. Para cerrarla, presiona Esc, haz clic en otro sitio o cambia de app.

Las preguntas empiezan en Quick, con un modelo rápido. Cuando una pregunta necesita archivos, comandos o el navegador, Quick se la pasa a Deep, que usa un modelo más potente, y te avisa cuando lo hace. Empieza una pregunta con "go deep" para ir directamente a Deep, o con "research" para iniciar un trabajo largo en segundo plano. En Settings › Models eliges el modelo de cada modo y el enrutamiento (Auto, Always Quick o Always Deep).

## Qué ve y qué envía

Lumi solo mira cuando lo llamas. En ese momento lee:

- la app y la ventana que tienes al frente;
- el texto que tienes seleccionado, el elemento bajo el puntero y si el campo activo es editable;
- lo que muestra la app del frente, cuando Lumi puede identificarlo: la carpeta y el comando de una terminal, el puerto y la carpeta de un servidor de desarrollo local, el proyecto y el archivo de un editor, el canal y el hilo de un chat, o una carpeta del Finder y lo que tienes seleccionado en ella;
- qué apps usaste hace poco y la disposición de tus pantallas;
- una captura de la ventana del frente o de la pantalla.

Nunca mira los gestores de contraseñas ni las apps que bloquees en Settings › Privacy. Sus ventanas quedan fuera de las capturas. Nunca lee el texto de los campos de contraseña, aunque los puntos de un campo pueden aparecer en una captura. Los secretos que haya en líneas de comandos y direcciones, como tokens y claves, se eliminan antes de enviar nada.

Tu pregunta, este contexto y la captura van a **tu propio agente de Claude**, que los envía a Anthropic para responder, con tu cuenta de Claude. Lumi solo se conecta a internet para estas cosas:

- cuando activas la voz, descarga un pequeño detector de silencio desde Hugging Face (alrededor de 1 MB, una sola vez);
- solo si los eliges, durante la configuración inicial o en Settings › Voice, descarga el reconocimiento de voz Parakeet (alrededor de 466 MB) o la voz Kokoro (alrededor de 437 MB) desde Hugging Face, una sola vez cada uno;
- si activas la voz de ElevenLabs, el texto de la respuesta va a ElevenLabs para que lo pronuncie.

Los servidores MCP que agregues en Settings › Connections se ejecutan dentro de tu agente de Claude y se comunican con sus propios servicios, igual que cualquier otro servidor MCP.

Por defecto, Lumi escucha y habla con el reconocimiento de voz y la voz del propio Mac, así que no hace falta descargar nada grande. Es posible que macOS agregue sus archivos de voz en inglés la primera vez. El reconocimiento de voz y todas las voces, salvo ElevenLabs, se ejecutan en tu Mac. La grabación de tu voz nunca sale de él. Las capturas se guardan en tu Mac 24 horas como máximo, y en Settings › Privacy puedes reducir ese plazo a 6 horas o a 1 hora. El registro de trazas está desactivado por defecto. Si lo activas, guarda tiempos, tipos de evento y resultados, nunca lo que dijiste o lo que había en pantalla, y los conserva 7 días.

## Instalación

Lumi se distribuye como DMG en GitHub Releases. Todavía no está en la Mac App Store ni en Homebrew.

1. Descarga `Lumi-<version>.dmg` y `Lumi-<version>.dmg.sha256` desde la [página de Releases](https://github.com/loomtable/lumi/releases/latest). Para verificar la descarga, ejecuta `shasum -a 256 -c Lumi-<version>.dmg.sha256` en la carpeta donde guardaste los dos archivos.
2. Abre la imagen de disco y arrastra Lumi a Aplicaciones.
3. Lumi aún no está firmado con un Apple Developer ID, así que macOS detiene el primer arranque. Abre Lumi una vez y cierra el aviso. Después abre Ajustes del Sistema › Privacidad y seguridad, desplázate hacia abajo, haz clic en **Abrir igualmente** junto a Lumi y confirma con tu contraseña o con Touch ID. A partir de ahí, Lumi se abre con normalidad.

   Si te manejas con la Terminal, este comando hace lo mismo, solo para esta app:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. Sigue la configuración inicial: la tecla de Lumi, los permisos y la voz.

Para actualizar, descarga la nueva versión desde la [página de Releases](https://github.com/loomtable/lumi/releases/latest) y reemplaza Lumi en Aplicaciones. Tus ajustes, conversaciones y permisos se mantienen.

## Permisos

Lumi los pide durante la configuración inicial. Cada uno abre el lugar correcto de Ajustes del Sistema:

- **Monitorización de entrada** (obligatorio): para detectar la tecla de Lumi. Lumi nunca graba lo que escribes.
- **Accesibilidad** (obligatorio): para leer tu selección, insertar texto y cerrar tarjetas con Esc.
- **Grabación de pantalla** (obligatorio): para la captura que se envía con tu pregunta.
- **Micrófono** (opcional): para preguntar en voz alta. Sin él, siempre puedes escribir.

macOS aplica la Monitorización de entrada y la Grabación de pantalla solo después de que Lumi se vuelve a abrir. Usa el botón Quit & Reopen que aparece junto a cada uno.

## Compilar desde el código fuente

```sh
Scripts/make-dev-cert.sh   # una vez: una identidad de firma estable, para que los permisos sobrevivan a las recompilaciones
Scripts/build-app.sh       # compila, firma e instala /Applications/Lumi.app
open -a Lumi
```

`make-dev-cert.sh` te pide la contraseña de inicio de sesión una vez, para confiar en el certificado de firma de código. La primera compilación puede preguntar si codesign puede usar la clave de desarrollo que creó `make-dev-cert.sh`. Elige «Permitir siempre». `INSTALL=0 Scripts/build-app.sh` compila `dist/Lumi.app` sin instalarla. Ejecuta las pruebas con `Scripts/test.sh`.

El icono de la app necesita Xcode (para `actool`). Sin Xcode, la compilación usa el icono genérico.

Abre Lumi siempre desde Aplicaciones, Spotlight o el Finder, nunca desde una terminal. Una copia iniciada desde una terminal toma prestados los permisos de esa terminal.

## Desinstalación

1. Si también quieres borrar los registros que tu agente de Claude guarda de las conversaciones con Lumi, hazlo primero: en Conversations, usa Forget en cada una. Tu agente de Claude las guarda en `~/.claude/projects/`, mezcladas con tus propias sesiones.
2. Cierra Lumi desde su menú en la barra de menús y arrastra `/Applications/Lumi.app` a la Papelera.
3. Borra sus datos:
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # conversaciones, informes, modelos de voz, copia del plugin
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # tokens de conexión guardados
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # capturas
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # registro de trazas
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # caché de red, si existe
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # datos de pronunciación de la voz
   defaults delete com.loomtable.lumi                         # preferencias
   ```
4. Si agregaste una clave de ElevenLabs, abre Acceso a Llaveros, busca `com.loomtable.lumi.elevenlabs` y bórrala.
5. Si agregaste servidores MCP en Settings › Connections, ejecuta `claude mcp list` para verlos y quita cada uno con `claude mcp remove --scope user <name>`.
6. Opcional: en Ajustes del Sistema › Privacidad y seguridad, selecciona Lumi en cada lista y haz clic en −.

## Cómo se compara Lumi

| Si usas… | Lo que añade Lumi |
| --- | --- |
| Tu agente de Claude en una terminal | El mismo agente, desde cualquier app: una tecla, tu voz y la ventana del frente como contexto. No tienes que pegar capturas ni explicar dónde estás. |
| Una app de chat para preguntas de IA | Respuestas de tu propia configuración (repositorio, CLAUDE.md, servidores MCP, skills) en lugar de otra cuenta y otra memoria, mostradas junto a lo que estás mirando. |
| Un asistente que graba tu pantalla todo el día | Lumi solo mira cuando presionas la tecla. Las capturas se quedan en tu Mac 24 horas como máximo. |

## Preguntas frecuentes

**¿Qué es Lumi?**
Una app gratuita y de código abierto para la barra de menús de macOS. Tocas una tecla en cualquier app y preguntas en voz alta o escribes. Tu propio agente de Claude responde con lo que tienes en pantalla, y Lumi dice una respuesta corta y muestra una tarjeta cuando una imagen ayuda.

**¿Lumi es gratis?**
Sí. Lumi es gratis y de código abierto, con licencia GPL-3.0. Tus preguntas pasan por tu propio agente de Claude, así que cuentan en tu propio plan de Claude o en tu uso de la API.

**¿Qué necesito para usar Lumi?**
Un Mac con macOS 26 en Apple Silicon y tu agente de Claude, versión 2.1.312 o posterior, instalado y con la sesión iniciada. Lumi lo ejecuta en tu Mac. Lumi no tiene inicio de sesión ni servidores propios.

**¿Lumi está hecho por Anthropic?**
No. Lumi está hecho por Loomtable. Funciona con Claude, a través de tu agente de Claude, y no está hecho por Anthropic ni afiliado a ella.

**¿Qué envía Lumi, y adónde?**
Tu pregunta, el contexto que Lumi leyó de la app del frente y una captura van a tu agente de Claude, que los envía a Anthropic para responder. Lumi no tiene servidores ni analíticas. Consulta [Qué ve y qué envía](#qué-ve-y-qué-envía).

**¿Lumi vigila mi pantalla todo el tiempo?**
No. Solo mira cuando presionas la tecla de Lumi. Se salta los gestores de contraseñas y las apps que bloquees en Settings › Privacy.

**¿Puedo usarlo sin hablar?**
Sí. Toca dos veces la tecla de Lumi para escribir. El permiso de micrófono es opcional.

**¿Lumi puede cambiar archivos o ejecutar comandos?**
Lumi trabaja a través de tu agente de Claude: puede leer, ejecutar y editar en tu Mac, y usar las herramientas que hayas conectado. Los cambios que propone Lumi esperan tu OK, y el texto que inserta nunca se envía por ti.

**¿Funciona en Mac con Intel, en versiones anteriores de macOS, en Windows o en Linux?**
No. Lumi necesita macOS 26 en Apple Silicon.

**¿Funciona sin conexión?**
No. El reconocimiento de voz y la voz por defecto se ejecutan en tu Mac, pero las respuestas vienen de Claude a través de tu agente de Claude, que necesita internet.

**¿Por qué macOS bloquea el primer arranque?**
Lumi aún no está firmado con un Apple Developer ID. Ábrelo una vez y luego haz clic en Abrir igualmente en Ajustes del Sistema › Privacidad y seguridad. Consulta [Instalación](#instalación).

## Estructura del repositorio

| Ruta | Qué contiene |
| --- | --- |
| `Sources/BuddyCore` | Tipos de valor compartidos: paquete de contexto, bloque de respuesta, modos y modelos |
| `Sources/BuddyKeys` | Gestos de la tecla de Lumi, manejo acotado de Esc, combinaciones |
| `Sources/BuddyContext` | Construye el paquete de contexto a partir de la app del frente |
| `Sources/BuddyAct` | Inserta texto en tu app |
| `Sources/BuddyVoice` | Micrófono, reconocimiento de voz, síntesis de voz, medidores, sonidos |
| `Sources/BuddyOverlay` | Píldora, chip, tarjeta, cápsula, posicionamiento, movimiento |
| `Sources/BuddyBridge` | Ejecuta tu agente de Claude y analiza su flujo de salida |
| `Sources/BuddyConversations` | Índice de conversaciones y archivos de sesión del agente |
| `Sources/BuddyTrace` | El registro de trazas opcional |
| `Sources/BuddyApp` | El coordinador que ejecuta cada pregunta, el entorno de la app y la migración desde versiones anteriores |
| `Sources/BuddyCompanion` | Ajustes, configuración inicial, Conversations |
| `Sources/Lumi` | Estructura de la app de la barra de menús |
| `buddy-plugin/` | El plugin para tu agente de Claude que hace el razonamiento; viene dentro de la app |
| `App/` | Info.plist, entitlements y el icono de la app (Icon Composer) |
| `Scripts/` | Scripts de compilación, pruebas y firma |
| `Scenarios/`, `Tools/` | Escenarios de respuesta y las herramientas que los comprueban |

## Licencia

GPL-3.0. © 2026 Loomtable. Con la tecnología de Claude. «Claude» y los nombres de sus productos son marcas de Anthropic. Lumi no está hecho por Anthropic ni afiliado a ella.
