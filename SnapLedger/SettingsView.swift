//
//  SettingsView.swift
//  家庭账本连接、身份、截图权限
//

import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared
    @ObservedObject private var sync = SyncEngine.shared

    @State private var joinCode: String = ""
    @State private var busy = false
    @State private var err: String?
    @State private var photoStatus: String = "未知"

    private var code: String { store.db.sync?.code ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                familySection
                identitySection
                captureSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("出错了", isPresented: .init(get: { err != nil }, set: { if !$0 { err = nil } })) {
                Button("好") { err = nil }
            } message: {
                Text(err ?? "")
            }
            .task { await refreshPhotoStatus() }
        }
    }

    // MARK: 家庭账本

    @ViewBuilder
    private var familySection: some View {
        Section {
            if code.isEmpty {
                Text("还没有连接家庭账本。两台手机要用同一个账本，先在一台上创建，另一台输入邀请码加入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    run { try await sync.createFamily() }
                } label: {
                    HStack {
                        Text("创建新的家庭账本")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)

                HStack {
                    TextField("输入 6 位邀请码", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("加入") {
                        run { try await sync.joinFamily(joinCode) }
                    }
                    .disabled(busy || joinCode.trimmingCharacters(in: .whitespaces).count < 4)
                }
            } else {
                HStack {
                    Text("邀请码")
                    Spacer()
                    Text(code)
                        .font(.body.monospaced().bold())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }

                LabeledContent("同步状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(sync.state == .error ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(sync.state.label)
                    }
                }

                if !sync.message.isEmpty {
                    Text(sync.message).font(.footnote).foregroundStyle(.orange)
                }

                LabeledContent("本机记录", value: "\(store.db.records.count) 条")

                Button("立即同步") {
                    sync.now()
                }

                Button("离开这个账本", role: .destructive) {
                    sync.leaveFamily()
                }
            }
        } header: {
            Text("家庭账本")
        } footer: {
            Text("两台 iPhone 用同一个邀请码，账目自动合并。数据主要存在各自手机上，服务器只做交换。")
        }
    }

    // MARK: 身份

    @ViewBuilder
    private var identitySection: some View {
        Section {
            Picker("我是", selection: Binding(
                get: { store.selfMemberId },
                set: { sync.setSelfMember($0) }
            )) {
                ForEach(store.db.members) { m in
                    Text("\(m.emoji) \(m.name)").tag(m.id)
                }
            }
            if store.db.members.count < 2 {
                Text("换一台手机加入后，这里会出现对方的名字。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("身份")
        } footer: {
            Text("记的账会带上这个身份，聊天里能看出是谁记的。")
        }
    }

    // MARK: 截图

    @ViewBuilder
    private var captureSection: some View {
        Section {
            LabeledContent("相册权限", value: photoStatus)
            Button("立即读取最新一张截图") {
                Task {
                    await ScreenshotWatcher.shared.pickUpNow()
                    photoStatus = "已触发，回到聊天页看结果"
                }
            }
        } header: {
            Text("截图识别")
        } footer: {
            Text("轻点背面 → 打开本 App 时，会自动读取最近 2 分钟内的截图并识别，不用你把图贴进来。若相册设为「仅选中的照片」，新截图读不到，需要改成允许访问所有照片。")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("识别引擎", value: "系统 Vision · 设备端")
            LabeledContent("数据位置", value: "本机 + 家庭交换站")
        } header: {
            Text("关于")
        } footer: {
            Text("图片不离开手机，只有识别出的文字和账目会参与同步。")
        }
    }

    // MARK: 工具

    private func run(_ work: @escaping () async throws -> String) {
        busy = true
        Task {
            do {
                _ = try await work()
                busy = false
            } catch {
                busy = false
                err = error.localizedDescription
            }
        }
    }

    private func refreshPhotoStatus() async {
        let status = await ScreenshotWatcher.ensurePhotoAccess()
        switch status {
        case .authorized: photoStatus = "允许访问所有照片"
        case .limited: photoStatus = "仅选中的照片（可能读不到新截图）"
        case .denied, .restricted: photoStatus = "已拒绝"
        case .notDetermined: photoStatus = "未询问"
        @unknown default: photoStatus = "未知"
        }
    }
}
