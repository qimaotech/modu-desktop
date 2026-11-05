import SwiftUI

struct CommitLaneView: View {
    let index: Int
    let count: Int
    var rowHeight: CGFloat = 24

    var body: some View {
        Image("DesignIcons/CommitLane").resizable().frame(width: 24, height: 72)
            .offset(y: index == 0 ? 0 : index == count - 1 ? -48 : -24)
            .offset(y: (rowHeight - 24) / 2)
            .frame(width: 24, height: rowHeight, alignment: .top).clipped()
            .mask { if count == 1 { Circle().frame(width: 6, height: 6) } else { Rectangle() } }
            .accessibilityHidden(true)
    }
}
