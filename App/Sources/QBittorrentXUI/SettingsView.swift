import QBKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(Settings.Key.columns) private var columns = TableColumnCustomization<Torrent>()

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var saved = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("服务器") {
                TextField("地址", text: $url, prompt: Text("https://bt.example.com"))
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
                // API Key 用明文：它是令牌不是登录密码，遮住反而看不出填错了哪一段。
                TextField("API Key（可选）", text: $apiKey)
                HStack {
                    Button("保存并连接") { save() }
                    if saved {
                        Text("已保存到钥匙串").foregroundStyle(.secondary)
                    }
                }
                Text("密码与 API Key 只存钥匙串，不进偏好设置文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("数据用量") {
                Picker("档位", selection: $model.dataUsage) {
                    ForEach(Settings.DataUsage.allCases, id: \.self) { usage in
                        Text(usage.displayName).tag(usage)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isModeForcedLite)

                if model.isModeForcedLite {
                    Text("只填了 API Key，拿不到会话 cookie，无法增量同步，已强制省流量。要用完整档请填用户名和密码。")
                        .font(.caption).foregroundStyle(.orange)
                } else if model.dataUsage == .auto {
                    Text(model.isMeteredPath
                         ? "当前网络被判定为计费或低数据模式，已自动切到省流量。"
                         : "当前网络不计费，使用完整档。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("省流量刷新间隔")
                    TextField("30", value: $model.liteInterval, format: .number)
                        .frame(width: 60)
                    Text("秒（5–300）")
                    Spacer()
                    Text("越大越省，单任务统计粒度也越粗")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(model.snapshot.mode != .lite)
            }

            Section("界面") {
                Button("重置列显隐与顺序") { columns = TableColumnCustomization<Torrent>() }
                Text("列宽由系统决定，SwiftUI 没有列宽持久化接口，拖动的宽度重启后不保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(20)
        .onAppear(perform: load)
        .onChange(of: model.dataUsage) { model.applyDataUsage() }
        .onChange(of: model.liteInterval) { model.applyIntervals() }
    }

    private func load() {
        let c = model.loadCredentials()
        url = c.baseURL
        username = c.username
        password = c.password
        apiKey = c.apiKey
    }

    private func save() {
        model.saveCredentials(
            Credentials(baseURL: url, username: username, password: password, apiKey: apiKey)
        )
        saved = model.actionError == nil
    }
}