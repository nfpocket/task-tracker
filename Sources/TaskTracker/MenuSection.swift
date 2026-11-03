import SwiftUI
import TaskTrackerCore

/// The menu at the top of the popover: per PR, the checks and ideas an agent left for you.
/// Hidden while there's nothing on it.
struct MenuSection: View {
    @Bindable var panel: MenuPanel
    @State private var contentHeight: CGFloat = 0

    /// The task list below keeps the rest of the popover.
    static let maxHeight: CGFloat = 290

    var body: some View {
        let groups = panel.groups
        if !groups.isEmpty {
            VStack(spacing: 0) {
                header(open: groups.reduce(0) { $0 + $1.items.filter { $0.status == .open }.count })
                if !panel.collapsed {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(groups, id: \.pr.id) { group in
                                    PRGroup(panel: panel, pr: group.pr, items: group.items)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        }
                        .frame(height: min(max(contentHeight, 1), Self.maxHeight))
                        .onChange(of: panel.selectedID) {
                            guard let id = panel.selectedID else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                        }
                    }
                }
                if let message = panel.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(panel.messageIsError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                        .textSelection(.enabled)
                }
            }
            Divider()
        }
    }

    private func header(open: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { panel.collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(panel.collapsed ? 0 : 90))
                    .frame(width: 10)
                Image(systemName: "hourglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Menu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(open)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .help(panel.collapsed ? "Show the menu" : "Hide the menu")
    }
}

/// One PR: its header, a banner when problems wait for a fix, and its items.
private struct PRGroup: View {
    @Bindable var panel: MenuPanel
    let pr: MenuPR
    let items: [MenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: "#\(pr.number)")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: pr.title ?? pr.repo)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let state = pr.state { StateChip(state: state) }
            }
            .padding(.leading, 18)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
            .help(pr.repo)
            .onTapGesture {
                if let url = pr.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            }

            let problems = items.filter { $0.status == .problem }
            if !problems.isEmpty { fixBanner(count: problems.count) }

            ForEach(items) { item in
                ItemRow(panel: panel, pr: pr, item: item)
                    .id(item.id)
            }
        }
    }

    private func fixBanner(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: count == 1 ? "1 problem waiting in PR #\(pr.number)" : "\(count) problems waiting in PR #\(pr.number)")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Spacer(minLength: 4)
            if panel.isBusy(pr.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Fix in its session") { panel.fix(pr) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Sends the problems to the Claude Code session that built this PR, in Ghostty")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
        .padding(.leading, 30)
        .padding(.vertical, 2)
    }
}

private struct StateChip: View {
    let state: PRState

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private var label: String {
        switch state {
        case .open: "PR open"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    private var color: Color {
        switch state {
        case .open: .blue
        case .merged: .purple
        case .closed: .secondary
        }
    }
}

private struct ItemRow: View {
    @Bindable var panel: MenuPanel
    let pr: MenuPR
    let item: MenuItem

    private var selected: Bool { panel.selectedID == item.id }
    private var reporting: Bool { panel.reportingID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { panel.toggle(item) } label: { row }
                .buttonStyle(.plain)
            if reporting {
                problemForm
            } else if selected {
                details
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.primary.opacity(0.08) : .clear))
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(item.status.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = item.note, item.status == .open {
                    Text(verbatim: "\(note) · check again")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 6)
            if panel.isBusy(item.id) {
                ProgressView().controlSize(.mini)
            } else {
                Text(verbatim: meta)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(metaColor)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .open where item.kind == .check: Image(systemName: "magnifyingglass").foregroundStyle(.cyan)
        case .open: Image(systemName: "lightbulb").foregroundStyle(.yellow)
        case .works: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem: Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
        case .fixing: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .issue: Image(systemName: "smallcircle.filled.circle").foregroundStyle(.green)
        case .later: Image(systemName: "moon.zzz").foregroundStyle(.purple)
        case .dismissed: Image(systemName: "xmark").foregroundStyle(.secondary)
        }
    }

    private var meta: String {
        switch item.status {
        case .open: item.minutes.map { "\($0) min" } ?? ""
        case .issue: item.issue.map { "#\($0)" } ?? "issue"
        default: item.status.label
        }
    }

    private var metaColor: Color {
        switch item.status {
        case .problem, .fixing: .orange
        case .issue: .green
        default: .secondary
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let why = item.why {
                Text(verbatim: why)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let location = item.location {
                Label { Text(verbatim: location) } icon: { Image(systemName: "mappin") }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let problem = item.problem, item.status == .problem || item.status == .fixing || item.status == .issue {
                Text(verbatim: "Problem: \(problem)")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                switch item.kind {
                case .check:
                    if item.openURL != nil {
                        Button("Open") { panel.open(item) }.buttonStyle(.borderedProminent)
                    }
                    Button("Works") { panel.setStatus(item, .works) }
                    Button("Problem…") { panel.beginProblem(item) }
                case .idea:
                    Button("Make issue") { panel.makeIssue(item) }.buttonStyle(.borderedProminent)
                    Button("Later") { panel.setStatus(item, .later) }
                    Button("No") { panel.setStatus(item, .dismissed) }
                }
                if item.link != nil {
                    Spacer(minLength: 4)
                    Button(item.status == .issue ? "View issue" : "View comment") { panel.openLink(item) }
                        .buttonStyle(.link)
                }
            }
            .controlSize(.small)
            .disabled(panel.isBusy(item.id))
        }
        .padding(.leading, 54)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
    }

    private var problemForm: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What’s wrong?")
                .font(.system(size: 12, weight: .semibold))
            TextField("", text: $panel.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(2...5)
                .onSubmit { send() }
            Text(verbatim: pr.state == .open || pr.state == nil
                 ? "Goes to PR #\(pr.number) as a comment. The fix lands in that PR."
                 : "PR #\(pr.number) is \(pr.state!.rawValue), so this becomes a new issue that links to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button {
                    send()
                } label: {
                    Text(verbatim: pr.state == .open || pr.state == nil ? "Send to PR #\(pr.number)" : "Make issue")
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(panel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || panel.isBusy(item.id))
                Button("Cancel") { panel.cancelProblem() }
                if panel.isBusy(item.id) { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
        }
        .padding(.leading, 54)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
    }

    private func send() {
        guard !panel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        panel.sendProblem(item)
    }
}
