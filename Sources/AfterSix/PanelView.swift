import SwiftUI
import AfterSixCore

// Explicit type alias retains the macOS 13 property wrapper with SDK 27.
private typealias PanelState<Value> = SwiftUI.State<Value>

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendarSync: CalendarSyncModel
    @ObservedObject var plugins: PluginManagerModel
    @ObservedObject private var language = AppLanguage.shared
    @StateObject private var agenda: FeatureCalendarModel
    @PanelState private var editing = false
    @PanelState private var clockText = ""
    @PanelState private var initialClock = ""
    @PanelState private var editDay = ""
    @FocusState private var clockFocused: Bool
    @PanelState private var saveGeneration = 0
    @PanelState private var selectingType = false
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    let onOpenCalendar: () -> Void
    private let accent = Color(red: 0.16, green: 0.48, blue: 0.42)

    init(model: AppModel, calendarSync: CalendarSyncModel, plugins: PluginManagerModel,
         onOpenHistory: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
         onOpenCalendar: (() -> Void)? = nil) {
        self.model = model; self.calendarSync = calendarSync; self.plugins = plugins
        self.onOpenHistory = onOpenHistory; self.onOpenSettings = onOpenSettings
        self.onOpenCalendar = onOpenCalendar ?? onOpenSettings
        _agenda = StateObject(wrappedValue: FeatureCalendarModel(router: plugins.router))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 28, height: 28)
                    .accessibilityLabel("HappyLulu")
                Text("HappyLulu").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onOpenSettings) { Image(systemName: "gearshape").font(.system(size: 16)) }
                    .buttonStyle(.plain).frame(width: 28, height: 28)
                    .accessibilityLabel(L("설정", "Settings"))
            }
            VStack(alignment: .leading, spacing: 8) {
                TodayDayTypeView(model: model, onSelect: { type in
                    saveGeneration += 1
                    selectingType = true
                    defer { DispatchQueue.main.async { selectingType = false } }
                    return saveClock(dayType: type)
                })
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("출근", "Arrival")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        if editing {
                            TextField("09:00", text: $clockText)
                                .textFieldStyle(.plain).font(.system(size: 31, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(accent).focused($clockFocused)
                                .accessibilityLabel(L("출근 시각", "Arrival time"))
                                .background(ClockClickAwayMonitor(onClickAway: scheduleSave))
                                .onSubmit { _ = saveClock() }
                                .onExitCommand { editing = false; clockFocused = false; model.errorMessage = nil }
                        } else {
                            Button(action: beginEditing) {
                                Text(storedArrival.map { model.timeLabel($0.time) } ?? "—")
                                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                                    .monospacedDigit().foregroundStyle(accent)
                            }.buttonStyle(.plain).accessibilityLabel(L("출근 시각 수정", "Edit arrival time"))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(accent.opacity(0.12)).frame(width: 1, height: 52)
                    timeColumn(L("퇴근 예정", "Departure"), time: model.departure.map { model.timeLabel($0) } ?? "—")
                }
                if let error = model.errorMessage {
                    Text(visibleMessage(error)).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .topLeading)
            .background(accent.opacity(0.085), in: RoundedRectangle(cornerRadius: 12))
            Divider()
            TodayAgendaView(model: agenda, plugins: plugins, sync: calendarSync,
                            now: model.now, onOpenCalendar: onOpenCalendar)
        }
        .padding(16).frame(width: 364, height: 350, alignment: .topLeading)
        .tint(accent)
        .environment(\.locale, selectedLocale)
        .onAppear { model.refresh() }
        .onChange(of: clockFocused) { focused in
            if !focused && editing { scheduleSave() }
        }
        .onDisappear { if editing { _ = saveClock() } }
    }

    private func scheduleSave() {
        guard !selectingType else { return }
        let generation = saveGeneration
        DispatchQueue.main.async {
            if editing && generation == saveGeneration && !selectingType { _ = saveClock() }
        }
    }

    private func beginEditing() {
        model.refresh()
        initialClock = storedArrival.map { model.timeLabel($0.time) } ?? ""
        clockText = initialClock
        editDay = model.dayKey(model.now)
        model.errorMessage = nil
        editing = true
        clockFocused = true
    }

    @discardableResult private func saveClock(dayType: ManualDayType? = nil) -> Bool {
        guard editing else { return dayType.map { model.setDayType($0) } ?? true }
        let saved: Bool
        if clockText == initialClock {
            saved = dayType.map { model.setDayType($0) } ?? true
        } else {
            saved = model.saveManualClockText(clockText, forDay: editDay, dayType: dayType)
        }
        if saved { editing = false; clockFocused = false }
        return saved
    }

    private var storedArrival: Arrival? { model.state.arrivals[model.dayKey(model.now)] }
    private var selectedLocale: Locale { _ = language.choice; return displayLocale }
    private func timeColumn(_ label: String, time: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(time).font(.system(size: 31, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(accent)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClockClickAwayMonitor: NSViewRepresentable {
    var onClickAway: () -> Void
    final class Coordinator {
        var onClickAway: () -> Void
        var monitor: Any?
        init(_ action: @escaping () -> Void) { onClickAway = action }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onClickAway) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view, weak coordinator] event in
            guard let view, let window = view.window else { return event }
            if event.window !== window || !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                coordinator?.onClickAway()
            }
            return event
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onClickAway = onClickAway }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}
