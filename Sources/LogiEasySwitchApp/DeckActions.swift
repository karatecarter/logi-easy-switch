import Foundation
import CoreAudio
import AudioToolbox
import Darwin

struct BuiltinDeckProvider: DeckActionProvider {
    let kinds = ["group", "homeassistant", "shortcuts", "applescript", "python", "microphone", "camera", "volumeUp", "volumeDown", "volumeMute"]

    func execute(_ button: DeckButton, configuration: DeckConfiguration) async throws {
        let value = button.settings
        switch button.kind {
        case "homeassistant":
            guard value["requiresThermostat"] != "true" else { throw DeckError.message("Choose a thermostat entity in the parent button’s settings before setting its mode.") }
            let action = (value["action"] ?? "").split(separator: ".")
            guard action.count == 2, action.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) else { throw DeckError.message("Enter a Home Assistant action such as light.toggle.") }
            let body = try DeckHomeAssistantClient.actionData(value["data"] ?? "{}")
            _ = try await request(configuration, path: "services/\(action[0])/\(action[1])", body: body, returnResponse: value["returnResponse"] == "true")
        case "shortcuts": _ = try await process("/usr/bin/shortcuts", ["run", value["name"] ?? ""])
        case "applescript", "camera":
            guard let script = value["script"], !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeckError.message("Configure an AppleScript command for this button first.") }
            _ = try await process("/usr/bin/osascript", ["-e", script])
        case "python":
            let interpreter = value["interpreter"] ?? "/usr/bin/python3"
            guard interpreter.hasPrefix("/"), let path = value["path"], path.hasPrefix("/") else { throw DeckError.message("Use absolute paths for the Python interpreter and script.") }
            _ = try await process(interpreter, [path])
        case "microphone": try AudioControl.toggleMute(input: true)
        case "volumeMute": try AudioControl.toggleMute(input: false)
        case "volumeUp", "volumeDown": try AudioControl.adjustVolume(button.kind == "volumeUp" ? 0.0625 : -0.0625)
        default: throw DeckError.message("Unsupported action provider: \(button.kind)")
        }
    }

    func presentation(_ button: DeckButton, configuration: DeckConfiguration) async throws -> DeckPresentation {
        switch button.kind {
        case "homeassistant", "group":
            var result = DeckPresentation()
            if DeckHATarget.automaticLight(button) {
                let entities = DeckHATarget.entities(button)
                if !entities.isEmpty {
                    var states: [String] = []
                    for entity in entities {
                        guard entity.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { continue }
                        let request = try DeckHomeAssistantClient.makeRequest(configuration, token: DeckTokenStore.load(), path: "states/" + entity)
                        let data = try await DeckHomeAssistantClient.send(request)
                        states.append(try JSONDecoder().decode(DeckHAEntity.self, from: data).state)
                    }
                    result = DeckHATarget.lightPresentation(states: states)
                } else { result = DeckPresentation(text: "Choose a light entity", icon: "lightbulb") }
            }
            if let template = button.settings["textTemplate"], !template.isEmpty { result.text = try await render(template, configuration) }
            if let template = button.settings["iconTemplate"], !template.isEmpty { result.icon = try await render(template, configuration).trimmingCharacters(in: .whitespacesAndNewlines) }
            return result
        case "microphone", "volumeMute", "volumeUp", "volumeDown":
            let input = button.kind == "microphone"
            let muted = try AudioControl.muted(input: input)
            let volume = try? AudioControl.volume()
            return DeckPresentation(text: input ? (muted ? "Muted" : "Live") : (muted ? "Muted" : "\(Int((volume ?? 0) * 100))%"), icon: input ? (muted ? "mic.slash.fill" : "mic.fill") : (muted ? "speaker.slash.fill" : ((volume ?? 0) < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")))
        case "camera":
            guard let script = button.settings["stateScript"], !script.isEmpty else { return DeckPresentation(text: "App-specific", icon: "video") }
            let state = try await process("/usr/bin/osascript", ["-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
            return DeckPresentation(text: state, icon: state == "on" ? "video.fill" : "video.slash.fill")
        default: return DeckPresentation()
        }
    }

    private func render(_ template: String, _ configuration: DeckConfiguration) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["template": template])
        return String(decoding: try await request(configuration, path: "template", body: body), as: UTF8.self)
    }

    private func request(_ configuration: DeckConfiguration, path: String, body: Data, returnResponse: Bool = false) async throws -> Data {
        let request = try DeckHomeAssistantClient.makeRequest(configuration, token: DeckTokenStore.load(), path: path, body: body, returnResponse: returnResponse)
        return try await DeckHomeAssistantClient.send(request)
    }
}

enum DeckHomeAssistantClient {
    static func actionData(_ source: String) throws -> Data {
        let data = Data(source.utf8)
        do {
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                throw DeckError.message("Service data must be a JSON object, for example: {\"entity_id\":\"light.office_lights\"}")
            }
            return data
        } catch let error as DeckError { throw error }
        catch {
            if source.contains("“") || source.contains("”") {
                throw DeckError.message("Invalid service data JSON: use straight double quotes (\") instead of curly quotes (“ ”). For example: {\"entity_id\":\"light.office_lights\"}")
            }
            throw DeckError.message("Invalid service data JSON. Use double-quoted keys and values, and check commas and braces. For example: {\"entity_id\":\"light.office_lights\"}")
        }
    }

    static func makeRequest(_ configuration: DeckConfiguration, token: String, path: String = "", body: Data? = nil, returnResponse: Bool = false) throws -> URLRequest {
        let address = configuration.homeAssistantURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: address), ["https", "http"].contains(base.scheme), base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw DeckError.message("Enter a Home Assistant HTTP or HTTPS base URL.") }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeckError.message("Enter a Home Assistant access token.") }
        var components = URLComponents(url: base.appendingPathComponent("api/" + path), resolvingAgainstBaseURL: false)!
        if returnResponse { components.queryItems = [URLQueryItem(name: "return_response", value: nil)] }
        guard let url = components.url else { throw DeckError.message("Invalid Home Assistant URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func testConnection(_ configuration: DeckConfiguration, token: String, transport: (URLRequest) async throws -> Data = send) async throws {
        let request = try makeRequest(configuration, token: token)
        let data = try await transport(request)
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["message"] as? String == "API running." else {
            throw DeckError.message("The server responded, but it did not return the Home Assistant API status. Check the base URL.")
        }
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DeckError.message("Home Assistant returned an invalid response.") }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw DeckError.message("Home Assistant rejected the access token (HTTP \(http.statusCode)). Check the token and user permissions.")
        case 300..<400: throw DeckError.message("Home Assistant redirected the request. Enter the final base URL; redirects are not followed.")
        default: throw DeckError.message("Home Assistant request failed (HTTP \(http.statusCode)). Check the base URL and server.")
        }
    }

    static func send(_ request: URLRequest) async throws -> Data {
        // Never forward the bearer token through redirects.
        let session = URLSession(configuration: .ephemeral, delegate: DeckNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }
}

private final class DeckNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// Drain both output streams to files, avoiding pipe deadlocks. Never invoke a shell.
func process(_ executable: String, _ arguments: [String]) async throws -> String {
    try await Task.detached {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardOutput = handle
        child.standardError = handle
        try child.run()
        let deadline = Date().addingTimeInterval(60)
        while child.isRunning && Date() < deadline && !Task.isCancelled { try await Task.sleep(for: .milliseconds(50)) }
        if child.isRunning {
            child.terminate()
            try? await Task.sleep(for: .milliseconds(250))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            throw DeckError.message("Action exceeded the 60-second limit.")
        }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 65536) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard child.terminationStatus == 0 else { throw DeckError.message(text.isEmpty ? "Action failed (\(child.terminationStatus))." : text) }
        return text
    }.value
}

enum AudioControl {
    private static func address(_ selector: AudioObjectPropertySelector, input: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static func device(input: Bool) throws -> AudioDeviceID {
        var property = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device))
        guard device != 0 else { throw DeckError.message("No default audio device.") }
        return device
    }
    static func muted(input: Bool) throws -> Bool {
        let device = try device(input: input)
        var property = address(kAudioDevicePropertyMute, input: input)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
        return value != 0
    }
    static func toggleMute(input: Bool) throws {
        var value: UInt32 = try muted(input: input) ? 0 : 1
        var property = address(kAudioDevicePropertyMute, input: input)
        try check(AudioObjectSetPropertyData(try device(input: input), &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }
    static func volume() throws -> Float32 {
        var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        try check(AudioObjectGetPropertyData(try device(input: false), &property, 0, nil, &size, &value))
        return value
    }
    static func adjustVolume(_ change: Float32) throws {
        var value = min(1, max(0, try volume() + change))
        var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        try check(AudioObjectSetPropertyData(try device(input: false), &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value))
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw DeckError.message("This audio device does not support that control (\(status)).") }
    }
}
