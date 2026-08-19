import Testing
@testable import PasteMemo

/// Table-driven corpus for the SMS verification-code extractor.
///
/// Every user-reported miss gets masked and appended here as a permanent
/// regression case — the corpus is the feature's safety net, same idea as
/// LocalizationFilesTests.
@Suite("VerificationCodeExtractor Tests")
struct VerificationCodeExtractorTests {

    // MARK: - Positive corpus: (message, expected code)

    static let positiveCases: [(message: String, expected: String)] = [
        // ---- zh-Hans: mainstream mainland templates ----
        ("【淘宝网】您正在登录，验证码123456，请勿告知他人。", "123456"),
        ("【支付宝】校验码1234，您正在进行身份验证，5分钟内有效。", "1234"),
        ("【微信支付】验证码：987654，用于绑定银行卡。", "987654"),
        ("【京东】您的手机验证码为334455，请在10分钟内完成验证。", "334455"),
        ("【中国移动】动态密码668899，请勿泄露给他人。", "668899"),
        ("【12306】您的登录验证码：445566，切勿转发。", "445566"),
        ("验证码 2468 有效期10分钟，请尽快使用。", "2468"),
        ("您的验证码是112233。如非本人操作请忽略本短信。", "112233"),
        ("【百度】您的动态码为：85274196。", "85274196"),
        ("【顺丰】您的验证码为 5566，感谢使用。", "5566"),
        // Code BEFORE keyword
        ("【美团】837291（登录验证码）。工作人员不会向您索取，请勿泄露。", "837291"),
        // Parenthesized code
        ("【滴滴出行】验证码：（476982），欢迎使用滴滴。", "476982"),
        // Fullwidth digits
        ("【测试】验证码：１２３４５６", "123456"),
        // Amount + hotline distractors
        ("【工商银行】验证码123456，您正在向张*转账1000元，客服电话95588。", "123456"),
        // Card-tail distractor
        ("【招商银行】您尾号8866的储蓄卡收到验证码776655，30分钟内有效。", "776655"),
        // Date + time distractors
        ("验证码334455已发送，若非本人操作请忽略。2026-08-19 12:30", "334455"),
        // Currency-symbol distractor
        ("【银行】验证码998877，交易金额¥2000。请核对后输入。", "998877"),

        // ---- zh-Hans: real-world templates from MessAuto's corpus ----
        ("【自如网】自如验证码 356407，有效时间为一分钟，请勿将验证码告知任何人！如非您本人操作，请及时致电4001001111", "356407"),
        ("【必胜客】116352（动态验证码），请在30分钟内填写", "116352"),
        ("【智谱AI】您的验证码为210465，请于3分钟内使用，若非本人操作，请忽略本短信。", "210465"),
        ("【倒三角】易支撑（登录）——您的账号W8406772本次登录验证码为666684，请勿泄露，有效时间5分钟，如非本人操作请忽略本短信。", "666684"),
        ("【百度账号】验证码：534571 。验证码提供他人可能导致百度账号被盗，请勿转发或泄漏。", "534571"),
        ("【APPLE】Apple ID代码为：724818。请勿与他人共享。", "724818"),
        ("【Microsoft】将 12345X 初始化Microsoft账户安全代码", "12345X"),
        ("【CSDN】678571是你的验证码，有效期2分钟，切勿将验证码泄露于他人。发送时间：2025-08-19 10:20:30", "678571"),
        ("【XXX】您在2024-04-02 17:23:35登录系统的动态密码为：524678", "524678"),
        ("您好, 请确认是您本人操作，用户15670006000登录验证码为:809198，有效期5分钟。[XXX统一门户]", "809198"),
        // Spaced-out digits → whitespace-stripped retry pass
        ("【测试】您的验证码 3 3 4 4 5 5，请勿泄露。", "334455"),

        // ---- zh-Hans: templates from real chat.db validation (sanitized) ----
        // Code wrapped in fullwidth brackets AFTER the brand label (114-挂号)
        ("【北京114预约挂号】您的短信验证码为【824193】", "824193"),
        // 和包 "验证密码" wording, no "验证码" anywhere
        ("【验证密码】335577，尊敬的客户，您好！您尾号为1234的手机号将登录和包账户，有效期3分钟。若非本人操作请勿泄露，可直接回复DJZH冻结账户。【中国移动 和包】", "335577"),
        // Carrier service-password reset ("密码为")
        ("【服务密码变更提醒】尊敬的客户，您重置的服务密码为：264855。服务密码是您身份鉴权的一个重要方式，请注意妥善保管避免泄露。", "264855"),
        // "密码是" wording (途牛)
        ("【途牛旅游网】尊敬的客户，您好！您的途牛密码是：428731，您可以使用手机号登录途牛网站或App，预订您喜欢的产品和查看订单。", "428731"),
        // "操作码" wording (阿里云邮)
        ("【阿里云邮】您的邮箱(user@example.com)申请更改邮箱设置，如确认是本人行为，请正确提交以下操作码：771384", "771384"),
        // Bank transfer code with account-number distractor
        ("验证码566218，该手机交易码用于您进行贵金属积存签约交易，交易账户为：8801。【中国银行】", "566218"),
        // Leading-zero code + masked phone number distractor
        ("【验证密码】：073916。尊敬的客户，您好！您正在通过中国移动线上渠道为号码178****0000兑换3元话费兑换券。", "073916"),
        ("动态验证码为4275，尊敬的客户，您好！您正在中国移动互联网上办理会员低价合约，资费1元/月，订购立即生效，有效期12个月。", "4275"),
        // Lowercase alphanumeric codes
        ("【北京口腔健康网】正在进行注册操作，您的验证码是u7k2", "u7k2"),
        ("83nfkq2v 是你重置密码的验证码。请勿回复此短信。[PIN]", "83nfkq2v"),
        // URL fragment must not shadow the real code
        ("【测试】您的验证码为 995511，详情见 https://e.example.com/a/5m4899vD", "995511"),

        // ---- zh-Hant ----
        ("【中華電信】您的驗證碼為 224466，請於5分鐘內輸入。", "224466"),
        ("【台灣銀行】動態密碼：135790。", "135790"),

        // ---- English: major services ----
        ("G-123456 is your Google verification code.", "123456"),
        ("Your Apple Account code is: 553311. Do not share it with anyone.", "553311"),
        ("Use 1234567 as Microsoft account security code.", "1234567"),
        ("123456 is your Amazon OTP. Do not share it with anyone.", "123456"),
        ("Your WhatsApp code: 123-456. Don't share this code with others.", "123456"),
        ("Telegram code: 54321", "54321"),
        ("Your Uber code is 1234. Never share this code.", "1234"),
        ("747474 is your Facebook confirmation code", "747474"),
        ("Your X confirmation code is 998877.", "998877"),
        ("PayPal: Your security code is 112358. It expires in 10 minutes.", "112358"),
        ("Your verification code is 246810. Valid for 5 minutes.", "246810"),
        ("Enter 3344 to verify your phone number.", "3344"),
        ("Your one-time password is 90807060.", "90807060"),
        ("Your code is 5533 and expires at 12:45.", "5533"),
        // Alphanumeric codes
        ("Your Steam verification code is 7Q8R2", "7Q8R2"),
        ("Your login code is A1B2C3.", "A1B2C3"),
        // Hyphenated code kept whole — the hyphen is part of the code (Citi style)
        ("Code is: RKJ-YP6 We'll NEVER call or text for this code.", "RKJ-YP6"),
        ("Citi ID Code: 12345678 We'll NEVER call or text for this code.", "12345678"),

        // ---- ja / ko ----
        ("【楽天】認証コード：456789 をご入力ください。", "456789"),
        ("Yahoo! JAPANの確認コードは 8642 です。", "8642"),
        ("[네이버] 인증번호 [246813]를 입력해 주세요.", "246813"),
        ("카카오 인증번호는 987123 입니다.", "987123"),

        // ---- de / fr / es / ru / id ----
        ("Dein Bestätigungscode lautet 445599.", "445599"),
        ("Votre code de vérification est 778899.", "778899"),
        ("Tu código de verificación es 556677.", "556677"),
        ("Ваш код подтверждения: 334455.", "334455"),
        ("Kode verifikasi Anda adalah 221133.", "221133"),
    ]

    @Test("Extracts the code from verification SMS", arguments: positiveCases)
    func extractsCode(testCase: (message: String, expected: String)) {
        #expect(VerificationCodeExtractor.extract(from: testCase.message) == testCase.expected)
        #expect(VerificationCodeExtractor.isLikelyVerificationMessage(testCase.message))
    }

    // MARK: - Negative corpus: ordinary SMS must not trigger at all

    static let negativeCases: [String] = [
        // Package pickup code — deliberately out of scope (取件码 not a keyword)
        "【顺丰速运】您的快递已到丰巢，取件码8-3021，请及时取件。",
        // Balance / usage alerts
        "【中国联通】您本月已使用流量10.5GB，剩余2048MB。",
        "余额提醒：您尾号8866的账户余额为1234.56元。",
        // Marketing
        "【淘宝】双11狂欢，满1000减100，速来抢购！",
        // Coupon "code" must not fire ("use code SAVE20" is not verification)
        "Use code SAVE20 for 20% off your next order!",
        // Delivery / travel
        "Your package 12345678 has been delivered to the front desk.",
        "Flight CA1234 departs at 08:45 on 2026-08-19. Gate 23.",
        // Everyday chat with numbers
        "会议改到明天 14:30，地点 3021 会议室，记得带电脑。",
        // Long service notification stuffed with IDs, dates and URLs (MessAuto corpus)
        "【腾讯云】尊敬的腾讯云用户，您的账号（账号 ID：100022305033，昵称：724818342@qq.com）下有 1 个域名即将到期：xjp.asia 将于北京时间 2023-11-01 到期。域名过期三天后仍未续费，将会停止正常解析，请及时登录腾讯云进行续费：https://mc.tencent.com/N1op7G3l",
        // Marketing / spam abusing "验证码" wording — unsubscribe tail kills the gate
        // (real chat.db validation, sanitized)
        "【卡姿兰官方旗舰店】618今晚8点抢！1分钱抢包包！戳 s.tb.cn/y6.ERlOw 验证码回T退订",
        "【京红包】恭喜您，获得京东618超级红包补贴，最高20618元，打开京东APP首页输入：红包每天领 即可领取，可领三次，验证码 拒T",
        "【什么值得买】北京消费券再来！1500元大额券包！每天10点发放，买大件超值 smzdm.com/a/xxxx 回验证码N拒",
        "【天津农行】密码太长不用烦，快捷登录更安全！点击 go.abchina.com/k/0t7 立即设置。如有疑问请致电95599。退订请回TD#TJ。",
    ]

    @Test("Ordinary SMS never trigger", arguments: negativeCases)
    func ignoresOrdinarySMS(message: String) {
        #expect(!VerificationCodeExtractor.isLikelyVerificationMessage(message))
        #expect(VerificationCodeExtractor.extract(from: message) == nil)
    }

    // MARK: - Real code SMS carrying unsubscribe-looking strings

    /// The marketing-tail filter applies only to `isLikelyVerificationMessage`
    /// (fallback suppression), never to `extract` — real senders append these
    /// strings too. Callers try `extract` first, so these still deliver a code
    /// even though `isLikely` is false.
    static let tailCarryingCases: [(message: String, expected: String)] = [
        ("【盛趣游戏】账号登录短信验证码:118264.拒收请回复R", "118264"),
        ("验证码930528，仅用于咪咕帐号登录，有效期5分钟。如非本人操作，请忽略此短信。回复qx退订。 【中国移动　咪咕视频】", "930528"),
        ("【验证密码】662917，尊敬的客户，您好！您将通过线上渠道退订基础安防包-3天事件，验证码5分钟内有效，若非本人操作，请勿泄露。【中国移动智慧家庭】", "662917"),
    ]

    @Test("Unsubscribe tails never block extraction", arguments: tailCarryingCases)
    func extractsDespiteUnsubscribeTail(testCase: (message: String, expected: String)) {
        #expect(VerificationCodeExtractor.extract(from: testCase.message) == testCase.expected)
    }

    // MARK: - Fallback path: looks like a code SMS but no extractable code

    static let fallbackCases: [String] = [
        // Voice-call delivery — keyword present, no code in the message
        "您的验证码已通过语音电话告知，请注意接听。",
        // Code went to another device; the only digits are a phone tail
        "验证码已发送至您尾号5566的手机，请查收。",
    ]

    @Test("Keyword hit without code returns nil (caller shows full message)", arguments: fallbackCases)
    func fallsBackToFullMessage(message: String) {
        #expect(VerificationCodeExtractor.isLikelyVerificationMessage(message))
        #expect(VerificationCodeExtractor.extract(from: message) == nil)
    }

    // MARK: - Exclusion rules (unit-level)

    @Test("Rejects year in date context")
    func rejectsDate() {
        #expect(VerificationCodeExtractor.extract(from: "您的验证码将于2026-09-01后失效，码为445533。") == "445533")
    }

    @Test("Rejects hotline number next to keyword")
    func rejectsHotline() {
        #expect(VerificationCodeExtractor.extract(from: "登录验证码887766，如有疑问请致电95588。") == "887766")
    }

    @Test("Rejects duration digits")
    func rejectsDuration() {
        #expect(VerificationCodeExtractor.extract(from: "验证码665544，3600秒内有效。") == "665544")
    }

    @Test("Rejects order number context")
    func rejectsOrderNumber() {
        #expect(VerificationCodeExtractor.extract(from: "您的订单号88776655已发货，收货验证码1122。") == "1122")
    }

    @Test("Rejects digits inside brand brackets")
    func rejectsBrandBrackets() {
        #expect(VerificationCodeExtractor.extract(from: "【95588】您的验证码123456，请勿泄露。") == "123456")
    }

    // MARK: - Robustness

    @Test("Empty and whitespace input")
    func emptyInput() {
        #expect(VerificationCodeExtractor.extract(from: "") == nil)
        #expect(VerificationCodeExtractor.extract(from: "   \n  ") == nil)
        #expect(!VerificationCodeExtractor.isLikelyVerificationMessage(""))
    }

    @Test("Oversized input is clipped, not scanned")
    func oversizedInput() {
        let huge = String(repeating: "x", count: 50_000) + " 验证码123456"
        // Code lies beyond the clip window → treated as not-a-code-SMS
        #expect(VerificationCodeExtractor.extract(from: huge) == nil)
        // But a code within the window still extracts
        let headCode = "验证码654321 " + String(repeating: "x", count: 50_000)
        #expect(VerificationCodeExtractor.extract(from: headCode) == "654321")
    }

    @Test("Message with keyword but only overlong digits returns nil")
    func overlongDigits() {
        #expect(VerificationCodeExtractor.extract(from: "验证码已发送，流水号123456789012。") == nil)
    }
}
