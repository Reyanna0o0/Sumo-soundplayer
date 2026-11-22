import Foundation
import HibikiCore

// 命令行的 Mac 端识别工具。
//
// 用法示例：
//   ASRTool --audio 作品/本編SEあり/wav --script 台本.pdf --model ~/models/kotoba.bin --out ~/Desktop/字幕
//   ASRTool --audio 单个文件.wav --model ... --out ...
//
// 做的事情：
//   音频 → ffmpeg 转 16k 单声道 → whisper-cli 出 JSON → 词级时间
//        → （可选）台本对齐 → .srt / .ja.srt + .zh.srt

struct Options {
    var audioPaths: [String] = []
    var scriptPath: String?
    var modelPath: String = ""
    var outputDirectory: String = "."
    var language: String = "ja"
    var trackNumber: Int?
    var verbose = false
}

func parseArguments() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--audio": if let value = iterator.next() { options.audioPaths.append(value) }
        case "--script": options.scriptPath = iterator.next()
        case "--model": options.modelPath = iterator.next() ?? ""
        case "--out": options.outputDirectory = iterator.next() ?? "."
        case "--lang": options.language = iterator.next() ?? "ja"
        case "--track": options.trackNumber = iterator.next().flatMap(Int.init)
        case "--verbose": options.verbose = true
        case "-h", "--help":
            print("""
            用法: ASRTool --model <模型> [--audio <音频或目录> ...] [--script <台本>] [--out <输出目录>]

              --audio    音频文件或目录（可重复）；目录会递归找音频
              --script   台本（PDF/TXT），有的话会做对齐
              --model    whisper.cpp 的 ggml 模型路径
              --out      字幕输出目录
              --lang     识别语言，默认 ja
              --track    合集台本时指定用第几段
            """)
            exit(0)
        default:
            if !arg.hasPrefix("--") { options.audioPaths.append(arg) }
        }
    }
    return options
}

let options = parseArguments()

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - 前置检查

guard !options.modelPath.isEmpty else {
    log("缺少 --model 参数")
    exit(1)
}
guard FileManager.default.fileExists(atPath: options.modelPath) else {
    log("模型文件不存在：\(options.modelPath)")
    exit(1)
}
guard !options.audioPaths.isEmpty else {
    log("缺少 --audio 参数")
    exit(1)
}

let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "flac", "aiff", "aif", "ogg", "opus"]

/// 把输入展开成音频文件列表
func collectAudioFiles(from paths: [String]) -> [String] {
    var result: [String] = []
    let fm = FileManager.default
    for path in paths {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
            guard let enumerator = fm.enumerator(atPath: path) else { continue }
            for case let relative as String in enumerator {
                let ext = (relative as NSString).pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { continue }
                result.append((path as NSString).appendingPathComponent(relative))
            }
        } else {
            result.append(path)
        }
    }
    return result.sorted { NaturalSort.compare($0, $1) }
}

// MARK: - 找外部工具

func findExecutable(_ name: String, extraPaths: [String] = []) -> String? {
    for candidate in extraPaths where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    for directory in searchPaths {
        let full = (directory as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: full) { return full }
    }
    return nil
}

guard let ffmpeg = findExecutable("ffmpeg") else {
    log("找不到 ffmpeg（可以 brew install ffmpeg）")
    exit(1)
}
guard let whisper = findExecutable("whisper-cli") else {
    log("找不到 whisper-cli（可以 brew install whisper-cpp）")
    exit(1)
}

/// 运行外部命令，返回 (退出码, stdout, stderr)
@discardableResult
func run(_ executable: String, _ arguments: [String]) -> (code: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        return (-1, "", "启动失败: \(error.localizedDescription)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

// MARK: - 台本

var scriptLines: [String]?
/// 当前这条音频实际要用的台词
var currentSectionLines: [String]?
/// 合集台本的各段，按音频文件名里的轨道号取用
var pendingSections: [ScriptSection]?
var scriptTitle = ""
var crossLanguage = false

if let scriptPath = options.scriptPath {
    do {
        let url = URL(fileURLWithPath: scriptPath)
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            text = try PDFTextExtractor.extract(url: url)
        } else {
            let data = try Data(contentsOf: url)
            text = SubtitleTextDecoder.decode(data: data) ?? ""
        }

        let sections = ScriptSectioner.split(text)
        if sections.count > 1 {
            // 没指定 --track 时，按每个音频文件名里的轨道号自己找
            // （比如 Tr2_xxx.wav → 第 2 段），这样批量处理整张专辑时不用逐个指定
            pendingSections = sections
            if let track = options.trackNumber,
               let section = ScriptSectioner.section(forTrackNumber: track, in: sections) {
                scriptLines = section.lines.map(\.text)
                scriptTitle = section.title
                log("合集台本 \(sections.count) 段，使用第 \(track) 段：\(section.title)")
            } else {
                log("合集台本 \(sections.count) 段，将按每个音频文件的轨道号自动对应")
            }
        } else if let only = sections.first {
            scriptLines = only.lines.map(\.text)
        }
        log("台本：\(scriptLines?.count ?? 0) 行 \(scriptTitle.isEmpty ? "" : "（\(scriptTitle)）")")
    } catch {
        log("读取台本失败：\(error.localizedDescription)，本次不用台本")
    }
}

// MARK: - 逐条处理

let files = collectAudioFiles(from: options.audioPaths)
guard !files.isEmpty else {
    log("没有找到音频文件")
    exit(1)
}
log("待处理音频 \(files.count) 个")

try? FileManager.default.createDirectory(
    atPath: options.outputDirectory,
    withIntermediateDirectories: true
)

var successCount = 0
var failureCount = 0

for (index, audioPath) in files.enumerated() {
    let name = (audioPath as NSString).lastPathComponent
    log("[\(index + 1)/\(files.count)] \(name)")

    // 合集台本：按这个音频的轨道号选对应段落
    if let sections = pendingSections, sections.count > 1 {
        if let number = ScriptSectioner.trackNumber(fromFileName: name),
           let section = ScriptSectioner.section(forTrackNumber: number, in: sections) {
            currentSectionLines = section.lines.map(\.text)
            log("  使用台本第 \(number) 段：\(section.title)（\(currentSectionLines?.count ?? 0) 句）")
        } else {
            currentSectionLines = nil
            log("  台本里没有第几段的信息，这首不用台本")
        }
    } else {
        currentSectionLines = scriptLines
    }

    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("asr-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    // ① 转成 16kHz 单声道 WAV（whisper 要求）
    let converted = temporary.appendingPathComponent("input.wav").path
    let convert = run(ffmpeg, ["-y", "-i", audioPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", converted, "-loglevel", "error"])
    guard convert.code == 0, FileManager.default.fileExists(atPath: converted) else {
        log("  转换失败：\(convert.err.prefix(200))")
        failureCount += 1
        continue
    }

    // ② whisper 识别，输出 JSON（带词级时间）
    let base = temporary.appendingPathComponent("out").path
    let started = Date()
    let recognize = run(whisper, [
        "-m", options.modelPath,
        "-f", converted,
        "-l", options.language,
        "-oj", "-ojf",
        "-of", base,
        "-np",
        "--no-prints"
    ])
    let elapsed = Date().timeIntervalSince(started)

    guard recognize.code == 0 else {
        log("  识别失败：\(recognize.err.suffix(300))")
        failureCount += 1
        continue
    }

    let jsonPath = base + ".json"
    guard let jsonData = FileManager.default.contents(atPath: jsonPath) else {
        log("  没有生成 JSON 结果")
        failureCount += 1
        continue
    }

    let tokens = WhisperJSONParser.parseTokens(jsonData)
    guard !tokens.isEmpty else {
        log("  识别结果为空")
        failureCount += 1
        continue
    }
    log("  识别 \(tokens.count) 个词，用时 \(String(format: "%.1f", elapsed))s")

    // ③ 对齐 / 断句
    let cues: [SubtitleCue]
    if let scriptLines = currentSectionLines, !scriptLines.isEmpty {
        let scriptText = scriptLines.joined(separator: "\n")
        crossLanguage = ScriptLanguageCheck.isCrossLanguage(scriptText: scriptText, asrTokens: tokens)
        let totalDuration = tokens.last?.endMS ?? 0
        let aligned: [AlignedScriptLine]
        if crossLanguage {
            aligned = CrossLanguageAligner.align(scriptLines: scriptLines, tokens: tokens)
        } else {
            aligned = ScriptAligner.align(scriptLines: scriptLines, tokens: tokens)
        }
        cues = ScriptToCues.build(aligned: aligned, totalDurationMS: totalDuration)
        let summary = ScriptToCues.summarize(aligned)
        if crossLanguage {
            log("  对齐：\(cues.count) 句（跨语言，按字数比例分配，需人工校对）")
        } else {
            log("  对齐：\(summary.description)")
        }
    } else {
        cues = TokenCueBuilder.build(tokens: tokens)
        log("  断句：\(cues.count) 句")
    }

    // ④ 写字幕
    let outputBase = (options.outputDirectory as NSString)
        .appendingPathComponent((name as NSString).deletingPathExtension)

    var exportOptions = SubtitleExportOptions()
    exportOptions.includeTranslation = false
    let srt = SubtitleExporter.export(cues, format: .srt, options: exportOptions)
    do {
        try srt.write(toFile: outputBase + ".srt", atomically: true, encoding: .utf8)
        successCount += 1
    } catch {
        log("  写文件失败：\(error.localizedDescription)")
        failureCount += 1
    }
}

log("完成：成功 \(successCount)，失败 \(failureCount)")
