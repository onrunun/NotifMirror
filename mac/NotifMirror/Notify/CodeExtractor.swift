import Foundation

extension NotificationHistory.Entry {
    /// Best-guess verification code in `body`. Multilingual keyword-aware
    /// extractor ported from jd1378/otphelper (MIT — github.com/jd1378/otphelper).
    var extractedCode: String? {
        guard !body.isEmpty else { return nil }
        return CodeExtractor.shared.code(in: body)
    }

    var hasReplyAction: Bool {
        actions?.contains(where: \.isReply) ?? false
    }
}

final class CodeExtractor {
    static let shared = CodeExtractor()

    private let sensitivePhrases: [String] = [
        "code",
        #"One[-\s]Time[-\s]Password"#, #"One[-\s]Time[-\s]Code"#,
        "کد", "رمز",
        #"\bOTP\W"#, #"\b2FA\W"#,
        "Einmalkennwort",
        "contraseña", #"c[oó]digo"#, "clave", #"\bel siguiente PIN\W"#,
        "验证码", "校验码", "識別碼", "認證", "驗證",
        "код",
        "סיסמ", #"\bהקוד\W"#, #"\bקוד\W"#,
        #"\bKodu\W"#, #"\bKodunuz\W"#, #"\b[sş]ifre\W"#,
        #"\bparola\W"#, #"\bdo[ğg]rulama\W"#, #"\bonay\W"#, #"\bg[uü]venlik\W"#,
        #"\bgiri[sş]\W"#, #"\baktivasyon\W"#, #"\btek[-\s]kullan[ıi]ml[ıi]k\W"#,
        #"\bKodi\W"#, #"\bKods\W"#,
        #"\b(?:m|sms)?TAN\W"#,
        #"\bcodice\W"#,
        "コード", "パスワード", "認証番号", "ワンタイム",
        #"\bvahvistuskoodi"#, #"\bkertakäyttökoodisi\W"#,
        #"\bkod\W"#, #"\bautoryzacji\W"#,
        #"Parol\s+dlya\s+podtverzhdeniya"#, #"\bпароль\W"#,
        "인증번호",
        "code secret", "code de vérification", "code de validation",
        "code de confirmation", "mot de passe", "code de sécurité",
        "code d'accès",
        "código de verificação", "código de confirmação",
        "código de segurança", "senha", "palavra-passe",
        "verificatiecode", "bevestigingscode", "inlogcode",
        "toegangscode", "wachtwoord",
        "verifieringskod", "engångskod", "säkerhetskod", "bekräftelsekod",
        "verifiseringskode", "engangskode", "sikkerhetskode",
        "verificeringskode", "engangskode", "sikkerhedskode",
        "κωδικός", "κωδικός επαλήθευσης", "κωδικός πρόσβασης",
        "รหัส", "รหัสยืนยัน", "รหัสผ่าน", "รหัส OTP",
        "mã xác nhận", "mã xác thực", "mật khẩu", "mã OTP",
        "رمز التحقق", "رمز التأكيد", "كلمة المرور", "رمز الدخول",
        "कोड", "पासवर्ड", "ओटीपी",
        "kode verifikasi", "kode pengesahan", "kata laluan",
        "kod pengesahan", "kata sandi",
        "cod de verificare", "cod de confirmare",
        "код підтвердження", "пароль",
        "megerősítő kód", "ellenőrző kód", "jelszó",
        "ověřovací kód", "overovací kód", "heslo",
        "কোড", "পাসওয়ার্ড", "ওটিপি",
        "ઓટીપી", "કોડ", "પાસવર્ડ",
        "ಕೋಡ್", "ಪಾಸ್ವರ್ಡ್",
    ]

    private let skipPhrases: [String] = [
        "مقدار", "مبلغ", "amount", "برای", "-ارز",
        #"\bindirim\W"#, #"\bkampanya\W"#, #"\bpromosyon\W"#,
        #"\bbakiyeniz\W"#, #"\bbakiye\W"#,
        #"\bTutar\W"#, #"\bFiyat\W"#, #"\bÜcret\W"#,
        "[a-zA-Z0-9] [a-zA-Z0-9] [a-zA-Z0-9] [a-zA-Z0-9] ?",
    ]

    private let currencyIndicators: [String] = [
        "USD", "EUR", "GBP", "TRY", "TL", #"[$€£₺]"#,
    ]

    private let nonCodeIndicators: [String] = [
        #"\b\d{1,2}[./]\d{1,2}[./]?\d{0,4}\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b\d+[.,]\d{2}\b"#,
        #"\b\d{9,}\b"#,
        #"%\d+"#, #"\d+%"#,
        #"\b\d{4,6}\s?(?:K?B|MB|GB|TB)\b"#,
    ]

    private let cleanupPhrases: [String] = [
        #"[a-zA-Z0-9][a-zA-Z0-9-]{0,61}\.[a-zA-Z]{2,}(?:[.a-zA-Z]{0,3}(?=\s+)|)"#,
        #"['"]"#,
        #"Endziffer-\d+"#,
        #"Ending \d+"#,
        "<#>",
        "share OTP",
    ]

    private let ignoredPhrases: [String] = [
        "تخفیف", "takhfif", "off", "اشتباه وارد شده",
        "RatingCode", "vscode", "versionCode", "unicode",
        "discount code", "fancode", "encode", "decode",
        "barcode", "codex",
        "kargo", "takip", "sipariş", "fatura",
    ]

    private let generalMatcher: NSRegularExpression?
    private let specialMatcher: NSRegularExpression?
    private let cleanupMatcher: NSRegularExpression?
    private let ignoredMatcher: NSRegularExpression?
    private let standaloneMatcher: NSRegularExpression?
    private let bracketMatcher: NSRegularExpression?
    private let nonCodeMatcher: NSRegularExpression?

    private init() {
        let opts: NSRegularExpression.Options = [.caseInsensitive, .anchorsMatchLines]
        let sensitive = sensitivePhrases.joined(separator: "|")
        let skip = skipPhrases.joined(separator: "|")
        let currency = currencyIndicators.joined(separator: "|")

        let general = #"(\#(sensitive))(?:\s*(?!\#(skip))(?:[^\s:：܃︓﹕.'"\d٠-٩۰-۹]|[\d٠-٩۰-۹,\s]+(?:\#(currency))|[\d٠-٩۰-۹][^\d٠-٩۰-۹]))*\s*[:：܃︓﹕]?\s*(["'「]?)([\d٠-٩۰-۹a-zA-Z\-]{4,}|(?: [\d٠-٩۰-۹a-zA-Z]){4,}|)\1?(?:[^\d٠-٩۰-۹a-zA-Z]|$)"#
        let special = #"((?:[\d٠-٩۰-۹]-?){4,}(?=\s)|[\d٠-٩۰-۹ ]{4,}(?=\s)|[\d٠-٩۰-۹]{4,})[^:]*(\#(sensitive))"#
        let standalone = #"(?:^|\n)\s*(["'「\[\(\{]*)((?:[\d٠-٩۰-۹][\- ]?){3,}[\d٠-٩۰-۹])\1\s*(?:$|\n)"#
        let bracket = #"[\[\(\{]([\d٠-٩۰-۹a-zA-Z\-]{4,})[\]\)\}]"#

        self.generalMatcher = try? NSRegularExpression(pattern: general, options: opts)
        self.specialMatcher = try? NSRegularExpression(pattern: special, options: opts)
        self.standaloneMatcher = try? NSRegularExpression(pattern: standalone, options: opts)
        self.bracketMatcher = try? NSRegularExpression(pattern: bracket, options: opts)
        self.cleanupMatcher = try? NSRegularExpression(
            pattern: #"(\#(cleanupPhrases.joined(separator: "|")))"#,
            options: opts
        )
        self.ignoredMatcher = try? NSRegularExpression(
            pattern: #"\b(\#(ignoredPhrases.joined(separator: "|")))\b"#,
            options: opts
        )
        self.nonCodeMatcher = try? NSRegularExpression(
            pattern: nonCodeIndicators.joined(separator: "|"),
            options: opts
        )
    }

    func code(in body: String) -> String? {
        let bodyNs = body as NSString
        if let ignored = ignoredMatcher,
           ignored.firstMatch(in: body, range: NSRange(location: 0, length: bodyNs.length)) != nil {
            return nil
        }

        let cleaned = cleanup(body)
        let ns = cleaned as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let result = keywordBasedCode(in: cleaned, ns: ns, full: full) {
            return result
        }

        if let result = standaloneOrBracketCode(in: cleaned, ns: ns, body: body) {
            return result
        }

        return nil
    }

    private func keywordBasedCode(in cleaned: String, ns: NSString, full: NSRange) -> String? {
        if let general = generalMatcher {
            let matches = general.matches(in: cleaned, range: full)
            for m in matches where m.numberOfRanges >= 4 {
                let codeRange = m.range(at: 3)
                guard codeRange.location != NSNotFound, codeRange.length > 0 else { continue }
                let normalized = ns.substring(with: codeRange)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if !normalized.isEmpty {
                    return toEnglishNumbers(normalized)
                }
            }
        }

        if let special = specialMatcher,
           let m = special.firstMatch(in: cleaned, range: full),
           m.numberOfRanges >= 2 {
            let codeRange = m.range(at: 1)
            if codeRange.location != NSNotFound {
                let normalized = ns.substring(with: codeRange)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if !normalized.isEmpty {
                    return toEnglishNumbers(normalized)
                }
            }
        }
        return nil
    }

    private func standaloneOrBracketCode(in cleaned: String, ns: NSString, body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmed.count

        if charCount <= 6 {
            let digitsOnly = trimmed.filter { $0.isNumber || $0 == "-" || $0 == " " }
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            if digitsOnly.count >= 4, digitsOnly.count <= 8,
               digitsOnly.allSatisfy({ $0.isNumber }) {
                return toEnglishNumbers(digitsOnly)
            }
        }

        if let bracket = bracketMatcher,
           let m = bracket.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 2 {
            let codeRange = m.range(at: 1)
            if codeRange.location != NSNotFound, codeRange.length > 0 {
                let normalized = ns.substring(with: codeRange)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                let english = toEnglishNumbers(normalized)
                if !english.isEmpty,
                   english.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil {
                    return english
                }
            }
        }

        if let standalone = standaloneMatcher,
           let m = standalone.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 3 {
            let codeRange = m.range(at: 2)
            if codeRange.location != NSNotFound, codeRange.length > 0 {
                let matched = ns.substring(with: codeRange)
                let normalized = matched
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if normalized.count >= 4, normalized.count <= 8,
                   normalized.allSatisfy({ $0.isNumber }),
                   nonCodeMatcher?.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) == nil {
                    return toEnglishNumbers(normalized)
                }
            }
        }

        return nil
    }

    private func cleanup(_ str: String) -> String {
        guard let regex = cleanupMatcher else { return str }
        let ns = str as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: str, range: range, withTemplate: "")
    }

    private func toEnglishNumbers(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v >= 0x0660 && v <= 0x0669 {
                result.unicodeScalars.append(Unicode.Scalar(v - 0x0660 + 0x30)!)
            } else if v >= 0x06F0 && v <= 0x06F9 {
                result.unicodeScalars.append(Unicode.Scalar(v - 0x06F0 + 0x30)!)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
