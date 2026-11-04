import Foundation

/// Publishes to ntfy.sh: a POST with a text/plain body and the options as
/// query params (Ntfy.publishURL), as in the web app.
enum NtfyPublisher {
    struct HTTPError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "HTTP \(status) \(body)" }
    }

    struct BadTopic: LocalizedError {
        var errorDescription: String? { "the topic can't go in a URL" }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Ntfy.publishTimeout
        c.timeoutIntervalForResource = Ntfy.publishTimeout
        return URLSession(configuration: c)
    }()

    /// Returns ntfy's message id once it accepted the message.
    static func publish(topic: String, title: String, priority: Int, tags: String, body: String) async throws -> String? {
        guard let url = Ntfy.publishURL(topic: topic, title: title, priority: priority, tags: tags) else { throw BadTopic() }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }
}

/// Follows the control topic's JSON stream (one JSON object per line). Every
/// (re)connect asks for what was sent since the last message handled, so a
/// command sent while the app was down or offline still arrives. Drops
/// reconnect after 5 s, doubling to 60 s while they keep failing.
final class ControlStream: NSObject, URLSessionDataDelegate {
    enum Event {
        case connecting
        case open
        case keepalive
        case message(ControlMessage)
        case dropped(String, retryIn: TimeInterval)
    }

    static let firstRetry: TimeInterval = 5
    static let maxRetry: TimeInterval = 60
    /// ntfy sends a keepalive every 45 s, so this long without data means a dead connection.
    static let idleTimeout: TimeInterval = 120

    /// Called on the stream's own queue.
    var onEvent: ((Event) -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "spotwatch.control"
        return q
    }()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = ControlStream.idleTimeout
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    // Stream queue only.
    private var topic: String?
    private var lastId: String?             // the last message handled, for `since=`
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var retry = ControlStream.firstRetry
    private var retryWork: DispatchWorkItem?

    /// Connects to `topic` from just after `lastId`, or stops when the topic is nil.
    func connect(topic: String?, lastId: String?) {
        queue.addOperation {
            self.topic = topic
            self.lastId = lastId
            self.retry = ControlStream.firstRetry
            self.open()
        }
    }

    private func open() {
        retryWork?.cancel()
        task?.cancel()
        task = nil
        buffer = Data()
        guard let topic = topic, let url = Ntfy.streamURL(topic: topic, since: lastId) else { return }
        onEvent?(.connecting)
        let t = session.dataTask(with: url)
        task = t
        t.resume()
    }

    private func scheduleRetry(_ why: String) {
        let wait = retry
        retry = min(retry * 2, ControlStream.maxRetry)
        onEvent?(.dropped(why, retryIn: wait))
        let work = DispatchWorkItem { [weak self] in
            self?.queue.addOperation { self?.open() }
        }
        retryWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: work)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else { return completionHandler(.cancel) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            task = nil
            scheduleRetry("HTTP \(status)")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let m = ControlMessage.parse(Substring(line)) else { continue }
            retry = ControlStream.firstRetry
            switch m.event {
            case "open": onEvent?(.open)
            case "keepalive": onEvent?(.keepalive)
            case "message":
                if let id = m.id { lastId = id }
                onEvent?(.message(m))
            default: break
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        scheduleRetry(error?.localizedDescription ?? "the server closed the stream")
    }
}
