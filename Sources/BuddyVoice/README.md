# BuddyVoice

Mic capture, speech-to-text, end-of-speech safeguards, reply speech, level meters and sounds.

## Using it

```swift
let voice = VoiceController.live(settings: VoiceSettings())
try await voice.prepare()                  // loads models, warms Kokoro, prepares the mic (mic stays off);
                                           // progress in `prepareState` / `.prepare(_)`; call again to retry
try await voice.startListening()           // key press
try await voice.startListening(.dictation) // dictation key: no silence stop, 60 min, chunked
let text = try await voice.finishListening() // second tap or release → transcript for the bridge
try await voice.speak(reply.say)           // returns once playing; .speakingFinished when done
try await voice.speak(rest, continuing: true)  // queued after the reply in flight, not cutting it
for await event in voice.events { … }     // states: warnings, auto-stops, mic problems — never words
for await level in voice.levels { … }     // .mic / .reply loudness, 0…1 every ~20 ms
```

Esc on more than 30 s of speech: `discard()` returns `.needsConfirmation`; call `interrupt(.confirmingDiscard)` to stop the mic and hold the recording while asking, then `discard(confirmed: true)`. `discard(playSound: false)` for discards the user didn't ask for. `.autoStopped(reason, held:)` says whether a recording was kept. Settings › Sounds is `setSoundsEnabled(_:)` (or `VoiceSettings.soundsEnabled`).

`VoiceController` is the only entry point the app needs. The transcript leaves the module only as the return value of `finishListening()` / `sendHeld()`; events carry levels and states, so the UI layer can't show what the user said.

## Parts

| Seam | Real | Fake |
| --- | --- | --- |
| `MicCapture` | `EngineMic`: AVAudioSinkNode, voice processing on by default but switched on only while capturing (a VP engine ducks other apps by 30 dB while it exists), `start()` returns once real audio arrives, 16 kHz mono from channel 0, fresh engine on any config or default-input change, zero-run and permission watchdog | `FakeMic`, `FileMic` (plays a sound file) |
| `SpeechTranscriber` | `AppleSpeechTranscriber` (macOS SpeechAnalyzer, no Lumi download) for fresh installs; `ParakeetTranscriber`: TDT v2 (batch on finish), Unified selectable (`SpeechModel`) | `FakeTranscriber` |
| `SpeechActivityDetector` | `SileroDetector`: only drives the 30 s silence stop; sending is always the user's gesture | `FakeSpeechDetector` |
| `SpeechSpeaker` | `FallbackSpeaker(KokoroSpeaker → SystemSpeaker)` through `AudioPlayback`; Kokoro speaks sentence by sentence (`SentenceSplitter`), so audio starts after the first sentence; stop within 150 ms | `FakeSpeaker` |
| `ElevenLabsSpeaker` (opt-in, Settings › Voice) | Eleven v4 Turbo over `ElevenLabsClient` (streamed 24 kHz PCM, key in the Keychain via `KeychainSecretStore`); same sentence and `continueReply` contract as Kokoro; account failures throw `loadFailed`, network ones `synthesisFailed`, so `FallbackSpeaker` uses the on-device voice. `ElevenLabsAccount` checks keys and lists voices | `ScriptedStreamer` (tests), `FakeSecretStore`, `FakeElevenLabsAccount` |
| `SoundPlayer` | `TonePlayer` (`ToneSynth`) | `FakeSoundPlayer` |
| `VoiceClock` | `SystemVoiceClock` | `FakeClock` |

Pure logic with its own tests: `ListenSafeguards` (30 s silence, 1:45 warning, 2:00 stop, confirm discarding over 30 s of speech; a dictation has no silence stop and a 60-minute limit that keeps the recording), `VoiceController.nextChunk` (a dictation's transcript moves to a new chunk at the first pause after 45 s, or after 5 min, so its length never matters and a failed chunk loses only itself), `LevelMeter` / `MeterFramer` (20 ms frames, 30 ms rise, 250 ms mic / 120 ms reply fall), `InputHealth`, `SampleRing`, `Resampler`.

## Measured rules (don't undo them)

- Use `AVAudioSinkNode`, not `installTap`: taps deliver 100 ms buffers whatever size you ask for.
- Never keep a voice-processing engine at idle, not even unprepared or stopped: it ducks every other app's audio by 30 dB (measured with a Core Audio process tap). Only releasing the engine or `setVoiceProcessingEnabled(false)` ends it; no ducking level is zero (`.min` −8 dB is used while listening). VP can only be switched on an engine that isn't prepared (−10849).
- On a configuration change or a default-input change, build a fresh engine from `inputNode.inputFormat(forBus:)`. Reusing the engine either raises an uncatchable NSException (stale format) or fails with −10875 (voice processing). With voice processing on, the engine doesn't follow default-input changes by itself.
- Build every framework callback in a `nonisolated static` factory (runtime isolation trap).
- A revoked mic permission arrives as exact zeros with no error, which is why the zero-run watchdog exists.

## Known issues

- **Parakeet Unified (optional, not the default) dropped the last word once in 4 live runs** ("…filter yes" instead of "yesterday."). All audio had reached the transcriber, so the loss is inside FluidAudio's streaming `finish()`. It happened while CoreML was recompiling after a toolchain update. Until it's reproduced with a warm CoreML cache and fixed, Settings › Voice shows Unified only as "experimental". TDT v2, the default, was complete in every run.

## What's stored

Models live under `VoiceSettings.modelsDirectory` (`~/Library/Application Support/<bundle id>/models`, the release app's `com.loomtable.lumi`). One exception: FluidAudio 0.17.7 always keeps Kokoro's English pronunciation lexicon (about 41 MB) in `~/.cache/fluidaudio/Models/kokoro` ([FluidAudio#1023](https://github.com/FluidInference/FluidAudio/issues/1023) asks for a configurable path). `VoiceStorage.locations()` lists both for Settings › Privacy. This module never writes audio or transcripts to disk; a dictation's words are kept by the app's Dictation history (`DictationHistory`, Settings › Privacy applies).

## Tests

- `Scripts/test.sh --filter BuddyVoiceTests` runs everything that needs no hardware or models.
- Opt-in live suites (models must be downloaded; set `BUDDYVOICE_MODELS_DIR` to reuse a folder):
  - `BUDDYVOICE_LIVE_MODELS=1 BUDDYVOICE_CLIP=speech.wav … --filter LiveModels` loads each model and times it.
  - `BUDDYVOICE_LIVE_E2E=1 … --filter LiveEndToEnd` asks a question through `FileMic`, transcribes it with each `SpeechModel`, then speaks a reply and times the stop.
- End-to-end tests inject audio from a file instead of speaking through the speakers. With voice processing on, the echo canceller removes whatever the Mac itself plays, so a question played out loud transcribes as nothing. That's the behaviour we want for users (a playing video never leaks into a question). A human-voice check with voice processing on is in the owner's manual test batch.
