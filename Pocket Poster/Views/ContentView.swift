//
//  ContentView.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

struct ContentView: View {
    @ObservedObject var pbManager = PosterBoardManager.shared
    
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    
    @State var showTendiesImporter: Bool = false
    @State var hideResetHelp: Bool = true
    
    var body: some View {
        NavigationStack {
            List {
                Section {} header: {
                    Label("Version \(Bundle.main.releaseVersionNumber ?? "UNKNOWN") (\(Int(buildNumber) != 0 ? "Beta \(buildNumber)" : NSLocalizedString("Release", comment:"")))", systemImage: "info.circle.fill")
                        .font(.caption)
                }
                
                Section {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        showTendiesImporter.toggle()
                    }) {
                        Label("Select Tendies", systemImage: "document.circle")
                    }
                    .buttonStyle(TintedButton(color: .green, fullwidth: true))
                }
                .listRowInsets(EdgeInsets())
                .padding(7)
                
                if !pbManager.selectedTendies.isEmpty {
                    Section {
                        ForEach(pbManager.selectedTendies, id: \.self) { tendie in
                            Text(tendie.deletingPathExtension().lastPathComponent)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Label("Selected Tendies", systemImage: "document")
                    }
                }
                
                // 【应用区域】
                Section {
                    VStack {
                        if !pbManager.selectedTendies.isEmpty || !pbManager.videos.isEmpty {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                // 立刻呼出弹窗，覆盖整个长达 5 秒的底层操作轴
                                UIApplication.shared.alert(title: NSLocalizedString("Applying...", comment: ""), body: NSLocalizedString("Please wait 5 seconds...", comment: ""), animated: false, withButton: false)

                                DispatchQueue.global(qos: .userInitiated).async {
                                    do {
                                        // 核心操作：内部包含了 [杀 -> 写 -> 杀 -> 等5秒 -> 绝杀] 的完整时序
                                        try PosterBoardManager.shared.applyTendies()
                                        SymHandler.cleanup()
                                        try? FileManager.default.removeItem(at: PosterBoardManager.shared.getTendiesStoreURL())
                                        
                                        DispatchQueue.main.async {
                                            // 全部操作(包含5秒休眠)执行完毕后，才关闭弹窗
                                            UIApplication.shared.dismissAlert(animated: false)
                                            PosterBoardManager.shared.selectedTendies.removeAll()
                                            Haptic.shared.notify(.success)
                                        }
                                    } catch CocoaError.fileWriteUnknown {
                                        self.presentError(ApplyError.wrongAppHash)
                                    } catch CocoaError.fileWriteFileExists {
                                        self.presentError(ApplyError.collectionsNeedsReset)
                                    } catch {
                                        print(error.localizedDescription)
                                        self.presentError(ApplyError.unexpected(info: error.localizedDescription))
                                    }
                                }
                            }) {
                                Label("Apply", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(TintedButton(color: .blue, fullwidth: true))
                        }
                        Button(action: {
                            if #available(iOS 18.0, *) {
                                guard let lang = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first else {
                                    hideResetHelp = false
                                    return
                                }
                                UIApplication.shared.confirmAlert(title: NSLocalizedString("Reset Collections", comment: ""), body: NSLocalizedString("Do you want to reset collections?", comment: ""), onOK: {
                                    if PosterBoardManager.shared.setSystemLanguage(to: lang) {
                                        UIApplication.shared.alert(title: NSLocalizedString("Collections Successfully Reset!", comment: ""), body: NSLocalizedString("Your PosterBoard will refresh automatically.", comment: ""))
                                    } else {
                                        UIApplication.shared.alert(body: "The API failed to call correctly.\nSystem Locale Code: \(lang)")
                                    }
                                }, noCancel: false)
                            } else {
                                hideResetHelp = false
                            }
                        }) {
                            Label("Reset Collections", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(TintedButton(color: .red, fullwidth: true))
                    }
                    .listRowInsets(EdgeInsets())
                    .padding(7)
                } header: {
                    Label("Actions", systemImage: "hammer")
                }
                
                // 【删除区域】
                if !pbManager.appliedWallpapers.isEmpty {
                    Section {
                        ForEach(pbManager.appliedWallpapers) { wallpaper in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(wallpaper.displayName)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    Text(wallpaper.extensionType.replacingOccurrences(of: "com.apple.", with: ""))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    // 唤起专属的 6 秒删除等待弹窗
                                    UIApplication.shared.alert(title: NSLocalizedString("Deleting...", comment: ""), body: NSLocalizedString("Please wait 6 seconds...", comment: ""), animated: false, withButton: false)
                                    
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        do {
                                            // 核心操作：内部包含了 [杀 -> 删 -> 等6秒 -> 绝杀]
                                            try PosterBoardManager.shared.deleteAppliedWallpaper(wallpaper)
                                            DispatchQueue.main.async {
                                                // 6秒流水线跑完后，关闭界面遮罩
                                                UIApplication.shared.dismissAlert(animated: false)
                                                Haptic.shared.notify(.success)
                                            }
                                        } catch {
                                            DispatchQueue.main.async {
                                                UIApplication.shared.dismissAlert(animated: false)
                                                UIApplication.shared.alert(body: "删除失败: \(error.localizedDescription)")
                                            }
                                        }
                                    }
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    } header: {
                        Label("已导入的第三方自定壁纸 (点击垃圾桶单个删除并即时刷新)", systemImage: "photo.stack.fill")
                    }
                }
            }
            .navigationTitle("Pocket Poster")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let wpURL = URL(string: PosterBoardManager.WallpapersURL) {
                        Link(destination: wpURL) {
                            Image(systemName: "safari")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing, content: {
                    NavigationLink(destination: {
                        SettingsView()
                    }, label: {
                        Image(systemName: "gear")
                    })
                })
            }
        }
        .fileImporter(isPresented: $showTendiesImporter, allowedContentTypes: [UTType(filenameExtension: "tendies", conformingTo: .data)!], allowsMultipleSelection: true, onCompletion: { result in
            switch result {
            case .success(let url):
                if pbManager.selectedTendies.count + url.count > PosterBoardManager.MaxTendies {
                    UIApplication.shared.alert(title: NSLocalizedString("Max Tendies Reached", comment: ""), body: String(format: NSLocalizedString("You can only apply %@ descriptors.", comment: ""), "\(PosterBoardManager.MaxTendies)"))
                } else {
                    pbManager.selectedTendies.append(contentsOf: url)
                }
            case .failure(let error):
                Haptic.shared.notify(.error)
                UIApplication.shared.alert(body: error.localizedDescription)
            }
        })
        .overlay {
            OnBoardingView(cards: resetCollectionsInfo, isFinished: $hideResetHelp)
                .opacity(hideResetHelp ? 0.0 : 1.0)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.5), value: hideResetHelp)
        }
        .onAppear {
            pbManager.fetchAppliedWallpapers()
        }
    }
    
    func delete(at offsets: IndexSet) {
        pbManager.selectedTendies.remove(atOffsets: offsets)
    }
    
    func presentError(_ error: ApplyError) {
        SymHandler.cleanup()
        DispatchQueue.main.async {
            UIApplication.shared.dismissAlert(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: {
            Haptic.shared.notify(.error)
            UIApplication.shared.alert(body: error.localizedDescription)
        })
    }
    
    init() {
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)
    }
}
