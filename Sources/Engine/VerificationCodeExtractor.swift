import Foundation

/// Extracts verification codes from SMS message text ("验证码123456"、
/// "G-123456 is your Google verification code"、"WhatsApp code: 123-456"…).
///
/// Two-stage design:
/// 1. `isLikelyVerificationMessage` — keyword gate deciding whether the message
///    is a verification-code SMS at all. This stage guards precision: ordinary
///    messages (marketing, delivery, balance alerts) never trigger.
/// 2. `extract` — candidate mining + context exclusion + scoring. This stage is
///    tuned for recall: a wrongly picked token only shows a wrong code next to
///    the visible message, while a miss is invisible. Callers must fall back to
///    surfacing the whole message when stage 1 passes but stage 2 returns nil —
///    that fallback is the feature's real safety net, not the regexes.
///
/// Pure text logic, no system dependencies — fully unit-testable and reusable
/// for future sources (email codes etc.).
enum VerificationCodeExtractor {

    // MARK: - Public API

    /// Stage 1: does this message look like a verification-code SMS?
    static func isLikelyVerificationMessage(_ message: String) -> Bool {
        let text = normalize(clip(message))
        return !keywordRanges(in: text).isEmpty
    }

    /// Stage 2: extract the code. Returns nil when the message doesn't look like
    /// a verification SMS, or when no plausible candidate survives exclusion —
    /// in the latter case the caller should surface the full message instead.
    static func extract(from message: String) -> String? {
        let text = normalize(clip(message))
        if let code = attemptExtraction(in: text) { return code }
        // SmsCode-style fallback: CJK SMS sometimes space out the code
        // ("验证码 3 3 4 4 5 5") in shapes the grouped patterns don't cover.
        // Latin keywords contain spaces, so this pass only runs for CJK messages.
        if containsCJK(text) {
            return attemptExtraction(in: String(text.filter { !$0.isWhitespace }))
        }
        return nil
    }

    private static func attemptExtraction(in text: String) -> String? {
        let keywords = keywordRanges(in: text)
        guard !keywords.isEmpty else { return nil }

        let candidates = mineCandidates(in: text).filter { !isExcluded($0, in: text) }
        guard !candidates.isEmpty else { return nil }

        let best = candidates.max { lhs, rhs in
            let l = score(lhs, keywords: keywords, in: text)
            let r = score(rhs, keywords: keywords, in: text)
            // Tie → earlier occurrence wins
            if l == r { return lhs.range.location > rhs.range.location }
            return l < r
        }
        return best?.code
    }

    // MARK: - Stage 1: keyword gate

    /// CJK keywords matched by plain substring search (no word boundaries in CJK).
    /// Curated data, extended via the user-feedback loop; every addition must come
    /// with a corpus test case. The zh lists merge tianma8023/SmsCode's
    /// battle-tested keyword set plus templates from MessAuto's corpus
    /// ("安全代码" Microsoft、"代码为" Apple).
    private static let CJK_KEYWORDS: [String] = [
        // zh-Hans
        "验证码", "校验码", "检验码", "确认码", "激活码", "动态码", "安全码",
        "验证代码", "校验代码", "检验代码", "激活代码", "确认代码", "动态代码",
        "安全代码", "代码为", "登录码", "登入码", "认证码", "识别码", "短信码",
        "短信口令", "动态密码", "动态口令", "交易码", "上网密码", "随机码", "授权码",
        // zh-Hant
        "驗證碼", "校驗碼", "檢驗碼", "確認碼", "激活碼", "動態碼", "安全碼",
        "驗證代碼", "校驗代碼", "檢驗代碼", "確認代碼", "激活代碼", "動態代碼",
        "代碼為", "登入碼", "認證碼", "識別碼", "動態密碼", "授權碼", "啟用碼",
        // ja
        "認証コード", "確認コード", "認証番号", "確認番号",
        "ワンタイムパスワード", "セキュリティコード", "認証キー",
        // ko
        "인증번호", "인증 번호", "인증코드", "인증 코드", "확인코드",
        "확인 코드", "보안코드", "보안 코드", "인증 키",
    ]

    /// Latin/Cyrillic keywords matched with word boundaries (case-insensitive).
    /// `\botp\b` etc. need boundaries so "otp" doesn't fire inside "footpath".
    private static let LATIN_KEYWORD_PATTERN: String = {
        let alternatives = [
            "verification", "verify",
            "security code", "authentication code", "auth code", "authorization code",
            "one[- ]?time (?:password|passcode|pin|code)", "otp", "2fa", "two[- ]?factor",
            "login code", "log[- ]?in code", "sign[- ]?in code", "signin code",
            "access code", "confirmation code", "activation code", "sms code",
            "passcode", "your [a-z0-9 ]{0,15}code", "code is",
            // de
            "bestätigungscode", "sicherheitscode", "verifizierungscode",
            "einmalpasswort", "anmeldecode",
            // fr
            "code de vérification", "code de sécurité", "code de confirmation",
            "code d.authentification", "code de connexion",
            // es / pt
            "código de verificación", "código de seguridad", "código de confirmación",
            "clave de verificación", "código de verificação", "código de segurança",
            // it
            "codice di verifica", "codice di sicurezza", "codice di conferma",
            // ru
            "код подтверждения", "проверочный код", "код безопасности",
            "одноразовый пароль", "код для входа", "код авторизации",
            // id
            "kode verifikasi", "kode otp", "kode keamanan", "kode konfirmasi",
        ]
        // "code:" / "code：" separately — a trailing \b after the colon would be wrong
        return "\\b(?:" + alternatives.joined(separator: "|") + ")\\b|\\bcode[::]"
    }()

    /// All keyword occurrence ranges (used both as the gate and for proximity scoring).
    private static func keywordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []

        for keyword in CJK_KEYWORDS {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: keyword, options: [], range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = found.location + found.length
                guard next < ns.length else { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }

        if let regex = try? NSRegularExpression(pattern: LATIN_KEYWORD_PATTERN, options: [.caseInsensitive]) {
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            ranges.append(contentsOf: matches.map(\.range))
        }
        return ranges
    }

    // MARK: - Stage 2: candidate mining

    private struct Candidate {
        let code: String
        let range: NSRange
        /// Form prior: how likely this shape is a verification code at all.
        /// 6-digit is the dominant format, then 4/5-digit, then rarer shapes.
        let prior: Int
    }

    /// Mining patterns. Custom `(?<![0-9A-Za-z])` boundaries instead of `\b`:
    /// ICU treats CJK ideographs as word characters, so `\b` never fires between
    /// "码" and "1" — exactly where Chinese SMS put their codes.
    private static let MINING_PATTERNS: [(pattern: String, prior: Int, joinGroups: Bool)] = [
        // Pure digit runs, 4–8 digits ("验证码123456" / "code is 1234")
        ("(?<![0-9A-Za-z])[0-9]{4,8}(?![0-9A-Za-z])", 40, false),
        // 3-3 grouped digits, WhatsApp style ("123-456" / "123 456")
        ("(?<![0-9A-Za-z])([0-9]{3})[- ]([0-9]{3})(?![0-9A-Za-z])", 38, true),
        // 4-4 grouped digits, some banks ("1234 5678")
        ("(?<![0-9A-Za-z])([0-9]{4})[- ]([0-9]{4})(?![0-9A-Za-z])", 35, true),
        // Hyphenated code with ≥1 letter and ≥1 digit, kept whole: the hyphen is
        // part of the code (Citi "RKJ-YP6"). Pure-digit groups never land here —
        // their separator is cosmetic and the grouped patterns above join them.
        ("(?<![0-9A-Za-z-])(?=[A-Z0-9-]*[A-Z])(?=[A-Z0-9-]*[0-9])[A-Z0-9]+-[A-Z0-9]+(?![0-9A-Za-z-])", 22, false),
        // Uppercase alphanumeric with ≥1 letter and ≥1 digit ("7Q8R2" / "12345X")
        ("(?<![0-9A-Za-z])(?=[0-9A-Z]*[A-Z])(?=[0-9A-Z]*[0-9])[0-9A-Z]{4,8}(?![0-9A-Za-z])", 20, false),
    ]

    private static func mineCandidates(in text: String) -> [Candidate] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var candidates: [Candidate] = []

        for spec in MINING_PATTERNS {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                let code: String
                if spec.joinGroups {
                    code = ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2))
                } else {
                    code = ns.substring(with: match.range)
                }
                // Hyphenated pattern has unbounded segments; cap total length here
                guard code.count <= 9 else { continue }
                var prior = spec.prior
                if !spec.joinGroups, code.allSatisfy(\.isNumber) {
                    // Length-sensitive prior within pure digit runs
                    switch code.count {
                    case 6: prior = 40
                    case 4, 5: prior = 33
                    case 7: prior = 25
                    default: prior = 24
                    }
                }
                candidates.append(Candidate(code: code, range: match.range, prior: prior))
            }
        }
        return candidates
    }

    // MARK: - Stage 2: context exclusion

    /// Patterns rejecting candidates that are dates, times, amounts, durations,
    /// phone hotlines, card tails or order numbers. Checked against a short
    /// context window around the candidate.
    private static let AFTER_REJECT_PATTERNS: [String] = [
        "^[年月/\\-\\.][0-9]{1,2}",                                    // date: 2026-08 / 2026年8
        "^[::][0-9]{2}",                                               // time: 12:30
        "^\\s?(元|块|萬|万|円|港币|港幣|美元|美金|欧元|歐元|%|％)",      // amount (CJK)
        "^\\s?(usd|rmb|cny|eur|jpy|krw|dollars?|yuan)\\b",             // amount (latin)
        "^\\s?(分钟|分鐘|秒钟|秒鐘|秒|小时|小時|天)",                    // duration (CJK)
        "^\\s?(minutes?|mins?|seconds?|secs?|hours?|hrs?|days?)\\b",   // duration (latin)
    ]

    private static let BEFORE_REJECT_PATTERNS: [String] = [
        "[0-9][年月/\\-\\.]$",                                          // tail of a date
        "[0-9][::]$",                                                  // tail of a time
        "[¥￥$€£₩]\\s?$",                                              // currency symbol
        "(尾号|尾號|尾數|末四位|末尾)$",                                 // card/phone tail: 尾号8866
        "(ending (in |with )?)$",                                      // card tail (latin)
        "(电话|電話|致电|致電|拨打|撥打|热线|熱線|客服|专线|專線)[\\s::.,]{0,3}$",  // hotline
        "(hotline|call|dial|tel|phone)[\\s::.,]{0,3}$",
        "(订单|訂單|单号|單號|运单|運單|流水号|流水號)[\\s::.,]{0,3}$",     // order number
        "(order|tracking)\\s?(no\\.?|number|#)?[\\s::.,]{0,3}$",
    ]

    private static func isExcluded(_ candidate: Candidate, in text: String) -> Bool {
        let ns = text as NSString
        let start = candidate.range.location
        let end = candidate.range.location + candidate.range.length

        let beforeStart = max(0, start - 12)
        let before = ns.substring(with: NSRange(location: beforeStart, length: start - beforeStart))
        let afterLength = min(12, ns.length - end)
        let after = ns.substring(with: NSRange(location: end, length: afterLength))

        let beforeLowered = before.lowercased()
        let afterLowered = after.lowercased()

        for pattern in AFTER_REJECT_PATTERNS where afterLowered.range(of: pattern, options: [.regularExpression]) != nil {
            return true
        }
        for pattern in BEFORE_REJECT_PATTERNS where beforeLowered.range(of: pattern, options: [.regularExpression]) != nil {
            return true
        }

        // Inside an unclosed 【…】 pair → sender/brand label, not a code
        let prefix = ns.substring(to: start)
        if let open = prefix.range(of: "【", options: .backwards) {
            let closed = prefix.range(of: "】", options: .backwards)
            if closed == nil || closed!.lowerBound < open.lowerBound { return true }
        }
        return false
    }

    // MARK: - Stage 2: scoring

    /// Gap fillers that keep keyword→code adjacency intact after stripping
    /// whitespace/punctuation: "验证码是123456"、"code is 123456"、
    /// "Bestätigungscode lautet 445599"…
    private static let ADJACENCY_FILLERS: Set<String> = [
        "", "是", "为", "為", "is", "es", "e", "est", "lautet",
        "は", "です", "은", "는", "입니다",
    ]

    private static func score(_ candidate: Candidate, keywords: [NSRange], in text: String) -> Int {
        var total = candidate.prior

        var minGap = Int.max
        var nearestGapRange: NSRange?
        for keyword in keywords {
            let (gap, gapRange) = distance(candidate.range, keyword)
            if gap < minGap {
                minGap = gap
                nearestGapRange = gapRange
            }
        }
        total += max(0, 40 - minGap)

        // Adjacency bonus: keyword and code separated only by punctuation/filler
        if let gapRange = nearestGapRange, minGap <= 8 {
            let ns = text as NSString
            let gapText = ns.substring(with: gapRange)
            let stripped = String(gapText.unicodeScalars.filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }).lowercased()
            if ADJACENCY_FILLERS.contains(stripped) { total += 25 }
        }
        return total
    }

    /// UTF-16 gap between two non-overlapping ranges (0 when adjacent/overlapping),
    /// plus the range of the text between them.
    private static func distance(_ a: NSRange, _ b: NSRange) -> (gap: Int, gapRange: NSRange) {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        if aEnd <= b.location {
            return (b.location - aEnd, NSRange(location: aEnd, length: b.location - aEnd))
        }
        if bEnd <= a.location {
            return (a.location - bEnd, NSRange(location: bEnd, length: a.location - bEnd))
        }
        return (0, NSRange(location: a.location, length: 0))
    }

    // MARK: - Normalization

    /// SMS are short; clip degenerate inputs (clipboard dumps) before regex work.
    private static func clip(_ message: String) -> String {
        message.count > 1000 ? String(message.prefix(1000)) : message
    }

    /// Han / Kana / Hangul presence — gates the whitespace-stripped retry pass.
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF,    // CJK Unified Ideographs
                 0x3040...0x30FF,    // Hiragana + Katakana
                 0xAC00...0xD7AF:    // Hangul Syllables
                return true
            default:
                return false
            }
        }
    }

    /// Fullwidth digits/letters/colon → ASCII so "１２３４５６" parses like "123456".
    /// 1:1 scalar mapping, so ranges stay aligned.
    private static func normalize(_ message: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(message.unicodeScalars.count)
        for scalar in message.unicodeScalars {
            switch scalar.value {
            case 0xFF10...0xFF19:  // ０-９
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            case 0xFF21...0xFF3A:  // Ａ-Ｚ
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF21 + 0x41)!)
            case 0xFF41...0xFF5A:  // ａ-ｚ
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF41 + 0x61)!)
            case 0xFF1A:  // ：
                result.unicodeScalars.append(":")
            case 0xFF0D:  // －
                result.unicodeScalars.append("-")
            case 0x3000:  // ideographic space
                result.unicodeScalars.append(" ")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
