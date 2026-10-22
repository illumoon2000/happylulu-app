import SwiftUI
import AfterSixCore

private typealias AppearanceState<Value> = SwiftUI.State<Value>

@MainActor
struct AppearanceSettingsView: View {
    @ObservedObject var appearance: AppearanceModel
    init(appearance: AppearanceModel = .shared) { self.appearance = appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: appearance.iconImage).resizable().scaledToFit().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("외관", "Appearance")).font(.title2.bold())
                    Text(L("테마, 색상과 앱 아이콘을 선택합니다.", "Choose your theme, colors and app icon."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = appearance.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            GroupBox(L("테마", "Theme")) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 10) {
                        ForEach(AppearancePalette.allCases, id: \.self) { palette in
                            Button { appearance.selectPalette(palette) } label: {
                                VStack(spacing: 7) {
                                    HStack(spacing: 0) {
                                        ForEach([AppearanceColorRole.sidebar, .background, .accent], id: \.self) { role in
                                            Color(nsColor: AppearanceModel.nsColor(palette.colors[role]!))
                                        }
                                    }.frame(height: 27).clipShape(RoundedRectangle(cornerRadius: 5))
                                    HStack(spacing: 3) {
                                        Text(palette.title).font(.caption).lineLimit(2)
                                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                        if appearance.preferences.palette == palette {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                }.padding(8).frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                                .accessibilityLabel(palette.title)
                                .accessibilityValue(appearance.preferences.palette == palette ? L("선택됨", "Selected") : "")
                        }
                    }
                    if !appearance.preferences.customColors.isEmpty {
                        Label(L("사용자 지정 색상", "Custom colors"), systemImage: "slider.horizontal.3").font(.caption)
                    }
                }.padding(8)
            }.disabled(appearance.isReadOnly)
            GroupBox(L("세부 색상", "Colors")) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AppearanceColorRole.allCases, id: \.self) { role in
                        AppearanceColorEditor(appearance: appearance, role: role)
                    }
                    HStack {
                        Spacer()
                        Button(L("현재 테마 기본값 복원", "Restore theme defaults")) { appearance.resetColors() }
                    }
                }.padding(8)
            }.disabled(appearance.isReadOnly)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(appearance.sidebar).frame(width: 35)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("미리보기", "Preview")).font(.headline)
                        Text(L("출퇴근 기록과 설정에 같은 색상을 사용합니다.", "Attendance and settings share these colors."))
                            .font(.callout)
                        Text(L("강조색", "Accent")).foregroundStyle(appearance.accent).font(.caption.bold())
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(appearance.surface)
                }.padding(10).foregroundStyle(appearance.text).background(appearance.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if appearance.hasLowContrast {
                    Label(L("글자 대비가 낮습니다. 가독성을 확인해 주세요.", "Low text contrast. Check readability."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            GroupBox(L("앱 아이콘", "App icon")) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], spacing: 10) {
                        ForEach(AppearanceIcon.allCases.filter { $0 != .custom }, id: \.self) { icon in
                            Button { appearance.selectIcon(icon) } label: {
                                VStack(spacing: 5) {
                                    Image(nsImage: appearance.image(for: icon)).resizable().scaledToFit().frame(width: 48, height: 48)
                                    Text(icon.title).font(.caption)
                                    if appearance.preferences.icon == icon { Image(systemName: "checkmark.circle.fill") }
                                }.frame(maxWidth: .infinity, minHeight: 90)
                            }.buttonStyle(.bordered).accessibilityLabel(icon.title)
                                .accessibilityValue(appearance.preferences.icon == icon ? L("선택됨", "Selected") : "")
                        }
                    }
                    HStack {
                        Button(L("PNG/JPEG 가져오기…", "Import PNG/JPEG…")) { appearance.importIcon() }
                        if appearance.preferences.customImageFilename != nil {
                            Button { appearance.selectIcon(.custom) } label: {
                                Label(L("사용자 이미지", "Custom image"), systemImage: appearance.preferences.icon == .custom ? "checkmark.circle.fill" : "photo")
                            }
                        }
                    }
                    Text(L("최대 20MB · 각 변 최대 8192px. 실행 중 아이콘만 바뀌며 Finder 설치 아이콘은 유지됩니다.", "Up to 20MB and 8192px per side. Changes the running app icon; Finder keeps the installed icon."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(appearance.isReadOnly)
        }.foregroundStyle(appearance.text)
    }
}

private struct AppearanceColorEditor: View {
    @ObservedObject var appearance: AppearanceModel
    let role: AppearanceColorRole
    @AppearanceState private var draft = ""
    @FocusState private var isFocused: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(role.title).frame(maxWidth: .infinity, alignment: .leading)
            ColorPicker(role.title, selection: Binding(get: { appearance.color(role) }, set: { appearance.setColor($0, for: role) }), supportsOpacity: false)
                .labelsHidden().accessibilityLabel(role.title)
            TextField("#RRGGBB", text: $draft)
                .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 110)
                .focused($isFocused).onSubmit { appearance.setColor(draft, for: role) }
                .onChange(of: isFocused) { focused in if !focused { appearance.setColor(draft, for: role) } }
                .onAppear { draft = appearance.hex(role) }
                .onChange(of: appearance.hex(role)) { draft = $0 }
                .accessibilityLabel(role.title + " HEX")
        }
    }
}

private extension AppearancePalette {
    var title: String {
        switch self {
        case .offwhiteLilac: L("오프화이트 라일락", "Off-white lilac")
        case .softMint: L("소프트 민트", "Soft mint")
        case .warmStone: L("웜 스톤", "Warm stone")
        case .blueGray: L("블루 그레이", "Blue gray")
        case .dustyLavender: L("더스티 라벤더", "Dusty lavender")
        case .charcoal: L("차콜", "Charcoal")
        }
    }
}
private extension AppearanceIcon {
    var title: String {
        switch self {
        case .original: L("기존 아이콘", "Original")
        case .mint: L("민트", "Mint")
        case .blue: L("블루", "Blue")
        case .lavender: L("라벤더", "Lavender")
        case .graphite: L("그라파이트", "Graphite")
        case .custom: L("사용자 이미지", "Custom image")
        }
    }
}
private extension AppearanceColorRole {
    var title: String {
        switch self {
        case .background: L("창 배경", "Window background")
        case .sidebar: L("사이드바", "Sidebar")
        case .surface: L("주요 카드", "Cards")
        case .accent: L("강조색", "Accent")
        case .text: L("본문", "Text")
        }
    }
}
