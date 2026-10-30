import MKCore
import MKLayout

/// What the layout editor asks of the session.
extension MenuBarSession {
    /// A drop, a "Move to", "Move Left"/"Move Right" or an "Add" of the layout editor, made on the model as it is now.
    ///
    /// The request says which tokens the thing lands between, not where in the list: the list is the session's, and may not be the one the
    /// drop was worked out on (a change before it still being made, a read that listed an app). The place in the list is worked out here,
    /// on the session's model, by the calls the other changes make, and nothing between that and the change: it is one step of the
    /// session. When a token it lands beside has left the strip, or it wouldn't land between them on this model, nothing is written, and
    /// the log says so.
    ///
    /// - Returns: what was done, nil when the request was declined.
    @discardableResult
    public func drop(_ request: DropRequest) async -> EditorOperation? {
        guard let operation = LayoutEditorModel.resolve(request, sections: sections, inventory: inventory) else {
            Log.info("session", "a drop in the layout editor wasn't made: it no longer lands where it was dropped")
            return nil
        }
        switch operation {
        case .insert(let item, let section, let index):
            await insert(item, in: section, at: index)
        case .moveToGroup(let bundleID, let group, let index):
            await move(app: bundleID, toGroup: group, at: index)
        case .addSpacer(let section, let index):
            var spacer = LayoutSpacer()
            if case .spacer(let made)? = request.created { spacer = made }
            await addSpacer(spacer, in: section, at: index)
        case .addGroup(let section, let index):
            var group = IconGroup()
            if case .group(let made)? = request.created { group = made }
            await addGroup(group, in: section, at: index)
        case .marker(let section, let index):
            await setNewItemsMarker(section: section, index: index)
        case .noChange, .refused:
            break
        }
        return operation
    }
}
