import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Bloom", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let model = MobileConnection()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.tintColor = BloomTheme.accent
        window.rootViewController = BloomSplitController(model: model)
        self.window = window
        window.makeKeyAndVisible()
        #if DEBUG
        if !IOSLiveSession.install(in: window, model: model) { IOSPreviewFixture.install(in: window) }
        #endif
    }

    func sceneDidDisconnect(_ scene: UIScene) { model.suspend() }
    func sceneDidEnterBackground(_ scene: UIScene) { model.suspend() }
    func sceneDidBecomeActive(_ scene: UIScene) { model.resume() }
}
