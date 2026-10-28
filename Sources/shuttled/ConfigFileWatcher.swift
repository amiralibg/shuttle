import Foundation

/// Calls `onChange` on the main queue when the config file changes.
///
/// Two watches, because editors save two ways. Some write a new file and
/// rename it over the old one: only the directory sees that. Others (VS Code,
/// Zed) write into the file in place: only a watch on the file sees that. The
/// file watch is re-armed after every change, since a rename-save leaves it
/// watching a file that no longer has the name.
final class ConfigFileWatcher: @unchecked Sendable {
    private let file: URL
    private let onChange: @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(file: URL, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.onChange = onChange
    }

    func start() {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directorySource = watch(directory.path, [.write, .rename, .delete])
        fileSource = watch(file.path, [.write, .extend, .rename, .delete, .attrib])
    }

    func stop() {
        directorySource?.cancel()
        fileSource?.cancel()
        directorySource = nil
        fileSource = nil
    }

    private func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    /// Trailing debounce: one save is several events.
    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fileSource?.cancel()
            self.fileSource = self.watch(self.file.path, [.write, .extend, .rename, .delete, .attrib])
            self.onChange()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}
