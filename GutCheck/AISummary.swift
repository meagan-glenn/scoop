import Foundation

/// The opening statement: the two or three sentences a vet hears first,
/// written by the model from the summary's own bullets and nothing else.
/// The facts stay computed; the model only orders and phrases them.
///
/// Three guards keep it on the right side of the no-diagnosis line, all in
/// code rather than in the prompt: every sentence must cite the facts it
/// restates (uncited sentences are dropped), every number in a sentence must
/// appear in a cited fact next to the same neighbouring word (recombined
/// figures are dropped), and any sentence that reads as a cause is dropped.
/// The summary is complete without it.
enum AISummary {
    struct Sentence {
        var text: String
        var sources: [Int]
    }

    /// One call per distinct set of facts per session; scrolling and
    /// reopening the sheet don't re-bill.
    private static var cache: [String: [String]] = [:]

    // Written for Claude Sonnet 5, which follows instructions literally:
    // scope, order, and the citation rule, once each. What it must not do
    // is enforced below, not asked for here.
    private static let systemPrompt = """
        You write the opening statement a pet owner gives at the start of a vet \
        appointment, from a numbered list of facts logged in a pet-health tracker. \
        Two or three plain sentences, with numbers and dates exactly as written in the \
        facts. Lead with what a vet needs first: current medications, what changed \
        recently, what the stools did since. \
        Use only the listed facts, each fact at most once, and cite each sentence's \
        fact numbers. Restate; do not interpret or explain.
        """

    private static let toolDefinition: [String: Any] = [
        "name": "report_opening",
        "description": "The opening statement as separate sentences, each citing the fact numbers it restates.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["sentences"],
            "properties": [
                "sentences": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["text", "sources"],
                        "properties": [
                            "text": ["type": "string"],
                            "sources": [
                                "type": "array",
                                "items": ["type": "integer"],
                                "description": "Fact numbers this sentence restates.",
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ]

    /// Words that turn a restatement into an inference. A sentence carrying
    /// any of them is dropped whole.
    private static let causal = [
        "likely", "probably", "caused", "cause", "because", "suggest", "due to",
        "may be", "might be", "could be", "related", "linked", "indicat",
        "consistent with", "diagnos", "explain",
    ]

    @MainActor
    static func opening(facts: [String]) async throws -> [String] {
        let key = facts.joined(separator: "\n")
        if let cached = cache[key] { return cached }
        guard let apiKey = AIScorer.apiKey else { throw AIScorerError.notConfigured }

        let numbered = facts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": AIScorer.model,
            "max_tokens": 1024,
            "output_config": ["effort": "low"],
            "system": systemPrompt,
            "tools": [toolDefinition],
            "tool_choice": ["type": "tool", "name": "report_opening"],
            "messages": [[
                "role": "user",
                "content": numbered,
            ]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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
              let input = toolUse["input"] as? [String: Any],
              let raw = input["sentences"] as? [[String: Any]]
        else { throw AIScorerError.badResponse }

        let sentences = raw.compactMap { entry -> Sentence? in
            guard let text = entry["text"] as? String else { return nil }
            let sources = (entry["sources"] as? [Any])?.compactMap { source -> Int? in
                if let n = source as? Int { return n }
                if let d = source as? Double { return Int(d) }
                return nil
            } ?? []
            return Sentence(text: text, sources: sources)
        }
        let result = validated(sentences, facts: facts)
        cache[key] = result
        return result
    }

    /// The guards. Pure so it can be checked without a network.
    static func validated(_ sentences: [Sentence], facts: [String]) -> [String] {
        sentences.prefix(3).compactMap { sentence in
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            // Must cite something real.
            let indices = sentence.sources.filter { $0 >= 1 && $0 <= facts.count }
            guard !indices.isEmpty else { return nil }

            // Must not reason.
            let lower = text.lowercased()
            if causal.contains(where: { lower.contains($0) }) { return nil }

            // Every number must come from a cited fact, next to the same
            // neighbouring word: "8 of 9" passes on "8 of 9 scheduled doses";
            // "missed 3 doses" fails even though a "Sep 3" is in the source.
            let sourceWords = words(indices.map { facts[$0 - 1] }.joined(separator: " "))
            var bigrams = Set<String>()
            for i in sourceWords.indices.dropLast() {
                bigrams.insert(sourceWords[i] + " " + sourceWords[i + 1])
            }
            let sentenceWords = words(text)
            for (i, word) in sentenceWords.enumerated() where word.contains(where: \.isNumber) {
                var candidates: [String] = []
                if i > 0 { candidates.append(sentenceWords[i - 1] + " " + word) }
                if i + 1 < sentenceWords.count { candidates.append(word + " " + sentenceWords[i + 1]) }
                guard candidates.contains(where: bigrams.contains) else { return nil }
            }

            return text
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
