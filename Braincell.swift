// Braincell: two little peekers in the menu bar who share one braincell. They show up while you
// and a friend are both mid-turn in Claude Code, and act out what each Claude is doing. Yours can
// also stay out on its own.
//
// Build: swiftc -O -swift-version 5 Braincell.swift -o Braincell   (install.sh does this)
// Try:   Braincell --demo

import AppKit
import CryptoKit

let staleAfter: TimeInterval = 900    // a session silent for this long has stopped (Esc fires no hook)
let idleGrace: TimeInterval = 20      // stay "busy" this long after a turn ends, to bridge back-to-back prompts
let reannounce: TimeInterval = 600    // repeat "busy" this often...
let friendLease: TimeInterval = 1500  // ...and forget a friend's "busy" once it's this old
let napFor: TimeInterval = 300        // whoever stops sleeps this long before leaving
let squabbleOdds = 100_000            // the twins' squabble: one chance in this many each quiet moment together, so every few months
let longDay: TimeInterval = 4 * 3600  // after this much work in a day, a twin is worn out
let detailEvery: TimeInterval = 60    // say what I'm doing at most this often...
let detailBudget = 120                // ...and this many times a day (ntfy.sh allows 250 messages a day)
let accent = NSColor(srgbRed: 0.91, green: 0.55, blue: 0.37, alpha: 1)

let home = ProcessInfo.processInfo.environment["BRAINCELL_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".braincell")
let busyDir = home.appendingPathComponent("busy")
let debug = ProcessInfo.processInfo.environment["BRAINCELL_DEBUG"] != nil

func log(_ s: @autoclosure () -> String) {
    if debug { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) }
}

@MainActor @discardableResult
func after(_ seconds: TimeInterval, repeats: Bool = false, _ body: @escaping @MainActor () -> Void) -> Timer {
    let t = Timer(timeInterval: seconds, repeats: repeats) { _ in MainActor.assumeIsolated(body) }
    t.tolerance = repeats ? 0 : min(1, seconds * 0.1)
    RunLoop.main.add(t, forMode: .common)
    return t
}

// MARK: - What a Claude is up to

enum Doing: String {
    case think, read, write, run, web, plan, team, wait, tidy

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
        case .tidy: return "tidying its memory"
        }
    }

    var beat: Double {      // how long its gesture lasts
        switch self {
        case .think: return 1.8
        case .read: return 2.4
        case .write: return 1.8
        case .run: return 1.8
        case .web: return 2.4
        case .plan: return 2.6
        case .team: return 2.4
        case .wait: return 2.2
        case .tidy: return 1.6
        }
    }
}

/// weary: after a long day's work. fresh: on a Claude model it hasn't used before. spent: out of usage.
enum Mood: String { case fine, weary, fresh, spent }

struct Mind: Equatable {
    var busy = false
    var doing = Doing.think
    var label: String?      // a few words from Claude's own to-do list or command description
    var ticked = 0          // to-do items finished this turn
    var mood = Mood.fine

    var words: String {
        guard busy else { return mood == .spent ? "out of usage" : "taking a break" }
        return (doing == .wait ? doing.phrase : label ?? doing.phrase) + "…"
    }
}

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

/// For events too long to arrive as whole JSON.
func capture(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

/// One Claude Code session, pieced together from the lines its hook logs.
struct Session {
    var born: Date?                 // each turn starts a new log file
    var offset: UInt64 = 0          // how much of it has been read
    var doing = Doing.think
    var task: String?               // the to-do item Claude says it's on
    var purpose: String?            // what Claude says the current command or subagent is for
    var ticked = 0
    var plan: [String] = [], at = 0 // desktop app task list: its steps, and the current one
    var tasks: [String] = []        // CLI task list: created in order, then addressed by number

    mutating func apply(_ line: String) {
        switch line {
        case "prompt": doing = .think; task = nil; purpose = nil; ticked = 0
        case "wait": doing = .wait
        case "done": if doing == .wait { doing = .think }
        case "tidy": doing = .tidy
        default:
            guard line.hasPrefix("tool ") else { return }
            let json = String(line.dropFirst(5))
            let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let name = event?["tool_name"] as? String ?? capture(#""tool_name"\s*:\s*"([^"]+)""#, in: json) ?? ""
            let input = event?["tool_input"] as? [String: Any] ?? [:]
            let key = name.lowercased(), before = task
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
                let number = (Int("\(input["taskId"] ?? "")") ?? 0) - 1
                if tasks.indices.contains(number) {
                    let status = input["status"] as? String
                    if status == "in_progress" { task = tasks[number] } else if status == "completed", task == tasks[number] { task = nil }
                }
            } else if doing == .run || doing == .team {
                purpose = input["description"] as? String ?? capture(#""description"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: json)
            } else {
                purpose = nil
            }
            if let before, task != before { ticked += 1 }
        }
    }

    var mind: Mind { Mind(busy: true, doing: doing, label: (task ?? purpose).flatMap(brief), ticked: ticked) }
}

// MARK: - The twins

/// A value that glides from one keyframe to the next: (time, value) pairs, in order.
func key(_ t: Double, _ frames: [(Double, CGFloat)]) -> CGFloat {
    var last = frames[0]
    for next in frames {
        if t < next.0 {
            let u = CGFloat(max(0, (t - last.0) / max(next.0 - last.0, 0.001)))
            return last.1 + (next.1 - last.1) * u * u * (3 - 2 * u)
        }
        last = next
    }
    return last.1
}

/// Draws the two peekers and their braincell. Coordinates are points, with y = 0 on the ledge they
/// peek over; anything below it is out of sight. They keep still most of the time: movement comes
/// in short, smooth bursts, and between them nothing is redrawn and no timer runs.
final class Twins: NSView {
    static let size = NSSize(width: 34, height: 18)
    static let soloWidth: CGFloat = 17.2            // the part of that my twin needs when it's out on its own
    static let ledgeBelowCenter: CGFloat = 8        // centered: how far under the menu bar's midline the ledge sits
    private static let doze: CGFloat = 3.4          // how far a sleeping head sinks
    var showOff = false                             // the demo: rare moments come up often, and long waits are short
    var onWidth: ((CGFloat) -> Void)?               // makes room in the menu bar before a second twin shows, and gives it back after
    var onSquabble: (() -> Void)?                   // they've fallen out, by chance: my friend's Mac should see it too
    var onFree: (() -> Void)?                       // a squabble is over: they can be told what they missed

    private struct Twin { let x, width, top, eyeGap, eyeY, paw: CGFloat }
    private let twin = [
        Twin(x: 8.95, width: 10.0, top: 8.7, eyeGap: 2.15, eyeY: 4.5, paw: 6.95),   // me: solid
        Twin(x: 25.35, width: 9.4, top: 9.9, eyeGap: 2.0, eyeY: 5.4, paw: 6.65),    // my friend: outlined
    ]

    // Tweened poses. paws, up, cellUp: 0 = below the ledge, 1 = in place. sink: 1 = dozing low.
    // lid: 1 = eyes shut. ko: 1 = eyes crossed out. perch: 1 = the braincell rests on their paws.
    // center: 1 = level with the other icons. alone: 1 = my twin has the ledge to itself.
    private var pose: [String: CGFloat] = ["paws0": 0, "paws1": 0, "up0": 0, "up1": 0, "cellUp": 0, "sink0": 0, "sink1": 0,
                                           "lid0": 0, "lid1": 0, "ko0": 0, "ko1": 0, "perch": 0, "center": 0, "alone": 1]
    private enum Ease { case smooth, spring, windUp }    // spring overshoots at the end; windUp pulls back first
    private struct Tween { let start: CFTimeInterval, length: Double, from, to: CGFloat, ease: Ease, then: (() -> Void)? }
    private var tweens: [String: Tween] = [:]

    private var here = [false, false]               // who is out on the ledge. My friend's is never out without mine
    private var awake = [false, false]              // only a twin that is out can be
    private var doing: [Doing] = [.think, .think]
    private var mood: [Mood] = [.fine, .fine]
    private var since: [CFTimeInterval] = [0, 0]    // when each started what it's doing now
    private var woke: [CFTimeInterval] = [0, 0]     // when each last woke up
    private var slept = [Date.distantPast, .distantPast]    // when each last dropped off
    private var acted: [CFTimeInterval] = [0, 0]    // when each last acted out its work: it keeps still for a while after
    private var lastMet: Date?                      // when the two were last awake together

    // The braincell. cellAt: 0 = over my twin, 1 = over my friend's, 0.5 = shared.
    private struct Hop { var from, to: CGFloat, start: CFTimeInterval, length: Double, height: CGFloat, wobble: CGFloat = 0, caught = false, header = false }
    private var cellAt: CGFloat = 0
    private var hop: Hop?
    private var holder = 0      // who has it when nothing else decides: whoever switched tasks last
    private var lastHop: CFTimeInterval = 0
    private var nextPass: CFTimeInterval = 0
    private var nextTrick: CFTimeInterval = 0, trick = 0    // on its own, my twin finds things to do: when, and which is next
    private var twinkle: CFTimeInterval = -60, nextTwinkle: CFTimeInterval = 0

    // A gesture is one short burst of movement by one twin.
    private enum Move: Equatable {
        case act(Doing), catchIt, bump, greet, glad, toss, grab, five, yawn, stretch
        case hug, peek, bye                         // meeting and parting
        case juggle, header, admire, seek           // what my twin gets up to on its own
        case squabble
    }
    private struct Gesture { let move: Move, start: CFTimeInterval, length: Double; var cut: CFTimeInterval? }
    private var gesture: [Gesture?] = [nil, nil]
    private var queued: [(move: Move, length: Double)?] = [nil, nil]
    private var settled: [CFTimeInterval] = [0, 0]      // a twin that just arrived or woke takes a moment before its next gesture
    private var owed: Move?                             // something they do as one, once both have a moment

    // Little things that drift away from a twin: a sleeper's z, a bead of sweat.
    private struct Wisp { let who: Int, sweat: Bool, x, y, side, size: CGFloat, start: CFTimeInterval }
    private var wisps: [Wisp] = []
    private var nextWisp: [CFTimeInterval] = [0, 0]

    private var frames: Timer?, drift = 0
    private var life: Timer?
    weak var button: NSView?    // the status item's button knows whether the menu bar is light or dark
    var edge: CGFloat? { didSet { if edge != oldValue { needsDisplay = true } } }      // where the menu bar slot ends, on the right

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks belong to the status item
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private var now: CFTimeInterval { CACurrentMediaTime() }
    private var rest: Double { showOff ? 3 : 30 }       // how long a twin keeps still after acting out its work
    private func long(_ seconds: Double) -> Double { showOff ? seconds / 40 : seconds }
    private func rarely(_ oneIn: Int) -> Bool { Int.random(in: 0..<(showOff ? 2 : oneIn)) == 0 }
    private func free(_ who: Int) -> Bool { awake[who] && gesture[who] == nil && now >= settled[who] }
    private func remember() { if awake[0], awake[1] { lastMet = Date() } }
    private var missed: Bool { lastMet.map { Date().timeIntervalSince($0) > (showOff ? 6 : 3600) } ?? true }   // it's been a while

    /// Where each twin stands. On its own, mine sits further over: in the middle of the narrower slot the menu bar gives it.
    private func place(_ who: Int) -> CGFloat {
        who == 1 ? twin[1].x : twin[0].x + (Twins.size.width - Twins.soloWidth / 2 - twin[0].x) * pose["alone"]!
    }

    // MARK: Coming and going

    func setCentered(_ on: Bool, animated: Bool) {
        if animated { move("center", to: on ? 1 : 0, over: 0.5) } else { pose["center"] = on ? 1 : 0; needsDisplay = true }
    }

    /// Brings my twin out, with my friend's beside it or not. Called again whenever that changes:
    /// mine shuffles over to make room, and back to the middle once it's alone again.
    func show(friend: Bool) {
        guard here != [true, friend] else { return }
        remember()
        let fresh = !here[0], joins = friend && !here[1], parts = !friend && here[1]
        here = [true, friend]
        if fresh {      // up from nowhere: paws, then head, then the braincell
            let center = tweens["center"]
            tweens.removeAll(); tweens["center"] = center
            hop = nil; gesture = [nil, nil]; queued = [nil, nil]; wisps = []; owed = nil
            if pose["up0"]! == 0, pose["paws0"]! == 0 { pose["alone"] = friend ? 0 : 1 }    // nobody can see it move over
            awake[0] = true; woke[0] = now; since[0] = now; acted[0] = 0
        }
        let lone: CGFloat = friend ? 0 : 1
        onWidth?(friend || pose["alone"]! < 1 ? Twins.size.width : Twins.soloWidth)

        let first = fresh && friend && Bool.random() ? 1 : 0       // when both come at once, either may pop up first
        if fresh { raise(0, after: first == 0 ? 0.12 : 0.27) }
        if joins {
            if !fresh { calm(0) }
            awake[1] = true; woke[1] = now; since[1] = now; acted[1] = 0
            raise(1, after: !fresh ? 0.6 : first == 1 ? 0.12 : 0.27) { [weak self] in if !fresh { self?.welcome() } }
        } else if pose["up1"]! > 0 || pose["paws1"]! > 0 {          // my friend's ducks out; mine watches it go
            if parts { awake[1] = false; calm(1); owed = nil; trick = 3 }                   // (the first thing it'll do alone is look for it)
            if parts, awake[0] { interrupt(0, with: .bye, for: 1.1) }
            lower(1, after: 0)
        }
        if friend { settled = [max(settled[0], settled[1]), max(settled[0], settled[1])] }      // so they can greet each other as one
        if pose["alone"]! != lone {
            move("alone", to: lone, over: awake[0] ? 0.8 : 1.1, delay: friend ? 0.1 : 0.9) { [weak self] in
                if lone == 1 { self?.onWidth?(Twins.soloWidth) }
                self?.placeCell()
            }
        }
        if fresh {
            if pose["cellUp"]! == 0 {      // only pick a new spot for the braincell while nobody can see it
                holder = friend && Bool.random() ? 1 : 0
                let spot = cellSpot()
                cellAt = spot.at; pose["perch"] = spot.perched ? 1 : 0
            }
            move("cellUp", to: 1, over: 0.4, .spring, delay: 0.82) { [weak self] in self?.welcome() }
            nextPass = now + .random(in: 30...60); nextTrick = now + long(.random(in: 40...120)); trick = 0
        }
        scheduleLife()
    }

    /// Back to nowhere: the braincell drops away, the heads duck, and the paws let go last.
    func leave(then done: @escaping () -> Void) {
        remember()
        life?.invalidate(); life = nil
        calm(0); calm(1)
        let pair = here[1]
        here = [false, false]; awake = [false, false]
        move("cellUp", to: 0, over: 0.35)
        lower(0, after: 0.25, then: pair ? nil : done)
        if pair { lower(1, after: 0.37, then: done) }
    }

    private func raise(_ who: Int, after delay: Double, then: (() -> Void)? = nil) {
        if pose["up\(who)"]! == 0 { pose["sink\(who)"] = 0; pose["ko\(who)"] = 0; pose["lid\(who)"] = droop(who) }
        else { wakeUp(who) }   // caught on its way out
        settled[who] = now + delay + 1.05
        move("paws\(who)", to: 1, over: 0.25, .spring, delay: delay)      // a beat for the menu bar to make room
        move("up\(who)", to: 1, over: 0.45, .spring, delay: delay + 0.15, then: then)
    }

    private func lower(_ who: Int, after delay: Double, then done: (() -> Void)? = nil) {
        move("up\(who)", to: 0, over: 0.45, .windUp, delay: delay)
        move("paws\(who)", to: 0, over: 0.25, delay: delay + 0.6, then: done)
    }

    /// Once both are up: a paw bump, or a hug if it's been a while. A sleeper just gets looked at.
    private func welcome() {
        guard here[1] else { return }
        if awake[0], awake[1] {
            let hello: Move = missed ? .hug : .bump
            for who in 0..<2 { start(hello, on: who, for: hello == .hug ? 2.4 : 0.6) }
        } else if awake[1] {
            start(.peek, on: 1, for: 1.4)
        }
    }

    func setAwake(_ who: Int, _ on: Bool) {
        guard here[who], awake[who] != on else { return }
        remember()
        awake[who] = on
        let other = 1 - who
        if on {
            settled[who] = now + 0.9; woke[who] = now
            wakeUp(who)
            if Date().timeIntervalSince(slept[who]) > long(120) { start(.yawn, on: who, for: 1.9) }    // a long nap ends with a yawn
            if awake[other] {
                interrupt(other, with: .greet, for: 1.1)
                if missed { owed = .hug }                                                              // and a long time apart, with a hug
            }
            scheduleLife()
            placeCell()
        } else {
            let lag = gesture[who] == nil ? 0 : 0.27    // a gesture under way eases out first
            slept[who] = Date()
            calm(who)
            var wait = max(0, settled[who] - now + 0.6), toss: Double?     // what it does before dropping off, and how long that takes
            if now >= settled[who], mood[who] != .spent {
                if now - woke[who] > long(600) {                                            // a long stint ends with a stretch
                    start(.stretch, on: who, for: 1.7); wait = lag + 1.7
                } else if cellAt == CGFloat(who), hop == nil, awake[other] {                // or it flicks the braincell over first
                    start(.toss, on: who, for: 0.55); wait = lag + 0.5; toss = lag + 0.2
                }
            }
            dropOff(who, after: wait)
            placeCell(tossedAfter: toss)
        }
    }

    private func wakeUp(_ who: Int) {
        if pose["ko\(who)"]! > 0 { move("ko\(who)", to: 0, over: 0.25) }
        move("lid\(who)", to: droop(who), over: 0.25)
        move("sink\(who)", to: 0, over: 0.5, .spring)
    }

    /// Its Claude has stopped: it nods off. Out of usage, it slumps with its eyes crossed out instead.
    private func dropOff(_ who: Int, after wait: Double) {
        let lid = "lid\(who)", sink = "sink\(who)", spent = mood[who] == .spent
        move("ko\(who)", to: spent ? 1 : 0, over: 0.3, delay: wait)
        if spent || pose[sink]! > 0.6 {
            move(lid, to: 1, over: 0.3, delay: wait)
            move(sink, to: spent ? 0.75 : 1, over: 0.7, delay: wait) { [weak self] in self?.puff(who) }
            return
        }
        move(lid, to: 0.8, over: 0.45, delay: wait)                     // nods off...
        move(sink, to: 0.5, over: 0.5, delay: wait) { [weak self] in
            self?.move(lid, to: 0.35, over: 0.15)                       // ...catches itself...
            self?.move(sink, to: 0.1, over: 0.25, .spring) { [weak self] in
                self?.move(lid, to: 1, over: 0.45)                      // ...and is gone
                self?.move(sink, to: 1, over: 0.8) { [weak self] in self?.puff(who) }
            }
        }
    }

    func setDoing(_ who: Int, _ what: Doing) {
        guard doing[who] != what else { return }
        doing[who] = what; since[who] = now
        holder = who
        guard awake[who] else { return }
        relax(who)
        if what == .wait || what == .tidy { interrupt(who, with: .act(what), for: what.beat) }      // worth showing right away
        else if gesture[who] == nil, now - acted[who] > rest { start(.act(what), on: who, for: what.beat) }
        placeCell()
    }

    func setMood(_ who: Int, _ feels: Mood) {
        guard mood[who] != feels else { return }
        let wasSpent = mood[who] == .spent
        mood[who] = feels
        guard here[who] else { return }
        if awake[who] { relax(who) } else if wasSpent != (feels == .spent) { dropOff(who, after: 0) }
        if feels == .fresh { holder = who; nextTwinkle = 0; placeCell(); sparkle() }    // it gets to show off the braincell
    }

    /// A to-do item is done.
    func tick(_ who: Int) {
        if awake[who] { interrupt(who, with: .glad, for: 1.4) }
    }

    /// Another hour of working together.
    func highFive() {
        if here[1] { owed = .five; settleUp() }
    }

    /// What they do as one waits until neither is in the middle of something.
    private func settleUp() {
        guard let move = owed, free(0), free(1) else { return }
        owed = nil
        for who in 0..<2 { start(move, on: who, for: move == .hug ? 2.4 : 1.3) }
    }

    // MARK: A little life

    private func scheduleLife() {
        life?.invalidate()
        let deep = !awake[0] && !awake[1] && Date().timeIntervalSince(max(slept[0], slept[1])) > 120    // everyone out here is sound asleep
        life = after(showOff ? .random(in: 2.5...4.5) : deep ? .random(in: 60...150) : .random(in: 6...10)) { [weak self] in self?.liveALittle() }
    }

    private func liveALittle() {
        defer { scheduleLife() }
        guard scene == nil else { return }
        let up = [0, 1].filter { awake[$0] }
        let rested = up.filter { free($0) && now - acted[$0] > rest }
        if owed != nil, free(0), free(1) {
            settleUp()
        } else if !showOff, rarely(squabbleOdds), squabble() {
            onSquabble?()                                                                   // every few months, they fall out
            return
        } else if rested.count == 2, doing[0] == doing[1], doing[0] != .think, rarely(3) {
            for who in up { start(.act(doing[who]), on: who, for: doing[who].beat) }        // same work: they move as one
        } else if !here[1], rested == [0], now > nextTrick, cellAt == 0, hop == nil, doing[0] != .wait {
            let next: Move = [.juggle, .header, .admire, .seek][trick % 4]                  // on its own, it plays with the braincell
            start(next, on: 0, for: next == .juggle ? 3.2 : next == .seek ? 3.6 : 2.8)
            if next == .admire { twinkle = max(now, settled[0]) + 1.1 }
            nextTrick = now + long(.random(in: 100...260)); trick += 1
        } else if let who = rested.randomElement(), Bool.random() {
            let sleepy = mood[who] == .weary ? rarely(3) : Calendar.current.component(.hour, from: Date()) < 5 && rarely(6)
            if sleepy { start(.yawn, on: who, for: 1.9) } else { start(.act(doing[who]), on: who, for: doing[who].beat) }
        }
        if let who = up.randomElement(), gesture[who] == nil, tweens["lid\(who)"] == nil { blink(who) }
        for who in up { relax(who) }
        for who in 0..<2 where here[who] && !awake[who] && tweens["sink\(who)"] == nil && now > nextWisp[who] { puff(who) }
        sparkle()
        if up.count == 2, now > nextPass {
            holder = 1 - holder
            nextPass = now + .random(in: 40...90)
        }
        placeCell()
    }

    /// On a Claude model it hasn't used before, a twin's braincell sparkles when it comes to rest, and now and then after.
    private func sparkle() {
        guard hop == nil, scene == nil, now > nextTwinkle,
              let who = [0, 1].first(where: { awake[$0] && mood[$0] == .fresh && cellAt == CGFloat($0) }) else { return }
        twinkle = now; nextTwinkle = now + long(.random(in: 60...120))
        if free(who) { start(.glad, on: who, for: 1.4) }
        run()
    }

    /// How far shut a twin's eyes rest: tired after a long day, or bored of waiting.
    private func droop(_ who: Int) -> CGFloat {
        if mood[who] == .weary { return 0.4 }
        return doing[who] == .wait && now - since[who] > long(60) ? 0.45 : 0
    }

    private func relax(_ who: Int) {
        let lid = "lid\(who)"
        if awake[who], tweens[lid] == nil, pose[lid]! != droop(who) { move(lid, to: droop(who), over: 0.6) }
    }

    /// A z drifts up from a sleeper (a big one after a long day). A twin that's out of usage sweats instead.
    private func puff(_ who: Int) {
        guard here[who] else { return }
        if mood[who] == .spent {
            sweat(who)
        } else {
            let side: CGFloat = who == 0 ? -1 : 1, size: CGFloat = mood[who] == .weary ? 1.5 : 1
            wisps.append(Wisp(who: who, sweat: false, x: place(who) + side * (2.6 + 1.6 * size), y: twin[who].top - Twins.doze + 1.8, side: side, size: size, start: now))
        }
        let sound = !showOff && Date().timeIntervalSince(slept[who]) > 120       // sound asleep, it barely stirs
        nextWisp[who] = now + (sound ? .random(in: 60...150) : .random(in: 5...9))
        run()
    }

    private func sweat(_ who: Int) {
        let side: CGFloat = who == 0 ? -1 : 1, t = twin[who]
        wisps.append(Wisp(who: who, sweat: true, x: place(who) + side * (t.width / 2 + 1.5), y: t.top - pose["sink\(who)"]! * Twins.doze - 0.3, side: side, size: 1, start: now))
        run()
    }

    private func blink(_ who: Int) {
        move("lid\(who)", to: 1, over: 0.07) { [weak self] in
            guard let self, self.awake[who] else { return }
            self.move("lid\(who)", to: self.droop(who), over: 0.11)
        }
    }

    private func start(_ move: Move, on who: Int, for length: Double) {
        if gesture[who] != nil { queued[who] = (move, length); return }    // never cut a movement short: it waits its turn
        gesture[who] = Gesture(move: move, start: max(now, settled[who]), length: length, cut: nil)
        run()
    }

    /// Eases a twin out of whatever it's doing, rather than snapping it back to rest.
    private func calm(_ who: Int) {
        queued[who] = nil
        if gesture[who] != nil, gesture[who]!.cut == nil { gesture[who]!.cut = now }
    }

    private func interrupt(_ who: Int, with move: Move, for length: Double) {
        calm(who)
        start(move, on: who, for: length)
    }

    // MARK: The braincell

    private func cellSpot() -> (at: CGFloat, perched: Bool, urgent: Bool) {
        if !here[1] { return (0, false, true) }                                     // on its own, my twin keeps it
        if awake[0] != awake[1] { return (awake[0] ? 0 : 1, false, true) }          // whoever is still thinking keeps it
        if !awake[0] { return (cellAt, false, false) }                              // both dozing: leave it be
        let (a, b) = (doing[0], doing[1])
        if a == .wait && b == .wait { return (0.5, true, true) }                    // nobody's using it: it's set down on their paws
        if a == .wait || b == .wait { return (a == .wait ? 1 : 0, false, true) }    // the one who isn't stuck gets it
        if a == b && a != .think { return (0.5, false, false) }                     // same work: they share it
        return (CGFloat(holder), false, false)
    }

    /// Sends the braincell where it belongs, once it has sat still for a while. How it travels
    /// depends on what they're up to.
    private func placeCell(tossedAfter toss: Double? = nil) {
        guard scene == nil, tweens["alone"] == nil else { return }
        let spot = cellSpot()
        if (pose["perch"]! > 0.5) != spot.perched { move("perch", to: spot.perched ? 1 : 0, over: 0.7) }
        guard hop == nil, tweens["cellUp"] == nil, spot.at != cellAt, now - lastHop > (spot.urgent ? 1 : showOff ? 3 : 20) else { return }
        let pair = [doing[0], doing[1]]
        let giver = [0, 1].first { CGFloat($0) == cellAt }, taker = [0, 1].first { CGFloat($0) == spot.at }
        let dozing = giver.map { here[$0] && !awake[$0] && pose["sink\($0)"]! > 0.9 } ?? false
        var next = Hop(from: cellAt, to: spot.at, start: now, length: 0.9, height: 1.8)                 // an easy lob
        func grab(_ who: Int) {
            gesture[who] = Gesture(move: .grab, start: now, length: 1.7, cut: nil)
            next.start = now + 0.36 * 1.7; next.length = 0.34 * 1.7; next.height = 1.0
        }
        if let toss {                                                                                    // flicked over on the way to sleep
            next.start = now + toss; next.length = 0.7; next.height = 2.2; next.caught = true
        } else if let giver, !here[giver] {                                                              // left behind: it settles over whoever stayed
            next.length = 0.6; next.height = 0.5
        } else if let taker, dozing {                                                                    // nobody throws in their sleep: the other one takes it
            guard free(taker) else { after(0.5) { [weak self] in self?.placeCell() }; return }
            grab(taker)
        } else if let giver, let taker, !spot.urgent, awake[giver], free(taker), rarely(6) {             // and now and then it just takes it anyway
            grab(taker)
        } else if pair.contains(.web) {                                                                  // surfing: it weaves across
            next.length = 1.1; next.height = 1.4; next.wobble = 0.9
        } else if pair.contains(.plan) || pair.contains(.team) {                                         // big ideas: a high, slow lob
            next.length = 1.3; next.height = 3.0
        } else if let giver, taker != nil, free(giver), pair.contains(.run) || pair.contains(.write) {   // busy hands: a flick and a catch
            start(.toss, on: giver, for: 0.55)
            next.start = now + 0.2; next.length = 0.6; next.height = 0.9; next.caught = true
        } else {
            next.header = taker != nil && rarely(8)                                                      // or it lands on a head and pops back up
        }
        hop = next
        run()
    }

    // MARK: Tweening (a 60 fps timer that exists only while something is moving)

    private func move(_ key: String, to: CGFloat, over length: Double, _ ease: Ease = .smooth, delay: Double = 0, then: (() -> Void)? = nil) {
        tweens[key] = Tween(start: now + delay, length: length, from: pose[key]!, to: to, ease: ease, then: then)
        run()
    }

    private func run() {
        if frames == nil { frames = after(1.0 / 60, repeats: true) { [weak self] in self?.step() } }
    }

    private func step() {
        let now = self.now
        for (key, t) in tweens where tweens[key]?.start == t.start {     // skips any replaced earlier in this pass
            let p = max(0, min(1, (now - t.start) / t.length))
            let eased: Double
            switch t.ease {
            case .smooth: eased = p * p * (3 - 2 * p)
            case .spring: eased = 1 + 2.7 * pow(p - 1, 3) + 1.7 * pow(p - 1, 2)
            case .windUp: eased = 2.7 * p * p * p - 1.7 * p * p
            }
            pose[key] = p >= 1 ? t.to : t.from + (t.to - t.from) * CGFloat(eased)
            if p >= 1 { tweens[key] = nil; t.then?() }
        }
        if let h = hop, now - h.start >= h.length {
            cellAt = h.to; hop = nil; lastHop = now
            if let who = [0, 1].first(where: { CGFloat($0) == h.to }), h.caught || h.header, awake[who], gesture[who] == nil {
                start(.catchIt, on: who, for: 0.4)
                if h.header { hop = Hop(from: h.to, to: h.to, start: now, length: 0.4, height: -1.2) }      // down onto the head, and back up
            }
            sparkle()
        }
        if var s = scene {      // the squabble's sweat and sparkles, and its end
            let t = now - s.start, owner = s.owner, taker = 1 - owner
            let cues: [(at: Double, run: () -> Void)] = [
                (9.1, { self.sweat(owner) }), (9.25, { self.sweat(taker) }), (10.3, { self.sweat(taker) }),
                (16.8, { self.twinkle = now }), (19.9, { self.twinkle = now }),
            ]
            while s.cue < cues.count, t >= cues[s.cue].at { cues[s.cue].run(); s.cue += 1 }
            scene = s
            if t >= Twins.squabbleLength {
                scene = nil; cellAt = CGFloat(owner); holder = owner; lastHop = now
                after(0.05) { [weak self] in self?.onFree?() }
            }
        }
        var ended = false
        for who in 0..<2 {
            guard let g = gesture[who], now - g.start >= g.length || g.cut.map({ now - $0 >= 0.25 }) == true else { continue }
            switch g.move {
            case .act, .juggle, .header, .admire, .seek: acted[who] = now
            default: break
            }
            gesture[who] = nil; ended = true
            if let next = queued[who] { queued[who] = nil; start(next.move, on: who, for: next.length) }
        }
        if ended { settleUp(); placeCell() }
        wisps.removeAll { now - $0.start >= 2.4 }
        let still = tweens.isEmpty && hop == nil && gesture[0] == nil && gesture[1] == nil && now - twinkle > 1.4
        if still && wisps.isEmpty { frames?.invalidate(); frames = nil }
        drift += 1
        if !still || wisps.isEmpty || drift % 3 == 0 { needsDisplay = true }     // a z drifts so slowly that a third of the frames will do
    }

    // MARK: Gestures

    private struct Limbs {
        var gazeX: CGFloat = 0, gazeY: CGFloat = 0, head: CGFloat = 0, tilt: CGFloat = 0, lean: CGFloat = 0
        var pawX: (CGFloat, CGFloat) = (0, 0), pawY: (CGFloat, CGFloat) = (0, 0)
        var squint: CGFloat = 0, smile: CGFloat = 0, mouth: CGFloat = 0, squash: CGFloat = 0
        var wide: CGFloat = 0, frown: CGFloat = 0, derp: CGFloat = 0, daze: CGFloat = 0
        var reach: (x: CGFloat, y: CGFloat) = (0, 0)    // how far its inner paw has gone toward the braincell...
        var grip: CGFloat = 0                           // ...to lift it from below (0), or to hold its near side (1)
        var toy: (x: CGFloat, y: CGFloat) = (0, 0)      // where its playing carries the braincell
    }

    private func limbs(_ who: Int, at now: CFTimeInterval) -> Limbs {
        var l = Limbs()
        func smooth(_ x: CGFloat) -> CGFloat { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }
        if who == 0, let slide = tweens["alone"], now > slide.start {       // shuffling along the ledge
            let u = CGFloat(min(1, (now - slide.start) / slide.length)), swing = pow(sin(.pi * u), 2)
            if awake[0] {       // it leans into the move, paw over paw, with an eye on its friend's side
                let step = u * 4, lift = pow(sin(.pi * step.truncatingRemainder(dividingBy: 1)), 2) * 0.9 * swing
                l.tilt = (slide.to > slide.from ? -5 : 5) * swing; l.gazeX = 0.8 * swing
                l.pawY = Int(step) % 2 == 0 ? (lift, 0) : (0, lift)
            } else {            // asleep, it's nudged along, or slumps into the space
                l.tilt = -5 * swing
            }
        }
        guard let g = gesture[who] else { return l }
        if g.move == .squabble, let s = scene { return quarrel(who, now - s.start, owner: s.owner) }
        let p = CGFloat(min(1, max(0, (now - g.start) / g.length)))
        let fade = CGFloat(g.cut.map { max(0, 1 - (now - $0) / 0.25) } ?? 1)   // easing out early, if it was asked to stop
        let ease = smooth(min(p, 1 - p) * 4) * fade                             // glides in, holds, glides out
        let bell = pow(sin(.pi * p), 2) * fade                                  // one smooth rise and fall
        let toward: CGFloat = who == 0 ? 1 : -1                                 // which way the other twin is
        func wave(_ cycles: CGFloat) -> CGFloat { sin(p * cycles * 2 * .pi) }
        func inner(_ v: CGFloat) -> (CGFloat, CGFloat) { who == 0 ? (0, v) : (v, 0) }
        switch g.move {
        case .act(.think):      // gazes up, pondering
            l.gazeY = 0.45 * ease
        case .act(.read):       // eyes travel along two lines, gliding back to the start of the second
            let line = (p * 2).truncatingRemainder(dividingBy: 1)
            l.gazeX = (2 * smooth(line < 0.8 ? line / 0.8 : 1 - (line - 0.8) / 0.2) - 1) * 0.85 * ease; l.gazeY = -0.35 * ease
        case .act(.write):      // four soft taps, one paw and then the other
            let beat = p * 4, tap = pow(sin(.pi * beat.truncatingRemainder(dividingBy: 1)), 2) * 0.9 * ease
            l.pawY = Int(beat) % 2 == 0 ? (tap, 0) : (0, tap); l.gazeY = -0.4 * ease
        case .act(.run):        // leans in and narrows its eyes at the output
            l.squint = 0.5 * ease; l.gazeY = -0.3 * ease; l.head = -0.3 * ease
        case .act(.web):        // looks all around, once
            l.gazeX = wave(1) * 0.9 * ease; l.gazeY = cos(p * 2 * .pi) * 0.4 * ease
        case .act(.plan):       // tilts its head one way, then the other
            l.tilt = wave(1) * 6 * ease; l.gazeY = 0.4 * ease
        case .act(.team):       // conducts with both paws
            l.pawY = (2.2 * ease, 2.2 * ease); l.pawX = (wave(1) * 0.7 * ease, -wave(1) * 0.7 * ease)
        case .act(.wait):       // leans out and waves at whoever it's waiting for
            l.tilt = 5 * toward * ease; l.gazeY = -0.3 * ease
            if who == 0 { l.pawY.0 = 2.8 * ease; l.pawX.0 = wave(2) * 0.7 * ease } else { l.pawY.1 = 2.8 * ease; l.pawX.1 = wave(2) * 0.7 * ease }
        case .act(.tidy):       // squeezes itself down, the way its Claude is squeezing its memory
            l.squash = bell; l.squint = 0.6 * bell
        case .catchIt:          // dips as the braincell lands
            l.head = -0.6 * bell
        case .bump:             // the paws they hold bump once
            l.pawY = inner(1.3 * bell)
        case .greet:            // the other one just woke up: a glance over, and it sits up a little
            l.gazeX = 0.9 * toward * ease; l.head = 0.6 * bell
        case .glad:             // a to-do item is done: its eyes smile
            l.smile = ease; l.head = 0.5 * bell
        case .toss:             // flicks the braincell over
            l.pawY = inner(2.2 * bell); l.pawX = inner(0.9 * toward * bell)
        case .grab:             // reaches up and over, takes the braincell from above the other's head, and brings it home
            l.reach = p < 0.5 ? (smooth((p - 0.08) / 0.24) * fade, smooth(p / 0.24) * fade)
                              : ((1 - smooth((p - 0.72) / 0.2)) * fade, (1 - smooth((p - 0.78) / 0.22)) * fade)
        case .five:             // a high five
            l.pawY = inner(4.2 * bell); l.pawX = inner(0.4 * toward * bell); l.gazeX = 0.8 * toward * ease; l.smile = bell
        case .yawn:             // a big yawn
            let wide = smooth(min(p, 1 - p) * 3.5) * fade
            l.mouth = wide; l.squint = wide; l.head = 0.5 * wide
        case .stretch:          // a long stint is over: it stretches
            l.pawY = (3.2 * ease, 3.2 * ease); l.pawX = (-0.9 * ease, 0.9 * ease); l.head = 0.7 * ease; l.smile = ease
        case .hug:              // it's been a while: they lean in until their heads touch, and stay there a moment
            let close = smooth(min(p, 1 - p) * 3) * fade
            l.lean = 2.0 * toward * close; l.tilt = -6 * toward * close + wave(2) * 1.5 * close; l.smile = ease
        case .peek:             // its friend is asleep: it leans over for a look
            l.lean = 0.9 * toward * ease; l.tilt = -6 * toward * ease; l.gazeX = 0.9 * toward * ease; l.gazeY = -0.35 * ease
        case .bye:              // its friend is off: it watches it go, with a little wave
            l.gazeX = 0.9 * toward * ease; l.gazeY = -0.3 * ease
            l.pawY = inner(2.4 * ease); l.pawX = inner(wave(2) * 0.7 * ease)
        case .juggle:           // tosses the braincell from paw to paw
            let swing = wave(2), right = pow(max(0, swing), 2) * ease, left = pow(max(0, -swing), 2) * ease
            l.toy = (6.5 * swing * ease, -3.4 * swing * swing * ease)
            l.pawY = (4.6 * left, 4.6 * right); l.pawX = (0.4 * left, -0.4 * right)
            l.gazeX = 0.9 * swing * ease; l.gazeY = 0.2 * ease
        case .header:           // keeps the braincell up with its head: down onto it and up again, three times
            let fall: CGFloat = p < 0.2 ? pow(p / 0.2, 2) : p > 0.8 ? pow((1 - p) / 0.2, 2) : 1
            let bounce = p > 0.2 && p < 0.8 ? abs(sin(.pi * (p - 0.2) / 0.3)) : 0
            let knock = [0.2, 0.5, 0.8].map { pow(max(0, 1 - abs(p - $0) / 0.07), 2) }.reduce(0, +)
            l.toy = (0, (3.6 * bounce - 1.2 * fall) * fade); l.head = -0.7 * knock * fade; l.gazeY = 0.5 * ease
        case .admire:           // takes the braincell in a paw to admire it
            l.toy = (6.5 * ease, -3.4 * ease * ease); l.pawY.1 = 4.6 * ease; l.pawX.1 = -0.4 * ease
            l.gazeX = 0.9 * ease; l.tilt = -4 * ease; l.smile = smooth((p - 0.35) / 0.15) * ease
        case .seek:             // looks one way and then the other for its friend, and sighs
            let look = key(Double(p), [(0, 0), (0.16, 1), (0.36, 1), (0.56, -1), (0.76, -1), (0.9, 0)]) * fade
            let sigh = pow(sin(.pi * max(0, min(1, (p - 0.78) / 0.22))), 2) * fade
            l.gazeX = 0.95 * look; l.lean = 1.3 * look; l.tilt = -3.5 * look; l.head = 0.8 * abs(look) - 0.6 * sigh; l.squint = 0.5 * sigh
        case .squabble:
            break
        }
        return l
    }

    // MARK: The squabble

    /// Every few months, the one without the braincell helps itself, and it gets out of hand.
    /// It's all here as keyframes, in seconds from the start: A is whose braincell it was, B the
    /// one who took it.
    private struct Scene { let start: CFTimeInterval, owner: Int; var cue = 0 }
    private var scene: Scene?
    static let squabbleLength = 22.0
    var absorbed: Bool { scene != nil }

    /// Starts it, if both are up with nothing else going on.
    @discardableResult func squabble() -> Bool {
        guard scene == nil, here[1], free(0), free(1), hop == nil, tweens.isEmpty, pose["perch"]! == 0, cellAt == 0 || cellAt == 1 else { return false }
        scene = Scene(start: now, owner: Int(cellAt))
        queued = [nil, nil]
        for who in 0..<2 { gesture[who] = Gesture(move: .squabble, start: now, length: Twins.squabbleLength, cut: nil) }
        log("twins: squabble")
        run()
        return true
    }

    private func quarrel(_ who: Int, _ t: Double, owner: Int) -> Limbs {
        var l = Limbs()
        let a = who == owner, toward: CGFloat = who == 0 ? 1 : -1
        func k(_ frames: (Double, CGFloat)...) -> CGFloat { key(t, frames) }
        func beat(_ at: Double, _ length: Double) -> CGFloat {      // one smooth pulse
            let u = (t - at) / length
            return u > 0 && u < 1 ? pow(sin(.pi * CGFloat(u)), 2) : 0
        }
        var gaze: CGFloat = 0, paw: CGFloat = 0     // toward the other one: its eyes, and its inner paw

        // B eyes the braincell and helps itself. A takes it back, B hangs on, and they pull.
        let hold = a ? k((2.5, 0), (2.8, 1), (5.4, 1), (5.62, 0))
                     : k((0.7, 0), (1.05, 1), (1.7, 1), (2.0, 0), (2.85, 0), (3.15, 1), (5.4, 1), (5.62, 0))
        let strain = k((3.3, 0), (3.8, 0.4), (5.3, 1), (5.45, 1.5), (6.1, 0))       // leaning back on it, and thrown back when it goes
        l.reach = (hold, hold); l.grip = k((3.1, 0), (3.5, 1))
        l.lean = -1.7 * toward * strain; l.tilt = 8 * toward * strain
        l.squint = 0.5 * k((3.4, 0), (3.8, 1), (5.35, 1), (5.45, 0))
        l.frown = a ? k((1.9, 0), (2.3, 1), (5.4, 1), (5.6, 0)) : k((2.9, 0), (3.2, 1), (5.4, 1), (5.6, 0))
        if a {
            l.head = 0.5 * beat(1.9, 0.8)
        } else {
            let sly = k((0.1, 0), (0.5, 1), (0.9, 1), (1.3, 0))
            l.squint += 0.4 * sly; l.lean += 0.6 * toward * sly
            l.smile = k((1.6, 0), (1.8, 1), (2.4, 1), (2.6, 0))
        }

        // It shoots off the top of the screen. They watch it go, blink, and without a braincell their minds wander.
        let came = a ? 8.4 : 8.85                   // A comes round first, and gives B a nudge
        let blank = k((7.2, 0), (7.9, 1), (came, 1), (came + 0.15, 0))
        l.gazeY = k((5.4, 0), (5.6, 1), (7.2, 1), (7.9, 0.2), (came, 0.2), (came + 0.1, 0))
        l.head += 0.6 * k((5.5, 0), (5.9, 1), (7.2, 1), (7.7, 0))
        l.squint += beat(6.3, 0.2) + beat(6.68, 0.2) + 0.3 * blank
        l.derp = blank; l.tilt += (a ? 6 : -5) * toward * blank
        gaze = k((5.6, 0), (5.9, 0.3), (7.2, 0.3), (7.6, 0))
        if a {
            l.gazeX = sin((t - 8.4) * 8 * .pi) * 0.7 * beat(8.4, 0.5)
            gaze += k((8.6, 0), (8.75, 0.8), (9.0, 0.8), (9.1, 0)); paw = 0.62 * beat(8.7, 0.35)
        } else {
            l.tilt += 3 * sin((t - 8.85) * 6 * .pi) * beat(8.85, 0.6)
        }

        // Panic: they look everywhere, one over the top while the other ducks under the ledge. Then it's the other one's fault.
        let panic = k((9.0, 0), (9.2, 1), (11.0, 1), (11.2, 0)), blame = k((11.1, 0), (11.3, 1), (12.3, 1), (12.6, 0))
        l.gazeX += sin((t - 9.0) * 3.4 * .pi + (a ? 0 : 2)) * panic
        let over = a ? k((9.4, 0), (9.7, 1), (10.2, 1), (10.4, 0)) : k((10.4, 0), (10.7, 1), (11.0, 1), (11.2, 0))
        let under = a ? k((10.4, 0), (10.62, 1), (10.9, 1), (11.1, 0)) : k((9.4, 0), (9.62, 1), (9.95, 1), (10.15, 0))
        l.head += 2 * over - 12 * under; l.gazeY += over
        l.frown += blame; l.lean += 0.8 * toward * blame; l.tilt -= 4 * toward * blame; gaze += 0.8 * blame
        for at in a ? [11.3, 11.78, 12.15] : [11.55, 11.98] { paw += beat(at, 0.24) }      // they slap at each other's paws

        // B has an idea: half a braincell each. It squeezes one out, a little dizzy after; A sighs and does the same.
        let pop = a ? 15.35 : 13.55
        let squeeze = k((pop - 0.45, 0), (pop, 1), (pop + 0.12, -0.45), (pop + 0.45, 0)), woozy = beat(pop + 0.1, 0.7)
        l.squash = squeeze; l.squint += 0.8 * max(0, squeeze); l.derp += 0.5 * woozy
        l.tilt += 2.5 * sin((t - pop) * 3 * .pi) * woozy
        if a {
            gaze += k((12.3, 0), (12.5, 0.9), (14.2, 0.9), (14.5, 0))
            l.gazeY += k((12.3, 0), (12.5, 0.3), (14.2, 0.3), (14.5, 1), (14.9, 1), (15.1, 0))
            l.head -= 0.6 * beat(14.5, 0.5); l.squint += 0.6 * beat(14.5, 0.5)
        } else {
            let idea = k((12.3, 0), (12.45, 1), (13.0, 1), (13.15, 0))
            l.gazeY += 0.9 * idea; l.head += 0.8 * beat(12.3, 0.9)
            l.smile += k((12.7, 0), (12.9, 1), (13.1, 1), (13.2, 0)) + k((14.1, 0), (14.3, 1), (14.9, 1), (15.1, 0))
            gaze += k((14.1, 0), (14.3, 0.8), (15.9, 0.8), (16.1, 0))
        }

        // The halves click together. Relief, and a high five.
        let watch = k((15.9, 0), (16.2, 1), (16.8, 1), (17.0, 0))
        gaze += 0.6 * watch; l.gazeY += 0.6 * watch
        l.smile += k((16.8, 0), (17.0, 1), (18.4, 1), (18.7, 0)); l.head += 0.5 * beat(16.8, 0.5)
        let five = beat(17.3, 1.1)

        // The old one drops back in, onto B's head, and bounces into the new one: for a moment, a big brain.
        if a {
            gaze += k((18.9, 0), (19.05, 0.9), (19.3, 0.9), (19.9, 0))
            l.gazeY += k((18.9, 0), (19.05, 0.8), (19.3, 0.1), (19.9, 1), (20.9, 1), (21.3, 0))
            l.head -= 0.6 * k((19.9, 0), (20.1, 1), (20.9, 1), (21.3, 0))
            l.smile += k((20.4, 0), (20.6, 1), (21.2, 1), (21.5, 0))
        } else {
            l.squash += k((19.3, 0), (19.38, 1), (19.6, -0.2), (19.9, 0)); l.head -= 1.4 * beat(19.3, 0.5)
            l.daze = k((19.3, 0), (19.36, 1), (20.4, 1), (20.7, 0))
            gaze += k((20.5, 0), (20.7, 0.9), (21.2, 0.9), (21.3, 0))
        }
        l.wide = a ? k((5.4, 0), (5.5, 1), (7.2, 0.7), (7.9, 0.2), (8.4, 0.2), (8.6, 0.8), (9.0, 1), (11.1, 1), (11.3, 0.1), (12.3, 0.1), (12.5, 0.5),
                       (14.9, 0.5), (15.1, 0), (15.9, 0), (16.1, 0.5), (16.8, 0.5), (17.0, 0), (18.9, 0), (19.05, 1), (20.9, 1), (21.3, 0))
                   : k((5.4, 0), (5.5, 1), (7.2, 0.7), (7.9, 0.2), (8.85, 0.2), (9.0, 1), (11.1, 1), (11.3, 0.1), (12.3, 0.1), (12.45, 0.8),
                       (13.0, 0.8), (13.15, 0), (15.9, 0), (16.1, 0.5), (16.8, 0.5), (17.0, 0), (20.5, 0), (20.7, 0.9), (20.9, 0.9), (21.3, 0))

        // And back to work, with a look at each other.
        gaze += k((21.3, 0), (21.5, 0.8), (21.8, 0.8), (22, 0)); l.squint += beat(21.55, 0.2); l.tilt += 4 * toward * beat(21.3, 0.6)
        l.gazeX += gaze * toward
        let lift = 2.6 * paw + 4.2 * five, across = (2.4 * paw + 0.4 * five) * toward
        if who == 0 { l.pawY.1 = lift; l.pawX.1 = across } else { l.pawY.0 = lift; l.pawX.0 = across }
        return l
    }

    /// What isn't a twin, in the squabble: the braincell, the two halves, the old one coming back, and B's idea.
    private struct Stage {
        var c: CGFloat = 0, x: CGFloat = 0, y: CGFloat = 0      // the braincell: between A (0) and B (1), and where that is
        var wide: CGFloat = 1, tall: CGFloat = 1, shown = true, watched: CGFloat = 1
        var halves: [(x: CGFloat, y: CGFloat, turn: CGFloat, size: CGFloat)] = []
        var spare: NSPoint?, idea: (x: CGFloat, y: CGFloat, size: CGFloat) = (0, 0, 0)
    }

    private func staged(_ t: Double, owner a: Int, at x: [CGFloat], ceiling: CGFloat) -> Stage {
        var s = Stage()
        let b = 1 - a, aloft = [twin[0].top + 3.1, twin[1].top + 3.1], middle = (x[a] + x[b]) / 2, between = (aloft[a] + aloft[b]) / 2
        func k(_ frames: (Double, CGFloat)...) -> CGFloat { key(t, frames) }
        func span(_ from: Double, _ length: Double) -> CGFloat { CGFloat(max(0, min(1, (t - from) / length))) }

        // Carried off, carried halfway back, pulled this way and that, and gone. It's back once the halves have met.
        s.c = k((1.1, 0), (1.6, 1), (2.85, 1), (3.3, 0.5), (3.8, 0.37), (4.25, 0.62), (4.7, 0.39), (5.1, 0.6), (5.4, 0.5), (18.4, 0.5), (18.9, 0))
        s.wide = k((3.4, 1), (3.8, 1.5), (4.0, 1.3), (4.25, 1.7), (4.5, 1.45), (4.7, 1.9), (4.9, 1.65), (5.1, 2.1), (5.4, 2.3), (5.5, 0.6), (6, 0.6),
                   (6.1, 1), (16.7, 1), (16.8, 1.4), (17.0, 0.85), (17.2, 1.08), (17.4, 1))
        s.tall = pow(s.wide, -0.8)
        let size = k((19.9, 1), (20.08, 1.7), (20.25, 1.5), (20.9, 1.5), (21.3, 1))
        s.wide *= size; s.tall *= size
        s.x = x[a] + (x[b] - x[a]) * s.c
        s.y = aloft[a] + (aloft[b] - aloft[a]) * s.c + pow(sin(.pi * span(1.1, 0.5)), 2) + k((2.9, 0), (3.5, -2.6), (6, -2.6), (6.1, 0))
        if t < 6 { s.y += (ceiling + 5 - s.y) * pow(span(5.4, 0.45), 2) }
        s.shown = t < 5.85 || t >= 16.8
        s.watched = k((5.4, 1), (5.7, 0), (16.8, 0), (17.1, 1))

        // Each half rises out of a head as a dome, then turns on its side and drifts in to meet the other.
        for who in [a, b] where t >= (who == a ? 15.35 : 13.55) && t < 16.8 {
            let pop = who == a ? 15.35 : 13.55, away: CGFloat = who == 0 ? -1 : 1
            s.halves.append((x: k((16.0, x[who]), (16.65, middle + 0.4 * away), (16.8, middle)),
                             y: k((pop, twin[who].top - 1), (pop + 0.22, aloft[who] + 0.6), (pop + 0.45, aloft[who] - 0.9), (16.0, aloft[who] - 0.9), (16.65, between)),
                             turn: -90 * away * k((16.0, 0), (16.6, 1)), size: k((pop, 0.3), (pop + 0.2, 1))))
        }
        s.idea = (x[b], twin[b].top + 5, pow(sin(.pi * span(12.4, 0.8)), 2))

        // The old one falls back onto B's head, and bounces across into the new one.
        if t >= 18.9, t < 19.9 {
            let landing = twin[b].top + 1.9, fall = pow(span(18.9, 0.4), 2), u = span(19.3, 0.6)
            s.spare = NSPoint(x: x[b] + (x[a] - x[b]) * u, y: ceiling + 3 + (landing - ceiling - 3) * fall + (aloft[a] - landing) * u + 5 * sin(.pi * u))
        }
        return s
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = (button ?? self).effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The ledge: the menu bar's bottom edge, or a line level with the other icons. Below it is clipped away.
        let ledge = (bounds.midY - Twins.ledgeBelowCenter) * pose["center"]!
        let shift = NSAffineTransform()
        shift.translateX(by: 0, yBy: ledge)
        shift.concat()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: 0, width: bounds.width, height: bounds.height)).addClip()
        // The slot's right edge stays where it is when the menu bar makes room, so everything is measured from there.
        paint(dark: dark, originX: (edge ?? bounds.width) - Twins.size.width, ceiling: bounds.height - ledge, at: now)
    }

    private func paint(dark: Bool, originX ox: CGFloat, ceiling: CGFloat, at now: CFTimeInterval) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let ink = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
        let perch = pose["perch"]!, cellUp = pose["cellUp"]!
        let limb = [limbs(0, at: now), limbs(1, at: now)], at = [place(0), place(1)]
        func drop(_ i: Int) -> CGFloat { (pose["up\(i)"]! - 1) * (twin[i].top + 2.5) - pose["sink\(i)"]! * Twins.doze + limb[i].head }
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSRect {
            NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        }
        func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            let pinch = r * 0.22, path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y + r)); path.line(to: NSPoint(x: x + pinch, y: y + pinch))
            path.line(to: NSPoint(x: x + r, y: y)); path.line(to: NSPoint(x: x + pinch, y: y - pinch))
            path.line(to: NSPoint(x: x, y: y - r)); path.line(to: NSPoint(x: x - pinch, y: y - pinch))
            path.line(to: NSPoint(x: x - r, y: y)); path.line(to: NSPoint(x: x - pinch, y: y + pinch))
            path.close(); path.fill()
        }

        var cell = cellAt, arc: CGFloat = 0     // where the braincell is on its way across
        if let h = hop {
            let u = CGFloat(min(1, max(0, (now - h.start) / h.length)))
            cell = h.from + (h.to - h.from) * (u * u * (3 - 2 * u))
            arc = sin(.pi * u) * (h.height + sin(.pi * u * 4) * h.wobble)
        }
        // It floats over a head. While it's coming or going it passes behind them, as if popping out of one.
        func float(_ i: Int) -> CGFloat { twin[i].top - pose["sink\(i)"]! * Twins.doze + limb[i].head + 3.1 }
        let aloft = float(0) + (float(1) - float(0)) * cell + arc
        var cellSpot = oval(ox + at[0] + (at[1] - at[0]) * cell + limb[0].toy.x, -3 + (aloft + (3.6 - aloft) * perch + 3) * cellUp + limb[0].toy.y, 1.9, 1.9)
        var watching = max(0, min(1, cellUp)), stage: Stage?
        if let s = scene {      // in the squabble, it goes where the story takes it
            let set = staged(now - s.start, owner: s.owner, at: at, ceiling: ceiling)
            cell = s.owner == 0 ? set.c : 1 - set.c; watching *= set.watched
            cellSpot = oval(ox + set.x, set.y, 1.9 * set.wide, 1.9 * set.tall)
            stage = set
        }
        if cellUp < 1 { accent.setFill(); NSBezierPath(ovalIn: cellSpot).fill() }

        for (i, t) in twin.enumerated() {
            let l = limb[i], cx = ox + at[i] + l.lean, down = drop(i), hollow = i == 1
            let edge: CGFloat = hollow ? 0.55 : 0          // keeps the outline inside the same silhouette
            let wide = t.width / 2 - edge, top = t.top + down - edge, shoulder = top - wide * 0.95
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

            // Eyes drift toward the braincell: the holder glances up, the other looks across.
            let holds = i == 0 ? 1 - cell : cell, ko = max(pose["ko\(i)"]!, l.daze)
            let reach: CGFloat = hollow ? 0.55 : 1.2
            let gazeX = max(-reach, min(reach, (i == 0 ? 0.55 : -0.55) * (1 - holds) * watching + l.gazeX))
            let gazeY = (0.35 * holds * (1 - perch) - 0.45 * perch) * watching + l.gazeY + 0.25 * l.smile
            let open = 1.2 * (1 - 0.75 * pose["lid\(i)"]!) * (1 - 0.75 * min(1, l.squint)) * (1 - ko)
            let face = NSBezierPath(), crosses = NSBezierPath()
            for side: CGFloat in [-1, 1] {
                // Wide with alarm, the eyes grow. Without a braincell, they wander off in different directions.
                let x = cx + side * (t.eyeGap + 0.5 * l.derp) + gazeX * (1 - ko), y = t.eyeY + down + gazeY * (1 - ko) + side * 0.7 * l.derp
                let w = (1 + 0.3 * l.wide) * (1 + 0.22 * side * l.derp), k = open * 4 / 3 * w, low = k * (1.55 * l.smile - 1)    // the lower lid curves down (an oval) or, smiling, up
                let scowl = k * (1 - 0.9 * l.frown)                                              // cross: the upper lid slopes down toward the nose
                face.move(to: NSPoint(x: x - w, y: y))
                face.curve(to: NSPoint(x: x + w, y: y), controlPoint1: NSPoint(x: x - w, y: y + (side > 0 ? scowl : k)), controlPoint2: NSPoint(x: x + w, y: y + (side < 0 ? scowl : k)))
                face.curve(to: NSPoint(x: x - w, y: y), controlPoint1: NSPoint(x: x + w, y: y + low), controlPoint2: NSPoint(x: x - w, y: y + low))
                face.close()
                for slant: CGFloat in [-1, 1] {
                    crosses.move(to: NSPoint(x: x - 0.75, y: y - 0.75 * slant)); crosses.line(to: NSPoint(x: x + 0.75, y: y + 0.75 * slant))
                }
            }
            if l.mouth > 0 { face.appendOval(in: oval(cx, t.eyeY + down - 2.4, 0.85 * l.mouth, 1.15 * l.mouth)) }
            if l.tilt != 0 || l.squash != 0 {
                var bend = AffineTransform(translationByX: cx, byY: 0)
                bend.rotate(byDegrees: l.tilt)
                bend.scale(x: 1 + 0.08 * l.squash, y: 1 - 0.2 * l.squash)
                bend.translate(x: -cx, y: 0)
                for path in [head, face, crosses] { path.transform(using: bend) }
            }
            if cellUp < 1 {     // the braincell is passing behind: don't let it show through
                cg.setBlendMode(.clear); head.fill(); cg.setBlendMode(.normal)
            }
            crosses.lineWidth = 0.6; crosses.lineCapStyle = .round
            if hollow {         // my friend's is an outline with solid eyes
                ink.setStroke(); head.lineWidth = 1.1; head.stroke()
                ink.setFill(); face.fill()
                ink.withAlphaComponent(ink.alphaComponent * ko).setStroke(); crosses.stroke()
            } else {            // mine is solid, with the eyes cut out
                ink.setFill(); head.fill()
                cg.setBlendMode(.destinationOut)
                NSColor.black.setFill(); face.fill()
                NSColor.black.withAlphaComponent(ko).setStroke(); crosses.stroke()
                cg.setBlendMode(.normal)
            }
        }

        ink.setFill()
        for (i, t) in twin.enumerated() {       // the ledge cuts the paws into flat-bottomed mitts
            let l = limb[i], lift = (pose["paws\(i)"]! - 1) * 4
            for (n, side) in [CGFloat(-1), 1].enumerated() {
                var x = ox + at[i] + side * t.paw + (n == 0 ? l.pawX.0 : l.pawX.1), y = lift + 0.7 + (n == 0 ? l.pawY.0 : l.pawY.1)
                if n != i {     // the inner paw can go and fetch the braincell, from below or by its near side
                    let hold = NSPoint(x: cellSpot.midX + (i == 0 ? -1 : 1) * l.grip * (cellSpot.width / 2 + 0.3), y: cellSpot.midY - 2.6 + 2.3 * l.grip)
                    x += (hold.x - x) * l.reach.x; y += (hold.y - y) * l.reach.y
                }
                NSBezierPath(ovalIn: oval(x, y, 1.6, 1.35)).fill()
            }
        }

        accent.setFill()
        if cellUp >= 1, stage?.shown != false { NSBezierPath(ovalIn: cellSpot).fill() }
        if let stage {
            for half in stage.halves {
                let dome = NSBezierPath()
                dome.appendArc(withCenter: .zero, radius: 1.9 * half.size, startAngle: 0, endAngle: 180)
                dome.close()
                var put = AffineTransform(translationByX: ox + half.x, byY: half.y)
                put.rotate(byDegrees: half.turn)
                dome.transform(using: put); dome.fill()
            }
            if let spare = stage.spare { NSBezierPath(ovalIn: oval(ox + spare.x, spare.y, 1.9, 1.9)).fill() }
            if stage.idea.size > 0 { star(ox + stage.idea.x, stage.idea.y, 2 * stage.idea.size) }
        }
        let glint = CGFloat((now - twinkle) / 1.4)
        if glint < 1 {
            for (n, at) in ([(-3.8, 0.6), (3.6, 1.8), (0.4, 4.3)] as [(CGFloat, CGFloat)]).enumerated() {
                star(cellSpot.midX + at.0, cellSpot.midY + at.1, 1.6 * pow(sin(.pi * max(0, min(1, (glint - 0.2 * CGFloat(n)) / 0.6))), 2))
            }
        }

        for w in wisps {        // they fade as they go, and with their twin if it ducks away
            let p = CGFloat((now - w.start) / 2.4)
            guard p > 0, p < 1 else { continue }
            let shade = ink.withAlphaComponent(ink.alphaComponent * min(1, p * 4) * (1 - p) * max(0, min(1, pose["up\(w.who)"]!))), path = NSBezierPath()
            if w.sweat {        // a bead of sweat runs down beside the head
                let x = ox + w.x, y = w.y - 3 * p
                path.move(to: NSPoint(x: x, y: y + 1.4))
                path.curve(to: NSPoint(x: x, y: y - 0.9), controlPoint1: NSPoint(x: x + 1.2, y: y - 0.1), controlPoint2: NSPoint(x: x + 0.9, y: y - 0.9))
                path.curve(to: NSPoint(x: x, y: y + 1.4), controlPoint1: NSPoint(x: x - 0.9, y: y - 0.9), controlPoint2: NSPoint(x: x - 1.2, y: y - 0.1))
                shade.setFill(); path.fill()
            } else {            // a z drifts up and away
                let half = (1.0 + 0.6 * p) * w.size
                let x = ox + w.x + w.side * 1.4 * p + sin(p * 2 * .pi) * 0.4, y = w.y + 5 * p
                path.move(to: NSPoint(x: x - half, y: y + half)); path.line(to: NSPoint(x: x + half, y: y + half))
                path.line(to: NSPoint(x: x - half, y: y - half)); path.line(to: NSPoint(x: x + half, y: y - half))
                path.lineWidth = 0.7; path.lineCapStyle = .round; path.lineJoinStyle = .round
                shade.setStroke(); path.stroke()
            }
        }
    }
}

// MARK: - Menu bar item

/// Owns the status item. Shy ("Disappear when idle", the usual way), the twins come out while
/// we're both working; whoever stops falls asleep, and they leave once either has slept for
/// `nap`. Otherwise my twin is always out, asleep whenever I'm not working: my friend's joins it
/// while they work, falls asleep when they stop, and leaves after its nap.
@MainActor final class MenuBarItem: NSObject, NSMenuDelegate {
    var nap = napFor
    var hour: TimeInterval = 3600       // each one we've worked together today earns a high five
    var shy = false { didSet { if shy != oldValue { refresh() } } }
    var onSquabble: (() -> Void)?       // my twins have fallen out: time to tell my friend's
    var paired = true                   // false until a friend's Mac has ever been heard from
    var crowded = false { didSet { crowd.isHidden = !crowded } }      // a third Mac is using our pairing code
    private let item = NSStatusBar.system.statusItem(withLength: Twins.size.width)
    private let twins = Twins()
    private let mine = NSMenuItem(), theirs = NSMenuItem(), tally = NSMenuItem()
    private let crowd = NSMenuItem(title: "This pairing code is on more than two Macs", action: nil, keyEquivalent: "")
    private var out = [false, false]    // which twins are on the ledge
    private var room = Twins.size.width // how wide a slot they need for now
    private var latest: (me: Mind, friend: Mind, stopped: [Date?])?
    private var napTimer: Timer?
    private var fiveTimer: Timer?
    private var inkWatch: NSKeyValueObservation?
    private var ticked = [0, 0]
    private var together: TimeInterval = 0, bothSince: Date?, day = Date()   // how long we've both been working today

    init(extras: [NSMenuItem]) {
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for line in [mine, theirs, tally, crowd] { line.isEnabled = false; menu.addItem(line) }
        crowd.isHidden = true
        if !extras.isEmpty { menu.addItem(.separator()) }
        extras.forEach { menu.addItem($0) }
        item.isVisible = false
        item.menu = menu
        twins.button = item.button
        twins.autoresizingMask = [.width, .height]
        twins.onWidth = { [weak self] width in self?.room = width; self?.seat() }
        twins.onSquabble = { [weak self] in self?.onSquabble?() }
        twins.onFree = { [weak self] in self?.refresh() }
        inkWatch = item.button?.observe(\.effectiveAppearance) { [twins] _, _ in
            MainActor.assumeIsolated { twins.needsDisplay = true }
        }
        seat()
    }

    /// The twins live in the status item's window rather than its button: the window is as tall as
    /// the menu bar on every Mac, so they can sit on its bottom edge with headroom above. Where the
    /// menu bar leaves room around each item (that window is wider than the button), the slot is
    /// exactly as wide as the twins. Where it doesn't, they keep a little room of their own.
    private func seat() {
        guard let button = item.button else { return }
        var host: NSView = button
        if let content = button.window?.contentView, content.bounds.height < 64, content.bounds.width < button.bounds.width + 64 {
            host = content      // only while that window is what it is today: one menu bar slot
        }
        let pad: CGFloat = host.bounds.width >= button.bounds.width + 8 ? 0 : 2
        if item.length != room + pad * 2 { item.length = room + pad * 2; log("slot: \(item.length) pt wide") }
        if twins.superview !== host { host.addSubview(twins) }
        if twins.frame != host.bounds { twins.frame = host.bounds }
        twins.edge = button.convert(button.bounds, to: host).maxX - pad
    }

    func setCentered(_ on: Bool, animated: Bool) { twins.setCentered(on, animated: animated) }

    func menuWillOpen(_ menu: NSMenu) {
        let minutes = Int((together + (bothSince.map { Date().timeIntervalSince($0) } ?? 0)) / 60)
        let time = minutes < 1 ? "under a minute" : (minutes < 60 ? "" : "\(minutes / 60)h ") + "\(minutes % 60)m"
        tally.title = "Together: \(time) today"
    }

    /// stopped: when each of us went quiet (nil while working).
    func update(me: Mind, friend: Mind, stopped: [Date?]) {
        latest = (me, friend, stopped)
        let now = Date(), both = me.busy && friend.busy
        mine.title = "You: " + me.words
        theirs.title = "Friend: " + (paired ? friend.words : "hasn't joined yet")
        item.button?.toolTip = mine.title + "\n" + theirs.title
        if !Calendar.current.isDate(now, inSameDayAs: day) { day = now; together = 0; bothSince = bothSince.map { _ in now }; fiveTimer?.invalidate(); fiveTimer = nil }
        if both { bothSince = bothSince ?? now } else if let since = bothSince { together += now.timeIntervalSince(since); bothSince = nil }
        if both != (fiveTimer != nil) { scheduleFive() }
        guard !twins.absorbed else { return }       // mid-squabble: they catch up when it's over

        seat()
        if me.busy { twins.setDoing(0, me.doing) }
        if friend.busy { twins.setDoing(1, friend.doing) }
        twins.setMood(0, me.mood); twins.setMood(1, friend.mood)
        let ticks = [me.busy ? me.ticked : 0, friend.busy ? friend.ticked : 0]
        for who in 0..<2 where out[who] && ticks[who] > ticked[who] { twins.tick(who) }
        ticked = ticks

        // Who belongs on the ledge. A twin that's out and asleep stays until its nap is over:
        // my friend's nap, or when we're shy, whichever of ours began first.
        let napEnds = (shy ? stopped.compactMap { $0 }.min() : stopped[1])?.addingTimeInterval(nap)
        let napping = out[1] && (napEnds.map { $0 > now } ?? false)
        let pair = napping || (shy ? both : friend.busy)
        napTimer?.invalidate()
        napTimer = napping ? after(napEnds!.timeIntervalSince(now) + 0.05) { [weak self] in self?.refresh() } : nil
        if pair || !shy {
            if !out[0] { item.isVisible = true; seat() }
            if out != [true, pair] { log("twins: \(pair ? "both" : "mine") out") }
            out = [true, pair]
            twins.show(friend: pair)
        } else if out[0] {
            out = [false, false]
            log("twins: leave")
            twins.leave { [weak self] in
                guard let self, !self.out[0] else { return }   // they came back mid-exit
                self.item.isVisible = false
            }
        }
        twins.setAwake(0, me.busy); twins.setAwake(1, friend.busy)
    }

    private func refresh() {
        if let latest { update(me: latest.me, friend: latest.friend, stopped: latest.stopped) }
    }

    private func scheduleFive() {
        fiveTimer?.invalidate(); fiveTimer = nil
        guard let since = bothSince else { return }
        let done = together + Date().timeIntervalSince(since)
        fiveTimer = after(hour - done.truncatingRemainder(dividingBy: hour) + 0.5) { [weak self] in
            self?.twins.highFive(); self?.scheduleFive()
        }
    }

    /// The demo runs on a fast clock, and rare moments come up often.
    func showOff() {
        nap = 8; hour = 30; twins.showOff = true
    }

    /// The rarest moment, on request. False if the twins are in the middle of something.
    func squabble() -> Bool { twins.squabble() }
    var squabbling: Bool { twins.absorbed }

    /// On my friend's Mac the twins have just fallen out, so here they do too, as soon as they have a moment.
    func squabbleToo() {
        var tries = 0, timer: Timer?
        timer = after(0.5, repeats: true) { [weak self] in
            tries += 1
            if self?.twins.squabble() != false || tries == 10 { timer?.invalidate() }
        }
    }
}

/// `Braincell --demo` acts out a script, rare moments included, so you can see the twins without a
/// friend. It runs with "Disappear when idle" unticked, to show what a twin does on its own as well.
@MainActor func demo() {
    let item = MenuBarItem(extras: [])
    func m(_ doing: Doing, _ label: String? = nil, ticked: Int = 0, mood: Mood = .fine) -> Mind {
        Mind(busy: true, doing: doing, label: label, ticked: ticked, mood: mood)
    }
    var script: [(at: Double, me: Mind, friend: Mind)] = [
        (0.5, m(.think), m(.think)),
        (5, m(.write, "adding custom widgets"), m(.read, "tracing the login bug")),
        (10, m(.run, "running the tests"), Mind()),
        (15, m(.run, "running the tests"), m(.think)),
        (19, m(.write, "fixing the layout"), m(.write, "patching the login")),
        (24, m(.plan, "polishing the menu", ticked: 1), m(.team, "reviewing with agents")),
        (29, m(.tidy, ticked: 1), m(.write, "patching the login", ticked: 1)),
        (33, m(.wait, ticked: 1), m(.write, "patching the login", ticked: 1)),
        (38, m(.think, ticked: 1), m(.web, "reading the docs", ticked: 1)),
        (42, m(.think, ticked: 1), m(.web, "reading the docs", ticked: 1, mood: .fresh)),
        (48, Mind(), m(.think, ticked: 1, mood: .weary)),
        (53, Mind(mood: .spent), m(.think, ticked: 1, mood: .weary)),
        (58, m(.think), Mind(mood: .weary)),            // from here my friend is away, and my twin stays out on its own
        (84, Mind(), Mind(mood: .weary)),
        (89, Mind(), m(.read, "tracing the login bug")),
        (96, m(.think), m(.read, "tracing the login bug")),
    ]
    var ends = script.last!.at + 8
    if CommandLine.arguments.contains("--squabble") {       // not in the demo: it's meant to be a surprise
        script = [(0.5, m(.think), m(.think))]
        ends = 300
        var began = false
        after(6) {
            after(0.5, repeats: true) { if !began { began = item.squabble() } else if !item.squabbling { after(3) { exit(0) } } }
        }
    } else {
        item.showOff()
    }
    var quiet: [Date?] = [.distantPast, .distantPast]       // when each of us last stopped
    for act in script {
        after(act.at) {
            for (who, mind) in [act.me, act.friend].enumerated() { quiet[who] = mind.busy ? nil : quiet[who] ?? Date() }
            item.update(me: act.me, friend: act.friend, stopped: quiet)
        }
    }
    after(ends) { exit(0) }
}

// MARK: - Relay (one ntfy topic shared by the two of us)

struct Config: Decodable { let server: String, room: String, id: String }

@MainActor final class Relay {
    private let topic: URL, key: SymmetricKey, me: String
    private let onFriend: (_ id: String, _ mind: Mind, _ sent: Date, _ squabble: Bool) -> Void
    private let session: URLSession
    private var stream: Task<Void, Never>?
    private var posting: URLSessionDataTask?
    private var lastMessage: String?
    private var skew: TimeInterval = 0      // this Mac's clock minus the relay's, so a wrong clock can't expire a friend early

    init(_ config: Config, onFriend: @escaping (String, Mind, Date, Bool) -> Void) {
        // The pairing code never leaves this Mac. The topic's name and the key that seals every
        // message are both derived from it, so the relay sees neither the code nor anything readable.
        let code = SymmetricKey(data: Data(config.room.utf8))
        func derive(_ purpose: String, bytes: Int) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: code, info: Data(purpose.utf8), outputByteCount: bytes)
        }
        key = derive("braincell key", bytes: 32)
        let name = derive("braincell topic", bytes: 16).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        topic = URL(string: config.server)!.appendingPathComponent("braincell-" + name)
        me = config.id
        self.onFriend = onFriend
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true      // offline: wait quietly instead of retrying
        session = URLSession(configuration: c)
    }

    /// Everything that ever leaves this Mac: this one line, sealed so only the two of us can read it.
    func send(_ mind: Mind, squabble: Bool = false, then done: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        var line: [String: Any] = ["id": me, "busy": mind.busy]
        if mind.busy { line["doing"] = mind.doing.rawValue; line["ticked"] = mind.ticked }
        if mind.busy, let label = mind.label { line["label"] = label }
        if mind.mood != .fine { line["mood"] = mind.mood.rawValue }
        if squabble { line["squabble"] = true }     // my twins have just fallen out: yours should too
        guard let plain = try? JSONSerialization.data(withJSONObject: line),
              let sealed = try? ChaChaPoly.seal(plain, using: key).combined else { return }
        var r = URLRequest(url: topic)
        r.httpMethod = "POST"
        r.httpBody = Data(sealed.base64EncodedString().utf8)
        r.timeoutInterval = 20
        let what = "busy=\(mind.busy) \(mind.doing.rawValue) \(mind.label ?? "-") ticked=\(mind.ticked) \(mind.mood.rawValue)"
        posting?.cancel()       // only the newest state matters
        posting = session.dataTask(with: r) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("sent \(what): \(status) \(error?.localizedDescription ?? "")")
            if (error as? URLError)?.code == .cancelled { return }
            Task { @MainActor in done(status == 200) }
        }
        posting?.resume()
    }

    /// (Re)opens the one long-lived stream. Recent messages are replayed first.
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
                    log("listening on \(self.topic.lastPathComponent)")
                    for try await line in lines.lines {
                        wait = 2
                        self.receive(line)
                    }
                } catch {
                    log("stream ended: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                wait = min(wait * 2, 300)
            }
        }
    }

    private func receive(_ line: String) {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let time = outer["time"] as? Double
        guard outer["event"] as? String == "message", let sealed = outer["message"] as? String else {
            if let time { skew = Date().timeIntervalSince1970 - time }      // "open" and "keepalive" lines carry the relay's time
            return
        }
        lastMessage = outer["id"] as? String ?? lastMessage
        guard let box = Data(base64Encoded: sealed).flatMap({ try? ChaChaPoly.SealedBox(combined: $0) }),
              let plain = try? ChaChaPoly.open(box, using: key),      // only someone with our pairing code could have sealed it
              let inner = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let id = inner["id"] as? String, id != me, let busy = inner["busy"] as? Bool else { return }
        // A friend's words are shown as plain text, but keep them short and printable all the same.
        let label = (inner["label"] as? String).map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40))) }
        let mind = Mind(busy: busy, doing: Doing(rawValue: inner["doing"] as? String ?? "") ?? .think,
                        label: label?.isEmpty == false ? label : nil, ticked: inner["ticked"] as? Int ?? 0,
                        mood: Mood(rawValue: inner["mood"] as? String ?? "") ?? .fine)
        let sent = time.map { Date(timeIntervalSince1970: $0 + skew) } ?? Date()
        onFriend(id, mind, min(sent, Date()), inner["squabble"] as? Bool == true)
    }
}

// MARK: - App

@MainActor final class App: NSObject, NSApplicationDelegate {
    private var item: MenuBarItem!
    private var relay: Relay?
    private var watcher: DispatchSourceFileSystemObject?
    private var sessions: [String: Session] = [:]                   // my Claude Code sessions, by id
    private var friends: [String: (until: Date, since: Date, mind: Mind)] = [:]   // what each friend last said, when, and how long it holds
    private var met: [String: Date] = [:]                           // when each was first heard from
    private var crowdedAt: Date?                                    // when two of them last proved to be different Macs, both in use
    private let pairedFlag = home.appendingPathComponent("paired")  // exists once a friend has ever been heard from
    private var latest = Mind()                                     // what I was last doing
    private var told = Mind()                                       // what my friend currently believes about me
    private var lastSent = Date.distantPast
    private var retryAt: Date?, backoff: TimeInterval = 15          // the last message didn't get through
    private var idleSince: Date?
    private var worked: TimeInterval = 0, workingSince: Date?, workDay = Date()    // how long my Claude has worked today
    private var budget = 0, budgetFrom = Date.distantPast           // today's allowance of "what I'm doing" updates
    private var wake: Timer?
    private var settling = false
    // Each setting is a tick in the menu, remembered as a flag file that exists while it's off.
    private let placement = NSMenuItem(title: "Sit on the bottom edge", action: #selector(togglePlacement), keyEquivalent: "")
    private let sharing = NSMenuItem(title: "Share what I'm working on", action: #selector(toggleSharing), keyEquivalent: "")
    private let shyness = NSMenuItem(title: "Disappear when idle", action: #selector(toggleShyness), keyEquivalent: "")
    private let centeredFlag = home.appendingPathComponent("centered"), privateFlag = home.appendingPathComponent("private")
    private let stayFlag = home.appendingPathComponent("stay")

    func applicationDidFinishLaunching(_ note: Notification) {
        let remove = NSMenuItem(title: "Remove Braincell…", action: #selector(remove), keyEquivalent: "")
        remove.target = self
        for (entry, flag) in [(placement, centeredFlag), (sharing, privateFlag), (shyness, stayFlag)] {
            entry.target = self
            entry.state = FileManager.default.fileExists(atPath: flag.path) ? .off : .on
        }
        item = MenuBarItem(extras: [placement, sharing, shyness, remove])
        item.setCentered(placement.state == .off, animated: false)
        item.shy = shyness.state == .on

        guard let data = try? Data(contentsOf: home.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(Config.self, from: data), URL(string: config.server) != nil else {
            log("no usable config.json in \(home.path); run install.sh")
            exit(0)
        }
        relay = Relay(config) { [weak self] id, mind, sent, squabble in
            guard let self else { return }
            // Braincell pairs two Macs. A new Mac on the code is fine if the old one has gone quiet for
            // good (a reinstall); one that keeps talking after the new one arrives is a third.
            if self.met[id] == nil { self.met[id] = sent }
            if self.friends.contains(where: { $0.key != id && $0.value.since > self.met[id]! }) { self.crowdedAt = Date(); log("crowded: \(self.friends.count + 1) other Macs") }
            self.friends[id] = (mind.busy ? sent.addingTimeInterval(friendLease) : .distantPast, sent, mind)
            log("friend \(id): busy=\(mind.busy) \(mind.doing.rawValue) \(mind.label ?? "-") ticked=\(mind.ticked) \(mind.mood.rawValue)")
            if !self.item.paired { self.item.paired = true; FileManager.default.createFile(atPath: self.pairedFlag.path, contents: nil) }
            if squabble, Date().timeIntervalSince(sent) < 30 { self.item.squabbleToo() }       // (not one replayed from earlier)
            self.settle()
        }
        item.paired = FileManager.default.fileExists(atPath: pairedFlag.path)
        item.onSquabble = { [weak self] in
            if let self { self.relay?.send(self.told, squabble: true) { [weak self] ok in self?.delivered(ok) } }
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

    /// The whole state machine: who is doing what, what to tell the friend, how to pose the twins,
    /// and when to look again.
    private func evaluate() {
        let now = Date()
        var next: Date?
        func consider(_ d: Date) { if next == nil || d < next! { next = d } }

        // Me: the session that did something most recently, if any is mid-turn.
        var me = Mind()
        if let newest = liveSessions(now).max(by: { $0.touched < $1.touched }) {
            me = sessions[newest.id]?.mind ?? Mind(busy: true)
            consider(newest.touched.addingTimeInterval(staleAfter))
        }

        // My mood: out of usage, on a Claude model I haven't used before, or worn out by a long day.
        // The hook leaves a flag file for the first two.
        if !Calendar.current.isDate(now, inSameDayAs: workDay) { workDay = now; worked = 0; workingSince = workingSince.map { _ in now } }
        if me.busy { workingSince = workingSince ?? now } else if let since = workingSince { worked += now.timeIntervalSince(since); workingSince = nil }
        let today = worked + (workingSince.map { now.timeIntervalSince($0) } ?? 0)
        func flagged(_ name: String, hours: Double) -> Bool {
            let made = (try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(name).path))?[.modificationDate] as? Date
            guard let ends = made?.addingTimeInterval(hours * 3600), ends > now else { return false }
            consider(ends)
            return true
        }
        me.mood = flagged("spent", hours: 5) ? .spent : flagged("fresh", hours: 12) ? .fresh : today >= longDay ? .weary : .fine
        if me.busy {
            latest = me
            if today < longDay { consider(now.addingTimeInterval(longDay - today)) }
        }

        // My friend hears "busy" at once, "idle" after the grace period, and what I'm doing now and then.
        if me.busy { idleSince = nil } else if idleSince == nil { idleSince = now }
        let say = me.busy || (told.busy && now.timeIntervalSince(idleSince!) < idleGrace)
        if !me.busy && say { consider(idleSince!.addingTimeInterval(idleGrace)) }
        var news = say ? latest : Mind()
        news.mood = me.mood
        if sharing.state == .off { news.label = nil }
        let flipped = news.busy != told.busy || lastSent == .distantPast || (!say && news.mood != told.mood)
        let overdue = say && now.timeIntervalSince(lastSent) >= reannounce
        let retry = retryAt.map { now >= $0 } ?? false
        var detail = false
        if say && !flipped && !overdue && !retry && news != told {
            if now.timeIntervalSince(budgetFrom) >= 86400 { budgetFrom = now; budget = detailBudget }
            let ready = lastSent.addingTimeInterval(detailEvery)
            if budget > 0 { if now >= ready { detail = true; budget -= 1 } else { consider(ready) } }
        }
        if flipped || overdue || retry || detail {
            told = news; lastSent = now; retryAt = nil
            relay?.send(news) { [weak self] ok in self?.delivered(ok) }
        }
        if say { consider(lastSent.addingTimeInterval(reannounce)) }
        if let retryAt { consider(retryAt) }

        // My friend: busy until their lease runs out.
        let live = friends.values.filter { $0.until > now }
        live.forEach { consider($0.until) }
        let last = friends.values.max { $0.since < $1.since }?.mind
        let friend = live.max { $0.until < $1.until }?.mind ?? Mind(mood: last?.mood ?? .fine)
        // When they went quiet: their last "idle", or the moment a lapsed "busy" ran out.
        let friendStopped = friends.values.map { $0.mind.busy ? $0.until : $0.since }.max() ?? .distantPast

        log("me: \(me.words) [\(me.doing.rawValue) \(me.mood.rawValue)]  friend: \(friend.words) [\(friend.doing.rawValue) \(friend.mood.rawValue)]  say=\(say)")
        let crowdedUntil = crowdedAt?.addingTimeInterval(86400)                 // the menu says so for a day
        item.crowded = crowdedUntil.map { $0 > now } ?? false
        if item.crowded { consider(crowdedUntil!) }
        item.update(me: me, friend: friend, stopped: [me.busy ? nil : idleSince, friend.busy ? nil : friendStopped])

        wake?.invalidate()
        wake = next.map { after(max(1, $0.timeIntervalSince(now) + 0.2)) { [weak self] in self?.evaluate() } }
    }

    /// A message that didn't get through goes again later, after a pause that grows each time.
    private func delivered(_ ok: Bool) {
        backoff = ok ? 15 : min(backoff * 2, 900)
        if !ok { retryAt = Date().addingTimeInterval(backoff); settle() }
    }

    /// Reads what's new in each live session's log, and deletes stale ones.
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

    private func flip(_ entry: NSMenuItem, _ flag: URL) -> Bool {
        let on = entry.state != .on
        entry.state = on ? .on : .off
        if on { try? FileManager.default.removeItem(at: flag) } else { FileManager.default.createFile(atPath: flag.path, contents: nil) }
        return on
    }

    /// Unticked, the twins float level with the other menu bar icons instead of sitting on the bar's bottom edge.
    @objc private func togglePlacement() { item.setCentered(!flip(placement, centeredFlag), animated: true) }

    /// Unticked, my friend sees the kind of work I'm doing but not the few words about it.
    @objc private func toggleSharing() {
        _ = flip(sharing, privateFlag)
        lastSent = .distantPast
        evaluate()
    }

    /// Unticked, my twin stays out all the time: asleep whenever I'm not working, with my friend's beside it whenever they are.
    @objc private func toggleShyness() { item.shy = flip(shyness, stayFlag) }

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
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // no Dock icon, no windows
    let delegate = App()
    if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--squabble") { demo() } else { app.delegate = delegate }
    withExtendedLifetime(delegate) { app.run() }
}
