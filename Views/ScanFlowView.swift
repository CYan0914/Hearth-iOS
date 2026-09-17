import PhotosUI
import SwiftUI

/// Photograph a nameplate, confirm what was read, get a schedule.
///
/// This is the screen the product lives or dies on. The plan's finding was that
/// this category fails because value arrives too slowly -- record fifteen
/// appliances, get nothing back for eight months -- so the confirm step shows the
/// task count *before* anything is created, and the step after creation shows the
/// schedule that now exists. The value is visible in the same session as the
/// effort.
///
/// Four steps in one sheet, as a state machine rather than a NavigationStack: the
/// steps share the captured photo and the classification, and back-navigation
/// between them would have to unwind half-created state.
struct ScanFlowView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .capture
    @State private var image: UIImage?
    @State private var ocrText: String?
    @State private var scan: ScanResult?
    @State private var draft = AssetDraft()
    @State private var error: String?
    @State private var isWorking = false
    @State private var created: AssetCreateResponse?

    /// Generated once per scan session and reused for every create attempt. This
    /// is what makes a retry after a timeout safe: the server sees the same
    /// `client_ref` and returns the asset it already made instead of a second one.
    @State private var clientRef = UUID().uuidString

    enum Step: Equatable {
        case capture
        case reading
        case confirm
        case creating
        case done
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .capture, .reading:
                    CaptureStep(image: $image, isReading: step == .reading, onPick: handlePicked)
                case .confirm:
                    ConfirmStep(
                        scan: scan,
                        draft: $draft,
                        image: image,
                        error: error,
                        isWorking: isWorking,
                        onCategory: chooseCategory,
                        onConfirm: create
                    )
                case .creating:
                    CreatingStep()
                case .done:
                    DoneStep(result: created, asset: draft, onDone: { dismiss() })
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if step == .confirm, let scan, !scan.isConfident {
                    // Only offered when the classifier was unsure, because that
                    // is the only case where a different category would change
                    // the schedule the user is about to accept.
                    ToolbarItem(placement: .primaryAction) {
                        Button("Change type") { step = .capture }
                    }
                }
            }
        }
        .interactiveDismissDisabled(step == .creating)
    }

    private var title: String {
        switch step {
        case .capture: return "Scan a nameplate"
        case .reading: return "Reading…"
        case .confirm: return "Confirm"
        case .creating: return "Setting up…"
        case .done: return "Scheduled"
        }
    }

    // MARK: - Capture → classify

    private func handlePicked(_ picked: UIImage) {
        image = picked
        error = nil
        step = .reading

        Task {
            do {
                let ocr = try await NameplateOCR.read(picked)
                ocrText = ocr.text
                let result = try await HearthAPI.classify(ocrText: ocr.text)
                scan = result
                draft = AssetDraft(from: result, ocrText: ocr.text)
                step = .confirm
            } catch {
                self.error = error.localizedDescription
                // Back to capture, not stuck on a spinner: the fix for an
                // unreadable photo is another photo.
                step = .capture
            }
        }
    }

    /// A chip was tapped. The selection is applied immediately -- the tap must
    /// feel instant -- and the preview is re-fetched behind it.
    ///
    /// Re-running the classifier is not optional here: the headline of the
    /// confirm screen is "6 tasks scheduled", and that number belongs to the old
    /// category until the server has been asked about the new one. Leaving it
    /// would make the app promise a schedule it is not going to create.
    private func chooseCategory(_ option: CategoryOption) {
        guard option.id != draft.category else { return }
        draft.category = option.id
        draft.categoryLabel = option.label
        error = nil
        isWorking = true

        Task {
            defer { isWorking = false }
            do {
                let result = try await HearthAPI.classify(ocrText: ocrText, hintCategory: option.id)
                scan = result
                draft.apply(result, keepingCategory: option.id)
            } catch {
                // The chip stays selected and the previous preview stays on
                // screen with the error above it. Reverting the user's choice
                // silently would be worse than showing a stale count they have
                // been told is stale.
                self.error = "Could not load the schedule for that type: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Create

    private func create() {
        step = .creating
        error = nil

        Task {
            do {
                var payload = draft.payload
                payload.clientRef = clientRef
                payload.fromScan = true

                let response = try await HearthAPI.createAsset(payload)

                // Attach the nameplate photo. A failure here does not fail the
                // scan: the asset and its schedule exist, which is the value the
                // user came for, and a missing photo is fixable from the asset
                // screen later.
                if let image {
                    do {
                        _ = try await PhotoUploader.upload(image, forAsset: response.asset.id, kind: .modelPlate)
                    } catch {
                        print("[Hearth] nameplate upload failed: \(error.localizedDescription)")
                    }
                }

                created = response
                step = .done
                await session.refresh()
            } catch {
                self.error = error.localizedDescription
                // Back to confirm with everything the user typed intact. The
                // client_ref is unchanged, so a retry cannot create a duplicate.
                step = .confirm
            }
        }
    }
}

// MARK: - Step 1: capture

/// Camera or library, one photo.
///
/// Not a custom camera with a live overlay: a nameplate is a small, badly lit
/// label in an awkward place, and the system camera already has focus/exposure
/// controls, the flash, and a retina preview. Reproducing those badly would be
/// worse than the one extra tap.
private struct CaptureStep: View {
    @Binding var image: UIImage?
    let isReading: Bool
    let onPick: (UIImage) -> Void

    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 54))
                .foregroundStyle(Theme.ember)

            VStack(spacing: 8) {
                Text("Point at the label")
                    .font(.headline)
                Text("The sticker on the side or back with the brand and model number. Anything with text works — the app will do its best.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            if isReading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the label…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            if let error {
                ErrorBanner(message: error)
                    .padding(.horizontal, 24)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take a photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isReading)
                .padding(.horizontal, 24)

                PhotosPicker(selection: $libraryItem, matching: .images, photoLibrary: .shared()) {
                    Text("Choose from library")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isReading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { picked in
                showCamera = false
                if let picked { onPick(picked) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let picked = UIImage(data: data)
                    else {
                        error = "That image could not be opened. Try another one."
                        return
                    }
                    onPick(picked)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// The system camera, wrapped. `UIImagePickerController` rather than
/// `AVCaptureSession` because it is the camera the user already knows, including
/// the flash control and the tap-to-focus behaviour.
private struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDone(nil)
        }
    }
}

// MARK: - Step 2: confirm

/// What was read, what it will schedule, and the fields worth correcting.
///
/// The task count is the headline, not the asset name: the user's question at
/// this moment is "what do I get for this", and "6 tasks scheduled" answers it.
private struct ConfirmStep: View {
    let scan: ScanResult?
    @Binding var draft: AssetDraft
    let image: UIImage?
    let error: String?
    let isWorking: Bool
    let onCategory: (CategoryOption) -> Void
    let onConfirm: () -> Void

    @State private var showAllFields = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                }

                if let error {
                    ErrorBanner(message: error)
                }

                scheduleCard
                fieldsCard
            }
            .padding(Theme.gutter)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Button(action: onConfirm) {
                Text(confirmTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.category.isEmpty)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var confirmTitle: String {
        if let count = scan?.tasksPreviewCount, count > 0 {
            return "Add to my home"
        }
        // An unknown category schedules nothing, and saying so here is the
        // honest thing -- the alternative is a silent asset with no reminders.
        return "Add without a schedule"
    }

    private var scheduleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(scan?.tasksPreviewCount ?? 0)")
                        .font(Theme.bigNumber)
                        .foregroundStyle(Theme.ember)
                    Text(scan?.tasksPreviewCount == 1 ? "task scheduled" : "tasks scheduled")
                        .font(.headline)
                    Spacer()
                }

                if let items = scan?.templatePreview, !items.isEmpty {
                    Text("For a \(scan?.suggestedCategoryLabel?.lowercased() ?? draft.category):")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.isSafety ? "exclamationmark.triangle.fill" : "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(item.isSafety ? .red : Theme.ember)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline)
                                HStack(spacing: 6) {
                                    Text(item.cadenceLabel)
                                    if item.isSafety { Text("· Safety") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if item.isSafety, let note = item.safetyNote {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if let first = items.first?.cadenceLabel {
                        Text("First reminder \(first.lowercased()) from today.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                } else {
                    Text("We could not tell what this is, so no reminders were set up. You can pick a type below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fieldsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                // Only when the classifier failed. A chip row on a good scan
                // would invite the user to second-guess a correct answer.
                if let options = scan?.categoryOptions, !options.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("What is it?")
                                .font(.subheadline.weight(.semibold))
                            if isWorking { ProgressView().controlSize(.small) }
                        }
                        CategoryChips(
                            options: options,
                            selected: draft.category,
                            onSelect: onCategory
                        )
                    }
                    Divider()
                }

                LabeledField(title: "Name", text: $draft.name, placeholder: "Kitchen fridge")

                if let label = scan?.suggestedCategoryLabel, !label.isEmpty,
                   scan?.categoryOptions.isEmpty ?? true {
                    HStack {
                        Text("Type").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(label).font(.subheadline)
                    }
                }

                // The three fields the classifier reads. Shown as read, editable
                // in place, because the common correction is one wrong character
                // in a model number -- not a reason to open a separate screen.
                LabeledField(title: "Brand", text: $draft.brand, placeholder: "Optional")
                LabeledField(title: "Model", text: $draft.model, placeholder: "Optional")

                if showAllFields {
                    LabeledField(title: "Serial", text: $draft.serial, placeholder: "Optional")
                    LabeledField(title: "Location", text: $draft.location, placeholder: "Kitchen")
                } else {
                    Button(showAllFields ? "Fewer fields" : "Add serial, location, purchase details") {
                        withAnimation { showAllFields = true }
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

/// A wrapping row of category choices.
///
/// Hand-rolled rather than a `Picker`: 27 categories in a wheel is a scroll
/// through most of them, and a menu hides the fact that there is a choice to
/// make. The chips show the schedule size, which is the information that makes
/// picking one worth the tap.
private struct CategoryChips: View {
    let options: [CategoryOption]
    let selected: String
    let onSelect: (CategoryOption) -> Void

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(option.templateCount == 1 ? "1 task" : "\(option.templateCount) tasks")
                            .font(.caption2)
                            .foregroundStyle(selected == option.id ? .white.opacity(0.8) : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        selected == option.id ? Theme.ember : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .foregroundStyle(selected == option.id ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A text field with a label above it, sized for a form that is mostly optional.
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(title == "Location" || title == "Name" ? .words : .never)
        }
    }
}

// MARK: - Step 3 & 4

private struct CreatingStep: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Setting up your schedule…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// The payoff screen. `POST /assets` returned the schedule, so this renders from
/// the create response -- no second request, no spinner, no chance of the screen
/// disagreeing with what was actually created.
private struct DoneStep: View {
    let result: AssetCreateResponse?
    let asset: AssetDraft
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                    .padding(.top, 26)

                Text(asset.name.isEmpty ? "Added" : asset.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let schedule = result?.schedule {
                    VStack(spacing: 6) {
                        Text("\(schedule.tasksScheduled)")
                            .font(Theme.bigNumber)
                            .foregroundStyle(Theme.ember)
                        Text(schedule.tasksScheduled == 1 ? "reminder set up" : "reminders set up")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let next = schedule.nextDue {
                            Text("Next one \(next.relativeDescription().lowercased()).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if let titles = schedule.titles, !titles.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(titles, id: \.self) { title in
                                    HStack(spacing: 8) {
                                        Image(systemName: "calendar")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.ember)
                                        Text(title).font(.subheadline)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.gutter)
                    }
                } else if result?.duplicate == true {
                    // The idempotent replay. Saying so is better than silently
                    // showing a schedule that was created on the earlier attempt.
                    Text("This was already added, so nothing was duplicated.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                } else {
                    Text("No reminders were set up for this one. You can add your own from the asset's page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer(minLength: 20)

                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 22)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}
