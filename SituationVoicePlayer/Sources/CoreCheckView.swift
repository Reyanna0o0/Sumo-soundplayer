import SwiftUI

/// 内核自检：在真机/模拟器上跑一遍关键逻辑，确认打包后的内核行为正确。
///
/// 这不是演示玩具 —— 它是开发期的验收工具：
/// 每次改完内核，跑这里就能确认"打包进 App 之后"行为仍然对
/// （单元测试跑在 macOS 上，这里跑在 iOS 上，两条独立的验证路径）。
struct CoreCheckView: View {

    struct CheckItem: Identifiable {
        let id = UUID()
        let title: String
        let passed: Bool
        let detail: String
    }

    @State private var items: [CheckItem] = []
    @State private var elapsedMilliseconds: Double = 0

    var body: some View {
        AppList {
            Section {
                HStack {
                    Text("结果")
                    Spacer()
                    let passed = items.filter(\.passed).count
                    Text("\(passed) / \(items.count) 通过")
                        .foregroundStyle(passed == items.count ? .green : .red)
                        .fontWeight(.semibold)
                }
                LabeledContent("耗时", value: String(format: "%.1f ms", elapsedMilliseconds))
            }

            Section("检查项") {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.passed ? .green : .red)
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Text("这些检查在 iOS 上运行关键逻辑；完整测试由开发环境中的独立测试套件执行。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("内核自检"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            runChecks()
        }
    }

    // MARK: - 检查

    private func runChecks() {
        let started = Date()
        var results: [CheckItem] = []

        results.append(checkSubtitleParsing())
        results.append(checkTimecode())
        results.append(checkStatSplitting())
        results.append(checkScriptAlignment())
        results.append(checkExport())
        results.append(checkClassification())

        items = results
        elapsedMilliseconds = Date().timeIntervalSince(started) * 1000
    }

    private func checkSubtitleParsing() -> CheckItem {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        あ、そこはだめ

        2
        00:00:05,500 --> 00:00:08,000
        そんなこと言われたら
        """
        let result = SubtitleParser.parse(srt)
        let ok = result.cues.count == 2
            && result.cues.first?.startMS == 1000
            && result.cues.first?.text == "あ、そこはだめ"
        let detail = ok
            ? "解析出 \(result.cues.count) 条；第一条 \(SubtitleTime.srt(result.cues[0].startMS)) 「\(result.cues[0].text)」"
            : "预期 2 条，实际 \(result.cues.count) 条"
        return CheckItem(title: "字幕解析（SRT）", passed: ok, detail: detail)
    }

    private func checkTimecode() -> CheckItem {
        let ms = 3_723_456
        let srt = SubtitleTime.srt(ms)
        let vtt = SubtitleTime.vtt(ms)
        let lrc = SubtitleTime.lrc(ms)
        let roundTrip = SubtitleTime.parseMilliseconds(srt) == ms
        let ok = srt == "01:02:03,456" && vtt == "01:02:03.456" && roundTrip
        return CheckItem(
            title: "时间码互转",
            passed: ok,
            detail: "SRT \(srt) · VTT \(vtt) · LRC \(lrc) · 往返\(roundTrip ? "一致" : "不一致")"
        )
    }

    private func checkStatSplitting() -> CheckItem {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 11; startComponents.day = 2
        startComponents.hour = 21; startComponents.minute = 40
        var endComponents = startComponents
        endComponents.hour = 22; endComponents.minute = 30

        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(from: endComponents) else {
            return CheckItem(title: "统计跨小时切分", passed: false, detail: "日期构造失败")
        }

        let slices = PlaybackStatSplitter.split(start: start, end: end, calendar: calendar)
        let ok = slices.count == 2
            && slices[0].hourSlot == 21 && slices[0].seconds == 1200
            && slices[1].hourSlot == 22 && slices[1].seconds == 1800
        let detail = slices
            .map { "\($0.hourSlot) 点 \($0.seconds / 60) 分" }
            .joined(separator: " + ")
        return CheckItem(
            title: "统计跨小时切分（21:40→22:30）",
            passed: ok,
            detail: ok ? detail : "结果异常：\(detail)"
        )
    }

    private func checkScriptAlignment() -> CheckItem {
        let tokens: [TimedToken] = [
            TimedToken(text: "あ", startMS: 0, endMS: 200),
            TimedToken(text: "そこ", startMS: 200, endMS: 500),
            TimedToken(text: "は", startMS: 500, endMS: 600),
            TimedToken(text: "だべ", startMS: 600, endMS: 900),   // 故意用识别错字
            TimedToken(text: "よ", startMS: 900, endMS: 1000)
        ]
        let aligned = ScriptAligner.align(
            scriptLines: ["あ、そこはだめよ", "（ドアを叩く）"],
            tokens: tokens
        )
        let first = aligned.first
        let ok = first?.status == .ok
            && first?.startMS == 0
            && first?.endMS == 1000
            && aligned.count > 1 && aligned[1].status == .unaligned
        let detail: String
        if let first {
            detail = "第一行 \(first.startMS ?? -1)~\(first.endMS ?? -1) ms，匹配率 "
                + String(format: "%.0f%%", first.matchRatio * 100)
                + "；舞台指示行被判为\(aligned.count > 1 ? (aligned[1].status == .unaligned ? "未对齐（正确）" : "已对齐（错误）") : "缺失")"
        } else {
            detail = "没有对齐结果"
        }
        return CheckItem(title: "台本锚点对齐（含识别错字）", passed: ok, detail: detail)
    }

    private func checkExport() -> CheckItem {
        let cues = [
            SubtitleCue(index: 0, startMS: 1000, endMS: 3500, text: "あ、そこはだめ", translatedText: "Ah, not there"),
            SubtitleCue(index: 1, startMS: 4000, endMS: 6000, text: "そんなこと")
        ]
        let srt = SubtitleExporter.export(cues, format: .srt)
        let reparsed = SRTSubtitleParser.parse(srt)
        let ok = srt.contains("00:00:01,000 --> 00:00:03,500")
            && srt.contains("あ、そこはだめ\nAh, not there")
            && reparsed.cues.count == 2

        let files = SubtitleExporter.exportFiles(
            cues, format: .srt, baseName: "作品名",
            primaryLanguage: "ja", secondaryLanguage: "zh",
            options: SubtitleExportOptions(bilingualLayout: .splitFiles)
        )
        let fileNames = files.map(\.suggestedFileName).joined(separator: " / ")
        return CheckItem(
            title: "字幕导出（含双语拆文件）",
            passed: ok && files.count == 2,
            detail: "SRT 往返 \(reparsed.cues.count) 条；拆分文件：\(fileNames)"
        )
    }

    private func checkClassification() -> CheckItem {
        let result = FolderClassifier.classify(name: "[サークル名] 素敵な作品 RJ01234567 [花子]")
        let ok = result.rjCode == "RJ01234567"
            && result.circle == ["サークル名"]
            && result.seiyuu == ["花子"]
            && result.cleanedTitle == "素敵な作品"
        return CheckItem(
            title: "文件夹名分类",
            passed: ok,
            detail: "RJ=\(result.rjCode ?? "nil") · 社团=\(result.circle.joined(separator: ",")) · 声优=\(result.seiyuu.joined(separator: ",")) · 标题=「\(result.cleanedTitle)」"
        )
    }
}

#Preview {
    NavigationStack {
        CoreCheckView()
    }
}
