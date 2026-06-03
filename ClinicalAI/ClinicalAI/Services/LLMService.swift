// LLMService.swift
// ClinicalAI — Claude API Integration and Prompt Engineering
//
// All communication with the Anthropic Claude API lives in this file.
// Responsibilities:
//   - Read the API key from the iOS Keychain (never from source code)
//   - Build multimodal prompts combining audio transcript text + Base64-encoded exam images
//   - Generate structured SOAP notes by calling the Claude Messages API
//   - Stream real-time diagnostic suggestions token-by-token (Phase 2)
//
// Security rules enforced here:
//   • The API key is read from Keychain at call time — it is never stored as a property.
//   • The key value is never interpolated into log messages.
//   • Image data is passed as Base64 directly to the API and not cached locally.
//
// Pattern: LLMServiceProtocol → LLMService (live) + MockLLMService (development/testing).

import Foundation

// MARK: - LLMServiceError

/// Errors that the LLM service can throw or surface through the diagnostic stream.
enum LLMServiceError: LocalizedError {
    /// No API key has been saved to the Keychain yet. Show the setup screen.
    case apiKeyMissing
    /// The HTTP response was not an `HTTPURLResponse` (should never happen in practice).
    case invalidResponse
    /// The API returned a non-2xx status. Contains the status code and the API's error message.
    case httpError(statusCode: Int, message: String?)
    /// Claude returned a response but the text was not valid JSON or was missing required keys.
    case jsonParsingFailed(String)
    /// Claude returned a message with no content blocks (empty response).
    case noContentInResponse

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "No API key is configured. Please enter your Anthropic API key in Settings."
        case .invalidResponse:
            return "The server returned an unexpected response format."
        case .httpError(let code, let message):
            let detail = message ?? "No detail provided."
            return "API request failed with status \(code): \(detail)"
        case .jsonParsingFailed(let detail):
            return "Could not parse the note returned by Claude: \(detail)"
        case .noContentInResponse:
            return "Claude returned an empty response. Please try again."
        }
    }
}

// MARK: - Private Codable types (Request)

/// A single block of content in an Anthropic Messages API request.
///
/// Content blocks can be either plain text or an image.
/// The image case encodes as a Base64 data URI per the Anthropic multimodal spec.
private enum ContentBlock: Encodable {
    case text(String)
    /// - Parameters:
    ///   - mediaType: MIME type such as `"image/jpeg"` or `"image/png"`.
    ///   - base64Data: Base64-encoded bytes of the image.
    case image(mediaType: String, base64Data: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let data):
            try container.encode("image", forKey: .type)
            let source = ImageSource(mediaType: mediaType, data: data)
            try container.encode(source, forKey: .source)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, text, source }

    /// The `source` object required for image content blocks.
    private struct ImageSource: Encodable {
        let type = "base64"
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}

/// A single turn in the conversation history sent to the API.
private struct RequestMessage: Encodable {
    let role: String   // Always "user" for this app's single-turn requests.
    let content: [ContentBlock]
}

/// The full JSON body sent in every POST to /v1/messages.
///
/// `stream` uses `encodeIfPresent` so it is omitted (not null) when nil,
/// which is the correct way to request non-streaming mode from the Anthropic API.
private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [RequestMessage]
    let stream: Bool?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(system, forKey: .system)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(stream, forKey: .stream)
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream
        case maxTokens = "max_tokens"
    }
}

// MARK: - Private Codable types (Response)

/// Top-level response object returned by the non-streaming Messages API.
private struct AnthropicResponse: Decodable {
    let content: [ResponseContent]
}

/// One content block in an Anthropic API response.
private struct ResponseContent: Decodable {
    let type: String
    let text: String?
}

/// The five SOAP fields Claude is asked to return as JSON.
private struct SOAPNoteFields: Decodable {
    let chiefComplaint: String
    let historyOfPresentIllness: String
    let physicalExamFindings: String
    let assessment: String
    let plan: String
}

/// Error body returned by the Anthropic API on 4xx / 5xx responses.
private struct AnthropicErrorResponse: Decodable {
    let error: ErrorDetail
    struct ErrorDetail: Decodable {
        let message: String
    }
}

/// A single SSE event from the streaming endpoint.
///
/// Only `content_block_delta` events with `delta.type == "text_delta"` carry
/// text tokens; all other event types (ping, message_start, etc.) are ignored.
private struct StreamEvent: Decodable {
    let type: String
    let delta: Delta?

    struct Delta: Decodable {
        let type: String
        let text: String?
    }
}

// MARK: - LLMServiceProtocol

/// The interface through which the rest of the app requests AI-generated content.
///
/// Both methods read the API key from the Keychain at call time and throw (or surface
/// an error through the stream) if no key is available.
protocol LLMServiceProtocol {

    /// Generates a structured SOAP note from a completed encounter session.
    ///
    /// Combines the session's audio transcript with any captured exam-finding images
    /// into a single multimodal prompt. Claude returns a JSON object which is decoded
    /// into a `ClinicalNote` and linked back to the session via `encounterSessionId`.
    ///
    /// - Parameter session: The completed encounter. Must have a populated `fullTranscript`
    ///   and/or `examFindings` — calling with both empty is valid but will produce a sparse note.
    /// - Returns: A `ClinicalNote` with all five SOAP fields populated.
    /// - Throws: `LLMServiceError` variants for missing key, HTTP failures, or bad JSON.
    func generateNote(from session: EncounterSession) async throws -> ClinicalNote

    /// Streams a real-time AI diagnostic response, one text token at a time.
    ///
    /// The stream begins as soon as the function is called; no `await` is needed on
    /// the call site. Consume the stream with `for try await token in stream { ... }`.
    /// The stream ends when Claude finishes generating or an error occurs.
    ///
    /// Example use in a ViewModel:
    /// ```swift
    /// for try await token in llmService.streamDiagnosticConsultation(for: session, question: text) {
    ///     responseBuffer += token
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - session: The active encounter, used to provide clinical context to Claude.
    ///   - question: The physician's specific question or concern.
    /// - Returns: A throwing async stream of text tokens (individual words or sub-word pieces).
    func streamDiagnosticConsultation(for session: EncounterSession, question: String) -> AsyncThrowingStream<String, Error>
}

// MARK: - LLMService (Live)

/// Production implementation. Makes real HTTPS calls to the Anthropic Claude API.
///
/// The API key is read from the iOS Keychain on every call — it is never stored
/// as a property of this class to reduce the risk of it appearing in memory dumps or logs.
final class LLMService: LLMServiceProtocol {

    // MARK: Constants

    /// The Claude model to use. Pin to a specific version so API changes don't break parsing.
    private let model = "claude-sonnet-4-20250514"

    /// Maximum tokens in Claude's response for note generation.
    /// SOAP notes are typically 300–600 words; 2048 tokens is generous headroom.
    private let noteMaxTokens = 2048

    /// Maximum tokens for a streaming diagnostic response.
    private let diagnosticMaxTokens = 1024

    /// System prompt for SOAP note generation. Instructs Claude to return strict JSON.
    private let noteSystemPrompt = """
        You are a clinical documentation assistant. Analyze the clinical encounter \
        transcript and physical examination images provided. Generate a structured \
        SOAP note. For physical exam findings, incorporate observations from both \
        verbal descriptions and the provided images. Be precise and use standard \
        medical terminology. Return a JSON object with keys: chiefComplaint, \
        historyOfPresentIllness, physicalExamFindings, assessment, plan.
        """

    /// System prompt for the real-time diagnostic consultation chat (Phase 2).
    private let diagnosticSystemPrompt = """
        You are an AI diagnostic partner assisting a physician during a clinical encounter. \
        Provide differential diagnoses with likelihood assessments, suggest targeted exam \
        maneuvers, and recommend diagnostic tests with rationale. Be concise and clinically focused.
        """

    // MARK: Shared infrastructure

    /// Dedicated URLSession. `ephemeral` disables disk caching so response bodies
    /// (which contain patient data) are never written to the filesystem.
    private let urlSession = URLSession(configuration: .ephemeral)

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .withoutEscapingSlashes
        return e
    }()

    // MARK: LLMServiceProtocol

    func generateNote(from session: EncounterSession) async throws -> ClinicalNote {
        let apiKey = try loadAPIKey()

        let content = buildNoteContent(for: session)
        let requestBody = AnthropicRequest(
            model: model,
            maxTokens: noteMaxTokens,
            system: noteSystemPrompt,
            messages: [RequestMessage(role: "user", content: content)],
            stream: nil
        )
        let urlRequest = try buildURLRequest(path: "messages", apiKey: apiKey, body: requestBody)

        let (data, response) = try await urlSession.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? decoder.decode(AnthropicErrorResponse.self, from: data))?.error.message
            throw LLMServiceError.httpError(statusCode: http.statusCode, message: message)
        }

        let apiResponse = try decoder.decode(AnthropicResponse.self, from: data)
        guard let rawText = apiResponse.content.first(where: { $0.type == "text" })?.text else {
            throw LLMServiceError.noContentInResponse
        }

        return try parseNoteResponse(rawText: rawText, sessionId: session.id)
    }

    func streamDiagnosticConsultation(for encounterSession: EncounterSession, question: String) -> AsyncThrowingStream<String, Error> {
        // The closure captures the request-building work so it runs only when the stream
        // is first iterated, not at call time. This avoids blocking the caller.
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let apiKey = try self.loadAPIKey()
                    let userMessage = self.buildDiagnosticUserMessage(for: encounterSession, question: question)
                    let requestBody = AnthropicRequest(
                        model: self.model,
                        maxTokens: self.diagnosticMaxTokens,
                        system: self.diagnosticSystemPrompt,
                        messages: [RequestMessage(role: "user", content: [.text(userMessage)])],
                        stream: true
                    )
                    let urlRequest = try self.buildURLRequest(path: "messages", apiKey: apiKey, body: requestBody)

                    let (bytes, response) = try await self.urlSession.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMServiceError.invalidResponse
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw LLMServiceError.httpError(statusCode: http.statusCode, message: nil)
                    }

                    // Parse Server-Sent Events (SSE). Each line is either:
                    //   "event: <type>"  — event type name (we ignore this line)
                    //   "data: <json>"   — JSON payload for the event
                    //   ""               — blank line separating events
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard payload != "[DONE]" else { break }

                        if let eventData = payload.data(using: .utf8),
                           let event = try? self.decoder.decode(StreamEvent.self, from: eventData),
                           event.type == "content_block_delta",
                           let delta = event.delta,
                           delta.type == "text_delta",
                           let token = delta.text {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // If the consumer cancels the for-await loop, also cancel the network task.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private helpers

    /// Reads the API key from the Keychain and converts KeychainError to LLMServiceError
    /// so callers only need to handle one error type.
    private func loadAPIKey() throws -> String {
        do {
            return try KeychainService.shared.loadAPIKey()
        } catch {
            throw LLMServiceError.apiKeyMissing
        }
    }

    /// Builds the ordered array of content blocks for the SOAP note request.
    ///
    /// Layout:
    ///   1. Text block with the full encounter transcript.
    ///   2. For each ExamFinding with image data: image block + annotation text block.
    ///   3. For annotation-only findings (image already cleared): plain text block.
    private func buildNoteContent(for session: EncounterSession) -> [ContentBlock] {
        var blocks: [ContentBlock] = []

        // Include the transcript even if it is empty — Claude handles sparse data gracefully.
        let transcript = session.fullTranscript.isEmpty
            ? "(No audio transcript available for this encounter.)"
            : session.fullTranscript
        blocks.append(.text("Encounter transcript:\n\(transcript)"))

        // Append each exam finding. When an image is present, the adjacent annotation
        // text block tells Claude which body system the image belongs to.
        for finding in session.examFindings {
            if let imageData = finding.image {
                let mediaType = detectMediaType(imageData)
                let base64 = imageData.base64EncodedString()
                blocks.append(.image(mediaType: mediaType, base64Data: base64))
                blocks.append(.text(
                    "Physical exam finding (\(finding.bodySystem.displayName)): \(finding.annotation)"
                ))
            } else {
                // Image data was cleared post-note or was never captured; use annotation only.
                blocks.append(.text(
                    "Physical exam finding (\(finding.bodySystem.displayName)): \(finding.annotation)"
                ))
            }
        }

        return blocks
    }

    /// Builds the text-only user message for a diagnostic consultation.
    ///
    /// No images are sent here — this endpoint is optimised for real-time latency.
    private func buildDiagnosticUserMessage(for session: EncounterSession, question: String) -> String {
        var parts: [String] = []

        if !session.fullTranscript.isEmpty {
            parts.append("Current encounter transcript:\n\(session.fullTranscript)")
        }

        if !session.examFindings.isEmpty {
            let findingsSummary = session.examFindings
                .map { "\($0.bodySystem.displayName): \($0.annotation)" }
                .joined(separator: "\n")
            parts.append("Physical exam findings noted so far:\n\(findingsSummary)")
        }

        parts.append("Physician question: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// Constructs a URLRequest for the Anthropic Messages API.
    ///
    /// The API key is placed in the `x-api-key` header — never in the URL, query string,
    /// or request body, as those are more likely to appear in access logs.
    private func buildURLRequest(path: String, apiKey: String, body: AnthropicRequest) throws -> URLRequest {
        // Force-unwrapping a hand-written constant URL is safe; any typo would be caught
        // immediately in development.
        let url = URL(string: "https://api.anthropic.com/v1/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        // Pin the API version so breaking changes in future API versions don't affect us.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Extracts the JSON object from Claude's text response and decodes it into a `ClinicalNote`.
    ///
    /// Claude is instructed to return raw JSON, but it may occasionally wrap the object in
    /// a Markdown code block (` ```json ... ``` `). This method handles both cases.
    private func parseNoteResponse(rawText: String, sessionId: UUID) throws -> ClinicalNote {
        guard let jsonData = extractJSONData(from: rawText) else {
            throw LLMServiceError.jsonParsingFailed(
                "Could not locate a JSON object in Claude's response."
            )
        }
        do {
            let fields = try decoder.decode(SOAPNoteFields.self, from: jsonData)
            return ClinicalNote(
                id: UUID(),
                encounterSessionId: sessionId,
                generatedAt: Date(),
                chiefComplaint: fields.chiefComplaint,
                historyOfPresentIllness: fields.historyOfPresentIllness,
                physicalExamFindings: fields.physicalExamFindings,
                assessment: fields.assessment,
                plan: fields.plan,
                rawJSON: rawText,
                isEdited: false
            )
        } catch {
            throw LLMServiceError.jsonParsingFailed(error.localizedDescription)
        }
    }

    /// Robustly extracts a JSON object from a string that may contain Markdown code fences.
    ///
    /// Strategy:
    ///   1. Try parsing the raw text directly as JSON.
    ///   2. Strip ` ```json ` / ` ``` ` fences, then retry.
    ///   3. Find the outermost `{` and `}` and parse that substring.
    private func extractJSONData(from text: String) -> Data? {
        // 1 — Plain JSON (ideal case).
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        // 2 — Strip common Markdown code fence patterns.
        var cleaned = text
        for prefix in ["```json\n", "```json\r\n", "```\n", "```\r\n"] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)) }
        }
        if cleaned.hasSuffix("\n```") { cleaned = String(cleaned.dropLast(4)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        let stripped = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = stripped.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        // 3 — Find the outermost { ... } as a last resort.
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            let jsonSubstring = String(text[start...end])
            if let data = jsonSubstring.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
        }

        return nil
    }

    /// Detects whether image bytes are JPEG or PNG by inspecting the magic bytes header.
    ///
    /// The Anthropic API requires the correct `media_type` for each image block.
    /// JPEG: starts with `FF D8 FF`. PNG: starts with `89 50 4E 47`.
    private func detectMediaType(_ data: Data) -> String {
        if data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return "image/jpeg" // Default — the glasses are most likely to produce JPEG.
    }
}

// MARK: - MockLLMService

/// Development-only implementation that returns hardcoded data without hitting the API.
///
/// Use this in:
///   - Xcode Previews (no API key needed in the simulator).
///   - Unit tests (fast, deterministic, free).
///   - UI walkthroughs when demonstrating the app to non-medical stakeholders.
///
/// The note reflects a realistic community-acquired pneumonia case so reviewers can
/// evaluate the note format and layout with clinically meaningful content.
final class MockLLMService: LLMServiceProtocol {

    func generateNote(from session: EncounterSession) async throws -> ClinicalNote {
        // Simulate the 3–8 s that a real API call takes so UI loading states can be tested.
        try await Task.sleep(for: .seconds(2))

        let rawJSON = """
        {
          "chiefComplaint": "Productive cough, fever, and right-sided chest pain for 3 days",
          "historyOfPresentIllness": "Mr. J.D. is a 52-year-old male with a history of type 2 \
        diabetes mellitus who presents with a 3-day history of productive cough with yellow-green \
        sputum, subjective fever measured at 38.9°C at home, and right-sided pleuritic chest pain \
        that worsens with deep inspiration. He reports associated fatigue and markedly decreased \
        appetite. He denies hemoptysis, orthopnea, or lower extremity edema. He completed a course \
        of antibiotics for an upper respiratory infection approximately 6 weeks ago. No sick contacts \
        identified. He is a former smoker with a 15 pack-year history, quit 8 years ago.",
          "physicalExamFindings": "Vital signs: Temperature 38.6°C, HR 98 bpm, BP 138/84 mmHg, \
        RR 20 breaths/min, O2 saturation 95% on room air. General: Alert and oriented ×3, in mild \
        respiratory distress. Pulmonary: Dullness to percussion over the right lower lobe posteriorly. \
        Tactile fremitus increased at the right lower lobe. Auscultation reveals crackles and bronchial \
        breath sounds in the right lower lobe; left lung fields clear. Visual exam image demonstrates \
        right-sided reduced excursion consistent with splinting. Cardiac: Regular rate and rhythm, no \
        murmurs or gallops. Skin: Mild diaphoresis noted.",
          "assessment": "1. Community-acquired pneumonia (CAP), right lower lobe — CURB-65 score \
        1 (age ≥65 not met; urea pending; RR 20; BP within normal limits; not confused); low severity, \
        outpatient management appropriate.\n2. Type 2 diabetes mellitus — unrelated to acute presentation; \
        monitor for hyperglycemia during illness.",
          "plan": "1. Amoxicillin-clavulanate 875/125 mg PO twice daily × 5 days.\n\
        2. Azithromycin 500 mg PO Day 1, then 250 mg PO Days 2–5 for atypical organism coverage.\n\
        3. Acetaminophen 1000 mg PO every 6 hours as needed for fever and pain.\n\
        4. Encourage oral hydration, target 2–3 L per day.\n\
        5. Follow-up in 48–72 hours or sooner if symptoms worsen or O2 saturation drops below 92%.\n\
        6. Return precautions: worsening dyspnea, hemoptysis, altered mental status → Emergency Department.\n\
        7. Chest X-ray follow-up in 6 weeks to confirm clearance and rule out underlying mass."
        }
        """

        return ClinicalNote(
            id: UUID(),
            encounterSessionId: session.id,
            generatedAt: Date(),
            chiefComplaint: "Productive cough, fever, and right-sided chest pain for 3 days",
            historyOfPresentIllness: """
                Mr. J.D. is a 52-year-old male with a history of type 2 diabetes mellitus \
                who presents with a 3-day history of productive cough with yellow-green sputum, \
                subjective fever measured at 38.9°C at home, and right-sided pleuritic chest pain \
                that worsens with deep inspiration. He reports associated fatigue and markedly \
                decreased appetite. He denies hemoptysis, orthopnea, or lower extremity edema. \
                He completed a course of antibiotics for an upper respiratory infection \
                approximately 6 weeks ago. No sick contacts identified. He is a former smoker \
                with a 15 pack-year history, quit 8 years ago.
                """,
            physicalExamFindings: """
                Vital signs: Temperature 38.6°C, HR 98 bpm, BP 138/84 mmHg, RR 20 breaths/min, \
                O2 saturation 95% on room air. General: Alert and oriented ×3, in mild respiratory \
                distress. Pulmonary: Dullness to percussion over the right lower lobe posteriorly. \
                Tactile fremitus increased at the right lower lobe. Auscultation reveals crackles \
                and bronchial breath sounds in the right lower lobe; left lung fields clear. \
                Visual exam image demonstrates right-sided reduced excursion consistent with splinting. \
                Cardiac: Regular rate and rhythm, no murmurs or gallops. Skin: Mild diaphoresis.
                """,
            assessment: """
                1. Community-acquired pneumonia (CAP), right lower lobe — CURB-65 score 1 \
                (age ≥65 not met; urea pending; RR 20; BP within normal limits; not confused); \
                low severity, outpatient management appropriate.
                2. Type 2 diabetes mellitus — unrelated to acute presentation; monitor for \
                hyperglycemia during illness.
                """,
            plan: """
                1. Amoxicillin-clavulanate 875/125 mg PO twice daily × 5 days.
                2. Azithromycin 500 mg PO Day 1, then 250 mg PO Days 2–5 (atypical coverage).
                3. Acetaminophen 1000 mg PO every 6 hours as needed for fever and pain.
                4. Encourage oral hydration, target 2–3 L per day.
                5. Follow-up in 48–72 hours or sooner if symptoms worsen or O2 saturation \
                drops below 92%.
                6. Return precautions: worsening dyspnea, hemoptysis, altered mental status \
                → Emergency Department.
                7. Chest X-ray follow-up in 6 weeks to confirm clearance and rule out \
                underlying mass.
                """,
            rawJSON: rawJSON,
            isEdited: false
        )
    }

    func streamDiagnosticConsultation(for session: EncounterSession, question: String) -> AsyncThrowingStream<String, Error> {
        // Realistic diagnostic response streamed word-by-word to exercise the streaming UI.
        let fullResponse = """
            Based on the clinical presentation — productive cough, fever, pleuritic chest pain, \
            and right lower lobe findings — the differential includes:

            **High Likelihood**
            • Community-acquired pneumonia (CAP) — Streptococcus pneumoniae most likely given \
            acute lobar pattern, productive sputum, and fever.

            **Moderate Likelihood**
            • Atypical pneumonia (Mycoplasma pneumoniae, Legionella) — consider given patient age \
            and diabetes; Legionella more likely if recent hotel or spa exposure.
            • Pulmonary embolism — tachycardia (HR 98) with pleuritic pain warrants consideration; \
            low Wells score but elevated RR supports clinical evaluation.

            **Low Likelihood**
            • Lung abscess — would expect longer prodrome and more systemic toxicity.

            **Suggested Exam Maneuvers**
            • Whispered pectoriloquy at right lower lobe (consolidation vs. pleural effusion)
            • Assess for dullness vs. stony dullness to distinguish pneumonia from effusion

            **Recommended Tests**
            • CBC with differential, BMP, LFTs
            • Blood cultures ×2 before starting antibiotics
            • CXR PA and lateral (confirm lobar consolidation, assess for effusion)
            • Urine Legionella antigen
            • Procalcitonin and CRP (baseline for response monitoring)
            • Consider CT pulmonary angiography if PE cannot be excluded clinically
            """

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Stream word-by-word at ~50 ms intervals to simulate realistic token delivery.
                let tokens = fullResponse.components(separatedBy: " ")
                for token in tokens {
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(for: .milliseconds(40))
                    continuation.yield(token + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
