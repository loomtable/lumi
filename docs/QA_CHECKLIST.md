# QA checklist

Manual checks for what the automated tests can't cover: things only a person at the Mac can confirm. Run through them before a release, or after changing the area a check covers.

Run `Scripts/build-app.sh` on the latest main (it installs to /Applications), then open Lumi from Applications (Finder or Spotlight), **never from a terminal**: a copy started from a terminal borrows the terminal's permissions.

1. **Install and launch.** Open Lumi from /Applications.
   **Expected:** the ember orb with a face appears in the menu bar and onboarding opens.

2. **Onboarding permissions.** On the Permissions page, with System Settings beside it, grant Microphone, Input Monitoring, Accessibility and Screen Recording one at a time. Then use Quit & Reopen when it's offered.
   **Expected:** Microphone's first Allow… shows the system prompt; the others open the right System Settings pane. Each row flips to ✓ within about a second, without a click, though Input Monitoring and Screen Recording may only show ✓ after Quit & Reopen. After Quit & Reopen, all rows stay ✓. Continue waits until Input Monitoring, Accessibility and Screen Recording are ✓; Microphone is optional.

3. **Ask, Esc, ask again.** Ask a question, press Esc while it's thinking, then ask again at once.
   **Expected:** Esc stops it straight away. The second question gets its own answer, with no cold-start delay and none of the first answer's text.

4. **First word on the built-in mic.** With no audio playing and no earbuds, tap the key and speak at once, five times.
   **Expected:** the first word is in every transcript.

5. **Video playing while asking.** Play a video on the speakers and ask by voice. Then look at Settings › Voice.
   **Expected:** the video's sound stays out of what you said; losing about the first second is expected on this path only. Settings reads "Voice Isolation when other audio is playing".

6. **Hold-to-talk during an answer.** While a long answer is thinking or showing, hold the key and speak. Separately, type an AltGr character (é, €) during a Deep turn.
   **Expected:** the hold interrupts the answer and keeps your first word. The AltGr character leaves Deep thinking.

7. **Insert and Replace.** In TextEdit, ask for a draft with the caret in an empty line, then ask for a rewrite with a word selected. Press the main button (or ⌘↵), then ⌘Z.
   **Expected:** the button reads Insert, then Replace. The text lands in TextEdit and ⌘Z undoes it. With a web page in front instead, the button reads Copy, or Insert when a text field on the page has focus.

8. **Copy.** On a card with a code block or a draft, click the header Copy, then the block's own Copy, then press ⌘C on the focused card. Paste each into TextEdit.
   **Expected:** a "Copied" toast each time. The paste is the draft or the card's text with its formatting. A whole-card copy starts with the headline (by design). ⌘C with text selected in the card copies just that selection, without a toast.

9. **Answer actions toggles.** In Settings › Appearance › Answer actions, turn off Rings on screen and ask "where is …" about visible text. Then turn off Insert & Replace and repeat step 7. Turn both back on.
   **Expected:** with rings off, no rings, no step-pointer ring and no "jump" links appear. With insert off, the main button is always Copy.

10. **Rings, light and dark.** Ask "where is …" about visible text in light mode, then in dark mode.
    **Expected:** a soft feathered wash with no outline, readable in both.

11. **Drag.** Drag the listening pill, an answer card and the research capsule by their backgrounds. Then click a card's button and a link inside a card.
    **Expected:** each follows the pointer. The next answer in the same conversation opens where you left the card, without its tail. A new conversation (⌘N) goes back to normal placement. Buttons and links still work.

12. **Status spot and glow.** In Settings › Appearance, try Listening and status at top centre, then bottom centre, and listen to a spoken reply.
    **Expected:** the pill and status sit at the chosen spot on the display under the pointer, below the research capsule at the top. The pill glows while it speaks.

13. **Menu bar.** Ask a question while watching the menu bar. Click a problem line, if one shows.
    **Expected:** the orb pulses while thinking (steady with Reduce Motion), has curved eyes when idle and open eyes while listening, and is an outline with flat eyes when paused. A red badge shows only while a required permission is missing. A problem line opens the right Settings tab.

14. **ElevenLabs.** In Settings › Voice, choose ElevenLabs, paste your key and press Save & Check. Pick a voice, ask a question, then Remove Key.
    **Expected:** the voice list appears. Replies use that voice. After Remove Key, replies use the Mac voice, or Kokoro if you had it chosen before ElevenLabs in the same visit.

15. **Spaces, full-screen apps, Stage Manager, second display.** Summon and ask over a full-screen app, on a second Space, with Stage Manager on, and on a second display if you have one.
    **Expected:** the overlay appears on the active Space and display without switching Spaces or taking focus from your app, and typing goes back to your app afterwards. (A card in Lumi's own full-screen view (F) can't be dragged; that's intended.)

16. **Voice step.** On a first run, reach the Voice page and wait a few seconds, then press Continue. Later, tap the Lumi key and speak.
    **Expected:** Mac speech recognition and Mac voice are selected and set up at once, with progress, ending in "Ready" (macOS may add its English speech files first). Parakeet and Kokoro say "Recommended" with a size and Download; nothing downloads until one is clicked. There is no "Not now, I'll type". Voice works later with no "Voice isn't set up".

17. **Settings › Voice: switching and removing models.** With voice set up, choose Parakeet (or Kokoro) when it isn't downloaded, then press Download. Then switch back to the Mac's option and press Remove… on that model's row, then Remove.
    **Expected:** choosing it downloads nothing; a row says it isn't on this Mac yet, with its size and Download, and Lumi keeps using the current one until Download is clicked. The model in use says "In use" with no Remove. Removing an unused model frees the space and changes no setting; voice keeps working.

18. **Permission card and Fix chip.** Turn Accessibility off for Lumi in System Settings. Open Settings, then close an answer with Esc.
    **Expected:** a card at the top of every Settings pane names the missing permission, and the Privacy tab shows a warning icon. After the Esc, a chip says Lumi needs Accessibility; Fix opens the right pane. It shows once per run and goes after 8 s.

19. **Connections.** In Settings › Connections, Add… Context7, ask a question, then Remove… it. On a first run, the Connections page follows Voice.
    **Expected:** "Added · checked on your next question", then Connected. Slack, Linear, Notion and Atlassian offer "Connect on claude.ai". The onboarding page is optional.

20. **Conversations.** Open Conversations (⌘Y), click a few past conversations, then Resume one and ask.
    **Expected:** each one's turns show on the right, oldest first, without a "Loading…" flash. After Resume it's marked Current and the next question continues it.

21. **Tuck and recall.** With an answer up, close it each way in turn: click elsewhere, Esc, ✕, switch app. After each, left-click the menu-bar orb. Once, right-click the orb; once, open Lumi from Applications.
    **Expected:** nothing dims the screen. Each close folds the answer into the orb; a left-click brings it back, another tucks it. Right-click opens the menu with Show Last Answer first. Reopening recalls it. A new question clears it.

22. **Chip Copy, rings, type and glass.** On a short chip, click its Copy icon and paste. Ask "where is …" in light mode, then dark. Look at a card.
    **Expected:** "Copied", and the paste is the chip's line. The wash is ember in light and a softer mist in dark, gone after about 6 s or at the next question. Cards are glass with 15 pt headlines.

23. **Reply hint.** Reply to an answer once by tapping the key, and to a later answer by clicking it and typing. Ask again, then quit, reopen and ask once more.
    **Expected:** "tap <key> to reply · click to type" shows under answers until you've done both; after that it's gone, with no blank row, even after reopening.
