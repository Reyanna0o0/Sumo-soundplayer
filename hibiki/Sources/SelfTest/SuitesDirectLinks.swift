import Foundation
import HibikiCore

func runDirectLinkSuites(_ h: Harness) {
    func test(_ name: String, _ body: () throws -> Void) { h.test(name) { do { try body() } catch { h.expect(false, "\(error)") } } }
    h.suite("作品直链与离线台本") {
        test("规范化作品链接并拒绝错误域名、账号页和转义路径") {
            h.expectEqual(try DirectLink(" http://www.soundgasm.net/u/Test/Title?tracking=1#part ", site: .soundgasm).url.absoluteString,
                          "https://soundgasm.net/u/Test/Title", "去跟踪参数并用HTTPS")
            for bad in ["https://soundgasm.net/u/a", "https://soundgasm.net.evil.test/u/a/b", "https://user@soundgasm.net/u/a/b", "file:///u/a/b", "https://soundgasm.net/u/a%2fb/c", "https://soundgasm.net/u/a/%2e%2e", "https://soundgasm.net:8080/u/a/b"] {
                do { _ = try DirectLink(bad, site: .soundgasm); h.expect(false, "应拒绝错误链接") } catch { h.expect(true, "已拒绝") }
            }
            h.expect(!DirectLink.isSoundgasmAudio(URL(string: "https://media.soundgasm.net.evil.test/sounds/a.m4a")!), "严格检查媒体域名")
        }
        test("读取实际播放器结构，说明中的署名保留且不推定作者身份") {
            let link = try DirectLink("https://soundgasm.net/u/uploader/sample", site: .soundgasm)
            let page = try SoundgasmPage.parse(html: """
              <div class="jp-title" aria-label="title">A &amp; B &#x27;sample&#39;</div>
              <div class="jp-description"><p>Voice: Performer<br>Script: Writer</p></div>
              <script>p.setMedia({m4a: "https://media.soundgasm.net/sounds/test.m4a"});</script>
              """, link: link)
            h.expectEqual(page.metadata.title, "A & B 'sample'", "只解码一次实体")
            h.expectEqual(page.metadata.uploadAccount, "uploader", "上传账号单独保留")
            h.expectEqual(page.metadata.description, "Voice: Performer\nScript: Writer", "原始署名说明不丢失")
            do { _ = try SoundgasmPage.parse(html: "<h1>Log in</h1>", link: link); h.expect(false, "登录页不能导入") }
            catch { h.expect(true, "拒绝无媒体页面") }
        }
        test("Scriptbin 保留段落、舞台提示、数字，不推测时间或双语") {
            let link = try DirectLink("https://scriptbin.works/u/writer/sample", site: .scriptbin)
            let original = "Author note\n--8<--\n\n[00:10] A stage direction\nSpeaker: keep this line\n\n第二段\nSecond paragraph"
            let doc = try ScriptbinDocument(link: link, title: "Sample", text: original)
            let cues = ScriptImportPlan.cues(for: doc.section)
            h.expectEqual(doc.text, original, "完整文本原样")
            h.expectEqual(cues.map(\.text).joined(separator: "\n\n"), original, "台本正文逐段保留")
            h.expect(cues.allSatisfy { $0.status == .untimed && $0.translatedText == nil && $0.speaker == nil }, "不生成时间、翻译、角色")
            let blankLines = try ScriptbinDocument(link: link, title: "Blank line layout", text: "First\n\u{00a0}\n \n\nSecond")
            h.expectEqual(blankLines.text, "First\n\nSecond", "网页空白占位符变为段落间隔")
            h.expectEqual(blankLines.section.lines.count, 2, "多余空白不会让全文挤成一个段落")
            do { _ = try ScriptbinDocument(link: link, title: "Title", text: " \n "); h.expect(false, "空白不得成功") }
            catch { h.expect(true, "拒绝空正文") }
        }
        test("v17升级保留旧数据；来源独立保存、同名不合并、删除作品级联来源") {
            let fixture = try RelinkingFixture(version: 17)
            let before = try fixture.db.query("SELECT * FROM work ORDER BY id")
            let oldColumns = Set(try fixture.db.query("PRAGMA table_info(work)").compactMap { $0.string("name") })
            h.expectEqual(try fixture.library.prepare(), Schema.currentVersion - 17, "运行 v17 后新增来源、视频位置与通话资料迁移")
            let migrated = try fixture.db.query("SELECT * FROM work ORDER BY id")
            let originalFields = migrated.map { SQLRow($0.values.filter { oldColumns.contains($0.key) }) }
            h.expectEqual(originalFields, before, "所有旧作品字段原样")
            let link = try DirectLink("https://soundgasm.net/u/uploader/entry", site: .soundgasm)
            let metadata = DirectLinkMetadata(link: link, title: "Remote title", description: "Script: Somebody else")
            try fixture.library.saveDirectLink(metadata, workID: fixture.workID)
            h.expectEqual(try fixture.library.directLinks(workID: fixture.workID), [metadata], "来源信息可重读")
            h.expectEqual(try fixture.db.query("SELECT * FROM work ORDER BY id"), migrated, "网页信息不覆盖作品")
            h.expectEqual(try fixture.library.workForDirectLink(link), fixture.workID, "按直链查重")
            h.expectNil(try fixture.library.workForDirectLink(link, library: .personal), "查重尊重库")
            let count = try fixture.db.query("SELECT * FROM work_direct_link")
            do { try fixture.library.saveDirectLink(metadata, workID: fixture.workID); h.expect(false, "禁止覆盖来源") }
            catch { h.expectEqual(try fixture.db.query("SELECT * FROM work_direct_link"), count, "重复保存未改动") }
            try fixture.db.execute("DELETE FROM work WHERE id = ?", [.integer(fixture.workID)])
            h.expect(try fixture.library.directLinks(workID: fixture.workID).isEmpty, "删除作品清理来源")
        }
    }
}
