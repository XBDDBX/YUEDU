import SwiftUI

@main
struct AuraReadApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppStore.shared)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: Int = 0

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                ShelfView()
                    .tabItem { Label("书架", systemImage: "books.vertical") }
                    .tag(0)

                SearchView()
                    .tabItem { Label("找书", systemImage: "magnifyingglass") }
                    .tag(1)

                SourceListView()
                    .tabItem { Label("书源", systemImage: "square.stack.3d.up") }
                    .tag(2)

                SettingsHomeView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(.blue)

            if let t = store.toast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.footnote)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 70)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
    }
}
