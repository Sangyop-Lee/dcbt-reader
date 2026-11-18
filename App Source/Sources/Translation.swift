import Foundation
import AppKit
import Security

// MARK: - Translation through the OpenAI API

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case korean = "Korean", english = "English"
    var id: String { rawValue }
}

enum TranslationProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI", anthropic = "Anthropic", gemini = "Gemini"
    var id: String { rawValue }
    /// Shown in the interface: the company.
    var label: String { self == .openai ? "OpenAI" : self == .anthropic ? "Anthropic" : "Google" }
    /// Whose API key it takes.
    var keyName: String { self == .openai ? "OpenAI API key" : self == .anthropic ? "Anthropic API key" : "Gemini API key" }
    var account: String { self == .openai ? "openai" : self == .anthropic ? "anthropic" : "gemini" }
    var keyHint: String { self == .openai ? "sk-…" : self == .anthropic ? "sk-ant-…" : "AIza…" }
    /// Shown as the placeholder of the model field; the user picks the model.
    var modelHint: String { self == .anthropic ? "e.g. claude-opus-5-5" : "model name (press List Models)" }
}

/// API keys live in the Mac's keychain, one per provider, never in a file.
enum KeyStore {
    private static let service = "DCBT Reader OpenAI API key"      // name kept from the first version

    private static func query(_ p: TranslationProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.account]
    }

    static func load(_ p: TranslationProvider) -> String {
        var q = query(p)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func save(_ key: String, for p: TranslationProvider) {
        SecItemDelete(query(p) as CFDictionary)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return }
        var add = query(p)
        add[kSecValueData as String] = Data(k.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Translation requests to OpenAI, Anthropic or Google Gemini over plain HTTPS.
/// Keys always travel in a header, never in the address.
enum Translator {
    private static func fail(_ data: Data?, _ status: Int, _ done: (Result<String, Error>) -> Void, _ fallback: String? = nil) {
        var m = fallback ?? "The translation service answered with error \(status)."
        if let data = data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = o["error"] as? [String: Any], let msg = e["message"] as? String { m = msg }
        done(.failure(NSError(domain: "Translator", code: status, userInfo: [NSLocalizedDescriptionKey: m])))
    }

    private static func request(_ p: TranslationProvider, _ path: String, key: String) -> URLRequest {
        let base: String
        switch p {
        case .openai: base = "https://api.openai.com/v1/"
        case .anthropic: base = "https://api.anthropic.com/v1/"
        case .gemini: base = "https://generativelanguage.googleapis.com/v1beta/"
        }
        var r = URLRequest(url: URL(string: base + path)!)
        switch p {
        case .openai: r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case .anthropic:
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case .gemini: r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        r.timeoutInterval = 180
        return r
    }

    /// Names of the text models this key can use.
    static func models(_ p: TranslationProvider, key: String, done: @escaping (Result<[String], Error>) -> Void) {
        let path = p == .anthropic ? "models?limit=1000" : p == .gemini ? "models?pageSize=1000" : "models"
        URLSession.shared.dataTask(with: request(p, path, key: key)) { data, resp, err in
            if let err = err { return done(.failure(err)) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail(data, status) { r in if case .failure(let e) = r { done(.failure(e)) } }
            }
            var ids: [String] = []
            switch p {
            case .openai:
                let skip = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "moderation", "realtime", "transcribe", "babbage", "davinci", "sora"]
                ids = ((o["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { id in !skip.contains { id.contains($0) } }
            case .anthropic:
                ids = ((o["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            case .gemini:
                ids = ((o["models"] as? [[String: Any]]) ?? []).filter { (($0["supportedGenerationMethods"] as? [String]) ?? []).contains("generateContent") }
                    .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
            }
            done(.success(ids.sorted()))
        }.resume()
    }

    static func translate(_ text: String, context: String, to language: TranslationLanguage, provider p: TranslationProvider,
                          model: String, key: String, done: @escaping (Result<String, Error>) -> Void) {
        let system = """
        You translate classical Chinese Buddhist texts for a scholar. Translate the passage into \(language.rawValue), \
        accurately and closely to the original, in a natural scholarly register. Keep proper names and technical terms \
        recognisable, giving the Chinese in parentheses where a reader would need it. Give only the translation, with no \
        commentary. The passage is from: \(context).
        """
        var r: URLRequest
        var body: [String: Any]
        switch p {
        case .openai:
            r = request(p, "chat/completions", key: key)
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": text]]]
        case .anthropic:
            r = request(p, "messages", key: key)
            body = ["model": model, "max_tokens": 16000, "system": system, "messages": [["role": "user", "content": text]]]
            // On the newest models a safety classifier can decline a request; let the API retry it on a fallback model.
            if ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model) {
                r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .gemini:
            let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            r = request(p, "models/\(name):generateContent", key: key)
            body = ["system_instruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": text]]]]]
        }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { data, resp, err in
            if let err = err { return done(.failure(err)) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail(data, status, done)
            }
            var out = ""
            switch p {
            case .openai:
                out = (((o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
            case .anthropic:
                if o["stop_reason"] as? String == "refusal" {
                    return fail(nil, 200, done, "The model declined to translate this passage.")
                }
                out = ((o["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
            case .gemini:
                let parts = ((((o["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [])
                out = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { return fail(nil, 200, done, "The service returned no translation.") }
            done(.success(out))
        }.resume()
    }
}

// MARK: - What the reader does with a selection

enum BottomTab: String, CaseIterable, Identifiable {
    case variants = "Variants", dictionary = "Dictionary", translation = "Translation"
    var id: String { rawValue }
}

extension AppState {
    static func hanCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (isSearchScalar($1.value) && $1.value > 0x2E7F ? 1 : 0) }
    }

    /// The selection in the reader changed; it is acted on once it has been still for a moment.
    func selectionChanged(_ text: String) {
        selectionGeneration += 1
        let gen = selectionGeneration
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self, gen == self.selectionGeneration else { return }
            self.actOnSelection(t)
        }
    }

    private func actOnSelection(_ raw: String) {
        // line numbers shown in the text are not part of the passage
        let text = raw.replacingOccurrences(of: "\u{2009}[0-9]{1,4}[a-z][0-9]{2}\u{2009}", with: "", options: .regularExpression)
                      .replacingOccurrences(of: "\u{FFFC}", with: "")
        let n = AppState.hanCount(text)
        if n == 0 { return }
        if n <= 4 {
            // up to four characters: the dictionaries
            lookUp(text)
            if !showVariants { toggle(.variants) }
            bottomTab = .dictionary
        } else {
            // five or more: translation
            translationSource = text
            translationResult = ""
            translationError = ""
            if !showVariants { toggle(.variants) }
            bottomTab = .translation
        }
    }

    /// Translates the selected passage and adds the result to the translation log.
    func translate() {
        let text = translationSource
        guard !text.isEmpty else { return }
        let language = translationLanguage
        let provider = translationProvider
        let model = translationModel
        let key = KeyStore.load(provider)
        guard !key.isEmpty, !model.isEmpty else {
            translationError = "Add your \(provider.keyName) and choose a model in Translation Settings first."
            translationResult = ""
            return
        }
        if text.count > 4000 {
            translationError = "That selection is \(text.count) characters long; select at most 4,000 at a time."
            return
        }
        translationGeneration += 1
        let gen = translationGeneration
        translating = true
        translationError = ""
        translationResult = ""
        var context = "a Chinese Buddhist text"
        var textId = "", title = "", place = ""
        if let ix = index, let ti = readerText {
            textId = ix.texts[ti].id; title = ix.texts[ti].title
            context = "\(title) (\(textId))"
            if let p = currentPlace() { place = prettyLbn(p.lbn) }
        }
        Translator.translate(text, context: context, to: language, provider: provider, model: model, key: key) { result in
            DispatchQueue.main.async {
                // keep every finished translation, even if the selection has moved on
                if case .success(let s) = result {
                    ActivityLog.translations.add("\(textId) \(title), p. \(place)", "\(provider.label) \(model)", language.rawValue,
                                                 text.replacingOccurrences(of: "\n", with: " "), s.replacingOccurrences(of: "\n", with: " "))
                }
                guard gen == self.translationGeneration else { return }
                self.translating = false
                switch result {
                case .success(let s): self.translationResult = s
                case .failure(let e): self.translationError = e.localizedDescription
                }
            }
        }
    }

    func saveTranslationSettings() {
        let d = UserDefaults.standard
        d.set(translationProvider.rawValue, forKey: "translation.provider")
        d.set(translationModel, forKey: "translation.model." + translationProvider.account)
        d.set(translationLanguage.rawValue, forKey: "translation.language")
    }

    func loadTranslationSettings() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "translation.provider"), let v = TranslationProvider(rawValue: p) { translationProvider = v }
        translationModel = d.string(forKey: "translation.model." + translationProvider.account)
            ?? (translationProvider == .openai ? d.string(forKey: "translation.model") ?? "" : "")
        if let l = d.string(forKey: "translation.language"), let v = TranslationLanguage(rawValue: l) { translationLanguage = v }
    }

    /// Switching provider in the settings: each provider remembers its own model.
    func setTranslationProvider(_ p: TranslationProvider) {
        let d = UserDefaults.standard
        d.set(translationModel, forKey: "translation.model." + translationProvider.account)
        translationProvider = p
        translationModel = d.string(forKey: "translation.model." + p.account) ?? ""
    }

    // MARK: stepping through the results with the arrow keys

    func stepRow(_ d: Int) {
        guard !rows.isEmpty else { return }
        var i = selectedRow.flatMap { rows.firstIndex(of: $0) } ?? (d > 0 ? -1 : rows.count)
        i = min(max(i + d, 0), rows.count - 1)
        if rows[i] == selectedRow { return }
        selectedRow = rows[i]
        openRow(rows[i])
    }

    /// Up and down arrows move through the results whenever one is selected and
    /// the keys are not needed for moving the caret in the text being read.
    func installArrowKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.keyCode == 125 || e.keyCode == 126,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  self.selectedRow != nil, self.showResults, let w = e.window, w.attachedSheet == nil else { return e }
            if let tv = w.firstResponder as? NSTextView {
                // the reader keeps its arrows; so does any text box other than the search box
                if !tv.isFieldEditor || !((tv.delegate as AnyObject?) is SearchField.Field) { return e }
            }
            self.stepRow(e.keyCode == 125 ? 1 : -1)
            return nil
        }
    }
}
