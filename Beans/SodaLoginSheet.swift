import SwiftUI
import UIKit
import WebKit

/// 汽水音乐登录页：网页登录（推荐）/ 手动粘贴 sessionid
/// 确认后自动下发 sessionid 并同步账号歌单。
struct SodaLoginSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: SodaLoginMode = .qr

    enum SodaLoginMode: String, CaseIterable, Identifiable {
        case qr = "扫码登录"
        case paste = "粘贴Session"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
            GlassBackdrop()
            VStack(spacing: 16) {
                Capsule()
                    .fill(Color.beansComment.opacity(0.3))
                    .frame(width: 38, height: 4)
                    .padding(.top, 12)

                HStack(spacing: 10) {
                    Image("BrandSoda")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("登录汽水音乐")
                        .font(BeansFont.appFont(20, .bold))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    Button {
                        BeansHaptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.beansComment)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.9))
                }
                .padding(.horizontal, 24)

                Picker("登录方式", selection: $mode) {
                    ForEach(SodaLoginMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)

                Group {
                    switch mode {
                    case .qr:
                        SodaQRLoginPanel(onSuccess: { dismiss() })
                    case .paste:
                        SodaSessionImportPanel(onSuccess: { dismiss() })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 扫码登录（抖音护照二维码，参考 qishui-api auth_qrcode / check_qrconnect）

struct SodaQRLoginPanel: View {
    @EnvironmentObject private var theme: ThemeStore
    @State private var qrImage: UIImage?
    @State private var qrToken = ""
    @State private var loading = true
    @State private var message = ""
    @State private var timer: Timer?
    @State private var finished = false
    let onSuccess: () -> Void

    var body: some View {
        let _ = theme.accent
        VStack(spacing: 16) {
            Text("请使用「抖音 APP」扫码登录（同一字节账号体系）。汽水音乐暂无独立账号，扫码授权后自动同步歌单")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .frame(width: 220, height: 220)
                if let qrImage {
                    Image(uiImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                } else if loading {
                    ProgressView("正在获取二维码…")
                        .tint(Color.beansAmber)
                }
            }
            .frame(width: 220, height: 220)

            if !message.isEmpty {
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.beansSage : Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button {
                refresh()
            } label: {
                Label("刷新二维码", systemImage: "arrow.clockwise")
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.beansAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
            .padding(.horizontal, 20)

            Spacer(minLength: 8)
        }
        .onAppear { refresh() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func refresh() {
        timer?.invalidate(); timer = nil
        loading = true
        qrImage = nil
        message = ""
        Task {
            do {
                let info = try await SodaAuth.shared.fetchLoginQR()
                await MainActor.run {
                    qrImage = UIImage(data: info.imageData)
                    qrToken = info.token
                    loading = false
                    startPolling()
                }
            } catch {
                await MainActor.run {
                    loading = false
                    message = error.localizedDescription
                }
            }
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            poll()
        }
    }

    private func poll() {
        let token = qrToken
        guard !token.isEmpty, !finished else { return }
        Task {
            let status = await SodaAuth.shared.pollLoginQR(token: token)
            await MainActor.run {
                switch status {
                case .waiting:
                    message = "等待扫码…"
                case .scanned:
                    message = "已扫码，请在手机上确认授权"
                case .success:
                    finishSuccess()
                case .expired:
                    timer?.invalidate(); timer = nil
                    message = "二维码已过期，请点击刷新"
                case .error(let err):
                    message = err
                }
            }
        }
    }

    private func finishSuccess() {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        message = "✓ 汽水音乐登录成功，正在同步歌单…"
        BeansHaptics.success()
        Task {
            let error = await SodaAuth.shared.verifyLogin()
            await MainActor.run {
                if let error {
                    message = "登录成功，但歌单同步失败：\(error)"
                    ToastCenter.shared.show("汽水登录成功，歌单同步失败")
                } else {
                    message = "✓ 汽水音乐登录成功，歌单已同步"
                    ToastCenter.shared.show("汽水音乐登录成功")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        onSuccess()
                    }
                }
            }
        }
    }
}

// MARK: - WKWebView 封装（打开抖音网页版授权登录，读取同体系登录态 Cookie）

struct SodaWebView: UIViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://www.douyin.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 自动点击「登录」按钮弹出登录框（抖音为 SPA，登录按钮由 JS 触发）
            let autoLoginJS = """
            (() => {
              const tryClick = () => {
                const els = document.querySelectorAll('button, [role="button"], div, span, a');
                for (const el of els) {
                  const t = (el.textContent || '').trim();
                  if (t === '登录' && el.offsetParent !== null) { el.click(); return true; }
                }
                return false;
              };
              if (!tryClick()) setTimeout(tryClick, 900);
            })();
            """
            webView.evaluateJavaScript(autoLoginJS, completionHandler: nil)
            DispatchQueue.main.async {
                self.onLoaded()
            }
        }
    }
}

// MARK: - 手动粘贴 sessionid

struct SodaSessionImportPanel: View {
    @EnvironmentObject private var theme: ThemeStore
    @State private var sessionText = ""
    @State private var message = ""
    let onSuccess: () -> Void

    var body: some View {
        let _ = theme.accent
        VStack(spacing: 12) {
            Text("在电脑浏览器登录汽水音乐网页版或抖音网页版后，按 F12 → Application → Cookies，找到 sessionid 的值复制到下方；也可以直接粘贴整段 Cookie（会自动提取 sessionid）")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            TextEditor(text: $sessionText)
                .font(BeansFont.appFont(11, .regular, .monospaced))
                .beansScrollContentBackgroundHidden()
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(height: 160)
                .padding(.horizontal, 20)

            if !message.isEmpty {
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.beansSage : Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button {
                importSession()
            } label: {
                Label("导入登录态", systemImage: "arrow.down.doc")
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.beansAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
            .padding(.horizontal, 20)

            Spacer(minLength: 8)
        }
        .padding(.top, 8)
    }

    private func importSession() {
        let raw = sessionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            message = "未找到有效的 sessionid，请确认已完整复制"
            return
        }
        if raw.contains(";") || raw.contains("sessionid=") {
            guard SodaAuth.shared.importCookieHeader(raw) else {
                message = "未找到有效的 sessionid，请确认已完整复制"
                return
            }
        } else {
            SodaAuth.shared.importSessionID(raw)
        }
        message = "正在验证登录状态…"
        Task {
            let error = await SodaAuth.shared.verifyLogin()
            await MainActor.run {
                if let error {
                    message = "登录失败：\(error)"
                    ToastCenter.shared.show("汽水登录失败")
                } else {
                    message = "✓ 汽水音乐登录成功"
                    BeansHaptics.success()
                    ToastCenter.shared.show("汽水音乐登录成功")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        onSuccess()
                    }
                }
            }
        }
    }
}
