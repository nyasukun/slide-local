import Foundation

@main struct NativeUXPolicyTests {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw StudioError(message) } }
    static func main() throws {
        var p = Project(id: "test", filename: "test.pptx", created: 0, slide_count: 1, image_count: 0, slides: [], units: [])
        let options = QueueOptions(target: "ja", source: "en", model: p.model, notes: false, fit: true)
        try check(TranslationPolicy.exportBlockReason(project: p, drafts: [:], options: options, busy: false) == nil, "zero-unit deck blocked")
        p.units = [TextUnit(id: "u", part: "slide", index: 0, kind: "slide", source: "Hello", slides: [1])]
        try check(TranslationPolicy.exportBlockReason(project: p, drafts: ["u": " \n"], options: options, busy: false) != nil, "blank draft export allowed")
        try check(TranslationPolicy.exportBlockReason(project: p, drafts: ["u": "翻訳"], options: options, busy: false) == nil, "valid draft export blocked")
        p.state = "queued"
        try check(TranslationPolicy.exportBlockReason(project: p, drafts: ["u": "翻訳"], options: options, busy: false) != nil, "queued export allowed")
        p.state = "ready"
        p.translated_preview = PreviewRecord(state: "ready", fingerprint: try TranslationPolicy.previewFingerprint(p, translated: true))
        try check(TranslationPolicy.previewIsFresh(p, translated: true, hasDrafts: false, options: options), "fresh preview rejected")
        try check(!TranslationPolicy.previewIsFresh(p, translated: true, hasDrafts: true, options: options), "draft preview treated as current")
        p.units[0].translation = "変更"; p.units[0].status = "done"
        try check(!TranslationPolicy.previewIsFresh(p, translated: true, hasDrafts: false, options: options), "old image treated as current")
        try check(!TranslationPolicy.previewIsFresh(p, translated: false, hasDrafts: false, options: options), "translated record accepted as source")
        p.units[0].status = "pending"; p.units[0].translation = ""
        try check(TranslationPolicy.phase(project: p, options: options) == .ready, "initial workflow not ready")
        try check(TranslationPolicy.actionTitle(project: p, options: options, paused: true).contains("予約"), "paused action promised immediate translation")
        p.state = "queued"
        try check(TranslationPolicy.phase(project: p, options: options) == .queued, "waiting not separated")
        p.state = "translating"
        try check(TranslationPolicy.phase(project: p, options: options) == .running, "running not separated")
        p.state = "review"
        try check(TranslationPolicy.phase(project: p, options: options) == .review, "review not separated")
        p.units[0].status = "done"; p.units[0].translation = "編集した訳文"; p.state = "complete"
        try check(TranslationPolicy.phase(project: p, options: options) == .complete, "completed workflow not ready to save")
        var changed = options; changed.fit = false
        try check(TranslationPolicy.phase(project: p, options: changed) == .settingsChanged, "unapplied settings not shown")
        try check(TranslationPolicy.actionTitle(project: p, options: changed, paused: false) == "変更を反映する", "fit-only implied retranslating")
        changed.target = "en"
        try check(TranslationPolicy.actionTitle(project: p, options: changed, paused: false).contains("翻訳し直す"), "destructive settings action hidden")
        var item = QueueItem(id: "q", project_id: "p", filename: "file", status: "running", message: "", options: options, cancel_requested: true)
        try check(TranslationPolicy.queueStatusTitle(item, paused: false).contains("停止"), "stop request not visible")
        item.status = "confirmation"
        try check(TranslationPolicy.queueStatusTitle(item, paused: false).contains("確認"), "blocked item not distinguishable")
        print("UX policy: zero-unit/blank-draft/queued export and kind/revision/draft preview freshness PASS")
    }
}
