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

20. **The Lumi window.** Choose Open Lumi in the menu, click a few past sessions in the sidebar, then type a follow-up in one. Press ⌘, and ⌘K.
    **Expected:** Home shows the orb, a composer and the health strip. Each session's turns show oldest first, full answers included, without a "Loading…" flash. The follow-up continues that session. ⌘, opens Settings in the sidebar; ⌘K focuses search.

21. **Tuck and recall.** With an answer up, close it each way in turn: click elsewhere, Esc, ✕, switch app. After each, left-click the menu-bar orb. Once, right-click the orb; once, open Lumi from Applications.
    **Expected:** nothing dims the screen. Each close folds the answer into the orb; a left-click brings it back, another tucks it. Right-click opens the menu with Show Last Answer first. Reopening recalls it. A new question clears it.

22. **Chip Copy, rings, type and glass.** On a short chip, click its Copy icon and paste. Ask "where is …" in light mode, then dark. Look at a card.
    **Expected:** "Copied", and the paste is the chip's line. The wash is ember in light and a softer mist in dark, gone after about 6 s or at the next question. Cards are glass with 15 pt headlines.

23. **Reply hint.** Reply to an answer once by tapping the key, and to a later answer by clicking it and typing. Ask again, then quit, reopen and ask once more.
    **Expected:** "tap <key> to reply · click to type" shows under answers until you've done both; after that it's gone, with no blank row, even after reopening.

24. **Sessions across apps.** Ask by voice about the front app. Within 30 minutes, ask a follow-up from a different app, then one with a terminal in a repo in front.
    **Expected:** all three land in the same session (one row in the Lumi window's sidebar), with a short title and an icon. Nothing says "new".

25. **Tab switcher.** With three or more sessions, hold the Lumi key and press Tab, then Tab and ⇧Tab. Release once while speaking, once silently. Then hold, Tab, and press N.
    **Expected:** the strip grows out of the listening pill (top centre, or bottom with Settings › Appearance › Listening and status at the bottom), on the screen with the pointer, showing the last few sessions and New; the first Tab lands on the previous session, and the front app never gets the Tab. Speaking sends the words to the highlighted session; a silent release makes it current and peeks its last answer for about 4 s. N starts a new session.

26. **Panel.** Double-tap the key and type a question whose answer has a code block. Then press the Lumi key while the Panel shows that session, and speak.
    **Expected:** the Panel opens and the answer streams in as Markdown with the code block. Nothing is spoken unless Settings › Voice says so. The spoken turn lands in the same page, with no Glance card.

27. **Background work and approvals.** Start a long typed task that edits a file, switch to another app and wait.
    **Expected:** a capsule at the top centre shows it running, one per running question. An approval turns it amber, and a click opens what's needed; "yes" works for an edit inside the session's folder, while commands, web and anything that sends need a click. When it finishes, the answer waits as a Ready capsule and never covers a card you're reading (one banner instead if you've been away for 2 minutes or more).

28. **Teammates.** By voice, ask for a job that splits well ("compare these three files").
    **Expected:** Lumi proposes the split in one line and waits for your yes. Each teammate gets a name and its own lane; Stop stops them.

29. **Quit mid-turn.** Start a long answer, quit Lumi from the menu, reopen it and open that session.
    **Expected:** the turn reads "Interrupted" with Continue; Continue picks the turn up. Idle sessions reopen with their history, including turns from before a `/compact`.

30. **Dictation key.** Check Settings › General for the dictation key and why it was picked. In TextEdit, tap it, speak for a minute with pauses, and tap again. Then hold it, speak and let go. Then press ⌘C quickly with ⌘ as the dictation key.
    **Expected:** both times the words are typed at the cursor and nothing reaches Claude; pauses never stop it. Each dictation shows on the Lumi window's Dictation page. A quick ⌘C never starts the mic.

31. **Kill switch.** `defaults write com.loomtable.lumi v2.sessions -bool NO`, reopen Lumi, ask twice. Then `defaults delete com.loomtable.lumi v2.sessions` and reopen.
    **Expected:** with the switch off: answers only in the Glance and no strip. The Lumi window stays the only window, and no Conversations or old Settings window ever opens. After the delete, everything is back.

32. **Edit an earlier question.** In a session with three turns, hover the first question in the Panel, click Edit, change it and send.
    **Expected:** the turns below it are replaced by the new answer; if a later reply changed files, the first Send warns that those changes stay.

33. **Composer.** In the Panel, paste a screenshot with ⌘V, type `@` and pick a file, then type `/` at the start and pick a command.
    **Expected:** the picture shows as a thumbnail and reaches Claude; the menu floats above the field; the file becomes `@path`.

34. **Themes and Dock.** Switch Settings › Appearance through each theme with a session page, the Panel and a card open. Turn off Settings › General › Show in Dock and relaunch.
    **Expected:** every surface switches at once and stays readable; the Dock icon opens the Lumi window, and it's gone after the relaunch with Show in Dock off.
