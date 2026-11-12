import Foundation

enum ViewerTool: String, CaseIterable, Decodable {
    case getState = "get_state"
    case setView = "set_view"
    case navigate
    case getImage = "get_image"
    case configureVolume = "configure_volume"
    case measure
    case bookmark

    private var definition: (description: String, properties: [String: Any], required: [String]) {
        let description: String
        var properties: [String: Any] = [:]
        var required: [String] = []
        switch self {
        case .getState:
            description = "Read the state of the open INV Viewer window, including the active view and current slice coordinates."
        case .setView:
            description = "Switch the open INV Viewer window to a view. Cross-section detail uses the current position on the dental arch."
            properties["view"] = ["type": "string", "enum": MCPView.allCases.map(\.rawValue)]
            required = ["view"]
        case .navigate:
            description = "Move in a slice, panorama, cross-section or MPR. Supply one movement. In MPR, mpr_plane may qualify slice or steps. In panorama, slice moves the axial guide."
            properties = [
                "jaw": ["type": "string", "enum": MCPJaw.allCases.map(\.rawValue)],
                "position_mm": ["type": "number", "minimum": 0, "description": "Distance along the current dental arch."],
                "slice": ["type": "integer", "minimum": 1, "description": "One-based slice number."],
                "steps": ["type": "integer", "minimum": -100, "maximum": 100, "description": "Signed number of neighboring slices."],
                "zoom": ["type": "number", "minimum": 1, "maximum": 4],
                "mpr_plane": ViewerCall.MPRPlane.schema
            ]
        case .getImage:
            description = "Return the current scan view as a PNG with its own coordinates and an image_id for measurement where supported."
            properties["mpr_plane"] = ViewerCall.MPRPlane.schema
        case .configureVolume:
            description = "Adjust the open 3D view. Use set_view with volume_3d first. Rotation angles are relative to the current camera."
            properties = [
                "yaw_deg": number(-180, 180), "pitch_deg": number(-180, 180),
                "preset": ["type": "string", "enum": ViewerCall.VolumePreset.allCases.map(\.rawValue)],
                "zoom": number(0.65, 3), "opacity": number(0, 1), "density": number(-1, 1),
                "clip_axis": ["type": "string", "enum": ViewerCall.ClipAxis.allCases.map(\.rawValue)],
                "clip_position": number(0, 1), "reverse_clip": ["type": "boolean"], "reset": ["type": "boolean"]
            ]
        case .measure:
            description = "Draw a two-point ruler on the latest PNG from MPR or a detailed cross-section. The user supplies the endpoints. Coordinates are fractions from the top-left of the image."
            let point: [String: Any] = ["type": "array", "items": number(0, 1), "minItems": 2, "maxItems": 2]
            properties = ["image_id": ["type": "string"], "first": point, "second": point]
            required = ["image_id", "first", "second"]
        case .bookmark:
            description = "List saved bookmarks, save the current 2D view with its ruler and optional note, or open a bookmark by id."
            properties = [
                "action": ["type": "string", "enum": ViewerCall.BookmarkAction.allCases.map(\.rawValue)],
                "id": ["type": "string"], "name": ["type": "string"], "note": ["type": "string"]
            ]
            required = ["action"]
        }
        return (description, properties, required)
    }

    private func number(_ minimum: Double, _ maximum: Double) -> [String: Any] {
        ["type": "number", "minimum": minimum, "maximum": maximum]
    }

    var schema: [String: Any] {
        let definition = definition
        var input: [String: Any] = ["type": "object", "properties": definition.properties, "additionalProperties": false]
        if !definition.required.isEmpty { input["required"] = definition.required }
        return [
            "name": rawValue, "description": definition.description, "inputSchema": input,
            "annotations": [
                "readOnlyHint": self == .getState || self == .getImage,
                "destructiveHint": false, "openWorldHint": false
            ]
        ]
    }

    func accepts(_ arguments: [String: Any]) -> Bool {
        let definition = definition
        return arguments.allSatisfy { definition.properties[$0.key] != nil && !($0.value is NSNull) }
            && definition.required.allSatisfy { arguments[$0] != nil }
    }
}

enum MCPView: String, CaseIterable, Decodable {
    case axial, coronal, sagittal, mpr, panorama, crossSection = "cross_section", volume3D = "volume_3d"

    init(_ plane: Plane) {
        self = [.axial, .coronal, .sagittal][plane.rawValue]
    }

    var plane: Plane? {
        switch self {
        case .axial: .axial
        case .coronal: .coronal
        case .sagittal: .sagittal
        case .mpr, .panorama, .crossSection, .volume3D: nil
        }
    }
}

enum MCPJaw: String, CaseIterable, Decodable {
    case upper, lower
}

struct ViewerCall: Decodable {
    enum MPRPlane: String, Decodable, CaseIterable {
        case axial, coronal, sagittal

        var plane: Plane {
            switch self {
            case .axial: .axial
            case .coronal: .coronal
            case .sagittal: .sagittal
            }
        }

        static var schema: [String: Any] {
            ["type": "string", "enum": allCases.map(\.rawValue),
             "description": "Select a linked MPR plane. Defaults to the active plane."]
        }
    }

    enum VolumePreset: String, Decodable, CaseIterable { case bone, softTissue = "soft_tissue" }
    enum ClipAxis: String, Decodable, CaseIterable {
        case none, axial, coronal, sagittal

        var plane: Plane? { MCPView(rawValue: rawValue)?.plane }
    }
    enum BookmarkAction: String, Decodable, CaseIterable { case list, save, open }

    struct Arguments: Decodable {
        let view: MCPView?
        let jaw: MCPJaw?
        let position_mm: Double?
        let slice: Int?
        let steps: Int?
        let zoom: Double?
        let mpr_plane: MPRPlane?
        let yaw_deg: Double?
        let pitch_deg: Double?
        let preset: VolumePreset?
        let opacity: Double?
        let density: Double?
        let clip_axis: ClipAxis?
        let clip_position: Double?
        let reverse_clip: Bool?
        let reset: Bool?
        let image_id: UUID?
        let first: [Double]?
        let second: [Double]?
        let action: BookmarkAction?
        let id: UUID?
        let name: String?
        let note: String?
    }

    let name: ViewerTool
    let arguments: Arguments?

    static func decode(_ data: Data) throws -> Self {
        let call = try JSONDecoder().decode(Self.self, from: data)
        let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arguments: [String: Any]
        if let raw = request?["arguments"] {
            guard let object = raw as? [String: Any] else { throw BridgeError.invalidMessage }
            arguments = object
        } else {
            arguments = [:]
        }
        guard call.name.accepts(arguments) else { throw BridgeError.invalidMessage }
        return call
    }
}

struct ViewerToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ViewerMCP {
    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static func serve() {
        var initialized = false
        while let line = readLine() {
            let data = Data(line.utf8)
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(error(id: NSNull(), code: -32700, message: "Parse error"))
                continue
            }
            let id = message["id"]
            guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
                send(error(id: id ?? NSNull(), code: -32600, message: "Invalid request"))
                continue
            }
            guard let id else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch method {
            case "initialize":
                guard let requested = params["protocolVersion"] as? String else {
                    send(error(id: id, code: -32602, message: "Missing protocolVersion"))
                    continue
                }
                initialized = true
                result = [
                    "protocolVersion": versions.contains(requested) ? requested : versions[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "inv-viewer", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
                ]
            case "ping":
                result = [:]
            case "tools/list" where initialized:
                result = ["tools": ViewerTool.allCases.map(\.schema)]
            case "tools/call" where initialized:
                do {
                    let request = try JSONSerialization.data(withJSONObject: params)
                    _ = try ViewerCall.decode(request)
                    let reply = try LocalBridge.request(request)
                    guard let decoded = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                        throw BridgeError.invalidMessage
                    }
                    result = decoded
                } catch is DecodingError {
                    result = failure(String(localized: "Неизвестная команда или неверные аргументы."))
                } catch {
                    result = failure(error.localizedDescription)
                }
            default:
                send(error(id: id, code: -32601, message: "Method not found"))
                continue
            }
            send(["jsonrpc": "2.0", "id": id, "result": result])
        }
    }

    static func reply(_ state: [String: Any], image: Data? = nil) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return try reply(stateData: data, image: image)
    }

    static func reply(stateData: Data, image: Data?) throws -> Data {
        let state = try JSONSerialization.jsonObject(with: stateData)
        var content: [[String: String]] = [["type": "text", "text": String(decoding: stateData, as: UTF8.self)]]
        if let image {
            content.append(["type": "image", "mimeType": "image/png", "data": image.base64EncodedString()])
        }
        return try JSONSerialization.data(withJSONObject: ["content": content, "structuredContent": state])
    }

    static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    static func failureData(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: failure(message))) ?? Data()
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
