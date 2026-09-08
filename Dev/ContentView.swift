import SwiftUI

struct ContentView: View {
  enum Page {
    case icon, localization
  }
  @State var createIcon = CreateIcon()
  @State var page = Page.icon
  var body: some View {
    NavigationSplitView {
      List {
        Button("Create Icon") {
          page = .icon
        }
        Button("Localization") {
          page = .localization
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
