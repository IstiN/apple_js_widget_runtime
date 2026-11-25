#if canImport(UIKit) && os(iOS)
import UIKit
import JSRCore
import JSRUIKit

// JSRUIDemo (issue #2): single-screen host with a fixture picker
// (hello / counter / scroll_list). The window hosts the UIKitMapper and the
// live-view dump; Tests/JSRUIKitTests run inside this application so the
// conformance runner produces ios results for the harness.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = DemoViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class DemoViewController: UIViewController {
    private var host: JSRUIKitDemoHost?
    private let picker = UISegmentedControl(items: jsrUIKitDemoSeeds)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        picker.selectedSegmentIndex = 0
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.addTarget(self, action: #selector(loadSelected(_:)), for: .valueChanged)
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        load(seed: jsrUIKitDemoSeeds[0])
    }

    @objc private func loadSelected(_ sender: UISegmentedControl) {
        load(seed: jsrUIKitDemoSeeds[sender.selectedSegmentIndex])
    }

    private func load(seed: String) {
        // widget.js lives in the application bundle next to the sources
        guard let fixtureRoot = Bundle.main.resourceURL?.appendingPathComponent("Fixtures"),
              let widget = try? String(contentsOf: fixtureRoot.appendingPathComponent(seed).appendingPathComponent("widget.js"), encoding: .utf8) else {
            title = "missing fixture \(seed)"
            return
        }
        let container = UIView(frame: view.bounds)
        let host = JSRUIKitDemoHost(container: container)
        view.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.load(widget: widget, name: seed)
        self.host = host
        title = host.windowTitle
    }
}
#endif
