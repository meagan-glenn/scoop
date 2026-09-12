import Foundation
import UIKit

/// AI photo scoring: a photo of the stool goes to Claude (vision), which
/// returns a proposed 4C reading via a forced, strict tool call. The model
/// proposes, the owner corrects — the stored record is always owner-confirmed,
/// and the AI never writes to the record directly.
///
/// The API key lives in Secrets.plist (gitignored, copied into the app bundle
/// by an optional build step). No key means scoring is disabled and capture
/// falls back to manual chips. For a shipped app this call would go through a
/// backend proxy; a key in the bundle is a local-development convenience only.

struct AIScore {
    var reading: StoolReading
    /// Axis labels the owner should double-check (low confidence or unscorable).
    var uncertainAxes: [String]
    var isStool: Bool
}

enum AIScorerError: Error {
    case notConfigured
    case badResponse
    case api(String)
}

enum AIScorer {
    static let model = "claude-sonnet-5"

    static var apiKey: String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["ANTHROPIC_API_KEY"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }

    static var isConfigured: Bool { apiKey != nil }

    // Written for Claude Sonnet 5, which follows instructions literally: the
    // prompt states scope and the abstain rule once, and the axis definitions
    // live in the tool schema, where the model reads them at the point of
    // decision. Nothing about diagnosis needs saying — the strict schema
    // cannot express one. Enum values match the app's Codable raw values.
    private static let systemPrompt = """
        You score photos of dog or cat stool for a pet-health tracker. Score only the \
        stool; ignore grass, snow, pavement, bags, and anything else in frame. Report \
        through the tool: one value per axis plus a confidence from 0 to 1, meaning how \
        likely that value is correct. Use "unscorable" for any axis the photo does not \
        show well enough to judge instead of guessing. Set is_stool to false if the \
        photo is not clearly stool.
        """

    private static let toolDefinition: [String: Any] = [
        "name": "report_stool_score",
        "description": "Report the stool reading on four independent axes with a confidence for each.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "is_stool",
                "consistency", "consistency_confidence",
                "color", "color_confidence",
                "coating", "coating_confidence",
                "contents", "contents_confidence",
            ],
            "properties": [
                "is_stool": ["type": "boolean", "description": "True only if the photo clearly shows animal stool."],
                "consistency": [
                    "type": "string",
                    "enum": ["hard", "logs", "littleSoft", "softServe", "diarrhea", "liquid", "unscorable"],
                    "description": "Purina fecal score. hard: 1, dry pellets or crumbly. logs: 2-3, firm and formed, holds shape. littleSoft: 4, formed but soft, leaves residue. softServe: 5, soft pile, loses shape. diarrhea: 6, texture but no shape. liquid: 7, watery puddle.",
                ],
                "consistency_confidence": ["type": "number", "description": "0 to 1."],
                "color": [
                    "type": "string",
                    "enum": ["brown", "green", "yellowOrange", "greyGreasy", "redStreaks", "whiteChalky", "blackTarry", "pinkPurple", "unscorable"],
                    "description": "Dominant color. redStreaks: fresh red on the surface. blackTarry: black and sticky. pinkPurple: pink to purple, jam-like.",
                ],
                "color_confidence": ["type": "number", "description": "0 to 1."],
                "coating": [
                    "type": "string",
                    "enum": ["none", "mucus", "greasy", "unscorable"],
                    "description": "Surface film. mucus: slimy, jelly-like. greasy: oily or shiny sheen.",
                ],
                "coating_confidence": ["type": "number", "description": "0 to 1."],
                "contents": [
                    "type": "string",
                    "enum": ["none", "riceSpecks", "grass", "hair", "foreignMaterial", "blood", "unscorable"],
                    "description": "Visible inclusions. riceSpecks: small white rice-like segments. blood: blood mixed through, not only surface streaks.",
                ],
                "contents_confidence": ["type": "number", "description": "0 to 1."],
            ],
        ],
    ]

    /// Stool photos don't need the model's 2576px high-res tier. 1280px on
    /// the long edge shows every axis at roughly a quarter of the image
    /// tokens, and the upload drops from a 12-megapixel original to well
    /// under a megabyte. Re-encoding also guarantees the bytes are JPEG,
    /// whatever the picker handed over.
    private static let maxEdge: CGFloat = 1280

    private static func prepared(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        let ratio = min(1, maxEdge / max(longest, 1))
        let target = CGSize(width: (pixelSize.width * ratio).rounded(), height: (pixelSize.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85) ?? data
    }

    static func score(_ imageData: Data) async throws -> AIScore {
        guard let key = apiKey else { throw AIScorerError.notConfigured }

        // Decode and resize off the main actor; the caller is a UI task.
        let jpeg = await Task.detached(priority: .userInitiated) { prepared(imageData) }.value

        // Sonnet 5 runs adaptive thinking by default; `medium` effort is the
        // floor where it still reasons per axis instead of answering from an
        // overall impression, and max_tokens leaves room for that thinking
        // ahead of the ~150-token tool call.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "output_config": ["effort": "medium"],
            "system": systemPrompt,
            "tools": [toolDefinition],
            "tool_choice": ["type": "tool", "name": "report_stool_score"],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": jpeg.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": "Score this photo."],
                ],
            ]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIScorerError.badResponse }
        guard http.statusCode == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
            throw AIScorerError.api(message ?? "HTTP \(http.statusCode)")
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] as? [String: Any]
        else { throw AIScorerError.badResponse }

        return parse(input)
    }

    /// Map the tool output onto a reading. Unscorable or low-confidence axes
    /// keep the manual default and get flagged for the owner to check.
    private static func parse(_ input: [String: Any]) -> AIScore {
        let isStool = input["is_stool"] as? Bool ?? false
        var reading = StoolReading.normal
        var uncertain: [String] = []
        let threshold = 0.6

        func axis<T: RawRepresentable>(_ key: String, _ label: String, as type: T.Type) -> T? where T.RawValue == String {
            let confidence = input["\(key)_confidence"] as? Double ?? 0
            guard let raw = input[key] as? String,
                  raw != "unscorable",
                  let value = T(rawValue: raw),
                  confidence >= threshold
            else {
                uncertain.append(label)
                return (input[key] as? String).flatMap { T(rawValue: $0) }
            }
            return value
        }

        if isStool {
            if let value = axis("consistency", "consistency", as: ConsistencyChoice.self) { reading.consistency = value }
            if let value = axis("color", "color", as: StoolColor.self) { reading.color = value }
            if let value = axis("coating", "coating", as: Coating.self) { reading.coating = value }
            if let value = axis("contents", "contents", as: Contents.self) { reading.contents = value }
        }

        return AIScore(reading: reading, uncertainAxes: uncertain, isStool: isStool)
    }
}
