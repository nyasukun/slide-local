import Foundation
import CryptoKit

enum WorkflowPhase { case ready, queued, running, review, complete, settingsChanged }

struct TranslationAssessment: Sendable {
    let projectID: String
    let filename: String
    let fingerprint: String
    let resetsTranslations: Bool
    let translatedCount: Int
    let options: QueueOptions
}

enum TranslationPolicy {
    static func phase(project p: Project, options: QueueOptions) -> WorkflowPhase {
        if p.state == "queued" { return .queued }
        if p.state == "translating" { return .running }
        if self.options(p) != options { return .settingsChanged }
        let selected = p.units.filter { options.notes || $0.kind != "notes" }
        if selected.allSatisfy({ ["done", "preserved"].contains($0.status) }) { return .complete }
        if ["review", "error", "cancelled", "interrupted", "confirmation"].contains(p.state) || selected.contains(where: { !$0.translation.isEmpty }) { return .review }
        return .ready
    }
    static func actionTitle(project p: Project, options: QueueOptions, paused: Bool) -> String {
        if paused { return "この資料の翻訳を予約する" }
        if p.units.contains(where: { !$0.translation.isEmpty }), changesLanguageOrModel(p, options) { return "設定を変えて翻訳し直す" }
        if self.options(p) != options, !changesLanguageOrModel(p, options) { return "変更を反映する" }
        if p.units.contains(where: { !$0.translation.isEmpty }) { return "未完了部分を翻訳する" }
        return "この資料を翻訳する"
    }
    static func queueStatusTitle(_ item: QueueItem, paused: Bool) -> String {
        switch item.status {
        case "queued": return paused ? "順番待ち（一時停止中）" : "順番待ち"
        case "running": return item.cancel_requested == true ? "停止を受け付けました" : "翻訳中"
        case "complete": return "翻訳完了"
        case "review": return "未翻訳・エラーの文章があります"
        case "confirmation": return "訳文を消す前に確認が必要"
        case "cancelled": return "予約取消・翻訳停止済み"
        default: return "エラー"
        }
    }
    static func options(_ p: Project) -> QueueOptions {
        QueueOptions(target: p.target, source: p.source, model: p.model, notes: p.include_notes ?? false, fit: p.fit)
    }
    static func changesLanguageOrModel(_ p: Project, _ options: QueueOptions) -> Bool {
        p.target != options.target || p.source != options.source || p.model != options.model
    }
    static func fingerprint(_ project: Project) throws -> String {
        // No display state, conversation or preview metadata: those may change
        // while inference is suspended without invalidating translation consent.
        let values = [project.id, project.source, project.target, project.model, String(project.include_notes ?? false), String(project.fit)]
            + project.units.flatMap { [$0.id, $0.kind, $0.source, $0.translation, $0.status] }
        return SHA256.hash(data: try JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }
    static func assess(_ p: Project, options: QueueOptions) throws -> TranslationAssessment {
        let count = p.units.filter { !$0.translation.isEmpty }.count
        return TranslationAssessment(projectID: p.id, filename: p.filename, fingerprint: try fingerprint(p),
                                     resetsTranslations: count > 0 && changesLanguageOrModel(p, options),
                                     translatedCount: count, options: options)
    }
    static func exportBlockReason(project p: Project, drafts: [String: String], options: QueueOptions, busy: Bool) -> String? {
        if busy { return "現在の保存・読み込みが終わるまでお待ちください。" }
        if p.state == "queued" { return "順番待ちです。翻訳が終わると保存できます。" }
        if p.state == "translating" { return "翻訳が終わると保存できます。" }
        if self.options(p) != options { return "変更した翻訳設定を反映してから保存してください。" }
        let units = p.units.filter { (p.include_notes ?? false) || $0.kind != "notes" }
        if units.contains(where: { drafts[$0.id] != nil && drafts[$0.id]!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "空白だけの訳文があります。訳文を入力してください。"
        }
        if units.contains(where: { !["done", "preserved"].contains($0.status) && drafts[$0.id] == nil }) {
            return "未翻訳・エラーの文章を翻訳するか、訳文を入力してから保存してください。"
        }
        return nil
    }
    static func previewFingerprint(_ p: Project, translated: Bool) throws -> String {
        translated ? try fingerprint(p) : "source-" + p.id
    }
    static func previewIsFresh(_ p: Project, translated: Bool, hasDrafts: Bool, options: QueueOptions) -> Bool {
        if translated && (hasDrafts || self.options(p) != options) { return false }
        let record = translated ? p.translated_preview : p.source_preview
        return record?.state == "ready" && record?.fingerprint == (try? previewFingerprint(p, translated: translated))
    }
}
