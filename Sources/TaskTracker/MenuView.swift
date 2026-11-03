import AppKit
import SwiftUI
import TaskTrackerCore

/// The Menu tab: per PR, the checks and ideas an agent left for you. A PR's header stays at the
/// top while you scroll through its items.
struct MenuView: View {
    @Bindable var panel: MenuPanel

    var body: some View {
        let groups = panel.groups
        if groups.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.pr.id) { group in
                            let expanded = panel.isExpanded(group.pr, items: group.items)
                            Section {
                                PRBody(panel: panel, pr: group.pr, items: group.items, expanded: expanded)
                            } header: {
                                PRHeader(panel: panel, pr: group.pr, items: group.items, expanded: expanded)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: panel.selectedID) {
                    guard let id = panel.selectedID else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Nothing to check")
                .font(.system(size: 13, weight: .semibold))
            Text("When an agent opens a PR, what it couldn’t check itself lands here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A PR's line: expands and collapses it, and stays pinned at the top while its items scroll.
private struct PRHeader: View {
    @Bindable var panel: MenuPanel
    let pr: MenuPR
    let items: [MenuItem]
    let expanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
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
                    if !expanded { Counts(items: items) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse #\(pr.number)" : "Expand #\(pr.number)")

            if let state = pr.state { StateChip(state: state) }
            if let url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open #\(pr.number) on GitHub")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(HeaderBackground())
        .contextMenu {
            Button(expanded ? "Collapse" : "Expand", action: toggle)
            if let url {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button(items.count == 1 ? "Delete 1 Item" : "Delete \(items.count) Items", role: .destructive) {
                panel.delete(items)
            }
        }
    }

    private var url: URL? { pr.url.flatMap(URL.init(string:)) }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { panel.setExpanded(pr, items: items, !expanded) }
    }
}

/// What scrolls under a pinned header shows through blurred, like a list's section header.
private struct HeaderBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Under a PR's header: the banner when problems wait for a fix, and its items when expanded.
private struct PRBody: View {
    @Bindable var panel: MenuPanel
    let pr: MenuPR
    let items: [MenuItem]
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let problems = items.filter { $0.status == .problem }
            if !problems.isEmpty { fixBanner(count: problems.count) }
            if expanded {
                ForEach(items) { item in
                    ItemRow(panel: panel, pr: pr, item: item)
                        .id(item.id)
                }
            }
        }
        .padding(.bottom, 4)
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
        .padding(.leading, 38)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
    }
}

/// What a closed PR still holds: open checks and ideas.
private struct Counts: View {
    let items: [MenuItem]

    var body: some View {
        let checks = items.filter { $0.kind == .check && $0.status == .open }.count
        let ideas = items.filter { $0.kind == .idea && $0.status == .open }.count
        HStack(spacing: 8) {
            if checks > 0 { count(checks, "magnifyingglass", .cyan) }
            if ideas > 0 { count(ideas, "lightbulb", .yellow) }
            if checks == 0 && ideas == 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(checks) to check, \(ideas) \(ideas == 1 ? "idea" : "ideas")")
    }

    private func count(_ value: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(verbatim: "\(value)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
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
        .padding(.horizontal, 8)
        .contextMenu { contextMenu }
    }

    /// Right-click: the same decisions as the buttons, plus Dismiss and Delete for every item.
    @ViewBuilder private var contextMenu: some View {
        switch item.kind {
        case .check:
            if item.openURL != nil {
                Button("Open") { panel.open(item) }
                Divider()
            }
            Button("Works") { panel.setStatus(item, .works) }
                .disabled(item.status == .works)
            Button("Problem…") { panel.beginProblem(item) }
        case .idea:
            Button("Make Issue") { panel.makeIssue(item) }
                .disabled(item.status == .issue)
            Button("Later") { panel.setStatus(item, .later) }
                .disabled(item.status == .later)
        }
        Button("Dismiss") { panel.setStatus(item, .dismissed) }
            .disabled(item.status == .dismissed)
        if [.works, .issue, .later, .dismissed].contains(item.status) {
            Button("Back to Open") { panel.setStatus(item, .open) }
        }
        if item.link != nil {
            Divider()
            Button(item.status == .issue ? "View Issue" : "View Comment") { panel.openLink(item) }
        }
        Divider()
        Button("Delete", role: .destructive) { panel.delete([item]) }
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
                    Button("Dismiss") { panel.setStatus(item, .dismissed) }
                }
                Spacer(minLength: 4)
                if item.link != nil {
                    Button(item.status == .issue ? "View issue" : "View comment") { panel.openLink(item) }
                        .buttonStyle(.link)
                }
                Button { panel.delete([item]) } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete (⌘Z brings it back)")
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
