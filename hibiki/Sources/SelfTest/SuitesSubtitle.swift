import Foundation
import HibikiCore

/// 字幕匹配与持久化的测试套件
func runSubtitleSuites(_ h: Harness) {

    // ─────────────────────────────────────────────────────────
    h.suite("外挂字幕自动匹配") {
        h.test("同名同扩展") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "01 本編.mp3",
                candidatePaths: ["/w/01 本編.srt", "/w/cover.jpg", "/w/02 本編.mp3"]
            )
            h.expectEqual(matches.count, 1, "找到一个")
            h.expectEqual(matches.first?.format, .srt, "格式")
            h.expectEqual(matches.first?.confidence, 1.0, "完全匹配")
        }

        h.test("带语言后缀") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "01 本編.mp3",
                candidatePaths: ["/w/01 本編.ja.srt", "/w/01 本編.zh.srt"]
            )
            h.expectEqual(matches.count, 2, "两个语言版本")
            let languages = Set(matches.compactMap(\.languageHint))
            h.expectEqual(languages, ["ja", "zh"], "语言识别")
        }

        h.test("字幕省掉轨号") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "03. エピローグ.mp3",
                candidatePaths: ["/w/エピローグ.srt"]
            )
            h.expectEqual(matches.count, 1, "找到")
            h.expect(matches.first!.confidence < 1.0, "置信度低于完全匹配")
        }

        h.test("字幕保留完整音频名与语言标记") {
            let matches = SubtitleSidecarFinder.find(audioFileName: "02.本編.WAV", candidatePaths: [
                "/w/02.本編.wav.zh.vtt", "/w/03.特典.wav.vtt"
            ])
            h.expectEqual(matches.map(\.path), ["/w/02.本編.wav.zh.vtt"], "只配这首")
            h.expectEqual(matches.first?.languageHint, "zh", "语言")
        }

        h.test("真实多轨双扩展名，不依赖唯一剩余兜底") {
            let tracks = ["/w/WAV/01_本編.wav", "/w/WAV/02_特典.mp3", "/w/WAV/03_別編.mp3"]
            let matches = SubtitleSidecarFinder.importMatches(audioPaths: tracks, subtitlePaths: [
                tracks[1] + ".vtt", tracks[0] + ".vtt"
            ])
            h.expectEqual(matches[tracks[0]]?.path, tracks[0] + ".vtt", "wav 完整名")
            h.expectEqual(matches[tracks[1]]?.path, tracks[1] + ".vtt", "mp3 完整名")
            h.expectNil(matches[tracks[2]], "没有字幕")
        }

        h.test("作品根目录或独立字幕目录按同名或唯一轨号配对") {
            let tracks = ["/w/音频/1_Track1_日文.wav", "/w/音频/2_Track2_日文.wav", "/w/音频/特典.wav"]
            let paths = ["/w/繁中/1_Track1_中文.wav.vtt", "/w/繁中/2_Track2_中文.wav.vtt", "/w/特典.srt"]
            let matches = SubtitleSidecarFinder.importMatches(audioPaths: tracks, subtitlePaths: paths)
            h.expectEqual(tracks.compactMap { matches[$0]?.path }, paths, "不依赖枚举顺序")
        }

        h.test("同一文件夹的多种音频编码共用裸曲名 SRT") {
            let stem = "/w/特典/主水Ash様フリートーク"
            let tracks = [stem + ".mp3", stem + ".wav"]
            for sub in [stem + ".srt", "/w/字幕/主水Ash様フリートーク.srt"] {
                let matches = SubtitleSidecarFinder.importMatches(audioPaths: tracks, subtitlePaths: [sub],
                                                                   selectedAudioPaths: [tracks[1]])
                h.expectEqual(matches[tracks[1]]?.path, sub, "为选中的 WAV 配对")
                h.expectNil(matches[tracks[0]], "不再分配给 MP3")
            }
            let duplicate = "/w/无SE/主水Ash様フリートーク.wav"
            let ambiguous = SubtitleSidecarFinder.importMatches(audioPaths: tracks + [duplicate],
                subtitlePaths: ["/w/字幕/主水Ash様フリートーク.srt"], selectedAudioPaths: [tracks[1]])
            h.expect(ambiguous.isEmpty, "独立字幕目录里的裸曲名不能区分不同 SE 文件夹")
        }

        h.test("同名和同轨号的多版本不猜") {
            let tracks = ["/w/有SE/Track1_本編.wav", "/w/无SE/Track1_本編.wav"]
            let paths = ["/w/字幕/Track1_本編.wav.vtt", "/w/字幕/Track1_正篇.vtt"]
            h.expect(SubtitleSidecarFinder.importMatches(audioPaths: tracks, subtitlePaths: paths).isEmpty, "两种歧义均跳过")
            let local = tracks[0] + ".vtt"
            let result = SubtitleSidecarFinder.importMatches(audioPaths: tracks, subtitlePaths: paths + [local])
            h.expectEqual(result[tracks[0]]?.path, local, "优先同目录")
            h.expectNil(result[tracks[1]], "局部已配对也不能打破作品内的歧义")
        }

        h.test("分别收录的同名格式可共用台词，专属字幕只配给对应格式") {
            let flac = "/w/音声/Track1.flac"
            let mp3 = "/w/音声/Track1.mp3"
            let shared = "/w/音声/Track1.srt"
            let specific = "/w/字幕/Track1.mp3.vtt"
            let both: Set<String> = [flac, mp3]
            let first = SubtitleSidecarFinder.importMatches(audioPaths: [flac, mp3], subtitlePaths: [shared],
                                                           selectedAudioPaths: both)
            h.expectEqual(first[flac]?.path, shared, "FLAC 收到同名字幕")
            h.expectEqual(first[mp3]?.path, shared, "MP3 也收到同名字幕")
            let second = SubtitleSidecarFinder.importMatches(audioPaths: [flac, mp3],
                subtitlePaths: [shared, specific], selectedAudioPaths: both)
            h.expectEqual(second[flac]?.path, shared, "FLAC 使用通用字幕")
            h.expectEqual(second[mp3]?.path, specific, "MP3 使用格式专属字幕")
        }

        h.test("同一轨号有两份翻译，不猜语言或目录") {
            let matches = SubtitleSidecarFinder.importMatches(audioPaths: ["/w/1_Track1_日.wav"],
                subtitlePaths: ["/w/简中/1_Track1_简.wav.vtt", "/w/繁中/1_Track1_繁.wav.vtt"])
            h.expect(matches.isEmpty, "重复字幕轨号跳过")
        }

        h.test("局部精确匹配优先，剩余的通用名只在同目录兜底") {
            let tracks = ["/w/本編/01_本編.wav", "/w/本編/02_本編.wav", "/w/特典/独白.wav"]
            let named = "/w/本編/02_本編.srt"
            let other = "/w/本編/wav.vtt"
            let matches = SubtitleSidecarFinder.importMatches(audioPaths: tracks,
                subtitlePaths: [named, other, "/w/单独字幕/台词.vtt"])
            h.expectEqual(matches[tracks[1]]?.path, named, "精确优先")
            h.expectEqual(matches[tracks[0]]?.path, other, "同目录剩一对")
            h.expectNil(matches[tracks[2]], "不跨目录兜底")
        }

        h.test("多种字幕格式") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "track.wav",
                candidatePaths: ["/w/track.srt", "/w/track.ass", "/w/track.vtt", "/w/track.lrc"]
            )
            h.expectEqual(matches.count, 4, "四种都认")
        }

        h.test("不相关文件不匹配") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "01 本編.mp3",
                candidatePaths: ["/w/02 別の曲.srt", "/w/readme.txt"]
            )
            h.expectEqual(matches.count, 0, "没有匹配")
        }

        h.test("匹配结果按可信度排序") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "01 本編.mp3",
                candidatePaths: ["/w/本編.srt", "/w/01 本編.srt"]
            )
            h.expectEqual(matches.first?.confidence, 1.0, "完全匹配排前面")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("字幕原文/译文配对") {
        h.test("日文原文 + 中文译文") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "01.mp3",
                candidatePaths: ["/w/01.ja.srt", "/w/01.zh.srt"]
            )
            let pairs = SubtitleSidecarFinder.pair(matches, preferPrimary: "ja")
            h.expectEqual(pairs.count, 1, "一组")
            h.expectEqual(pairs.first?.primary.languageHint, "ja", "原文是日文")
            h.expectEqual(pairs.first?.secondary?.languageHint, "zh", "译文是中文")
        }

        h.test("只有一份字幕") {
            let matches = SubtitleSidecarFinder.find(
                audioFileName: "01.mp3",
                candidatePaths: ["/w/01.srt"]
            )
            let pairs = SubtitleSidecarFinder.pair(matches)
            h.expectEqual(pairs.count, 1, "一组")
            h.expectNil(pairs.first?.secondary, "没有译文")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("字幕持久化") {
        func makeSetup(database: SQLiteDatabase? = nil) throws -> (SubtitleRepository, Int64) {
            let db = try database ?? SQLiteDatabase.inMemory()
            let lib = LibraryRepository(database: db)
            try lib.prepare()
            let sid = try lib.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let wid = try lib.upsertWork(WorkRecord(title: "w", folderPath: "/m/w",
                                                     folderRelativePath: "w", sourceID: sid))
            try lib.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "01.mp3", filePath: "/m/w/01.mp3",
                            relativePath: "01.mp3", fileType: "mp3")
            ])
            let trackID = try lib.tracks(workID: wid)[0].id
            return (SubtitleRepository(database: db), trackID)
        }

        func sampleCues() -> [SubtitleCue] {
            [
                SubtitleCue(index: 0, startMS: 1000, endMS: 3000, text: "あ、そこはだめ",
                            translatedText: "啊，那里不行"),
                SubtitleCue(index: 1, startMS: 3500, endMS: 6000, text: "そんなこと")
            ]
        }

        h.test("创建字幕轨并读回") {
            let (repo, trackID) = try! makeSetup()
            _ = try! repo.createTrack(
                trackID: trackID, kind: .sidecar, language: "ja",
                label: "01.srt", cues: sampleCues()
            )
            let tracks = try! repo.tracks(forTrackID: trackID)
            h.expectEqual(tracks.count, 1, "一条轨")
            h.expectEqual(tracks.first?.kind, .sidecar, "来源")
            h.expectEqual(tracks.first?.language, "ja", "语言")
            h.expectEqual(tracks.first?.isActive, true, "默认激活")
            h.expectEqual(tracks.first?.cueCount, 2, "两条字幕")
        }

        h.test("台本文字持久化保留顺序与状态，默认不切走已有字幕") {
            let (repo, trackID) = try! makeSetup()
            let original = try! repo.createTrack(trackID: trackID, kind: .sidecar, language: "ja",
                                                 label: "原字幕", cues: sampleCues())
            let track = TrackRecord(id: trackID, workID: 1, fileName: "01.mp3", filePath: "/m/w/01.mp3", fileType: "mp3")
            let plan = ScriptImportPlan.make(sections: ScriptSectioner.split("TRACK1\n甲：台本一\n乙：台本二"), tracks: [track])
            h.expectEqual(try! repo.importScriptSections(plan, fileName: "整部.pdf"), 1, "导入一段")
            let all = try! repo.tracks(forTrackID: trackID)
            h.expectEqual(all.count, 2, "来源都保留")
            h.expectEqual(all.first(where: \.isActive)?.id, original.track, "仍显示原带时间字幕")
            let script = all.first(where: { $0.kind == .script })!
            try! repo.activateTrack(trackID: trackID, subtitleTrackID: script.id)
            let saved = try! repo.activeCues(trackID: trackID)
            h.expectEqual(saved.map(\.text), ["台本一", "台本二"], "正文顺序")
            h.expect(saved.allSatisfy { $0.status == .untimed && !$0.hasTiming }, "状态读回")
            let edited = CueEditor.settingText(saved, at: 1, to: "修正台本二")
            _ = try! repo.insertVersion(subtitleTrackID: script.id, note: "改文字", isBaseline: false, cues: edited)
            h.expectEqual(try! repo.activeCues(trackID: trackID)[1].status, .untimed, "文字改后重读仍无时间")
            h.expectEqual(try! repo.cues(versionID: original.version).count, 2, "旧字幕版本完整")
        }

        h.test("特典单曲没有轨号也落库；自动重扫与重复手选保留手改及停用") {
            let (repo, id) = try! makeSetup()
            let track = TrackRecord(id: id, workID: 1, fileName: "特典.mp3", filePath: "/w/特典.mp3", fileType: "mp3")
            let plan = ScriptImportPlan.make(sections: ScriptSectioner.split("甲：第一句\n甲：第二句"), tracks: [track])
            for _ in 0..<2 { _ = try! repo.importScriptSections(plan, fileName: "300DL/台本.pdf", automatically: true) }
            h.expectEqual(try! repo.tracks(forTrackID: id).count, 1, "只建一个特典来源")
            h.expectEqual(try! repo.activeCues(trackID: id).map(\.text), ["第一句", "第二句"], "确实保存文字")
            let first = try! repo.tracks(forTrackID: id)[0]
            _ = try! repo.insertVersion(subtitleTrackID: first.id, note: "自改", isBaseline: false,
                cues: CueEditor.settingText(try! repo.activeCues(trackID: id), at: 1, to: "改过"))
            _ = try! repo.importScriptSections(plan, fileName: "另选.pdf")
            _ = try! repo.importScriptSections(plan, fileName: "另选.pdf")
            h.expectEqual(try! repo.tracks(forTrackID: id).count, 2, "重复手选同一份没有副本")
            h.expectEqual(try! repo.activeCues(trackID: id)[1].text, "改过", "未打轴的手改来源继续显示")
            try! repo.deactivateAll(trackID: id)
            _ = try! repo.importScriptSections(plan, fileName: "另选.pdf")
            h.expect(try! repo.activeCues(trackID: id).isEmpty, "尊重已关闭的来源")
        }

        h.test("自动 PDF 来源重扫幂等，手改版本、现有激活来源及打轴状态保留") {
            let (repo, id) = try! makeSetup()
            let track = TrackRecord(id: id, workID: 1, fileName: "01.wav", filePath: "/w/01.wav", fileType: "wav")
            func scan(_ text: String) {
                let plan = ScriptImportPlan.make(sections: ScriptSectioner.split("TRACK1\n" + text), tracks: [track])
                _ = try! repo.importScriptSections(plan, fileName: "台本/script.pdf", automatically: true)
            }
            scan("原稿")
            let origin = try! repo.tracks(forTrackID: id).first!
            scan("原稿")
            h.expectEqual(try! repo.tracks(forTrackID: id).map(\.id), [origin.id], "相同文件重扫不重复")
            scan("来源修正版")
            let updated = try! repo.activeCues(trackID: id)
            h.expectEqual(updated.first?.text, "来源修正版", "未动过的自动底稿可刷新")
            h.expect(try! repo.shouldActivateNewSidecar(alongside: repo.tracks(forTrackID: id)), "新出现的带轴字幕可接手")
            try! repo.activateTrack(trackID: id, subtitleTrackID: origin.id)
            h.expect(!(try! repo.shouldActivateNewSidecar(alongside: repo.tracks(forTrackID: id))), "主动选择 PDF 后晚到的 SRT 不切走它")
            let timed = CueEditor.settingRange(updated, at: 0, startMS: 1000, endMS: 3000)
            _ = try! repo.insertVersion(subtitleTrackID: origin.id, note: "手动打轴", isBaseline: false, cues: timed)
            scan("再版")
            h.expectEqual(try! repo.activeCues(trackID: id).first?.endMS, 3000, "人工打轴保留")
            h.expect(!(try! repo.shouldActivateNewSidecar(alongside: repo.tracks(forTrackID: id))), "新字幕不覆盖已编辑来源")
            try! repo.deactivateAll(trackID: id)
            scan("再版")
            h.expect(try! repo.activeCues(trackID: id).isEmpty, "重扫尊重手动停用")
        }
        h.test("旧自动台本升级为印刷起点，重新配对保留来源、版本和手改") {
            let (repo, id) = try! makeSetup()
            let track = TrackRecord(id: id, workID: 1, fileName: "02.mp3", filePath: "/w/02.mp3", fileType: "mp3")
            let source = "简体中文.pdf"
            let old = try! repo.createTrack(trackID: id, kind: .script, language: nil,
                label: source + " · 第2轨", cues: [SubtitleCue(index: 0, startMS: 0, endMS: 0, text: "旧底稿", status: .untimed)],
                note: "从作品 PDF 自动识别 · 尚未设置时间", prefersTimedSidecar: true)
            func scan(_ start: String) {
                let sections = ScriptSectioner.split("tr02\n" + start + " 第一句\n11:55 印刷越界")
                let plan = ScriptImportPlan.make(sections: sections, tracks: [track])
                try! repo.importScriptSections(plan, fileName: source, automatically: true, durationsMS: [id: 696_840])
            }
            scan("3:50")
            let cues = try! repo.activeCues(trackID: id)
            h.expectEqual(cues.first?.startMS, 230_000, "旧自动底稿原位升级到印刷时间")
            h.expectEqual(cues.first?.endMS, 235_000, "五秒暂估句尾")
            h.expectEqual(cues.first?.status, .provisional, "标注待校准")
            h.expectEqual(cues.last?.status, .untimed, "超出时长不自动打轴")
            h.expectEqual(CueEditor.settingText(cues, at: 0, to: "文字修正").first?.status, .provisional, "只改文字不确认估算句尾")
            scan("3:50")
            h.expectEqual(try! repo.tracks(forTrackID: id).map(\.id), [old.track], "重扫同稿不增加来源")
            h.expectEqual(try! repo.versions(subtitleTrackID: old.track).map(\.id), [old.version], "底稿版本稳定")
            scan("3:51")
            h.expectEqual(try! repo.activeCues(trackID: id).first?.startMS, 231_000, "只有印刷时间变化也会更新")
            let edited = CueEditor.settingRange(cues, at: 0, startMS: 230_100, endMS: 232_100)
            _ = try! repo.insertVersion(subtitleTrackID: old.track, note: "人工校准", isBaseline: false, cues: edited)
            scan("3:52")
            h.expectEqual(try! repo.activeCues(trackID: id).first?.endMS, 232_100, "保留人工校准")
        }

        h.test("保存自动句尾的新版本遇错回滚，重试后可读取并导出实际区间") {
            let db = try! SQLiteDatabase.inMemory()
            let (repo, trackID) = try! makeSetup(database: db)
            let original = sampleCues()
            let baseline = try! repo.createTrack(trackID: trackID, kind: .script, language: nil,
                                                 label: "初稿", cues: original)
            let edited = CueEditor.settingEditableRange(original, at: 0, startMS: 2000, endMS: nil, durationMS: 7000)!
            let resolved = CueEditor.resolvingAutomaticEnds(edited, durationMS: 7000)
            try! db.executeScript("""
                CREATE TEMP TRIGGER fail_second_cue BEFORE INSERT ON subtitle_cue
                WHEN NEW.cue_index = 1 BEGIN SELECT RAISE(ABORT, '测试失败'); END;
                """)
            do {
                _ = try repo.insertVersion(subtitleTrackID: baseline.track, note: "自动句尾", isBaseline: false, cues: resolved)
                h.expect(false, "应遇到第二句写入失败")
            } catch {
                h.expectEqual(try! repo.versions(subtitleTrackID: baseline.track).count, 1, "仅保留基线")
                h.expectEqual(try! repo.activeCues(trackID: trackID).first?.endMS, original.first?.endMS, "失败后继续播放旧版本")
            }
            try! db.executeScript("DROP TRIGGER fail_second_cue")
            _ = try! repo.insertVersion(subtitleTrackID: baseline.track, note: "自动句尾", isBaseline: false, cues: resolved)
            let saved = try! repo.activeCues(trackID: trackID)
            h.expectEqual(saved[0].status, .provisional, "重开仍能自动调句尾")
            h.expectEqual(saved[0].endMS, original[1].startMS, "持久化的终点供播放和导出共用")
            let srt = SubtitleExporter.export(saved, format: .srt)
            h.expect(srt.contains("00:00:02,000 --> 00:00:03,500"), "有真实可分享的开始和结束")
        }
        h.test("批量台本保存失败不留下部分结果") {
            let (repo, trackID) = try! makeSetup()
            let good = TrackRecord(id: trackID, workID: 1, fileName: "01.mp3", filePath: "/m/w/01.mp3", fileType: "mp3")
            let missing = TrackRecord(id: 987654, workID: 1, fileName: "02.mp3", filePath: "/missing/02.mp3", fileType: "mp3")
            let plan = ScriptImportPlan.make(sections: ScriptSectioner.split("track1\n甲\ntrack2\n乙"), tracks: [good, missing])
            do {
                _ = try repo.importScriptSections(plan, fileName: "失败.pdf")
                h.expect(false, "无效曲目必须失败")
            } catch {
                h.expectEqual(try! repo.tracks(forTrackID: trackID).count, 0, "前一段也回滚")
            }
        }

        h.test("两份附件一起保存、失败回滚，重试保留手动字幕") {
            let db = try! SQLiteDatabase.inMemory()
            let (repo, first) = try! makeSetup(database: db)
            let lib = LibraryRepository(database: db)
            let workID = try! lib.works()[0].id
            let oldTrack = try! lib.tracks(workID: workID)[0]
            let other = TrackRecord(workID: workID, fileName: "02.mp3", filePath: "/m/w/02.mp3",
                                    relativePath: "02.mp3", fileType: "mp3")
            try! lib.replaceTracks(workID: workID, tracks: [oldTrack, other])
            let second = try! lib.tracks(workID: workID).first { $0.fileName == "02.mp3" }!.id
            let a = ScriptImportPlan.make(sections: ScriptSectioner.split("甲：上篇"), tracks: [oldTrack])
            var b = ScriptImportPlan.make(sections: ScriptSectioner.split("乙：下篇"), tracks: [other])
            b[0].trackID = 9999999
            do {
                _ = try repo.importScriptFiles([("甲.txt", a), ("乙.txt", b)], activate: true)
                h.expect(false, "不存在的音轨必须报错")
            } catch {
                h.expect(try! repo.tracks(forTrackID: first).isEmpty, "第二份失败，第一份也没有保存")
            }
            b[0].trackID = second
            let files = [(name: "甲.txt", rows: a), (name: "乙.txt", rows: b)]
            h.expectEqual(try! repo.importScriptFiles(files, activate: true), 2, "重试保存两份")
            h.expectEqual(try! repo.activeCues(trackID: first).map(\.text), ["上篇"], "第一份未串轨")
            let cues = try! repo.activeCues(trackID: second)
            let source = try! repo.tracks(forTrackID: second)[0]
            _ = try! repo.insertVersion(subtitleTrackID: source.id, note: "手改", isBaseline: false,
                                        cues: CueEditor.settingText(cues, at: 0, to: "下篇修订"))
            _ = try! repo.importScriptFiles(files, activate: false)
            h.expectEqual(try! repo.tracks(forTrackID: second).count, 1, "重复导入未新增副本")
            h.expectEqual(try! repo.activeCues(trackID: second).map(\.text), ["下篇修订"], "重新导入保留手改")
        }

        h.test("同一首曲目可有两份译本，首选来源、自动手选互认、重复和取消均正确") {
            let (repo, id) = try! makeSetup()
            let track = TrackRecord(id: id, workID: 1, fileName: "01.wav", filePath: "/w/01.wav", fileType: "wav")
            let ch = WorkScriptMatching(text: "封面\nTrack1 标题\n0:01 原文", fileName: "簡体中文.pdf", candidates: [track])
                .suggestedAssignments
            let en = WorkScriptMatching(text: "Track1 Title\n0:01 One", fileName: "English.pdf", candidates: [track])
                .suggestedAssignments
            let cnName = "language/簡体中文.pdf", enName = "language/English.pdf"
            _ = try! repo.importScriptSections(ch, fileName: cnName, automatically: true)
            let original = try! repo.tracks(forTrackID: id)[0]
            _ = try! repo.insertVersion(subtitleTrackID: original.id, note: "手改", isBaseline: false,
                cues: CueEditor.settingText(try! repo.activeCues(trackID: id), at: 0, to: "手改简中"))
            _ = try! repo.importScriptFiles([(enName, en), (cnName, ch)], activate: true)
            h.expectEqual(try! repo.tracks(forTrackID: id).count, 2, "一轨保留两个来源，自动来源不重复")
            h.expectEqual(try! repo.activeCues(trackID: id).map(\.text), ["One"], "明确切换时显示先选的台本")
            _ = try! repo.importScriptFiles([(cnName, ch), (enName, en)], activate: false)
            h.expectEqual(try! repo.activeCues(trackID: id).map(\.text), ["One"], "关闭切换时不改变已有显示")
            _ = try! repo.importScriptFiles([(cnName, ch), (enName, en)], activate: true)
            h.expectEqual(try! repo.tracks(forTrackID: id).first(where: \.isActive)?.id, original.id, "同一份自动底稿按原 id 沿用")
            h.expectEqual(try! repo.activeCues(trackID: id).map(\.text), ["手改简中"], "手选时保留人工版本")
            _ = try! repo.importScriptSections(en, fileName: enName, automatically: true)
            h.expectEqual(try! repo.tracks(forTrackID: id).count, 2, "先手选英文再自动扫描也不新增")
            var skipped = ch
            skipped[0].trackID = nil
            h.expectEqual(try! repo.importScriptFiles([("未选.txt", skipped), (cnName, ch)], activate: false), 1, "整份略过不妨碍其余文件保存")
            do {
                _ = try repo.importScriptFiles([("重复.txt", en), ("重复.txt", ch)], activate: true)
                h.expect(false, "同文件分段不可争用同轨")
            } catch {
                h.expectEqual(try! repo.tracks(forTrackID: id).count, 2, "同文件重复触发整批回滚")
            }
            _ = try! repo.importScriptSections(ch, fileName: "不同目录/簡体中文.pdf")
            h.expectEqual(try! repo.tracks(forTrackID: id).count, 3, "同名不同路径不会仅因正文恰好相同而合并")
        }

        h.test("升级旧单选台本时按唯一附件和底稿核对，保留原来源和手改") {
            let (repo, id) = try! makeSetup()
            let track = TrackRecord(id: id, workID: 1, fileName: "01.wav", filePath: "/w/01.wav", fileType: "wav")
            let rows = WorkScriptMatching(text: "Track1\n对白", fileName: "译本.txt", candidates: [track]).suggestedAssignments
            _ = try! repo.importScriptSections(rows, fileName: "译本.txt")
            let old = try! repo.tracks(forTrackID: id)[0]
            _ = try! repo.insertVersion(subtitleTrackID: old.id, note: "改字", isBaseline: false,
                cues: CueEditor.settingText(try! repo.activeCues(trackID: id), at: 0, to: "修订"))
            let name = "作品/附件/译本.txt"
            _ = try! repo.importScriptFiles([(name, rows)], activate: false, legacyNames: [name: ["译本.txt"]])
            let updated = try! repo.tracks(forTrackID: id)
            h.expectEqual(updated.map(\.id), [old.id], "仍为同一来源")
            h.expect(updated[0].label.hasPrefix(name + " · "), "来源补全目录")
            h.expectEqual(try! repo.activeCues(trackID: id).map(\.text), ["修订"], "手改继续显示")
        }

        h.test("读取生效字幕") {
            let (repo, trackID) = try! makeSetup()
            _ = try! repo.createTrack(trackID: trackID, kind: .sidecar,
                                      language: "ja", label: "x", cues: sampleCues())
            let cues = try! repo.activeCues(trackID: trackID)
            h.expectEqual(cues.count, 2, "两条")
            h.expectEqual(cues[0].text, "あ、そこはだめ", "第一条原文")
            h.expectEqual(cues[0].translatedText, "啊，那里不行", "第一条译文")
            h.expectEqual(cues[1].startMS, 3500, "第二条时间")
        }

        h.test("多条轨只有一条生效") {
            let (repo, trackID) = try! makeSetup()
            let a = try! repo.createTrack(trackID: trackID, kind: .sidecar,
                                          language: "ja", label: "日文", cues: sampleCues())
            _ = try! repo.createTrack(trackID: trackID, kind: .manual,
                                      language: "zh", label: "中文",
                                      cues: [SubtitleCue(index: 0, startMS: 0, endMS: 1000, text: "测试")])
            let tracks = try! repo.tracks(forTrackID: trackID)
            h.expectEqual(tracks.filter(\.isActive).count, 1, "只有一条激活")
            // 切回第一条
            try! repo.activateTrack(trackID: trackID, subtitleTrackID: a.track)
            let cues = try! repo.activeCues(trackID: trackID)
            h.expectEqual(cues.count, 2, "切回后有两条")
        }

        h.test("关闭字幕后没有生效条目") {
            let (repo, trackID) = try! makeSetup()
            _ = try! repo.createTrack(trackID: trackID, kind: .sidecar,
                                      language: "ja", label: "x", cues: sampleCues())
            try! repo.deactivateAll(trackID: trackID)
            h.expectEqual(try! repo.activeCues(trackID: trackID).count, 0, "已关闭")
            h.expect(try! !repo.hasActiveSubtitles(trackID: trackID), "没有生效字幕")
        }

        h.test("版本管理：新版本不影响基线") {
            let (repo, trackID) = try! makeSetup()
            let created = try! repo.createTrack(trackID: trackID, kind: .ai,
                                                language: "ja", label: "AI", cues: sampleCues())
            var edited = sampleCues()
            edited[0].text = "修正后的文字"
            _ = try! repo.insertVersion(subtitleTrackID: created.track,
                                        note: "手工修正", isBaseline: false, cues: edited)
            let versions = try! repo.versions(subtitleTrackID: created.track)
            h.expectEqual(versions.count, 2, "两个版本")
            h.expectEqual(versions[0].isBaseline, true, "第一版是基线")
            h.expectEqual(versions[0].note, "导入", "基线备注")

            // 基线内容没被改
            let baselineCues = try! repo.cues(versionID: versions[0].id)
            h.expectEqual(baselineCues[0].text, "あ、そこはだめ", "基线保持原样")
            let latestCues = try! repo.cues(versionID: versions[1].id)
            h.expectEqual(latestCues[0].text, "修正后的文字", "新版已改")
        }

        h.test("生效字幕取最新版本") {
            let (repo, trackID) = try! makeSetup()
            let created = try! repo.createTrack(trackID: trackID, kind: .ai,
                                                language: "ja", label: "AI", cues: sampleCues())
            var edited = sampleCues()
            edited[0].text = "新版文字"
            _ = try! repo.insertVersion(subtitleTrackID: created.track,
                                        note: "改", isBaseline: false, cues: edited)
            let cues = try! repo.activeCues(trackID: trackID)
            h.expectEqual(cues[0].text, "新版文字", "用的是最新版")
        }

        h.test("基线版本不能删") {
            let (repo, trackID) = try! makeSetup()
            let created = try! repo.createTrack(trackID: trackID, kind: .ai,
                                                language: "ja", label: "AI", cues: sampleCues())
            let versions = try! repo.versions(subtitleTrackID: created.track)
            try! repo.deleteVersion(versions[0].id)
            h.expectEqual(try! repo.versions(subtitleTrackID: created.track).count, 1, "基线还在")
        }

        h.test("替换条目并更新计数") {
            let (repo, trackID) = try! makeSetup()
            let created = try! repo.createTrack(trackID: trackID, kind: .manual,
                                                language: "ja", label: "x", cues: sampleCues())
            try! repo.replaceCues(versionID: created.version, with: [
                SubtitleCue(index: 0, startMS: 0, endMS: 500, text: "只剩一条")
            ])
            let cues = try! repo.cues(versionID: created.version)
            h.expectEqual(cues.count, 1, "只剩一条")
            let versions = try! repo.versions(subtitleTrackID: created.track)
            h.expectEqual(versions[0].cueCount, 1, "计数已更新")
        }

        h.test("按来源删除旧字幕轨") {
            let (repo, trackID) = try! makeSetup()
            _ = try! repo.createTrack(trackID: trackID, kind: .sidecar,
                                      language: "ja", label: "旧", cues: sampleCues())
            try! repo.deleteTracks(trackID: trackID, kind: .sidecar)
            h.expectEqual(try! repo.tracks(forTrackID: trackID).count, 0, "已删除")
        }

        h.test("删除曲目级联删字幕") {
            let (repo, trackID) = try! makeSetup()
            _ = try! repo.createTrack(trackID: trackID, kind: .sidecar,
                                      language: "ja", label: "x", cues: sampleCues())
            try! repo.deleteTrack(try! repo.tracks(forTrackID: trackID)[0].id)
            h.expectEqual(try! repo.tracks(forTrackID: trackID).count, 0, "轨已删")
        }

        h.test("没字幕时返回空") {
            let (repo, trackID) = try! makeSetup()
            h.expectEqual(try! repo.activeCues(trackID: trackID).count, 0, "空")
        }
    }
}

/// 编码识别与双语合并
func runSubtitleSupportSuites(_ h: Harness) {

    h.suite("字幕文件编码识别") {
        h.test("UTF-8") {
            let text = "1\n00:00:01,000 --> 00:00:03,000\nこんにちは\n"
            let decoded = SubtitleTextDecoder.decode(data: Data(text.utf8))
            h.expectEqual(decoded, text, "原样解码")
        }

        h.test("带 BOM 的 UTF-8") {
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data("1\n00:00:01,000 --> 00:00:02,000\nやあ\n".utf8))
            let decoded = SubtitleTextDecoder.decode(data: data)
            h.expect(decoded?.hasPrefix("1") == true, "BOM 已去掉")
        }

        h.test("UTF-16 LE（带 BOM）") {
            let text = "1\n00:00:01,000 --> 00:00:03,000\nこんにちは\n"
            var data = Data([0xFF, 0xFE])
            data.append(text.data(using: .utf16LittleEndian)!)
            let decoded = SubtitleTextDecoder.decode(data: data)
            h.expectEqual(decoded, text, "能解码 UTF-16")
        }

        h.test("Shift-JIS 日文字幕") {
            let text = "1\n00:00:01,000 --> 00:00:03,000\nあ、そこはだめ\n"
            guard let data = text.data(using: .shiftJIS) else { return }
            let decoded = SubtitleTextDecoder.decode(data: data)
            h.expectEqual(decoded, text, "Shift-JIS 能还原")
        }

        h.test("GBK 中文字幕") {
            let text = "1\n00:00:01,000 --> 00:00:03,000\n啊，那里不行\n"
            guard let data = text.data(using: SubtitleTextDecoder.gb18030) else { return }
            let decoded = SubtitleTextDecoder.decode(data: data)
            h.expectEqual(decoded, text, "GBK 能还原")
        }

        h.test("空数据返回 nil") {
            h.expectNil(SubtitleTextDecoder.decode(data: Data()), "空数据")
        }
    }

    h.suite("双语字幕合并") {
        func cue(_ index: Int, _ start: Int, _ end: Int, _ text: String) -> SubtitleCue {
            SubtitleCue(index: index, startMS: start, endMS: end, text: text)
        }

        h.test("条数相同时按序号对齐") {
            let primary = [cue(0, 1000, 3000, "あ"), cue(1, 4000, 6000, "い")]
            let secondary = [cue(0, 1000, 3000, "啊"), cue(1, 4000, 6000, "咦")]
            let merged = SubtitleTranslationMerger.merge(primary: primary, secondary: secondary)
            h.expectEqual(merged[0].translatedText, "啊", "第一条")
            h.expectEqual(merged[1].translatedText, "咦", "第二条")
        }

        h.test("原文保留不受影响") {
            let primary = [cue(0, 1000, 3000, "あ")]
            let secondary = [cue(0, 1000, 3000, "啊")]
            let merged = SubtitleTranslationMerger.merge(primary: primary, secondary: secondary)
            h.expectEqual(merged[0].text, "あ", "原文没变")
        }

        h.test("条数不同时按时间重叠匹配") {
            let primary = [cue(0, 0, 1000, "あ"), cue(1, 1000, 2000, "い")]
            let secondary = [cue(0, 950, 1950, "咦")]   // 只有一条译文，覆盖第二条
            let merged = SubtitleTranslationMerger.merge(primary: primary, secondary: secondary)
            h.expectNil(merged[0].translatedText, "第一条没匹配到")
            h.expectEqual(merged[1].translatedText, "咦", "第二条匹配到")
        }

        h.test("空译文不覆盖") {
            let primary = [cue(0, 0, 1000, "あ")]
            let secondary = [cue(0, 0, 1000, "   ")]
            let merged = SubtitleTranslationMerger.merge(primary: primary, secondary: secondary)
            h.expectNil(merged[0].translatedText, "空白译文被忽略")
        }

        h.test("没有译文时返回原文") {
            let primary = [cue(0, 0, 1000, "あ")]
            let merged = SubtitleTranslationMerger.merge(primary: primary, secondary: [])
            h.expectEqual(merged.count, 1, "仍有原文")
            h.expectNil(merged[0].translatedText, "无译文")
        }
    }
}
