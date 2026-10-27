//  HoverTranslator
//  鼠标悬停任意位置 -> 截图OCR识别光标下的英文单词 -> 美音朗读 + 原生悬浮窗显示中文翻译
//  覆盖：PDF / Word / 网页 / 图片（扫描件）任意位置
//  技术：Swift + AppKit + Vision + ScreenCaptureKit + AVSpeechSynthesizer
//
//  修复要点（相对旧版）：
//   1. 所有 AppKit / UI 操作严格在主线程（旧版 showPanel 在 URLSession 回调线程、
//      NSAlert 在 async 后台任务里创建，必崩：SIGTRAP / SIGABRT）
//   2. 悬停触发改为「一次静止只触发一次」状态机 + 单飞保护；旧版每 0.18s 起一个
//      截图任务，鼠标一停就并发几十个 SCK 截图 + 几十次网络请求
//   3. OCR 改为「光标正下方的单词」：用 VNRecognizedText.boundingBox(for:) 逐词定位，
//      不再取第一个识别结果（旧版会把整行 "Hello world" 当单词朗读/翻译）
//   4. 坐标按显示器 + Retina 倍率换算，支持多显示器 / 菜单栏 / 全屏 Space
//   5. 屏幕录制权限：CGPreflightScreenCaptureAccess 预检，只请求一次、不刷屏，
//      自动轮询重试；悬浮窗 ignoresMouseEvents 避免挡住悬停
//   6. 翻译：本机实测 Google 被墙（TCP 超时），改为 有道(0.15s) -> MyMemory -> Google
//      自动降级 + 缓存 + 超时
//
//  命令行自检（无需屏幕录制权限）：
//    --selftest            渲染测试图并跑完整 OCR 取词流程（会打印选中的词）
//    --test-translate W    测试翻译链路
//    --test-tts W          测试朗读
//    --check-permission    打印屏幕录制授权状态

import Cocoa
import Vision
import AVFoundation
import ScreenCaptureKit
import CoreText
import ImageIO
import CFNetwork

// MARK: - 可调参数
enum Cfg {
    static let pollInterval: TimeInterval = 0.10      // 鼠标轮询
    static let hoverDelay: TimeInterval = 0.45        // 静止多久触发
    static let cropHalfW: CGFloat = 110               // 截图半宽(pt)
    static let cropHalfH: CGFloat = 30                // 截图半高(pt)
    static let panelW: CGFloat = 360
    static let panelH: CGFloat = 96
    static let panelHWithContext: CGFloat = 156
    static let panelAutoHide: TimeInterval = 3.6
    static let awayHideDelay: TimeInterval = 1.0      // 光标移开后多久隐藏面板
    static let awayDistance: CGFloat = 28             // 离开多远离算"移开"
    static let sameWordSpeakCooldown: TimeInterval = 1.2
    static let permissionRetryInterval: TimeInterval = 5.0
    static let maxPermissionRetries = 24              // 约 2 分钟
}

func log(_ msg: String) {
    NSLog("HoverTranslator: %@", msg)
}

// MARK: - OCR：找出光标正下方的英文单词
struct OCRHit {
    let word: String        // 光标下的词
    let phrase: String      // 连续大写的专有名词短语（New York / Albert Einstein），普通词 == word
}

enum OCR {
    // 本机实测：部分 macOS 版本 / 无 GPU 上下文时 .accurate 会直接抛 nilError，
    // 所以启动时探测一次，不可用就自动降到 .fast（对屏幕小字完全够用）。
    private static let calibLock = NSLock()
    private static var calibratedLevel: VNRequestTextRecognitionLevel?

    nonisolated static func recognitionLevel() -> VNRequestTextRecognitionLevel {
        calibLock.lock(); defer { calibLock.unlock() }
        if let level = calibratedLevel { return level }
        let level: VNRequestTextRecognitionLevel = probe(.accurate) ? .accurate : .fast
        calibratedLevel = level
        log("OCR 识别级别 = \(level == .accurate ? "accurate" : "fast")")
        return level
    }

    /// 用一张内置小图探测某个识别级别是否真的能跑
    nonisolated static func probe(_ level: VNRequestTextRecognitionLevel) -> Bool {
        let w = 240, h = 60
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
        let attr = NSAttributedString(string: "hello", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 12, y: 18)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
            return !(request.results?.isEmpty ?? true)
        } catch {
            return false
        }
    }

    /// 光标坐标使用「左上角为原点、y 向下」的图像像素坐标。
    nonisolated static func word(in image: CGImage, at cursor: CGPoint) -> OCRHit? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel()
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log("OCR 失败: \(error.localizedDescription)")
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        var best: (word: String, phrase: String, distance: CGFloat)?

        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string
            for range in wordRanges(in: text) {
                let token = String(text[range])
                let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
                guard stripped.count >= 2 else { continue }
                // 逐词拿精确包围盒：比按整行估算准得多，才能选到"光标下的词"
                guard let wordBox = box(for: range, in: cand, imageWidth: imgW, imageHeight: imgH) else { continue }
                let d = distance(from: cursor, to: wordBox)
                if best == nil || d < best!.distance {
                    best = (token, phrase(around: range, in: text), d)
                }
            }
        }
        guard let best else { return nil }
        // 光标必须真的落在某个词附近：否则悬停在中文/空白/行距处时，
        // 会误取几十点外最近的英文词（实测悬停"文件"会误报 Harness）
        let maxDistance = imgW * 0.12
        guard best.distance <= maxDistance else { return nil }
        return OCRHit(word: best.word, phrase: best.phrase)
    }

    // MARK: 专有名词短语（用于补充"背景解释"）
    nonisolated static func tokens(in text: String) -> [(range: Range<String.Index>, word: String)] {
        wordRanges(in: text).map { ($0, String(text[$0])) }
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "in", "on", "at", "of", "to", "for", "and", "or", "but", "nor", "so",
        "yet", "as", "by", "with", "from", "into", "onto", "over", "under", "up", "down", "out",
        "off", "then", "than", "that", "this", "these", "those", "is", "are", "was", "were", "be",
        "been", "being", "has", "have", "had", "do", "does", "did", "will", "would", "shall",
        "should", "can", "could", "may", "might", "must", "i", "you", "he", "she", "it", "we",
        "they", "my", "your", "his", "her", "its", "our", "their", "not", "no", "yes", "if",
        "when", "while", "because", "before", "after", "during", "about", "against", "between",
        "among", "through", "per", "via", "vs", "etc", "e.g", "i.e", "also", "just", "only"
    ]

    nonisolated static func isProperToken(_ token: String) -> Bool {
        guard let first = token.first, first.isUppercase, token.count >= 2 else { return false }
        return !stopwords.contains(token.lowercased())
    }

    /// 以光标下的词为中心，向左右扩展连续的大写词，拼出 New York / Albert Einstein 这类短语
    nonisolated static func phrase(around range: Range<String.Index>, in text: String) -> String {
        let toks = tokens(in: text)
        guard let idx = toks.firstIndex(where: { $0.range == range }) else { return String(text[range]) }
        var lo = idx, hi = idx
        while lo > 0 {
            let prev = toks[lo - 1]
            let between = text[prev.range.upperBound..<toks[lo].range.lowerBound]
            guard between.allSatisfy({ $0 == " " }), isProperToken(prev.word) else { break }
            lo -= 1
        }
        while hi + 1 < toks.count {
            let next = toks[hi + 1]
            let between = text[toks[hi].range.upperBound..<next.range.lowerBound]
            guard between.allSatisfy({ $0 == " " }), isProperToken(next.word) else { break }
            hi += 1
        }
        return toks[lo...hi].map(\.word).joined(separator: " ")
    }

    /// Vision 归一化坐标（原点左下）-> 左上原点的像素矩形
    nonisolated static func box(for range: Range<String.Index>,
                                in cand: VNRecognizedText,
                                imageWidth: CGFloat,
                                imageHeight: CGFloat) -> CGRect? {
        let maybeObservation: VNRectangleObservation?
        do {
            maybeObservation = try cand.boundingBox(for: range)
        } catch {
            return nil
        }
        guard let box = maybeObservation?.boundingBox else { return nil }
        return CGRect(x: box.minX * imageWidth,
                      y: (1.0 - box.maxY) * imageHeight,
                      width: box.width * imageWidth,
                      height: box.height * imageHeight)
    }

    /// 在字符串里找英文单词（允许 don't / well-known 这类连接符）
    nonisolated static func wordRanges(in text: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z]+(?:['’\\-][A-Za-z]+)*") else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return re.matches(in: text, range: full).compactMap { Range($0.range, in: text) }
    }

    nonisolated static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        if r.contains(p) { return 0 }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return sqrt(dx * dx + dy * dy)
    }
}

// MARK: - 屏幕捕获（与 app 内悬停路径共用同一套坐标换算）
struct DisplayInfo {
    let filter: SCContentFilter
    let points: CGSize          // 逻辑尺寸(pt)
    let scale: CGFloat          // Retina 倍率
    let flippedFrame: CGRect    // 以主屏左上为原点的全局坐标(y 向下)
}

enum ScreenGrabber {
    nonisolated static func loadDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.compactMap { makeInfo($0) }
    }

    /// 逻辑尺寸 / Retina 倍率从 NSScreen 取（SCDisplay.width 的口径在不同 macOS 版本不一致）
    nonisolated static func makeInfo(_ display: SCDisplay) -> DisplayInfo? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first {
            (($0.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0) == display.displayID
        }
        let points = screen?.frame.size ?? CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        let scale = screen?.backingScaleFactor ?? 2
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? points.height
        let flippedY = screen.map { mainHeight - $0.frame.maxY } ?? 0
        let flippedX = screen?.frame.minX ?? 0
        let flipped = CGRect(x: flippedX, y: flippedY, width: points.width, height: points.height)
        return DisplayInfo(filter: filter, points: points, scale: scale, flippedFrame: flipped)
    }

    nonisolated static func display(for p: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.flippedFrame.contains(p) } ?? displays.first
    }

    /// 抓光标周围一块区域，并返回「光标正下方的英文单词」
    /// cursor 使用全局坐标（主屏左上原点，y 向下）；SCK 的 sourceRect 也是左上原点
    nonisolated static func grabWord(at cursor: CGPoint,
                                     display info: DisplayInfo) async throws -> (image: CGImage, hit: OCRHit?) {
        let halfW = Cfg.cropHalfW, halfH = Cfg.cropHalfH
        let local = CGPoint(x: cursor.x - info.flippedFrame.minX,
                            y: cursor.y - info.flippedFrame.minY)
        let bounds = CGRect(origin: .zero, size: info.points)
        let rect = CGRect(x: local.x - halfW, y: local.y - halfH,
                          width: halfW * 2, height: halfH * 2).intersection(bounds)
        guard rect.width >= 16, rect.height >= 8 else {
            throw NSError(domain: "HoverTranslator", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "裁剪区域过小（光标贴边）"])
        }

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int(rect.width * info.scale))
        config.height = max(1, Int(rect.height * info.scale))
        config.scalesToFit = false
        config.capturesAudio = false
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: info.filter, configuration: config)
        let cursorInImage = CGPoint(x: (local.x - rect.minX) * info.scale,
                                    y: (local.y - rect.minY) * info.scale)
        let hit = await Task.detached(priority: .userInitiated) {
            OCR.word(in: image, at: cursorInImage)
        }.value
        return (image, hit)
    }
}

// MARK: - 翻译
// 设计要点（都是本机实测踩出来的）：
//  · 系统代理指向 Clash(127.0.0.1:7897)。旧版所有请求都走系统代理，
//    一旦 Clash 退出/切节点/全局模式，三条链路会一起失败 —— 这是"经常联网失败"的主因。
//    → 现在有道、MyMemory 都优先用「直连会话」（connectionProxyDictionary 置空字典 = 绕过系统代理），
//      只有直连失败时才用跟随系统代理的会话重试一次，两种网络环境都能用。
//  · Google 在本机完全不可用：直连必然超时、走代理返回 429 验证页。只作最后兜底，且超时给 2.5s。
//  · 有道没收录的生造词（如 enshittification），MyMemory 机翻常原样返回英文。
//    → 这种情况必须显示「词典未收录」，旧版却报成「网络获取失败」，把用户误导成网络问题。

struct Translation {
    let text: String
    let phonetic: String?
    let isMachine: Bool
    let displayWord: String?      // 纠错/补全后的完整单词（如 OCR 截断的 transla -> translate）
    let fallbackContext: String?  // 有道"网络释义"里的背景摘要（维基不可用时兜底）
}

enum TranslationOutcome {
    case ok(Translation)
    case noResult                    // 接口正常，但没有这个词的释义
    case network(String)             // 真正的网络层失败
}

private struct FetchResult {
    var text: String?
    var phonetic: String?
    var correctedWord: String?
    var context: String?          // 有道网络释义摘要（背景兜底）
    var transportError: Error?
    var gotHTTP: Bool = false
    var status: Int = 0
}

private struct RawResponse {
    var data: Data?
    var status: Int = 0
    var gotHTTP: Bool = false
    var transportError: Error?
}

actor Translator {
    private let direct: URLSession     // 绕过系统代理（有道/MyMemory 直连更稳）
    private let proxied: URLSession    // 跟随系统代理（直连失败时兜底）
    private var cache: [String: Translation] = [:]
    private var negativeUntil: [String: Date] = [:]
    private var lastYoudaoAt = Date.distantPast
    private var googleCooldownUntil: Date?     // Google 连续失败后熔断，避免每个生词都白等
    private let logURL: URL

    init() {
        direct = Translator.makeSession(bypassProxy: true, timeout: 4)
        proxied = Translator.makeSession(bypassProxy: false, timeout: 4)
        logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/HoverTranslator.log")
    }

    private static func makeSession(bypassProxy: Bool, timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        ]
        if bypassProxy {
            // 空字典 = 不使用任何代理（实测可绕过系统代理）
            c.connectionProxyDictionary = [AnyHashable: Any]()
        }
        return URLSession(configuration: c)
    }

    // MARK: 对外入口
    func translate(_ word: String) async -> TranslationOutcome {
        let key = word.lowercased()
        if let hit = cache[key] { return .ok(hit) }
        if let until = negativeUntil[key], Date() < until { return .noResult }

        let t0 = Date()

        // MyMemory 慢（0.6~2.5s），先并行发出；有道快（0.05s），命中就立刻取消它
        let mtTask = Task { await self.mymemory(word) }
        let dict = await youdao(word)
        if let text = dict.text, !text.isEmpty {
            mtTask.cancel()
            let t = Translation(text: text, phonetic: dict.phonetic, isMachine: false,
                                displayWord: dict.correctedWord, fallbackContext: dict.context)
            cache[key] = t
            negativeUntil.removeValue(forKey: key)
            appendLog("OK   word=\(key) src=dict \(String(format: "%.2f", Date().timeIntervalSince(t0)))s \(t.text.prefix(50))")
            return .ok(t)
        }
        let mt = await mtTask.value

        var sawHTTP = dict.gotHTTP || mt.gotHTTP
        let outcome: TranslationOutcome

        if let text = mt.text, !text.isEmpty, text.lowercased() != key {
            outcome = .ok(Translation(text: text, phonetic: nil, isMachine: true, displayWord: nil, fallbackContext: nil))
        } else {
            // 最后兜底：Google（境外直连可用；国内基本失败，失败后熔断 10 分钟）
            var g = FetchResult()
            if let until = googleCooldownUntil, Date() < until {
                // 熔断中，跳过
            } else {
                g = await google(word)
                if g.transportError != nil && !g.gotHTTP {
                    googleCooldownUntil = Date().addingTimeInterval(600)
                } else if g.text != nil {
                    googleCooldownUntil = nil
                }
            }
            sawHTTP = sawHTTP || g.gotHTTP
            if let text = g.text, !text.isEmpty, text.lowercased() != key {
                outcome = .ok(Translation(text: text, phonetic: nil, isMachine: true, displayWord: nil, fallbackContext: nil))
            } else if !sawHTTP {
                let detail = (dict.transportError ?? mt.transportError ?? g.transportError)?.localizedDescription ?? "未知错误"
                outcome = .network(detail)
            } else {
                outcome = .noResult
            }
        }

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(t0))
        switch outcome {
        case .ok(let t):
            cache[key] = t
            negativeUntil.removeValue(forKey: key)
            appendLog("OK   word=\(key) src=\(t.isMachine ? "MT" : "dict") \(elapsed)s \(t.text.prefix(50))")
        case .noResult:
            negativeUntil[key] = Date().addingTimeInterval(60)
            appendLog("NONE word=\(key) \(elapsed)s 词典未收录")
        case .network(let reason):
            appendLog("NETFAIL word=\(key) \(elapsed)s \(reason)")
        }
        return outcome
    }

    // MARK: 有道：jsonapi 优先（释义全、带音标），suggest 兜底
    private func youdao(_ word: String) async -> FetchResult {
        var result = FetchResult()

        // 轻微节流，避免超快速悬停把接口打爆
        let wait = 0.08 - Date().timeIntervalSince(lastYoudaoAt)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastYoudaoAt = Date()

        // 1) jsonapi：词条全，带美音音标
        if let url = makeURL("https://dict.youdao.com/jsonapi", [("q", word)]) {
            let r = await fetchPreferred(url, retries: 1)
            result.gotHTTP = r.gotHTTP
            result.transportError = r.transportError
            result.status = r.status
            if let data = r.data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let parsed = parseJSONAPI(json, word: word)
                result.phonetic = parsed.phonetic
                result.context = parseWebTrans(json, word: word)
                if let text = parsed.text, !text.isEmpty {
                    result.text = unescape(text)
                    return result
                }
            }
        }

        // 2) 纠错：OCR 把长词截断时（transla -> translate），用 typos 补全
        if let url = makeURL("https://dict.youdao.com/jsonapi", [("q", word)]) {
            let r = await fetchPreferred(url, retries: 0)
            if let data = r.data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let typos = json["typos"] as? [String: Any],
               let candidates = typos["typo"] as? [[String: Any]] {
                let q = word.lowercased()
                for cand in candidates {
                    guard let cw = cand["word"] as? String,
                          let trans = cand["trans"] as? String else { continue }
                    let c = cw.lowercased()
                    let prefix = c.hasPrefix(q) && c.count > q.count && c.count - q.count <= 8
                    let suffix = c.hasSuffix(q) && c.count > q.count && c.count - q.count <= 8
                    guard prefix || suffix else { continue }
                    result.text = unescape(trans.replacingOccurrences(of: " | ", with: "；"))
                    result.correctedWord = cw
                    return result
                }
            }
        }

        // 3) suggest：更轻量，个别词只有它有条目
        if let url = makeURL("https://dict.youdao.com/suggest", [("num", "1"), ("doctype", "json"), ("q", word)]) {
            let r = await fetchPreferred(url, retries: 1)
            result.gotHTTP = result.gotHTTP || r.gotHTTP
            if result.transportError == nil { result.transportError = r.transportError }
            if let data = r.data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let entries = dataObj["entries"] as? [[String: Any]],
               let first = entries.first,
               let rawEntry = first["entry"] as? String {
                // 关键：只接受「词形一致」或「查询词是它的前缀/后缀」的条目。
                // 有道会自动纠错成无关词（delulu -> delugu「大洪水」），那种必须拒绝；
                // 但 OCR 截断（transla -> translate）属于同类词，可以补全。
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                let q = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let e = entry.lowercased()
                let exact = (e == q)
                let truncated = (e.hasPrefix(q) || e.hasSuffix(q)) && e.count > q.count && e.count - q.count <= 8
                guard exact || truncated else { return result }
                if let explain = first["explain"] as? String, !explain.isEmpty {
                    result.text = unescape(explain)
                    result.correctedWord = exact ? nil : entry
                    return result
                }
                result.text = unescape(entry)
                result.correctedWord = exact ? nil : entry
                return result
            }
        }
        return result
    }

    // MARK: jsonapi 解析（兼容两种 trs 结构，并校验词条匹配）
    private func parseJSONAPI(_ json: [String: Any], word: String) -> (text: String?, phonetic: String?) {
        guard let ec = json["ec"] as? [String: Any],
              let words = ec["word"] as? [[String: Any]],
              let first = words.first else { return (nil, nil) }

        // 校验返回的是不是查询词本身（有道有时会自动纠错到别的词）
        if let phrase = phraseString(first["return-phrase"]) {
            let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, normalized != word.lowercased() { return (nil, nil) }
        }

        var phonetic: String?
        if let us = first["usphone"] as? String, !us.isEmpty { phonetic = us }
        else if let uk = first["ukphone"] as? String, !uk.isEmpty { phonetic = uk }

        var defs: [String] = []
        if let trs = first["trs"] { collectDefinitions(trs, into: &defs) }
        var seen = Set<String>()
        let unique = defs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return (unique.isEmpty ? nil : unique.joined(separator: "；"), phonetic)
    }

    /// 有道 web_trans（网络释义）里挑一条像"百科式介绍"的句子，作为背景兜底
    private func parseWebTrans(_ json: [String: Any], word: String) -> String? {
        guard let wt = json["web_trans"] as? [String: Any],
              let items = wt["web-translation"] as? [[String: Any]] else { return nil }
        let q = word.lowercased()
        var best: (score: Int, text: String)?

        for item in items {
            let same = (item["@same"] as? String) == "true"
            guard let transList = item["trans"] as? [[String: Any]] else { continue }
            for tr in transList {
                let value = (tr["value"] as? String) ?? ""
                let lines = ((tr["summary"] as? [String: Any])?["line"] as? [String]) ?? []
                for raw in lines {
                    var text = stripTags(raw)
                    guard text.count >= 16, text.count <= 220 else { continue }
                    guard !text.contains("..."), !text.contains("…") else { continue }
                    let startsWithValue = !value.isEmpty && text.hasPrefix(value)
                    let containsValue = !value.isEmpty && text.contains(value)
                    let mentionsWord = text.lowercased().contains(q)
                    guard startsWithValue || containsValue || mentionsWord else { continue }
                    // 明显的网文碎片/对话内容通常没有"是/位于/是…的"这类定义句式
                    let definitionLike = text.contains("是") || text.contains("位于") || text.contains("被称为")
                    guard definitionLike else { continue }
                    var score = startsWithValue ? 0 : (containsValue ? 1 : 2)
                    if !same { score += 3 }
                    if let b = best, b.score <= score { continue }
                    best = (score, text)
                }
            }
        }
        return best.map { shorten($0.text, maxChars: 70) }
    }

    private func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<b>", with: "")
        out = out.replacingOccurrences(of: "</b>", with: "")
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shorten(_ s: String, maxChars: Int) -> String {
        if s.count <= maxChars { return s }
        let prefix = String(s.prefix(maxChars))
        if let cut = prefix.lastIndex(where: { "。！？；".contains($0) }) {
            return String(prefix[...cut])
        }
        return prefix + "…"
    }

    private func phraseString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let d = value as? [String: Any],
           let l = d["l"] as? [String: Any],
           let i = l["i"] as? String { return i }
        return nil
    }

    /// 递归收集所有 {"i": [...]} 里的释义：
    /// 有的词条是 [[{"l":{"i":[...]}}]]，有的是 [{"tr":[{"l":{"i":[...]}}]}]，都要兼容。
    private func collectDefinitions(_ node: Any, into defs: inout [String]) {
        if let dict = node as? [String: Any] {
            for (k, v) in dict {
                if k == "i" {
                    if let arr = v as? [String] { defs.append(contentsOf: arr) }
                    else if let s = v as? String { defs.append(s) }
                } else {
                    collectDefinitions(v, into: &defs)
                }
            }
        } else if let arr = node as? [Any] {
            for item in arr { collectDefinitions(item, into: &defs) }
        }
    }

    // MARK: MyMemory 机翻（覆盖有道没有的新词，慢但直连可用）
    private func mymemory(_ word: String) async -> FetchResult {
        var result = FetchResult()
        guard let url = makeURL("https://api.mymemory.translated.net/get", [
            ("q", word), ("langpair", "en|zh-CN")
        ]) else { return result }
        let r = await fetchPreferred(url, retries: 1, timeoutOverride: 6)
        result.gotHTTP = r.gotHTTP
        result.transportError = r.transportError
        result.status = r.status
        if let data = r.data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rd = json["responseData"] as? [String: Any],
           let text = rd["translatedText"] as? String {
            let cleaned = unescape(text)
            if !cleaned.isEmpty, cleaned.lowercased() != word.lowercased() {
                result.text = cleaned
            }
        }
        return result
    }

    // MARK: Google（最后兜底）
    private func google(_ word: String) async -> FetchResult {
        var result = FetchResult()
        guard let url = makeURL("https://translate.googleapis.com/translate_a/single", [
            ("client", "gtx"), ("sl", "en"), ("tl", "zh-CN"), ("dt", "t"), ("q", word)
        ]) else { return result }
        let r = await fetch(direct, url, retries: 0, timeoutOverride: 1.8)
        result.gotHTTP = r.gotHTTP
        result.transportError = r.transportError
        result.status = r.status
        if let data = r.data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
           let seg = json.first as? [[Any]] {
            let text = seg.compactMap { $0.first as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.text = unescape(text) }
        }
        return result
    }

    // MARK: 网络诊断
    func diagnose() async -> String {
        var lines: [String] = []

        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            let on = (settings["HTTPEnable"] as? Int) ?? 0
            let host = (settings["HTTPProxy"] as? String) ?? ""
            let port = (settings["HTTPPort"] as? Int) ?? 0
            lines.append(on == 1 ? "系统代理：\(host):\(port)（翻译已改为直连优先，不依赖它）" : "系统代理：未启用")
        } else {
            lines.append("系统代理：读取失败")
        }

        if let url = makeURL("https://dict.youdao.com/suggest", [("num", "1"), ("doctype", "json"), ("q", "hello")]) {
            let t0 = Date()
            let r = await fetchPreferred(url, retries: 0)
            lines.append("有道（直连优先）：\(describe(r))  \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        }
        if let url = makeURL("https://api.mymemory.translated.net/get", [("q", "hello"), ("langpair", "en|zh-CN")]) {
            let t0 = Date()
            let r = await fetchPreferred(url, retries: 0, timeoutOverride: 6)
            lines.append("MyMemory：\(describe(r))  \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        }
        if let url = makeURL("https://translate.googleapis.com/translate_a/single", [
            ("client", "gtx"), ("sl", "en"), ("tl", "zh-CN"), ("dt", "t"), ("q", "hello")
        ]) {
            let t0 = Date()
            let r = await fetch(direct, url, retries: 0, timeoutOverride: 1.8)
            lines.append("Google（仅兜底）：\(describe(r))  \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        }
        lines.append("详细日志：~/Library/Logs/HoverTranslator.log")
        return lines.joined(separator: "\n")
    }

    private func describe(_ r: RawResponse) -> String {
        if r.gotHTTP { return "HTTP \(r.status)" }
        let msg = (r.transportError as NSError?)?.localizedDescription ?? "未知错误"
        return "网络错误（\(String(msg.prefix(40)))）"
    }

    // MARK: HTTP 基础设施
    private func fetchPreferred(_ url: URL, retries: Int, timeoutOverride: TimeInterval? = nil) async -> RawResponse {
        var r = await fetch(direct, url, retries: retries, timeoutOverride: timeoutOverride)
        if r.transportError != nil && !r.gotHTTP {
            // 有些网络必须走代理：直连失败时再跟随系统代理试一次
            let p = await fetch(proxied, url, retries: 0, timeoutOverride: timeoutOverride)
            if p.gotHTTP { return p }
            if r.transportError == nil { r.transportError = p.transportError }
        }
        return r
    }

    private func fetch(_ session: URLSession, _ url: URL, retries: Int,
                       timeoutOverride: TimeInterval? = nil) async -> RawResponse {
        var lastError: Error?
        var attempt = 0
        while attempt <= retries {
            if Task.isCancelled { return RawResponse(transportError: CancellationError()) }
            var req = URLRequest(url: url)
            req.timeoutInterval = timeoutOverride ?? session.configuration.timeoutIntervalForRequest
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if code == 200 {
                    return RawResponse(data: data, status: code, gotHTTP: true)
                }
                // 429/5xx 稍等重试一次
                if attempt < retries, code == 429 || (500...599).contains(code) {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                return RawResponse(data: nil, status: code, gotHTTP: true)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return RawResponse(transportError: CancellationError())
                }
                lastError = error
                if attempt < retries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                break
            }
        }
        return RawResponse(data: nil, status: 0, gotHTTP: false, transportError: lastError)
    }

    private func makeURL(_ base: String, _ items: [(String, String)]) -> URL? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.url
    }

    private func unescape(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 日志（出问题时可让用户把日志发来）
    private func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 512 * 1024 {
            try? fm.removeItem(at: logURL)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - 背景补充（人名 / 地名 / 机构等专有名词）
// 中文维基百科首句 = 最稳定的「它是什么、在哪、为什么重要」；国内直连被墙，走系统代理。
// 代理不可用时退回有道 web_trans 摘要（随翻译请求一起返回，不额外联网）。
actor Enricher {
    private let session: URLSession          // 跟随系统代理；没有代理时即直连
    private var cache: [String: String?] = [:]
    private var lastRequestAt = Date.distantPast
    private let logURL: URL

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 5
        c.httpAdditionalHeaders = ["User-Agent": "HoverTranslator/1.3 (macOS)"]
        session = URLSession(configuration: c)

        logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/HoverTranslator.log")
    }

    func explain(_ phrase: String) async -> String? {
        let key = phrase.lowercased()
        if let cached = cache[key] { return cached }
        guard phrase.count >= 2 else { return nil }

        // 轻微节流，避免快速悬停时打太多请求
        let wait = 0.5 - Date().timeIntervalSince(lastRequestAt)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequestAt = Date()

        let text = await wikipedia(phrase)
        cache[key] = text
        if let text { appendLog("CTX  \(phrase) -> \(String(text.prefix(40)))") }
        return text
    }

    private func wikipedia(_ phrase: String) async -> String? {
        var comps = URLComponents(string: "https://zh.wikipedia.org/w/api.php")
        comps?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: phrase),
            URLQueryItem(name: "gsrlimit", value: "1"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exsentences", value: "2"),
            URLQueryItem(name: "variant", value: "zh-cn"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        guard let url = comps?.url else { return nil }

        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let first = pages.first,
              let extract = first["extract"] as? String else { return nil }
        let cleaned = shorten(stripMarkup(extract))
        return cleaned.count >= 12 ? cleaned : nil
    }

    private func stripMarkup(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\\[[0-9]+\\]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shorten(_ s: String) -> String {
        var text = s
        // 去掉开头的外文名/读音括号，例如「巴黎（法语：Paris，发音：[paʁi] ）是…」->「巴黎是…」
        if let re = try? NSRegularExpression(pattern: "^([^（(]{1,20})[（(][^）)]{0,40}[）)]\\s*"),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
           let r = Range(m.range(at: 1), in: text) {
            let head = String(text[r])
            let tail = String(text[text.index(text.startIndex, offsetBy: m.range.location + m.range.length)...])
            if !head.isEmpty, !tail.isEmpty { text = head + tail }
        }
        let maxChars = 70
        if text.count <= maxChars { return text }
        let prefix = String(text.prefix(maxChars))
        if let cut = prefix.lastIndex(where: { "。！？；".contains($0) }) { return String(prefix[...cut]) }
        return prefix + "…"
    }

    private func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 512 * 1024 {
            try? fm.removeItem(at: logURL)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - 主程序
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var statusLine: NSMenuItem!
    private var panel: NSPanel!
    private var enLabel: NSTextField!
    private var zhLabel: NSTextField!
    private var contextLabel: NSTextField!
    private let synth = AVSpeechSynthesizer()
    private let translator = Translator()
    private let enricher = Enricher()

    private var displays: [DisplayInfo] = []
    private var captureReady = false
    private var permissionRequested = false
    private var failedAlertsShown = false

    private var lastMouse: CGPoint = CGPoint(x: -1, y: -1)
    private var lastMoveAt = Date()
    private var armed = false      // 鼠标已静止、但本次静止还没触发过
    private var busy = false       // 单飞保护：同一时间只跑一个截图任务
    private var enabled = true
    private var lastSpoken = ""
    private var lastSpokenAt = Date.distantPast
    private var lastWord = ""
    private var lastWordAt = Date.distantPast
    private var panelHideTask: DispatchWorkItem?
    private var panelAnchor: CGPoint?        // 面板对应的"词"所在位置
    private var panelHasContext = false
    private var awayHideScheduled = false
    private var currentContext: String = ""
    private var rawZh: String = ""
    private var heartbeatTimer: Timer?
    private var permissionTimer: Timer?
    private var permissionRetries = 0

    // MARK: 启动
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        if let i = CommandLine.arguments.firstIndex(of: "--preview-panel"),
           i + 1 < CommandLine.arguments.count {
            previewPanel(word: CommandLine.arguments[i + 1])
            return
        }
        startHeartbeat()
        startPermissionWatchdog()
        lastMoveAt = Date()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshCapture() }
            }
        }
        Task { await refreshCapture() }
        log("已启动 v1.1")
    }

    /// 命令行预览面板（用于截图验证 UI，不依赖截图权限）
    private func previewPanel(word: String) {
        let at = CGPoint(x: 300, y: 300)
        showPanel(at: at, word: word, zh: "翻译中…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.translator.translate(word) {
            case .ok(let t):
                let base = t.displayWord ?? word
                let shown = t.phonetic.map { "\(base)  /\($0)/" } ?? base
                let zh = t.isMachine ? t.text + "（机翻）" : t.text
                self.showPanel(at: at, word: shown, zh: zh)
                let ctx = await self.enricher.explain(word) ?? t.fallbackContext
                if let ctx {
                    self.showPanel(at: at, word: shown, zh: zh, context: ctx)
                }
            case .noResult:
                self.showPanel(at: at, word: word, zh: "词典未收录该词，暂无中文释义")
            case .network(let reason):
                self.showPanel(at: at, word: word, zh: "网络不通：\(String(reason.prefix(40)))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { NSApp.terminate(nil) }
        }
    }

    // MARK: 菜单栏
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "HoverTranslator 悬停翻译"

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "屏幕录制权限：检测中…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        toggleItem = NSMenuItem(title: "暂停 / 开启", action: #selector(toggleEnabled), keyEquivalent: "t")
        let test = NSMenuItem(title: "测试翻译与朗读（hello）", action: #selector(testTranslate), keyEquivalent: "")
        let diag = NSMenuItem(title: "网络诊断…", action: #selector(runDiagnostics), keyEquivalent: "d")
        let recheck = NSMenuItem(title: "重新检测授权", action: #selector(recheckPermission), keyEquivalent: "r")
        let openSettings = NSMenuItem(title: "打开屏幕录制授权设置", action: #selector(openScreenSettings), keyEquivalent: "")
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(toggleItem)
        menu.addItem(statusLine)
        menu.addItem(test)
        menu.addItem(diag)
        menu.addItem(recheck)
        menu.addItem(openSettings)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatusUI()
    }

    private func updateStatusUI() {
        guard let btn = statusItem.button else { return }
        let title = enabled ? "译 ●" : "译 ○"
        let color: NSColor = enabled ? .systemGreen : NSColor(white: 0.45, alpha: 1)
        btn.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color])
        toggleItem.title = enabled ? "状态：已开启（点此暂停）" : "状态：已暂停（点此开启）"
        statusLine.title = captureReady ? "屏幕录制权限：已就绪" : "屏幕录制权限：未就绪（点「重新检测授权」）"
    }

    // MARK: 悬浮窗
    private func setupPanel() {
        let w = Cfg.panelW, h = Cfg.panelH
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false   // 别因为切 App 就消失
        panel.ignoresMouseEvents = true   // 关键：别挡住鼠标，否则悬停会失效
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true

        enLabel = NSTextField(labelWithString: "")
        enLabel.font = NSFont.boldSystemFont(ofSize: 15)
        enLabel.textColor = .white
        enLabel.frame = NSRect(x: 12, y: 58, width: w - 24, height: 20)
        enLabel.lineBreakMode = .byTruncatingTail
        enLabel.usesSingleLineMode = true

        zhLabel = NSTextField(wrappingLabelWithString: "")
        zhLabel.font = NSFont.systemFont(ofSize: 13)
        zhLabel.textColor = NSColor(calibratedRed: 0.61, green: 0.91, blue: 0.77, alpha: 1)
        zhLabel.frame = NSRect(x: 12, y: 10, width: w - 24, height: 42)
        zhLabel.lineBreakMode = .byWordWrapping
        zhLabel.maximumNumberOfLines = 2
        zhLabel.usesSingleLineMode = false

        contextLabel = NSTextField(wrappingLabelWithString: "")
        contextLabel.font = NSFont.systemFont(ofSize: 11.5)
        contextLabel.textColor = NSColor(calibratedWhite: 0.80, alpha: 1)
        contextLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        contextLabel.frame = NSRect(x: 14, y: 10, width: w - 28, height: h - 96)
        contextLabel.lineBreakMode = .byWordWrapping
        contextLabel.maximumNumberOfLines = 3
        contextLabel.usesSingleLineMode = false
        contextLabel.isHidden = true

        content.addSubview(enLabel)
        content.addSubview(zhLabel)
        content.addSubview(contextLabel)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
    }

    /// 按宽度手动折行（NSTextField 的自动换行在固定窗口里不可靠，干脆自己算）
    private func wrapForDisplay(_ text: String, width: CGFloat, font: NSFont, maxLines: Int) -> (String, CGFloat) {
        guard !text.isEmpty, maxLines > 0 else { return ("", 0) }
        let chars = Array(text)
        var lines: [String] = []
        var i = 0
        while i < chars.count && lines.count < maxLines {
            var line = ""
            while i < chars.count {
                let candidate = line + String(chars[i])
                let w = (candidate as NSString).size(withAttributes: [.font: font]).width
                if w <= width { line = candidate; i += 1 } else { break }
            }
            if line.isEmpty { line = String(chars[i]); i += 1 }
            lines.append(line)
        }
        if i < chars.count, !lines.isEmpty {
            lines[lines.count - 1] = String(lines[lines.count - 1].dropLast()) + "…"
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return (lines.joined(separator: "\n"), CGFloat(max(lines.count, 1)) * lineHeight)
    }

    /// 排版三行文字并返回面板总高度
    private func layoutLabels(hasContext: Bool) -> CGFloat {
        let w = Cfg.panelW
        let textW = w - 28
        let enH: CGFloat = 20
        let zhFont = zhLabel.font ?? NSFont.systemFont(ofSize: 13)
        let ctxFont = contextLabel.font ?? NSFont.systemFont(ofSize: 11.5)

        let (zhText, zhH0) = wrapForDisplay(rawZh, width: textW, font: zhFont, maxLines: 2)
        zhLabel.stringValue = zhText
        let zhH = max(zhH0, 16)

        var ctxH: CGFloat = 0
        if hasContext {
            let (ctxText, h0) = wrapForDisplay("背景  " + currentContext, width: textW, font: ctxFont, maxLines: 3)
            contextLabel.stringValue = ctxText
            ctxH = max(h0, 14)
        } else {
            contextLabel.stringValue = ""
        }

        let padTop: CGFloat = 8, padBottom: CGFloat = 9, gap1: CGFloat = 4, gap2: CGFloat = 6
        let h = padTop + enH + gap1 + zhH + (ctxH > 0 ? gap2 + ctxH : 0) + padBottom

        enLabel.frame = NSRect(x: 14, y: h - padTop - enH, width: textW, height: enH)
        zhLabel.frame = NSRect(x: 14, y: h - padTop - enH - gap1 - zhH, width: textW, height: zhH)
        contextLabel.isHidden = !hasContext
        if hasContext {
            contextLabel.frame = NSRect(x: 14, y: padBottom, width: textW, height: ctxH)
        }
        return h
    }

    private func showPanel(at flippedGlobal: CGPoint, word: String?, zh: String?, context: String? = nil) {
        if let word { enLabel.stringValue = word }
        if let zh { rawZh = zh }
        currentContext = context ?? ""
        let visibleContext = !currentContext.isEmpty

        // 按内容算高度（有背景时更高，但不会留大片空白）
        let h = layoutLabels(hasContext: visibleContext)
        let w = Cfg.panelW
        if abs(panel.frame.size.height - h) > 0.5 || abs(panel.frame.size.width - w) > 0.5 {
            panel.setFrame(NSRect(x: panel.frame.origin.x, y: panel.frame.origin.y, width: w, height: h),
                           display: true)
        }

        // 全局坐标（主屏左上为原点，y 向下）-> AppKit 屏幕坐标（左下为原点）
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? (NSScreen.main?.frame.height ?? 0)
        let appKitPoint = NSPoint(x: flippedGlobal.x, y: mainHeight - flippedGlobal.y)

        let screen = NSScreen.screens.first { $0.frame.contains(appKitPoint) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size

        // 悬浮窗必须离光标足够远（> 截图半高 26pt），否则下一次截图会把自家窗口文字
        // 当成"光标下的单词"重新识别 -> 自我循环
        let gap: CGFloat = 44
        var x = appKitPoint.x + 18
        var y = appKitPoint.y - size.height - gap
        if y < vf.minY + 4 {                       // 下方空间不足，改放光标上方
            y = appKitPoint.y + gap
        }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        panelAnchor = flippedGlobal
        panelHasContext = visibleContext
        awayHideScheduled = false
        schedulePanelHide(after: visibleContext ? max(Cfg.panelAutoHide, 6.5) : Cfg.panelAutoHide)
    }

    // MARK: 心跳：读鼠标 + 静止检测 + 触发
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: Cfg.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        // .common 模式：菜单打开 / 模态框期间计时器不冻结
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func heartbeat() {
        guard let event = CGEvent(source: nil) else { return }
        let loc = event.location
        if abs(loc.x - lastMouse.x) > 1 || abs(loc.y - lastMouse.y) > 1 {
            lastMouse = loc
            lastMoveAt = Date()
            armed = true          // 移动过 -> 本次静止可以触发
        }
        // 光标离开触发词 -> 1 秒后自动收起，别让面板挡在屏幕上
        updatePanelVisibility(forCursor: loc)
        guard enabled, captureReady, !busy, armed else { return }
        guard Date().timeIntervalSince(lastMoveAt) >= Cfg.hoverDelay else { return }
        guard let info = ScreenGrabber.display(for: lastMouse, in: displays) else { return }

        armed = false             // 一次静止只触发一次，避免原地每 0.1s 重复截图
        busy = true
        let cursor = lastMouse
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            await self.captureAndProcess(at: cursor, display: info)
        }
    }


    // MARK: 截图 + OCR + 朗读 + 翻译
    private func captureAndProcess(at cursor: CGPoint, display info: DisplayInfo) async {
        let grabbed: (image: CGImage, hit: OCRHit?)
        do {
            grabbed = try await ScreenGrabber.grabWord(at: cursor, display: info)
        } catch {
            log("截图失败: \(error.localizedDescription)")
            return
        }
        guard let hit = grabbed.hit else { return }
        let w = hit.word
        let phrase = hit.phrase
        log("识别: \(w) @(\(Int(cursor.x)),\(Int(cursor.y)))")

        let now = Date()
        if w.lowercased() == lastWord.lowercased(), now.timeIntervalSince(lastWordAt) < 0.8 {
            return   // 同一个词极短时间重复识别（光标微抖），直接忽略
        }
        // 兜底：悬浮窗还开着时又"识别"到同一个词，多半是拍到了自家面板，忽略
        if panel.isVisible, w.lowercased() == lastWord.lowercased() {
            return
        }
        lastWord = w
        lastWordAt = now

        // 先把词显示出来，翻译回来再补中文，避免"没反应"的错觉
        showPanel(at: cursor, word: w, zh: "翻译中…")

        let sameWord = (w.lowercased() == lastSpoken.lowercased()) &&
                       (now.timeIntervalSince(lastSpokenAt) < Cfg.sameWordSpeakCooldown)
        if !sameWord {
            speak(w)
            lastSpoken = w
            lastSpokenAt = now
        }

        let outcome = await translator.translate(w)
        switch outcome {
        case .ok(let t):
            let base = t.displayWord ?? w
            let shownWord = t.phonetic.map { "\(base)  /\($0)/" } ?? base
            let zhText = t.isMachine ? t.text + "（机翻）" : t.text
            log("翻译 OK: \(w) -> \(shownWord) (\(t.isMachine ? "机翻" : "词典"))")
            showPanel(at: cursor, word: shownWord, zh: zhText)

            // 人名/地名/机构等专有名词：异步补一句"背景"（维基中文首句，失败则用有道网络释义）
            if looksLikeEntity(phrase: phrase, translated: t.text) {
                let target = phrase
                let fallback = t.fallbackContext
                let snapWord = w
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let ctx = await self.enricher.explain(target) ?? fallback
                    guard let ctx, !ctx.isEmpty else { return }
                    guard self.panel.isVisible, self.lastWord == snapWord,
                          self.cursorNear(cursor) else { return }
                    log("背景: \(target) -> \(String(ctx.prefix(30)))")
                    self.showPanel(at: cursor, word: shownWord, zh: zhText, context: ctx)
                }
            }
        case .noResult:
            showPanel(at: cursor, word: w, zh: "词典未收录该词，暂无中文释义")
        case .network(let reason):
            log("翻译网络失败: \(reason)")
            showPanel(at: cursor, word: w, zh: "网络不通，翻译失败（菜单栏「网络诊断」可检查）")
        }
    }

    /// 光标是否还停在触发位置附近
    private func cursorNear(_ anchor: CGPoint, threshold: CGFloat = Cfg.awayDistance) -> Bool {
        let dx = lastMouse.x - anchor.x
        let dy = lastMouse.y - anchor.y
        return dx * dx + dy * dy <= threshold * threshold
    }

    /// 是否值得补背景解释：词典释义里带「城市/首都/人名/公司…」等实体标记，
    /// 或识别到 New York / Albert Einstein 这类多词专名。
    /// 菜单项之类的大写普通词（Harness、Edit）不会触发，避免噪音。
    private func looksLikeEntity(phrase: String, translated: String) -> Bool {
        let markers = ["首都", "城市", "国家", "省", "州", "县", "市", "镇", "村",
                       "人名", "姓氏", "姓名", "物理学家", "科学家", "作家", "诗人", "演员",
                       "总统", "国王", "皇帝", "首相", "将军", "公司", "大学", "学院",
                       "河", "山", "岛", "湖", "海", "街", "广场", "教堂", "博物馆",
                       "王朝", "帝国", "王国", "战役", "条约", "组织", "机构", "乐队", "电影"]
        if translated.contains("（"), markers.contains(where: { translated.contains($0) }) {
            return true
        }
        let tokens = phrase.split(separator: " ")
        if tokens.count >= 2, tokens.count <= 4,
           tokens.allSatisfy({ $0.first?.isUppercase == true && !OCR.stopwords.contains($0.lowercased()) }) {
            return true
        }
        return false
    }

    /// 统一的面板隐藏调度（取消上一次计时）
    private func schedulePanelHide(after seconds: TimeInterval) {
        panelHideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panelAnchor = nil
                self.awayHideScheduled = false
            }
        }
        panelHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    /// 光标离开"触发的那个词"后，1 秒内收起面板；回到附近则恢复正常停留时间
    private func updatePanelVisibility(forCursor loc: CGPoint) {
        guard panel.isVisible, let anchor = panelAnchor else { return }
        let dx = loc.x - anchor.x
        let dy = loc.y - anchor.y
        let isAway = dx * dx + dy * dy > Cfg.awayDistance * Cfg.awayDistance
        if isAway {
            guard !awayHideScheduled else { return }
            awayHideScheduled = true
            schedulePanelHide(after: Cfg.awayHideDelay)
        } else if awayHideScheduled {
            awayHideScheduled = false
            schedulePanelHide(after: panelHasContext ? max(Cfg.panelAutoHide, 6.5) : Cfg.panelAutoHide)
        }
    }

    // MARK: 朗读
    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.5
        u.volume = 1.0
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(u)
    }

    // MARK: 屏幕录制权限
    private func startPermissionWatchdog() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: Cfg.permissionRetryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.captureReady, self.permissionRetries < Cfg.maxPermissionRetries else { return }
                self.permissionRetries += 1
                Task { await self.refreshCapture() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func refreshCapture() async {
        let preflight = CGPreflightScreenCaptureAccess()
        if !preflight && !permissionRequested {
            permissionRequested = true
            // 只在第一次触发系统授权弹窗，避免反复弹
            _ = CGRequestScreenCaptureAccess()
            openScreenSettings()
        }

        do {
            displays = try await ScreenGrabber.loadDisplays()
            captureReady = !displays.isEmpty
            if captureReady {
                log("屏幕捕获就绪，显示器数=\(displays.count)")
            } else {
                showPermissionAlertIfNeeded()
            }
        } catch {
            captureReady = false
            log("SCShareableContent 失败: \(error.localizedDescription)")
            showPermissionAlertIfNeeded()
        }
        updateStatusUI()
    }


    private func showPermissionAlertIfNeeded() {
        guard !failedAlertsShown else { return }
        failedAlertsShown = true
        alert("""
        还没拿到「屏幕与系统录音」权限，所以无法截图识别。

        请按顺序操作：
        1) 系统设置 → 隐私与安全性 → 屏幕与系统录音，打开 HoverTranslator（没有就用 ＋ 添加）；
        2) 完全退出本应用（菜单栏「退出」）后重新打开（权限必须重启才生效）；
        3) 回来点菜单里的「重新检测授权」。

        不想授权也能先验证朗读和翻译：菜单里点「测试翻译与朗读（hello）」。
        """)
    }

    private func alert(_ msg: String) {
        // 必须在主线程构造/运行 NSAlert（旧版在后台 async 任务里构造 -> SIGABRT）
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "HoverTranslator"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "知道了")
        a.runModal()
    }

    // MARK: 菜单动作
    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            lastMoveAt = Date()
            armed = false
        } else {
            busy = false
            panelHideTask?.cancel()
            panelAnchor = nil
            awayHideScheduled = false
            panel.orderOut(nil)
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        }
        updateStatusUI()
    }

    @objc private func recheckPermission() {
        permissionRequested = false
        failedAlertsShown = false
        permissionRetries = 0
        Task { await refreshCapture() }
    }

    @objc private func testTranslate() {
        let word = "hello"
        speak(word)
        let at = lastMouse.x < 0 ? CGPoint(x: 400, y: 400) : lastMouse
        showPanel(at: at, word: word, zh: "翻译中…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.translator.translate(word) {
            case .ok(let t):
                let shown = t.phonetic.map { "\(word)  /\($0)/" } ?? word
                self.showPanel(at: at, word: shown, zh: t.isMachine ? t.text + "（机翻）" : t.text)
            case .noResult:
                self.showPanel(at: at, word: word, zh: "词典未收录该词")
            case .network(let reason):
                self.showPanel(at: at, word: word, zh: "网络不通（\(String(reason.prefix(40)))）")
            }
        }
    }

    @objc private func runDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.translator.diagnose()
            self.alert("网络诊断结果：\n\n\(report)")
        }
    }

    @objc private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 命令行自检
enum SelfTest {
    /// 渲染 "the quick brown fox jumps"，把虚拟光标放在 brown / quick 上，跑完整取词
    static func runOcrTest() -> Int32 {
        let text = "the quick brown fox jumps"
        let width = 900, height = 140
        let scale: CGFloat = 2
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(CGFloat(width) * scale),
                                  height: Int(CGFloat(height) * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            report("FAIL: 无法创建位图上下文")
            return 1
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 30, y: 40)   // 基线 y=40（CoreText 左下原点）
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else {
            report("FAIL: 无法生成图像")
            return 1
        }
        writePNG(image, to: "/tmp/HoverTranslator-selftest.png")

        func cursorFor(_ needle: String) -> CGPoint {
            let start = text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound)
            let offset = CTLineGetOffsetForStringIndex(line, start, nil)
            return CGPoint(x: (30 + offset + 12) * scale,               // 词内偏 12pt
                           y: (CGFloat(height) - 40 - 12) * scale)      // 基线 40 + 半字高，转左上原点
        }

        let pickedBrown = OCR.word(in: image, at: cursorFor("brown"))?.word
        let pickedQuick = OCR.word(in: image, at: cursorFor("quick"))?.word
        let pickedFox = OCR.word(in: image, at: cursorFor("fox"))?.word
        print("光标在 brown 上 -> \(pickedBrown ?? "<nil>")")
        print("光标在 quick 上 -> \(pickedQuick ?? "<nil>")")
        print("光标在 fox 上 -> \(pickedFox ?? "<nil>")")

        let ok = pickedBrown?.lowercased() == "brown"
            && pickedQuick?.lowercased() == "quick"
            && pickedFox?.lowercased() == "fox"
        report(ok ? "PASS: OCR 能精确选到光标下的单词（且能区分相邻词）"
                  : "FAIL: OCR 取词不对")

        // 真实场景：13pt 界面小字，按 2x Retina 渲染成 ~170x50pt 的截图区
        let small = runSmallFontCase()
        report(small ? "PASS: 13pt 屏幕小字能识别并选中光标下的词" : "FAIL: 13pt 小字识别失败")
        return (ok && small) ? 0 : 2
    }

    /// 渲染 13pt 小字 + 模拟 180x52pt 的 Retina 截图，验证真实使用场景
    static func runSmallFontCase() -> Bool {
        let text = "serendipity happens"
        let scale: CGFloat = 2
        let w = 360, h = 104   // 180x52pt @2x
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 13 * scale, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 10, y: 36)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return false }
        writePNG(image, to: "/tmp/HoverTranslator-selftest-small.png")

        let idx = text.distance(from: text.startIndex, to: text.range(of: "happens")!.lowerBound)
        let offset = CTLineGetOffsetForStringIndex(line, idx, nil)
        let cursor = CGPoint(x: 10 + offset + 10, y: CGFloat(h) - 36 - 10)
        let picked = OCR.word(in: image, at: cursor)?.word
        report("13pt 小字: 识别到 \(picked ?? "<nil>")")
        return picked?.lowercased() == "happens"
    }

    /// 真实屏幕端到端测试：在指定全局坐标（主屏左上原点，y 向下）走一遍
    /// 「SCK 截图 -> 坐标换算 -> OCR -> 选中光标下的词」的完整路径
    nonisolated static func runLiveCapture(x: CGFloat, y: CGFloat) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var output = "FAIL: 未执行"
        Task {
            do {
                let displays = try await ScreenGrabber.loadDisplays()
                guard let info = ScreenGrabber.display(for: CGPoint(x: x, y: y), in: displays) else {
                    output = "FAIL: 找不到包含该坐标的显示器"
                    sem.signal(); return
                }
                let grabbed = try await ScreenGrabber.grabWord(at: CGPoint(x: x, y: y), display: info)
                SelfTest.writePNG(grabbed.image, to: "/tmp/HoverTranslator-live-crop.png")
                let localX = x - info.flippedFrame.minX
                let localY = y - info.flippedFrame.minY
                output = "显示器=\(Int(info.points.width))x\(Int(info.points.height))@\(info.scale)x "
                    + "全局=(\(x),\(y)) 局部=(\(localX),\(localY)) "
                    + "裁剪图=\(grabbed.image.width)x\(grabbed.image.height)px "
                    + "识别词=\(grabbed.hit?.word ?? "<nil>") 短语=\(grabbed.hit?.phrase ?? "<nil>")"
            } catch {
                output = "FAIL: \(error.localizedDescription)（多半是屏幕录制权限没给这个进程）"
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 15) == .timedOut {
            print("FAIL: 截图超时（屏幕录制权限？）")
            return 6
        }
        print(output)
        if output.hasPrefix("FAIL") || output.contains("识别词=<nil>") { return 7 }
        return 0
    }

    static func report(_ msg: String) {
        print(msg)
        let logURL = URL(fileURLWithPath: "/tmp/HoverTranslator-selftest.log")
        let line = msg + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func runTranslateTest(word: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var output = "FAIL: 未执行"
        var code: Int32 = 3
        let started = Date()
        Task {
            let t = Translator()
            switch await t.translate(word) {
            case .ok(let tr):
                let src = tr.isMachine ? "[机翻] " : ""
                let ph = tr.phonetic.map { " /\($0)/" } ?? ""
                output = "OK \(src)\(ph) \(tr.text)"
                code = 0
            case .noResult:
                output = "未收录（接口正常，但该词没有释义）"
                code = 4
            case .network(let e):
                output = "网络失败: \(e)"
                code = 3
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 25) == .timedOut {
            print("FAIL: 翻译超时")
            return 3
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        print("翻译 \(word) -> \(output)  (\(elapsed)s)")
        return code
    }

    /// 压力/稳定性测试：连续翻译一批词，统计 成功 / 未收录 / 网络失败
    static func runStressTranslate(count: Int) -> Int32 {
        let words = ["hello", "world", "translation", "serendipity", "ambiguity",
                     "quantum", "android", "safari", "controller", "framework",
                     "resilient", "abibliophobia", "rizz", "enshittification", "delulu"]
        let sem = DispatchSemaphore(value: 0)
        var lines: [String] = []
        var ok = 0, none = 0, netfail = 0
        Task {
            let t = Translator()
            for i in 0..<count {
                let w = words[i % words.count]
                let t0 = Date()
                switch await t.translate(w) {
                case .ok(let tr):
                    ok += 1
                    let src = tr.isMachine ? "[机翻] " : ""
                    lines.append("\(w): OK \(String(format: "%.2f", Date().timeIntervalSince(t0)))s \(src)\(tr.text.prefix(28))")
                case .noResult:
                    none += 1
                    lines.append("\(w): 未收录")
                case .network(let e):
                    netfail += 1
                    lines.append("\(w): 网络失败 \(String(e.prefix(50)))")
                }
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 180) == .timedOut {
            print("FAIL: 压力测试超时")
            return 3
        }
        for line in lines { print(line) }
        print("")
        print("统计: 成功 \(ok) / 未收录 \(none) / 网络失败 \(netfail)  (共 \(count) 次)")
        return netfail == 0 ? 0 : 5
    }

    static func runTTSTest(word: String) -> Int32 {
        guard let voice = AVSpeechSynthesisVoice(language: "en-US") else {
            print("FAIL: 没有 en-US 语音")
            return 5
        }
        print("语音: \(voice.name) / \(voice.identifier)")
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: word)
        u.voice = voice
        u.rate = 0.5
        synth.speak(u)
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        print("PASS: 朗读调用完成（若无声请检查系统输出设备/静音）")
        return 0
    }

    static func writePNG(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("（测试图已保存: \(path)）")
    }
}

// MARK: - 入口
let arguments = CommandLine.arguments
let app = NSApplication.shared

if arguments.contains("--selftest") {
    exit(SelfTest.runOcrTest())
}
if let i = arguments.firstIndex(of: "--context") {
    let phrase = i + 1 < arguments.count ? arguments[i + 1] : "Kyoto"
    let sem = DispatchSemaphore(value: 0)
    Task {
        let e = Enricher()
        let ctx = await e.explain(phrase)
        print("背景 \(phrase) -> \(ctx ?? "<无>")")
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
    exit(0)
}
if let i = arguments.firstIndex(of: "--stress-translate") {
    let n = i + 1 < arguments.count ? (Int(arguments[i + 1]) ?? 15) : 15
    exit(SelfTest.runStressTranslate(count: n))
}
if let i = arguments.firstIndex(of: "--test-translate") {
    let word = i + 1 < arguments.count ? arguments[i + 1] : "hello"
    exit(SelfTest.runTranslateTest(word: word))
}
if let i = arguments.firstIndex(of: "--test-tts") {
    let word = i + 1 < arguments.count ? arguments[i + 1] : "hello"
    exit(SelfTest.runTTSTest(word: word))
}
if let i = arguments.firstIndex(of: "--selftest-live") {
    var xs: CGFloat? = nil, ys: CGFloat? = nil
    if i + 2 < arguments.count {
        xs = Double(arguments[i + 1]).map { CGFloat($0) }
        ys = Double(arguments[i + 2]).map { CGFloat($0) }
    } else if i + 1 < arguments.count {
        let parts = arguments[i + 1].split(separator: ",")
        if parts.count == 2 {
            xs = Double(parts[0]).map { CGFloat($0) }
            ys = Double(parts[1]).map { CGFloat($0) }
        }
    }
    guard let x = xs, let y = ys else {
        print("用法: --selftest-live <x> <y>   （全局坐标，主屏左上原点，y 向下）")
        exit(64)
    }
    exit(SelfTest.runLiveCapture(x: x, y: y))
}
if arguments.contains("--diagnose") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t = Translator()
        print(await t.diagnose())
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    exit(0)
}
if arguments.contains("--check-permission") {
    let ok = CGPreflightScreenCaptureAccess()
    print(ok ? "屏幕录制权限: 已授权" : "屏幕录制权限: 未授权")
    exit(ok ? 0 : 1)
}

let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
