import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LLM Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct LLMSettingsCard: View, SettingsCardHelpers {

    @State private var selectedLLMProvider: LLMProvider = .doubao
    @State private var llmCredentialValues: [String: String] = [:]
    @State private var savedLLMValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var llmTestStatus: SettingsTestStatus = .idle
    @State private var isEditingLLM = true
    @State private var hasStoredLLM = false
    @State private var testTask: Task<Void, Never>?
    @State private var serverStarting = false
    @State private var serverRunning = false

    private var currentLLMFields: [CredentialField] {
        LLMProviderRegistry.configType(for: selectedLLMProvider)?.credentialFields ?? []
    }

    /// Effective values: saved base + dirty edits overlaid.
    private var effectiveLLMValues: [String: String] {
        var result = savedLLMValues
        for key in editedFields {
            result[key] = llmCredentialValues[key] ?? ""
        }
        return result
    }

    private var hasLLMCredentials: Bool {
        let required = currentLLMFields.filter { !$0.isOptional }
        let effective = effectiveLLMValues
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("LLM 文本处理", "LLM Settings"), icon: "gearshape.fill") {
            llmProviderPicker
            SettingsDivider()

            if selectedLLMProvider == .localQwen {
                localQwenStatusView
            } else if hasLLMCredentials && !isEditingLLM {
                credentialSummaryCard(rows: llmSummaryRows)
            } else {
                dynamicCredentialFields
            }

            HStack(spacing: 8) {
                Spacer()
                if selectedLLMProvider == .localQwen {
                    testButton(L("测试连接", "Test"), status: llmTestStatus) { testLLMConnection() }
                        .disabled(!LocalQwenLLMConfig.isModelAvailable)
                    primaryButton(L("保存", "Save")) { saveLLMCredentials() }
                } else {
                    testButton(L("测试连接", "Test"), status: llmTestStatus) { testLLMConnection() }
                        .disabled(!hasLLMCredentials)
                    if hasLLMCredentials && !isEditingLLM {
                        secondaryButton(L("修改", "Edit")) {
                            testTask?.cancel()
                            llmTestStatus = .idle
                            llmCredentialValues = [:]
                            editedFields = []
                            isEditingLLM = true
                        }
                    } else {
                        if hasLLMCredentials && hasStoredLLM {
                            secondaryButton(L("取消", "Cancel")) {
                                testTask?.cancel()
                                llmTestStatus = .idle
                                loadLLMCredentials()
                            }
                        }
                        primaryButton(L("保存", "Save")) { saveLLMCredentials() }
                            .disabled(!hasLLMCredentials)
                    }
                }
            }
            .padding(.top, 12)
        }
        .task {
            loadLLMCredentials()
        }
    }

    // MARK: - Local Qwen Status

    private var localQwenStatusView: some View {
        let model = LocalQwenLLMConfig.availableModel
        let modelAvailable = model != nil
        return VStack(alignment: .leading, spacing: 8) {
            // Model status
            HStack(spacing: 8) {
                Image(systemName: modelAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(modelAvailable ? TF.settingsAccentGreen : TF.settingsAccentRed)
                    .font(.system(size: 14))
                Text(modelAvailable
                    ? L("模型已就绪", "Model ready")
                    : L("模型未找到", "Model not found"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TF.settingsText)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let model {
                    Text("\(model.displayName)-Q4_K_M (GGUF)")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                    Text(L("~\(String(format: "%.1f", model.sizeGB))GB, Metal GPU 加速, \(model.tokPerSec) tok/s",
                           "~\(String(format: "%.1f", model.sizeGB))GB, Metal GPU, \(model.tokPerSec) tok/s"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                } else {
                    Text(L("支持 Qwen3.5-9B (推荐) 或 Qwen3-4B",
                           "Supports Qwen3.5-9B (recommended) or Qwen3-4B"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                    Text(L("请将 GGUF 模型放到 sensevoice-server/models/ 目录",
                           "Place GGUF model in sensevoice-server/models/"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentRed.opacity(0.8))
                }
            }

            // Server status + start button
            if modelAvailable {
                SettingsDivider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(serverRunning ? TF.settingsAccentGreen : TF.settingsAccentRed)
                        .frame(width: 8, height: 8)
                    Text(serverRunning
                        ? L("推理服务运行中", "Inference server running")
                        : L("推理服务未启动", "Inference server stopped"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                    Spacer()
                    if !serverRunning {
                        Button {
                            startLocalServer()
                        } label: {
                            if serverStarting {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 60)
                            } else {
                                Text(L("启动", "Start"))
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 60)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TF.settingsAccentAmber)
                        .controlSize(.small)
                        .disabled(serverStarting)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .task {
            await checkServerStatus()
        }
    }

    private func startLocalServer() {
        Task { await preloadLocalLLM() }
    }

    private func checkServerStatus() async {
        serverRunning = await SenseVoiceServerManager.shared.isRunning
    }

    /// Start server + send dummy request to trigger LLM model loading (~7-13s).
    private func preloadLocalLLM() async {
        serverStarting = true
        do {
            try await SenseVoiceServerManager.shared.start()
            serverRunning = true

            // Trigger lazy LLM model load with a minimal request
            if let port = SenseVoiceServerManager.currentPort {
                let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 60  // Model load can take a while
                let body = #"{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}"#
                request.httpBody = body.data(using: .utf8)
                NSLog("[Settings] Preloading local LLM model...")
                _ = try? await URLSession.shared.data(for: request)
                NSLog("[Settings] Local LLM model preloaded")
            }
        } catch {
            NSLog("[Settings] Local server start failed: %@", String(describing: error))
        }
        serverStarting = false
    }

    /// Stop server if ASR doesn't need it (user switched away from local LLM).
    private func stopServerIfUnneeded() async {
        let asrNeedsServer = KeychainService.selectedASRProvider == .sherpa
        if !asrNeedsServer {
            await SenseVoiceServerManager.shared.stop()
            serverRunning = false
            NSLog("[Settings] Stopped local server (no longer needed)")
        }
    }

    // MARK: - Provider Picker

    private var llmProviderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("服务商", "Provider").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { selectedLLMProvider.rawValue },
                    set: { if let p = LLMProvider(rawValue: $0) { selectedLLMProvider = p } }
                ),
                options: LLMProvider.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
        .padding(.vertical, 6)
        .onChange(of: selectedLLMProvider) { _, newProvider in
            testTask?.cancel()
            llmTestStatus = .idle
            isEditingLLM = true
            loadLLMCredentialsForProvider(newProvider)

            // Auto-save provider switch if target already has credentials (or needs none)
            let oldProvider = KeychainService.selectedLLMProvider
            if newProvider == .localQwen || hasLLMCredentials {
                KeychainService.selectedLLMProvider = newProvider
                if newProvider == .localQwen {
                    Task { await preloadLocalLLM() }
                } else if oldProvider == .localQwen {
                    Task { await stopServerIfUnneeded() }
                }
            }
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        let fields = currentLLMFields
        let rows = stride(from: 0, to: fields.count, by: 2).map { i in
            Array(fields[i..<min(i+2, fields.count)])
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { SettingsDivider() }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row) { field in
                        credentialFieldRow(field)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if row.count == 1 {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func credentialFieldRow(_ field: CredentialField) -> some View {
        let binding = Binding<String>(
            get: { llmCredentialValues[field.key] ?? "" },
            set: {
                llmCredentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
        if !field.options.isEmpty {
            let pickerBinding = Binding<String>(
                get: {
                    let val = llmCredentialValues[field.key] ?? ""
                    return val.isEmpty ? (savedLLMValues[field.key] ?? field.defaultValue) : val
                },
                set: {
                    llmCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsPickerField(field.label, selection: pickerBinding, options: field.options)
        } else {
            let savedVal = savedLLMValues[field.key] ?? ""
            let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
            if field.isSecure {
                settingsSecureField(field.label, text: binding, prompt: placeholder)
            } else {
                settingsField(field.label, text: binding, prompt: placeholder)
            }
        }
    }

    private var llmSummaryRows: [(String, String)] {
        var rows: [(String, String)] = []
        for field in currentLLMFields {
            let val = llmCredentialValues[field.key] ?? ""
            guard !val.isEmpty else { continue }
            let display = field.isSecure ? maskedSecret(val) : val
            rows.append((field.label, display))
        }
        return rows
    }

    // MARK: - Data

    private func loadLLMCredentials() {
        selectedLLMProvider = KeychainService.selectedLLMProvider
        loadLLMCredentialsForProvider(selectedLLMProvider)
    }

    private func loadLLMCredentialsForProvider(_ provider: LLMProvider) {
        testTask?.cancel()
        editedFields = []
        if let values = KeychainService.loadLLMCredentials(for: provider) {
            llmCredentialValues = values
            savedLLMValues = values
            hasStoredLLM = true
            isEditingLLM = !hasLLMCredentials
        } else {
            var defaults: [String: String] = [:]
            let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            for field in fields where !field.defaultValue.isEmpty {
                defaults[field.key] = field.defaultValue
            }
            llmCredentialValues = defaults
            savedLLMValues = [:]
            hasStoredLLM = false
            isEditingLLM = true
        }
    }

    private func saveLLMCredentials() {
        let values = effectiveLLMValues
        do {
            try KeychainService.saveLLMCredentials(for: selectedLLMProvider, values: values)
            KeychainService.selectedLLMProvider = selectedLLMProvider
            llmCredentialValues = values
            savedLLMValues = values
            editedFields = []
            hasStoredLLM = true
            isEditingLLM = false
            llmTestStatus = .saved

            // Preload local LLM model on save
            if selectedLLMProvider == .localQwen {
                Task { await preloadLocalLLM() }
            }
        } catch {
            llmTestStatus = .failed(L("保存失败", "Save failed"))
        }
    }

    private func testLLMConnection() {
        testTask?.cancel()
        llmTestStatus = .testing
        let testValues = effectiveLLMValues
        let provider = selectedLLMProvider
        testTask = Task {
            do {
                let llmConfig: LLMConfig
                if provider == .localQwen {
                    // Local Qwen uses SenseVoice server's dynamic port
                    guard let port = SenseVoiceServerManager.currentPort else {
                        guard !Task.isCancelled else { return }
                        llmTestStatus = .failed(L("SenseVoice 服务未运行", "SenseVoice server not running"))
                        return
                    }
                    llmConfig = LLMConfig(apiKey: "", model: "qwen3-4b", baseURL: "http://127.0.0.1:\(port)/v1")
                } else {
                    guard let configType = LLMProviderRegistry.configType(for: provider),
                          let config = configType.init(credentials: testValues)
                    else {
                        guard !Task.isCancelled else { return }
                        llmTestStatus = .failed(L("配置无效", "Invalid config"))
                        return
                    }
                    llmConfig = config.toLLMConfig()
                }
                let client: any LLMClient = provider == .claude
                    ? ClaudeChatClient()
                    : DoubaoChatClient(provider: provider)
                let reply = try await client.process(text: "hi", prompt: "{text}", config: llmConfig)
                guard !Task.isCancelled else { return }
                llmTestStatus = .success
                NSLog("[Settings] LLM test OK (%@): %@", provider.rawValue, reply)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[Settings] LLM test failed (%@): %@", provider.rawValue, String(describing: error))
                llmTestStatus = .failed(L("连接失败", "Connection failed"))
            }
        }
    }
}
