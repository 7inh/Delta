import UIKit
import Combine
import DeltaCore
import NESDeltaCore
import CoreData

// Minimal stand-ins for app-target types so the real MultiplayerSession compiles standalone.
struct Cheat { var isEnabled: Bool }
final class Game: NSObject, NSFetchRequestResult
{
    var type: GameType? = .nes
    var fileURL: URL = URL(fileURLWithPath: "/dev/null")
    var cheats: [Cheat] = []
    static func fetchRequest() -> NSFetchRequest<Game> { NSFetchRequest<Game>(entityName: "Game") }
}
final class StubContext
{
    var games: [Game] = []
    func fetch<T: NSFetchRequestResult>(_ request: NSFetchRequest<T>) throws -> [T] { games as! [T] }
}
final class DatabaseManager { static let shared = DatabaseManager(); let viewContext = StubContext() }
enum Settings { static var localControllerPlayerIndex: Int? }

// Drives the REAL guest session stack: browse, join, digest negotiation, replica, playback.
final class GuestDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    private var session: MultiplayerSession?
    private var subscription: AnyCancellable?
    private var poll: Timer?
    private var images = 0
    private var phases = Set<String>()
    private var joined = false
    private var finished = false
    private var wrongAttempted = false
    private var retried = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        DispatchQueue.main.async { self.run() }
        return true
    }

    private func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func finish(_ message: String, success: Bool)
    {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        session?.end()
        session?.player.onImage = nil
        print(message)
        fflush(stdout)
        try? message.write(to: documents().appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        exit(success ? 0 : 1)
    }

    private func run()
    {
        Delta.register(NES.core)
        let arguments = CommandLine.arguments
        let code = arguments.indices.first { arguments[$0] == "-code" }
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "492013"
        let romURL = documents().appendingPathComponent("guest.nes")
        do { try TestROM.make().write(to: romURL) }
        catch { finish("GUEST_FAIL rom: \(error)", success: false); return }
        let game = Game()
        game.fileURL = romURL
        DatabaseManager.shared.viewContext.games = [game]

        let session = MultiplayerSession()
        self.session = session
        session.player.onImage = { [weak self] _ in self?.images += 1 }
        subscription = session.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            print("GUEST \(Date().formatted(.dateTime.hour().minute().second())) phase=\(state.phase.rawValue)")
            fflush(stdout)
            self.phases.insert(state.phase.rawValue)
            if state.phase == .disconnected
            {
                if self.wrongAttempted, !self.retried
                {
                    // Try Again: a wrong code must not wedge the join screen.
                    self.retried = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.browse() }
                }
                else if self.retried, !self.phases.contains("playing")
                {
                    self.finish("GUEST_FAIL disconnected: \(session.errorMessage ?? "?") phases=\(self.phases.sorted()) images=\(self.images)", success: false)
                }
            }
        }
        session.browse()
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, !self.joined, let game = self.session?.games.first,
                  self.session?.state.phase == .browsing else { return }
            if self.wrongAttempted
            {
                self.joined = true
                self.poll?.invalidate()
                session.join(game, code: code)
            }
            else
            {
                // First attempt with a wrong code; the sink browses again after the failure.
                self.wrongAttempted = true
                session.join(game, code: "000000")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { self.evaluate() }
    }

    private func evaluate()
    {
        guard let session else { return }
        let local = session.usesLocalROM
        let audio = session.player.scheduledAudioBuffers
        let paired = MultiplayerPairing.rememberedHosts().contains { $0.name == "Integration Host" }
        let detail = "local=\(local) phases=\(phases.sorted()) images=\(images) audio=\(audio) paired=\(paired) joined=\(joined) retried=\(retried)"
        // The host quits at its own deadline; reaching playing/paused once is the pass condition.
        let success = local && joined && retried && phases.contains("playing") && phases.contains("paused") && images >= 5 && audio >= 50 && paired
        finish(success ? "GUEST_PASS \(detail)" : "GUEST_FAIL \(detail) error=\(session.errorMessage ?? "none")", success: success)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(GuestDelegate.self))
