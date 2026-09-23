import SwiftUI

struct MainPopoverView: View {
    enum Mode { case popover, window }

    let monitor: AudioProcessMonitor
    let output: OutputDeviceController
    let presentation: AppPresentation
    let mode: Mode

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .popover {
                popoverHeader
                Divider()
            }

            OutputSectionView(output: output)

            Divider()

            sectionHeader("앱")
            permissionBanner

            if monitor.apps.isEmpty {
                Text("소리를 내는 앱이 여기 표시됩니다.\n음악이나 영상을 재생해 보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                // MenuBarExtra 팝오버는 뷰의 "이상적 크기"로 창을 잡는데 ScrollView 의 이상적 높이는 0 이라
                // 목록이 접혀버린다. 행 높이가 고정이므로 개수로 높이를 직접 계산해 준다.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.apps) { app in
                            AppRowView(app: app, monitor: monitor)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(height: min(CGFloat(monitor.apps.count) * AppRowView.height + 6, 440))
            }

            if let message = monitor.errorMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch monitor.permission.status {
        case .granted:
            EmptyView()
        case .unknown:
            banner(
                icon: "hourglass",
                text: "시스템 오디오 녹음 권한을 요청하는 중입니다. 프롬프트에서 허용해 주세요.",
                buttonTitle: "다시 확인"
            ) {
                monitor.permission.refresh()
                monitor.refresh()
            }
        case .denied:
            banner(
                icon: "exclamationmark.triangle.fill",
                text: "앱별 볼륨 조절에는 시스템 오디오 녹음 권한이 필요합니다.",
                buttonTitle: "설정 열기"
            ) {
                AudioCapturePermission.openSystemSettings()
            }
        }
    }

    private func banner(icon: String, text: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
            Spacer(minLength: 0)
            Button(buttonTitle, action: action)
                .font(.caption)
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// 팝오버 상단: 제목 + "창으로 열기" 버튼 (SoundSource 의 detach 와 같은 역할)
    private var popoverHeader: some View {
        HStack {
            Text("Tapmix")
                .font(.headline)
            Spacer()
            Button {
                openWindow(id: AppPresentation.windowID)
                dismiss()
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("창으로 열기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Menu {
                Toggle("Dock 에 아이콘 표시", isOn: Binding(
                    get: { presentation.showInDock },
                    set: { presentation.showInDock = $0 }
                ))
                Toggle("창을 항상 위에", isOn: Binding(
                    get: { presentation.keepWindowOnTop },
                    set: { presentation.keepWindowOnTop = $0 }
                ))
                Toggle("시작할 때 창 열기", isOn: Binding(
                    get: { presentation.openWindowAtLaunch },
                    set: { presentation.openWindowAtLaunch = $0 }
                ))
                Divider()
                Button("권한 설정 열기") { AudioCapturePermission.openSystemSettings() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)

            Spacer()

            if mode == .window {
                Button("메뉴바로 접기") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
            }

            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
