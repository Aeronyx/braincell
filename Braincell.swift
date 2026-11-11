// Braincell: two little peekers in the menu bar who share one braincell.
// They show up only while you and a friend are both mid-turn in Claude Code,
// and act out what each of your Claudes is doing.
//
// Build:  swiftc -O -swift-version 5 Braincell.swift -o Braincell   (install.sh does this)
// Look:   Braincell --snapshot twins.png                            (renders the poses to a PNG)

import AppKit

// MARK: - Tunables

let staleAfter: TimeInterval = 600    // a session log with no heartbeat for this long is dropped
let idleGrace: TimeInterval = 20      // keep saying "busy" this long after my turn ends, to bridge back-to-back prompts
let reannounce: TimeInterval = 600    // repeat "busy" this often so my friend's copy can't go stale
let friendLease: TimeInterval = 1500  // forget a friend's "busy" that hasn't been repeated for this long
let linger: TimeInterval = 300        // whoever stops sleeps on the ledge this long before the twins leave
let detailEvery: TimeInterval = 60    // tell my friend what I'm doing at most this often...
let detailBudget = 120                // ...and at most this many times a day (ntfy.sh allows 250 messages in all)
let shareWords = true                 // false: my friend sees the kind of work I'm doing, but not the few words about it
let accent = NSColor(srgbRed: 0.91, green: 0.55, blue: 0.37, alpha: 1)   // light Claude orange

let home = ProcessInfo.processInfo.environment["BRAINCELL_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".braincell")
let busyDir = home.appendingPathComponent("busy")
let debug = ProcessInfo.processInfo.environment["BRAINCELL_DEBUG"] != nil

func log(_ s: @autoclosure () -> String) {
    if debug { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) }
}

/// A timer on the main run loop whose body runs on the main actor.
@MainActor @discardableResult
func after(_ seconds: TimeInterval, repeats: Bool = false, _ body: @escaping @MainActor () -> Void) -> Timer {
    let t = Timer(timeInterval: seconds, repeats: repeats) { _ in MainActor.assumeIsolated(body) }
    t.tolerance = repeats ? 0 : min(1, seconds * 0.1)
    RunLoop.main.add(t, forMode: .common)
    return t
}

// MARK: - What a Claude is up to

/// The kinds of work a twin can act out, worked out from the tool Claude Code is using.
enum Doing: String {
    case think, read, write, run, web, plan, team, wait

    init(tool: String) {
        let t = tool.lowercased()
        func any(_ names: String...) -> Bool { names.contains { t == $0 || t.hasSuffix("__" + $0) } }
        if any("read", "grep", "glob", "ls", "notebookread", "toolsearch") { self = .read }
        else if any("edit", "write", "multiedit", "notebookedit") { self = .write }
        else if any("bash", "bashoutput", "killshell", "monitor") || t.contains("terminal") { self = .run }
        else if any("websearch", "webfetch") || t.contains("browser") || t.contains("chrome") { self = .web }
        else if any("todowrite", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan", "enterplanmode", "exitplanmode") { self = .plan }
        else if any("agent", "task", "workflow", "sendmessage", "start_session") { self = .team }
        else if any("askuserquestion") { self = .wait }
        else { self = .think }
    }

    /// What to say when Claude hasn't described the work itself.
    var phrase: String {
        switch self {
        case .think: return "thinking"
        case .read: return "reading"
        case .write: return "writing"
        case .run: return "running commands"
        case .web: return "browsing the web"
        case .plan: return "planning"
        case .team: return "orchestrating agents"
        case .wait: return "waiting for an answer"
        }
    }

    /// How long this activity's gesture lasts, in seconds.
    var beat: Double {
        switch self {
        case .think: return 1.8
        case .read: return 2.2
        case .write: return 1.5
        case .run: return 1.3
        case .web: return 2.0
        case .plan: return 2.4
        case .team: return 2.0
        case .wait: return 1.6
        }
    }
}

/// One of us, as the other sees them.
struct Mind: Equatable {
    var busy = false
    var doing = Doing.think
    var label: String?       // a few words from Claude's own to-do list or command description

    var words: String {
        guard busy else { return "taking a break" }
        return (doing == .wait ? doing.phrase : label ?? doing.phrase) + "…"
    }
}

/// Shortens a to-do item or command description to about three words:
/// "Adding custom widgets to the settings page." becomes "adding custom widgets".
func brief(_ text: String) -> String? {
    let filler: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "for", "and", "with", "from", "into", "at", "by"]
    var words: [String] = [], weight = 0
    for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
        if weight == 3 || words.joined(separator: " ").count + word.count > 30 { break }
        words.append(word)
        if !filler.contains(word.lowercased()) { weight += 1 }
    }
    while let last = words.last, filler.contains(last.lowercased()) { words.removeLast() }
    var s = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,:;…!- "))
    if let first = s.first, s.dropFirst().first?.isLowercase == true { s = first.lowercased() + s.dropFirst() }
    return s.isEmpty ? nil : s
}

/// The first capture group of a regular expression, for events too long to arrive as whole JSON.
func capture(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

/// What one Claude Code session is doing, pieced together from the lines its hook logs.
struct Session {
    var born: Date?                 // when the log file was created; each turn starts a new file
    var offset: UInt64 = 0          // how much of it has been read
    var doing = Doing.think
    var task: String?               // the to-do item Claude says it's on
    var step: String?               // what Claude says the current command or subagent is for
    var plan: [String] = [], at = 0 // desktop app task list: its steps, and the current one
    var tasks: [String] = []        // CLI task list: created in order, then addressed by number

    mutating func apply(_ line: String) {
        switch line {
        case "prompt": doing = .think; task = nil; step = nil
        case "wait": doing = .wait
        case "done": if doing == .wait { doing = .think }
        default:
            guard line.hasPrefix("tool ") else { return }
            let json = String(line.dropFirst(5))
            let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let name = event?["tool_name"] as? String ?? capture(#""tool_name"\s*:\s*"([^"]+)""#, in: json) ?? ""
            let input = event?["tool_input"] as? [String: Any] ?? [:]
            let key = name.lowercased()
            doing = Doing(tool: name)

            if key == "todowrite" {
                let current = (input["todos"] as? [[String: Any]])?.first { $0["status"] as? String == "in_progress" }
                task = (current?["activeForm"] ?? current?["content"]) as? String
            } else if key.hasSuffix("update_plan") {
                if let items = input["items"] as? [[String: Any]] {
                    plan = items.map { $0["content"] as? String ?? "" }
                    at = items.firstIndex { $0["status"] as? String == "in_progress" } ?? plan.count
                } else if let start = input["start"] as? Int {
                    at = start - 1
                } else if input["advance"] as? Bool == true {
                    at += 1
                }
                task = plan.indices.contains(at) ? plan[at] : nil
            } else if key == "taskcreate" {
                tasks.append((input["activeForm"] ?? input["subject"]) as? String ?? "")
            } else if key == "taskupdate" {
                let number = Int("\(input["taskId"] ?? "")") ?? 0
                if input["status"] as? String == "in_progress", tasks.indices.contains(number - 1) { task = tasks[number - 1] }
            } else if doing == .run || doing == .team {
                step = input["description"] as? String ?? capture(#""description"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: json)
            } else {
                step = nil
            }
        }
    }

    var mind: Mind {
        let said = [task, step].compactMap { $0 }.first.flatMap(brief)
        return Mind(busy: true, doing: doing, label: said)
    }
}

// MARK: - The twins

/// Draws the two peekers and their braincell. Coordinates are points, with y = 0 on the ledge they
/// peek over: the menu bar's bottom edge, or an invisible line level with the bottoms of the other
/// icons. Anything below it is out of sight. Movement comes in short bursts; between them nothing is redrawn and
/// no timer runs.
final class Twins: NSView {
    static let size = NSSize(width: 34, height: 18)
    static let ledgeBelowCenter: CGFloat = 8     // when centered, how far under the menu bar's midline the ledge sits

    private struct Twin { let x, width, top, eyeGap, eyeY, paw: CGFloat }
    private let twin = [
        Twin(x: 8.95, width: 10.0, top: 8.7, eyeGap: 2.15, eyeY: 4.5, paw: 6.95),   // me
        Twin(x: 25.35, width: 9.4, top: 9.9, eyeGap: 2.0, eyeY: 5.4, paw: 6.65),    // my friend (inner paws touch)
    ]

    // Slow poses, tweened. paws, up0, up1, cellUp: 0 = hidden below the ledge, 1 = in place.
    // sink: 1 = dozing low. lid: 1 = eyes shut. perch: 1 = the braincell is set down on their joined paws.
    // center: 0 = the ledge is the menu bar's bottom edge, 1 = it's level with the other icons.
    private var pose: [String: CGFloat] = ["paws": 0, "up0": 0, "up1": 0, "cellUp": 0,
                                           "sink0": 0, "sink1": 0, "lid0": 0, "lid1": 0, "perch": 0, "center": 0]
    private enum Ease { case smooth, spring, windUp }    // spring overshoots at the end; windUp pulls back first
    private struct Tween { let start: CFTimeInterval, length: Double, from, to: CGFloat, ease: Ease, then: (() -> Void)? }
    private var tweens: [String: Tween] = [:]

    private var awake = [true, true]
    private var doing: [Doing] = [.think, .think]

    // The braincell. cellAt: 0 = over my twin, 1 = over my friend's, 0.5 = shared between them.
    private struct Hop { let from, to: CGFloat, start: CFTimeInterval, length: Double, height, wobble: CGFloat, hard: Bool }
    private var cellAt: CGFloat = 0
    private var hop: Hop?
    private var holder = 0                      // who gets it when nothing else decides: whoever switched tasks last
    private var lastHop: CFTimeInterval = 0
    private var nextPass: CFTimeInterval = 0

    // A gesture is one short burst of movement by one twin.
    private enum Move { case act(Doing), catchIt, bump }
    private struct Gesture { let move: Move, start: CFTimeInterval, length: Double; var cut: CFTimeInterval? }
    private var gesture: [Gesture?] = [nil, nil]
    private var queued: [(move: Move, length: Double)?] = [nil, nil]   // waits for the current gesture to finish
    private var settled: [CFTimeInterval] = [0, 0]                     // no gesture starts before this: a twin that just arrived or woke takes a moment

    private var frames: Timer?
    private var life: Timer?
    weak var button: NSView?    // the status item button: it knows whether the menu bar is light or dark

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks belong to the status item
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    // MARK: Poses

    /// Moves the ledge between the menu bar's bottom edge and the line the other icons sit on.
    func setCentered(_ on: Bool, animated: Bool) {
        if animated { move("center", to: on ? 1 : 0, over: 0.5) } else { pose["center"] = on ? 1 : 0; needsDisplay = true }
    }

    /// Up from nowhere: paws grab the ledge, the heads hop up one after the other, and the
    /// braincell pops out from behind whoever holds it. Then they bump paws.
    func arrive() {
        let center = tweens["center"]
        tweens.removeAll(); tweens["center"] = center
        hop = nil; gesture = [nil, nil]; queued = [nil, nil]
        settled = [CACurrentMediaTime() + 1.2, CACurrentMediaTime() + 1.2]
        awake = [true, true]
        for who in 0..<2 {
            if pose["up\(who)"]! == 0 { pose["sink\(who)"] = 0; pose["lid\(who)"] = 0 }             // out of sight: just reset
            else { move("lid\(who)", to: 0, over: 0.25); move("sink\(who)", to: 0, over: 0.5, .spring) }   // caught mid-exit: wake up smoothly
        }
        if pose["cellUp"]! == 0 {      // only choose a new spot for the braincell while nobody can see it
            holder = Bool.random() ? 0 : 1
            let spot = cellSpot()
            cellAt = spot.at; pose["perch"] = spot.perched ? 1 : 0
        }
        let first = Bool.random() ? 0 : 1
        move("paws", to: 1, over: 0.25, .spring, delay: 0.12)      // a beat for the menu bar to make room
        move("up\(first)", to: 1, over: 0.45, .spring, delay: 0.27)
        move("up\(1 - first)", to: 1, over: 0.45, .spring, delay: 0.42)
        move("cellUp", to: 1, over: 0.4, .spring, delay: 0.82) { [weak self] in
            self?.start(.bump, on: 0, for: 0.45); self?.start(.bump, on: 1, for: 0.45)
        }
        nextPass = CACurrentMediaTime() + .random(in: 8...20)
        scheduleLife()
    }

    /// Back to nowhere: the braincell drops out of sight, each head winds up and ducks, and the
    /// paws let go last. Only then is the status item itself taken away.
    func leave(then done: @escaping () -> Void) {
        life?.invalidate(); life = nil
        calm(0); calm(1)
        if let h = hop { cellAt = h.to; hop = nil }
        move("cellUp", to: 0, over: 0.35)
        move("up0", to: 0, over: 0.45, .windUp, delay: 0.25)
        move("up1", to: 0, over: 0.45, .windUp, delay: 0.37)
        move("paws", to: 0, over: 0.25, delay: 0.85, then: done)
    }

    func setAwake(_ who: Int, _ on: Bool) {
        guard awake[who] != on else { return }
        awake[who] = on
        if on {
            settled[who] = CACurrentMediaTime() + 0.9     // open its eyes and straighten up before doing anything
            move("lid\(who)", to: 0, over: 0.25)
            move("sink\(who)", to: 0, over: 0.5, .spring)
        } else {
            calm(who)
            move("lid\(who)", to: 1, over: 0.3)
            move("sink\(who)", to: 1, over: 0.7)
        }
        placeCell()     // the one still thinking gets the braincell
    }

    func setDoing(_ who: Int, _ what: Doing) {
        guard doing[who] != what else { return }
        doing[who] = what
        holder = who
        guard life != nil, awake[who] else { return }
        start(.act(what), on: who, for: what.beat)
        placeCell()
    }

    // MARK: A little life

    private func scheduleLife() {
        life?.invalidate()
        life = after(.random(in: 2.5...5.5)) { [weak self] in self?.liveALittle() }
    }

    private func liveALittle() {
        let up = [0, 1].filter { awake[$0] }
        let inStep = up.count == 2 && doing[0] == doing[1] && doing[0] != .think
        if inStep, gesture[0] == nil, gesture[1] == nil, Bool.random() {
            for who in up { start(.act(doing[who]), on: who, for: doing[who].beat) }   // same work: they move as one
        } else if !inStep {
            for who in up where gesture[who] == nil && Bool.random() { start(.act(doing[who]), on: who, for: doing[who].beat) }
        }
        if let who = up.randomElement(), gesture[who] == nil { blink(who) }
        if up.count == 2, CACurrentMediaTime() > nextPass {
            holder = 1 - holder
            nextPass = CACurrentMediaTime() + .random(in: 18...40)
        }
        placeCell()
        scheduleLife()
    }

    private func blink(_ who: Int) {
        move("lid\(who)", to: 1, over: 0.07) { [weak self] in
            guard let self, self.awake[who] else { return }
            self.move("lid\(who)", to: 0, over: 0.11)
        }
    }

    private func start(_ move: Move, on who: Int, for length: Double) {
        if gesture[who] != nil { queued[who] = (move, length); return }    // never cut a movement short: it waits its turn
        gesture[who] = Gesture(move: move, start: max(CACurrentMediaTime(), settled[who]), length: length, cut: nil)
        run()
    }

    /// Eases a twin out of whatever it's doing, rather than snapping it back to rest.
    private func calm(_ who: Int) {
        queued[who] = nil
        if gesture[who] != nil, gesture[who]!.cut == nil { gesture[who]!.cut = CACurrentMediaTime() }
    }

    // MARK: The braincell

    /// Where the braincell belongs, given what the two of them are doing.
    private func cellSpot() -> (at: CGFloat, perched: Bool) {
        if awake[0] != awake[1] { return (awake[0] ? 0 : 1, false) }        // whoever is still thinking keeps it
        if !awake[0] { return (cellAt, false) }                             // both dozing: leave it be
        let (a, b) = (doing[0], doing[1])
        if a == .wait && b == .wait { return (0.5, true) }                  // nobody's using it: it's set down on their paws
        if a == .wait || b == .wait { return (a == .wait ? 1 : 0, false) }  // the one who isn't stuck gets it
        if a == b && a != .think { return (0.5, false) }                    // same work: they share it
        return (CGFloat(holder), false)
    }

    /// Sends the braincell to where it belongs. How it travels depends on what they're up to.
    private func placeCell() {
        let now = CACurrentMediaTime(), spot = cellSpot()
        if (pose["perch"]! > 0.5) != spot.perched { move("perch", to: spot.perched ? 1 : 0, over: 0.7) }
        guard hop == nil, tweens["cellUp"] == nil, spot.at != cellAt, now - lastHop > 2.5 else { return }   // the life timer tries again
        let pair = [doing[0], doing[1]]
        var style = (length: 0.8, height: CGFloat(1.8), wobble: CGFloat(0), hard: false)                       // an easy lob
        if pair.contains(.run) || pair.contains(.write) { style = (0.38, 0.7, 0, true) }                      // busy hands: a quick flat toss
        else if pair.contains(.web) { style = (1.1, 1.4, 0.9, false) }                                        // surfing: it weaves across
        else if pair.contains(.plan) || pair.contains(.team) { style = (1.3, 3.0, 0, false) }                 // big ideas: a high, slow lob
        hop = Hop(from: cellAt, to: spot.at, start: now, length: style.length, height: style.height, wobble: style.wobble, hard: style.hard)
        run()
    }

    // MARK: Tweening (a 60 fps timer that exists only while something is moving)

    private func move(_ key: String, to: CGFloat, over length: Double, _ ease: Ease = .smooth, delay: Double = 0, then: (() -> Void)? = nil) {
        tweens[key] = Tween(start: CACurrentMediaTime() + delay, length: length, from: pose[key]!, to: to, ease: ease, then: then)
        run()
    }

    private func run() {
        if frames == nil { frames = after(1.0 / 60, repeats: true) { [weak self] in self?.step() } }
    }

    private func step() {
        let now = CACurrentMediaTime()
        for (key, t) in tweens {
            let p = max(0, min(1, (now - t.start) / t.length))
            let eased: Double
            switch t.ease {
            case .smooth: eased = p * p * (3 - 2 * p)
            case .spring: eased = 1 + 2.7 * pow(p - 1, 3) + 1.7 * pow(p - 1, 2)
            case .windUp: eased = 2.7 * p * p * p - 1.7 * p * p
            }
            pose[key] = t.from + (t.to - t.from) * CGFloat(eased)
            if p >= 1 { tweens[key] = nil; t.then?() }
        }
        if let h = hop, now - h.start >= h.length {
            cellAt = h.to; hop = nil; lastHop = now
            if h.hard, h.to != 0.5, awake[Int(h.to)], gesture[Int(h.to)] == nil { start(.catchIt, on: Int(h.to), for: 0.3) }   // caught it
        }
        for who in 0..<2 {
            guard let g = gesture[who], now - g.start >= g.length || g.cut.map({ now - $0 >= 0.25 }) == true else { continue }
            gesture[who] = nil
            if let next = queued[who] { queued[who] = nil; start(next.move, on: who, for: next.length) }
        }
        if tweens.isEmpty && hop == nil && gesture[0] == nil && gesture[1] == nil { frames?.invalidate(); frames = nil }
        needsDisplay = true
    }

    // MARK: Gestures

    private struct Limbs {
        var gazeX: CGFloat = 0, gazeY: CGFloat = 0, head: CGFloat = 0, tilt: CGFloat = 0
        var pawX: (CGFloat, CGFloat) = (0, 0), pawY: (CGFloat, CGFloat) = (0, 0)
    }

    /// How far a twin's eyes, head and paws are from rest at this instant of its gesture.
    private func limbs(_ who: Int, at now: CFTimeInterval) -> Limbs {
        var l = Limbs()
        guard let g = gesture[who] else { return l }
        let p = CGFloat(min(1, max(0, (now - g.start) / g.length)))
        let fade = CGFloat(g.cut.map { max(0, 1 - (now - $0) / 0.25) } ?? 1)   // easing out early, if it was asked to stop
        let ramp = min(1, p * 4, (1 - p) * 4)
        let ease = ramp * ramp * (3 - 2 * ramp) * fade                       // glide in and out of the gesture
        func wave(_ cycles: CGFloat) -> CGFloat { sin(p * cycles * 2 * .pi) }
        switch g.move {
        case .act(.think):      // gazes up, pondering
            l.gazeY = 0.45 * ease
        case .act(.read):       // eyes travel along three lines, gliding back to the start of each
            let line = (p * 3).truncatingRemainder(dividingBy: 1)
            let along = line < 0.8 ? line / 0.8 : 1 - (line - 0.8) / 0.2
            l.gazeX = (2 * along * along * (3 - 2 * along) - 1) * 0.85 * ease; l.gazeY = -0.35 * ease
        case .act(.write):      // paws type
            l.pawY = (max(0, wave(6)) * 1.1 * ease, max(0, -wave(6)) * 1.1 * ease); l.gazeY = -0.4 * ease
        case .act(.run):        // three little hops
            l.head = abs(wave(1.5)) * ease
        case .act(.web):        // looks all around
            l.gazeX = wave(2) * 0.9 * ease; l.gazeY = cos(p * 2 * .pi) * 0.4 * ease
        case .act(.plan):       // tilts its head one way, then the other
            l.tilt = wave(1) * 8 * ease; l.gazeY = 0.4 * ease
        case .act(.team):       // conducts with both paws
            l.pawY = (2.6 * ease, 2.6 * ease); l.pawX = (wave(2) * 0.9 * ease, -wave(2) * 0.9 * ease)
        case .act(.wait):       // leans out and waves at whoever it's waiting for
            l.tilt = (who == 0 ? 5 : -5) * ease; l.gazeY = -0.3 * ease
            if who == 0 { l.pawY.0 = 2.8 * ease; l.pawX.0 = wave(3) * 0.8 * ease } else { l.pawY.1 = 2.8 * ease; l.pawX.1 = wave(3) * 0.8 * ease }
        case .catchIt:          // dips as the braincell lands
            l.head = -0.8 * sin(.pi * p) * fade
        case .bump:             // the paws they hold bump once
            if who == 0 { l.pawY.1 = 1.6 * sin(.pi * p) * fade } else { l.pawY.0 = 1.6 * sin(.pi * p) * fade }
        }
        return l
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = (button ?? self).effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The ledge: the bottom of the status item's window (the menu bar's real bottom edge), or an
        // invisible line level with the other icons. Everything below it is clipped away.
        let shift = NSAffineTransform()
        shift.translateX(by: 0, yBy: (bounds.midY - Twins.ledgeBelowCenter) * pose["center"]!)
        shift.concat()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: 0, width: bounds.width, height: bounds.height)).addClip()
        paint(dark: dark, originX: (bounds.width - Twins.size.width) / 2, at: CACurrentMediaTime())
    }

    /// backdrop: what is behind the twins when that isn't the live menu bar (only the snapshot needs it).
    private func paint(dark: Bool, originX ox: CGFloat, at now: CFTimeInterval, backdrop: NSColor? = nil) {
        let ink = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
        let perch = pose["perch"]!, cellUp = pose["cellUp"]!
        let pawLift = (pose["paws"]! - 1) * 4
        // How far each head is from its resting height: hidden below the ledge, dozing low, or mid-gesture.
        func drop(_ i: Int, _ l: Limbs) -> CGFloat { (pose["up\(i)"]! - 1) * (twin[i].top + 2.5) - pose["sink\(i)"]! * 3.4 + l.head }
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSRect {
            NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        }

        // Where the braincell is on its way across.
        var cell = cellAt, arc: CGFloat = 0
        if let h = hop {
            let u = CGFloat(min(1, max(0, (now - h.start) / h.length)))
            cell = h.from + (h.to - h.from) * (u * u * (3 - 2 * u))
            arc = sin(.pi * u) * (h.height + sin(.pi * u * 4) * h.wobble)
        }
        let limb = [limbs(0, at: now), limbs(1, at: now)]

        // The one braincell: above a head, between the two, or set down on their joined paws.
        // While it's coming or going it passes behind the heads, as if popping out of one.
        func rest(_ i: Int) -> CGFloat { twin[i].top + drop(i, limb[i]) + 3.1 }
        let aloft = rest(0) + (rest(1) - rest(0)) * cell + arc
        let cellSpot = oval(ox + twin[0].x + (twin[1].x - twin[0].x) * cell, -3 + (aloft + (3.6 - aloft) * perch + 3) * cellUp, 1.9, 1.9)
        if cellUp < 1 { accent.setFill(); NSBezierPath(ovalIn: cellSpot).fill() }

        ink.setFill()
        for (i, t) in twin.enumerated() {
            let l = limb[i]
            let cx = ox + t.x, half = t.width / 2
            let down = drop(i, l)

            // Paws grip the ledge, which cuts them into flat-bottomed mitts, and stay put while the head ducks.
            let paws: [(CGFloat, CGFloat, CGFloat)] = [(-1, l.pawX.0, l.pawY.0), (1, l.pawX.1, l.pawY.1)]
            for (side, dx, dy) in paws { NSBezierPath(ovalIn: oval(cx + side * t.paw + dx, pawLift + 0.7 + dy, 1.6, 1.35)).fill() }

            // Mine is solid with the eyes punched out so the menu bar shows through. My friend's is
            // hollow: an outline with solid eyes. That's how you tell whose is whose.
            let hollow = i == 1
            let edge: CGFloat = hollow ? 0.55 : 0          // keeps the outline inside the same silhouette
            let wide = half - edge, top = t.top + down - edge, shoulder = top - wide * 0.95
            let head = NSBezierPath()
            head.move(to: NSPoint(x: cx - wide, y: -12))
            head.line(to: NSPoint(x: cx - wide, y: shoulder))
            head.curve(to: NSPoint(x: cx, y: top),
                       controlPoint1: NSPoint(x: cx - wide, y: shoulder + wide * 0.55),
                       controlPoint2: NSPoint(x: cx - wide * 0.56, y: top))
            head.curve(to: NSPoint(x: cx + wide, y: shoulder),
                       controlPoint1: NSPoint(x: cx + wide * 0.56, y: top),
                       controlPoint2: NSPoint(x: cx + wide, y: shoulder + wide * 0.55))
            head.line(to: NSPoint(x: cx + wide, y: -12))
            head.close()

            // Eyes drift toward the braincell once it's out (the holder glances up, the other looks
            // across), plus the gesture. The hollow twin's eyes stay clear of its outline.
            let holds = i == 0 ? 1 - cell : cell, watching = max(0, min(1, cellUp))
            let reach: CGFloat = hollow ? 0.55 : 1.2
            let gazeX = max(-reach, min(reach, (i == 0 ? 0.55 : -0.55) * (1 - holds) * watching + l.gazeX))
            let gazeY = (0.35 * holds * (1 - perch) - 0.45 * perch) * watching + l.gazeY
            let open = 1.2 * (1 - 0.75 * pose["lid\(i)"]!)
            let eyes = NSBezierPath()
            for side: CGFloat in [-1, 1] { eyes.appendOval(in: oval(cx + side * t.eyeGap + gazeX, t.eyeY + down + gazeY, 1.0, open)) }
            if l.tilt != 0 {
                var turn = AffineTransform(translationByX: cx, byY: 0)
                turn.rotate(byDegrees: l.tilt)
                turn.translate(x: -cx, y: 0)
                head.transform(using: turn); eyes.transform(using: turn)
            }
            if hollow {
                if cellUp < 1 {     // the braincell is passing behind: don't let it show through the hollow body
                    if let backdrop { backdrop.setFill(); head.fill(); ink.setFill() }
                    else {
                        NSGraphicsContext.current?.cgContext.setBlendMode(.clear); head.fill()
                        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
                    }
                }
                ink.setStroke()
                head.lineWidth = 1.1
                head.stroke()
                eyes.fill()
            } else {
                head.append(eyes)
                head.windingRule = .evenOdd
                head.fill()
            }
        }

        if cellUp >= 1 { accent.setFill(); NSBezierPath(ovalIn: cellSpot).fill() }
    }

    /// Renders a contact sheet of poses on light and dark menu bars, for tuning the look.
    static func snapshot(to path: String) {
        func mid(_ what: Doing, _ p: Double) -> Gesture { Gesture(move: .act(what), start: -p, length: 1, cut: nil) }
        let scenes: [(Twins) -> Void] = [
            { _ in },                                                                      // both thinking
            { $0.hop = Hop(from: 0, to: 1, start: -0.5, length: 1, height: 1.8, wobble: 0, hard: false) },   // passing it over
            { $0.cellAt = 1; $0.pose["lid0"] = 1; $0.pose["sink0"] = 1 },                  // I've stopped
            { $0.gesture = [mid(.read, 0.55), mid(.write, 0.29)] },                        // reading, typing
            { $0.gesture = [mid(.run, 0.5), mid(.web, 0.12)]; $0.cellAt = 1 },             // running, browsing
            { $0.gesture = [mid(.plan, 0.25), mid(.team, 0.5)] },                          // planning, orchestrating
            { $0.gesture = [mid(.wait, 0.5), nil]; $0.cellAt = 1 },                        // mine is waiting on me
            { $0.gesture = [mid(.write, 0.29), mid(.write, 0.29)]; $0.cellAt = 0.5 },      // same work: shared
            { $0.cellAt = 0.5; $0.pose["perch"] = 1 },                                     // both waiting: set down
            { $0.pose["up0"] = 0.8; $0.pose["up1"] = 0.25; $0.pose["cellUp"] = 0 },         // arriving: paws, then heads
            { $0.pose["up0"] = 0.1; $0.pose["up1"] = 0.6; $0.pose["cellUp"] = 0.45 },       // leaving: braincell first
        ]
        let scale: CGFloat = 6, pad: CGFloat = 4, bar: CGFloat = 24
        let cellW = Twins.size.width + pad * 2
        let w = Int(cellW * CGFloat(scenes.count) * scale), h = Int(bar * 2 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, dark) in [true, false].enumerated() {
            let backdrop = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.91, alpha: 1)
            backdrop.setFill()
            NSRect(x: 0, y: CGFloat(row) * bar * scale, width: CGFloat(w), height: bar * scale).fill()
            for (col, scene) in scenes.enumerated() {
                let view = Twins()
                for part in ["paws", "up0", "up1", "cellUp"] { view.pose[part] = 1 }
                scene(view)
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: CGFloat(col) * cellW * scale, yBy: CGFloat(row) * bar * scale)
                t.scale(by: scale)
                t.concat()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: cellW, height: bar)).addClip()
                view.paint(dark: dark, originX: pad, at: 0, backdrop: backdrop)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Menu bar item

/// Owns the status item. It appears when both of us are working, and once it's there whoever
/// stops just falls asleep; it leaves when someone has slept for `linger`.
/// Its menu says in a few words what each Claude is doing.
@MainActor final class MenuBarItem {
    private let item = NSStatusBar.system.statusItem(withLength: Twins.size.width + 4)
    private let twins = Twins()
    private let mine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let theirs = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var shown = false
    private var hideAt: Date?
    private var hideTimer: Timer?
    private var inkWatch: NSKeyValueObservation?

    init(extras: [NSMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        mine.isEnabled = false; theirs.isEnabled = false
        for entry in [mine, theirs, .separator()] + extras { menu.addItem(entry) }
        item.isVisible = false
        item.menu = menu
        twins.button = item.button
        inkWatch = item.button?.observe(\.effectiveAppearance) { [twins] _, _ in
            MainActor.assumeIsolated { twins.needsDisplay = true }
        }
        seat()
    }

    /// Puts the twins in the status item's window rather than its button: the window is as tall as
    /// the menu bar on every Mac, which leaves headroom for the braincell's higher throws.
    private func seat() {
        guard let button = item.button else { return }
        let host = button.window?.contentView ?? button
        guard twins.superview !== host else { return }
        twins.frame = host.bounds
        twins.autoresizingMask = [.width, .height]
        host.addSubview(twins)
    }

    func setCentered(_ on: Bool, animated: Bool) { twins.setCentered(on, animated: animated) }

    /// stopped: when each of us went quiet (nil while working).
    func update(me: Mind, friend: Mind, stopped: [Date?]) {
        mine.title = "You: " + me.words
        theirs.title = "Friend: " + friend.words
        item.button?.toolTip = mine.title + "\n" + theirs.title
        if me.busy { twins.setDoing(0, me.doing) }
        if friend.busy { twins.setDoing(1, friend.doing) }

        if me.busy && friend.busy {
            hideTimer?.invalidate(); hideTimer = nil; hideAt = nil
            if !shown {
                shown = true
                item.isVisible = true
                seat()
                twins.arrive()
                log("twins: arrive")
            }
            twins.setAwake(0, true); twins.setAwake(1, true)
        } else if shown {
            twins.setAwake(0, me.busy); twins.setAwake(1, friend.busy)
            // Whoever stopped sleeps where they are, and wakes if their Claude starts again.
            let due = (stopped.compactMap { $0 }.min() ?? Date()).addingTimeInterval(linger)
            if hideAt != due {
                hideAt = due
                hideTimer?.invalidate()
                hideTimer = after(max(0.1, due.timeIntervalSinceNow)) { [weak self] in self?.hide() }
            }
        }
    }

    private func hide() {
        shown = false; hideAt = nil; hideTimer = nil
        log("twins: leave")
        twins.leave { [weak self] in
            guard let self, !self.shown else { return }   // they came back mid-exit
            self.item.isVisible = false
        }
    }
}

// MARK: - Relay (one ntfy topic shared by the two of us)

struct Config: Decodable { let server: String, room: String, id: String }

@MainActor final class Relay {
    private let topic: URL
    private let me: String
    private let onFriend: (_ id: String, _ mind: Mind, _ sent: Date) -> Void
    private let session: URLSession
    private var stream: Task<Void, Never>?
    private var lastMessage: String?

    init(_ config: Config, onFriend: @escaping (String, Mind, Date) -> Void) {
        topic = URL(string: config.server)!.appendingPathComponent("braincell-" + config.room)
        me = config.id
        self.onFriend = onFriend
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true      // offline: wait quietly instead of retrying
        session = URLSession(configuration: c)
    }

    /// Everything that ever leaves this Mac: busy or not, the kind of work, and a few words about it.
    func send(_ mind: Mind) {
        var body: [String: Any] = ["id": me, "busy": mind.busy]
        if mind.busy { body["doing"] = mind.doing.rawValue }
        if mind.busy, shareWords, let label = mind.label { body["label"] = label }
        var r = URLRequest(url: topic)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 20
        let what = "busy=\(mind.busy) \(mind.doing.rawValue) \(mind.label ?? "-")"
        session.dataTask(with: r) { _, response, error in
            log("sent \(what): \((response as? HTTPURLResponse)?.statusCode ?? -1) \(error?.localizedDescription ?? "")")
        }.resume()
    }

    /// (Re)opens the one long-lived stream. Cached messages are replayed first, so we learn the current state.
    func listen() {
        stream?.cancel()
        stream = Task { [weak self] in
            var wait = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    var url = URLComponents(url: self.topic.appendingPathComponent("json"), resolvingAgainstBaseURL: false)!
                    url.queryItems = [URLQueryItem(name: "since", value: self.lastMessage ?? "\(Int(friendLease))s")]
                    var r = URLRequest(url: url.url!)
                    r.timeoutInterval = 150     // the server sends a keepalive every 45 s; silence means a dead link
                    let (lines, response) = try await self.session.bytes(for: r)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    log("listening")
                    for try await line in lines.lines {
                        wait = 2
                        self.receive(line)
                    }
                } catch {
                    log("stream ended: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                wait = min(wait * 2, 120)
            }
        }
    }

    private func receive(_ line: String) {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              outer["event"] as? String == "message",
              let body = outer["message"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let id = inner["id"] as? String, let busy = inner["busy"] as? Bool else { return }
        lastMessage = outer["id"] as? String ?? lastMessage
        guard id != me else { return }
        // A friend's words are shown as plain text, but keep them short and printable all the same.
        let label = (inner["label"] as? String).map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40))) }
        let mind = Mind(busy: busy, doing: Doing(rawValue: inner["doing"] as? String ?? "") ?? .think, label: label?.isEmpty == false ? label : nil)
        let sent = (outer["time"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        onFriend(id, mind, min(sent, Date()))
    }
}

// MARK: - App

@MainActor final class App: NSObject, NSApplicationDelegate {
    private var item: MenuBarItem!
    private var relay: Relay?
    private var watcher: DispatchSourceFileSystemObject?
    private var sessions: [String: Session] = [:]                   // my Claude Code sessions, by id
    private var friends: [String: (until: Date, since: Date, mind: Mind)] = [:]   // what each friend last said, when, and how long it holds
    private var latest = Mind()                                     // what I was last doing
    private var told = Mind()                                       // what my friend currently believes about me
    private var lastSent = Date.distantPast
    private var idleSince: Date?
    private var budget = 0, budgetFrom = Date.distantPast           // today's allowance of "what I'm doing" updates
    private var wake: Timer?
    private var settling = false
    private let placement = NSMenuItem(title: "Sit on the bottom edge", action: #selector(togglePlacement), keyEquivalent: "")
    private let centeredFlag = home.appendingPathComponent("centered")     // exists when the twins sit level with the other icons

    func applicationDidFinishLaunching(_ note: Notification) {
        let remove = NSMenuItem(title: "Remove Braincell…", action: #selector(remove), keyEquivalent: "")
        remove.target = self
        let centered = FileManager.default.fileExists(atPath: centeredFlag.path)
        placement.target = self
        placement.state = centered ? .off : .on
        item = MenuBarItem(extras: [placement, remove])
        item.setCentered(centered, animated: false)

        guard let data = try? Data(contentsOf: home.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(Config.self, from: data), URL(string: config.server) != nil else {
            log("no usable config.json in \(home.path); run install.sh")
            exit(0)
        }
        relay = Relay(config) { [weak self] id, mind, sent in
            self?.friends[id] = (mind.busy ? sent.addingTimeInterval(friendLease) : .distantPast, sent, mind)
            log("friend \(id): busy=\(mind.busy) \(mind.doing.rawValue) \(mind.label ?? "-")")
            self?.settle()
        }
        relay?.listen()

        // Hooks write to log files in busyDir; a kernel event tells us, so there's no polling.
        try? FileManager.default.createDirectory(at: busyDir, withIntermediateDirectories: true)
        let fd = open(busyDir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { [weak self] in self?.settle() } }
            source.resume()
            watcher = source
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        evaluate()
    }

    /// Coalesces bursts (a replayed backlog, several hooks at once) into one evaluation.
    private func settle() {
        guard !settling else { return }
        settling = true
        after(0.25) { [weak self] in self?.settling = false; self?.evaluate() }
    }

    /// The whole state machine: works out who is doing what, tells the friend, poses the twins,
    /// and sleeps until the next moment something could change on its own.
    private func evaluate() {
        let now = Date()
        var next: Date?
        func consider(_ d: Date) { if next == nil || d < next! { next = d } }

        // Me: the Claude Code session that did something most recently, if any is mid-turn.
        var me = Mind()
        if let newest = liveSessions(now).max(by: { $0.touched < $1.touched }) {
            me = sessions[newest.id]?.mind ?? Mind(busy: true)
            latest = me
            consider(newest.touched.addingTimeInterval(staleAfter))
        }

        // What I tell my friend: busy at once, idle only after the grace period, and what I'm doing now and then.
        if me.busy { idleSince = nil } else if idleSince == nil { idleSince = now }
        let say = me.busy || (told.busy && now.timeIntervalSince(idleSince!) < idleGrace)
        if !me.busy && say { consider(idleSince!.addingTimeInterval(idleGrace)) }
        let news = say ? latest : Mind()
        let flipped = news.busy != told.busy || lastSent == .distantPast
        let overdue = say && now.timeIntervalSince(lastSent) >= reannounce
        var detail = false
        if say && !flipped && !overdue && news != told {
            if now.timeIntervalSince(budgetFrom) >= 86400 { budgetFrom = now; budget = detailBudget }
            let ready = lastSent.addingTimeInterval(detailEvery)
            if budget > 0 { if now >= ready { detail = true; budget -= 1 } else { consider(ready) } }
        }
        if flipped || overdue || detail {
            told = news; lastSent = now
            relay?.send(news)
        }
        if say { consider(lastSent.addingTimeInterval(reannounce)) }

        // My friend: busy until their lease runs out.
        let live = friends.values.filter { $0.until > now }
        live.forEach { consider($0.until) }
        let friend = live.max { $0.until < $1.until }?.mind ?? Mind()
        // If they've gone quiet, since when: their last "idle", or the moment a lapsed "busy" ran out.
        let friendStopped = friends.values.map { $0.mind.busy ? $0.until : $0.since }.max() ?? .distantPast

        log("me: \(me.words) [\(me.doing.rawValue)]  friend: \(friend.words) [\(friend.doing.rawValue)]  say=\(say)")
        item.update(me: me, friend: friend, stopped: [me.busy ? nil : idleSince, friend.busy ? nil : friendStopped])

        wake?.invalidate()
        wake = next.map { after(max(1, $0.timeIntervalSince(now) + 0.2)) { [weak self] in self?.evaluate() } }
    }

    /// Reads what's new in each live session's log. Stale logs are deleted, so a later heartbeat
    /// recreates the file and the folder watcher fires.
    private func liveSessions(_ now: Date) -> [(id: String, touched: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: busyDir, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        let live: [(id: String, touched: Date)] = files.compactMap { file in
            guard let facts = try? file.resourceValues(forKeys: keys), let touched = facts.contentModificationDate else { return nil }
            guard now.timeIntervalSince(touched) < staleAfter else { try? FileManager.default.removeItem(at: file); return nil }
            let id = file.lastPathComponent
            var session = sessions[id] ?? Session()
            if session.born != facts.creationDate || UInt64(facts.fileSize ?? 0) < session.offset {   // a new turn's log
                session.born = facts.creationDate; session.offset = 0
            }
            if let handle = try? FileHandle(forReadingFrom: file) {
                try? handle.seek(toOffset: session.offset)
                let fresh = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                if let end = fresh.lastIndex(of: 0x0A) {                                              // whole lines only
                    session.offset += UInt64(end + 1)
                    for line in String(decoding: fresh[...end], as: UTF8.self).split(separator: "\n") { session.apply(String(line)) }
                }
            }
            sessions[id] = session
            return (id, touched)
        }
        if sessions.count > 60 { sessions = sessions.filter { id, _ in live.contains { $0.id == id } } }
        return live
    }

    @objc private func willSleep() {
        if told.busy { told = Mind(); lastSent = Date(); relay?.send(told) }
    }

    @objc private func didWake() {
        relay?.listen()
        settle()
    }

    /// Unticked, the twins float level with the other menu bar icons instead of sitting on the bar's bottom edge.
    @objc private func togglePlacement() {
        let centered = placement.state == .on
        placement.state = centered ? .off : .on
        if centered { FileManager.default.createFile(atPath: centeredFlag.path, contents: nil) }
        else { try? FileManager.default.removeItem(at: centeredFlag) }
        item.setCentered(centered, animated: true)
    }

    @objc private func remove() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove Braincell?"
        alert.informativeText = "This removes the app, its login item, and its Claude Code hooks from this Mac."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relay?.send(Mind())
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = [home.appendingPathComponent("uninstall.sh").path]
        try? script.run()      // its last step stops this app
    }
}

// MARK: - Main

MainActor.assumeIsolated {
    if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
        Twins.snapshot(to: CommandLine.arguments[flag + 1])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)     // no Dock icon, no windows
    app.run()
}
