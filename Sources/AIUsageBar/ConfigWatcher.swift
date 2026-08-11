import Foundation

/// Watches `config.toml` with a `DispatchSource` and fires `onChange` when it
/// is written or atomically replaced (editors rename a temp file over it, so
/// the source re-arms on delete/rename by re-opening the path). When the file
/// does not exist yet, the parent directory is watched until it appears.
final class ConfigWatcher {
    private let path: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(path: URL, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    deinit {
        source?.cancel()
    }

    private func arm() {
        source?.cancel()
        source = nil

        let watchingFile = FileManager.default.fileExists(atPath: path.path)
        let target = watchingFile ? path : path.deletingLastPathComponent()
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            self.fire()
            // An atomic save deletes/renames the watched node; re-open the
            // fresh file (or keep watching the directory) so we keep firing.
            if !events.isDisjoint(with: [.delete, .rename]) || !watchingFile {
                self.arm()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
