import Foundation

/// One timestamped segment of a whisper transcription (offsets in ms from track start).
struct TranscriptSegment {
    let fromMs: Int
    let toMs: Int
    let text: String
}

/// Transcribes audio files using whisper-cli (whisper.cpp).
/// Converts m4a → wav via ffmpeg, then runs whisper-cli.
///
/// When both mic and system tracks are usable, each track is transcribed
/// separately and the segments are interleaved by timestamp into a
/// speaker-labeled dialogue ("Я" = mic, "Собеседник" = system audio).
/// Falls back to the old merged-mix mono transcription when only one track
/// is usable or the dual-track path fails.
class Transcriber {
    static let shared = Transcriber()

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "ffmpeg"
    }()

    private static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli",  // Apple Silicon Homebrew
        "/usr/local/bin/whisper-cli",     // Intel Homebrew
        "/opt/local/bin/whisper-cli",     // MacPorts
    ]

    static let defaultModelDir = NSString("~/.local/share/whisper-models").expandingTildeInPath

    /// Resolved whisper-cli path (user override or auto-detected). Nil if not found.
    var resolvedWhisperPath: String? {
        let custom = SettingsManager.shared.whisperPath
        if !custom.isEmpty {
            return FileManager.default.fileExists(atPath: custom) ? custom : nil
        }
        return Self.whisperCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Resolved model file path. May point to a file that doesn't exist yet (for download target).
    var resolvedModelPath: String {
        let custom = SettingsManager.shared.modelPath
        if !custom.isEmpty { return custom }
        let fm = FileManager.default
        for name in ["ggml-large-v3-turbo.bin", "ggml-medium.bin"] {
            let path = (Self.defaultModelDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) { return path }
        }
        return (Self.defaultModelDir as NSString).appendingPathComponent("ggml-base.bin")
    }

    private let minTrackDuration: Double = 1.0
    private let processTimeout: TimeInterval = 3600

    /// Serial queue: running multiple whisper-cli jobs in parallel saturates CPU and
    /// causes per-chunk timeouts (lost transcripts).
    private let transcriptionQueue = DispatchQueue(label: "com.local.memorai.transcribe", qos: .utility)

    var isAvailable: Bool {
        guard let wp = resolvedWhisperPath else { return false }
        return FileManager.default.fileExists(atPath: wp) &&
               FileManager.default.fileExists(atPath: resolvedModelPath)
    }

    static func sessionTag(for reference: URL) -> String {
        reference.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_mic", with: "")
            .replacingOccurrences(of: "_system", with: "")
            .replacingOccurrences(of: "call_", with: "")
    }

    static func transcriptURL(for reference: URL) -> URL {
        let stem = reference.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_mic", with: "_transcript")
            .replacingOccurrences(of: "_system", with: "_transcript")
        return reference.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("txt")
    }

    /// Transcribe a recording session by merging mic + system audio into one file.
    /// Splits into 10-minute chunks to prevent whisper hallucination loops on long recordings.
    /// `namingURL` decides the session tag and output file names; pass it when
    /// the mic audio being transcribed is not the canonical `_mic.m4a`.
    /// `micStartSeconds`/`systemStartSeconds`/`videoStartSeconds` are the
    /// host-clock starts of the three files; they put both transcripts on one
    /// timeline. Omitting them transcribes each track from its own zero, which
    /// mis-orders the dialogue by however far apart the recorders started.
    ///
    /// This is the longest thing the app does — dozens of whisper runs over
    /// hours — so the recording gate has to reach inside the loop rather than
    /// only between stages. It does: `ProcessRunner` refuses to start a
    /// `.postProcessing` child while a recording is on, so the next chunk comes
    /// straight back cancelled and the track reports `.paused`. Finished chunks
    /// are kept on disk, so the resumed run costs the interrupted chunk and
    /// nothing more.
    ///
    /// `completion` reports whether the transcript is settled. `false` means
    /// the run paused for a recording and must be resumed — the caller must not
    /// record the stage as done on it.
    func transcribeSession(micURL: URL?, systemURL: URL?, namingURL: URL? = nil,
                           micStartSeconds: Double? = nil, systemStartSeconds: Double? = nil,
                           videoStartSeconds: Double? = nil,
                           completion: @escaping (Bool) -> Void) {
        transcriptionQueue.async { [self] in
            func finish(_ settled: Bool) { DispatchQueue.main.async { completion(settled) } }
            guard isAvailable, let wp = resolvedWhisperPath else {
                log("[Transcriber] whisper-cli or model not found — skipping (whisper: \(resolvedWhisperPath ?? "not found"), model: \(resolvedModelPath))")
                finish(true)
                return
            }
            let whisperExec = wp
            let modelFile = resolvedModelPath

            guard let micDur = trackDuration(micURL), let sysDur = trackDuration(systemURL) else {
                log("[Transcriber] ⏸ Paused for a recording before the tracks could be measured")
                finish(false)
                return
            }
            let micOK = micDur >= minTrackDuration
            let sysOK = sysDur >= minTrackDuration

            log("[Transcriber] Track durations — mic: \(Int(micDur))s (ok=\(micOK)), system: \(Int(sysDur))s (ok=\(sysOK))")

            guard micOK || sysOK else {
                log("[Transcriber] Both tracks too short — skipping transcription")
                finish(true)
                return
            }

            // Names are derived from a file name, so the caller can hand in a
            // different audio file than the one the session is named after —
            // the echo-cancelled mic lives at call_<tag>_mic.aec.m4a and would
            // otherwise produce call_<tag>_transcript.aec.txt.
            let refURL = namingURL ?? (micOK ? micURL : systemURL)!
            let dir = refURL.deletingLastPathComponent()
            let baseName = refURL.deletingPathExtension().lastPathComponent
            let sessionTag = Self.sessionTag(for: refURL)
            let txtPath = Self.transcriptURL(for: refURL)

            var existingIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: txtPath.path, isDirectory: &existingIsDirectory),
               !existingIsDirectory.boolValue {
                log("[Transcriber] Transcript already exists: \(txtPath.lastPathComponent)")
                finish(true)
                return
            }

            let lang = SettingsManager.shared.whisperLanguage
            var fullTranscript = ""

            func paused() {
                log("[Transcriber] [\(sessionTag)] ⏸ Paused for a recording — resumes from the finished chunks")
                finish(false)
            }
            func mergedMix() -> StageOutcome<String> {
                transcribeMergedMix(micURL: micURL, systemURL: systemURL, micOK: micOK, sysOK: sysOK,
                                    whisperExec: whisperExec, modelFile: modelFile, lang: lang,
                                    dir: dir, baseName: baseName, sessionTag: sessionTag)
            }

            var mixedFallback = false
            if micOK && sysOK {
                log("[Transcriber] [\(sessionTag)] Dual-track transcription (speaker-labeled, model: \((modelFile as NSString).lastPathComponent))")
                let micOutcome = transcribeTrack(micURL!, roleTag: "mic", whisperExec: whisperExec,
                                                 modelFile: modelFile, lang: lang, dir: dir,
                                                 sessionTag: sessionTag)
                if case .paused = micOutcome { paused(); return }
                let sysOutcome = transcribeTrack(systemURL!, roleTag: "system", whisperExec: whisperExec,
                                                 modelFile: modelFile, lang: lang, dir: dir,
                                                 sessionTag: sessionTag)
                if case .paused = sysOutcome { paused(); return }
                let micSegs = micOutcome.value
                let sysSegs = sysOutcome.value
                if let micSegs = micSegs, let sysSegs = sysSegs, !(micSegs.isEmpty && sysSegs.isEmpty) {
                    let offsets = AudioMuxer.computeOffsets(micStart: micStartSeconds,
                                                            systemStart: systemStartSeconds,
                                                            videoStart: videoStartSeconds)
                    if offsets.mic != 0 || offsets.system != 0 {
                        log(String(format: "[Transcriber] [\(sessionTag)] Aligning speakers (mic %+.3fs, system %+.3fs)",
                                   offsets.mic, offsets.system))
                    }
                    fullTranscript = Self.dialogueTranscript(
                        mic: Self.shifted(micSegs, bySeconds: offsets.mic),
                        system: Self.shifted(sysSegs, bySeconds: offsets.system))
                } else {
                    log("[Transcriber] [\(sessionTag)] ⚠️ Dual-track path failed — falling back to merged mix")
                    mixedFallback = true
                }
            } else {
                mixedFallback = true
            }

            if mixedFallback {
                let mixed = mergedMix()
                if case .paused = mixed { paused(); return }
                fullTranscript = mixed.value ?? ""
            }

            if !fullTranscript.isEmpty {
                do {
                    try fullTranscript.write(to: txtPath, atomically: true, encoding: .utf8)
                    deduplicateTranscript(at: txtPath)
                    log("[Transcriber] ✅ Transcript saved: \(txtPath.lastPathComponent)")
                } catch {
                    // Keep the chunk cache: a later retry can publish the same
                    // completed inference without running the model again.
                    log("[Transcriber] ❌ Could not save transcript: \(error.localizedDescription)")
                    finish(false)
                    return
                }
            } else {
                log("[Transcriber] ❌ Whisper produced no output")
            }
            // The per-chunk records only exist to survive a pause; the
            // transcript is written, so they are just disk now.
            Self.discardPartials(tag: sessionTag, in: dir)

            finish(true)
        }
    }

    // MARK: - Dual-track (speaker-labeled) transcription

    /// How one pass of transcription ended. Generic because the two paths
    /// produce different things — the dual-track one segments, the merged mix
    /// flat text — while ending in exactly the same three ways.
    enum StageOutcome<T> {
        case done(T)
        /// A recording started mid-pass. Whatever finished is cached on disk;
        /// the resumed run starts at the first piece that is not.
        case paused
        /// The audio could not be prepared at all (ffmpeg convert failed).
        case failed

        /// The result if the pass ran to the end, nil otherwise — callers that
        /// only distinguish "usable" from "not" read this.
        var value: T? {
            if case .done(let v) = self { return v }
            return nil
        }
    }

    typealias TrackOutcome = StageOutcome<[TranscriptSegment]>

    /// Transcribe a single track into timestamped segments. Applies loudnorm,
    /// resamples to 16 kHz mono, chunks long audio (10 min) and parses
    /// whisper's JSON output.
    ///
    /// Each chunk's whisper JSON is left on disk until the whole transcript is
    /// written, so a run cut short by a recording resumes at the chunk it lost
    /// instead of redoing hours of inference.
    private func transcribeTrack(_ sourceURL: URL, roleTag: String, whisperExec: String,
                                 modelFile: String, lang: String, dir: URL,
                                 sessionTag: String) -> TrackOutcome {
        // Kept, not deleted on the way out: it is part of the same cache as the
        // chunk JSONs, and `discardPartials` clears the lot once the transcript
        // exists. Deleting it here made every resume re-decode and re-normalise
        // the whole track — half a gigabyte and a full pass, per track, per
        // pause — to reach exactly the state it was already in.
        let trackWav = dir.appendingPathComponent("_track_\(sessionTag)_\(roleTag).wav")

        if !FileManager.default.fileExists(atPath: trackWav.path) {
            // Convert under a work name and rename, so `_track_…wav` exists only
            // when it holds the WHOLE track — the same rule `call_<tag>_mic.m4a`
            // follows. A size check cannot tell a finished 500 MB wav from one
            // truncated by a kill or a timeout, and reusing a truncated one
            // would transcribe part of the call and settle the stage on it.
            // `.part.wav`, not `.wav.part`: ffmpeg picks its muxer from the
            // extension, and an unknown one makes the convert fail outright.
            let partial = dir.appendingPathComponent("_track_\(sessionTag)_\(roleTag).part.wav")
            defer { try? FileManager.default.removeItem(at: partial) }
            let convert = runProcess(ffmpegPath, args: [
                "-y", "-nostats", "-loglevel", "error", "-i", sourceURL.path,
                "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                partial.path
            ])
            if convert.wasCancelled { return .paused }
            guard convert.exitCode == 0 else {
                log("[Transcriber] [\(sessionTag)] ❌ ffmpeg convert (\(roleTag)) failed (exit \(convert.exitCode)): \(convert.stderrTail)")
                return .failed
            }
            do {
                try FileManager.default.moveItem(at: partial, to: trackWav)
            } catch {
                log("[Transcriber] [\(sessionTag)] ❌ Could not publish the prepared \(roleTag) track: \(error.localizedDescription)")
                return .failed
            }
        }

        guard let duration = trackDuration(trackWav) else { return .paused }
        let chunkSec = 600.0
        let chunks = duration <= chunkSec * 1.5 ? 1 : Int(ceil(duration / chunkSec))
        var segments: [TranscriptSegment] = []
        var gaps = 0

        for i in 0..<chunks {
            let offsetMs = i * Int(chunkSec) * 1000
            let outBase = dir.appendingPathComponent("_whisper_\(sessionTag)_\(roleTag)_\(i)")
            let jsonURL = outBase.appendingPathExtension("json")

            // A chunk an earlier, interrupted run already got through: whisper
            // only writes this file after a clean exit, so parsing it is the
            // whole of the work.
            if let cached = Self.parseWhisperJSON(jsonURL, offsetMs: offsetMs) {
                log("[Transcriber] [\(sessionTag)]   \(roleTag) chunk \(i+1)/\(chunks) — reusing an earlier run")
                segments += cached
                continue
            }

            let chunkWav: URL
            if chunks == 1 {
                chunkWav = trackWav
            } else {
                let extracted = dir.appendingPathComponent("_chunk_\(sessionTag)_\(roleTag)_\(i).wav")
                let extract = runProcess(ffmpegPath, args: [
                    "-y", "-nostats", "-loglevel", "error", "-i", trackWav.path,
                    "-ss", String(i * Int(chunkSec)), "-t", String(Int(chunkSec)),
                    "-c:a", "pcm_s16le", extracted.path
                ])
                if extract.wasCancelled { return .paused }
                guard extract.exitCode == 0 else {
                    log("[Transcriber] [\(sessionTag)] ⚠️ \(roleTag) chunk \(i+1) extraction failed, skipping")
                    gaps += 1
                    continue
                }
                chunkWav = extracted
            }
            defer { if chunks > 1 { try? FileManager.default.removeItem(at: chunkWav) } }

            // One retry: a whisper that fell over on its own usually survives a
            // second run, and the alternative is a silent ten-minute hole in
            // the middle of the transcript.
            var parsed: [TranscriptSegment]?
            for attempt in 1...2 {
                let retry = attempt > 1 ? " (retry)" : ""
                if chunks > 1 {
                    log("[Transcriber] [\(sessionTag)]   \(roleTag) chunk \(i+1)/\(chunks)\(retry)…")
                } else {
                    log("[Transcriber] [\(sessionTag)]   \(roleTag) track (\(Int(duration))s)\(retry)…")
                }
                let result = runProcess(whisperExec, args: Self.whisperArgs(
                    model: modelFile, lang: lang, output: "-oj",
                    outBase: outBase.path, input: chunkWav.path))
                if result.wasCancelled {
                    // Killed mid-write: whatever is there must not pass for a
                    // finished chunk when this session is picked back up.
                    try? FileManager.default.removeItem(at: jsonURL)
                    log("[Transcriber] [\(sessionTag)] \(roleTag) paused during chunk \(i+1)/\(chunks)")
                    return .paused
                }
                if result.exitCode == 0, let segs = Self.parseWhisperJSON(jsonURL, offsetMs: offsetMs) {
                    parsed = segs
                    break
                }
                log("[Transcriber] [\(sessionTag)] ⚠️ \(roleTag) chunk \(i+1) whisper failed (exit \(result.exitCode))")
                try? FileManager.default.removeItem(at: jsonURL)
            }

            if let parsed = parsed {
                segments += parsed
            } else {
                gaps += 1
                let from = Self.timestamp(ms: offsetMs)
                let to = Self.timestamp(ms: offsetMs + Int(chunkSec) * 1000)
                log("[Transcriber] [\(sessionTag)] ❌ \(roleTag) chunk \(i+1)/\(chunks) lost after 2 attempts — \(from)–\(to) is missing from the transcript")
            }
        }

        if gaps > 0 {
            log("[Transcriber] [\(sessionTag)] ⚠️ \(roleTag) track finished with \(gaps) of \(chunks) chunk(s) missing")
        }
        return .done(segments)
    }

    /// Every per-chunk record left over from an interrupted transcription of
    /// `tag`. Kept only between a pause and the resume that uses them.
    static func discardPartials(tag: String, in dir: URL) {
        let prefixes = RetentionManager.transcriptionCachePrefixes(tag: tag)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where prefixes.contains(where: name.hasPrefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// The one place whisper is invoked from. There used to be three copies of
    /// this list and they had already drifted: `-t 2` was added to two of them
    /// and the merged-mix chunk loop kept spawning a run on every core, which
    /// is the path a long call takes whenever the dual-track one fails.
    ///
    /// Two threads, not all of them: even gated out of live calls, whisper
    /// shares the machine with whatever the user is doing.
    static func whisperArgs(model: String, lang: String, output: String,
                            outBase: String, input: String) -> [String] {
        ["-m", model, "-l", lang,
         "-t", "2",
         "-et", "2.2", "-lpt", "-0.5",
         output, "-of", outBase,
         input]
    }

    /// Parse whisper-cli -oj output into segments, shifting offsets by `offsetMs`.
    /// Drops empty segments and non-speech annotations like "[BLANK_AUDIO]" or "(music)".
    static func parseWhisperJSON(_ url: URL, offsetMs: Int) -> [TranscriptSegment]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["transcription"] as? [[String: Any]] else { return nil }
        var segments: [TranscriptSegment] = []
        for item in items {
            guard let offsets = item["offsets"] as? [String: Any],
                  let from = offsets["from"] as? Int,
                  let to = offsets["to"] as? Int,
                  let text = item["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isNonSpeechAnnotation(trimmed),
                  !isHallucinatedSegment(trimmed) else { continue }
            segments.append(TranscriptSegment(fromMs: from + offsetMs, toMs: to + offsetMs, text: trimmed))
        }
        return segments
    }

    /// Whisper emits sound-event pseudo-segments like "[BLANK_AUDIO]", "(музыка)", "*звонок*".
    static func isNonSpeechAnnotation(_ text: String) -> Bool {
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*")]
        for (open, close) in pairs {
            if text.first == open && text.last == close { return true }
        }
        return false
    }

    // MARK: - Hallucination filter

    /// Stock outro phrases whisper hallucinates on trailing silence: the model
    /// was trained on subtitled video, so silence decodes into typical subtitle
    /// endings. Matched against a WHOLE segment/line only (after
    /// normalization), so real sentences containing these words survive.
    static let hallucinationPhrases: Set<String> = [
        "продолжение следует",
        "спасибо за просмотр",
        "до новых встреч",
        "to be continued",
        "thanks for watching",
        "thank you for watching",
    ]

    /// Subtitle-credit hallucinations ("Субтитры сделал DimaTorzok", "Редактор
    /// субтитров А.Синецкая…") — matched as prefixes of a normalized segment.
    static let hallucinationPrefixes: [String] = [
        "субтитры сделал",
        "субтитры создавал",
        "субтитры делал",
        "субтитры сделаны",
        "субтитры подготов",
        "редактор субтитров",
        "subtitles by",
    ]

    private static let hallucinationTrimSet =
        CharacterSet(charactersIn: " \t\n.,!?…-–—:;\"'«»()[]")

    static func normalizedHallucinationText(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: hallucinationTrimSet)
    }

    /// True when the entire segment/line is a known whisper hallucination.
    static func isHallucinatedSegment(_ text: String) -> Bool {
        let norm = normalizedHallucinationText(text)
        guard !norm.isEmpty else { return false }
        if hallucinationPhrases.contains(norm) { return true }
        if hallucinationPrefixes.contains(where: { norm.hasPrefix($0) }) { return true }
        if norm.contains("dimatorzok") || norm.contains("amara.org") { return true }
        return false
    }

    /// Strip hallucinated outro phrases off the END of flat text. Needed for
    /// dictation, where whisper-server returns one line and a per-line whole-
    /// match can't catch "…я закончил мысль. Продолжение следует...".
    static func stripTrailingHallucinations(_ text: String) -> String {
        let alternatives = hallucinationPhrases
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let re = try? NSRegularExpression(
            pattern: "(?:^|\\s)(?:\(alternatives))[\\s.,!?…]*$",
            options: [.caseInsensitive]) else { return text }

        var result = text
        // A few passes: outros can stack ("…следует... Спасибо за просмотр!").
        for _ in 0..<3 {
            let range = NSRange(result.startIndex..., in: result)
            guard let m = re.firstMatch(in: result, range: range),
                  let r = Range(m.range, in: result) else { break }
            result = String(result[..<r.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Interleave mic ("Я") and system ("Собеседник") segments by start time into
    /// a dialogue transcript, grouping consecutive same-speaker segments into one line.
    /// Moves a track's segments onto the shared timeline. The two recorders do
    /// not start together — the SCStream is up before the mic engine, measured
    /// at 1.19 s apart on a real call — so timestamps read straight off each
    /// track interleave the dialogue in the wrong order around a handover.
    /// AudioMuxer already computes these offsets for the video; this applies
    /// the same numbers to the transcript.
    static func shifted(_ segments: [TranscriptSegment], bySeconds offset: Double) -> [TranscriptSegment] {
        let ms = Int((offset * 1000).rounded())
        guard ms != 0 else { return segments }
        return segments.map {
            TranscriptSegment(fromMs: max(0, $0.fromMs + ms),
                              toMs: max(0, $0.toMs + ms),
                              text: $0.text)
        }
    }

    /// A silence longer than this between two utterances of the SAME speaker
    /// starts a fresh line with its own timestamp instead of extending the run.
    /// Without it, one participant monologuing while the other stays quiet
    /// collapses into a single wall-of-text paragraph under one timestamp — a
    /// real 30-minute daily on 2026-08-11 rendered as 7 lines, one of them a
    /// solid 9-minute block.
    ///
    /// 5 s, measured rather than guessed: `silencedetect` over that call's
    /// far-end track found 2 silences of 20 s, 3 of 10 s, but 23 of 5 s — so a
    /// 20 s rule would have left the 9-minute block almost intact, while 5 s
    /// yields a fresh timestamp roughly every 75 s. It cannot fragment ordinary
    /// dialogue: a change of speaker already ends a line, so this only ever
    /// splits one person talking to themselves for a while.
    static let sameSpeakerGapBreakMs = 5_000

    /// Hard ceiling on how much wall-clock one line may cover, whatever the
    /// pauses do. Needed because the pause rule alone did not deliver: on the
    /// 2026-08-11 daily it turned 7 lines into 19, but the worst block only
    /// shrank from 9.4 to 7.7 minutes — whisper routinely stretches a segment
    /// across a short silence, so the gaps it reports are smaller than the
    /// silence actually in the audio. The break lands on a segment boundary,
    /// so a sentence is never cut in half; a block ends up spanning this plus
    /// the length of the segment that crossed the line.
    static let sameSpeakerMaxRunMs = 90_000

    static func dialogueTranscript(mic: [TranscriptSegment], system: [TranscriptSegment]) -> String {
        dialogueTranscript(mic.map { (seg: $0, speaker: "Я") } + system.map { (seg: $0, speaker: "Собеседник") })
    }

    static func dialogueTranscript(_ input: [(seg: TranscriptSegment, speaker: String)]) -> String {
        var tagged = input
        tagged.sort { $0.seg.fromMs < $1.seg.fromMs }
        guard !tagged.isEmpty else { return "" }

        var lines: [String] = []
        var curSpeaker = tagged[0].speaker
        var curStart = tagged[0].seg.fromMs
        var curEnd = tagged[0].seg.toMs
        var curText = tagged[0].seg.text
        for entry in tagged.dropFirst() {
            let gap = entry.seg.fromMs - curEnd
            let run = entry.seg.fromMs - curStart
            if entry.speaker == curSpeaker
                && gap <= Self.sameSpeakerGapBreakMs
                && run < Self.sameSpeakerMaxRunMs {
                curText += " " + entry.seg.text
                curEnd = max(curEnd, entry.seg.toMs)
            } else {
                lines.append(formatDialogueLine(startMs: curStart, speaker: curSpeaker, text: curText))
                curSpeaker = entry.speaker
                curStart = entry.seg.fromMs
                curEnd = entry.seg.toMs
                curText = entry.seg.text
            }
        }
        lines.append(formatDialogueLine(startMs: curStart, speaker: curSpeaker, text: curText))
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatDialogueLine(startMs: Int, speaker: String, text: String) -> String {
        return "[\(timestamp(ms: startMs))] \(speaker): \(text)"
    }

    /// Offset from the start of the call as it reads in the transcript.
    static func timestamp(ms: Int) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Merged-mix (single-speaker) transcription

    /// The original merged-mono path: mix usable tracks into one 16 kHz wav and
    /// transcribe as plain text. Used when only one track is usable or the
    /// dual-track path fails.
    private func transcribeMergedMix(micURL: URL?, systemURL: URL?, micOK: Bool, sysOK: Bool,
                                     whisperExec: String, modelFile: String, lang: String,
                                     dir: URL, baseName: String, sessionTag: String)
                                     -> StageOutcome<String> {
        let mergedWav = dir.appendingPathComponent(
            baseName.replacingOccurrences(of: "_mic", with: "_merged")
                    .replacingOccurrences(of: "_system", with: "_merged") + ".wav"
        )
        defer { try? FileManager.default.removeItem(at: mergedWav) }

        // Merge both tracks only when both are long enough. Otherwise use the usable single track
        // to avoid diluting a good track with a broken one.
        log("[Transcriber] Preparing audio (\(micOK && sysOK ? "merge mic+system" : (micOK ? "mic only" : "system only")))")
        let convertResult: ProcessRunner.Result
        if micOK && sysOK {
            convertResult = runProcess(ffmpegPath, args: [
                "-y", "-nostats", "-loglevel", "error",
                "-i", micURL!.path,
                "-i", systemURL!.path,
                "-filter_complex",
                "[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                + "[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[sys];"
                + "[mic][sys]amix=inputs=2:duration=longest[a]",
                "-map", "[a]",
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                mergedWav.path
            ])
        } else {
            let sourceURL = micOK ? micURL! : systemURL!
            convertResult = runProcess(ffmpegPath, args: [
                "-y", "-nostats", "-loglevel", "error", "-i", sourceURL.path,
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                mergedWav.path
            ])
        }

        if convertResult.wasCancelled { return .paused }
        guard convertResult.exitCode == 0 else {
            log("[Transcriber] ❌ ffmpeg merge failed (exit \(convertResult.exitCode)): \(convertResult.stderrTail)")
            return .failed
        }

        guard let duration = trackDuration(mergedWav) else { return .paused }
        let chunkSec = 600.0 // 10 minutes per chunk
        var fullTranscript = ""

        if duration <= chunkSec * 1.5 {
            log("[Transcriber] Transcribing merged audio (\(Int(duration))s, model: \((modelFile as NSString).lastPathComponent))...")
            let tmpBase = dir.appendingPathComponent("_whisper_tmp")
            let result = runProcess(whisperExec, args: Self.whisperArgs(
                model: modelFile, lang: lang, output: "-otxt",
                outBase: tmpBase.path, input: mergedWav.path))
            if result.wasCancelled {
                try? FileManager.default.removeItem(at: tmpBase.appendingPathExtension("txt"))
                return .paused
            }
            if result.exitCode == 0,
               let text = try? String(contentsOf: tmpBase.appendingPathExtension("txt"), encoding: .utf8) {
                fullTranscript = text
            } else if result.exitCode != 0 {
                log("[Transcriber] ❌ Whisper failed (exit \(result.exitCode)): \(result.stderr.suffix(500))")
            }
            try? FileManager.default.removeItem(at: tmpBase.appendingPathExtension("txt"))
        } else {
            let chunks = Int(ceil(duration / chunkSec))
            log("[Transcriber] [\(sessionTag)] Transcribing \(chunks) chunks (\(Int(duration))s total, model: \((modelFile as NSString).lastPathComponent))...")

            for i in 0..<chunks {
                let offset = Double(i) * chunkSec
                let chunkWav = dir.appendingPathComponent("_chunk_\(sessionTag)_\(i).wav")
                let chunkBase = dir.appendingPathComponent("_chunk_\(sessionTag)_\(i)")

                let extractResult = runProcess(ffmpegPath, args: [
                    "-y", "-nostats", "-loglevel", "error", "-i", mergedWav.path,
                    "-ss", String(Int(offset)), "-t", String(Int(chunkSec)),
                    "-c:a", "pcm_s16le", chunkWav.path
                ])
                if extractResult.wasCancelled { return .paused }
                guard extractResult.exitCode == 0 else {
                    log("[Transcriber] [\(sessionTag)] ⚠️ Chunk \(i+1) extraction failed, skipping")
                    continue
                }

                log("[Transcriber] [\(sessionTag)]   Chunk \(i+1)/\(chunks) @ \(Int(offset))s…")
                let result = runProcess(whisperExec, args: Self.whisperArgs(
                    model: modelFile, lang: lang, output: "-otxt",
                    outBase: chunkBase.path, input: chunkWav.path))

                if result.wasCancelled {
                    try? FileManager.default.removeItem(at: chunkWav)
                    try? FileManager.default.removeItem(at: chunkBase.appendingPathExtension("txt"))
                    return .paused
                }
                if result.exitCode == 0,
                   let text = try? String(contentsOf: chunkBase.appendingPathExtension("txt"), encoding: .utf8) {
                    fullTranscript += text
                } else {
                    log("[Transcriber] [\(sessionTag)] ⚠️ Chunk \(i+1) whisper failed (exit \(result.exitCode))")
                }

                try? FileManager.default.removeItem(at: chunkWav)
                try? FileManager.default.removeItem(at: chunkBase.appendingPathExtension("txt"))
            }
        }

        return .done(fullTranscript)
    }

    /// Get media file duration in seconds via ffmpeg. Returns 0 on failure or missing file.
    ///
    /// No output file: ffmpeg prints the container's duration and exits without
    /// decoding anything. It used to decode the whole track to `-f null -`,
    /// which on a four-hour call meant burning the full 10 s timeout — twice
    /// per transcription — and then parsing the very same header line it had
    /// printed in the first second.
    private func trackDuration(_ url: URL?) -> Double? {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let result = runProcess(ffmpegPath, args: ["-hide_banner", "-nostats", "-i", url.path], timeout: 10)
        // Nil is "could not measure", which is NOT "the track is empty". The
        // probe runs through the same gate as everything else, and a refused
        // probe reading as a zero-length track once made a whole session settle
        // as "both tracks too short" — losing its transcript for good.
        if result.wasCancelled { return nil }
        let output = result.stderr
        if let match = try? NSRegularExpression(pattern: #"Duration: (\d+):(\d+):(\d+\.\d+)"#)
                .firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            let h = Double((output as NSString).substring(with: match.range(at: 1))) ?? 0
            let m = Double((output as NSString).substring(with: match.range(at: 2))) ?? 0
            let s = Double((output as NSString).substring(with: match.range(at: 3))) ?? 0
            return h * 3600 + m * 60 + s
        }
        return 0
    }

    /// Remove hallucination loops: exact duplicates and near-duplicate runs.
    func deduplicateTranscript(at url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let rawLines = content.components(separatedBy: "\n")

        // Pass 0: drop whole-line subtitle outros ("Продолжение следует...")
        // — covers the merged-mix path where segments aren't parsed as JSON.
        let lines = rawLines.filter { !Self.isHallucinatedSegment($0) }

        // Pass 1: collapse exact consecutive duplicates
        var deduped: [String] = []
        var prevTrimmed: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed != prevTrimmed {
                deduped.append(line)
            }
            prevTrimmed = trimmed
        }

        // Pass 2: collapse near-duplicate runs (same prefix of 15+ chars, 3+ in a row)
        let prefixLen = 15
        var result: [String] = []
        var i = 0
        while i < deduped.count {
            let trimmed = deduped[i].trimmingCharacters(in: .whitespaces)
            if trimmed.count >= prefixLen {
                let prefix = String(trimmed.prefix(prefixLen))
                var runEnd = i + 1
                while runEnd < deduped.count {
                    let nextTrimmed = deduped[runEnd].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(prefix) {
                        runEnd += 1
                    } else {
                        break
                    }
                }
                let runLen = runEnd - i
                if runLen >= 3 {
                    result.append(deduped[i])
                    i = runEnd
                    continue
                }
            }
            result.append(deduped[i])
            i += 1
        }

        let cleaned = result.joined(separator: "\n")
        try? cleaned.write(to: url, atomically: true, encoding: .utf8)

        let removed = rawLines.count - result.count
        if removed > 0 {
            log("[Transcriber] Dedup: removed \(removed) hallucinated lines")
        }
    }

    // MARK: - Model Download

    func downloadBaseModel(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        guard let url = URL(string: urlString) else { return }

        let destDir = Self.defaultModelDir
        let destPath = (destDir as NSString).appendingPathComponent("ggml-base.bin")
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let delegate = DownloadDelegate(destPath: destPath, progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        activeDownloadDelegate = delegate
        session.downloadTask(with: url).resume()
    }

    private var activeDownloadDelegate: DownloadDelegate?

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let destPath: String
        private let progressHandler: (Double) -> Void
        private let completionHandler: (Error?) -> Void

        init(destPath: String, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
            self.destPath = destPath
            self.progressHandler = progress
            self.completionHandler = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
            let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            DispatchQueue.main.async { self.progressHandler(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                let dest = URL(fileURLWithPath: destPath)
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                DispatchQueue.main.async { self.completionHandler(nil) }
            } catch {
                DispatchQueue.main.async { self.completionHandler(error) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                DispatchQueue.main.async { self.completionHandler(error) }
            }
        }
    }

    /// Run a subprocess as post-processing work: background priority, and
    /// cancellable the moment a recording starts.
    ///
    /// This used to be a second, hand-rolled copy of ProcessRunner — which
    /// meant lowering the priority of "our subprocesses" in one place quietly
    /// missed whisper, the heaviest of them all. One runner, one place to
    /// change.
    private func runProcess(_ path: String, args: [String], timeout: TimeInterval? = nil) -> ProcessRunner.Result {
        ProcessRunner.run(path, args: args, timeout: timeout ?? processTimeout, role: .postProcessing)
    }
}
