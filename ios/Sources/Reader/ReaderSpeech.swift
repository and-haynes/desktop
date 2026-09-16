//  ReaderSpeech.swift
//  Read aloud: where the sentences are, and the synthesizer that speaks them.
//
//  ## Why the chunker owns offsets
//
//  Highlighting the sentence being spoken means turning "utterance 14" back
//  into a DOM range, and the only way that is exact is if both ends agree on
//  one string. So the reader page hands Swift *its own* flattened text — the
//  concatenation of the text nodes it rendered, with an index alongside — and
//  the chunking happens over that. A sentence is then a pair of offsets the
//  page can map straight back onto a `Range` with no searching and no guessing.
//
//  Offsets are **UTF-16**, because that is what a JavaScript string index is.
//  An article with an emoji or a CJK character in it would otherwise drift by
//  one from the first one onwards, and drift silently.
//
//  ## The rules
//
//  Sentence splitting is a bottomless problem and this is not a linguistics
//  project: the bar is "does the highlight move roughly when the voice does".
//  Terminators end a sentence, a paragraph break ends one, and four things
//  that look like terminators do not — an abbreviation (`Dr.`), an initial
//  (`J. R. R.`), a decimal point (`3.14`), and a run of them (`...`). A stretch
//  with no terminator at all is broken up anyway, because handing the
//  synthesizer four hundred characters means a highlight that does not move for
//  half a minute.

import AVFoundation
import Foundation

/// One spoken unit, and where it is in the source text.
struct ReaderSentence: Equatable, Sendable {
    let index: Int
    let text: String
    /// UTF-16 offset of the first character, inclusive.
    let start: Int
    /// UTF-16 offset one past the last character.
    let end: Int
}

enum ReaderSpeechChunker {

    /// Sentence-ending punctuation. `…` and the CJK stops are here because an
    /// article that uses them has no ASCII full stops at all to fall back on.
    static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// Past this many characters with no terminator in sight, break anyway.
    static let maximumLength = 320

    /// Words that end in a full stop without ending a sentence.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "rev", "gen", "col", "sgt",
        "vs", "etc", "eg", "ie", "cf", "al", "fig", "no", "vol", "pp", "ed", "approx",
        "inc", "ltd", "co", "corp", "dept", "est", "min", "max", "ca", "circa",
    ]

    /// Split `text` into sentences carrying their own offsets.
    static func sentences(in text: String) -> [ReaderSentence] {
        let characters = Array(text)
        // UTF-16 offset of each character, so a sentence's bounds can be
        // reported in the units JavaScript counts in.
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        var running = 0
        for (i, character) in characters.enumerated() {
            offsets[i] = running
            running += character.utf16.count
        }
        offsets[characters.count] = running

        var out: [ReaderSentence] = []
        var chunkStart = 0

        func flush(upTo end: Int) {
            guard end > chunkStart else { return }
            append(
                characters: characters, offsets: offsets, from: chunkStart, to: end, into: &out)
            chunkStart = end
        }

        var i = 0
        while i < characters.count {
            let character = characters[i]

            if character.isNewline {
                flush(upTo: i + 1)
                i += 1
                continue
            }

            if terminators.contains(character) {
                // Run the whole run of terminators together, so `?!` and `...`
                // are one boundary rather than three.
                var j = i
                while j + 1 < characters.count, terminators.contains(characters[j + 1]) { j += 1 }
                if isBoundary(characters, terminatorStart: i, terminatorEnd: j) {
                    // Take any closing quote or bracket with the sentence —
                    // a highlight that stops before the quote mark looks broken.
                    var end = j + 1
                    while end < characters.count, isClosing(characters[end]) { end += 1 }
                    flush(upTo: end)
                    i = end
                    continue
                }
                i = j + 1
                continue
            }

            // Nothing has ended for a long time. Break at the last comfortable
            // place rather than in the middle of a word.
            if i - chunkStart >= maximumLength {
                let breakPoint = softBreak(characters, from: chunkStart, to: i) ?? i
                flush(upTo: breakPoint)
                i = max(breakPoint, i)
                continue
            }

            i += 1
        }
        flush(upTo: characters.count)
        return out
    }

    /// Trim the whitespace off a candidate and keep it only if there is
    /// something to say — a chunk of bullet glyphs and spaces is not a sentence.
    private static func append(
        characters: [Character], offsets: [Int], from: Int, to: Int,
        into out: inout [ReaderSentence]
    ) {
        var start = from
        var end = to
        while start < end, characters[start].isWhitespace { start += 1 }
        while end > start, characters[end - 1].isWhitespace { end -= 1 }
        guard start < end else { return }
        let text = String(characters[start..<end])
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        out.append(
            ReaderSentence(
                index: out.count, text: text, start: offsets[start], end: offsets[end]))
    }

    /// Is the terminator run at `terminatorStart...terminatorEnd` the end of a
    /// sentence, or part of something else?
    private static func isBoundary(
        _ characters: [Character], terminatorStart: Int, terminatorEnd: Int
    ) -> Bool {
        let after = terminatorEnd + 1
        // End of text is always a boundary.
        guard after < characters.count else { return true }
        // Mid-word: `example.com`, `3.14`. Needs whitespace (or a closing mark
        // then whitespace) to be a sentence end at all.
        var probe = after
        while probe < characters.count, isClosing(characters[probe]) { probe += 1 }
        guard probe >= characters.count || characters[probe].isWhitespace else { return false }

        // Only a lone `.` can be an abbreviation or an initial; `?!` never is.
        guard characters[terminatorStart] == ".", terminatorStart == terminatorEnd else {
            return true
        }
        var wordStart = terminatorStart
        while wordStart > 0, characters[wordStart - 1].isLetter || characters[wordStart - 1].isNumber
        {
            wordStart -= 1
        }
        let word = String(characters[wordStart..<terminatorStart])
        // A single letter before a full stop is an initial — `J. R. R. Tolkien`,
        // and also the second half of `e.g.` and `i.e.`.
        if word.count == 1, word.first?.isLetter == true { return false }
        if abbreviations.contains(word.lowercased()) { return false }
        return true
    }

    /// The last sentence-ish seam before `limit`: a comma, a semicolon, a
    /// colon, a dash, or failing those a space.
    private static func softBreak(_ characters: [Character], from: Int, to limit: Int) -> Int? {
        let seams: Set<Character> = [",", ";", ":", "—", "–"]
        var best: Int?
        var i = limit - 1
        while i > from {
            if seams.contains(characters[i]) { return i + 1 }
            if best == nil, characters[i].isWhitespace { best = i + 1 }
            i -= 1
        }
        return best
    }

    private static func isClosing(_ character: Character) -> Bool {
        ["\"", "'", "”", "’", ")", "]", "»", "」"].contains(character)
    }
}

// MARK: - The voice

/// Drives `AVSpeechSynthesizer` one sentence at a time.
///
/// One utterance per sentence rather than one for the whole article, and the
/// next is only enqueued when the last one finishes. That costs a barely
/// perceptible beat between sentences and buys three things: the current
/// sentence is always known exactly (so the highlight cannot drift), skipping
/// forward is "stop and start the next one" rather than a queue surgery, and a
/// forty-minute article never sits in the synthesizer's buffer.
@MainActor
final class ReaderSpeech: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    /// Which sentence the voice is on, or nil when it is not reading.
    @Published private(set) var currentIndex: Int?

    /// Told whenever the spoken sentence changes — the reader page turns it
    /// into a highlighted range. Nil means "clear the highlight".
    var onSentence: ((ReaderSentence?) -> Void)?

    private(set) var sentences: [ReaderSentence] = []
    private let synthesizer = AVSpeechSynthesizer()
    /// Set while we are deliberately stopping in order to start somewhere else,
    /// so the cancellation does not read as "the article finished".
    private var isRetargeting = false

    /// 0.35–0.7 on `AVSpeechUtterance`'s own scale; 0.5 is its default.
    var rate: Double = 0.5
    /// BCP-47, from the article's own `lang` where it has one.
    var language: String?

    var sentenceCount: Int { sentences.count }
    var hasContent: Bool { !sentences.isEmpty }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func load(_ sentences: [ReaderSentence]) {
        stop()
        self.sentences = sentences
    }

    /// Play, pause or resume — the one button people actually press.
    func toggle() {
        if isSpeaking && !isPaused {
            pause()
        } else if isPaused {
            resume()
        } else {
            start(at: currentIndex ?? 0)
        }
    }

    func start(at index: Int) {
        guard sentences.indices.contains(index) else { return }
        // A session claimed here rather than at launch, and only for as long as
        // the voice is talking — see `MediaSession` for the same rule applied
        // to the page's own media.
        activateAudioSession()
        speak(index)
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }

    func stop() {
        isRetargeting = true
        synthesizer.stopSpeaking(at: .immediate)
        isRetargeting = false
        isSpeaking = false
        isPaused = false
        currentIndex = nil
        onSentence?(nil)
        deactivateAudioSession()
    }

    func next() { jump(by: 1) }
    func previous() { jump(by: -1) }

    /// Start reading from a sentence the reader tapped.
    func jump(to index: Int) {
        guard sentences.indices.contains(index) else { return }
        speak(index)
    }

    private func jump(by delta: Int) {
        let base = currentIndex ?? 0
        let target = base + delta
        guard sentences.indices.contains(target) else {
            // Off the end is "finished", off the front is "back to the top".
            if target < 0 { speak(0) } else { stop() }
            return
        }
        speak(target)
    }

    private func speak(_ index: Int) {
        guard let sentence = sentences[safe: index] else { return }
        isRetargeting = true
        synthesizer.stopSpeaking(at: .immediate)
        isRetargeting = false

        let utterance = AVSpeechUtterance(string: sentence.text)
        utterance.rate = Float(min(max(rate, 0), 1))
        if let language, let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        // A beat between sentences, which is what makes a paragraph sound like
        // prose rather than like a list.
        utterance.postUtteranceDelay = 0.12

        currentIndex = index
        isSpeaking = true
        isPaused = false
        onSentence?(sentence)
        synthesizer.speak(utterance)
    }

    // MARK: Audio session
    //
    // `.playback` so the voice keeps going with the phone locked or the app in
    // the background, and `.spokenAudio` so iOS ducks other audio rather than
    // killing it. `MediaSession` owns the same session for page media; reading
    // aloud and a video playing at once is a contradiction, so the last one to
    // ask wins, which is what `setActive` already does.

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }
}

extension ReaderSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.isRetargeting, let current = self.currentIndex else { return }
            let next = current + 1
            if self.sentences.indices.contains(next) {
                self.speak(next)
            } else {
                self.stop()
            }
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
