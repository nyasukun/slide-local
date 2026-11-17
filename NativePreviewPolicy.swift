import Foundation

/// The renderer receives one sanitized package and an empty profile, never the app's data directory.
struct NativePreviewPolicy {
    static let sandbox = """
    (version 1)
    (deny default)
    (allow process-exec (subpath (param "LO_APP")))
    (allow sysctl-read)
    (allow system-info (info-type "vfs.disk-space"))
    (allow file-read-metadata)
    (allow file-read-data (require-all (vnode-type DIRECTORY) (require-any (literal "/") (path-ancestors (param "RENDER_ROOT")))))
    (allow file-read*
      (subpath (param "LO_APP"))
      (subpath "/System/Library")
      (subpath "/usr/lib")
      (subpath "/usr/share")
      (subpath "/private/var/db/timezone")
      (subpath "/Library/Fonts")
      (subpath (param "USER_FONTS"))
      (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom")
      (literal "/private/etc/localtime"))
    (allow mach-lookup
      (global-name "com.apple.coreservices.launchservicesd")
      (global-name "com.apple.windowserver.active")
      (global-name "com.apple.FontObjectsServer")
      (global-name "com.apple.fonts")
      (global-name "com.apple.system.logger"))
    (allow file-read* file-write* (subpath (param "RENDER_ROOT")))
    (deny lsopen)
    (deny appleevent-send)
    (deny network*)
    (deny system-socket (socket-domain AF_INET))
    (deny system-socket (socket-domain AF_INET6))
    (allow system-socket (socket-domain AF_UNIX))
    (allow network-bind (local unix-socket (subpath (param "RENDER_ROOT"))))
    (allow network-inbound (local unix-socket (subpath (param "RENDER_ROOT"))))
    (allow network-outbound (remote unix-socket (subpath (param "RENDER_ROOT"))))
    """
    static let preferences = """
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry">
      <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
        <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
        <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
      </item>
    </oor:items>
    """
    static func physicalPath(_ url: URL) throws -> String {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else { throw StudioError("描画用ファイルの実体を確認できません。") }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func environment(root: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path,
         "TMPDIR": root.appendingPathComponent("tmp").path + "/", "LANG": "ja_JP.UTF-8", "SAL_SKIA": "raster"]
    }
    static func promotePDF(root: URL, destination: URL) throws {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw StudioError("描画結果の保存先を検証できません。") }
        defer { close(rootFD) }
        let resultFD = openat(rootFD, "result", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard resultFD >= 0 else { throw StudioError("描画結果のディレクトリが不正です。") }
        defer { close(resultFD) }
        let inputFD = openat(resultFD, "input.pdf", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard inputFD >= 0 else { throw StudioError("描画結果が通常のPDFファイルではありません。") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(inputFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size > 0 else { throw StudioError("描画結果の種類を検証できません。") }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".SlideLocal-preview-" + newID())
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw StudioError("プレビューを保存できません。") }
        let output = try FileHandle(forWritingTo: staged); defer { try? output.close() }
        var remaining = before.st_size
        while remaining > 0 {
            guard let data = try input.read(upToCount: Int(min(remaining, 1048576))), !data.isEmpty else { throw StudioError("描画結果が途中で変更されました。") }
            try output.write(contentsOf: data); remaining -= Int64(data.count)
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw StudioError("描画中にファイルが変更されたため、安全のため保存を止めました。") }
        try output.synchronize(); try output.close()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
    }

}
