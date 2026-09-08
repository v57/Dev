import SwiftUI

struct ContentView: View {
  enum Page: Hashable {
    case icon, localization
  }
  @State var createIcon = CreateIcon()
  @State var page = Page.icon
  var body: some View {
    NavigationSplitView {
      List(selection: $page) {
        NavigationLink(value: Page.icon) {
          Label("Create Icon", systemImage: "hammer.fill")
        }
        NavigationLink(value: Page.localization) {
          Label("Localization", systemImage: "globe")
        }
      }
      .navigationDestination(for: Page.self) { page in
        switch page {
        case .icon:
          CreateIconView().environment(createIcon)
        case .localization:
          LocalizationView()
        }
      }
    } detail: {
      switch page {
      case .icon:
        CreateIconView().environment(createIcon)
      case .localization:
        LocalizationView()
      }
    }
  }
}

#Preview {
  ContentView()
}
