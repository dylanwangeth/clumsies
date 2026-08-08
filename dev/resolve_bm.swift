import Foundation

let path = "/tmp/bm.txt"
let b64 = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let data = Data(base64Encoded: b64) else {
    print("base64 decode failed")
    exit(1)
}
print("bookmark bytes:", data.count)

func tryResolve(_ label: String, _ options: URL.BookmarkResolutionOptions) {
    var stale = false
    do {
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        print("\(label): OK path=\(url.path) stale=\(stale)")
    } catch {
        print("\(label): FAIL \(error)")
    }
}

tryResolve("withSecurityScope", [.withSecurityScope, .withoutUI, .withoutMounting, .withoutImplicitStartAccessing])
tryResolve("withoutSecurityScope", [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing])
tryResolve("plain", [])

// Also: does the path currently exist and is it reachable?
let fm = FileManager.default
print("path exists:", fm.fileExists(atPath: "/Users/weiwang/workspace/DylanVault/clumsies"))
print("canonical:", URL(fileURLWithPath: "/Users/weiwang/workspace/DylanVault/clumsies").standardizedFileURL.path)
