import Foundation

// Host services behind small interfaces (plan, Wave C rules): in-memory
// defaults for tests and the host conformance loop; Apple-backed
// implementations (UserDefaults, Keychain, URLSession, Process) for real hosts.

/// Host policy knobs. `exec` is off unless the embedding app turns it on.
public struct JSRConfiguration {
    public var allowsExec: Bool
    public init(allowsExec: Bool = false) {
        self.allowsExec = allowsExec
    }
}

public struct FetchRequest {
    public let url: String
    public let method: String
    public let headers: [String: Any]
    public init(url: String, method: String, headers: [String: Any]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

// MARK: - Service interfaces

public protocol StorageService: AnyObject {
    func get(_ key: String) -> Any?
    func set(_ key: String, _ value: Any?)
}

public protocol SecretsService: AnyObject {
    func get(_ key: String) -> Any?
    /// Returns the host ok boolean (PROTOCOL __jsr_secrets_set).
    func set(_ key: String, _ value: Any?) -> Bool
}

public protocol HttpService: AnyObject {
    func fetch(_ request: FetchRequest, completion: @escaping (Any) -> Void)
}

public protocol AssetService: AnyObject {
    /// Reads the asset at `path`; nil resolves null (loadAsset never rejects).
    func load(_ path: String) -> Any?
}

public protocol ProcessService: AnyObject {
    func run(_ command: String, completion: @escaping (Any) -> Void)
}

public protocol HostCallService: AnyObject {
    func call(name: String, args: [String: Any], completion: @escaping (Any) -> Void)
}

public protocol OpenUrlService: AnyObject {
    func open(_ url: String, completion: @escaping (Any) -> Void)
}

// MARK: - In-memory defaults (tests + host conformance loop use these)

public final class InMemoryStorage: StorageService {
    private var map: [String: Any] = [:]
    public init() {}
    public func get(_ key: String) -> Any? { map[key] }
    public func set(_ key: String, _ value: Any?) {
        if let value { map[key] = value } else { map.removeValue(forKey: key) }
    }
}

public final class InMemorySecrets: SecretsService {
    private var map: [String: Any] = [:]
    public init() {}
    public func get(_ key: String) -> Any? { map[key] }
    public func set(_ key: String, _ value: Any?) -> Bool {
        if let value { map[key] = value } else { map.removeValue(forKey: key) }
        return true
    }
}

/// Serves the fixture's `meta.json` mock map with the harness mockLookup
/// semantics: status >= 400 resolves {"__error": "HTTP <status>"}, else body.
public final class MockHttp: HttpService {
    private let mock: [String: Any]
    public init(mock: [String: Any]) {
        self.mock = mock
    }

    public func fetch(_ request: FetchRequest, completion: @escaping (Any) -> Void) {
        completion(MockHttp.lookup(mock, url: request.url))
    }

    public static func lookup(_ mock: [String: Any], url: String) -> Any {
        guard let components = URLComponents(string: url), let path = components.path.isEmpty ? nil : components.path else {
            return ["__error": "invalid url: \(url)"]
        }
        guard let entry = mock[path] as? [String: Any] else {
            return ["__error": "no mock for \(path)"]
        }
        if let status = entry["status"] as? NSNumber, status.int32Value >= 400 {
            return ["__error": "HTTP \(status)"]
        }
        return entry["body"] ?? [String: Any]()
    }
}

public final class FileAssetLoader: AssetService {
    private let rootPath: String
    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    public func load(_ path: String) -> Any? {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let full = root.appendingPathComponent(path).standardizedFileURL
        guard full.path.hasPrefix(root.path) else { return nil } // stays inside the root
        guard let data = try? Data(contentsOf: full) else { return nil }
        return JSON.parse(String(data: data, encoding: .utf8) ?? "") ?? String(decoding: data, as: UTF8.self)
    }
}

/// Resolves the named unsupported-host error (PROTOCOL.md section 5).
public final class UnsupportedHostCallService: HostCallService {
    public init() {}
    public func call(name: String, args: [String: Any], completion: @escaping (Any) -> Void) {
        completion(["__error": "hostCall is not supported by this host"])
    }
}

public final class UnsupportedOpenUrlService: OpenUrlService {
    public init() {}
    public func open(_ url: String, completion: @escaping (Any) -> Void) {
        completion(["__error": "openUrl is not supported by this host"])
    }
}

// MARK: - Apple-backed implementations

public final class UserDefaultsStorage: StorageService {
    private let defaults: UserDefaults
    public init(suiteName: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? defaults
    }

    public func get(_ key: String) -> Any? { defaults.object(forKey: key) }
    public func set(_ key: String, _ value: Any?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Keychain generic-password storage; values are JSON-encoded strings.
public final class KeychainSecrets: SecretsService {
    private let service: String
    public init(service: String) {
        self.service = service
    }

    public func get(_ key: String) -> Any? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return JSON.parse(String(decoding: data, as: UTF8.self))
    }

    public func set(_ key: String, _ value: Any?) -> Bool {
        guard let value else { return delete(key: key) }
        return upsert(key: key, data: Data(JSON.stringify(value).utf8))
    }

    /// Update first; add when the item does not exist yet.
    private func upsert(key: String, data: Data) -> Bool {
        var update = [String: Any]()
        update[kSecValueData as String] = data
        let status = SecItemUpdate(baseQuery(key: key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            return add(key: key, data: data)
        }
        return status == errSecSuccess
    }

    private func add(key: String, data: Data) -> Bool {
        var query = baseQuery(key: key)
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func delete(key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// URLSession-backed fetch; response shaping mirrors the harness contract.
public final class URLSessionHttp: HttpService {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ request: FetchRequest, completion: @escaping (Any) -> Void) {
        guard let url = URL(string: request.url) else {
            completion(["__error": "invalid url: \(request.url)"])
            return
        }
        let task = session.dataTask(with: urlRequest(request, url: url)) { data, response, _ in
            completion(URLSessionHttp.shape(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data))
        }
        task.resume()
    }

    private func urlRequest(_ request: FetchRequest, url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.uppercased()
        for (key, value) in request.headers {
            if let string = value as? String { urlRequest.setValue(string, forHTTPHeaderField: key) }
        }
        return urlRequest
    }

    /// status >= 400 → {"__error": "HTTP <status>"}; else parsed JSON body or {}.
    static func shape(status: Int, data: Data?) -> Any {
        if status >= 400 {
            return ["__error": "HTTP \(status)"]
        }
        if let data, let value = JSON.parse(String(decoding: data, as: UTF8.self)) {
            return value
        }
        return [String: Any]()
    }
}

/// `Process`-backed exec; the handler only wires this when
/// `JSRConfiguration.allowsExec` is true. `Process` does not exist on iOS,
/// where exec resolves the named host error instead.
public final class ProcessRunnerService: ProcessService {
    public init() {}

    public func run(_ command: String, completion: @escaping (Any) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
#if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                completion(["exitCode": process.terminationStatus, "stdout": String(decoding: data, as: UTF8.self)])
            } catch {
                completion(["__error": "exec failed: \(error.localizedDescription)"])
            }
#else
            completion(["__error": "exec is not supported by this host"])
#endif
        }
    }
}

// MARK: - Default bundle

public struct HostServices {
    public var storage: StorageService
    public var secrets: SecretsService
    public var http: HttpService
    public var assets: AssetService
    public var processRunner: ProcessService
    public var hostCall: HostCallService
    public var openUrl: OpenUrlService

    public init(
        storage: StorageService = InMemoryStorage(),
        secrets: SecretsService = InMemorySecrets(),
        http: HttpService = MockHttp(mock: [:]),
        assets: AssetService = FileAssetLoader(rootPath: "."),
        processRunner: ProcessService = ProcessRunnerService(),
        hostCall: HostCallService = UnsupportedHostCallService(),
        openUrl: OpenUrlService = UnsupportedOpenUrlService()
    ) {
        self.storage = storage
        self.secrets = secrets
        self.http = http
        self.assets = assets
        self.processRunner = processRunner
        self.hostCall = hostCall
        self.openUrl = openUrl
    }
}
