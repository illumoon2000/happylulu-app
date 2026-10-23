import SwiftUI
import AfterSixCore

// Explicit type alias retains the macOS 13 property wrapper with SDK 27.
private typealias PanelState<Value> = SwiftUI.State<Value>

struct PanelView: View {
    var glass = LuluGlass()
    @ObservedObject private var appearance = AppearanceModel.shared
    @ObservedObject var model: AppModel
    @ObservedObject var calendarSync: CalendarSyncModel
    @ObservedObject var plugins: PluginManagerModel
    @ObservedObject private var language = AppLanguage.shared
    @StateObject private var agenda: FeatureCalendarModel
    @PanelState private var editing = false
    @PanelState private var clockEdit: ArrivalClockEdit?
    @PanelState private var editDay = ""
    @PanelState private var focusedDigit: Int?
    @PanelState private var saveGeneration = 0
    @PanelState private var selectingType = false
    @FocusState private var moreMenuFocused: Bool
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    let onOpenCalendar: () -> Void
    let onOpenPlugin: (String) -> Void
    private var accent: Color { appearance.accent }

    init(model: AppModel, calendarSync: CalendarSyncModel, plugins: PluginManagerModel,
         onOpenHistory: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
         onOpenCalendar: (() -> Void)? = nil, onOpenPlugin: ((String) -> Void)? = nil) {
        self.model = model; self.calendarSync = calendarSync; self.plugins = plugins
        self.onOpenHistory = onOpenHistory; self.onOpenSettings = onOpenSettings
        self.onOpenCalendar = onOpenCalendar ?? onOpenSettings
        self.onOpenPlugin = onOpenPlugin ?? { _ in onOpenSettings() }
        _agenda = StateObject(wrappedValue: FeatureCalendarModel(router: plugins.router))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: LuluBrand.headerIcon(for: model.luluDisplayState, vacationEve: model.isVacationEve))
                    .resizable().interpolation(.high).frame(width: 28, height: 28)
                    .accessibilityLabel("happylulu, \(model.luluStateLabel)")
                Text("happylulu").font(.system(size: 16, weight: .semibold))
                Spacer()
                moreMenu
            }
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    TodayDayTypeView(model: model, onSelect: { type in
                        saveGeneration += 1
                        selectingType = true
                        defer { DispatchQueue.main.async { selectingType = false } }
                        return saveClock(dayType: type)
                    })
                    switch model.luluDisplayState {
                    case .waiting, .readyToLeave, .dayOff:
                        Text(model.luluStateLabel).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary).lineLimit(1)
                            .help(model.luluStateLabel)
                    default:
                        EmptyView()
                    }
                }.frame(height: 42, alignment: .top)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("출근", "Arrival")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        if editing {
                            clockEditor
                        } else {
                            Button(action: beginEditing) {
                                HStack(spacing: 0) {
                                    ForEach(Array((storedArrival.map { model.timeLabel($0.time) } ?? "—").enumerated()), id: \.offset) { _, character in
                                        Text(String(character)).frame(width: character == ":" ? 9 : 20)
                                    }
                                }
                                .font(.system(size: 31, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(accent)
                                .frame(height: 34).padding(.vertical, 12)
                            }.buttonStyle(.plain).accessibilityLabel(L("출근 시각 수정", "Edit arrival time"))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(accent.opacity(0.12)).frame(width: 1, height: 52)
                    timeColumn(L("퇴근 예정", "Departure"), time: model.departure.map { model.timeLabel($0) } ?? "—", timeTopInset: 12)
                }
                if let error = model.errorMessage {
                    Text(visibleMessage(error)).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
                        .help(visibleMessage(error))
                }
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 156, maxHeight: 156, alignment: .topLeading)
            .background(appearance.surface.opacity(glass.isEnabled && !appearance.usesNativeAppearance ? 0.42 : 1),
                        in: RoundedRectangle(cornerRadius: glass.isEnabled ? 18 : 12))
            Divider()
            ForEach(plugins.menuBarItems) { item in
                Button { onOpenPlugin(item.id) } label: {
                    HStack {
                        Text(item.title).monospacedDigit()
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(item.accessibilityLabel)
            }
            TodayAgendaView(model: agenda, plugins: plugins, sync: calendarSync,
                            now: model.now, onOpenCalendar: onOpenCalendar)
        }
        .padding(16).frame(width: 364, height: CGFloat(350 + 40 * plugins.menuBarItems.count), alignment: .topLeading)
        .tint(accent)
        .foregroundStyle(appearance.text)
        .luluGlassSurface(tint: appearance.background, fallback: appearance.background,
                          cornerRadius: 24, legacyCornerRadius: 0, usesSystemAppearance: appearance.usesNativeAppearance)
        .luluWindowColorScheme(appearance.preferredColorScheme)
        .environment(\.locale, selectedLocale)
        .onAppear { model.refresh() }
        .onChange(of: focusedDigit) { digit in
            if digit == nil && editing {
                scheduleSave(onlyIfUnfocused: true)
            }
        }
        .onDisappear { if editing { _ = saveClock() } }
    }

    @ViewBuilder private var moreMenu: some View {
        let menu = Menu {
            Button(L("설정", "Settings"), action: onOpenSettings)
            Button(L("종료", "Quit")) { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($moreMenuFocused)
        .accessibilityLabel(L("더 보기", "More"))
        if appearance.usesNativeAppearance {
            menu.luluGlassButton()
        } else if #available(macOS 14, *) {
            // Custom palettes retain the existing transparent header control.
            menu.buttonStyle(PanelMenuButtonStyle(accent: accent, isFocused: moreMenuFocused))
                .focusEffectDisabled()
        } else {
            menu.buttonStyle(PanelMenuButtonStyle(accent: accent, isFocused: moreMenuFocused))
        }
    }

    private func scheduleSave() { scheduleSave(onlyIfUnfocused: false) }

    private func scheduleSave(onlyIfUnfocused: Bool) {
        guard !selectingType else { return }
        let generation = saveGeneration
        DispatchQueue.main.async {
            if editing && generation == saveGeneration && !selectingType
                && (!onlyIfUnfocused || focusedDigit == nil) { _ = saveClock() }
        }
    }

    private func beginEditing() {
        model.refresh()
        clockEdit = ArrivalClockEdit(existingTime: storedArrival?.time, now: model.now,
                                     timeZone: model.calendar.timeZone)
        editDay = model.dayKey(model.now)
        model.errorMessage = nil
        editing = true
        focusedDigit = 0
    }

    @discardableResult private func saveClock(dayType: ManualDayType? = nil) -> Bool {
        guard editing else { return dayType.map { model.setDayType($0) } ?? true }
        let saved: Bool
        guard let clockEdit else { return false }
        if !clockEdit.needsSave {
            saved = dayType.map { model.setDayType($0) } ?? true
        } else {
            saved = model.saveManualClockText(clockEdit.text, forDay: editDay, dayType: dayType)
        }
        if saved { editing = false; focusedDigit = nil }
        return saved
    }

    private var clockEditor: some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { index in
                if index == 2 { Text(":").frame(width: 9) }
                VStack(spacing: 0) {
                    digitButton(at: index, delta: 1, symbol: "plus")
                    ArrivalClockDigitField(text: Binding(
                        get: { clockEdit?.digits[index] ?? "" },
                        set: { value in clockEdit?.replaceDigit(at: index, with: value) }),
                        focusedDigit: $focusedDigit, index: index, color: NSColor(accent), label: digitLabel(index),
                        onPaste: { clockEdit?.replaceDigit(at: index, with: $0) },
                        onSubmit: { _ = saveClock() },
                        onCancel: { editing = false; focusedDigit = nil; model.errorMessage = nil })
                        .frame(width: 20, height: 34)
                        .background(focusedDigit == index ? accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                    digitButton(at: index, delta: -1, symbol: "minus")
                }.frame(width: 20)
            }
        }.font(.system(size: 31, weight: .semibold, design: .rounded))
            .monospacedDigit().foregroundStyle(accent)
            .background(ClockClickAwayMonitor(onClickAway: scheduleSave))
    }

    private func digitButton(at index: Int, delta: Int, symbol: String) -> some View {
        Button {
            clockEdit?.adjustDigit(at: index, by: delta)
            focusedDigit = index
        } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 3))
            .disabled(!(clockEdit?.canAdjustDigit(at: index, by: delta) ?? false))
            .accessibilityLabel(digitLabel(index) + L(delta > 0 ? " 증가" : " 감소", delta > 0 ? " increase" : " decrease"))
    }

    private func digitLabel(_ index: Int) -> String {
        [L("시 십의 자리", "Hour tens"), L("시 일의 자리", "Hour units"),
         L("분 십의 자리", "Minute tens"), L("분 일의 자리", "Minute units")][index]
    }

    private var storedArrival: Arrival? { model.state.arrivals[model.dayKey(model.now)] }
    private var selectedLocale: Locale { _ = language.choice; return displayLocale }
    private func timeColumn(_ label: String, time: String, timeTopInset: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(time).font(.system(size: 31, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(accent)
                .padding(.top, timeTopInset)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PanelMenuButtonStyle: ButtonStyle {
    let accent: Color
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? accent : .clear, lineWidth: 2))
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
