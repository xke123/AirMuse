import AppKit
import DesignSystem

// MARK: - SearchBarView

/// Top search bar wrapper with 300ms debounce timer and scope support.
@MainActor
open class SearchBarView: NSView {

    public var onDebouncedQuery: ((String, Int) -> Void)?

    private let searchField = GlassSearchField()
    private var debounceTask: Task<Void, Never>?
    private var currentScope: Int = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        debounceTask?.cancel()
    }

    private func setup() {
        searchField.frame = bounds
        searchField.autoresizingMask = [.width, .height]
        addSubview(searchField)

        searchField.onScopeChanged = { [weak self] scope in
            guard let self else { return }
            self.currentScope = scope
        }

        searchField.onQueryChanged = { [weak self] query in
            guard let self else { return }
            self.debounceTask?.cancel()
            self.debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.onDebouncedQuery?(query, self.currentScope)
            }
        }
    }
}
