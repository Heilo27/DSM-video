import SwiftUI

// TASK-1066 · the profile editor's action row (Save, Cancel, Delete) and its PIN row.
//
// They were one fixed HStack each, inside an 80pt side inset (a tvOS margin) that left a 402pt
// iPhone's form only 242pt wide. Save (minWidth 160), a system `.bordered` Cancel, a `.bordered`
// "Delete Profile" label and 28pt gaps did not fit, and an HStack that cannot fit shrinks its
// flexible children before it overflows: Cancel wrapped one letter per line ("Ca/nc/el") and the
// Delete label wrapped into a 110x600 vertical pill. Nothing in the row said what to give up
// first. (ProfileEditorView now insets a phone by the screen-edge gutter, too.)
//
// Now the row says it. On iOS a `ViewThatFits` tries the compact arrangement first and falls back
// to a full-width stack when the labels (at the current Dynamic Type size) cannot sit side by
// side, so a label never has to break inside a word. Delete is always its own row, set apart from
// Save and Cancel by a larger gap and an error-coloured label, so it reads as the destructive
// action. tvOS keeps one row (Save, Cancel, then Delete at the far edge): the focus engine reaches
// them by successive Right presses (TVProfileEditorReachabilityTests).
//
// Buttons are the app's own styles (`dsPrimaryButton`, `dsSecondaryButton`), which supply font,
// height, fill and focus look; the call sites own `.focused` and the accessibility identifiers.

/// Save / Cancel / Delete for `ProfileEditorView`.
struct ProfileEditorActions: View {
  let saveTitle: String
  let canSave: Bool
  let showsDelete: Bool
  let focus: FocusState<ProfileEditorView.EditorControl?>.Binding
  let onSave: () -> Void
  let onCancel: () -> Void
  let onDelete: () -> Void

  /// Widest the iOS row grows, so on iPad it lines up with the age-rating list above it.
  private static let iPadMaxWidth: CGFloat = 520

  var body: some View {
    #if os(tvOS)
    HStack(spacing: .dsSpaceXXXL) {
      saveButton(fillsWidth: false)
      cancelButton(fillsWidth: false)
      Spacer()
      if showsDelete { deleteButton(fillsWidth: false) }
    }
    .focusSection()
    #else
    ViewThatFits(in: .horizontal) {
      // Compact: Save and Cancel side by side, Delete below. Labels are held to one line so this
      // candidate's ideal width is the true width of its words; it is chosen only if they fit.
      VStack(alignment: .leading, spacing: .dsSpaceXXL) {
        HStack(spacing: .dsSpaceMD) {
          saveButton(fillsWidth: true).lineLimit(1).fixedSize(horizontal: false, vertical: true)
          cancelButton(fillsWidth: false).lineLimit(1).fixedSize(horizontal: true, vertical: true)
        }
        if showsDelete { deleteButton(fillsWidth: true).lineLimit(1) }
      }
      // Stacked: every action full width, one under another. Words may wrap here; none is split.
      VStack(alignment: .leading, spacing: .dsSpaceMD) {
        saveButton(fillsWidth: true)
        cancelButton(fillsWidth: true)
        if showsDelete {
          deleteButton(fillsWidth: true).padding(.top, .dsSpaceMD)
        }
      }
    }
    .frame(maxWidth: Self.iPadMaxWidth, alignment: .leading)
    #endif
  }

  private func saveButton(fillsWidth: Bool) -> some View {
    Button(action: onSave) { Text(saveTitle) }
      .dsPrimaryButton(.card, fillsWidth: fillsWidth, minWidth: 160)
      .disabled(!canSave)
      .focused(focus, equals: .save)
      .accessibilityIdentifier(A11y.Profile.Editor.saveButton)
  }

  private func cancelButton(fillsWidth: Bool) -> some View {
    Button(action: onCancel) { Text("Cancel") }
      .dsSecondaryButton(fillsWidth: fillsWidth)
      .focused(focus, equals: .cancel)
      .accessibilityIdentifier(A11y.Profile.Editor.cancelButton)
  }

  private func deleteButton(fillsWidth: Bool) -> some View {
    Button(role: .destructive, action: onDelete) {
      Label("Delete Profile", systemImage: "trash").foregroundStyle(Color.dsError)
    }
    .dsSecondaryButton(fillsWidth: fillsWidth)
    .focused(focus, equals: .delete)
    .accessibilityIdentifier(A11y.Profile.Editor.deleteButton)
  }
}

/// "Off / Set PIN" and "On / Change PIN / Remove PIN" for `ProfileEditorView`.
struct ProfilePinRow: View {
  let hasPin: Bool
  let showsRemove: Bool
  let focus: FocusState<ProfileEditorView.EditorControl?>.Binding
  let onSetOrChange: () -> Void
  let onRemove: () -> Void

  var body: some View {
    #if os(tvOS)
    HStack(spacing: .dsSpaceXXL) {
      status.frame(minWidth: 80, alignment: .leading)
      setButton(fillsWidth: false)
      if showsRemove { removeButton(fillsWidth: false) }
    }
    #else
    // The state reads at the leading edge and the actions sit together at the trailing edge, so
    // the row has two ends and no button floating mid-row. When they cannot share a line the
    // state goes above full-width actions.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: .dsSpaceMD) {
        status.lineLimit(1).fixedSize()
        Spacer(minLength: .dsSpaceMD)
        setButton(fillsWidth: false).lineLimit(1).fixedSize(horizontal: true, vertical: true)
        if showsRemove {
          removeButton(fillsWidth: false).lineLimit(1).fixedSize(horizontal: true, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: .dsSpaceMD) {
        status
        setButton(fillsWidth: true)
        if showsRemove { removeButton(fillsWidth: true) }
      }
    }
    #endif
  }

  private var status: some View {
    Text(hasPin ? "On" : "Off")
      .font(ProfileMetrics.body)
      .foregroundStyle(.white)
  }

  private func setButton(fillsWidth: Bool) -> some View {
    Button(action: onSetOrChange) { Text(hasPin ? "Change PIN" : "Set PIN") }
      .dsSecondaryButton(fillsWidth: fillsWidth)
      .focused(focus, equals: .pinSet)
      .accessibilityIdentifier(A11y.Profile.Editor.pinSet)
  }

  private func removeButton(fillsWidth: Bool) -> some View {
    Button(action: onRemove) { Text("Remove PIN") }
      .dsSecondaryButton(fillsWidth: fillsWidth)
      .focused(focus, equals: .pinRemove)
      .accessibilityIdentifier(A11y.Profile.Editor.pinRemove)
  }
}
